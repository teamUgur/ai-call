import Foundation

/// One recorded call: a folder with me.wav (mic), them.wav (Mac output) and call.json.
final class CallSession {
    static var recordingsRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "recordingsRoot") {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/ugur-ai/ugur-studio/4-personal/calls", isDirectory: true)
    }

    let folder: URL
    let startedAt = Date()
    private let mic = MicCapture()
    private let system = SystemAudioTap()
    private var echoCancellation = false

    init() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        folder = Self.recordingsRoot.appendingPathComponent(formatter.string(from: startedAt), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func start(echoCancellation wantEchoCancellation: Bool) throws {
        do {
            try system.start(writingTo: folder.appendingPathComponent("them.wav"))
            echoCancellation = try mic.start(writingTo: folder.appendingPathComponent("me.wav"), echoCancellation: wantEchoCancellation)
        } catch {
            stopCapture()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func stop() {
        stopCapture()
        let endedAt = Date()
        let iso = ISO8601DateFormatter()
        let info: [String: Any] = [
            "started_at": iso.string(from: startedAt),
            "ended_at": iso.string(from: endedAt),
            "duration_seconds": Int(endedAt.timeIntervalSince(startedAt)),
            "echo_cancellation": echoCancellation,
            "tracks": ["me": "me.wav", "them": "them.wav"],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("call.json"))
        }
    }

    private func stopCapture() {
        mic.stop()
        system.stop()
    }
}
