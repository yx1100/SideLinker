import SwiftUI

/// 常见 iPad 的横屏像素尺寸。UU 不提供连入设备的屏幕信息，由用户为每台设备选一次
struct ScreenSize: Hashable, Identifiable {
    let name: String
    let width: Int
    let height: Int
    var id: String { "\(width)x\(height)" }
    var text: String { "\(width) × \(height)" }

    static let all = [
        ScreenSize(name: "iPad Pro 13 英寸（M4 及后续机型）", width: 2752, height: 2064),
        ScreenSize(name: "iPad Pro 12.9 英寸 / iPad Air 13 英寸", width: 2732, height: 2048),
        ScreenSize(name: "iPad Pro 11 英寸（M4 及后续机型）", width: 2420, height: 1668),
        ScreenSize(name: "iPad Pro 11 英寸（M2 及更早机型）", width: 2388, height: 1668),
        ScreenSize(name: "iPad Air 11 英寸 / iPad（第 10 代及后续机型）", width: 2360, height: 1640),
        ScreenSize(name: "iPad mini（第 6 代及后续机型）", width: 2266, height: 1488),
    ]
    static let standard = all[0]
    static func from(id: String?) -> ScreenSize { all.first { $0.id == id } ?? standard }
}

/// 设置窗口显示的状态快照和操作。逻辑在 AppDelegate，状态变化时由它写入
final class SettingsModel: ObservableObject {
    struct Device: Identifiable {
        let id: String
        let name: String
        let connected: Bool
    }

    /// 通过 UU 连入过的设备：当前连入的和已记住的
    struct RemoteDevice: Identifiable {
        let id: String
        let name: String
        let detail: String // 「iPadOS · 设备 ID」
        let connected: Bool
        let auto: Bool
        let size: ScreenSize
    }

    @Published var stateTitle = "就绪"
    @Published var sidecarDevices: [Device] = []
    @Published var autoConnect = true
    @Published var uuConnected = false
    @Published var remoteActive = false
    @Published var activeSize: ScreenSize? // 仅使用 iPad 显示时虚拟屏的尺寸
    @Published var busy = false
    @Published var remoteDevices: [RemoteDevice] = []
    @Published var launchAtLogin = false

    var setAutoConnect: (Bool) -> Void = { _ in }
    var toggleRemote: () -> Void = {}
    var setAutoDevice: (String, Bool) -> Void = { _, _ in }
    var setScreenSize: (String, ScreenSize) -> Void = { _, _ in }
    var forgetDevice: (String) -> Void = { _ in }
    var setNickname: (String, String) -> Void = { _, _ in }
    var setLaunchAtLogin: (Bool) -> Void = { _ in }
}

