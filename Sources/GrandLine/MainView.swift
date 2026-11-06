import SwiftUI
import UniformTypeIdentifiers
import AppKit

// MARK: - 主界面

struct MainView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var searchFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 172, maximum: 200), spacing: 12)]
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            AppBackground()

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 30)
                    .padding(.top, 18)
                    .padding(.bottom, 4)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        if !state.receivingEnabled {
                            frozenNotice
                        }

                        // 冻结时内容整体去色、变暗并禁用交互
                        VStack(alignment: .leading, spacing: 14) {
                            sectionHeader
                            if state.peerSearchOpen {
                                searchBar
                            }
                            deviceArea
                        }
                        .grayscale(state.receivingEnabled ? 0 : 1)
                        .opacity(state.receivingEnabled ? 1 : 0.42)
                        .allowsHitTesting(state.receivingEnabled)
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 26)
                    .padding(.bottom, 24)
                    .animation(.easeOut(duration: 0.25), value: state.receivingEnabled)
                }

                activeBar
            }

            // 航海日志
            if state.showTransfers {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.22)) { state.showTransfers = false }
                    }
                    .transition(.opacity)

                TransferDrawer()
                    .environmentObject(state)
                    .frame(width: 384)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing))
            }

            // 发送剪贴板（⌘K）
            if state.showClipboardSend {
                Color.black.opacity(0.42)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.22)) { state.showClipboardSend = false }
                    }
                    .transition(.opacity)

                ClipboardSendPanel { peer in
                    withAnimation(.easeOut(duration: 0.2)) { state.showClipboardSend = false }
                    state.sendClipboard(to: peer)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onExitCommand {
            // Esc：先收检索条，再关剪贴板面板，最后关抽屉
            if state.peerSearchOpen {
                if !state.peerQuery.isEmpty {
                    state.peerQuery = ""
                } else {
                    searchFocused = false
                    state.closePeerSearch()
                }
                return
            }
            if state.showClipboardSend {
                withAnimation(.easeOut(duration: 0.2)) { state.showClipboardSend = false }
                return
            }
            if state.showTransfers {
                withAnimation(.easeOut(duration: 0.2)) { state.showTransfers = false }
            }
        }
        .onChange(of: state.peerSearchFocusTick) { _, _ in
            searchFocused = true
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $state.showSettings) {
            SettingsSheet().environmentObject(state)
        }
        .sheet(isPresented: $state.showHelp) {
            HelpSheet().environmentObject(state)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.showTransfers)
        // 底部传输条的进出与完成态切换（含驻留消失）都带动画
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.primaryActiveTransfer?.id)
        .animation(.easeOut(duration: 0.25), value: state.primaryActiveTransfer?.status)
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            GLBrandMark(size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("GrandLine")
                    .font(GLFont.display(15.5, .semibold))
                    .tracking(0.4)
                    .foregroundColor(.glText)

                Button {
                    state.showSettings = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(state.serviceRunning ? Color.glSea : Color.glTextDim)
                            .frame(width: 5, height: 5)
                        Text(state.networkSummary)
                            .font(GLFont.text(10))
                            .foregroundColor(.glTextDim)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.glGold.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Color.glGold.opacity(0.24), lineWidth: 0.8))
                }
                .buttonStyle(.plain)
                .help("Manage charts")
            }

            Spacer()

            transfersButton

            IconButton(systemName: "questionmark.circle") {
                state.showHelp = true
            }
            .help("How to sail (⌘?)")

            IconButton(systemName: "slider.horizontal.3") {
                state.showSettings = true
            }
            .help("Settings")

            GLSwitch(isOn: $state.receivingEnabled)
                .help(state.receivingEnabled ? "Discoverable — click to drop anchor" : "Anchored — click to set sail")
        }
    }

    private var transfersButton: some View {
        ZStack(alignment: .topTrailing) {
            IconButton(systemName: "book.closed") {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    state.showTransfers.toggle()
                }
            }
            .help("Logbook")

            if !state.activeTransfers.isEmpty {
                Text("\(state.activeTransfers.count)")
                    .font(GLFont.mono(8, .bold))
                    .foregroundColor(Color(hex: 0x14100A))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(glAccentGradient))
                    .offset(x: 1, y: -1)
            } else if state.hasUnseenCompletions {
                // 未读的已完成传输提示；打开日志后清除
                Circle()
                    .fill(Color.glSea)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Color.glBackground, lineWidth: 1.5))
                    .offset(x: -6, y: 3)
            }
        }
    }

    // MARK: 抛锚提示

    private var frozenNotice: some View {
        HStack(spacing: 12) {
            AnchorShape()
                .stroke(Color.glGoldBright,
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 15)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.glGold.opacity(0.10)))

            VStack(alignment: .leading, spacing: 2) {
                Text("Dropped anchor")
                    .font(GLFont.display(12.5, .semibold))
                    .foregroundColor(.glText.opacity(0.92))
                Text("Not broadcasting or receiving — other ships can’t see you.")
                    .font(GLFont.text(10))
                    .foregroundColor(.glTextDim)
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.25)) { state.receivingEnabled = true }
            } label: {
                Text("Set sail")
                    .font(GLFont.text(11, .semibold))
                    .foregroundColor(Color(hex: 0x14100A))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(glAccentGradient))
                    .shadow(color: Color.glGold.opacity(0.28), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .chartPanel(radius: 14, highlighted: true)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: 船队区

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            Text("SHIPS NEARBY")
                .glSectionStyle()

            if !state.peers.isEmpty {
                Text("\(state.peers.count)")
                    .font(GLFont.mono(9, .bold))
                    .foregroundColor(Color.glGoldBright)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.glGold.opacity(0.22)))
            }

            Spacer()

            GhostButton(title: "Find", systemImage: "magnifyingglass") {
                if state.peerSearchOpen {
                    searchFocused = false
                    state.closePeerSearch()
                } else {
                    state.openPeerSearch()
                }
            }
            .help("Find a ship by name, model or IP (⌘F)")

            GhostButton(title: "Scan", systemImage: "location.north.line") {
                state.refresh()
            }
        }
    }

    // MARK: 检索条

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.glGoldBright)

            TextField("Name, model or IP fragment", text: $state.peerQuery)
                .textFieldStyle(.plain)
                .font(GLFont.text(12))
                .foregroundColor(.glText)
                .focused($searchFocused)
                .onSubmit { sendToFirstMatch() }

            if state.peerQuery.isEmpty {
                Text("⏎ choose files · Esc close")
                    .font(GLFont.text(9.5))
                    .foregroundColor(.glTextDim.opacity(0.7))
            } else {
                Text("\(state.matchingPeers.count)")
                    .font(GLFont.mono(9, .bold))
                    .foregroundColor(Color.glGoldBright)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.glGold.opacity(0.22)))

                Button {
                    state.peerQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.glTextDim)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: 0x05080C, alpha: 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.glGold.opacity(searchFocused ? 0.42 : 0.16), lineWidth: 1)
                )
        )
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var deviceArea: some View {
        if state.peers.isEmpty {
            CompassPlaceholder(enabled: state.serviceRunning,
                               name: state.effectiveName,
                               avatar: state.avatar,
                               detail: state.visibilitySummary)
        } else if state.matchingPeers.isEmpty {
            noMatchNotice
        } else {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(state.matchingPeers) { peer in
                    DeviceCard(peer: peer,
                               subtitle: subtitle(for: peer),
                               animated: state.peers.count <= 40,
                               progress: progress(for: peer)) { items in
                        state.send(items: items, to: peer)
                    } onTap: {
                        pickAndSend(to: peer)
                    } onPaste: {
                        state.sendClipboard(to: peer)
                    }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: state.matchingPeers.map(\.id))
        }
    }

    /// 卡片底注：重名时给完整 IP，设备较多时至少给 IP 末段。
    /// 上百台的场景里名字往往重复，没有地址就没有分辨依据。
    private func subtitle(for peer: Peer) -> String? {
        if state.duplicatePeerNames.contains(peer.name) { return peer.host }
        if state.peers.count > 8 { return "·\(PeerSearch.shortHost(peer.host))" }
        return nil
    }

    private var noMatchNotice: some View {
        VStack(spacing: 9) {
            Image(systemName: "binoculars")
                .font(.system(size: 19, weight: .light))
                .foregroundColor(Color.glGoldBright.opacity(0.66))

            Text("No ship matches “\(state.peerQuery)”")
                .font(GLFont.text(12, .medium))
                .foregroundColor(.glText.opacity(0.92))
                .lineLimit(1)

            Text("\(state.peers.count) ships nearby — try a shorter word or an IP fragment.")
                .font(GLFont.text(10.5))
                .foregroundColor(.glTextDim)

            Button {
                state.peerQuery = ""
                searchFocused = true
            } label: {
                Text("Clear search")
                    .font(GLFont.text(10.5, .semibold))
                    .foregroundColor(Color(hex: 0x14100A))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(glAccentGradient))
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .chartPanel(radius: 16)
    }

    private func sendToFirstMatch() {
        guard let peer = state.matchingPeers.first else { return }
        pickAndSend(to: peer)
    }

    private func progress(for peer: Peer) -> Double? {
        guard let t = state.transfers.first(where: {
            $0.peerName == peer.name && $0.direction == .outbound && $0.status == .transferring
        }) else { return nil }
        return t.progress
    }

    // MARK: 活跃航程条

    @ViewBuilder
    private var activeBar: some View {
        if let task = state.primaryActiveTransfer {
            let completed = task.status == .completed
            // 接收的文本条目：完成提示改为「已进剪贴板」
            let textInbound = task.direction == .inbound && (task.items.first?.isText ?? false)
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(completed ? Color.glSea.opacity(0.12) : Color.glGold.opacity(0.10))
                        .frame(width: 28, height: 28)
                    Image(systemName: task.direction == .inbound ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(completed ? Color.glSea : Color.glGoldBright)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(task.items.count == 1 ? task.items[0].name : "\(task.items.count) items")
                            .font(GLFont.text(11.5, .medium))
                            .foregroundColor(.glText)
                            .lineLimit(1)
                        Text(task.direction == .inbound ? "from \(task.peerName)" : "to \(task.peerName)")
                            .font(GLFont.text(10))
                            .foregroundColor(.glTextDim)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(completed
                             ? (textInbound ? "In clipboard — ⌘V to paste"
                                : task.direction == .inbound ? "Arrived" : "Delivered")
                             : "\(Int(task.progress * 100))%")
                            .font(GLFont.mono(10, .semibold))
                            .foregroundColor(completed ? Color.glSea : Color.glTextDim)
                    }
                    SlimProgressBar(progress: task.progress,
                                    tint: completed ? AnyShapeStyle(Color.glSea) : AnyShapeStyle(glAccentGradient),
                                    height: 3)
                }

                // 只给接收方提供「打开文件夹」入口：发送方的源文件本机就在哪，无需引导
                if completed && task.direction == .inbound {
                    Button {
                        state.revealTask(task)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Open")
                                .font(GLFont.text(10.5, .semibold))
                        }
                        .foregroundColor(Color(hex: 0x14100A))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.glSea.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help(task.direction == .inbound
                          ? "Open received folder in Finder"
                          : "Reveal sent files in Finder")
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }

                Button {
                    state.showTransfers = true
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.glTextDim)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.glGold.opacity(0.09)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 520)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.glBackground.opacity(0.55)))
                    .overlay(Capsule().strokeBorder(
                        completed ? Color.glSea.opacity(0.45) : Color.glGold.opacity(0.20),
                        lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Color.clear.frame(height: 8)
        }
    }

    private func pickAndSend(to peer: Peer) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "Choose files to send to \(peer.name)"
        if panel.runModal() == .OK {
            state.send(items: panel.urls.map { SharedItem(url: $0) }, to: peer)
        }
    }
}

