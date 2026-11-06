import SwiftUI
import AppKit

/// 右侧滑出的航海日志
struct TransferDrawer: View {
    @EnvironmentObject var state: AppState

    private var active: [TransferTask] { state.transfers.filter { !$0.status.isFinished } }
    private var finished: [TransferTask] { state.transfers.filter { $0.status.isFinished } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    if state.transfers.isEmpty {
                        emptyState
                    } else {
                        if !active.isEmpty { group(title: "UNDER WAY", items: active) }
                        if !finished.isEmpty { group(title: "PAST VOYAGES", items: finished, showClear: true) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }

            footer
        }
        .background(
            ZStack {
                VisualEffect(material: .sidebar)
                Color.glBackground.opacity(0.80)
            }
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.glGold.opacity(0.32))
                .frame(width: 1)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Logbook")
                    .font(GLFont.display(16, .semibold))
                    .tracking(0.6)
                    .foregroundColor(.glText)
                Text(active.isEmpty
                     ? "\(state.transfers.count) entr\(state.transfers.count == 1 ? "y" : "ies") in the log"
                     : "\(active.count) under way · \(finished.count) arrived")
                    .font(GLFont.text(10))
                    .foregroundColor(.glTextDim)
            }
            Spacer()
            IconButton(systemName: "xmark", size: 11) {
                withAnimation(.easeOut(duration: 0.2)) { state.showTransfers = false }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func group(title: String, items: [TransferTask], showClear: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title)
                    .glSectionStyle()
                Spacer()
                if showClear {
                    GhostButton(title: "Clear") { state.clearFinished() }
                }
            }
            ForEach(items) { task in
                TransferRow(task: task,
                            onResend: { state.resend(task: task) },
                            onCancel: { state.cancel(taskID: task.id) })
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "book.closed")
                .font(.system(size: 22, weight: .light))
                .foregroundColor(Color.glGold.opacity(0.55))
            Text("The logbook is still blank")
                .font(GLFont.display(11.5))
                .foregroundColor(.glTextDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var footer: some View {
        HStack {
            Button {
                state.revealInbox()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "shippingbox").font(.system(size: 9.5))
                    Text("Cargo hold").font(GLFont.text(10.5))
                }
                .foregroundColor(.glTextDim)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            Rectangle()
                .fill(Color.glGold.opacity(0.03))
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.glGold.opacity(0.22)).frame(height: 1)
                }
        )
    }
}

// MARK: - 单条航程

struct TransferRow: View {
    let task: TransferTask
    var onResend: () -> Void = {}
    var onCancel: () -> Void

    private var tint: Color {
        switch task.status {
        case .completed: return .glSea
        case .failed, .rejected: return .glWax
        case .cancelled: return .glTextDim
        default: return .glGold
        }
    }

    private var title: String {
        task.items.count == 1 ? task.items[0].name : "\(task.items.count) items"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.glGold.opacity(0.07))
                    .frame(width: 30, height: 30)
                Image(systemName: task.direction == .inbound ? "arrow.down.left" : "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(GLFont.text(11.5, .medium))
                        .foregroundColor(.glText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if task.status == .completed {
                        // 完成的航程可一键重发（源文件仍在时）
                        Button(action: onResend) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(.glTextDim)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.glGold.opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                        .help("Send these files again")
                    }
                    if !task.status.isFinished && task.status != .waitingApproval {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.glTextDim)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.glGold.opacity(0.09)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 4) {
                    Text(task.direction == .inbound ? "from" : "to")
                    Text(task.peerName).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(task.status.displayText)
                        .foregroundColor(tint)
                }
                .font(GLFont.text(9.5))
                .foregroundColor(.glTextDim)

                if task.status == .transferring || task.status == .completed {
                    SlimProgressBar(
                        progress: task.progress,
                        tint: AnyShapeStyle(task.status == .completed ? Color.glSea : Color.glGold)
                    )
                    .padding(.top, 1)
                }

                HStack(spacing: 6) {
                    Text("\(ByteFormatter.string(task.transferredBytes)) / \(ByteFormatter.string(task.totalBytes))")
                    if !task.speedText.isEmpty { Text("· \(task.speedText)") }
                    if !task.remainingText.isEmpty { Text("· \(task.remainingText)") }
                    Spacer()
                }
                .font(GLFont.mono(9))
                .foregroundColor(.glTextDim.opacity(0.75))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .chartPanel(radius: 12, cornerMarks: false)
        .overlay(alignment: .topTrailing) {
            if task.status == .completed {
                WaxSeal(size: 22).offset(x: 7, y: -7)
            }
        }
    }
}
