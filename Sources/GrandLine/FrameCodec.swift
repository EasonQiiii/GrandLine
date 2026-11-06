import Foundation

/// 线协议帧格式（统一，控制消息 payload 长度为 0）：
///   [4B 大端 header 长度][header JSON]
///   [8B 大端 payload 长度][payload 原始字节...]
enum FrameCodec {
    static func encodeHeader(_ header: MessageHeader) throws -> Data {
        let json = try JSONEncoder().encode(header)
        var out = Data(capacity: json.count + 4)
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    static func payloadLengthHeader(_ length: Int64) -> Data {
        var v = UInt64(length).bigEndian
        return Data(bytes: &v, count: 8)
    }

    /// 一次性编码「无 payload 的控制消息」
    static func encodeControl(_ header: MessageHeader) throws -> Data {
        var d = try encodeHeader(header)
        d.append(payloadLengthHeader(0))
        return d
    }
}

/// 增量解析器：把 TCP 字节流还原为「控制消息」与「payload 分块」两类事件。
/// payload 到达即刻以 chunk 形式抛出，不在内存中整体驻留。
final class FrameDecoder {

    enum Event {
        case header(MessageHeader)
        case payload(Data)
        case payloadComplete
    }

    var onEvent: ((Event) -> Void)?
    var onError: ((Error) -> Void)?

    private var buffer = Data()
    private var state: State = .headerLength
    private var headerLength: Int = 0

    private enum State {
        case headerLength
        case headerBody
        case payloadLength
        case payload(Int64)
    }

    func feed(_ data: Data) {
        buffer.append(data)
        drain()
    }

    private func drain() {
        var progressed = true
        while progressed {
            progressed = false

            switch state {
            case .headerLength:
                guard buffer.count >= 4 else { return }
                headerLength = Int(readUInt32BE(0))
                consume(4)
                if headerLength == 0 {
                    // 空 header 非法，跳过
                    state = .headerLength
                } else {
                    state = .headerBody
                }
                progressed = true

            case .headerBody:
                guard buffer.count >= headerLength else { return }
                let json = buffered(headerLength)
                consume(headerLength)

                do {
                    let header = try JSONDecoder().decode(MessageHeader.self, from: json)
                    onEvent?(.header(header))
                } catch {
                    onError?(error)
                    return
                }
                state = .payloadLength
                progressed = true

            case .payloadLength:
                guard buffer.count >= 8 else { return }
                let v = readUInt64BE(0)
                consume(8)
                if v == 0 {
                    onEvent?(.payloadComplete)
                    state = .headerLength
                } else {
                    state = .payload(Int64(v))
                }
                progressed = true

            case .payload(let remaining):
                if buffer.isEmpty { return }
                let n = min(Int64(buffer.count), remaining)
                let chunk = buffered(Int(n))
                consume(Int(n))
                onEvent?(.payload(chunk))
                if n == remaining {
                    onEvent?(.payloadComplete)
                    state = .headerLength
                } else {
                    state = .payload(remaining - n)
                }
                progressed = true
            }
        }
    }

    // MARK: - 缓冲区操作

    private func buffered(_ n: Int) -> Data {
        let start = buffer.startIndex
        return buffer.subdata(in: start..<(start + n))
    }

    private func consume(_ n: Int) {
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + n))
    }

    private func readUInt32BE(_ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(buffer[buffer.startIndex + offset + i]) }
        return v
    }

    private func readUInt64BE(_ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(buffer[buffer.startIndex + offset + i]) }
        return v
    }
}
