import AVFoundation

/// Rolling window of the most recent mono samples, written from the audio thread and read by
/// the HUD's animation loop. Lock-protected; both sides hold it for microseconds.
final class WaveformBuffer: @unchecked Sendable {
    private let capacity = 8192
    private var ring: [Float]
    private var head = 0  // next write index
    private let lock = NSLock()
    private(set) var sampleRate: Double = 48_000

    init() { ring = [Float](repeating: 0, count: capacity) }

    func reset() {
        lock.withLock {
            for i in ring.indices { ring[i] = 0 }
            head = 0
        }
    }

    /// First channel only; that's plenty for a visualization.
    func push(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        push(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)), sampleRate: buffer.format.sampleRate)
    }

    func push(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        lock.withLock {
            self.sampleRate = sampleRate
            for s in samples {
                ring[head] = s
                head = (head + 1) % capacity
            }
        }
    }

    /// The newest `count` samples, oldest first.
    func latest(_ count: Int) -> [Float] {
        let n = min(count, capacity)
        return lock.withLock {
            var out = [Float](repeating: 0, count: n)
            var idx = (head - n + capacity) % capacity
            for i in 0..<n {
                out[i] = ring[idx]
                idx = (idx + 1) % capacity
            }
            return out
        }
    }

    // MARK: Preview signal

    private var previewPhase = 0.0
    private var previewClock = 0.0

    /// Speech-like synthetic audio (harmonics under a syllable-rate envelope) so the style
    /// preview in Settings has something to draw. Call once per UI frame.
    func pushSynthetic(seconds: Double, sampleRate: Double = 48_000) {
        let n = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = previewClock + Double(i) / sampleRate
            let syllable = max(0, sin(2 * .pi * 2.6 * t)) * (0.55 + 0.45 * sin(2 * .pi * 0.7 * t))
            let f0 = 130 + 35 * sin(2 * .pi * 0.9 * t)
            previewPhase += 2 * .pi * f0 / sampleRate
            var v = 0.0
            for h in 1...8 { v += sin(Double(h) * previewPhase) / Double(h) }
            let noise = Double.random(in: -1...1) * 0.02
            samples[i] = Float(v * 0.22 * syllable + noise)
        }
        previewClock += seconds
        samples.withUnsafeBufferPointer { push($0, sampleRate: sampleRate) }
    }
}
