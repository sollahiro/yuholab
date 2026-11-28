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

/// 旧区分の名称 → 段階ごとの答え（新区分の名称、または cannot_decide）。
private actor ReorgAnswers: SegmentReorgDeciding {
    private let answers: [String: [String: String]]
    private(set) var asked: [[String]] = []

    init(answers: [String: [String: String]]) { self.answers = answers }

    func chooseDestination(
        _ pair: SegmentReorgPair, options: [String], model: String
    ) async -> JevChoiceAggregate.Sample {
        asked.append([pair.oldLabel, model])
        let label = answers[pair.oldLabel]?[model] ?? SegmentReorgJev.cannotDecide
        let selected = pair.currentNew.first { $0.label == label }?.key ?? SegmentReorgJev.cannotDecide
        return JevChoiceAggregate.Sample(
            selected: selected, probability: 0.99, options: options, model: model)
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
            // 旧と新の合計が合う部分集合が無い値（金額で組に分けられず regroup のまま）。
            row("TE", "通信・エネルギー事業", 200), row("SHOP", "店舗・施設ソリューション事業", 15),
            row("FIN", "金融事業", 5),
        ])
    }

    @Test func asksOncePerOldSegmentWithAmountsAndStepsThroughTheModels() async throws {
        let question = try #require(
            SegmentWaterfall.reorgQuestion(
                fyEnd: "2025-08-31", previous: ("2024-08-31", "A", old), payload: new, transitions: []))
        #expect(question.old.map(\.key) == ["TEL", "BIZ", "SHOP0"])
        #expect(question.new.map(\.key) == ["TE", "SHOP", "FIN"])
        #expect(question.old.first { $0.key == "BIZ" }?.sales == 50)
        #expect(question.new.first { $0.key == "SHOP" }?.sales == 15)
        let first = Api.openrouterReorgModels[0]
        let second = Api.openrouterReorgModels[1]
        let decider = ReorgAnswers(answers: [
            // 名称は通信・エネルギーに似ているが、モデルは金融と答える（名称より優先される）。
            "通信事業": [first: "金融事業"],
            // 1 段目で決められず、2 段目で決まる。
            "業務用システム事業": [second: "店舗・施設ソリューション事業"],
            // どちらの段でも決められない。
            "店舗サービス事業": [:],
        ])
        let verdicts = await SegmentReorgJev.judge(
            question, previousFilingText: "前", currentFilingText: "当", decider: decider)
        #expect(verdicts == [
            SegmentReorgVerdict(oldKey: "TEL", newKey: "FIN", decision: segmentTransitionDecisionSuccessor),
            SegmentReorgVerdict(oldKey: "BIZ", newKey: "SHOP", decision: segmentTransitionDecisionSuccessor),
            SegmentReorgVerdict(oldKey: "SHOP0", newKey: nil, decision: segmentTransitionDecisionSuccessorReview),
        ])
        let asked = await decider.asked
        // 決まった段で止まる（TEL は 1 段、BIZ は 2 段、SHOP0 は 2 段）。
        #expect(asked.filter { $0[0] == "通信事業" }.count == 3)
        #expect(asked.filter { $0[0] == "業務用システム事業" }.map { $0[1] }.contains(second))
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
            draft(segmentTransitionDecisionSuccessor, "TEL", "FIN"),
            draft(segmentTransitionDecisionSuccessorReview, "SHOP0", "TE"),
        ])
        let links = try #require(judged[segmentWaterfallReorgLinksKey] as? [[String: String]])
        #expect(links == [
            ["from": "BIZ", "to": "SHOP", "basis": "jev"], ["from": "TEL", "to": "FIN", "basis": "jev"],
        ])
        func stripped(_ object: [String: Any]) throws -> Data {
            var copy = object
            copy.removeValue(forKey: segmentWaterfallReorgLinksKey)
            return try JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys])
        }
        #expect(try stripped(plain) == stripped(judged))
    }
}

@Suite struct SegmentNoteTableTests {
    @Test func keepsTextTablesAndDropsNumericOnes() {
        let html = """
            <p>報告セグメント</p>
            <table><tr><td>通信事業</td><td>携帯電話の販売</td></tr></table>
            <table><tr><td>通信事業</td><td>1,234</td></tr><tr><td>合計</td><td>5,678</td></tr></table>
            """
        let text = BreakdownExtractor.textOnlyTables(html)
        #expect(text.contains("携帯電話の販売"))
        #expect(!text.contains("1,234"))
    }
}
