import Foundation
import AppKit
import Network

/// 接收端：监听 TCP 端口并通过 Bonjour 广播自身，处理入站投送请求。
final class TransferServer {

    static let candidatePorts: [UInt16] = Array(47821...47880)

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "grandline.server")
    private var sessions: [ObjectIdentifier: InboundSession] = [:]
    private var sessionSeq = 0

    /// 需要用户确认时调用；返回 true 表示接受
    var approvalHandler: ((IncomingOffer) async -> Bool)?
    /// 任务状态变化（等待确认 / 传输中 / 完成）
    var taskUpdate: ((TransferTask) -> Void)?
    /// 日志
    var logHandler: ((String) -> Void)?

    var isRunning: Bool { listener != nil }

    // MARK: - 生命周期

    func start(pinEnabled: Bool) {
        stop()

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        // 关闭端口复用，避免同机多实例抢占同一端口
        params.allowLocalEndpointReuse = false

        var created: NWListener?
        var chosenPort: UInt16 = 0

        for candidate in Self.candidatePorts {
            guard let p = NWEndpoint.Port(rawValue: candidate), Self.isPortFree(candidate) else { continue }
            if let l = try? NWListener(using: params, on: p) {
                created = l
                chosenPort = candidate
                break
            }
        }
        if created == nil {
            log("Cannot start receiver: ports 47821-47880 all in use")
            return
        }
        guard let listener = created else { return }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let p = listener.port?.rawValue, chosenPort == 0 {
                    self.port = p
                } else {
                    self.port = chosenPort
                }
                self.log("Receiver ready on port \(self.port)")
            case .failed(let err):
                self.log("Receiver error: \(err.localizedDescription)")
                self.port = 0
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.queue.async {
                self.sessionSeq += 1
                let session = InboundSession(connection: conn,
                                             server: self,
                                             sequence: self.sessionSeq)
                self.sessions[ObjectIdentifier(session)] = session
                session.onClose = { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.sessions.removeValue(forKey: ObjectIdentifier(session))
                }
                session.start()
            }
        }

        do {
            listener.start(queue: queue)
            self.listener = listener
            self.port = chosenPort
        } catch {
            log("Cannot start receiver: \(error.localizedDescription)")
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.port = 0
            for (_, s) in self.sessions { s.cancel() }
            self.sessions.removeAll()
        }
    }

    /// 广播内容里的 PIN 状态变化时需要重启服务
    func restart(pinEnabled: Bool) {
        start(pinEnabled: pinEnabled)
    }

    /// 探测 TCP 端口是否可绑定（NWListener 的端口绑定发生在 start() 阶段，无法用初始化抛错判断）
    static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// 手工构造 DNS-SD TXT record 二进制：每项 1 字节长度前缀 + "key=value"
    static func makeTXTRecord(_ dict: [String: String]) -> Data {
        var data = Data()
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let entry = Array("\(k)=\(v)".utf8)
            var offset = 0
            while offset < entry.count {
                let n = min(255, entry.count - offset)
                data.append(UInt8(n))
                data.append(contentsOf: entry[offset..<(offset + n)])
                offset += n
            }
        }
        return data
    }

    // MARK: - 回调桥接

    func requestApproval(_ offer: IncomingOffer) async -> Bool {
        guard let handler = approvalHandler else { return false }
        return await handler(offer)
    }

    /// 取消某条入站传输（Logbook 行的 × 按钮）
    func cancelInbound(taskID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, s) in self.sessions {
                s.abortIfMatches(taskID: taskID)
            }
        }
    }

    func emit(_ task: TransferTask) {
        taskUpdate?(task)
    }

    func log(_ message: String) {
        NSLog("[GrandLine] \(message)")
        logHandler?(message)
    }

    // MARK: - 接收目录

    static var inboxRoot: URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("GrandLine", isDirectory: true)
    }
}

// MARK: - 入站会话

final class InboundSession {

    private let connection: NWConnection
    private unowned let server: TransferServer
    private let sequence: Int
    private let queue: DispatchQueue

    private let decoder = FrameDecoder()
    private var offer: IncomingOffer?
    private var transferID = ""
    private var senderFolder: URL?
    private var task: TransferTask?
    private var totalReceived: Int64 = 0
    private var expectedCount = 0
    private var finishedCount = 0

    private var currentHandle: FileHandle?
    private var currentFileURL: URL?
    private var removePartialOnCancel = false
    private var currentRemaining: Int64 = 0
    private var lastProgressFlush = Date.distantPast
    /// 当前条目是否为剪贴板文本
    private var currentIsText = false
    /// 本次传输中已完成的文本条目（接收完成后进剪贴板）
    private var deliveredTextURLs: [URL] = []

    var onClose: (() -> Void)?