private enum Pane: String, CaseIterable, Identifiable {
    case sidecar = "随航", remote = "远程连接", general = "通用"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .sidecar: "ipad.landscape"
        case .remote: "display"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    // 上次打开的页签存在 UserDefaults，窗口关闭重开后还原
    @State private var pane: Pane? = {
        UserDefaults.standard.string(forKey: "settingsPane").flatMap(Pane.init(rawValue:))
    }() ?? .sidecar
    @State private var editingID: String? // 正在编辑名称的设备
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        // 不用 NavigationSplitView：放在 AppKit 窗口里时，侧栏和标题栏的分隔线会错位
        HStack(spacing: 0) {
            List(selection: $pane) {
                Section {
                    ForEach([Pane.sidecar, Pane.remote]) { pane in
                        Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                    }
                }
                Section {
                    Label(Pane.general.rawValue, systemImage: Pane.general.symbol).tag(Pane.general)
                }
            }
            .onChange(of: pane) { UserDefaults.standard.set(pane?.rawValue, forKey: "settingsPane") }
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
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: 随航

    @ViewBuilder private var sidecar: some View {
        Section("附近的 iPad") {
            if model.sidecarDevices.isEmpty {
                Text("未发现 iPad").foregroundStyle(.secondary)
            }
            ForEach(model.sidecarDevices) { device in
                LabeledContent {
                    status(device.connected, on: "已连接", off: "未连接")
                } label: {
                    Label(device.name, systemImage: "ipad.landscape")
                }
            }
        }
        Section {
            Toggle(isOn: binding(\.autoConnect, model.setAutoConnect)) {
                Text("无显示器时自动连接")
                Text("开机时若未连接显示器，将自动连接最近使用的 iPad 作为唯一显示器")
            }
        }
        Section("无线随航条件") {
            tip("person.crop.circle", "登录同一 Apple 账户", "Mac 与 iPad 需登录同一 Apple 账户，并启用双重认证")
            tip("wifi", "打开 Wi-Fi、蓝牙和接力", "无需接入无线网络，两台设备保持在 10 米范围内即可")
            tip("personalhotspot", "关闭 iPad 个人热点", "个人热点开启时无法使用无线随航")
            tip("cable.connector", "建议携带 USB-C 线缆", "有线连接不受无线条件限制；首次连接时需在 iPad 上信任此电脑")
        }
        Section("无显示器开机准备") {
            LabeledContent {
                Button("前往设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?FileVault")!)
                }
            } label: {
                tip("lock.shield", "关闭文件保险箱并启用自动登录", "文件保险箱开启时，Mac 开机后将停留在登录界面，无法自动连接")
            }
            tip("power", "启用登录时启动", "位于「通用」设置，确保开机后 SideLinker 自动运行")
            tip("clock.arrow.circlepath", "出行前完成一次连接", "SideLinker 将优先连接最近使用的 iPad")
            tip("ipad.landscape", "保持 iPad 解锁并靠近 Mac", "iPad 端无需其他操作，连接后即作为 Mac 的显示器")
        }
    }

    // MARK: 远程连接

    @ViewBuilder private var remote: some View {
        Section("状态") {
            LabeledContent("UU 远程连接") {
                status(model.uuConnected, on: "已连接", off: "未连接")
            }
            Toggle(isOn: Binding(get: { model.remoteActive }, set: { _ in model.toggleRemote() })) {
                Text("仅使用 iPad 显示")
                Text(model.activeSize.map { "已开启，分辨率 \($0.text)" } ?? "停用其他显示器，仅保留一块与 iPad 尺寸相同的虚拟显示器")
            }
            .disabled(model.busy || !(model.uuConnected || model.remoteActive))
        }
        if model.remoteDevices.isEmpty {
            Section("设备") {
                Text("暂无通过 UU 远程接入的设备").foregroundStyle(.secondary)
            }
        }
        ForEach(model.remoteDevices) { device in
            Section {
                Toggle("接入时自动启用「仅使用 iPad 显示」", isOn: Binding(get: { device.auto }, set: { model.setAutoDevice(device.id, $0) }))
                Picker("屏幕尺寸", selection: Binding(get: { device.size }, set: { model.setScreenSize(device.id, $0) })) {
                    ForEach(ScreenSize.all) { size in
                        Text("\(size.name)　\(size.text)").tag(size)
                    }
                }
                HStack {
                    Spacer()
                    Button("忘记此设备") { model.forgetDevice(device.id) }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    nameEditor(device)
                    Text(device.detail).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if device.connected { status(true, on: "已接入", off: "") }
                }
            }
        }
    }

    // MARK: 通用

    @ViewBuilder private var general: some View {
        Section {
            Toggle("登录时启动", isOn: binding(\.launchAtLogin, model.setLaunchAtLogin))
        }
        Section {
            LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        }
    }

    // MARK: 组件

    /// 设备名称：点击后就地编辑，回车或移开焦点时保存，Esc 取消，清空则恢复 UU 中的名称
    @ViewBuilder private func nameEditor(_ device: SettingsModel.RemoteDevice) -> some View {
        if editingID == device.id {
            Label {
                TextField("设备名称", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onExitCommand { editingID = nil }
                    .onChange(of: nameFocused) { if !nameFocused { commitName() } }
            } icon: {
                Image(systemName: "ipad.landscape")
            }
        } else {
            Button {
                draftName = device.name
                editingID = device.id
                nameFocused = true
            } label: {
                Label(device.name, systemImage: "ipad.landscape")
            }
            .buttonStyle(.plain)
            .help("点击修改设备名称")
        }
    }

    private func commitName() {
        guard let id = editingID else { return }
        editingID = nil
        model.setNickname(id, draftName)
    }

    /// 系统设置风格的状态：圆点加文字
    private func status(_ on: Bool, on onText: String, off offText: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(on ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
            Text(on ? onText : offText).foregroundStyle(.secondary)
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20) // 图标宽度不一，固定列宽让文字对齐
        }
    }

    private func binding(_ key: KeyPath<SettingsModel, Bool>, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { model[keyPath: key] }, set: set)
    }
}
