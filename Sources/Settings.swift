import AppKit
import SwiftUI
import ServiceManagement

final class Preferences: ObservableObject {
    let defaults: UserDefaults
    var changed: (() -> Void)?
    @Published var enabled: Bool { didSet { save() } }
    @Published var sensitivity: Double { didSet { save() } }
    @Published var maxSpeed: Double { didSet { save() } }
    @Published var reverseVertical: Bool { didSet { save() } }
    @Published var horizontal: Bool { didSet { save() } }
    @Published var excluded: [String] { didSet { save() } }
    @Published var lineApps: [String] { didSet { save() } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["enabled": true, "sensitivity": 1.0,
                                    "maxSpeed": 1800.0, "horizontal": false, "reverseVertical": false])
        enabled = defaults.bool(forKey: "enabled")
        let s = defaults.double(forKey: "sensitivity")
        sensitivity = s.isFinite ? min(max(s, 0.25), 3) : 1
        let v = defaults.double(forKey: "maxSpeed")
        maxSpeed = v.isFinite ? min(max(v, 300), 4000) : 1800
        horizontal = defaults.bool(forKey: "horizontal")
        reverseVertical = defaults.bool(forKey: "reverseVertical")
        excluded = defaults.stringArray(forKey: "excluded") ?? []
        lineApps = defaults.stringArray(forKey: "lineApps") ?? []
    }

    var tuning: ScrollTuning {
        var t = ScrollTuning()
        t.sensitivity = sensitivity; t.maxSpeed = maxSpeed; t.horizontal = horizontal
        return t
    }

    func save() {
        defaults.set(enabled, forKey: "enabled")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(maxSpeed, forKey: "maxSpeed")
        defaults.set(horizontal, forKey: "horizontal")
        defaults.set(reverseVertical, forKey: "reverseVertical")
        defaults.set(excluded, forKey: "excluded")
        defaults.set(lineApps, forKey: "lineApps")
        changed?()
    }

    func restore() {
        sensitivity = 1; maxSpeed = 1800; horizontal = false
        excluded = []; lineApps = []
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    let retry: () -> Void
    let diagnostics: () -> Void
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AnchorScroll · 中键滚动").font(.title2.bold())
            Text("点按中键 → 移开后持续滚动 → 回中心停住\n点击或 Esc 退出；Option＋中键保留原有功能。")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("启用中键自动滚动", isOn: $prefs.enabled)
            VStack(alignment: .leading) {
                Text(String(format: "灵敏度  %.2f×", prefs.sensitivity))
                Slider(value: $prefs.sensitivity, in: 0.25...3, step: 0.05)
                Text("越低越适合精细阅读；中心 6 点以内始终停止。")
                    .font(.caption).foregroundColor(.secondary)
            }
            VStack(alignment: .leading) {
                Text("最高速度  \(Int(prefs.maxSpeed)) 像素／秒")
                Slider(value: $prefs.maxSpeed, in: 300...4000, step: 100)
            }
            Toggle("反转中键上下方向", isOn: $prefs.reverseVertical)
            Toggle("同时允许左右滚动", isOn: $prefs.horizontal)
            Toggle("登录时启动", isOn: $login).onChange(of: login) { _, value in
                do {
                    if value { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    message = SMAppService.mainApp.status == .requiresApproval
                        ? "请在系统设置的登录项中允许 AnchorScroll。" : "登录项设置已更新。"
                } catch { message = "登录项设置失败：\(error.localizedDescription)" }
                login = SMAppService.mainApp.status == .enabled
            }
            Divider()
            appList("不接管这些应用的中键", ids: $prefs.excluded)
            appList("使用普通滚轮模式的应用", ids: $prefs.lineApps)
            Text("普通滚轮模式适用于不接受连续像素滚动的应用，低速会按行输出。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("权限检查／重试", action: retry)
                Button("滚动测试窗口", action: diagnostics)
                Spacer()
                Button("恢复默认手感") { prefs.restore() }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundColor(.secondary) }
        }.padding(24).frame(width: 560)
    }

    func appList(_ title: String, ids: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("添加应用…") {
                    let picker = NSOpenPanel()
                    picker.directoryURL = URL(fileURLWithPath: "/Applications")
                    picker.canChooseDirectories = false; picker.canChooseFiles = true
                    picker.allowedContentTypes = [.applicationBundle]
                    if picker.runModal() == .OK, let url = picker.url,
                       let id = Bundle(url: url)?.bundleIdentifier, !ids.wrappedValue.contains(id) {
                        ids.wrappedValue.append(id)
                    }
                }
            }
            if ids.wrappedValue.isEmpty { Text("尚未添加").font(.caption).foregroundColor(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ids.wrappedValue, id: \.self) { id in
                        HStack {
                            Text(appName(id)).lineLimit(1)
                            Spacer()
                            Button("移除") { ids.wrappedValue.removeAll { $0 == id } }
                        }
                    }
                }
            }.frame(height: ids.wrappedValue.isEmpty ? 0 : min(90, CGFloat(ids.wrappedValue.count * 28)))
        }
    }

    func appName(_ id: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return id }
        return url.deletingPathExtension().lastPathComponent
    }
}
