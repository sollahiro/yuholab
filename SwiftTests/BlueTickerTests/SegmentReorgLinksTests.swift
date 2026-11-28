import Testing

@testable import BlueTickerCore

@Suite struct SegmentReorgLinksTests {
    // U-NEXT 9418 S100X6EF: 旧 5 区分 → 新 4 区分（コンテンツ配信は同じキーで組み替え）。
    @Test func linksSharedKeyAndNameComponentsOnly() {
        let links = SegmentReorgLinks.deterministic(
            from: [
                ("BIZ", "業務用システム事業"), ("TEL", "通信事業"), ("ENE", "エネルギー事業"),
                ("STORE", "店舗サービス事業"), ("CONTENT", "コンテンツ配信事業"),
            ],
            to: [
                ("TE", "通信・エネルギー事業"), ("FIN", "金融・不動産・グローバル事業"),
                ("SHOP", "店舗・施設ソリューション事業"), ("CONTENT", "コンテンツ配信事業"),
            ])
        #expect(links.map { "\($0.fromKey)>\($0.toKey):\($0.basis)" } == [
            "TEL>TE:name", "ENE>TE:name", "CONTENT>CONTENT:same_key",
        ])
    }

    // 日立 6501 / メディア工房 3815: 1 つの旧区分が複数の新区分へ分かれる。
    @Test func oneOldSegmentCanLinkToSeveralNewOnes() {
        let hitachi = SegmentReorgLinks.deterministic(
            from: [("GEM", "グリーンエナジー＆モビリティ")],
            to: [("EN", "エナジー"), ("MOB", "モビリティ")])
        #expect(hitachi.map(\.toKey) == ["EN", "MOB"])
        let media = SegmentReorgLinks.deterministic(
            from: [("XRSNS", "Xr／Sns事業")], to: [("SNS", "SNS事業"), ("XR", "XR事業")])
        #expect(media.map(\.toKey) == ["SNS", "XR"])
    }

    @Test func partsSharedBySeveralNamesAndPartialWordsDoNotLink() {
        let links = SegmentReorgLinks.deterministic(
            from: [("A", "情報・システム事業"), ("B", "制御・システム事業"), ("C", "店舗サービス事業")],
            to: [("X", "業務・システム事業"), ("Y", "店舗・施設ソリューション事業")])
        #expect(links.isEmpty)
    }

    @Test func suffixSharedByEveryNameIsDroppedWithoutAWordList() {
        let parts = SegmentReorgLinks.nameParts(
            old: ["通信セグメント"], new: ["情報通信セグメント", "エネルギーセグメント"])
        #expect(parts.old == [["通信"]])
        #expect(parts.new == [["情報通信"], ["エネルギー"]])
    }
}

@Suite struct GeographyMissingYearsTests {
    // 酉島 6363: 地域別があるのは 22・25・26。範囲は 26 から数えた 5 年。
    @Test func listsOnlyYearsInsideTheWindowWithoutGeography() {
        let sales: [(fyEnd: String, docID: String?, sales: Double)] = [
            ("2026-03-31", "A", 929), ("2025-03-31", "B", 865), ("2024-03-31", "C", 811),
            ("2023-03-31", "D", 647), ("2022-03-31", "E", 522), ("2021-03-31", "F", 508),
        ]
        let missing = GeographyWaterfall.missingYears(
            covered: [2026, 2025, 2022], sales: sales, limit: 5)
        #expect(missing.compactMap { $0["fiscal_year"] as? Int } == [2024, 2023])
    }
}
