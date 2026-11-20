import AppKit
import AVFoundation
import Carbon
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let recorder = Recorder()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggleItem = NSMenuItem(title: "Start recording", action: #selector(toggleRecording), keyEquivalent: "r")
    private let echoItem = NSMenuItem(title: "Echo cancellation (no headphones)", action: #selector(toggleEchoCancellation), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
    private var hotKey: HotKey?

    private lazy var window: NSWindow = {
        let window = NSWindow(contentViewController: NSHostingController(rootView: MainView(recorder: recorder)))
        window.title = "Call Recorder"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        // The window is designed white; keep it light in dark mode too.
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        return window
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchedAtLogin = Self.launchedAsLoginItem()
        recorder.applyOpenAtLogin()
        recorder.onChange = { [weak self] in self?.updateStatus() }
        buildMenu()
        updateStatus()
        // Control + Option + Command + R
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | cmdKey) { [weak self] in
            MainActor.assumeIsolated { self?.recorder.toggle() }
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        // At login the app starts quietly in the Dock; opened by hand it shows the window.
        if !launchedAtLogin {
            showWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.finishRecording()
    }

    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication
        else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let menu = NSMenu()
        toggleItem.keyEquivalentModifierMask = [.control, .option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(item("Show window", #selector(showWindow)))
        menu.addItem(.separator())

        echoItem.target = self
        menu.addItem(echoItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(item("Open last recording", #selector(openLastRecording)))
        menu.addItem(item("Open recordings folder", #selector(openRecordingsFolder)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Call Recorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleRecording() {
        recorder.toggle()
    }

    @objc private func toggleEchoCancellation() {
        recorder.echoCancellation.toggle()
        updateStatus()
    }

    @objc private func toggleOpenAtLogin() {
        recorder.setOpensAtLogin(!recorder.opensAtLogin)
    }

    @objc private func openLastRecording() {
        if let call = recorder.recentCalls.first {
            recorder.open(call)
        } else {
            recorder.openRecordingsFolder()
        }
    }

    @objc private func openRecordingsFolder() {
        recorder.openRecordingsFolder()
    }

    private func updateStatus() {
        echoItem.state = recorder.echoCancellation ? .on : .off
        loginItem.state = recorder.opensAtLogin ? .on : .off
        guard let button = statusItem.button else { return }
        if recorder.isRecording {
            let time = formatDuration(recorder.elapsed)
            button.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
            button.contentTintColor = .systemRed
            button.title = " " + time
            toggleItem.title = "Stop recording"
            NSApp.dockTile.badgeLabel = time
        } else {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Call Recorder")
            button.contentTintColor = nil
            button.title = ""
            toggleItem.title = "Start recording"
            NSApp.dockTile.badgeLabel = nil
        }
    }
}
