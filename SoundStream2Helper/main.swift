import Foundation
import ScreenCaptureKit
import Accelerate
import AVFoundation
import CoreMedia
import CoreGraphics

let kShmName = "/soundstream2_audio"

struct SharedAudioData {
    var level: Float = 0
    var peak: Float = 0
    var smoothLevel: Float = 0
    var spectrum: (
        Float, Float, Float, Float,
        Float, Float, Float, Float,
        Float, Float, Float, Float,
        Float, Float, Float, Float
    ) = (0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0)
    var active: UInt32 = 0
    var timestamp: UInt64 = 0

    func spectrumValue(at index: Int) -> Float {
        withUnsafeBytes(of: spectrum) { buf in
            buf.load(fromByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
        }
    }

    mutating func setSpectrum(at index: Int, value: Float) {
        withUnsafeMutableBytes(of: &spectrum) { buf in
            buf.storeBytes(of: value, toByteOffset: index * MemoryLayout<Float>.size, as: Float.self)
        }
    }
}

let kShmSize = MemoryLayout<SharedAudioData>.size
let spectrumBands = 16
let audioBufSize = 1024

var shmPtr: UnsafeMutablePointer<SharedAudioData>?
var autoGain: Float = 30.0
var fftSetup: vDSP.FFT<DSPSplitComplex>?
var window = [Float]()
var tapCount = 0
var stream: SCStream?

func setupSharedMemory() -> Bool {
    shm_unlink_bridge(kShmName)
    let fd = shm_open_bridge(kShmName, O_CREAT | O_RDWR, 0o666)
    guard fd >= 0 else {
        NSLog("SOUNDSTREAM-HELPER: shm_open failed: %d", errno)
        return false
    }
    ftruncate(fd, off_t(kShmSize))
    let ptr = mmap(nil, kShmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    close(fd)
    guard ptr != MAP_FAILED else {
        NSLog("SOUNDSTREAM-HELPER: mmap failed")
        return false
    }
    shmPtr = ptr!.assumingMemoryBound(to: SharedAudioData.self)
    shmPtr!.pointee = SharedAudioData()
    NSLog("SOUNDSTREAM-HELPER: Shared memory created OK")
    return true
}

func processAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
    guard let shm = shmPtr, frameCount > 0 else { return }

    var rawRms: Float = 0
    vDSP_rmsqv(samples, 1, &rawRms, vDSP_Length(frameCount))
    if !rawRms.isFinite { rawRms = 0 }

    tapCount += 1
    if tapCount <= 5 || tapCount % 200 == 0 {
        var maxSample: Float = 0
        vDSP_maxmgv(samples, 1, &maxSample, vDSP_Length(min(frameCount, 256)))
        NSLog("SOUNDSTREAM-HELPER: tap #%d frames=%d rawRms=%.6f max=%.6f gain=%.1f",
              tapCount, frameCount, rawRms, maxSample, autoGain)
    }

    if rawRms > 0.00005 {
        let target = min(max(0.25 / rawRms, 3.0), 150.0)
        autoGain = autoGain * 0.99 + target * 0.01
    }

    let rms = min(rawRms * autoGain, 1.0)

    shm.pointee.active = 1
    shm.pointee.level = rms
    shm.pointee.smoothLevel = shm.pointee.smoothLevel * 0.8 + rms * 0.2
    if rms > shm.pointee.peak {
        shm.pointee.peak = rms
    } else {
        shm.pointee.peak *= 0.97
    }
    shm.pointee.timestamp = mach_absolute_time()

    if frameCount >= audioBufSize {
        computeSpectrum(samples: samples, shm: shm)
    }
}

func computeSpectrum(samples: UnsafePointer<Float>, shm: UnsafeMutablePointer<SharedAudioData>) {
    let n = audioBufSize
    let log2n = vDSP_Length(log2f(Float(n)))

    if window.isEmpty {
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
    }

    var windowed = [Float](repeating: 0, count: n)
    vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

    let halfN = n / 2
    var realp = [Float](repeating: 0, count: halfN)
    var imagp = [Float](repeating: 0, count: halfN)

    realp.withUnsafeMutableBufferPointer { realBuf in
        imagp.withUnsafeMutableBufferPointer { imagBuf in
            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
            windowed.withUnsafeBufferPointer { winBuf in
                winBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(halfN))
                }
            }
            if fftSetup == nil {
                fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)
            }
            fftSetup?.forward(input: split, output: &split)

