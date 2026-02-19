import Foundation

let kSharedMemoryName = "/soundstream2_audio"
let kSharedMemorySize = MemoryLayout<SharedAudioData>.size

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

    func toAudioState() -> AudioState {
        var state = AudioState()
        state.level = level
        state.peak = peak
        state.smoothLevel = smoothLevel
        state.active = active != 0
        for i in 0..<AudioState.spectrumBands {
            state.spectrum[i] = spectrumValue(at: i)
        }
        return state
    }
}
