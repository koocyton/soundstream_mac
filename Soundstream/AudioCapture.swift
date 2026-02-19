import Foundation

struct AudioState {
    static let spectrumBands = 16

    var level: Float = 0
    var peak: Float = 0
    var smoothLevel: Float = 0
    var spectrum: [Float] = Array(repeating: 0, count: spectrumBands)
    var active: Bool = false
}

import AppKit

final class AudioCapture {
    private var shmPtr: UnsafeMutablePointer<SharedAudioData>?
    private var helperPID: pid_t = 0

    var state: AudioState {
        if shmPtr == nil { tryOpenSharedMemory() }
        guard let shm = shmPtr else { return AudioState() }

        let data = shm.pointee
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let age = Double(mach_absolute_time() - data.timestamp) * Double(info.numer) / Double(info.denom) / 1_000_000_000
        if data.active == 0 || age > 2.0 {
            return AudioState()
        }
        return data.toAudioState()
    }

    func start() {
        launchHelper()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.tryOpenSharedMemory()
        }
    }

    func stop() {
        if helperPID > 0 {
            kill(helperPID, SIGTERM)
            helperPID = 0
        }
        if let ptr = shmPtr {
            munmap(ptr, kSharedMemorySize)
            shmPtr = nil
        }
    }

    private func tryOpenSharedMemory() {
        guard shmPtr == nil else { return }
        let fd = shm_open_bridge(kSharedMemoryName, O_RDONLY, 0)
        guard fd >= 0 else { return }
        let ptr = mmap(nil, kSharedMemorySize, PROT_READ, MAP_SHARED, fd, 0)
        close(fd)
        if ptr != MAP_FAILED {
            shmPtr = ptr!.assumingMemoryBound(to: SharedAudioData.self)
            NSLog("SOUNDSTREAM: Shared memory connected")
        }
    }

    private func launchHelper() {
        let bundle = Bundle(for: SoundstreamView.self)
        let helperAppName = "SoundStream2Helper.app"

        var appPath: String?
        for candidate in [
            bundle.bundlePath + "/Contents/Resources/" + helperAppName,
            bundle.bundlePath + "/Contents/MacOS/" + helperAppName,
        ] {
            if FileManager.default.fileExists(atPath: candidate) {
                appPath = candidate
                break
            }
        }

        guard let path = appPath else {
            NSLog("SOUNDSTREAM: Helper app not found in bundle: %@", bundle.bundlePath)
            return
        }

        NSLog("SOUNDSTREAM: Launching helper app: %@", path)
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, error in
            if let error = error {
                NSLog("SOUNDSTREAM: Failed to launch helper app: %@", error.localizedDescription)
            } else if let app = app {
                self.helperPID = app.processIdentifier
                NSLog("SOUNDSTREAM: Helper app launched, pid=%d", app.processIdentifier)
            }
        }
    }
}