    init(connection: NWConnection, server: TransferServer, sequence: Int) {
        self.connection = connection
        self.server = server
        self.sequence = sequence
        self.queue = DispatchQueue(label: "grandline.inbound.\(sequence)")
    }

    func start() {
        decoder.onEvent = { [weak self] event in
            self?.handle(event)
        }
        decoder.onError = { [weak self] error in
            self?.fail("Protocol error: \(error.localizedDescription)")
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let err):
                self.fail(err.localizedDescription)
            case .cancelled:
                self.cleanup()
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveLoop()
        // 30 秒内没收到 offer 则断开，避免空连接堆积
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.offer == nil else { return }
            self.cancel()
        }
    }

    func cancel() {
        cleanup()
        connection.cancel()
    }

    /// 与 taskID 匹配时中止本会话：标记 cancelled、断连并删除未完成的半截文件
    func abortIfMatches(taskID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard var t = self.task, t.id == taskID, !t.status.isFinished else { return }
            t.status = .cancelled
            t.finishedAt = Date()
            self.task = t
            self.server.emit(t)
            self.removePartialOnCancel = true
            self.cancel()
        }
    }

    // MARK: - 接收

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.decoder.feed(data) }
            if let error {
                self.fail(error.localizedDescription)
                return
            }
            if isComplete {
                self.cleanup()
                return
            }
            self.receiveLoop()
        }
    }

    // MARK: - 帧处理

    private func handle(_ event: FrameDecoder.Event) {
        switch event {
        case .header(let header):
            handleHeader(header)
        case .payload(let chunk):
            write(chunk)
        case .payloadComplete:
            closeCurrentFile()
        }
    }

    private func handleHeader(_ header: MessageHeader) {
        switch header.type {
        case MessageType.offer:
            handleOffer(header)
        case MessageType.item:
            beginItem(header)
        case MessageType.done:
            completeTransfer()
        case MessageType.avatarRequest:
            sendAvatarResponse()
        default:
            break
        }
    }

    /// 回应头像拉取：payload 为 PNG 字节，无头像时回空 payload，随后断开
    private func sendAvatarResponse() {
        let data = (try? Data(contentsOf: AvatarStore.fileURL)) ?? Data()
        var header = MessageHeader(type: MessageType.avatarResponse)
        header.senderID = DeviceInfo.deviceID

        guard var out = try? FrameCodec.encodeHeader(header) else {
            cancel()
            return
        }
        out.append(FrameCodec.payloadLengthHeader(Int64(data.count)))
        out.append(data)

        connection.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.3) { self?.cancel() }
        })
    }

    private func handleOffer(_ header: MessageHeader) {
        guard offer == nil else { return }
        let items = header.items ?? []
        guard !items.isEmpty else {
            sendReject(reason: "No files to receive")
            return
        }

        // PIN 校验（信任设备跳过：白名单语义优先于防陌生人）
        let isTrusted = TrustedPeers.ids.contains(header.senderID)
        let requiredPIN = UserDefaults.standard.string(forKey: "GrandLine.pin") ?? ""
        let pinEnabled = UserDefaults.standard.bool(forKey: "GrandLine.pinEnabled")
        if !isTrusted, pinEnabled, !requiredPIN.isEmpty {
            guard header.pin == requiredPIN else {
                server.log("Rejected \(header.senderName): incorrect PIN")
                sendReject(reason: "Incorrect PIN")
                return
            }
        }

        transferID = header.transferID
        deliveredTextURLs.removeAll()
        let incoming = IncomingOffer(id: header.transferID,
                                     senderName: header.senderName,
                                     senderID: header.senderID,
                                     items: items)
        offer = incoming
        expectedCount = items.count

        let dir = InboundSession.makeInbox(for: header.senderName, transferID: header.transferID)
        senderFolder = dir

        var t = TransferTask(id: header.transferID,
                             peerName: header.senderName,
                             peerID: header.senderID,
                             direction: .inbound,
                             items: items.map { meta in
                                 SharedItem(url: dir.appendingPathComponent(meta.name),
                                            size: meta.size,
                                            isText: meta.kind == ItemKind.text)
                             },
                             totalBytes: incoming.totalBytes,
                             transferredBytes: 0,
                             status: .waitingApproval,
                             startedAt: Date(),
                             finishedAt: nil)
        task = t
        server.emit(t)

        Task { [weak self] in
            guard let self else { return }
            let accepted: Bool
            if isTrusted {
                self.server.log("Auto-accepted trusted ship \(header.senderName)")
                accepted = true
            } else {
                accepted = await self.server.requestApproval(incoming)
            }
            self.queue.async {
                if accepted {
                    self.sendAccept()
                    t.status = .transferring
                    self.task = t
                    self.server.emit(t)
                } else {
                    self.sendReject(reason: "Receiver declined")
                    self.server.log("Declined offer from \(header.senderName)")
                    t.status = .rejected
                    self.server.emit(t)
                    self.queue.asyncAfter(deadline: .now() + 0.3) { self.cancel() }
                }
            }
        }
    }

    private func beginItem(_ header: MessageHeader) {
        guard let offer else { return }
        closeCurrentFile()

        guard let index = header.itemIndex, index >= 0, index < offer.items.count else { return }
        let meta = offer.items[index]
        guard let dir = senderFolder else { return }

        let safeName = PathSafety.sanitize(meta.name)
        let target = PathSafety.uniqueURL(in: dir, name: safeName)

        currentIsText = (meta.kind == ItemKind.text)

        FileManager.default.createFile(atPath: target.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: target) else {
            sendReject(reason: "Cannot write to receive folder")
            return
        }
        currentHandle = handle
        currentFileURL = target
        currentRemaining = meta.size

        // 无内容的空文件：直接算完成
        if meta.size == 0 {
            closeCurrentFile()
        }
    }

    private func write(_ data: Data) {
        guard let handle = currentHandle else { return }
        // 防御：不超过声明长度
        let payload = data.count > Int(currentRemaining) ? data.prefix(Int(currentRemaining)) : data
        do {
            try handle.write(contentsOf: payload)
        } catch {
            fail("Write failed: \(error.localizedDescription)")
            return
        }
        currentRemaining -= Int64(payload.count)
        totalReceived += Int64(payload.count)

        if Date().timeIntervalSince(lastProgressFlush) > 0.15 {
            lastProgressFlush = Date()
            flushProgress()
        }
    }

    private func closeCurrentFile() {
        guard let handle = currentHandle else { return }
        try? handle.close()
        currentHandle = nil
        if currentIsText, let url = currentFileURL {
            deliveredTextURLs.append(url)
        }
        currentIsText = false
        finishedCount += 1
        flushProgress()
    }

    private func flushProgress() {
        guard var t = task else { return }
        t.transferredBytes = totalReceived
        task = t
        server.emit(t)
    }

    private func completeTransfer() {
        guard var t = task else { return }
        if finishedCount < expectedCount {
            // 发送端提前结束但文件未齐，按已收到处理
            server.log("Transfer ended early: \(finishedCount)/\(expectedCount)")
        }
        t.transferredBytes = totalReceived
        t.status = .completed
        t.finishedAt = Date()
        task = t
        server.emit(t)

        sendDone()
        server.log("Received \(finishedCount) file(s) · \(ByteFormatter.string(totalReceived))")
        deliverTextToClipboard()
        queue.asyncAfter(deadline: .now() + 0.4) { self.cancel() }
    }

    /// 把本次传输中的文本条目写入系统剪贴板（货舱中的文件同时保留留档）
    private func deliverTextToClipboard() {
        let urls = deliveredTextURLs
        deliveredTextURLs.removeAll()
        guard !urls.isEmpty else { return }

        let senderName = task?.peerName ?? ""
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            let before = pb.changeCount
            pb.clearContents()
            let snippets = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                .filter { !$0.isEmpty }
            guard !snippets.isEmpty else {
                NSLog("[GrandLine] Clipboard write skipped: no readable text in \(urls.count) item(s)")
                return
            }
            let combined = snippets.joined(separator: "\n")
            let ok = pb.setString(combined, forType: .string)
            NSLog("[GrandLine] Clipboard write \(ok ? "OK" : "FAILED") · changeCount \(before)→\(pb.changeCount) · \(combined.utf8.count) bytes from \(senderName)")
        }
        server.log("Text snippet from \(senderName) copied to clipboard — press ⌘V to paste")
    }

    // MARK: - 发送控制消息

    private func sendAccept() {
        send(MessageHeader(type: MessageType.accept, transferID: transferID))
    }

    private func sendReject(reason: String) {
        send(MessageHeader(type: MessageType.reject, transferID: transferID, reason: reason))
    }

    private func sendDone() {
        var h = MessageHeader(type: MessageType.done)
        h.transferID = transferID
        h.receivedCount = finishedCount
        send(h)
    }

    private func send(_ header: MessageHeader) {
        guard let data = try? FrameCodec.encodeControl(header) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - 收尾

    private func fail(_ reason: String) {
        if var t = task, !t.status.isFinished {
            t.status = .failed(reason)
            t.finishedAt = Date()
            task = t
            server.emit(t)
        }
        server.log("Inbound connection closed: \(reason)")
        cancel()
    }

    private func cleanup() {
        closeCurrentFile()
        if removePartialOnCancel, let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentFileURL = nil
        removePartialOnCancel = false
        onClose?()
    }

    // MARK: - 目录

    private static func makeInbox(for senderName: String, transferID: String) -> URL {
        let root = TransferServer.inboxRoot
        let safeSender = PathSafety.sanitize(senderName)
        let dir = root.appendingPathComponent(safeSender, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
