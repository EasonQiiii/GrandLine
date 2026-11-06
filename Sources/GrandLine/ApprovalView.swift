import SwiftUI
import AppKit

/// 接收确认浮层：对方投送到达时弹出，用户决定接收或拒绝。
/// 版式做成一张贴在船舷上的悬赏令：双线金框 + 四角花饰 + 大字船名。
struct ApprovalView: View {
    let offer: IncomingOffer
    /// 发送方头像（若已从信标同步到）；nil 则回退到渐变船徽
    var senderAvatar: NSImage? = nil
    var onAccept: (_ trustNow: Bool) -> Void
    var onDecline: () -> Void

    @State private var trustNow = false

    private var visibleItems: [ItemMeta] { Array(offer.items.prefix(4)) }
    private var overflow: Int { max(0, offer.items.count - 4) }

    /// 文本快传条目：有则弹窗切换为文本预览版式
    private var textItem: ItemMeta? { offer.items.first(where: { $0.kind == ItemKind.text }) }

    var body: some View {
        VStack(spacing: 0) {
            masthead
            if let textItem {
                textPreview(textItem)
            } else {
                fileList
            }
            totalLine
            trustToggle
            actions
        }
        .frame(width: 400)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color(hex: 0x090D12).opacity(0.92)
                // 纸面受光的暖调
                LinearGradient(colors: [Color(hex: 0xE8D9B8, alpha: 0.085), .clear],
                               startPoint: .top,
                               endPoint: .center)
            }
        )
        .posterFrame(radius: 12)
        .preferredColorScheme(.dark)
    }

    // MARK: 报头

    private var masthead: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                rule
                Text("A SHIP HAILS")
                    .font(GLFont.display(10, .semibold))
                    .tracking(3.0)
                    .foregroundColor(Color.glGoldBright)
                    .fixedSize()
                rule
            }

            ZStack {
                if let senderAvatar {
                    GLAvatar(image: senderAvatar,
                             seed: offer.senderID,
                             size: 58,
                             ringed: false)
                } else {
                    // 迷你模型船：随浪轻摇
                    ShipShowcase(seed: offer.senderID, size: 54, engraved: false)
                }
                Circle()
                    .strokeBorder(Color.glGold.opacity(0.60), lineWidth: 1)
                    .frame(width: 58, height: 58)
                Circle()
                    .strokeBorder(Color.glGold.opacity(0.20), lineWidth: 0.8)
                    .frame(width: 70, height: 70)
            }
            .shadow(color: Color.glGold.opacity(0.22), radius: 12, y: 3)
            .padding(.top, 2)

            VStack(spacing: 4) {
                Text(offer.senderName)
                    .font(GLFont.display(22, .bold))
                    .tracking(1.0)
                    .foregroundColor(.glText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)

                Text(textItem != nil
                     ? "sends a text snippet — will land in your clipboard"
                     : "requests passage — \(offer.items.count == 1 ? "1 file" : "\(offer.items.count) files")")
                    .font(GLFont.text(10.5))
                    .foregroundColor(.glTextDim)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var rule: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, Color.glGold.opacity(0.65)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 0.8)
    }

    // MARK: 货单

    private var fileList: some View {
        VStack(spacing: 0) {
            ForEach(Array(visibleItems.enumerated()), id: \.offset) { idx, item in
                HStack(spacing: 9) {
                    Image(systemName: iconFor(item.name))
                        .font(.system(size: 10.5))
                        .foregroundColor(Color.glGold.opacity(0.85))
                        .frame(width: 15)
                    Text(item.name)
                        .font(GLFont.text(11.5))
                        .foregroundColor(.glText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteFormatter.string(item.size))
                        .font(GLFont.mono(9.5))
                        .foregroundColor(.glTextDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)

                if idx < visibleItems.count - 1 {
                    Rectangle()
                        .fill(Color.glGold.opacity(0.10))
                        .frame(height: 1)
                        .padding(.leading, 36)
                }
            }

            if overflow > 0 {
                HStack {
                    Text("and \(overflow) more")
                        .font(GLFont.text(10.5))
                        .foregroundColor(.glTextDim)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: 0x05080C, alpha: 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.glGold.opacity(0.16), lineWidth: 1)
                )
        )
        .padding(.horizontal, 30)
    }

    /// 文本快传版式：单行货物信息 + 预览正文
    private func textPreview(_ item: ItemMeta) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.glGold.opacity(0.85))
                    .frame(width: 15)
                Text(item.name)
                    .font(GLFont.text(11.5))
                    .foregroundColor(.glText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(ByteFormatter.string(item.size))
                    .font(GLFont.mono(9.5))
                    .foregroundColor(.glTextDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle()
                .fill(Color.glGold.opacity(0.10))
                .frame(height: 1)
                .padding(.leading, 12)

            ScrollView(.vertical, showsIndicators: false) {
                Text(item.preview ?? "")
                    .font(GLFont.text(11))
                    .foregroundColor(.glText.opacity(0.86))
                    .lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 120)
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(hex: 0x05080C, alpha: 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.glGold.opacity(0.16), lineWidth: 1)
                )
        )
        .padding(.horizontal, 30)
    }

    private var totalLine: some View {
        HStack(spacing: 8) {
            Text("CARGO")
                .font(GLFont.display(8.5, .semibold))
                .tracking(1.6)
                .foregroundColor(.glTextDim.opacity(0.75))
            Text(ByteFormatter.string(offer.totalBytes))
                .font(GLFont.mono(10, .medium))
                .foregroundColor(.glTextDim)
            Spacer()
        }
        .padding(.horizontal, 31)
        .padding(.top, 10)
    }

    // MARK: 按钮

    private var trustToggle: some View {
        Button {
            trustNow.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: trustNow ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundColor(trustNow ? Color.glSea : .glTextDim.opacity(0.8))
                Text("Trust \(offer.senderName) — receive future transfers without asking")
                    .font(GLFont.text(10))
                    .foregroundColor(.glTextDim)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 31)
        .padding(.top, 12)
    }

    private var actions: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onDecline) {
                    Text("Decline")
                        .font(GLFont.text(12, .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(hex: 0xE8D9B8, alpha: 0.06))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.glGold.opacity(0.14), lineWidth: 1)
                                )
                        )
                        .foregroundColor(.glText)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: { onAccept(trustNow) }) {
                    Text("Accept")
                        .font(GLFont.text(12, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(glAccentGradient)
                        )
                        .foregroundColor(Color(hex: 0x161208))
                        .shadow(color: Color.glGold.opacity(0.28), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 30)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
    }

    private func iconFor(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp": return "photo"
        case "mov", "mp4", "m4v", "avi", "mkv": return "film"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "pdf": return "doc.richtext"
        case "mp3", "wav", "flac", "aac": return "music.note"
        default: return "doc"
        }
    }
}
