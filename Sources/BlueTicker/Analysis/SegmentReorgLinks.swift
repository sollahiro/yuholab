// 複数対複数の再編（regroup）の旧区分 → 新区分の対応。区分名と segment_key だけで決まる組を拾う。
// 金額は使わないし、組み替えもしない。決められない行には組を作らない。

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
        var links: [SegmentReorgLink] = []
        for old in from {
            if shared.contains(old.key) {
                links.append(
                    SegmentReorgLink(
                        fromKey: old.key, toKey: old.key,
                        basis: segmentWaterfallReorgLinkBasisSameKey))
                continue
            }
            let oldParts = nameParts(old.label)
            for new in to where !shared.contains(new.key) {
                guard !oldParts.isDisjoint(with: nameParts(new.label)) else { continue }
                links.append(
                    SegmentReorgLink(
                        fromKey: old.key, toKey: new.key, basis: segmentWaterfallReorgLinkBasisName))
            }
        }
        return links
    }

    /// どの会社にも出る語。これだけの一致では対応と見ない。
    private static let genericParts: Set<String> = [
        "その他", "サービス", "システム", "ソリューション", "製品", "商品", "国内", "海外", "関連", "開発",
    ]
    private static let nameSuffixes = ["セグメント", "事業", "部門", "分野", "関連"]
    private static let nameSeparators = CharacterSet(charactersIn: "・&/、,")

    /// 区分名を「・」「＆」「／」などで区切った要素。末尾の「事業」等は落とし、全半角と大小文字はそろえる。
    /// 要素は丸ごと一致で比べる（「店舗サービス」と「店舗・施設ソリューション」は結ばない）。
    static func nameParts(_ label: String) -> Set<String> {
        let folded = label.precomposedStringWithCompatibilityMapping.lowercased()
            .filter { !$0.isWhitespace }
        return Set(
            folded.components(separatedBy: nameSeparators).compactMap { part -> String? in
                var name = part
                while let suffix = nameSuffixes.first(where: { name.hasSuffix($0) }) {
                    name.removeLast(suffix.count)
                }
                guard name.count >= 2, !genericParts.contains(name) else { return nil }
                return name
            })
    }
}
