import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// 维护者联系方式：同事遇到问题从这里找人
    private let maintainerEmail = "eason.qi@byd.com"

    @State private var copiedEmail = false
    @State private var manualIP = ""
    @State private var manualPort = "47821"
    @State private var manualError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    identitySection
                    securitySection
                    trustedSection
                    networksSection
                    directSection
                    storageSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            contactFooter
        }
        .frame(width: 500, height: 640)
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
            Text("Settings")
                .font(GLFont.display(17, .semibold))
                .tracking(0.5)
                .foregroundColor(.glText)
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

    private var identitySection: some View {
        section(title: "CAPTAIN") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Button(action: pickAvatar) {
                        ZStack(alignment: .bottomTrailing) {
                            GLAvatar(image: state.avatar,
                                     seed: DeviceInfo.deviceID,
                                     size: 62)

                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(.glText)
                                )
                                .overlay(Circle().strokeBorder(Color.glBackground, lineWidth: 1.5))
                                .offset(x: 4, y: 4)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Choose a photo")

                    VStack(alignment: .leading, spacing: 8) {
                        TextField(DeviceInfo.computerName, text: $state.displayName)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundColor(.glText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(fieldBackground)

                        HStack(spacing: 6) {
                            if displayNameDiffers {
                                GhostButton(title: "Reset to computer name",
                                            systemImage: "arrow.counterclockwise") {
                                    state.displayName = DeviceInfo.computerName
                                }
                            }
                            if state.avatar != nil {
                                GhostButton(title: "Remove photo", systemImage: "trash") {
                                    state.clearAvatar()
                                }
                            }
                        }
                    }
                }

                Text("Other ships see this name on their chart. Empty or matching the computer name falls back to “\(DeviceInfo.computerName)”. Changes apply immediately.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.glTextDim.opacity(0.7))
            }
        }
    }

    private var displayNameDiffers: Bool {
        state.displayName.trimmingCharacters(in: .whitespacesAndNewlines) != DeviceInfo.computerName
    }

    private func pickAvatar() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Photo"
        panel.message = "Choose a photo for your profile"
        if panel.runModal() == .OK, let url = panel.url {
            state.setAvatar(from: url)
        }
    }

    private var securitySection: some View {
        section(title: "SECURITY") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Require a PIN")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.glText)
                        Text("Senders must enter the correct code before transferring")
                            .font(.system(size: 9.5))
                            .foregroundColor(.glTextDim)
                    }
                    Spacer()
                    GLSwitch(isOn: $state.pinEnabled)
                }

                if state.pinEnabled {
                    HStack(spacing: 8) {
                        TextField("4 digits", text: $state.pin)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.glText)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .frame(width: 108)
                            .background(fieldBackground)

                        GhostButton(title: "Generate", systemImage: "dice") {
                            state.pin = String(format: "%04d", Int.random(in: 0...9999))
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var networksSection: some View {
        section(title: "CHARTS") {
            VStack(alignment: .leading, spacing: 8) {
                if state.interfaces.isEmpty {
                    Text("No active IPv4 interface")
                        .font(.system(size: 11))
                        .foregroundColor(.glTextDim)
                        .padding(.vertical, 6)
                } else {
                    ForEach(state.interfaces) { iface in
                        InterfaceRow(
                            iface: iface,
                            isOn: Binding(
                                get: { !state.disabledInterfaces.contains(iface.id) },
                                set: { _ in state.toggleInterface(iface.id) }
                            )
                        )
                    }
                }

                Text("GrandLine only hails ships on the charts you enable here.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.glTextDim.opacity(0.7))
                    .padding(.top, 2)
            }
        }
    }

    private var trustedSection: some View {
        section(title: "TRUSTED SHIPS") {
            VStack(alignment: .leading, spacing: 8) {
                if state.trustedList.isEmpty {
                    Text("No trusted ships yet. Check “Trust” in an incoming request and that ship will be received automatically from then on.")
                        .font(.system(size: 9.5))
                        .foregroundColor(.glTextDim.opacity(0.7))
                } else {
                    ForEach(state.trustedList, id: \.id) { entry in
                        HStack(spacing: 11) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.glSea.opacity(0.10))
                                    .frame(width: 30, height: 30)
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.glSea)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundColor(.glText)
                                    .lineLimit(1)
                                Text(entry.id)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.glTextDim.opacity(0.7))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            IconButton(systemName: "xmark", size: 9) {
                                state.untrustPeer(id: entry.id)
                            }
                            .help("Stop trusting this ship")
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(rowBackground)
                    }
                }
            }
        }
    }

    private var directSection: some View {
        section(title: "DIRECT BEACONS") {
            VStack(alignment: .leading, spacing: 8) {
                Text("For networks where broadcast is suppressed (switch storm control / port isolation). Add the other Mac by its IP and it stays on your chart.")
                    .font(.system(size: 9.5))
                    .foregroundColor(.glTextDim.opacity(0.7))

                ForEach(state.manualPeers) { peer in
                    HStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.glGold.opacity(0.07))
                                .frame(width: 30, height: 30)
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.glAccent)
                        }
                        Text(peer.host)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.glText)
                        Spacer()
                        Text("port \(peer.port)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.glTextDim)
                            .padding(.trailing, 4)
                        IconButton(systemName: "xmark", size: 9) {
                            state.removeManualPeer(id: peer.id)
                        }
                        .help("Remove this beacon")
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(rowBackground)
                }

                HStack(spacing: 8) {
                    TextField("192.168.1.23", text: $manualIP)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.glText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(width: 150)
                        .background(fieldBackground)

                    TextField("47821", text: $manualPort)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.glText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(width: 76)
                        .background(fieldBackground)

                    GhostButton(title: "Add", systemImage: "plus") {
                        manualError = nil
                        guard let port = UInt16(manualPort.trimmingCharacters(in: .whitespaces)), port > 0 else {
                            manualError = "Invalid port"
                            return
                        }
                        if let err = state.addManualPeer(host: manualIP, port: port) {
                            manualError = err
                        } else {
                            manualIP = ""
                        }
                    }
                }

                if let manualError {
                    Text(manualError)
                        .font(.system(size: 9.5))
                        .foregroundColor(.glWax)
                }
            }
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

    private var storageSection: some View {
        section(title: "CARGO HOLD") {
            HStack(spacing: 8) {
                Text(TransferServer.inboxRoot.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.glTextDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                GhostButton(title: "Open", systemImage: "folder") { state.revealInbox() }
            }
        }
    }

    // MARK: 组件

    /// 底部联系方式条：点击复制邮箱，方便同事遇到问题时找到维护者
    private var contactFooter: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(maintainerEmail, forType: .string)
            copiedEmail = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedEmail = false }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: copiedEmail ? "checkmark.circle.fill" : "envelope")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(copiedEmail ? .glSea : .glGold.opacity(0.85))

                Text(copiedEmail ? "Copied to clipboard" : maintainerEmail)
                    .font(GLFont.mono(10.5))
                    .foregroundColor(copiedEmail ? .glSea : .glTextDim)
                    .lineLimit(1)

                Spacer()

                Text(copiedEmail ? "" : "Issues? Click to copy")
                    .font(.system(size: 9.5))
                    .foregroundColor(.glTextDim.opacity(0.6))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            Rectangle()
                .fill(Color.glBackground.opacity(0.6))
                .overlay(
                    Rectangle()
                        .fill(Color.glGold.opacity(0.14))
                        .frame(height: 1),
                    alignment: .top
                )
        )
        .help("Copy maintainer email")
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .glSectionStyle()
            content()
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(hex: 0xE8D9B8, alpha: 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.glGold.opacity(0.14), lineWidth: 1)
            )
    }
}

// MARK: - 网卡行

struct InterfaceRow: View {
    let iface: NetInterface
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.glGold.opacity(0.07))
                    .frame(width: 30, height: 30)
                Image(systemName: iface.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isOn ? .glAccent : .glTextDim)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(iface.name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(isOn ? .glText : .glTextDim)
                Text("\(iface.id) · \(iface.subnetLabel)")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(.glTextDim.opacity(0.8))
            }

            Spacer()

            Text(iface.ip)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.glTextDim)
                .padding(.trailing, 4)

            GLSwitch(isOn: $isOn)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0xE8D9B8, alpha: isOn ? 0.05 : 0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.glGold.opacity(isOn ? 0.14 : 0.06), lineWidth: 1)
                )
        )
        .opacity(isOn ? 1 : 0.72)
    }
}
