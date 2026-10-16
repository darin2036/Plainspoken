import Accelerate
import SwiftUI

/// Debug counter: how many times a visualizer canvas has drawn. `--preview-hud` prints its rate.
nonisolated(unsafe) var visualizerFrames = 0

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case oscilloscope, fire
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oscilloscope: return "Oscilloscope"
        case .fire: return "Fire"
        }
    }
}

struct VisualizerView: View {
    let style: VisualizerStyle
    let waveform: WaveformBuffer

    var body: some View {
        switch style {
        case .oscilloscope: OscilloscopeView(waveform: waveform)
        case .fire: FireView(waveform: waveform)
        }
    }
}

// MARK: - Oscilloscope

/// Phosphor-green scope trace with a rising-edge trigger, so voiced sounds hold still
/// instead of scrolling like a raw waveform.
struct OscilloscopeView: View {
    let waveform: WaveformBuffer
    private let phosphor = Color(red: 0.25, green: 1.0, blue: 0.55)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { ctx, size in
                // Reading the timeline date makes this closure differ every tick; without it
                // SwiftUI sees an unchanged Canvas and never redraws it.
                _ = timeline.date
                visualizerFrames += 1
                // Graticule
                var grid = Path()
                for i in 1..<4 {
                    let y = size.height * CGFloat(i) / 4
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                for i in 1..<8 {
                    let x = size.width * CGFloat(i) / 8
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                ctx.stroke(grid, with: .color(phosphor.opacity(0.10)), lineWidth: 0.5)

                let window = 1024
                let samples = waveform.latest(window * 2)
                var start = 0
                for i in 0..<window where samples[i] <= 0 && samples[i + 1] > 0 {
                    start = i
                    break
                }

                let points = max(24, Int(size.width / 2))
                let mid = size.height / 2
                var trace = Path()
                for p in 0..<points {
                    let s = samples[start + p * window / points]
                    // Soft clip: quiet speech still moves the trace, shouting doesn't leave the box.
                    let y = mid - CGFloat(tanh(Double(s) * 5)) * mid * 0.92
                    let pt = CGPoint(x: CGFloat(p) * size.width / CGFloat(points - 1), y: y)
                    if p == 0 { trace.move(to: pt) } else { trace.addLine(to: pt) }
                }
                ctx.stroke(trace, with: .color(phosphor.opacity(0.22)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                ctx.stroke(trace, with: .color(phosphor), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Fire

/// Classic demoscene fire: a low-res heat grid cooled and smoothed upward each frame, with
/// the bottom row fuelled by the voice's spectrum (the way Winamp's fire reacted to music).
final class FireSimulation {
    static let width = 48
    static let height = 12
    private let w = FireSimulation.width
    private let h = FireSimulation.height

    private var heat: [Float]
    private var next: [Float]
    private var levels: [Float]
    private var peakMagnitude: Float = 40

    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private let fft: FFTSetup
    private let window: [Float]
    private let palette: [UInt32]  // premultiplied RGBA, one per heat 0...255

    init() {
        heat = [Float](repeating: 0, count: FireSimulation.width * FireSimulation.height)
        next = heat
        levels = [Float](repeating: 0, count: FireSimulation.width)
        fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        var win = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&win, 1024, Int32(vDSP_HANN_NORM))
        window = win

        palette = (0..<256).map { i in
            let t = Float(i) / 255
            let r = min(1, t * 2.3)
            let g = max(0, min(1, (t - 0.30) * 2.0))
            let b = max(0, min(1, (t - 0.78) * 4.0))
            let a = min(1, t * 2.6)
            func c(_ v: Float) -> UInt32 { UInt32(max(0, min(255, v * a * 255))) }
            return c(r) | (c(g) << 8) | (c(b) << 16) | (UInt32(a * 255) << 24)
        }
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    /// One animation frame. Returns the grid as an image.
    func step(waveform: WaveformBuffer) -> CGImage? {
        updateLevels(from: waveform)

        // Fuel the bottom two rows from the spectrum, plus a faint ember bed so it never looks dead.
        for x in 0..<w {
            let level = levels[x]
            let fuel = min(1, level * 1.15) * 255
            let ember = Float.random(in: 0...1) < 0.18 ? Float.random(in: 20...50) : 0
            let v = max(fuel * Float.random(in: 0.55...1.0), ember)
            heat[(h - 1) * w + x] = max(heat[(h - 1) * w + x] * 0.5, v)
            heat[(h - 2) * w + x] = max(heat[(h - 2) * w + x] * 0.7, v * 0.9)
        }

        // Heat rises: each cell averages the cells beneath it, then cools a little. A few sub-steps
        // per frame make flames climb several rows at once, so a short burst of speech still
        // reaches the top instead of dying a few rows up.
        for _ in 0..<3 {
            for y in 0..<(h - 2) {
                for x in 0..<w {
                    let l = heat[(y + 1) * w + max(0, x - 1)]
                    let c = heat[(y + 1) * w + x]
                    let r = heat[(y + 1) * w + min(w - 1, x + 1)]
                    let b = heat[min(h - 1, y + 2) * w + x]
                    let avg = (l * 0.8 + c * 1.2 + r * 0.8 + b * 1.2) * 0.25  // center-weighted: keeps tongues narrow
                    next[y * w + x] = max(0, avg * 0.972 - Float.random(in: 0.1...1.1))
                }
            }
            for y in 0..<(h - 2) {
                for x in 0..<w { heat[y * w + x] = next[y * w + x] }
            }
        }

        var pixels = [UInt32](repeating: 0, count: w * h)
        for i in 0..<(w * h) { pixels[i] = palette[Int(max(0, min(255, heat[i])))] }
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue  // bytes in memory: R, G, B, A
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Log-spaced spectrum bands (about 100 Hz to 5 kHz, where speech lives) with auto gain.
    private func updateLevels(from waveform: WaveformBuffer) {
        var samples = waveform.latest(fftSize)
        vDSP.multiply(samples, window, result: &samples)

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var mags = [Float](repeating: 0, count: fftSize / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        let binHz = Float(waveform.sampleRate) / Float(fftSize)
        let lo: Float = 100, hi: Float = 5000
        var frameMax: Float = 0
        var raw = [Float](repeating: 0, count: w)
        for x in 0..<w {
            let f0 = lo * pow(hi / lo, Float(x) / Float(w))
            let f1 = lo * pow(hi / lo, Float(x + 1) / Float(w))
            let b0 = max(1, Int(f0 / binHz))
            let b1 = min(fftSize / 2 - 1, max(b0, Int(f1 / binHz)))
            var sum: Float = 0
            for b in b0...b1 { sum = max(sum, mags[b]) }
            raw[x] = sum
            frameMax = max(frameMax, sum)
        }

        // Auto gain with a floor so room noise doesn't get boosted into a bonfire.
        peakMagnitude = max(frameMax, peakMagnitude * 0.992, 12)
        for x in 0..<w {
            // Tilt up the highs a little; speech spectra fall off with frequency.
            let tilt = 1 + 1.6 * Float(x) / Float(w)
            raw[x] = min(1, pow(raw[x] * tilt / peakMagnitude, 0.4))
        }
        // Speech spectra are spiky (harmonics); widen each peak so the fire has bodies, not threads.
        for x in 0..<w {
            var v = raw[x]
            if x >= 1 { v = max(v, raw[x - 1] * 0.8) }
            if x + 1 < w { v = max(v, raw[x + 1] * 0.8) }
            if x >= 2 { v = max(v, raw[x - 2] * 0.55) }
            if x + 2 < w { v = max(v, raw[x + 2] * 0.55) }
            let gated = frameMax < 6 ? 0 : v
            levels[x] += (gated - levels[x]) * (gated > levels[x] ? 0.6 : 0.2)
        }
    }
}

struct FireView: View {
    let waveform: WaveformBuffer
    @State private var sim = FireSimulation()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date  // see OscilloscopeView: forces a redraw each tick
                visualizerFrames += 1
                guard let image = sim.step(waveform: waveform) else { return }
                ctx.draw(Image(decorative: image, scale: 1).interpolation(.none), in: CGRect(origin: .zero, size: size))
            }
        }
    }
}
