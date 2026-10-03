import SwiftUI

/// 设置窗口显示的状态快照和操作。逻辑在 AppDelegate，状态变化时由它写入
final class SettingsModel: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let name: String
        let connected: Bool
    }

    @Published var stateTitle = "就绪"
    @Published var sidecarDevices: [Device] = []
    @Published var autoConnect = true
    @Published var uuConnected = false
    @Published var remoteActive = false
    @Published var busy = false
    @Published var controllers: [String: String] = [:] // 当前连入的设备 ID → 名称
    @Published var autoDevices: [String: String] = [:] // 记住的设备 ID → 名称
    @Published var launchAtLogin = false
    @Published var details: [String: String] = [:] // 设备 ID → 「系统 · 设备 ID」

    var setAutoConnect: (Bool) -> Void = { _ in }
    var toggleRemote: () -> Void = {}
    var setAutoDevice: (String, Bool) -> Void = { _, _ in }
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
}

private enum Pane: String, CaseIterable, Identifiable {
    case sidecar = "随航", remote = "UU 远程", general = "通用"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .sidecar: "ipad.landscape"
        case .remote: "rectangle.inset.filled"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var pane: Pane? = .sidecar

    var body: some View {
        // 不用 NavigationSplitView：放在 AppKit 窗口里时，侧栏和标题栏的分隔线会错位
        HStack(spacing: 0) {
            List(Pane.allCases, selection: $pane) { pane in
                Label(pane.rawValue, systemImage: pane.symbol)
            }
            .listStyle(.sidebar)
            .safeAreaPadding(.top, 40) // 让出红绿灯按钮
            .frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(pane?.rawValue ?? "")
                    .font(.title2.bold())
                    .padding(.horizontal, 30)
                    .padding(.top, 40)
                Form {
                    switch pane ?? .sidecar {
                    case .sidecar: sidecar
                    case .remote: remote
                    case .general: general
                    }
                }
                .formStyle(.grouped)
            }
        }
        .ignoresSafeArea()
        .frame(minWidth: 620, minHeight: 420)
    }

    @ViewBuilder private var sidecar: some View {
        Section("附近的 iPad") {
            if model.sidecarDevices.isEmpty {
                Text("未发现").foregroundStyle(.secondary)
            }
            ForEach(model.sidecarDevices) { device in
                LabeledContent(device.name) {
                    Text(device.connected ? "已连接" : "未连接").foregroundStyle(device.connected ? .green : .secondary)
                }
            }
        }
        Section {
            Toggle("没有显示器时自动连接", isOn: binding(\.autoConnect, model.setAutoConnect))
        }
    }

    @ViewBuilder private var remote: some View {
        Section("状态") {
            LabeledContent("UU 远程", value: model.uuConnected ? "已连接" : "未连接")
            LabeledContent("iPad 单屏", value: model.remoteActive ? "已开启" : "未开启")
            HStack {
                Spacer()
                Button(model.remoteActive ? "恢复物理显示器" : "切换到 iPad 单屏", action: model.toggleRemote)
                    .disabled(model.busy || !(model.uuConnected || model.remoteActive))
            }
        }
        Section("连入时自动切换") {
            if model.controllers.isEmpty {
                Text("当前没有连入的设备").foregroundStyle(.secondary)
            }
            ForEach(model.controllers.sorted { $0.value < $1.value }, id: \.key) { id, name in
                Toggle(isOn: Binding(get: { model.autoDevices[id] != nil }, set: { model.setAutoDevice(id, $0) })) {
                    deviceLabel(id, name)
                }
            }
        }
        Section("已记住的设备") {
            if model.autoDevices.isEmpty {
                Text("无").foregroundStyle(.secondary)
            }
            ForEach(model.autoDevices.sorted { $0.value < $1.value }, id: \.key) { id, name in
                HStack {
                    deviceLabel(id, name)
                    Spacer()
                    Button("忘记") { model.setAutoDevice(id, false) }
                }
            }
        }
    }

    @ViewBuilder private var general: some View {
        Section {
            Toggle("登录时启动", isOn: binding(\.launchAtLogin, model.setLaunchAtLogin))
        }
        Section {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        }
    }

    private func deviceLabel(_ id: String, _ name: String) -> some View {
        VStack(alignment: .leading) {
            Text(name)
            if let detail = model.details[id] { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func binding(_ key: KeyPath<SettingsModel, Bool>, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model[keyPath: key] }, set: set)
    }
}
