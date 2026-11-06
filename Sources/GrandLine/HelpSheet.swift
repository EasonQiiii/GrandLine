import SwiftUI
import AppKit

/// 内置使用说明（顶栏 ? 按钮 / ⌘? / Help 菜单打开）。
/// 版式与设置面板一致：分区标题 + 图标行 + 快捷键徽章。
struct HelpSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    quickStart
                    sendWays
                    receiveWays
                    shortcuts
                    tips
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 560, height: 660)
        .onExitCommand { dismiss() }
        .background(
            ZStack {
                Color.glBackground
                AppBackground().opacity(0.7)
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("How to sail")
                    .font(GLFont.display(17, .semibold))
                    .tracking(0.5)
                    .foregroundColor(.glText)
                Text("Everything GrandLine can do, on one page")
                    .font(GLFont.text(10))
                    .foregroundColor(.glTextDim)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.glText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: 分区

    private var quickStart: some View {
        section(title: "QUICK START") {
            VStack(alignment: .leading, spacing: 9) {
                stepRow(1, "Open GrandLine on both Macs — keep the top switch on (set sail).")
                stepRow(2, "Wait for the other ship to appear on your chart.")
                stepRow(3, "Drag files onto its card — or use any of the ways below.")
            }
        }
    }

    private var sendWays: some View {
        section(title: "WAYS TO SEND") {
            VStack(alignment: .leading, spacing: 8) {
                helpRow(icon: "hand.draw",
                        title: "Drag & drop",
                        detail: "Drop files or folders onto a ship card. Folders are zipped automatically.")
                helpRow(icon: "cursorarrow.click.2",
                        title: "Click a card",
                        detail: "Pick files with the open panel.")
                helpRow(icon: "doc.on.clipboard",
                        title: "Clipboard text",
                        detail: "Hover a card and click the paste button, or press ⌘K. The text lands in the other Mac's clipboard.")
                helpRow(icon: "dock.rectangle",
                        title: "Dock & Finder",
                        detail: "Drop files on the Dock icon, or right-click a file → Open With → GrandLine.")
                helpRow(icon: "arrow.clockwise",
                        title: "Send again",
                        detail: "In the Logbook (⌘T), click ↻ on a finished voyage to resend it.")
            }
        }
    }

    private var receiveWays: some View {
        section(title: "RECEIVING") {
            VStack(alignment: .leading, spacing: 8) {
                helpRow(icon: "scroll",
                        title: "Wanted poster",
                        detail: "Every arrival shows a poster — Return accepts, Esc declines.")
                helpRow(icon: "doc.plaintext",
                        title: "Text snippets",
                        detail: "Accepted text goes straight into your clipboard (⌘V to paste). A copy is kept in the cargo hold.")
                helpRow(icon: "checkmark.seal",
                        title: "Trusted ships",
                        detail: "Check “Trust” on a poster to auto-accept that ship from now on (also skips PIN). Manage in Settings → Trusted Ships.")
                helpRow(icon: "shippingbox",
                        title: "Cargo hold",
                        detail: "Files land in ~/Downloads/GrandLine/<sender>/. ⌘O opens it. A PIN can be required in Settings.")
                helpRow(icon: "bell",
                        title: "Notifications",
                        detail: "When GrandLine is in the background, finished transfers raise a system notification — click it to jump back.")
            }
        }
    }

    private var shortcuts: some View {
        section(title: "KEYBOARD") {
            VStack(alignment: .leading, spacing: 6) {
                keyRow("⌘R", "Scan for nearby ships")
                keyRow("⌘F", "Find a ship by name, model or IP")
                keyRow("⌘D", "Set sail / drop anchor (pause broadcasting & receiving)")
                keyRow("⌘K", "Send clipboard text")
                keyRow("⌘T", "Logbook")
                keyRow("⌘O", "Open cargo hold")
                keyRow("⌘,", "Settings")
                keyRow("⌘?", "This page")
                keyRow("Esc", "Close panels · decline in the poster")
                keyRow("⌘W / ⌘M", "Close window / minimize")
            }
        }
    }

    private var tips: some View {
        section(title: "GOOD TO KNOW") {
            VStack(alignment: .leading, spacing: 8) {
                helpRow(icon: "antenna.radiowaves.left.and.right",
                        title: "Direct beacons",
                        detail: "Corporate switches that suppress broadcast? Settings → Direct Beacons → add the peer by IP.")
                helpRow(icon: "network",
                        title: "Charts",
                        detail: "Settings → Charts lets you enable or disable each network interface (Ethernet / Wi-Fi / VPN) individually.")
                helpRow(icon: "book.closed",
                        title: "Unread badge",
                        detail: "A green dot on the Logbook icon means a transfer finished while you were away.")
            }
        }
    }

    // MARK: 组件

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .glSectionStyle()
            content()
        }
    }

    private func stepRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(GLFont.mono(10, .bold))
                .foregroundColor(Color(hex: 0x14100A))
                .frame(width: 18, height: 18)
                .background(Circle().fill(glAccentGradient))

            Text(text)
                .font(GLFont.text(11))
                .foregroundColor(.glText.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.glGold.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.glGold.opacity(0.08))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(GLFont.text(11.5, .semibold))
                    .foregroundColor(.glText)
                Text(detail)
                    .font(GLFont.text(10))
                    .foregroundColor(.glTextDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(rowBackground)
    }

    private func keyRow(_ key: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(GLFont.mono(10, .semibold))
                .foregroundColor(.glGoldBright)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(minWidth: 58)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.glGold.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.glGold.opacity(0.28), lineWidth: 0.8)
                        )
                )
            Text(detail)
                .font(GLFont.text(10.5))
                .foregroundColor(.glTextDim)
            Spacer(minLength: 0)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(hex: 0xE8D9B8, alpha: 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.glGold.opacity(0.10), lineWidth: 1)
            )
    }
}