            var mags = [Float](repeating: 0, count: halfN)
            vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))

            let gain = autoGain * autoGain * 0.0001
            let binsPerBand = halfN / spectrumBands
            for i in 0..<spectrumBands {
                var sum: Float = 0
                for j in (i * binsPerBand)..<((i + 1) * binsPerBand) {
                    sum += mags[j]
                }
                var val = min(sqrtf(sum / Float(binsPerBand)) * gain, 1.0)
                let old = shm.pointee.spectrumValue(at: i)
                val = old * 0.6 + val * 0.4
                shm.pointee.setSpectrum(at: i, value: val)
            }
        }
    }
}

// MARK: - SCStream Audio Delegate

class AudioOutputHandler: NSObject, SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var data = [UInt8](repeating: 0, count: length)
        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: &data)

        let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer)
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc!)!.pointee

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let channels = Int(asbd.mChannelsPerFrame)
            let totalFloats = length / MemoryLayout<Float>.size
            let framesPerChannel = totalFloats / max(channels, 1)

            data.withUnsafeBufferPointer { bytesBuf in
                bytesBuf.baseAddress!.withMemoryRebound(to: Float.self, capacity: totalFloats) { floatPtr in
                    if channels > 1 {
                        var mono = [Float](repeating: 0, count: framesPerChannel)
                        for i in 0..<framesPerChannel {
                            var sum: Float = 0
                            for ch in 0..<channels {
                                sum += floatPtr[i * channels + ch]
                            }
                            mono[i] = sum / Float(channels)
                        }
                        processAudioSamples(&mono, frameCount: framesPerChannel)
                    } else {
                        processAudioSamples(floatPtr, frameCount: totalFloats)
                    }
                }
            }
        }
    }
}

let audioHandler = AudioOutputHandler()

func startSystemAudioCapture() async -> Bool {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            NSLog("SOUNDSTREAM-HELPER: No display found")
            return false
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.channelCount = 2
        config.sampleRate = 44100
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try scStream.addStreamOutput(audioHandler, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await scStream.startCapture()

        stream = scStream
        NSLog("SOUNDSTREAM-HELPER: System audio capture started")
        return true
    } catch {
        NSLog("SOUNDSTREAM-HELPER: Failed to start capture: %@", error.localizedDescription)
        return false
    }
}

// MARK: - Cleanup

func cleanup() {
    if let s = stream {
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await s.stopCapture()
            sem.signal()
        }
        sem.wait(timeout: .now() + 2)
    }
    shm_unlink_bridge(kShmName)
}

signal(SIGTERM) { _ in
    NSLog("SOUNDSTREAM-HELPER: SIGTERM, cleaning up")
    cleanup()
    exit(0)
}

signal(SIGINT) { _ in
    NSLog("SOUNDSTREAM-HELPER: SIGINT, cleaning up")
    cleanup()
    exit(0)
}

// MARK: - Main

NSLog("SOUNDSTREAM-HELPER: Starting (system audio mode)...")

let preflight = CGPreflightScreenCaptureAccess()
NSLog("SOUNDSTREAM-HELPER: Screen capture preflight=%d", preflight ? 1 : 0)
if !preflight {
    NSLog("SOUNDSTREAM-HELPER: Requesting screen capture permission...")
    let _ = CGRequestScreenCaptureAccess()
    NSLog("SOUNDSTREAM-HELPER: Will try ScreenCaptureKit anyway...")
}

guard setupSharedMemory() else { exit(1) }

let sem = DispatchSemaphore(value: 0)
Task {
    var ok = false
    for attempt in 1...5 {
        NSLog("SOUNDSTREAM-HELPER: Capture attempt %d/5", attempt)
        ok = await startSystemAudioCapture()
        if ok { break }
        NSLog("SOUNDSTREAM-HELPER: Attempt %d failed, waiting 3s...", attempt)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }
    if !ok {
        NSLog("SOUNDSTREAM-HELPER: All attempts failed. Please grant screen capture permission in System Settings > Privacy & Security > Screen & System Audio Recording for SoundStream2Helper, then relaunch.")
        exit(1)
    }
    sem.signal()
}
sem.wait()

NSLog("SOUNDSTREAM-HELPER: Running... (Ctrl+C to stop)")
RunLoop.current.run()
