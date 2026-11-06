import Foundation
import Network
import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published state

    /// 广播发现的设备（只读，由 DiscoveryService 回写）
    @Published var discoveredPeers: [Peer] = [] { didSet { rebuildPeerIndex() } }
    /// 固定 IP 直连的对端（设置里手动添加）
    @Published var manualPeers: [Peer] = [] { didSet { rebuildPeerIndex() } }
    /// 主界面展示的全部设备：按「直连 → 信任 → 名称 → IP → ID」稳定排序后缓存。
    /// 上百台设备时 View 会多次读取，必须缓存，不能在求值时重复排序。
    @Published private(set) var peers: [Peer] = []
    /// 检索命中的设备；查询为空时等于 peers（再按匹配度重排一次）
    @Published private(set) var matchingPeers: [Peer] = []
    /// 出现重名的设备名：重名时卡片要补完整 IP 才能分辨
    @Published private(set) var duplicatePeerNames: Set<String> = []
    /// 与各设备成功传输过的次数：仅用于默认排序，界面不展示
    private var peerTransferCounts: [String: Int] = [:]
    /// 信任设备白名单（设置面板展示用）
    @Published var trustedList: [(id: String, name: String)] = [] { didSet { rebuildPeerIndex() } }

    /// 设备检索词（⌘F）
    @Published var peerQuery: String = "" { didSet { rebuildMatches() } }
    /// 检索条是否展开
    @Published var peerSearchOpen = false
    /// 每次请求聚焦自增；View 监听它来把焦点交给输入框
    @Published private(set) var peerSearchFocusTick = 0
    @Published var transfers: [TransferTask] = []
    @Published var pendingOffer: IncomingOffer?
    @Published var serviceRunning = false
    @Published var logLines: [String] = []

    /// 本机所有可用网段
    @Published var interfaces: [NetInterface] = []
    /// 被用户关闭的网卡（BSD 名称）
    @Published var disabledInterfaces: Set<String> = []

    /// 传输面板是否展开
    @Published var showTransfers = false {
        didSet {
            // 打开面板即视为已读，顶栏的绿点提示随之消失
            if showTransfers { hasUnseenCompletions = false }
        }
    }
    /// 有已完成但尚未查看的传输时，顶栏显示绿点
    @Published var hasUnseenCompletions = false
    /// 最近一次完成的传输：底部胶囊在其完成后驻留几秒再消失
    @Published var recentCompleted: TransferTask?
    private var recentCompletionWork: DispatchWorkItem?
    /// 已提示过「开始接收」的入站任务，避免同一次传输重复响铃
    private var announcedInbound: Set<String> = []
    @Published var showSettings = false
    /// 内置使用说明（? / ⌘?）
    @Published var showHelp = false
    /// 「发送剪贴板」面板（⌘K）是否展开
    @Published var showClipboardSend = false

    @Published var pinEnabled: Bool {
        didSet {
            UserDefaults.standard.set(pinEnabled, forKey: "GrandLine.pinEnabled")
            let active = pinEnabled && !pin.isEmpty
            server.restart(pinEnabled: active)
            discovery.updateAdvertisement(port: server.port, pinEnabled: active)
        }
    }

    @Published var pin: String {
        didSet { UserDefaults.standard.set(pin, forKey: "GrandLine.pin") }
    }

    @Published var displayName: String {
        didSet {
            let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == DeviceInfo.computerName {
                // 与电脑名一致时不落盘，电脑改名后自动跟随
                UserDefaults.standard.removeObject(forKey: "GrandLine.displayName")
            } else {
                UserDefaults.standard.set(trimmed, forKey: "GrandLine.displayName")
            }
            DeviceInfo.runtimeName = effectiveName
            discovery.updateAdvertisement(name: effectiveName)
        }
    }

    /// 本机头像（已裁切压缩）；nil 表示使用默认渐变图案
    @Published var avatar: NSImage? {
        didSet {
            if let avatar {
                AvatarStore.save(avatar)
            } else {
                AvatarStore.remove()
            }
            // 头像版本随信标广播，对端据此拉取新头像
            discovery.updateAdvertisement(avatarVersion: AvatarStore.version())
        }
    }

    @Published var receivingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(receivingEnabled, forKey: "GrandLine.receivingEnabled")
            if receivingEnabled {
                startServices()
            } else {
                server.stop()
                discovery.stop()
                serviceRunning = false
            }
        }
    }

    // MARK: - Services

    private let discovery = DiscoveryService()
    private let server = TransferServer()
    private var clients: [String: TransferClient] = [:]
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    private var ticker: Timer?
    private var lastInterfaceScan = Date.distantPast

    init() {
        let d = UserDefaults.standard
        self.pinEnabled = d.bool(forKey: "GrandLine.pinEnabled")
        self.pin = d.string(forKey: "GrandLine.pin") ?? ""
        // displayName 已兼容环境变量覆盖与「电脑名」回退
        self.displayName = DeviceInfo.displayName
        self.avatar = AvatarStore.load()
        self.disabledInterfaces = Set(d.stringArray(forKey: "GrandLine.disabledInterfaces") ?? [])
        self.manualPeers = ManualPeers.entries.compactMap(Self.makeManualPeer)
        self.trustedList = TrustedPeers.entries
        self.peerTransferCounts = TransferCounts.all

        if d.object(forKey: "GrandLine.receivingEnabled") == nil {
            d.set(true, forKey: "GrandLine.receivingEnabled")
        }
        self.receivingEnabled = d.bool(forKey: "GrandLine.receivingEnabled")

        // 让广播与投送立即使用当前昵称
        DeviceInfo.runtimeName = effectiveName

        self.interfaces = NetworkInfo.interfaces()

        discovery.onPeersChanged = { [weak self] list in
            Task { @MainActor in
                guard let self else { return }
                self.discoveredPeers = list
                self.maybeAutoSend(list)
                self.maybeAutoSendText(list)
            }
        }

        server.taskUpdate = { [weak self] task in
            Task { @MainActor in self?.upsert(task) }
        }
        server.approvalHandler = { [weak self] offer in
            await self?.requestApproval(offer) ?? false
        }
        server.logHandler = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }

        if receivingEnabled { startServices() }

        // 自动化钩子：仅允许启动时展开设置面板；传输面板永不自动展开
        if ProcessInfo.processInfo.environment["GRANDLINE_UI"] == "settings" {
            showSettings = true
        }

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.transfers.contains(where: { $0.status == .transferring }) {
                    self.objectWillChange.send()
                }
                if Date().timeIntervalSince(self.lastInterfaceScan) > 3 {
                    self.lastInterfaceScan = Date()
                    self.refreshInterfaces()
                }
            }
        }

        // init 中的属性赋值不触发 didSet，索引在这里补建一次
        rebuildPeerIndex()
    }

    // MARK: - 设备检索

    /// 展开检索条并请求焦点（⌘F）
    func openPeerSearch() {
        peerSearchOpen = true
        peerSearchFocusTick &+= 1
    }

    /// 关闭检索条并清空条件
    func closePeerSearch() {
        peerQuery = ""
        peerSearchOpen = false
    }

    /// 重建设备索引：稳定排序 + 重名统计 + 检索结果，三者一次算完
    private func rebuildPeerIndex() {
        let manualIDs = Set(manualPeers.map(\.id))
        let trustedIDs = Set(trustedList.map(\.id))

        // 置顶区只放静态集合：手动直连与信任设备。
        // 不用「最近投送」这类动态键——投完一台它就跳到首位，会摧毁空间记忆。
        func rank(_ peer: Peer) -> Int {
            if manualIDs.contains(peer.id) { return 0 }
            if trustedIDs.contains(peer.id) { return 1 }
            return 2
        }

        let all = discoveredPeers + manualPeers
        duplicatePeerNames = PeerSearch.duplicateNames(all)
        let counts = peerTransferCounts

        peers = all.sorted { a, b in
            // 第一优先：成功传输次数，越多越靠前（默认排序的主权重）
            let ca = counts[a.id] ?? 0
            let cb = counts[b.id] ?? 0
            if ca != cb { return ca > cb }

            // 次数相同（含都为 0）时回落到静态次序：
            // 手动直连 → 信任设备 → 名称 → IP → ID
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            // 同名设备（机房常态）必须有确定性次级键，否则位置会随字典遍历顺序抖动
            let ha = IPKey.value(a.host), hb = IPKey.value(b.host)
            if ha != hb { return ha < hb }
            return a.id < b.id
        }

        rebuildMatches()
    }

    private func rebuildMatches() {
        let tokens = PeerSearch.tokens(peerQuery)
        guard !tokens.isEmpty else {
            matchingPeers = peers
            return
        }
        // 前缀命中优先；同档内沿用稳定排序的原有次序
        matchingPeers = peers
            .filter { PeerSearch.matches($0, tokens: tokens) }
            .enumerated()
            .sorted { lhs, rhs in
                let ls = PeerSearch.score(lhs.element, tokens: tokens)
                let rs = PeerSearch.score(rhs.element, tokens: tokens)
                return ls == rs ? lhs.offset < rhs.offset : ls < rs
            }
            .map(\.element)
    }

    // MARK: - Service control

    /// 对外展示的昵称；输入为空时回退到电脑名
    var effectiveName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? DeviceInfo.computerName : trimmed
    }

    func startServices() {
        let pinActive = pinEnabled && !pin.isEmpty
        server.start(pinEnabled: pinActive)
        discovery.start(port: server.port, pinEnabled: pinActive, name: effectiveName)
        discovery.setEnabledInterfaces(enabledInterfaces)
        serviceRunning = true
        appendLog("Sailing as \(effectiveName)")
    }

    func refresh() {
        refreshInterfaces()
        // 暂停态下刷新只更新网卡列表，不能把广播重新拉起来
        guard receivingEnabled else { return }
        let pinActive = pinEnabled && !pin.isEmpty
        discovery.stop()
        discovery.start(port: server.port, pinEnabled: pinActive, name: effectiveName)
        discovery.setEnabledInterfaces(enabledInterfaces)
    }

    // MARK: - Interfaces

    /// 当前参与收发的网段
    var enabledInterfaces: [NetInterface] {
        interfaces.filter { !disabledInterfaces.contains($0.id) }
    }

    var networkSummary: String {
        let list = enabledInterfaces
        if !serviceRunning { return "Anchored" }
        if list.isEmpty { return "No chart enabled" }
        if list.count == 1 { return "\(list[0].name) · \(list[0].ip)" }
        return "\(list.count) networks active"
    }

    /// 扫描区展示的一句话状态，说明本机在哪些网段可见
    var visibilitySummary: String {
        guard serviceRunning else { return "Anchored — out of sight" }
        let list = enabledInterfaces
        if list.isEmpty { return "No chart enabled" }
        if list.count == 1 { return "Visible on \(list[0].name) · \(list[0].ip)" }
        return "Visible on \(list.count) networks"
    }

    func toggleInterface(_ id: String) {
        if disabledInterfaces.contains(id) {
            disabledInterfaces.remove(id)
        } else {
            disabledInterfaces.insert(id)
        }
        UserDefaults.standard.set(Array(disabledInterfaces), forKey: "GrandLine.disabledInterfaces")
        discovery.setEnabledInterfaces(enabledInterfaces)

        // 关闭某条网段后，来自该网段的设备应立即消失（手动对端不受网段过滤影响）
        let stillVisible = enabledInterfaces
        discoveredPeers = discoveredPeers.filter { peer in
            stillVisible.contains { NetworkInfo.ip(peer.host, belongsTo: $0) }
        }
        appendLog("Network selection updated: \(enabledInterfaces.map { $0.id }.joined(separator: ", "))")
    }

    func refreshInterfaces() {
        let fresh = NetworkInfo.interfaces()
        if fresh != interfaces {
            interfaces = fresh
            discovery.setEnabledInterfaces(enabledInterfaces)
        }
    }

    var serverPort: UInt16 { server.port }
    var isServerRunning: Bool { server.isRunning }

    // MARK: - Transfers

    var activeTransfers: [TransferTask] {
        transfers.filter { !$0.status.isFinished }
    }

    /// 主界面底部胶囊展示的那一条：优先显示进行中的传输；
    /// 没有进行中时，显示刚完成的传输（驻留几秒，方便点「打开文件夹」）
    var primaryActiveTransfer: TransferTask? {
        if let t = activeTransfers.first { return t }
        return recentCompleted
    }

    func send(items: [SharedItem], to peer: Peer) {
        guard !items.isEmpty else { return }

        var pinValue: String?
        if peer.requiresPIN {
            guard let entered = promptPIN(for: peer) else { return }
            pinValue = entered
        }

        let client = TransferClient(peer: peer, items: items, pin: pinValue)
        client.onUpdate = { [weak self] task in
            Task { @MainActor in
                self?.upsert(task)
                if task.status.isFinished {
                    self?.clients.removeValue(forKey: task.id)
                }
            }
        }
        clients[client.transferIdentifier] = client
        upsert(client.snapshotTask)
        client.start()
        appendLog("Sending \(items.count) item(s) to \(peer.name)")
    }

    func cancel(taskID: String) {
        clients[taskID]?.cancel()
        clients.removeValue(forKey: taskID)
        // 入站传输没有客户端对象，走服务端会话中止
        server.cancelInbound(taskID: taskID)
    }

    /// 剪贴板文本快传：把剪贴板内容作为 text 条目发给对端。
    /// 接收端确认后内容直接进入其剪贴板，同时在货舱留档。
    func sendClipboard(to peer: Peer) {
        guard let text = ClipboardBridge.text else {
            appendLog("Clipboard has no text to send")
            return
        }
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clipboard Text.txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            appendLog("Failed to stage clipboard text: \(error.localizedDescription)")
            return
        }
        appendLog("Sending clipboard text (\(ByteFormatter.string(Int64(text.utf8.count)))) to \(peer.name)")
        send(items: [SharedItem(url: fileURL, isText: true)], to: peer)
    }

    /// Dock 拖拽 / 「打开方式」进入的发送流程：单设备直发，多设备弹窗选择
    func sendWithTargetPicker(items: [SharedItem]) {
        guard !items.isEmpty else { return }
        let available = peers
        guard !available.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No ships in sight"
            alert.informativeText = "Open GrandLine on the other Mac and make sure both are on the same network."
            alert.runModal()
            return
        }

        let peer: Peer
        if available.count == 1 {
            peer = available[0]
        } else {
            let alert = NSAlert()
            alert.messageText = "Send to which ship?"
            alert.informativeText = items.count == 1
                ? "Destination for “\(items[0].name)”"
                : "Destination for \(items.count) item(s)"
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
            for p in available { popup.addItem(withTitle: "\(p.name) — \(p.host)") }
            popup.selectItem(at: 0)
            alert.accessoryView = popup
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            peer = available[popup.indexOfSelectedItem]
        }
        send(items: items, to: peer)
    }

    /// 航海日志「再发一次」：优先按设备 ID 找目标，回退按名字；过滤已不存在的源文件
    func resend(task: TransferTask) {
        let urls = task.items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            appendLog("Resend aborted: source files are gone")
            return
        }
        guard let peer = peers.first(where: { $0.id == task.peerID })
                ?? peers.first(where: { $0.name == task.peerName }) else {
            appendLog("Resend aborted: \(task.peerName) is not in sight")
            return
        }
        appendLog("Re-sending \(urls.count) item(s) to \(peer.name)")
        send(items: urls.map { SharedItem(url: $0) }, to: peer)
    }

    // MARK: - Manual peers (direct IP)

    private static func makeManualPeer(_ entry: ManualPeers.Entry) -> Peer? {
        guard let addr = IPv4Address(entry.host),
              let port = NWEndpoint.Port(rawValue: entry.port) else { return nil }
        return Peer(id: entry.id,
                    name: entry.host,
                    model: "Direct beacon",
                    endpoint: .hostPort(host: .ipv4(addr), port: port),
                    host: entry.host,
                    port: entry.port,
                    requiresPIN: false,
                    lastSeen: Date())
    }

    /// 添加固定 IP 直连对端；返回错误信息（nil 表示成功）
    func addManualPeer(host: String, port: UInt16) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard IPv4Address(trimmed) != nil else { return "Invalid IPv4 address" }
        let id = "manual-\(trimmed):\(port)"
        guard !manualPeers.contains(where: { $0.id == id }) else { return "Already on the chart" }
        ManualPeers.add(host: trimmed, port: port)
        manualPeers = ManualPeers.entries.compactMap(Self.makeManualPeer)
        appendLog("Direct beacon added: \(trimmed):\(port)")
        return nil
    }

    func removeManualPeer(id: String) {
        ManualPeers.remove(id: id)
        manualPeers = ManualPeers.entries.compactMap(Self.makeManualPeer)
        appendLog("Direct beacon removed")
    }

    // MARK: - Trusted peers

    func trustPeer(id: String, name: String) {
        TrustedPeers.trust(id: id, name: name)
        trustedList = TrustedPeers.entries
        appendLog("Trusted ship added: \(name)")
    }

    func untrustPeer(id: String) {
        TrustedPeers.remove(id: id)
        trustedList = TrustedPeers.entries
        appendLog("Trusted ship removed")
    }

    func clearFinished() {
        transfers.removeAll { $0.status.isFinished }
    }

    func revealInbox() {
        let dir = TransferServer.inboxRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    /// 在 Finder 中打开某次传输的成果：
    /// 接收 → 打开该发送者的收件文件夹；发送 → 定位到源文件
    func revealTask(_ task: TransferTask) {
        if task.direction == .inbound {
            let safeSender = PathSafety.sanitize(task.peerName)
            let dir = TransferServer.inboxRoot.appendingPathComponent(safeSender, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                NSWorkspace.shared.open(dir)
                return
            }
            revealInbox()
        } else {
            let urls = task.items.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// 完成的传输在底部胶囊驻留一段时间，期间可点「打开文件夹」
    private func celebrate(_ task: TransferTask) {
        recentCompletionWork?.cancel()
        recentCompleted = task
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.3)) { self?.recentCompleted = nil }
        }
        recentCompletionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: - Identity

    /// 从磁盘选择头像：保留原图，居中裁切 + 裁透明边距后落盘
    func setAvatar(from url: URL) {
        guard let normalized = AvatarStore.importImage(from: url) else { return }
        avatar = normalized
        appendLog("Profile photo updated")
    }

    /// 移除头像，回退到默认渐变图案
    func clearAvatar() {
        avatar = nil
        appendLog("Profile photo removed")
    }

    // MARK: - Approval

    private func requestApproval(_ offer: IncomingOffer) async -> Bool {
        if ProcessInfo.processInfo.environment["GRANDLINE_AUTO_ACCEPT"] == "1" {
            appendLog("Auto-accepted offer from \(offer.senderName) (test mode)")
            return true
        }
        if let existing = approvalContinuation {
            existing.resume(returning: false)
            approvalContinuation = nil
        }
        return await withCheckedContinuation { continuation in
            self.approvalContinuation = continuation
            self.pendingOffer = offer
            NSSound(named: "Ping")?.play()
        }
    }

    func respondToOffer(accept: Bool) {
        pendingOffer = nil
        approvalContinuation?.resume(returning: accept)
        approvalContinuation = nil
    }

    // MARK: - Internal

    private func upsert(_ task: TransferTask) {
        if let idx = transfers.firstIndex(where: { $0.id == task.id }) {
            transfers[idx] = task
        } else {
            transfers.insert(task, at: 0)
        }
        // 信任设备是静默自动接收的，没有审批浮层：传输一开始就必须给出提示，
        // 否则用户在窗口关闭/后台状态下全程无感知，直到文件默默落地。
        if task.direction == .inbound,
           task.status == .transferring,
           !announcedInbound.contains(task.id) {
            announcedInbound.insert(task.id)
            Notifier.transferIncoming(task)
        }
        if task.status == .completed {
            // 出站完成才计入排序权重：这是「我主动找过谁」的直接证据。
            // 入站不计数——收到别人的文件不代表我要发给它。
            if task.direction == .outbound, !task.peerID.isEmpty {
                TransferCounts.bump(id: task.peerID)
                peerTransferCounts = TransferCounts.all
                rebuildPeerIndex()
            }
            appendLog("\(task.direction == .inbound ? "Received" : "Delivered") \(task.items.count) item(s) · \(ByteFormatter.string(task.totalBytes))")
            // 底部胶囊驻留几秒，给出「打开文件夹」的入口
            celebrate(task)
            // 面板没开着时才算“未读”，点亮顶栏绿点
            if !showTransfers { hasUnseenCompletions = true }
            // 后台到达时弹系统通知（前台不打扰）
            Notifier.transferCompleted(task)
        }
    }

    private func appendLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.insert("[\(ts)] \(line)", at: 0)
        if logLines.count > 200 { logLines.removeLast(logLines.count - 200) }
    }

    // MARK: - Automation hooks

    private var autoSendTriggered = false

    private func maybeAutoSend(_ list: [Peer]) {
        guard !autoSendTriggered,
              let path = ProcessInfo.processInfo.environment["GRANDLINE_AUTO_SEND"], !path.isEmpty,
              let peer = list.first else { return }
        autoSendTriggered = true
        let paths = path.split(separator: ",").map(String.init)
        let items = paths.map { SharedItem(url: URL(fileURLWithPath: $0)) }
        appendLog("Auto-send \(items.count) item(s) to \(peer.name) (test mode)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.send(items: items, to: peer)
        }
    }

    private var autoTextTriggered = false

    /// 测试钩子：GRANDLINE_AUTO_SEND_TEXT=1 时，发现首个设备即发送当前剪贴板文本
    private func maybeAutoSendText(_ list: [Peer]) {
        guard !autoTextTriggered,
              ProcessInfo.processInfo.environment["GRANDLINE_AUTO_SEND_TEXT"] == "1",
              let peer = list.first else { return }
        autoTextTriggered = true
        appendLog("Auto-send clipboard text to \(peer.name) (test mode)")
        NSLog("[GrandLine] auto-send-text hook fired for \(peer.name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sendClipboard(to: peer)
        }
    }

    private func promptPIN(for peer: Peer) -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter PIN"
        alert.informativeText = "\(peer.name) requires a PIN. Enter the 4-digit code shown on that device."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "4-digit PIN"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
