import Foundation
import Network
import AppKit

// MARK: - 广播载荷

struct BeaconPayload: Codable {
    var id: String
    var name: String
    var model: String
    var port: UInt16
    var pin: Bool
    var version: Int = 1
    /// 头像版本号（AvatarStore.version()），0 或缺省表示无头像。
    /// 旧版本对端会忽略该字段，双向兼容。
    var av: Int? = nil
}

/// 基于 UDP 广播的设备发现，支持按网卡（网段）独立收发。
///
/// 为什么不用 Bonjour：`NWBrowser` 在部分系统版本上返回的 metadata 为 `.none`，
/// 拿不到 TXT 记录；而 TXT 里恰好承载着设备 ID 与端口。
/// UDP 广播另有两点好处：
///   1. 对端 IP 直接取自数据包源地址，多网卡场景不会选错地址；
///   2. 不依赖 mDNSResponder，在网络策略禁用组播的受控环境中依然可用。
final class DiscoveryService {

    static let beaconPort: UInt16 = 47820

    /// macOS 私有 setsockopt：把 socket 固定到某个接口出站
    private static let IP_BOUND_IF: Int32 = 25

    private static let beaconInterval: TimeInterval = 1.5
    private static let peerTimeout: TimeInterval = 6.0
    /// 列表回写主线程的合并窗口：上百台设备时每秒可达上百个心跳包，
    /// 逐包 publish 会让主线程反复重建数组并触发整页 diff。
    private static let publishInterval: TimeInterval = 0.2

    var onPeersChanged: (([Peer]) -> Void)?

    private let queue = DispatchQueue(label: "grandline.discovery")
    private var listenSocket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?

    /// 每个启用网卡一个发送 socket，出站流量互不干扰
    private var sendSockets: [String: Int32] = [:]
    /// 当前参与广播与接收过滤的网卡
    private var activeInterfaces: [NetInterface] = []

    private var peers: [String: Peer] = [:]
    private var advertisement: BeaconPayload?
    /// 待执行的合并发布；窗口期内到达的包只标记一次
    private var pendingPublish: DispatchWorkItem?

    // 头像缓存：peerID -> 已拉取的图片与对应版本
    private var avatarCache: [String: NSImage] = [:]
    private var fetchedVersions: [String: Int] = [:]
    private var inflightAvatars: Set<String> = []
    private var fetchCooldown: [String: Date] = [:]
    private var avatarClients: [String: AvatarClient] = [:]

    // MARK: - 生命周期

    func start(port: UInt16, pinEnabled: Bool, name: String) {
        stop()
        advertisement = BeaconPayload(id: DeviceInfo.deviceID,
                                      name: name,
                                      model: DeviceInfo.model,
                                      port: port,
                                      pin: pinEnabled,
                                      av: AvatarStore.version())
        guard openListenSocket() else { return }
        startTimer()
        NSLog("[GrandLine] Discovery started on UDP \(Self.beaconPort) as \(name)")
    }

    /// 昵称等身份信息变化时即时更新广播内容，无需重启服务
    func updateAdvertisement(name: String? = nil, port: UInt16? = nil, pinEnabled: Bool? = nil, avatarVersion: Int? = nil) {
        if let name { advertisement?.name = name }
        if let port { advertisement?.port = port }
        if let pinEnabled { advertisement?.pin = pinEnabled }
        if let avatarVersion { advertisement?.av = avatarVersion }
    }

    /// 由上层在网卡开关变化时调用；会重建发送 socket
    func setEnabledInterfaces(_ list: [NetInterface]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeInterfaces = list
            self.rebuildSendSockets()
            NSLog("[GrandLine] Active interfaces: \(list.map { "\($0.id)(\($0.ip))" }.joined(separator: ", "))")
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        timer?.cancel()
        timer = nil
        pendingPublish?.cancel()
        pendingPublish = nil
        if listenSocket >= 0 {
            close(listenSocket)
            listenSocket = -1
        }
        for (_, fd) in sendSockets { close(fd) }
        sendSockets.removeAll()
        activeInterfaces.removeAll()
        peers.removeAll()
        for (_, c) in avatarClients { c.cancel() }
        avatarClients.removeAll()
        inflightAvatars.removeAll()
        publish()
    }

    // MARK: - 发送 socket

    private func rebuildSendSockets() {
        for (_, fd) in sendSockets { close(fd) }
        sendSockets.removeAll()

        for iface in activeInterfaces {
            guard iface.broadcast != nil else { continue }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }

            var yes: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, size)