// MARK: - 设备卡片

struct DeviceCard: View {
    let peer: Peer
    /// 卡片底注：重名给完整 IP，设备多时给 IP 末段
    var subtitle: String? = nil
    /// 是否跑船舶动效；设备多时关闭，避免滚动中反复创建无限动画
    var animated: Bool = true
    let progress: Double?
    var onDropItems: ([SharedItem]) -> Void
    var onTap: () -> Void
    var onPaste: () -> Void

    @State private var targeted = false
    @State private var pulse = false
    /// 悬停时剪贴板里有文本 → 显示「粘贴发送」按钮
    @State private var showPasteButton = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if targeted {
                    Circle()
                        .stroke(Color.glGold.opacity(0.55), lineWidth: 1)
                        .frame(width: 120, height: 120)
                        .scaleEffect(pulse ? 1.30 : 1.0)
                        .opacity(pulse ? 0 : 0.9)
                }

                if let avatar = peer.avatar {
                    // 对端头像：有照片显示照片
                    GLAvatar(image: avatar,
                             seed: peer.id,
                             size: 92,
                             ringed: true)
                        .shadow(color: Color.glGold.opacity(targeted ? 0.60 : 0.32),
                                radius: targeted ? 20 : 12, y: 3)
                } else {
                    // 模型船：船型按设备 ID 稳定分配，船身铭牌即身份
                    ShipShowcase(seed: peer.id, name: peer.name, size: 148, animated: animated)
                }
            }
            .frame(width: 148, height: 152)
            // 粘贴发送：金胶囊悬浮在船上方，好点、醒目
            .overlay(alignment: .top) {
                if showPasteButton {
                    Button(action: onPaste) {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text("Paste")
                                .font(GLFont.text(11, .semibold))
                        }
                        .foregroundColor(Color(hex: 0x161208))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(glAccentGradient))
                        .shadow(color: Color.glGold.opacity(0.30), radius: 9, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Paste clipboard text to \(peer.name)")
                    .offset(y: 2)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            // 名字与地址：船身铭牌只有 6pt，上百台时不足以辨认目标
            VStack(spacing: 1) {
                Text(peer.name)
                    .font(GLFont.text(11.5, .medium))
                    .foregroundColor(.glText.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(GLFont.mono(9))
                        .foregroundColor(.glTextDim)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 152)

            if let progress {
                SlimProgressBar(progress: progress, height: 3)
                    .frame(width: 120)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .help("\(peer.name) · \(peer.host)")
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { h in
            // 悬停时才探测剪贴板，避免常驻轮询；非文本内容不显示按钮
            withAnimation(.easeOut(duration: 0.16)) { showPasteButton = h && ClipboardBridge.hasText }
        }
        .onTapGesture(perform: onTap)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            loadItems(from: providers) { items in
                if !items.isEmpty { onDropItems(items) }
            }
            return true
        }
        .onChange(of: targeted) { _, isTarget in
            if isTarget {
                pulse = false
                withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            } else {
                pulse = false
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: targeted)
    }

    private func loadItems(from providers: [NSItemProvider], completion: @escaping ([SharedItem]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(urls.map { SharedItem(url: $0) })
        }
    }
}

// MARK: - 发送剪贴板面板（⌘K）

struct ClipboardSendPanel: View {
    @EnvironmentObject var state: AppState
    var onSend: (Peer) -> Void

    @State private var selectedID: String?
    /// 目标过滤：上百台设备时逐台翻页不可用
    @State private var query = ""

    private var text: String? { ClipboardBridge.text }

    private var list: [Peer] {
        let tokens = PeerSearch.tokens(query)
        guard !tokens.isEmpty else { return state.peers }
        return state.peers.filter { PeerSearch.matches($0, tokens: tokens) }
    }

    private var selectedPeer: Peer? {
        list.first { $0.id == selectedID } ?? list.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            shipList
            actions
        }
        .frame(width: 420)
        .background(
            ZStack {
                VisualEffect(material: .hudWindow)
                Color(hex: 0x090D12).opacity(0.92)
            }
        )
        .posterFrame(radius: 12)
        .preferredColorScheme(.dark)
        .onAppear { selectedID = state.peers.first?.id }
        .onMoveCommand { direction in
            guard list.count > 1 else { return }
            let idx = list.firstIndex { $0.id == selectedID } ?? 0
            let next: Int
            switch direction {
            case .up: next = max(0, idx - 1)
            case .down: next = min(list.count - 1, idx + 1)
            default: return
            }
            withAnimation(.easeOut(duration: 0.12)) { selectedID = list[next].id }
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(LinearGradient(colors: [.clear, Color.glGold.opacity(0.65)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 0.8)
                Text("SEND CLIPBOARD")
                    .font(GLFont.display(10, .semibold))
                    .tracking(3.0)
                    .foregroundColor(Color.glGoldBright)
                    .fixedSize()
                Rectangle()
                    .fill(LinearGradient(colors: [Color.glGold.opacity(0.65), .clear],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 0.8)
            }
            Text("Clipboard text will arrive in the other ship's clipboard.")
                .font(GLFont.text(10.5))
                .foregroundColor(.glTextDim)
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var preview: some View {
        Group {
            if let text {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(text)
                        .font(GLFont.text(11))
                        .foregroundColor(.glText.opacity(0.86))
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 96)
            } else {
                Text("Clipboard has no text — copy something first.")
                    .font(GLFont.text(11))
                    .foregroundColor(.glTextDim)
                    .padding(14)
                    .frame(maxWidth: .infinity)
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

    private var shipList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(state.peers.count == 1 ? "DESTINATION" : "CHOOSE A SHIP · ↑↓")
                    .font(GLFont.display(8.5, .semibold))
                    .tracking(1.6)
                    .foregroundColor(.glTextDim.opacity(0.75))
                Spacer()
                if !query.isEmpty {
                    Text("\(list.count) of \(state.peers.count)")
                        .font(GLFont.mono(8.5))
                        .foregroundColor(.glGoldBright.opacity(0.85))
                }
            }
            .padding(.horizontal, 31)
            .padding(.top, 14)
            .padding(.bottom, 7)

            if state.peers.count > 8 {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.glGoldBright)
                    TextField("Filter ships", text: $query)
                        .textFieldStyle(.plain)
                        .font(GLFont.text(11))
                        .foregroundColor(.glText)
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.glTextDim)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(hex: 0x05080C, alpha: 0.5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.glGold.opacity(0.16), lineWidth: 1)
                        )
                )
                .padding(.bottom, 6)
            }

            if state.peers.isEmpty {
                Text("No ships in sight — open GrandLine on the other Mac.")
                    .font(GLFont.text(11))
                    .foregroundColor(.glTextDim)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
            } else if list.isEmpty {
                Text("No ship matches “\(query)”.")
                    .font(GLFont.text(11))
                    .foregroundColor(.glTextDim)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
            } else {
                // 上百台时必须懒加载 + 限高，否则面板会被列表撑爆
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { idx, peer in
                            shipRow(peer, selected: peer.id == selectedPeer?.id, index: idx)
                        }
                    }
                }
                .frame(maxHeight: 244)
            }
        }
        .padding(.horizontal, 30)
    }

    private func shipRow(_ peer: Peer, selected: Bool, index: Int) -> some View {
        Button {
            selectedID = peer.id
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(PeerPalette.gradient(for: peer.id))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.glGold.opacity(0.4), lineWidth: 0.8))
                Text(peer.name)
                    .font(GLFont.text(11.5, selected ? .semibold : .regular))
                    .foregroundColor(.glText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(peer.host)
                    .font(GLFont.mono(9.5))
                    .foregroundColor(.glTextDim)
                if selected {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.glGoldBright)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.glGold.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { state.showClipboardSend = false }
            } label: {
                Text("Cancel")
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

            Button {
                if let peer = selectedPeer { onSend(peer) }
            } label: {
                Text(selectedPeer.map { "Send to \($0.name)" } ?? "Send")
                    .font(GLFont.text(12, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedPeer == nil
                                  ? AnyShapeStyle(Color.glGold.opacity(0.25))
                                  : AnyShapeStyle(glAccentGradient))
                    )
                    .foregroundColor(selectedPeer == nil ? .glTextDim : Color(hex: 0x161208))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(selectedPeer == nil || text == nil)
        }
        .padding(.horizontal, 30)
        .padding(.top, 16)
        .padding(.bottom, 26)
    }
}

