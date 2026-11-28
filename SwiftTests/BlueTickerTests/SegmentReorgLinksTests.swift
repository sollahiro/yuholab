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
        #expect(hitachi.map(\.toKey) == ["MOB"])
        let media = SegmentReorgLinks.deterministic(
            from: [("XRSNS", "Xr／Sns事業")], to: [("SNS", "SNS事業"), ("XR", "XR事業")])
        #expect(media.map(\.toKey) == ["SNS", "XR"])
    }

    @Test func genericWordsAndPartialWordsDoNotLink() {
        let links = SegmentReorgLinks.deterministic(
            from: [("A", "その他の事業"), ("B", "情報・システム事業"), ("C", "店舗サービス事業")],
            to: [("X", "その他"), ("Y", "業務・システム事業"), ("Z", "店舗・施設ソリューション事業")])
        #expect(links.isEmpty)
    }
}