            // 关键：把出站流量钉死在该网卡上，否则多网卡会全部走默认路由
            var index = if_nametoindex(iface.id)
            if index != 0 {
                setsockopt(fd, IPPROTO_IP, Self.IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
            }

            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            sendSockets[iface.id] = fd
        }
    }

    // MARK: - 接收 socket

    private func openListenSocket() -> Bool {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            NSLog("[GrandLine] Cannot create UDP socket")
            return false
        }

        var yes: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, size)
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, size)
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &yes, size)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.beaconPort.bigEndian
        addr.sin_addr.s_addr = 0

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            NSLog("[GrandLine] UDP \(Self.beaconPort) bind failed, errno=\(errno)")
            close(sock)
            return false
        }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        listenSocket = sock

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.drainIncoming() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.listenSocket, fd >= 0 { close(fd) }
        }
        src.resume()
        readSource = src
        return true
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.beaconInterval)
        t.setEventHandler { [weak self] in
            self?.sendBeacon()
            self?.expirePeers()
        }
        t.resume()
        timer = t
    }

    // MARK: - 发送

    private func sendBeacon() {
        guard let adv = advertisement,
              let payload = try? JSONEncoder().encode(adv) else { return }

        for iface in activeInterfaces {
            guard let bcast = iface.broadcast,
                  let fd = sendSockets[iface.id] else { continue }

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Self.beaconPort.bigEndian
            addr.sin_addr.s_addr = inet_addr(bcast)

            _ = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    payload.withUnsafeBytes { raw in
                        sendto(fd, raw.baseAddress, raw.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // MARK: - 接收

    private func drainIncoming() {
        var buffer = [UInt8](repeating: 0, count: 2048)

        while true {
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(listenSocket, &buffer, buffer.count, 0, sa, &addrLen)
                }
            }
            guard n > 0 else { return }

            let data = Data(bytes: buffer, count: n)
            guard let beacon = try? JSONDecoder().decode(BeaconPayload.self, from: data) else { continue }
            guard beacon.id != DeviceInfo.deviceID, beacon.port != 0 else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = getnameinfo(sa, addrLen, &hostBuf, socklen_t(hostBuf.count), nil, 0, NI_NUMERICHOST)
                }
            }
            let host = String(cString: hostBuf)
            guard !host.isEmpty, host != "0.0.0.0" else { continue }

            // 只接受来自「已启用网段」的广播
            guard activeInterfaces.contains(where: { NetworkInfo.ip(host, belongsTo: $0) }) else { continue }

            let version = beacon.av ?? 0

            if var existing = peers[beacon.id] {
                // 同一设备可能从多条链路被看到，保留首次发现的地址，避免来回抖动；
                // 但名称 / PIN 状态 / 端口要跟随最新心跳，改名才能即时生效
                existing.lastSeen = Date()
                existing.name = beacon.name
                existing.model = beacon.model
                existing.requiresPIN = beacon.pin
                existing.avatarVersion = version
                existing.avatar = cachedAvatar(peerID: beacon.id, version: version)
                peers[beacon.id] = existing
            } else {
                peers[beacon.id] = Peer(id: beacon.id,
                                        name: beacon.name,
                                        model: beacon.model,
                                        endpoint: .hostPort(host: NWEndpoint.Host(host),
                                                            port: NWEndpoint.Port(rawValue: beacon.port) ?? .any),
                                        host: host,
                                        port: beacon.port,
                                        requiresPIN: beacon.pin,
                                        lastSeen: Date(),
                                        avatarVersion: version,
                                        avatar: cachedAvatar(peerID: beacon.id, version: version))
            }

            maybeFetchAvatar(peerID: beacon.id, host: host, port: beacon.port, version: version)
            schedulePublish()
        }
    }

    // MARK: - 头像同步

    /// 版本匹配时返回缓存的头像；未拉取或版本过旧返回 nil
    private func cachedAvatar(peerID: String, version: Int) -> NSImage? {
        guard version != 0, fetchedVersions[peerID] == version else { return nil }
        return avatarCache[peerID]
    }

    /// 信标带出的头像版本与本地缓存不一致时，向对端 TCP 端口发起拉取。
    /// 用 in-flight 去重 + 失败冷却，避免每 1.5s 的心跳反复打连接。
    private func maybeFetchAvatar(peerID: String, host: String, port: UInt16, version: Int) {
        guard version != 0,
              fetchedVersions[peerID] != version,
              !inflightAvatars.contains(peerID),
              (fetchCooldown[peerID] ?? .distantPast) < Date(),
              port != 0,
              let epPort = NWEndpoint.Port(rawValue: port) else { return }

        inflightAvatars.insert(peerID)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: epPort)
        let client = AvatarClient(endpoint: endpoint)
        avatarClients[peerID] = client
        NSLog("[GrandLine] Fetching avatar from \(peerID) (version \(version))")

        client.onFinish = { [weak self] image in
            guard let self else { return }
            self.queue.async {
                self.avatarClients.removeValue(forKey: peerID)
                self.inflightAvatars.remove(peerID)
                guard let image else {
                    // 拉取失败：冷却 15 秒后随下一次心跳重试
                    self.fetchCooldown[peerID] = Date().addingTimeInterval(15)
                    return
                }
                self.avatarCache[peerID] = image
                self.fetchedVersions[peerID] = version
                // 对端可能已经改名 / 过期，只在仍可见时回填
                if var p = self.peers[peerID], p.avatarVersion == version {
                    p.avatar = image
                    self.peers[peerID] = p
                }
                self.publish()
            }
        }
        client.start()
    }

    // MARK: - 过期清理

    private func expirePeers() {
        let cutoff = Date().addingTimeInterval(-Self.peerTimeout)
        let before = peers.count
        peers = peers.filter { $0.value.lastSeen > cutoff }
        if peers.count != before { publish() }
    }

    private func publish() {
        let list = peers.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?(list)
        }
    }

    /// 合并发布：窗口期内只保留一个待执行任务，后续到达的包直接复用
    private func schedulePublish() {
        guard pendingPublish == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPublish = nil
            self.publish()
        }
        pendingPublish = work
        queue.asyncAfter(deadline: .now() + Self.publishInterval, execute: work)
    }
}
