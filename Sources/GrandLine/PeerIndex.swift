import Foundation

// MARK: - 设备检索
//
// 上百台设备同处一个广播域时，「按名字排序后肉眼扫」不再成立，检索成为主路径。
// 这里只做纯计算，不持有状态：AppState 缓存结果，View 直接读。

enum PeerSearch {

    /// 归一化：大小写、重音、全半角都抹平后再比较
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: .current)
    }

    /// 查询串切成若干 token，空格与逗号都可作分隔
    static func tokens(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 多 token 之间是「且」：全部命中才算匹配，字段之间是「或」
    static func matches(_ peer: Peer, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        let haystack = [peer.name, peer.model, peer.host].map(normalize)
        return tokens.allSatisfy { token in
            haystack.contains { $0.contains(token) }
        }
    }

    /// 匹配度：0 名字前缀 > 1 名字包含 > 2 机型命中 > 3 仅 IP 命中。
    /// 取各 token 中最差的一档，保证多个 token 时排序仍有意义。
    static func score(_ peer: Peer, tokens: [String]) -> Int {
        guard !tokens.isEmpty else { return 0 }
        let name = normalize(peer.name)
        let model = normalize(peer.model)
        var worst = 0
        for token in tokens {
            let s: Int
            if name.hasPrefix(token) {
                s = 0
            } else if name.contains(token) {
                s = 1
            } else if model.contains(token) {
                s = 2
            } else {
                s = 3
            }
            worst = max(worst, s)
        }
        return worst
    }

    /// IP 末段，用于卡片上与同名设备区分
    static func shortHost(_ host: String) -> String {
        host.split(separator: ".").last.map(String.init) ?? host
    }

    /// 出现重名的名字集合：重名时卡片需要补完整 IP 才能分辨
    static func duplicateNames(_ list: [Peer]) -> Set<String> {
        var seen = Set<String>()
        var dup = Set<String>()
        for peer in list where !seen.insert(peer.name).inserted {
            dup.insert(peer.name)
        }
        return dup
    }
}

// MARK: - IP 排序键
//
// 名字相同时（机房里常见的一排同名机器）必须有确定性的次级键，
// 否则排序结果随字典遍历顺序抖动，卡片位置每 1.5 秒跳一次。

enum IPKey {

    /// IPv4 转可比较的整数；非法地址回落到最大值，保证全序仍然成立
    static func value(_ host: String) -> UInt64 {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return .max }
        var v: UInt64 = 0
        for part in parts {
            guard let n = UInt64(part), n <= 255 else { return .max }
            v = (v << 8) | n
        }
        return v
    }
}
