import AVFoundation

/// Records the microphone (the "Me" track) with AVAudioEngine, voice processing off.
final class MicCapture {
    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var folder: URL?
    private var segment = 0
    private var configObserver: NSObjectProtocol?

    var onBuffer: ((Float, UInt64) -> Void)?
    var onEvent: ((String) -> Void)?
    private(set) var firstHostTime: UInt64?
    private(set) var formatDescription = "?"

    func start(folder: URL?) throws {
        self.folder = folder
        try startEngine()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.onEvent?("Mic configuration changed. Restarting the mic into a new file segment.")
            self?.restartEngine()
        }
    }

    func stop() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        formatDescription = "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch"
        if let folder {
            let name = segment == 0 ? "mic.caf" : "mic-\(segment).caf"
            file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let self else { return }
            if self.firstHostTime == nil { self.firstHostTime = time.hostTime }
            try? self.file?.write(from: buffer)
            self.onBuffer?(rmsLevel(buffer), time.hostTime)
        }
        engine.prepare()
        try engine.start()
    }

    private func restartEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        segment += 1
        do {
            try startEngine()
        } catch {
            onEvent?("Mic restart failed: \(error)")
        }
    }
}
