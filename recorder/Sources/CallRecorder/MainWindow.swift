import SwiftUI

private let brandBlue = Color(red: 0x11 / 255, green: 0x50 / 255, blue: 0xF4 / 255)
private let paleBlue = Color(red: 0xEE / 255, green: 0xF2 / 255, blue: 0xFE / 255)

/// The app window: big record button, timer, recent calls, settings.
struct MainView: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            recentCalls
            Divider()
            settings
        }
        .frame(width: 380, height: 580)
        .background(Color.white)
    }

    private var header: some View {
        VStack(spacing: 14) {
            RecordButton(isRecording: recorder.isRecording, action: recorder.toggle)
                .padding(.top, 28)
            HStack(spacing: 8) {
                if recorder.isRecording {
                    PulsingDot()
                }
                Text(recorder.isRecording ? formatDuration(recorder.elapsed) : "Ready to record")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.black)
            }
            Text(recorder.isRecording ? "Recording you and the other side" : "Click the button or press ⌃⌥⌘R anywhere")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var recentCalls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent calls")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 6)
            if recorder.recentCalls.isEmpty {
                Text("No calls yet")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(recorder.recentCalls) { call in
                            CallRow(call: call, stage: recorder.stages[call.folder], recorder: recorder)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingRow("Echo cancellation (no headphones)", isOn: $recorder.echoCancellation)
            settingRow("Open at login", isOn: Binding(
                get: { recorder.opensAtLogin },
                set: { recorder.setOpensAtLogin($0) }
            ))
            Button("Open recordings folder", action: recorder.openRecordingsFolder)
                .buttonStyle(.link)
                .foregroundStyle(brandBlue)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(brandBlue)
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func settingRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.black)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
        }
    }
}

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(paleBlue)
                    .frame(width: 132, height: 132)
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(red: 0.15, green: 0.45, blue: 1), brandBlue],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 100, height: 100)
                    .shadow(color: brandBlue.opacity(0.35), radius: hovering ? 14 : 8, y: 4)
                if isRecording {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white)
                        .frame(width: 32, height: 32)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 34, height: 34)
                }
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isRecording ? "Stop recording" : "Start recording")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 10, height: 10)
            .opacity(on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(), value: on)
            .onAppear { on = true }
    }
}

private struct CallRow: View {
    let call: RecordedCall
    let stage: String?
    let recorder: Recorder
    @State private var hovering = false

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        Button { recorder.open(call) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.formatter.string(from: call.startedAt))
                        .foregroundStyle(.black)
                    status
                        .font(.system(size: 11))
                }
                Spacer()
                Text(formatDuration(call.durationSeconds))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Image(systemName: call.hasSummary ? "doc.text" : "folder")
                    .foregroundStyle(brandBlue)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? paleBlue : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(call.hasSummary ? "Open the summary. Right-click for more." : "Open this call's folder. Right-click for more.")
        .contextMenu {
            Button("Open summary") { recorder.open(call) }
                .disabled(!call.hasSummary)
            Button("Open transcript") { recorder.openTranscript(call) }
                .disabled(!call.hasTranscript)
            Button("Show in Finder") { recorder.showInFinder(call) }
            Divider()
            Button(call.hasSummary ? "Transcribe and summarize again" : "Transcribe and summarize") {
                recorder.process(call.folder)
            }
            .disabled(stage != nil)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch stage {
        case "queued":
            Text("Waiting to transcribe…").foregroundStyle(.secondary)
        case "transcribing":
            Text("Transcribing…").foregroundStyle(brandBlue)
        case "summarizing":
            Text("Writing summary…").foregroundStyle(brandBlue)
        default:
            if call.error != nil {
                Text("Failed - right-click to retry").foregroundStyle(.red)
            } else if call.hasSummary {
                Text("Transcript and summary ready").foregroundStyle(.secondary)
            } else {
                Text("Not transcribed").foregroundStyle(.secondary)
            }
        }
    }
}
