import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let prefs = Preferences()
    lazy var events = EventController(prefs: prefs)
    var statusItem: NSStatusItem!
    var statusLine: NSMenuItem!
    var toggleItem: NSMenuItem!
    var settingsWindow: NSWindow?
    var testWindow: TestWindow?
    var launchObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.up.and.down.circle", accessibilityDescription: "AnchorScroll 中键滚动")
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "AnchorScroll", action: nil, keyEquivalent: "")
        menu.addItem(statusLine); menu.addItem(.separator())
        toggleItem = item("暂停中键滚动", #selector(toggle))
        menu.addItem(toggleItem)
        menu.addItem(item("设置…", #selector(settings)))
        menu.addItem(item("权限检查／重试", #selector(retry)))
        menu.addItem(item("打开辅助功能设置", #selector(accessibility)))
        menu.addItem(item("滚动测试窗口", #selector(test)))
        menu.addItem(.separator())
        menu.addItem(item("退出 AnchorScroll", #selector(quit)))
        statusItem.menu = menu
        events.statusChanged = { [weak self] _ in self?.refreshMenu() }
        prefs.changed = { [weak self] in self?.events.configurationChanged(); self?.refreshMenu() }
        events.start(prompt: true); refreshMenu()
        if CommandLine.arguments.contains("--integration-test") {
            test()
            testWindow?.runIntegration(events: events)
        } else if !AXIsProcessTrusted() || !prefs.defaults.bool(forKey: "welcomeShown") {
            prefs.defaults.set(true, forKey: "welcomeShown")
            settings()
        }
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: ""); i.target = self; return i
    }
    func refreshMenu() {
        statusLine?.title = "AnchorScroll · \(prefs.enabled ? events.status : "已暂停")"
        toggleItem?.title = prefs.enabled ? "暂停中键滚动" : "启用中键滚动"
        statusItem.button?.appearsDisabled = !prefs.enabled
    }
    @objc func toggle() { prefs.enabled.toggle() }
    @objc func retry() { events.start(prompt: true) }
    @objc func accessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func settings() {
        events.cancel()
        if settingsWindow == nil {
            let view = SettingsView(prefs: prefs, retry: { [weak self] in self?.retry() },
                                    diagnostics: { [weak self] in self?.test() })
            let host = NSHostingView(rootView: view)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 660),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "AnchorScroll 设置"; w.contentView = host
            w.isReleasedWhenClosed = false; w.center(); settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func test() {
        events.cancel()
        if testWindow == nil { testWindow = TestWindow() }
        NSApp.activate(ignoringOtherApps: true); testWindow?.window.makeKeyAndOrderFront(nil)
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { events.shutdown() }
}

@main
struct AnchorScrollMain {
    static func main() {
        if CommandLine.arguments.contains("--permission-check") {
            print("{\"accessibility\":\(AXIsProcessTrusted())}")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
