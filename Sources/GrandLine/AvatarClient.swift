import Foundation
import Network
import AppKit

/// 头像拉取：连接对端 TCP 端口，发送 avatarReq，接收 avatarResp 的 PNG payload。
/// 一次连接只取一次，成功 / 失败 / 超时都通过 onFinish 回调（nil 表示失败）。
final class AvatarClient {

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "grandline.avatar.fetch")
    private let decoder = FrameDecoder()

    private var payload = Data()
    private var settled = false

    var onFinish: ((NSImage?) -> Void)?

    init(endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        self.connection = NWConnection(to: endpoint, using: params)
    }

    func start() {
        decoder.onEvent = { [weak self] event in self?.handle(event) }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed:
                self.finish(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveLoop()

        // 6 秒拿不到头像即放弃，冷却期内不再重试
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.finish(nil)
        }
    }

    func cancel() {
        finish(nil)
        connection.cancel()
    }

    // MARK: - 请求与接收

    private func sendRequest() {
        var header = MessageHeader(type: MessageType.avatarRequest)
        header.senderID = DeviceInfo.deviceID
        guard let data = try? FrameCodec.encodeControl(header) else {
            finish(nil)
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish(nil) }
        })
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.decoder.feed(data) }
            if error != nil { self.finish(nil); return }
            if isComplete { self.finish(nil); return }
            if !self.settled { self.receiveLoop() }
        }
    }

    private func handle(_ event: FrameDecoder.Event) {
        switch event {
        case .header(let header):
            // 对端拒绝或报错都视为拉取失败
            if header.type != MessageType.avatarResponse { finish(nil) }
        case .payload(let chunk):
            // 上限保护：头像规范化后是 256px PNG，正常不超过几百 KB
            guard payload.count < 1 << 20 else { finish(nil); return }
            payload.append(chunk)
        case .payloadComplete:
            finish(payload.isEmpty ? nil : NSImage(data: payload))
        }
    }

    private func finish(_ image: NSImage?) {
        guard !settled else { return }
        settled = true
        connection.cancel()
        onFinish?(image)
    }
}
