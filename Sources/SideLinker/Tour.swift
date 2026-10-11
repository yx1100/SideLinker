import SwiftUI

/// 首次启动的功能介绍：逐页说明三种场景和恢复方法，最后一页可开启登录时启动
struct TourView: View {
    @ObservedObject var model: SettingsModel
    let onFinish: () -> Void
    @State private var page = 0

    private struct Page {
        let symbol: String
        let tint: Color
        let title: String
        let text: String
    }

    private let pages = [
        Page(symbol: "macbook.and.ipad", tint: .blue, title: "欢迎使用 SideLinker",
             text: "SideLinker 让 iPad 在三种场景下作为 Mac 的显示器。它常驻在菜单栏，大部分时候不需要你操作。"),
        Page(symbol: "ipad.landscape.badge.play", tint: .teal, title: "随航",
             text: "Mac 接着显示器时，照常使用系统的随航。Mac 没有接任何显示器时，登录后自动连接最近使用的 iPad，让它成为唯一的显示器。"),
        Page(symbol: "display", tint: .indigo, title: "远程连接",
             text: "用 iPad 通过网易 UU 远程控制 Mac 时，先在设置里选好 iPad 的屏幕尺寸，再从菜单栏打开「使用 iPad 单屏显示」。物理显示器会暂时停用，只留一块与 iPad 尺寸相同的虚拟显示器，画面没有黑边。"),
        Page(symbol: "arrow.uturn.backward.circle", tint: .orange, title: "断开后自动恢复",
             text: "UU 断开 30 秒后，SideLinker 恢复物理显示器并锁屏。坐在 Mac 前看不到画面时，按 \(AppDelegate.restoreShortcut) 立即恢复。"),
        Page(symbol: "power", tint: .green, title: "开始使用",
             text: "建议开启登录时启动：开机后自动运行；App 意外退出或无响应时，系统会重新启动它并恢复显示器。之后可以在菜单栏图标的「设置…」中修改。"),
    ]

    var body: some View {
        let current = pages[page]
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(current.tint.gradient)
                Image(systemName: current.symbol)
                    .font(.system(size: 72, weight: .regular))
                    .foregroundStyle(.white)
            }
            .frame(height: 200)

            VStack(spacing: 12) {
                Text(current.title).font(.title2.bold())
                Text(current.text)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if page == pages.count - 1 {
                    Toggle("登录时启动", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
                        .toggleStyle(.switch)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 24)

            Spacer(minLength: 0)

            HStack {
                Button("上一步") { page -= 1 }
                    .opacity(page == 0 ? 0 : 1)
                    .disabled(page == 0)
                Spacer()
                Button(page == pages.count - 1 ? "开始使用" : "继续") {
                    if page == pages.count - 1 { onFinish() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .overlay { // 两侧按钮宽度不同，页码圆点单独居中
                HStack(spacing: 6) {
                    ForEach(pages.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? Color.primary : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(20)
        }
        .ignoresSafeArea() // 先铺满标题栏区域，再定尺寸，窗口才不会多出标题栏的高度
        .frame(width: 520, height: 420)
        .animation(.easeInOut(duration: 0.2), value: page)
    }
}