// MARK: - 罗盘空状态（展示本机身份）

struct CompassPlaceholder: View {
    let enabled: Bool
    let name: String
    let avatar: NSImage?
    let detail: String

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // 外刻度环
                CompassTicks(count: 72, majorEvery: 6)
                    .stroke(Color.glGold.opacity(0.28), lineWidth: 0.9)
                    .frame(width: 212, height: 212)

                Circle()
                    .strokeBorder(Color.glGold.opacity(0.18), lineWidth: 0.9)
                    .frame(width: 178, height: 178)

                Circle()
                    .strokeBorder(Color.glGold.opacity(0.11),
                                  style: StrokeStyle(lineWidth: 0.8, dash: [1.5, 4]))
                    .frame(width: 150, height: 150)

                // 罗盘玫瑰：主星 + 旋转 22.5° 的副星
                CompassStar(points: 8)
                    .fill(LinearGradient(colors: [Color.glGold.opacity(0.60), Color.glGold.opacity(0.16)],
                                         startPoint: .top,
                                         endPoint: .bottom))
                    .frame(width: 132, height: 132)

                CompassStar(points: 8, longRatio: 0.66)
                    .fill(Color.glGold.opacity(0.20))
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(22.5))

                if enabled {
                    CompassSweep()
                    CompassPulse()
                }

                // 中央船徽：本机头像
                GLAvatar(image: avatar,
                         seed: DeviceInfo.deviceID,
                         size: 64,
                         gradient: glAccentGradient,
                         ringed: false)
                    .overlay(
                        Circle().strokeBorder(Color.glGold.opacity(0.85), lineWidth: 1)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.glGold.opacity(0.35), lineWidth: 0.8)
                            .padding(-6)
                    )
                    .shadow(color: Color.glGold.opacity(enabled ? 0.45 : 0.15), radius: 18, y: 4)
            }
            .frame(height: 218)

            VStack(spacing: 5) {
                Text(name)
                    .font(GLFont.display(14, .semibold))
                    .foregroundColor(.glText)
                    .lineLimit(1)

                Text(enabled ? detail : "Anchored — set sail to become visible")
                    .font(GLFont.text(10.5))
                    .foregroundColor(.glTextDim)

                if enabled {
                    Text("Open GrandLine on the other Mac — it will appear on your chart.")
                        .font(GLFont.text(10))
                        .foregroundColor(.glTextDim.opacity(0.6))
                        .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// 罗盘刻度环
struct CompassTicks: Shape {
    var count: Int = 72
    var majorEvery: Int = 6

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            let major = i % majorEvery == 0
            let inner = R - (major ? 9 : 4)
            p.move(to: CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner))
            p.addLine(to: CGPoint(x: c.x + cos(angle) * R, y: c.y + sin(angle) * R))
        }
        return p
    }
}

