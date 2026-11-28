import Testing

@testable import BlueTickerCore

/// 親 / 子の行は親を subtotal にし、資産の調整表の行は reconciling にする。
struct SegmentRowKindLabelTests {
    private func row(_ label: String, kind: String = "segment") -> BreakdownRow {
        BreakdownRow(
            labelRaw: label, label: label, amount: 100, share: nil, profit: 10, rowKind: kind,
            description: nil)
    }

    @Test func parentRowsWithChildrenBecomeSubtotals() {
        let rows = [
            row("はせがわ / 仏壇仏具・墓石 / 東日本"),
            row("はせがわ / 仏壇仏具・墓石 / 西日本"),
            row("はせがわ / 仏壇仏具・墓石"),
            row("はせがわ / 屋内墓苑"),
            row("はせがわ"),
            row("現代仏壇"),
            row("調整額", kind: "reconciling"),
        ]
        let kinds = SegmentInfoLLMNormalizer.demotingParentRowsWithChildren(rows)
            .map { "\($0.labelRaw)=\($0.rowKind)" }
        #expect(kinds == [
            "はせがわ / 仏壇仏具・墓石 / 東日本=segment",
            "はせがわ / 仏壇仏具・墓石 / 西日本=segment",
            "はせがわ / 仏壇仏具・墓石=subtotal",
            "はせがわ / 屋内墓苑=segment",
            "はせがわ=subtotal",
            "現代仏壇=segment",
            "調整額=reconciling",
        ])
    }

    @Test func rowsWithoutChildrenAreUntouched() {
        let rows = [row("流通"), row("流通サービス"), row("運輸")]
        #expect(
            SegmentInfoLLMNormalizer.demotingParentRowsWithChildren(rows).allSatisfy {
                $0.rowKind == "segment"
            })
    }

    @Test func assetReconciliationMembersAreReconciling() {
        for label in ["全社資産（注）", "その他の調整額", "セグメント間取引消去等", "事業セグメントに配分していない資産"] {
            let raw = "\(SegmentAssetsDifferenceTable.labelRawPrefix)\(label)"
            let kind = SegmentMemberKind.classify(localName: raw, label: label)
            #expect(SegmentMemberKind.rowKind(kind) == "reconciling", "\(label)")
        }
    }

    @Test func aggregateParentSegmentBecomesSubtotal() {
        // 親（P）が子 4 つの合計に一致し、足すと連結を超える（親子の二重計上）。
        let amounts: [String: Double] = [
            "Chem": 360_202, "Parent": 1_268_246, "A": 244_102, "B": 423_967,
            "C": 544_278, "D": 55_899, "Reconciling": 0,
        ]
        var kinds: [String: String] = amounts.mapValues { _ in "segment" }
        kinds["Reconciling"] = "reconciling"
        BreakdownNormalizer.demoteAggregateParentSegments(
            kinds: &kinds, amounts: amounts, total: 1_628_448)
        #expect(kinds["Parent"] == "subtotal")
        #expect(kinds.filter { $0.value == "segment" }.count == 5)
    }

    @Test func aggregateParentIsKeptWhenTotalAlreadyMatches() {
        let amounts: [String: Double] = ["P": 100, "A": 60, "B": 40, "X": 50]
        var kinds: [String: String] = amounts.mapValues { _ in "segment" }
        BreakdownNormalizer.demoteAggregateParentSegments(
            kinds: &kinds, amounts: amounts, total: 250)
        #expect(kinds.values.allSatisfy { $0 == "segment" })
    }

    @Test func llmSkeletonAggregateRowsBecomeSubtotals() {
        func row(_ label: String, _ amount: Double, kind: String = "segment") -> BreakdownRowPayload {
            BreakdownRowPayload(labelRaw: label, label: label, amount: amount, profit: nil, rowKind: kind)
        }
        // 「連結（非継続事業調整前）」が子の合計に一致して segment のまま残り、連結を超える。
        var rows = [
            row("海外", 35_514), row("機電・IT", 91_064), row("建設", 44_994), row("製造", 7_993),
            row("その他", 1_650), row("非継続事業へ振替", -7_993),
            row("連結（非継続事業調整前）", 181_219), row("調整額", 2, kind: "reconciling"),
            row("EntityTotal", 173_225, kind: breakdownRowKindEntityTotal),
        ]
        SegmentV3.demoteAggregateParents(&rows, fallbackTotal: 0)
        #expect(rows.first { $0.label == "連結（非継続事業調整前）" }?.rowKind == "subtotal")
        #expect(rows.first { $0.label == "海外" }?.rowKind == "segment")
        // 偶然の部分和一致（建設≈海外+製造+その他）の行は落とさない。
        #expect(rows.first { $0.label == "建設" }?.rowKind == "segment")
    }
}
