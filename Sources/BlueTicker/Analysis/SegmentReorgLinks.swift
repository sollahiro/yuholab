// 複数対複数の再編（regroup）の旧区分 → 新区分の対応。区分名と segment_key だけで決まる組を拾う。
// 会社や業種の語の一覧は持たない。金額は使わないし、組み替えもしない。決められない行には組を作らない。

import Foundation

public struct SegmentReorgLink: Equatable, Sendable {
    public var fromKey: String
    public var toKey: String
    public var basis: String

    public init(fromKey: String, toKey: String, basis: String) {
        self.fromKey = fromKey
        self.toKey = toKey
        self.basis = basis
    }
}

public enum SegmentReorgLinks {
    /// 旧と新の全組み合わせから、同じキーと名称一致の組を返す（旧の並び順、その中は新の並び順）。
    /// 同じキーの行は、その組だけにする（名称で他の区分にも結ばない）。
    public static func deterministic(
        from: [(key: String, label: String)], to: [(key: String, label: String)]
    ) -> [SegmentReorgLink] {
        let shared = Set(from.map(\.key)).intersection(to.map(\.key))
        let (oldParts, newParts) = nameParts(old: from.map(\.label), new: to.map(\.label))
        var links: [SegmentReorgLink] = []
        for (old, parts) in zip(from, oldParts) {
            if shared.contains(old.key) {
                links.append(
                    SegmentReorgLink(
                        fromKey: old.key, toKey: old.key,
                        basis: segmentWaterfallReorgLinkBasisSameKey))
                continue
            }
            for (new, candidates) in zip(to, newParts) where !shared.contains(new.key) {
                guard parts.contains(where: { part in candidates.contains { matches(part, $0) } })
                else { continue }
                links.append(
                    SegmentReorgLink(
                        fromKey: old.key, toKey: new.key, basis: segmentWaterfallReorgLinkBasisName))
            }
        }
        return links
    }

    private static let nameSeparators = CharacterSet(charactersIn: "・&/、,")

    /// 丸ごと一致、または片方がもう片方で終わる（グリーンエナジー → エナジー）。後ろ側の一致は 3 文字以上だけ。
    private static func matches(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count < b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.hasSuffix(short)
    }

    /// 旧と新の区分名を、区切り記号で要素に分ける。語の一覧は持たず、並んだ区分名から決める。
    /// - 同じ側のどの区分名にも付く末尾（「事業」など）は落とす。その側で決まらなければ、反対側の末尾を使う。
    /// - 同じ側の 2 つ以上の区分名に出る要素は、区分を言い分けないので使わない。
    /// 要素は全半角と大小文字をそろえ、1 文字は使わない。
    static func nameParts(old: [String], new: [String]) -> (old: [Set<String>], new: [Set<String>]) {
        func fold(_ labels: [String]) -> [String] {
            labels.map {
                $0.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
            }
        }
        let (oldNames, newNames) = (fold(old), fold(new))
        let (oldSuffix, newSuffix) = (commonSuffix(oldNames), commonSuffix(newNames))
        func split(_ names: [String], suffix: String) -> [Set<String>] {
            let parts = names.map { name in
                let stem =
                    !suffix.isEmpty && name.count > suffix.count && name.hasSuffix(suffix)
                    ? String(name.dropLast(suffix.count)) : name
                return Set(stem.components(separatedBy: nameSeparators).filter { $0.count >= 2 })
            }
            let counts = parts.reduce(into: [String: Int]()) { counts, set in
                for part in set { counts[part, default: 0] += 1 }
            }
            return parts.map { $0.filter { counts[$0] == 1 } }
        }
        return (
            split(oldNames, suffix: oldSuffix.isEmpty ? newSuffix : oldSuffix),
            split(newNames, suffix: newSuffix.isEmpty ? oldSuffix : newSuffix))
    }

    /// 全部の名前に共通する末尾。名前が 1 つのとき、または落とすと空になる名前があるときは空。
    private static func commonSuffix(_ names: [String]) -> String {
        guard names.count > 1, var suffix = names.first.map({ Substring($0) }) else { return "" }
        for name in names.dropFirst() {
            while !name.hasSuffix(suffix) { suffix = suffix.dropFirst() }
        }
        return names.contains { $0.count == suffix.count } ? "" : String(suffix)
    }
}
