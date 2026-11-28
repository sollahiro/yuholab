import Foundation
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

private actor ReorgAnswers: SegmentReorgDeciding {
    private let movedPairs: Set<[String]>
    private(set) var asked: Set<[String]> = []

    init(movedPairs: Set<[String]>) { self.movedPairs = movedPairs }

    func chooseReorg(_ pair: SegmentReorgPair) async -> JevChoiceAggregate.Sample {
        asked.insert([pair.oldLabel, pair.newLabel])
        let selected = movedPairs.contains([pair.oldLabel, pair.newLabel])
            ? SegmentReorgJev.moved : SegmentReorgJev.notMoved
        return JevChoiceAggregate.Sample(
            selected: selected, probability: 0.99, options: SegmentReorgJev.options, model: "test")
    }
}

@Suite struct SegmentReorgJevTests {
    private func row(_ key: String, _ label: String, _ value: Double) -> BreakdownRowPayload {
        var row = BreakdownRowPayload(
            labelRaw: label, label: label, amount: value, profit: nil, rowKind: "segment")
        row.segmentKey = key
        row.externalSales = BreakdownMetricCellPayload(
            value: value, basis: breakdownSourceXbrlFacts, source: "Sales", decimals: -6)
        return row
    }

    private func payload(_ rows: [BreakdownRowPayload]) -> BreakdownSnapshotPayload {
        BreakdownSnapshotPayload(
            axis: breakdownAxisSegment, denominator: 1, denominatorTag: "Sales",
            rows: rows, sourceKind: breakdownSourceXbrlFacts, needsReview: false, warnings: [])
    }

    private var old: BreakdownSnapshotPayload {
        payload([row("TEL", "通信事業", 100), row("BIZ", "業務用システム事業", 50), row("SHOP0", "店舗サービス事業", 70)])
    }

    private var new: BreakdownSnapshotPayload {
        payload([
            row("TE", "通信・エネルギー事業", 120), row("SHOP", "店舗・施設ソリューション事業", 90),
            row("FIN", "金融事業", 10),
        ])
    }

    @Test func asksOnlyUnresolvedOldSegmentsAndKeepsManyToManyAnswers() async throws {
        let question = try #require(
            SegmentWaterfall.reorgQuestion(
                fyEnd: "2025-08-31", previous: ("2024-08-31", "A", old), payload: new, transitions: []))
        #expect(question.old.map(\.key) == ["BIZ", "SHOP0"])
        let decider = ReorgAnswers(movedPairs: [
            ["業務用システム事業", "店舗・施設ソリューション事業"], ["店舗サービス事業", "店舗・施設ソリューション事業"],
            ["店舗サービス事業", "金融事業"],
        ])
        let verdicts = await SegmentReorgJev.judge(
            question, previousFilingText: "前", currentFilingText: "当",
            skipping: [["BIZ", "TE"]], decider: decider)
        #expect(verdicts.count == 5)
        #expect(
            verdicts.filter { $0.decision == segmentTransitionDecisionSuccessor }
                .map { [$0.oldKey, $0.newKey] }
                == [["BIZ", "SHOP"], ["SHOP0", "SHOP"], ["SHOP0", "FIN"]])
    }

    @Test func storedSuccessorsBecomeJevLinksWithoutChangingPriorOrLineCut() throws {
        let years = [
            (fyEnd: "2024-08-31", docID: "A", payload: old),
            (fyEnd: "2025-08-31", docID: "B", payload: new),
        ]
        func year(_ transitions: [SegmentTransitionDraft]) throws -> [String: Any] {
            let json = SegmentWaterfall.jsonObject(
                code: "9418", metric: segmentWaterfallMetricExternalSales, years: years,
                transitions: transitions)
            return try #require((json["years"] as? [[String: Any]])?.first)
        }
        func draft(_ decision: String, _ from: String, _ to: String) -> SegmentTransitionDraft {
            SegmentTransitionDraft(
                oldKey: from, newKey: to, fyEnd: "2025-08-31", decision: decision,
                basis: segmentTransitionBasisJev, matched: segmentTransitionMatchedReorg)
        }
        let plain = try year([])
        let judged = try year([
            draft(segmentTransitionDecisionSuccessor, "BIZ", "SHOP"),
            draft(segmentTransitionDecisionSuccessorNone, "BIZ", "FIN"),
        ])
        let links = try #require(judged[segmentWaterfallReorgLinksKey] as? [[String: String]])
        #expect(links == [
            ["from": "TEL", "to": "TE", "basis": "name"], ["from": "BIZ", "to": "SHOP", "basis": "jev"],
        ])
        func stripped(_ object: [String: Any]) throws -> Data {
            var copy = object
            copy.removeValue(forKey: segmentWaterfallReorgLinksKey)
            return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
        }
        #expect(try stripped(plain) == stripped(judged))
    }
}
