import AppKit
import ServiceManagement

/// A finished call folder, shown in the window's list.
struct RecordedCall: Identifiable {
    let folder: URL
    let startedAt: Date
    let durationSeconds: Int
    let hasTranscript: Bool
    let hasSummary: Bool
    let error: String?

    var id: URL { folder }
    var summaryURL: URL { folder.appendingPathComponent("summary.md") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.txt") }

    init?(folder: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        guard let startedAt = formatter.date(from: folder.lastPathComponent),
              let data = try? Data(contentsOf: folder.appendingPathComponent("call.json")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        self.folder = folder
        self.startedAt = startedAt
        durationSeconds = info["duration_seconds"] as? Int ?? 0
        let files = FileManager.default
        hasTranscript = files.fileExists(atPath: folder.appendingPathComponent("transcript.txt").path)
        hasSummary = files.fileExists(atPath: folder.appendingPathComponent("summary.md").path)
        error = try? String(contentsOf: folder.appendingPathComponent("error.txt"), encoding: .utf8)
    }
}

/// Recording state shared by the window, the menu bar item, the Dock icon and the hotkey.
@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var session: CallSession?
    @Published private(set) var elapsed = 0
    @Published private(set) var recentCalls: [RecordedCall] = []
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// Calls being transcribed or summarized: folder -> "queued", "transcribing" or "summarizing".
    @Published private(set) var stages: [URL: String] = [:]
    @Published var echoCancellation: Bool {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: "echoCancellation") }
    }

    /// Called on every state change so AppKit parts (menu bar, Dock badge) can redraw.
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var processQueue: [URL] = []
    private var processingFolder: URL?

    var isRecording: Bool { session != nil }

    init() {
        echoCancellation = UserDefaults.standard.object(forKey: "echoCancellation") as? Bool ?? true
        reloadRecentCalls()
        // Finish calls that were never processed, e.g. the app quit while transcribing.
        for call in recentCalls where !call.hasSummary && call.error == nil {
            process(call.folder)
        }
    }

    func toggle() {
        if let session {
            session.stop()
            self.session = nil
            timer?.invalidate()
            timer = nil
            NSSound(named: "Pop")?.play()
            reloadRecentCalls()
            process(session.folder)
        } else {
            do {
                let session = try CallSession()
                try session.start(echoCancellation: echoCancellation)
                self.session = session
                elapsed = 0
                NSSound(named: "Tink")?.play()
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            } catch {
                showError(error)
            }
        }
        onChange?()
    }

    /// Saves a running call when the app quits.
    func finishRecording() {
        session?.stop()
        session = nil
    }

    /// Open at login is on unless Ugur switched it off. Registering again on every launch
    /// keeps the login item pointing at the current app location.
    func applyOpenAtLogin() {
        let wanted = UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true
        setOpensAtLogin(wanted)
    }

    func setOpensAtLogin(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: "openAtLogin")
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else if service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("Login item change failed: \(error)")
        }
        opensAtLogin = service.status == .enabled
        onChange?()
    }

    func reloadRecentCalls() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: CallSession.recordingsRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        recentCalls = Array(folders.compactMap(RecordedCall.init).sorted { $0.startedAt > $1.startedAt }.prefix(30))
    }

    /// Opens the summary when it exists, otherwise the call folder.
    func open(_ call: RecordedCall) {
        NSWorkspace.shared.open(call.hasSummary ? call.summaryURL : call.folder)
    }

    func openTranscript(_ call: RecordedCall) {
        NSWorkspace.shared.open(call.hasTranscript ? call.transcriptURL : call.folder)
    }

    func showInFinder(_ call: RecordedCall) {
        NSWorkspace.shared.activateFileViewerSelecting([call.folder])
    }

    /// Queues transcript + summary for a call. Runs one call at a time in the background.
    func process(_ folder: URL) {
        guard stages[folder] == nil else { return }
        stages[folder] = "queued"
        processQueue.append(folder)
        processNext()
    }

    private func processNext() {
        guard processingFolder == nil, !processQueue.isEmpty else { return }
        let folder = processQueue.removeFirst()
        guard let script = Bundle.main.url(forResource: "process_call", withExtension: "py") else {
            stages[folder] = nil
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, folder.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(separator: "\n") where line.hasPrefix("STAGE ") {
                let stage = String(line.dropFirst("STAGE ".count))
                Task { @MainActor in self?.setStage(stage, for: folder) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in self?.finishProcessing(folder) }
        }
        do {
            try process.run()
            processingFolder = folder
            stages[folder] = "transcribing"
        } catch {
            try? "Could not start processing: \(error)".write(
                to: folder.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8
            )
            stages[folder] = nil
            reloadRecentCalls()
            processNext()
        }
    }

    private func setStage(_ stage: String, for folder: URL) {
        guard processingFolder == folder, stage == "transcribing" || stage == "summarizing" else { return }
        stages[folder] = stage
    }

    private func finishProcessing(_ folder: URL) {
        processingFolder = nil
        stages[folder] = nil
        reloadRecentCalls()
        NSSound(named: "Glass")?.play()
        processNext()
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: CallSession.recordingsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CallSession.recordingsRoot)
    }

    private func tick() {
        guard let session else { return }
        elapsed = Int(Date().timeIntervalSince(session.startedAt))
        onChange?()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Recording did not start"
        alert.informativeText = "\(error.localizedDescription)\n\nCheck System Settings > Privacy & Security > Microphone and System Audio Recording."
        alert.runModal()
    }
}

func formatDuration(_ seconds: Int) -> String {
    seconds >= 3600
        ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        : String(format: "%d:%02d", seconds / 60, seconds % 60)
}