/// 八向罗盘玫瑰
struct CompassStar: Shape {
    var points: Int = 8
    var innerRatio: CGFloat = 0.17
    var longRatio: CGFloat = 1.0
    var shortRatio: CGFloat = 0.60

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let total = points * 2

        for i in 0..<total {
            let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / CGFloat(points)
            let tipIndex = i / 2
            let r: CGFloat
            if i % 2 == 0 {
                r = R * (tipIndex % 2 == 0 ? longRatio : shortRatio)
            } else {
                r = R * innerRatio
            }
            let pt = CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// 缓速扫过的光弧，保留「正在搜索」的语义
private struct CompassSweep: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    gradient: Gradient(colors: [
                        Color.glGold.opacity(0.0),
                        Color.glGold.opacity(0.24)
                    ]),
                    center: .center,
                    startAngle: .degrees(0),
                    endAngle: .degrees(52)
                )
            )
            .frame(width: 176, height: 176)
            .mask(Circle().frame(width: 176, height: 176))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 7.5).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

/// 船徽外扩散的呼吸圈
private struct CompassPulse: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(Color.glGold.opacity(0.42), lineWidth: 1)
            .frame(width: 78, height: 78)
            .scaleEffect(pulse ? 1.9 : 1.0)
            .opacity(pulse ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 3.4).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}
