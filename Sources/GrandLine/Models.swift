import Foundation
import Network
import AppKit

// MARK: - 传输方向

enum TransferDirection {
    case inbound
    case outbound
}

// MARK: - 传输状态

enum TransferStatus: Equatable {
    case waitingApproval
    case connecting
    case transferring
    case completed
    case rejected
    case cancelled
    case failed(String)

    var isFinished: Bool {
        switch self {
        case .completed, .rejected, .cancelled, .failed: return true
        default: return false
        }
    }

    var displayText: String {
        switch self {
        case .waitingApproval: return "Awaiting reply"
        case .connecting: return "Making way"
        case .transferring: return "Under way"
        case .completed: return "Arrived"
        case .rejected: return "Turned away"
        case .cancelled: return "Cancelled"
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}

// MARK: - 待发送条目

struct SharedItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    /// 目录会被 ditto 打包成 zip 后传输，这里记录原始是目录
    let isDirectory: Bool
    /// 剪贴板文本快传：内容是临时 txt 文件，接收端进剪贴板而非仅落盘
    var isText: Bool
    /// 实际参与传输的文件大小（目录为打包后的 zip 大小，打包后回填）
    var transferSize: Int64

    var name: String { url.lastPathComponent }

    /// 展示用大小
    var displaySize: String { ByteFormatter.string(transferSize) }

    init(url: URL, isText: Bool = false) {
        self.url = url
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        self.isDirectory = isDir.boolValue
        self.isText = isText
        self.transferSize = FileSize.size(of: url)
    }

    /// 用于「接收端」按声明尺寸构造条目（不做磁盘探测）
    init(url: URL, size: Int64, isText: Bool = false) {
        self.url = url
        self.isDirectory = false
        self.isText = isText
        self.transferSize = size
    }
}

// MARK: - 发现的设备

struct Peer: Identifiable, Hashable {
    let id: String
    var name: String
    var model: String
    var endpoint: NWEndpoint
    var host: String
    var port: UInt16
    var requiresPIN: Bool
    var lastSeen: Date
    /// 对端广播的头像版本（0 表示无头像）；与本地缓存版本一致时 avatar 有效
    var avatarVersion: Int = 0
    /// 已拉取到的对端头像
    var avatar: NSImage? = nil

    static func == (lhs: Peer, rhs: Peer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - 传输任务

struct TransferTask: Identifiable {
    let id: String
    var peerName: String
    /// 对端设备 ID：重发时优先按它找回目标（名字可能重复）
    var peerID: String = ""
    var direction: TransferDirection
    var items: [SharedItem]
    var totalBytes: Int64
    var transferredBytes: Int64
    var status: TransferStatus
    var startedAt: Date
    var finishedAt: Date?

    var progress: Double {
        guard totalBytes > 0 else { return status == .completed ? 1 : 0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    var speedText: String {
        guard let end = finishedAt ?? Optional(Date()), status == .transferring else { return "" }
        let elapsed = max(0.001, end.timeIntervalSince(startedAt))
        let bps = Double(transferredBytes) / elapsed
        return ByteFormatter.rate(bps)
    }

    var remainingText: String {
        guard status == .transferring, totalBytes > transferredBytes else { return "" }
        let elapsed = max(0.001, Date().timeIntervalSince(startedAt))
        let bps = Double(transferredBytes) / elapsed
        guard bps > 1 else { return "" }
        let remain = Double(totalBytes - transferredBytes) / bps
        if remain < 1 { return "almost done" }
        if remain < 60 { return "~\(Int(remain))s left" }
        return "~\(Int(remain / 60)) min left"
    }
}

// MARK: - 网络接口（网段）

struct NetInterface: Identifiable, Hashable {
    let id: String          // BSD 名称，如 en1
    let name: String        // 类型名，如 Ethernet / Wi-Fi
    let ip: String
    let netmask: String
    let broadcast: String?

    /// 例如 192.168.0.0/24
    var subnetLabel: String {
        let ipParts = ip.split(separator: ".").compactMap { UInt8($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt8($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return ip }
        let net = zip(ipParts, maskParts).map { $0 & $1 }
        let bits = maskParts.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(net.map(String.init).joined(separator: "."))/\(bits)"
    }

    var symbol: String {
        switch name {
        case "Wi-Fi": return "wifi"
        case "Ethernet": return "cable.connector"
        default: return "network"
        }
    }
}

// MARK: - 接收请求（待用户确认）

struct IncomingOffer: Identifiable {
    let id: String
    let senderName: String
    let senderID: String
    let items: [ItemMeta]
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
}

// MARK: - 线协议消息

struct ItemMeta: Codable, Identifiable {
    var id: String { name + String(size) }
    var name: String
    var size: Int64
    /// "text" 表示剪贴板文本条目；nil / 其他表示普通文件
    var kind: String? = nil
    /// 文本条目随 offer 携带的预览片段（截断），供接收弹窗展示
    var preview: String? = nil
}

enum ItemKind {
    static let text = "text"
}

struct MessageHeader: Codable {
    var type: String
    var transferID: String = ""
    var senderName: String = ""
    var senderID: String = ""
    var pin: String?
    var items: [ItemMeta]?
    var itemIndex: Int?
    var reason: String?
    var receivedCount: Int?
}

enum MessageType {
    static let offer = "offer"
    static let accept = "accept"
    static let reject = "reject"
    static let item = "item"
    static let done = "done"
    static let error = "error"
    // 头像同步：请求方发 avatarReq，对端回 avatarResp（payload 为 PNG 字节，空 payload 表示无头像）
    static let avatarRequest = "avatarReq"
    static let avatarResponse = "avatarResp"
}
