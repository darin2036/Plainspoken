import AVFoundation
import CoreMedia

enum AudioCaptureError: Error, CustomStringConvertible {
    case noInput
    case cannotUse(String)

    var description: String {
        switch self {
        case .noInput: return "No microphone is available"
        case .cannotUse(let name): return "Couldn't use the microphone \"\(name)\""
        }
    }
}

/// Microphone capture from a specific input device. Uses AVCaptureSession rather than
/// AVAudioEngine so the choice of microphone is independent of the system's default input and
/// output: picking the Mac's built-in mic never touches the Bluetooth headphones, which stay in
/// high-quality listening mode instead of dropping to call mode.
///
/// Each start() returns a stream of mono float buffers (device sample rate) that ends after stop().
final class AudioCapture {
    private let controlQueue = DispatchQueue(label: "io.github.darin2036.plainspoken.capture.control")
    private let sampleQueue = DispatchQueue(label: "io.github.darin2036.plainspoken.capture.samples")
    private var session: AVCaptureSession?

    private(set) var isRunning = false
    /// Recent samples for the HUD visualizer.
    let waveform = WaveformBuffer()
    /// Name of the device the current/last session captured from.
    private(set) var deviceName = ""

    /// `deviceUID` nil means the system default input.
    func start(deviceUID: String?) throws -> AsyncStream<AVAudioPCMBuffer> {
        stop()

        guard let device = deviceUID.flatMap({ AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureError.noInput
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch { throw AudioCaptureError.cannotUse(device.localizedName) }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Mono float, non-interleaved: one channel is all speech recognition needs, and it avoids
        // multi-channel mic arrays that the format converter can't always down-mix.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw AudioCaptureError.cannotUse(device.localizedName)
        }
        session.addInput(input)
        session.addOutput(output)

        waveform.reset()
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(bufferingPolicy: .unbounded)
        let tap = SampleTap(continuation: continuation, waveform: waveform)
        output.setSampleBufferDelegate(tap, queue: sampleQueue)

        self.session = session
        self.tap = tap
        deviceName = device.localizedName
        isRunning = true
        controlQueue.async { session.startRunning() }
        return stream
    }

    private var tap: SampleTap?  // the output only holds its delegate weakly

    func stop() {
        guard isRunning, let session, let tap else { return }
        isRunning = false
        self.session = nil
        self.tap = nil
        controlQueue.async { [sampleQueue] in
            session.stopRunning()
            // Finish after the sample queue drains so the last few milliseconds of speech aren't cut off.
            sampleQueue.async { tap.continuation.finish() }
        }
    }
}

private final class SampleTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    let waveform: WaveformBuffer

    init(continuation: AsyncStream<AVAudioPCMBuffer>.Continuation, waveform: WaveformBuffer) {
        self.continuation = continuation
        self.waveform = waveform
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let desc = sampleBuffer.formatDescription,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        waveform.push(buffer)
        continuation.yield(buffer)
    }
}
