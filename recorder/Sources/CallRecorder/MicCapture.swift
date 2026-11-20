import AVFoundation

/// Records the microphone (you). Echo cancellation stops the other side's voice from the
/// speakers leaking into your track, like Granola's getUserMedia({echoCancellation: true}).
final class MicCapture {
    private var engine: AVAudioEngine?
    private var writer: TrackWriter?
    private var observer: NSObjectProtocol?
    private var voiceProcessing = false

    /// Returns whether echo cancellation actually ended up on.
    @discardableResult
    func start(writingTo url: URL, echoCancellation: Bool) throws -> Bool {
        writer = TrackWriter(file: try makeWavFile(at: url, sampleRate: 48_000, channels: 1))
        if echoCancellation {
            do {
                try startEngine(voiceProcessing: true)
                return true
            } catch {
                stopEngine()
                NSLog("Echo cancellation failed, recording without it: \(error)")
            }
        }
        try startEngine(voiceProcessing: false)
        return false
    }

    func stop() {
        stopEngine()
        writer = nil
    }

    private func startEngine(voiceProcessing: Bool) throws {
        guard let writer else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            // Keep the call audio at full volume while voice processing runs.
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            // Voice processing needs the output side of the graph running too.
            engine.mainMixerNode.outputVolume = 0
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError(message: "No microphone found")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            writer.write(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.voiceProcessing = voiceProcessing
        // The engine stops itself when the input device changes (AirPods connect or switch
        // to call mode). Rebuild it on the new device and keep writing to the same file.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartEngine()
        }
    }

    private func restartEngine() {
        guard engine != nil else { return }
        let wanted = voiceProcessing
        stopEngine()
        do {
            try startEngine(voiceProcessing: wanted)
        } catch {
            stopEngine()
            NSLog("Mic restart failed: \(error)")
            if wanted {
                try? startEngine(voiceProcessing: false)
            }
        }
    }

    private func stopEngine() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
    }
}
