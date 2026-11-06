import Foundation
import Network

/// 发送端：连接对端、发起投送、流式发送文件内容。
final class TransferClient {

    private let peer: Peer
    private let originalItems: [SharedItem]
    private let pin: String?
    private let transferID = UUID().uuidString

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "grandline.outbound")
    private let decoder = FrameDecoder()

    private var task: TransferTask
    private var prepared: [(url: URL, cleanup: Bool)] = []
    private var currentIndex = 0
    private var settled = false
    private var acceptTimer: DispatchWorkItem?

    /// 供 UI 层引用
    var transferIdentifier: String { transferID }
    var snapshotTask: TransferTask { task }
    var isSettled: Bool { settled }

    var onUpdate: ((TransferTask) -> Void)?

    init(peer: Peer, items: [SharedItem], pin: String?) {
        self.peer = peer
        self.originalItems = items
        self.pin = pin

        let params = NWParameters.tcp
        params.includePeerToPeer = false
        self.connection = NWConnection(to: peer.endpoint, using: params)

        self.task = TransferTask(id: transferID,
                                 peerName: peer.name,
                                 peerID: peer.id,
                                 direction: .outbound,
                                 items: items,
                                 totalBytes: items.reduce(0) { $0 + $1.transferSize },
                                 transferredBytes: 0,
                                 status: .connecting,
                                 startedAt: Date(),
                                 finishedAt: nil)
    }

    func start() {
        decoder.onEvent = { [weak self] event in self?.handle(event) }
        decoder.onError = { [weak self] error in
            self?.finish(.failed("Protocol error: \(error.localizedDescription)"))
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.prepareAndOffer()
            case .failed(let err):
                self.finish(.failed(err.localizedDescription))
            case .waiting(let err):
                // 对端不可达时 NWConnection 会进入 waiting，10 秒后仍未就绪即判定失败
                self.queue.asyncAfter(deadline: .now() + 10) {
                    if !self.settled, self.task.status == .connecting {
                        self.finish(.failed(err.localizedDescription))
                    }
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveLoop()

        // 连接阶段超时
        queue.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.task.status == .connecting || self.task.status == .waitingApproval else { return }
            self.finish(.failed("Connection timed out — check the peer is online and on the same subnet"))
        }
    }

    func cancel() {
        finish(.cancelled)
    }

    // MARK: - 准备与发送 offer

    private func prepareAndOffer() {
        do {
            prepared = try originalItems.map { item in
                let r = try Staging.prepareForTransfer(item)
                return (url: r.url, cleanup: r.cleanup)
            }
        } catch {
            finish(.failed(error.localizedDescription))
            return
        }

        let total = prepared.reduce(Int64(0)) { $0 + FileSize.size(of: $1.url) }
        var t = task
        t.totalBytes = total
        t.status = .waitingApproval
        task = t
        emit()

        let metas = prepared.enumerated().map { index, entry -> ItemMeta in
            var meta = ItemMeta(name: entry.url.lastPathComponent, size: FileSize.size(of: entry.url))
            if originalItems[index].isText {
                meta.kind = ItemKind.text
                // 预览随 offer 内联，让接收弹窗在确认前就能看到内容
                if let s = try? String(contentsOf: entry.url, encoding: .utf8) {
                    meta.preview = String(s.prefix(400))
                }
            }
            return meta
        }
        var header = MessageHeader(type: MessageType.offer)
        header.transferID = transferID
        header.senderName = DeviceInfo.effectiveName
        header.senderID = DeviceInfo.deviceID
        header.items = metas
        if let pin, !pin.isEmpty { header.pin = pin }

        guard let data = try? FrameCodec.encodeControl(header) else {
            finish(.failed("Failed to encode message"))
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failed(error.localizedDescription)) }
        })

        // 等待对方确认的超时
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.task.status == .waitingApproval else { return }
            self.finish(.failed("Timed out waiting for approval"))
        }
        acceptTimer = work
        queue.asyncAfter(deadline: .now() + 120, execute: work)
    }

    // MARK: - 接收

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.decoder.feed(data) }
            if let error {
                if !self.settled { self.finish(.failed(error.localizedDescription)) }
                return
            }
            if isComplete {
                if !self.settled { self.finish(.failed("Peer disconnected")) }
                return
            }
            if !self.settled { self.receiveLoop() }
        }
    }

    private func handle(_ event: FrameDecoder.Event) {
        guard case .header(let header) = event else { return }

        switch header.type {
        case MessageType.accept:
            acceptTimer?.cancel()
            acceptTimer = nil
            sendNextItem()

        case MessageType.reject:
            finish(.rejected, reason: header.reason)

        case MessageType.done:
            finish(.completed)

        case MessageType.error:
            finish(.failed(header.reason ?? "Peer reported an error"))

        default:
            break
        }
    }

    // MARK: - 发送文件

    private func sendNextItem() {
        guard currentIndex < prepared.count else {
            sendDone()
            return
        }

        let entry = prepared[currentIndex]
        let size = FileSize.size(of: entry.url)
        var meta = ItemMeta(name: entry.url.lastPathComponent, size: size)
        if originalItems[currentIndex].isText { meta.kind = ItemKind.text }

        var header = MessageHeader(type: MessageType.item)
        header.transferID = transferID
        header.itemIndex = currentIndex
        header.items = [meta]

        guard let head = try? FrameCodec.encodeHeader(header) else {
            finish(.failed("Failed to encode message"))
            return
        }
        var framed = head
        framed.append(FrameCodec.payloadLengthHeader(size))

        let index = currentIndex
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failed(error.localizedDescription))
                return
            }
            self.streamFile(at: entry.url, itemIndex: index) { result in
                switch result {
                case .success:
                    self.currentIndex += 1
                    self.sendNextItem()
                case .failure(let err):
                    self.finish(.failed(err.localizedDescription))
                }
            }
        })
    }

    private func streamFile(at url: URL, itemIndex: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            completion(.failure(NSError(domain: "GrandLine", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "Cannot read \(url.lastPathComponent)"])))
            return
        }

        var remaining = FileSize.size(of: url)
        if remaining == 0 {
            try? handle.close()
            completion(.success(()))
            return
        }

        let chunkSize = 1 << 20   // 1 MB
        let window = 4
        var inflight = 0
        var finished = false

        func pump() {
            while inflight < window && remaining > 0 {
                let n = Int(min(Int64(chunkSize), remaining))
                guard let data = try? handle.read(upToCount: n), !data.isEmpty else {
                    remaining = 0
                    break
                }
                remaining -= Int64(data.count)
                inflight += 1

                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.queue.async {
                        inflight -= 1
                        if let error {
                            if !finished {
                                finished = true
                                try? handle.close()
                                completion(.failure(error))
                            }
                            return
                        }
                        self.task.transferredBytes += Int64(data.count)
                        self.throttledEmit()

                        if remaining == 0 && inflight == 0 {
                            if !finished {
                                finished = true
                                try? handle.close()
                                completion(.success(()))
                            }
                        } else {
                            pump()
                        }
                    }
                })
            }
        }

        pump()
    }

    private func sendDone() {
        var header = MessageHeader(type: MessageType.done)
        header.transferID = transferID
        guard let data = try? FrameCodec.encodeControl(header) else {
            finish(.completed)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.asyncAfter(deadline: .now() + 0.2) {
                self?.finish(.completed)
            }
        })
    }

    // MARK: - 状态

    private var lastEmit = Date.distantPast

    private func throttledEmit() {
        if Date().timeIntervalSince(lastEmit) > 0.12 {
            lastEmit = Date()
            emit()
        }
    }

    private func emit() {
        let snapshot = task
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private func finish(_ status: TransferStatus, reason: String? = nil) {
        guard !settled else { return }
        settled = true
        acceptTimer?.cancel()

        task.status = status
        task.finishedAt = Date()
        task.transferredBytes = min(task.transferredBytes, task.totalBytes)
        if status == .completed { task.transferredBytes = task.totalBytes }

        let snapshot = task
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }

        // 清理目录打包产生的临时 zip
        for entry in prepared where entry.cleanup {
            try? FileManager.default.removeItem(at: entry.url)
        }
        prepared.removeAll()

        queue.asyncAfter(deadline: .now() + 0.5) { self.connection.cancel() }

        if let reason, case .failed = status {
            NSLog("[GrandLine] Send failed: \(reason)")
        }
    }
}
