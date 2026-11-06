import Foundation
import AppKit
import SystemConfiguration
import UserNotifications

// MARK: - 字节格式化

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    static func rate(_ bps: Double) -> String {
        if bps <= 0 { return "" }
        let mb = bps / 1024 / 1024
        if mb >= 1 { return String(format: "%.1f MB/s", mb) }
        return String(format: "%.0f KB/s", bps / 1024)
    }
}

// MARK: - 文件体积与目录打包

enum FileSize {
    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }
}

enum Staging {
    /// 把目录打包成临时 zip，返回可传输的文件 URL。
    /// 已是普通文件则原样返回；剪贴板文本等临时产物在传输结束后清理。
    static func prepareForTransfer(_ item: SharedItem) throws -> (url: URL, cleanup: Bool) {
        guard item.isDirectory else { return (item.url, item.isText) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GrandLineStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent(item.url.lastPathComponent + ".zip")
        try? FileManager.default.removeItem(at: zip)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--norsrc", "--keepParent", item.url.path, zip.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "GrandLine", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to archive \(item.url.lastPathComponent)"])
        }
        return (zip, true)
    }
}

// MARK: - 文件名安全处理

enum PathSafety {
    /// 剔除路径穿越与非法字符，防止接收端被写入任意位置
    static func sanitize(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "/", with: "_")
        name = name.replacingOccurrences(of: "\0", with: "")
        name = name.replacingOccurrences(of: "..", with: "_..")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Untitled" }
        if name.count > 180 { name = String(name.prefix(180)) }
        return name
    }

    /// 目标目录内生成不冲突的文件名
    static func uniqueURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 1
        while true {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

// MARK: - 系统通知

enum Notifier {
    static func bootstrap() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 主窗口是否可见：可见时界面内已有胶囊进度，无需弹系统通知
    private static var isMainWindowVisible: Bool {
        NSApp?.windows.contains {
            $0.frameAutosaveName == "GrandLineMainWindow" && $0.isVisible
        } ?? false
    }

    /// 入站传输开始（信任设备自动接收，无审批浮层）：立即提示，不等传完。
    /// 窗口可见时只补一声轻响（胶囊已展示进度）；不可见时弹系统通知。
    static func transferIncoming(_ task: TransferTask) {
        let isText = task.items.first?.isText ?? false
        if isMainWindowVisible {
            NSSound(named: "Ping")?.play()
            return
        }
        let content = UNMutableNotificationContent()
        content.sound = .default
        if isText {
            content.title = "Text from \(task.peerName)"
            content.body = "Trusted ship — snippet incoming, will land in clipboard"
        } else {
            content.title = "Receiving from \(task.peerName)"
            let detail = task.items.count == 1
                ? task.items[0].name
                : "\(task.items.count) files"
            content.body = "\(detail) · \(ByteFormatter.string(task.totalBytes))"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 传输完成时提醒；主窗口可见时界面内已有胶囊提示，不打扰
    static func transferCompleted(_ task: TransferTask) {
        guard !isMainWindowVisible else { return }
        let content = UNMutableNotificationContent()
        content.sound = .default
        switch (task.direction, task.items.first?.isText ?? false) {
        case (.inbound, true):
            content.title = "Text from \(task.peerName)"
            content.body = "Snippet arrived — in your clipboard (⌘V to paste)"
        case (.inbound, false):
            content.title = "\(task.peerName) delivered cargo"
            let detail = task.items.count == 1
                ? task.items[0].name
                : "\(task.items.count) files"
            content.body = "\(detail) · \(ByteFormatter.string(task.totalBytes))"
        case (.outbound, _):
            content.title = "Cargo delivered"
            content.body = "Sent to \(task.peerName) · \(ByteFormatter.string(task.totalBytes))"
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - 信任设备白名单

enum TrustedPeers {
    private static let key = "GrandLine.trustedPeers"
    private static let nameKey = "GrandLine.trustedPeerNames"

    static var ids: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static var entries: [(id: String, name: String)] {
        let d = UserDefaults.standard
        let ids = d.stringArray(forKey: key) ?? []
        let names = d.dictionary(forKey: nameKey) as? [String: String] ?? [:]
        return ids.map { (id: $0, name: names[$0] ?? $0) }
    }

    static func trust(id: String, name: String) {
        guard !id.isEmpty else { return }
        let d = UserDefaults.standard
        var list = d.stringArray(forKey: key) ?? []
        if !list.contains(id) { list.append(id) }
        d.set(list, forKey: key)
        var names = d.dictionary(forKey: nameKey) as? [String: String] ?? [:]
        names[id] = name
        d.set(names, forKey: nameKey)
    }

    static func remove(id: String) {
        let d = UserDefaults.standard
        d.set((d.stringArray(forKey: key) ?? []).filter { $0 != id }, forKey: key)
        var names = d.dictionary(forKey: nameKey) as? [String: String] ?? [:]
        names.removeValue(forKey: id)
        d.set(names, forKey: nameKey)
    }
}

// MARK: - 传输次数（默认排序权重）
//
// 上百台设备同处一个广播域时，默认顺序应当反映「我实际找过谁」：
// 成功传输次数越多越靠前。计数按设备 ID 落盘，设备改名不影响权重；
// 设备暂时离线也不清零，重新出现时仍保持原有位置。
//
// 与「最近投送」相比，累计次数只增不减，是单调量：
// 位置会随使用逐步靠前，但不会因为投送别的设备而突然跳走。

enum TransferCounts {
    private static let key = "GrandLine.transferCounts"

    static var all: [String: Int] {
        // 兼容两种来源：App 自己写的是真整数，外部工具（defaults CLI）可能写成字符串
        let raw = UserDefaults.standard.object(forKey: key) as? [String: Any] ?? [:]
        return raw.compactMapValues { value in
            (value as? NSNumber)?.intValue ?? Int(value as? String ?? "")
        }
    }

    static func bump(id: String) {
        guard !id.isEmpty else { return }
        var counts = all
        counts[id, default: 0] += 1
        UserDefaults.standard.set(counts, forKey: key)
    }
}

// MARK: - 固定 IP 直连（手动对端）

enum ManualPeers {
    struct Entry: Identifiable, Equatable {
        let id: String
        let host: String
        let port: UInt16
    }

    private static let key = "GrandLine.manualPeers"

    static var entries: [Entry] {
        (UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []).compactMap { dict in
            guard let host = dict["host"] as? String, !host.isEmpty,
                  let port = dict["port"] as? Int, (1...65535).contains(port) else { return nil }
            return Entry(id: "manual-\(host):\(port)", host: host, port: UInt16(port))
        }
    }

    static func add(host: String, port: UInt16) {
        var list = UserDefaults.standard.array(forKey: key) as? [[String: Any]] ?? []
        let id = "manual-\(host):\(port)"
        guard !list.contains(where: { ($0["host"] as? String) == host && ($0["port"] as? Int) == Int(port) }) else { return }
        list.append(["host": host, "port": Int(port)])
        UserDefaults.standard.set(list, forKey: key)
    }

    static func remove(id: String) {
        let list = entries.filter { $0.id != id }
            .map { ["host": $0.host, "port": Int($0.port)] as [String: Any] }
        UserDefaults.standard.set(list, forKey: key)
    }
}

// MARK: - 剪贴板

enum ClipboardBridge {
    /// 当前剪贴板里的非空文本；非文本内容（图片、文件引用等）返回 nil
    static var text: String? {
        guard let s = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : s
    }

    static var hasText: Bool { text != nil }
}

// MARK: - 本机信息

enum DeviceInfo {
    /// AppState 在昵称变更时写入，保证广播与投送立即使用新名字，无需重启
    static var runtimeName: String?

    /// 系统电脑名（“设置 → 通用 → 共享”里的名字）
    static var computerName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.replacingOccurrences(of: ".local", with: "")
    }

    /// 用户自定义昵称；未设置或为空白时返回 nil
    static var customName: String? {
        guard let v = UserDefaults.standard.string(forKey: "GrandLine.displayName") else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static var displayName: String {
        if let v = ProcessInfo.processInfo.environment["GRANDLINE_NAME"], !v.isEmpty { return v }
        return customName ?? computerName
    }

    /// 运行期对外展示的名字（昵称变更后立即更新）
    static var effectiveName: String { runtimeName ?? displayName }

    static var model: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var chars = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    /// 稳定的设备标识，用于排除自身与去重
    static var deviceID: String {
        // 测试/多实例场景可通过环境变量隔离
        if let v = ProcessInfo.processInfo.environment["GRANDLINE_DEVICE_ID"], !v.isEmpty { return v }
        let key = "GrandLine.deviceID"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = UUID().uuidString
        UserDefaults.standard.set(v, forKey: key)
        return v
    }

    static var avatarSymbol: String { "laptopcomputer" }
}

// MARK: - 头像存储

enum AvatarStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("GrandLine", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("avatar.png") }
    /// 用户选择的原始图片副本；显示管线改进后可随时重新规范化
    static var rawFileURL: URL { directory.appendingPathComponent("avatar-original.png") }

    static func load() -> NSImage? {
        // 有原图时用最新管线重新规范化（裁边距等改进自动生效）
        if let raw = NSImage(contentsOf: rawFileURL), let fresh = normalized(raw) {
            save(fresh)
            return fresh
        }
        guard let data = try? Data(contentsOf: fileURL), let stored = NSImage(data: data) else { return nil }
        // 旧版本落盘的头像可能带透明留白，读取时顺手补裁
        if let improved = trimmedToContent(stored, side: 256) {
            save(improved)
            return improved
        }
        return stored
    }

    /// 从磁盘导入头像：保留原图 → 居中裁方 → 裁透明边距 → 压到 256px
    static func importImage(from url: URL) -> NSImage? {
        guard let raw = NSImage(contentsOf: url), let rawPng = pngData(from: raw) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? rawPng.write(to: rawFileURL, options: .atomic)
        guard let normalizedImage = normalized(raw) else { return nil }
        save(normalizedImage)
        return normalizedImage
    }

    static func save(_ image: NSImage) {
        guard let png = pngData(from: image) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: fileURL, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: rawFileURL)
    }

    /// 头像版本号：PNG 内容的 djb2 哈希，无头像时为 0。
    /// 随信标广播，对端据此判断是否需要重新拉取。
    static func version() -> Int {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return 0 }
        var h: UInt32 = 5381
        for b in data { h = (h &* 33) &+ UInt32(b) }
        return Int(h)
    }

    /// 居中裁成正方形并缩放到 256px，避免几十 MB 的原图拖慢渲染与磁盘；
    /// 随后裁掉四周全透明边距（App 图标类素材自带留白，不裁会导致头像缩在圆框中间）。
    static func normalized(_ image: NSImage, side: Int = 256) -> NSImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

        let src = image.size
        let edge = min(src.width, src.height)
        let crop = NSRect(x: (src.width - edge) / 2, y: (src.height - edge) / 2,
                          width: edge, height: edge)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: crop, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let square = NSImage(size: NSSize(width: side, height: side))
        square.addRepresentation(rep)

        // 裁掉透明边距后重新铺满画布；无需裁切时保持原样
        return trimmedToContent(square, side: side) ?? square
    }

    /// 检测位图 alpha 通道的内容包围盒，把四周全透明边距裁掉并放大铺满画布。
    /// 不需要裁切（无 alpha 或内容已顶满）时返回 nil。
    private static func trimmedToContent(_ image: NSImage, side: Int) -> NSImage? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.03 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              minX > 0 || minY > 0 || maxX < w - 1 || maxY < h - 1 else { return nil }

        // 位图行 0 在顶部，NSImage 坐标系 y 向上
        let content = NSRect(x: CGFloat(minX),
                             y: CGFloat(h - 1 - maxY),
                             width: CGFloat(maxX - minX + 1),
                             height: CGFloat(maxY - minY + 1))

        guard let outRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: outRep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: content, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: side, height: side))
        out.addRepresentation(outRep)
        return out
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - 本机地址展示

enum NetworkInfo {

    /// 枚举本机所有已启用、非回环的 IPv4 接口，附带系统层面的类型名
    static func interfaces() -> [NetInterface] {
        let names = interfaceDisplayNames()
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }

        var out: [NetInterface] = []
        var ptr = first
        while true {
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            if isUp, !isLoopback,
               let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let bsd = String(cString: ptr.pointee.ifa_name)
                let ip = numericHost(sa)

                var mask = "255.255.255.255"
                if let nm = ptr.pointee.ifa_netmask, nm.pointee.sa_family == UInt8(AF_INET) {
                    mask = numericHost(nm) ?? mask
                }

                if let ip, !ip.isEmpty, ip != "0.0.0.0" {
                    out.append(NetInterface(id: bsd,
                                            name: names[bsd] ?? bsd.uppercased(),
                                            ip: ip,
                                            netmask: mask,
                                            broadcast: broadcastAddress(ip: ip, netmask: mask)))
                }
            }
            guard let next = ptr.pointee.ifa_next else { break }
            ptr = next
        }

        // 稳定的展示顺序：以太网优先
        return out.sorted { lhs, rhs in
            let l = lhs.name == "Ethernet" ? 0 : 1
            let r = rhs.name == "Ethernet" ? 0 : 1
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    /// 通过 SystemConfiguration 拿到 en0 → "Wi-Fi" / "Ethernet" 这类人类可读名称
    private static func interfaceDisplayNames() -> [String: String] {
        var map: [String: String] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as NSArray? else { return map }
        for case let item as SCNetworkInterface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(item) as String? else { continue }
            if let display = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? {
                map[bsd] = display
            } else if let type = SCNetworkInterfaceGetInterfaceType(item) as String? {
                if type == (kSCNetworkInterfaceTypeEthernet as String) {
                    map[bsd] = "Ethernet"
                } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                    map[bsd] = "Wi-Fi"
                }
            }
        }
        return map
    }

    static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        guard r == 0 else { return nil }
        return String(cString: host)
    }

    static func broadcastAddress(ip: String, netmask: String) -> String? {
        let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = netmask.split(separator: ".").compactMap { UInt32($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return nil }

        let ipVal = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let maskVal = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]
        guard maskVal != 0xFFFFFFFF else { return nil }

        let bcast = ipVal | ~maskVal
        return "\((bcast >> 24) & 0xFF).\((bcast >> 16) & 0xFF).\((bcast >> 8) & 0xFF).\(bcast & 0xFF)"
    }

    /// 判断某个来源 IP 是否落在指定接口的网段内
    static func ip(_ ip: String, belongsTo iface: NetInterface) -> Bool {
        let a = ip.split(separator: ".").compactMap { UInt32($0) }
        let b = iface.ip.split(separator: ".").compactMap { UInt32($0) }
        let m = iface.netmask.split(separator: ".").compactMap { UInt32($0) }
        guard a.count == 4, b.count == 4, m.count == 4 else { return false }
        for i in 0..<4 where (a[i] & m[i]) != (b[i] & m[i]) {
            return false
        }
        return true
    }

    static func localIPv4Addresses() -> [(iface: String, ip: String)] {
        interfaces().map { ($0.id, $0.ip) }
    }

    /// 用于 UI 展示的主地址，优先私有网段
    static var primaryAddress: String {
        let list = interfaces().map { $0.ip }
        let preferred = list.first { $0.hasPrefix("192.168.") }
            ?? list.first { $0.hasPrefix("10.") }
            ?? list.first { $0.hasPrefix("172.") }
            ?? list.first
        return preferred ?? "No network"
    }
}
