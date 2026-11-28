// 報告セグメントの年次ウォーターフォール。スナップショットは当期だけを持ち、
// ここで複数年の格納行を指標ごとに並べる。つなぎは年次応答に載せる（別ルートにしない）。
// 丸め幅の差額は差額行に出さない。未取り込みの年は作らない。

import Foundation

public enum SegmentWaterfall {
    public static func jsonObject(
        code: String,
        metric: String,
        years: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        transitions: [SegmentTransitionDraft] = [],
        key: String? = nil,
        fiscalYear: String? = nil,
        limit: Int = Api.financialsYearsDefault
    ) -> [String: Any] {
        let newestFirst = years.sorted { $0.fyEnd > $1.fyEnd }
        // 移り先の判定の行は、年のつなぎ（prior / line_cut / 系列）には混ぜない。
        let successors = transitions.filter { $0.decision == segmentTransitionDecisionSuccessor }
        let transitions = transitions.filter { !segmentTransitionSuccessorDecisions.contains($0.decision) }
        let selected = selectYears(
            newestFirst, key: key, fiscalYear: fiscalYear, limit: limit, transitions: transitions)
        let previousByFyEnd = previousYearIndex(newestFirst)
        return [
            "code": code,
            "metric": metric,
            "years": selected.map { year in
                yearObject(
                    fyEnd: year.fyEnd, docID: year.docID, payload: year.payload,
                    metric: metric, key: key,
                    previous: previousByFyEnd[year.fyEnd].flatMap { fy in
                        newestFirst.first { $0.fyEnd == fy }
                    },
                    yearTransitions: transitions.filter { $0.fyEnd == year.fyEnd },
                    allTransitions: transitions,
                    successors: successors.filter { $0.fyEnd == year.fyEnd })
            },
        ]
    }

    public static func yearObject(
        fyEnd: String, docID: String, payload: BreakdownSnapshotPayload,
        metric: String, key: String?,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)? = nil,
        yearTransitions: [SegmentTransitionDraft] = [],
        allTransitions: [SegmentTransitionDraft] = [],
        successors: [SegmentTransitionDraft] = []
    ) -> [String: Any] {
        let seriesKeys = key.map {
            series(seed: $0, transitions: allTransitions.isEmpty ? yearTransitions : allTransitions)
        }
        let items = payload.rows.compactMap { row -> (row: BreakdownRowPayload, item: [String: Any])? in
            if let seriesKeys, let rowKey = row.segmentKey, !seriesKeys.contains(rowKey) {
                return nil
            }
            if seriesKeys != nil, row.rowKind != "segment" { return nil }
            guard var item = metricItem(row, metric: metric) else { return nil }
            if row.rowKind == "segment",
                let prior = priorLink(row: row, previous: previous, transitions: yearTransitions)
            {
                item[segmentWaterfallPriorKey] = prior
            }
            return (row, item)
        }

        var object: [String: Any] = [
            "fy_end": fyEnd,
            "doc_id": docID,
            segmentWaterfallLineCutKey: lineCut(
                fyEnd: fyEnd, previous: previous, payload: payload, transitions: yearTransitions,
                seriesKeys: seriesKeys),
        ]
        if let fiscalYear = fiscalYear(fyEnd: fyEnd) { object["fiscal_year"] = fiscalYear }
        if let salesBasis = payload.salesBasis { object[segmentSalesBasisKey] = salesBasis }
        let reorgGroups =
            seriesKeys == nil
            ? reorgGroups(
                fyEnd: fyEnd, previous: previous, payload: payload, metric: metric,
                transitions: yearTransitions)
            : []
        object[segmentWaterfallSegmentsKey] = items.filter { $0.row.rowKind == "segment" }.map {
            entry -> [String: Any] in
            var item = entry.item
            if let key = entry.row.segmentKey,
                let group = reorgGroups.first(where: { $0.toKeys.contains(key) })
            {
                var prior =
                    item[segmentWaterfallPriorKey] as? [String: Any] ?? [
                        "decision": segmentWaterfallDecisionReorg,
                        "basis": segmentTransitionBasisDeterministic,
                    ]
                prior[segmentWaterfallPriorFromKey] = group.fromKeys
                item[segmentWaterfallPriorKey] = prior
            }
            return item
        }
        if !reorgGroups.isEmpty {
            object[segmentWaterfallReorgsKey] = reorgGroups.map(\.json)
        }
        let links = reorgLinks(
            groups: reorgGroups, previous: previous?.payload, payload: payload, successors: successors)
        if !links.isEmpty {
            object[segmentWaterfallReorgLinksKey] = links.map {
                ["from": $0.fromKey, "to": $0.toKey, "basis": $0.basis]
            }
        }

        if seriesKeys == nil {
            let adjustments = items.filter { $0.row.rowKind == "reconciling" }.map(\.item)
            if adjustments.count == 1 {
                object[segmentWaterfallAdjustmentKey] = adjustments[0]
            } else if adjustments.count > 1 {
                object[segmentWaterfallAdjustmentsKey] = adjustments
            }
            if let consolidated = items.first(where: {
                $0.row.rowKind == breakdownRowKindEntityTotal
            })?.item {
                object[segmentWaterfallConsolidatedKey] = consolidated
            }
            if let difference = items.first(where: {
                $0.row.rowKind == breakdownRowKindDifference
            })?.item {
                object[breakdownRowKindDifference] = difference
            }
            if let gap = payload.roundingGaps?[metric] {
                object[segmentRoundingGapsKey] = [metric: breakdownJSONAmount(gap)]
            }
        }
        return object
    }

    public static func publicDecision(
        stored: String, oldKey: String?, newKey: String?
    ) -> String {
        switch stored {
        case segmentTransitionDecisionConnect:
            if let oldKey, let newKey, oldKey != newKey { return segmentWaterfallDecisionRename }
            return segmentTransitionDecisionConnect
        case segmentTransitionDecisionNeedsReview:
            return segmentWaterfallDecisionReorg
        case segmentTransitionDecisionBreak:
            if oldKey != nil, newKey != nil { return segmentWaterfallDecisionReorg }
            return segmentTransitionDecisionBreak
        default:
            return stored
        }
    }

    public static func matchesFiscalYear(_ fyEnd: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 10 { return fyEnd.hasPrefix(String(trimmed.prefix(10))) }
        if let year = Int(trimmed) { return fiscalYear(fyEnd: fyEnd) == year }
        return fyEnd == trimmed
    }

    public static func fiscalYear(fyEnd: String) -> Int? {
        Int(fyEnd.prefix(4))
    }

    public static func isAdjacentYear(newer: String, older: String) -> Bool {
        guard let n = fiscalYear(fyEnd: newer), let o = fiscalYear(fyEnd: older) else {
            return false
        }
        return n - o == 1
    }

    static func cutsLine(_ decision: String) -> Bool {
        decision == segmentWaterfallDecisionReorg || decision == segmentTransitionDecisionBreak
    }

    private static func selectYears(
        _ newestFirst: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)],
        key: String?, fiscalYear: String?, limit: Int, transitions: [SegmentTransitionDraft]
    ) -> [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)] {
        var selected = newestFirst
        if let fiscalYear {
            selected = selected.filter { matchesFiscalYear($0.fyEnd, query: fiscalYear) }
        } else {
            selected = Array(selected.prefix(max(1, limit)))
        }
        guard let key else { return selected }
        let chain = series(seed: key, transitions: transitions)
        return selected.filter { year in
            year.payload.rows.contains { row in
                guard let rowKey = row.segmentKey else { return false }
                return chain.contains(rowKey)
            }
        }
    }

    private static func previousYearIndex(
        _ newestFirst: [(fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)]
    ) -> [String: String] {
        let oldestFirst = newestFirst.sorted { $0.fyEnd < $1.fyEnd }
        var map: [String: String] = [:]
        for index in oldestFirst.indices where index > 0 {
            map[oldestFirst[index].fyEnd] = oldestFirst[index - 1].fyEnd
        }
        return map
    }

    static func series(seed: String, transitions: [SegmentTransitionDraft]) -> Set<String> {
        var keys: Set<String> = [seed]
        var changed = true
        while changed {
            changed = false
            for draft in transitions {
                let decision = publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey)
                guard decision == segmentTransitionDecisionConnect
                    || decision == segmentWaterfallDecisionRename
                else { continue }
                if let oldKey = draft.oldKey, let newKey = draft.newKey {
                    if keys.contains(oldKey), keys.insert(newKey).inserted { changed = true }
                    if keys.contains(newKey), keys.insert(oldKey).inserted { changed = true }
                }
            }
        }
        return keys
    }

    /// 年をまたいで消えた旧区分と現れた新区分を、つながなかった分だけ 1 組にまとめる。
    /// 旧区分の値は前年に開示された値、新区分の値は当年の値（遡及後の前年値は格納しない）。
    /// 旧 1・新 1 は replace（値も名前も合わず、つなげなかった入れ替え）、旧 k・新 1 は merge、旧 1・新 n は split、それ以外は regroup。
    /// 旧区分だけ・新区分だけ（終了・新規）は組にしない。regroup は対応を決めず、
    /// 旧と新の全行を並べる。値の合計は同じ指標の行どうしだけ足す。
    struct ReorgGroup {
        var kind: String
        var fromKeys: [String]
        var toKeys: [String]
        var json: [String: Any]
    }

    static func reorgGroups(
        fyEnd: String,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)?,
        payload: BreakdownSnapshotPayload, metric: String,
        transitions: [SegmentTransitionDraft]
    ) -> [ReorgGroup] {
        guard let previous, isAdjacentYear(newer: fyEnd, older: previous.fyEnd) else { return [] }
        var connectedOld: Set<String> = []
        var connectedNew: Set<String> = []
        for draft in transitions {
            let decision = publicDecision(
                stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey)
            guard decision == segmentTransitionDecisionConnect
                || decision == segmentWaterfallDecisionRename
            else { continue }
            if let oldKey = draft.oldKey { connectedOld.insert(oldKey) }
            if let newKey = draft.newKey { connectedNew.insert(newKey) }
        }
        func rows(_ payload: BreakdownSnapshotPayload) -> [(key: String, row: BreakdownRowPayload)] {
            var seen: Set<String> = []
            return payload.rows.compactMap { row in
                guard row.rowKind == "segment", let key = row.segmentKey,
                    cell(row, metric: metric) != nil, seen.insert(key).inserted
                else { return nil }
                return (key, row)
            }
        }
        let oldRows = rows(previous.payload)
        let newRows = rows(payload)
        let oldKeys = Set(oldRows.map(\.key))
        let newKeys = Set(newRows.map(\.key))
        var gone = oldRows.filter { !newKeys.contains($0.key) && !connectedOld.contains($0.key) }
        var added = newRows.filter { !oldKeys.contains($0.key) && !connectedNew.contains($0.key) }
        guard !gone.isEmpty, !added.isEmpty else { return [] }
        // 同じキーのまま値だけ組み替えられた区分（前期列が前期の開示と合わない）は、再編の一部でもある。
        // 旧区分の一部が同じ名前の区分へ移ると、消えた旧区分と現れた新区分だけでは前期の合計が合わない。
        // 組み替えられた同キーの区分を足すと合計が合うときだけ、その区分を旧・新の両側に入れる。
        let restatedShared = newRows.filter { entry in
            guard oldKeys.contains(entry.key), !connectedNew.contains(entry.key) else { return false }
            return isRestated(row: entry.row, previous: previous.payload)
        }
        if !restatedShared.isEmpty {
            func filedTotal(_ rows: [(key: String, row: BreakdownRowPayload)]) -> Double? {
                let values = rows.compactMap { $0.row.externalSales?.value }
                return values.count == rows.count ? values.reduce(0, +) : nil
            }
            func restatedTotal(_ rows: [(key: String, row: BreakdownRowPayload)]) -> Double? {
                let values = rows.compactMap { $0.row.priorYearExternalSales?.value }
                return values.count == rows.count ? values.reduce(0, +) : nil
            }
            func balances(
                _ from: [(key: String, row: BreakdownRowPayload)],
                _ to: [(key: String, row: BreakdownRowPayload)]
            ) -> Bool {
                guard let filed = filedTotal(from), let restated = restatedTotal(to) else { return false }
                return abs(filed - restated) <= max(1.0, abs(filed) * regroupExactTolerance)
            }
            let sharedOld = oldRows.filter { old in restatedShared.contains { $0.key == old.key } }
            if !balances(gone, added), balances(gone + sharedOld, added + restatedShared) {
                gone += sharedOld
                added += restatedShared
            }
        }
        func side(_ rows: [(key: String, row: BreakdownRowPayload)]) -> [[String: Any]] {
            rows.compactMap { entry in
                guard var item = metricItem(entry.row, metric: metric) else { return nil }
                item.removeValue(forKey: "decimals")
                return item
            }
        }
        func total(_ rows: [(key: String, row: BreakdownRowPayload)]) -> Double {
            rows.reduce(0.0) { $0 + (cell($1.row, metric: metric)?.value ?? 0) }
        }
        func group(
            from: [(key: String, row: BreakdownRowPayload)],
            to: [(key: String, row: BreakdownRowPayload)], balanced: Bool = false
        ) -> ReorgGroup {
            let kind: String
            switch (from.count, to.count) {
            case (1, 1): kind = segmentWaterfallReorgKindReplace
            case (_, 1): kind = segmentWaterfallReorgKindMerge
            case (1, _): kind = segmentWaterfallReorgKindSplit
            default: kind = segmentWaterfallReorgKindRegroup
            }
            var json: [String: Any] = [
                "kind": kind,
                "from": side(from),
                "to": side(to),
                "from_total": breakdownJSONAmount(total(from)),
                "to_total": breakdownJSONAmount(total(to)),
            ]
            // 旧と新の合計が近い部分集合に分けた組（regroup を分けた残り）。旧の一部が別の組へ移る分は含まない。
            if balanced { json["balanced"] = true }
            return ReorgGroup(
                kind: kind, fromKeys: from.map(\.key), toKeys: to.map(\.key), json: json)
        }
        let whole = group(from: gone, to: added)
        guard whole.kind == segmentWaterfallReorgKindRegroup else { return [whole] }
        // 今期の書類の前期列（今期の区分での前期値）が全部の新区分にあり、旧区分の外部売上もあるときは、
        // 旧の値と新の前期値が丸め幅で合うかで分ける（同じ年の値どうしなので近さではなく一致）。
        // 無いときは、旧の値と今期の値の近さで分ける。
        let restatedNew = added.compactMap { $0.row.priorYearExternalSales?.value }
        let filedOld = gone.compactMap { $0.row.externalSales?.value }
        let exact = restatedNew.count == added.count && filedOld.count == gone.count
        // 前期列が付いていても、旧の値と丸め幅で合うとは限らない（旧区分から一部が別の新区分へ移る再編）。
        // 合わなければ、同じ年の値どうし（旧の値と新の前期値）の近さで分ける（今期の値より近い）。
        let parts =
            exact
            ? (splitRegroup(
                gone: zip(gone, filedOld).map { ($0.0.key, $0.1) },
                added: zip(added, restatedNew).map { ($0.0.key, $0.1) },
                tolerance: regroupExactTolerance)
                ?? splitRegroup(
                    gone: zip(gone, filedOld).map { ($0.0.key, $0.1) },
                    added: zip(added, restatedNew).map { ($0.0.key, $0.1) },
                    tolerance: regroupRestatedTolerance, preferFiner: true))
            : splitRegroup(
                gone: gone.map { ($0.key, total([$0])) },
                added: added.map { ($0.key, total([$0])) },
                tolerance: regroupSplitTolerance)
        guard let parts else { return [whole] }
        return parts.map { part in
            group(
                from: gone.filter { part.from.contains($0.key) },
                to: added.filter { part.to.contains($0.key) }, balanced: true)
        }
    }

    /// 旧も新も複数の再編があった年の、旧区分 → 新区分の組。金額で分けた組をまたいで結ぶため、
    /// その年の全部の組の旧区分と新区分から決める。split / merge / replace だけの年は組で対応が分かるので返さない。
    static func reorgLinks(
        groups: [ReorgGroup], previous: BreakdownSnapshotPayload?, payload: BreakdownSnapshotPayload,
        successors: [SegmentTransitionDraft] = []
    ) -> [SegmentReorgLink] {
        guard let previous else { return [] }
        let fromKeys = groups.flatMap(\.fromKeys)
        let toKeys = groups.flatMap(\.toKeys)
        // 年全体で旧か新が 1 区分なら、対応はもう決まっている。
        guard Set(fromKeys).count > 1, Set(toKeys).count > 1 else { return [] }
        func labeled(_ keys: [String], _ rows: [BreakdownRowPayload]) -> [(key: String, label: String)] {
            keys.compactMap { key in
                rows.first { $0.rowKind == "segment" && $0.segmentKey == key }.map { (key, $0.label) }
            }
        }
        let named = SegmentReorgLinks.deterministic(
            from: labeled(fromKeys, previous.rows), to: labeled(toKeys, payload.rows))
        // コードで決まった組に、Jev が移ったと判定した組を足す（区分を超えた移動は名称で決まった旧区分にもある）。
        let pairs = Set(named.map { [$0.fromKey, $0.toKey] })
        let judged = successors.compactMap { draft -> SegmentReorgLink? in
            guard let from = draft.oldKey, let to = draft.newKey, !pairs.contains([from, to]),
                fromKeys.contains(from), toKeys.contains(to)
            else { return nil }
            return SegmentReorgLink(fromKey: from, toKey: to, basis: segmentTransitionBasisJev)
        }
        return named + judged.sorted { ($0.fromKey, $0.toKey) < ($1.fromKey, $1.toKey) }
    }

    /// Jev に聞く再編年の問い。金額や件数で対応が決まった組（split / merge / replace）の年は聞かない。
    /// 旧区分は全部聞く。コードで決まった組は `linked` に入れて聞き直さない。
    public static func reorgQuestion(
        fyEnd: String,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload),
        payload: BreakdownSnapshotPayload, transitions: [SegmentTransitionDraft]
    ) -> SegmentReorgQuestion? {
        let groups = reorgGroups(
            fyEnd: fyEnd, previous: previous, payload: payload,
            metric: segmentWaterfallMetricExternalSales, transitions: transitions)
        guard groups.contains(where: { $0.kind == segmentWaterfallReorgKindRegroup }) else { return nil }
        let fromKeys = groups.flatMap(\.fromKeys)
        let toKeys = groups.flatMap(\.toKeys)
        func segments(_ keys: [String], _ rows: [BreakdownRowPayload]) -> [SegmentReorgQuestion.Segment] {
            keys.compactMap { key in
                rows.first { $0.rowKind == "segment" && $0.segmentKey == key }
                    .map { SegmentReorgQuestion.Segment(key: key, label: $0.label) }
            }
        }
        let linked = Set(
            reorgLinks(groups: groups, previous: previous.payload, payload: payload)
                .map { [$0.fromKey, $0.toKey] })
        let old = segments(fromKeys, previous.payload.rows)
        let new = segments(toKeys, payload.rows)
        guard !old.isEmpty, !new.isEmpty else { return nil }
        return SegmentReorgQuestion(fyEnd: fyEnd, old: old, new: new, linked: linked)
    }

    /// regroup を、旧の合計と新の合計が近い部分集合の組に分ける。
    /// 旧の分け方すべてと、新の各区分をどの旧の組に付けるかを調べ、2 組以上に分かれて
    /// 全部の組で合計の差が 10% 以内のうち、最も差の小さい分け方を採る。分け切れなければ nil（regroup のまま）。
    /// 旧・新とも 6 区分までを調べる。
    static let regroupSplitTolerance = 0.10
    /// 前期列の値で分けるときの許容（丸め幅の累積に収まる 0.1%）。
    static let regroupExactTolerance = 0.001
    /// 前期列の値と旧の値が丸め幅では合わないとき（旧区分の一部が別の新区分へ移る再編）の許容。
    /// 同じ年の値どうしなので、今期の値で分ける 10% より厳しくする。
    static let regroupRestatedTolerance = 0.05

    static func splitRegroup(
        gone: [(key: String, value: Double)], added: [(key: String, value: Double)],
        tolerance: Double, preferFiner: Bool = false
    ) -> [(from: Set<String>, to: Set<String>)]? {
        guard gone.count >= 2, gone.count <= 6, added.count >= 2, added.count <= 6 else {
            return nil
        }
        var best: (score: Double, blocks: Int, parts: [(from: Set<String>, to: Set<String>)])?
        // 旧の分け方（制限付き成長列）
        func partitions(_ n: Int) -> [[Int]] {
            var out: [[Int]] = []
            func go(_ i: Int, _ cur: [Int], _ maxUsed: Int) {
                if i == n { out.append(cur); return }
                for g in 0...(maxUsed + 1) { go(i + 1, cur + [g], max(maxUsed, g)) }
            }
            go(0, [], -1)
            return out
        }
        for assignment in partitions(gone.count) {
            let blockCount = (assignment.max() ?? 0) + 1
            guard blockCount >= 2, blockCount <= added.count else { continue }
            var fromTotals = [Double](repeating: 0, count: blockCount)
            for (index, block) in assignment.enumerated() { fromTotals[block] += gone[index].value }
            // 新の各区分を旧の組に付ける（blockCount ^ added.count 通り）
            var toAssign = [Int](repeating: 0, count: added.count)
            func tryAssign(_ i: Int) {
                if i == added.count {
                    var toTotals = [Double](repeating: 0, count: blockCount)
                    var used = Set<Int>()
                    for (index, block) in toAssign.enumerated() {
                        toTotals[block] += added[index].value
                        used.insert(block)
                    }
                    guard used.count == blockCount else { return }
                    var worst = 0.0
                    for block in 0..<blockCount {
                        let base = max(abs(fromTotals[block]), abs(toTotals[block]))
                        guard base > 0 else { return }
                        worst = max(worst, abs(fromTotals[block] - toTotals[block]) / base)
                    }
                    guard worst <= tolerance else { return }
                    if let current = best {
                        // 通常は差が最小の分け方。`preferFiner` は、許容に収まる中で最も細かく分ける
                        // （旧区分ごとの行き先を、できるだけ細かく決める）。
                        if preferFiner {
                            if current.blocks > blockCount
                                || (current.blocks == blockCount && current.score <= worst)
                            { return }
                        } else if current.score < worst
                            || (current.score == worst && current.blocks >= blockCount)
                        { return }
                    }
                    var parts: [(from: Set<String>, to: Set<String>)] = Array(
                        repeating: ([], []), count: blockCount)
                    for (index, block) in assignment.enumerated() {
                        parts[block].from.insert(gone[index].key)
                    }
                    for (index, block) in toAssign.enumerated() {
                        parts[block].to.insert(added[index].key)
                    }
                    best = (worst, blockCount, parts)
                    return
                }
                for block in 0..<blockCount {
                    toAssign[i] = block
                    tryAssign(i + 1)
                }
            }
            tryAssign(0)
        }
        return best?.parts
    }

    private static func priorLink(
        row: BreakdownRowPayload,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)?,
        transitions: [SegmentTransitionDraft]
    ) -> [String: Any]? {
        guard let currentKey = row.segmentKey else { return nil }
        if let draft = transitions.first(where: { $0.newKey == currentKey }) {
            var object: [String: Any] = [
                "decision": publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey),
                "basis": draft.basis,
            ]
            if let oldKey = draft.oldKey { object[breakdownRowSegmentKeyKey] = oldKey }
            return object
        }
        guard let previous,
            previous.payload.rows.contains(where: { $0.segmentKey == currentKey })
        else { return nil }
        if isRestated(row: row, previous: previous.payload) {
            return [
                breakdownRowSegmentKeyKey: currentKey,
                "decision": segmentTransitionDecisionBreak,
                "basis": segmentTransitionMatchedRestated,
            ]
        }
        return [
            breakdownRowSegmentKeyKey: currentKey,
            "decision": segmentTransitionDecisionConnect,
            "basis": segmentTransitionMatchedSameKey,
        ]
    }

    /// 同じキーの区分で、前期の書類が出した外部売上と、今期の書類の前期列（今期の区分での前期値）が合わない。
    /// 開示精度の丸め（decimals）を超えて違うときだけ。どちらかの値が無ければ判定しない。
    static func isRestated(row: BreakdownRowPayload, previous: BreakdownSnapshotPayload) -> Bool {
        guard row.rowKind == "segment", let key = row.segmentKey,
            let restated = row.priorYearExternalSales,
            let filed = previous.rows.first(where: { $0.segmentKey == key })?.externalSales
        else { return false }
        let decimals = [restated.decimals, filed.decimals].compactMap { $0 }.min()
        let tolerance = decimals.map { $0 < 0 ? pow(10.0, Double(-$0)) : 1.0 } ?? 1.0
        return abs(restated.value - filed.value) > tolerance
    }

    private static func lineCut(
        fyEnd: String,
        previous: (fyEnd: String, docID: String, payload: BreakdownSnapshotPayload)?,
        payload: BreakdownSnapshotPayload,
        transitions: [SegmentTransitionDraft],
        seriesKeys: Set<String>?
    ) -> Bool {
        guard let previous else { return false }
        if !isAdjacentYear(newer: fyEnd, older: previous.fyEnd) { return true }
        let relevant = transitions.filter { draft in
            guard let seriesKeys else { return true }
            return [draft.oldKey, draft.newKey].compactMap { $0 }.contains {
                seriesKeys.contains($0)
            }
        }
        if relevant.contains(where: {
            cutsLine(publicDecision(stored: $0.decision, oldKey: $0.oldKey, newKey: $0.newKey))
        }) {
            return true
        }
        let restated = payload.rows.contains { row in
            guard let key = row.segmentKey else { return false }
            if let seriesKeys, !seriesKeys.contains(key) { return false }
            return isRestated(row: row, previous: previous.payload)
        }
        if restated { return true }
        let renamedFrom = Set(
            relevant.compactMap { draft -> String? in
                let decision = publicDecision(
                    stored: draft.decision, oldKey: draft.oldKey, newKey: draft.newKey)
                guard decision == segmentTransitionDecisionConnect
                    || decision == segmentWaterfallDecisionRename
                else { return nil }
                return draft.oldKey
            })
        let previousKeys = segmentKeys(previous.payload, seriesKeys: seriesKeys)
        let currentKeys = segmentKeys(payload, seriesKeys: seriesKeys)
        return !previousKeys.subtracting(currentKeys).subtracting(renamedFrom).isEmpty
    }

    private static func segmentKeys(
        _ payload: BreakdownSnapshotPayload, seriesKeys: Set<String>?
    ) -> Set<String> {
        Set(
            payload.rows.compactMap { row -> String? in
                guard row.rowKind == "segment", let key = row.segmentKey else { return nil }
                if let seriesKeys { return seriesKeys.contains(key) ? key : nil }
                return key
            })
    }

    private static func metricItem(_ row: BreakdownRowPayload, metric: String) -> [String: Any]? {
        guard let cell = cell(row, metric: metric) else { return nil }
        var item: [String: Any] = [
            "label": row.label,
            "value": breakdownJSONAmount(cell.value),
        ]
        if let segmentKey = row.segmentKey { item[breakdownRowSegmentKeyKey] = segmentKey }
        if let decimals = cell.decimals { item["decimals"] = decimals }
        if let source = optionalSource(cell) { item["source"] = source }
        if let basis = optionalBasis(cell) { item["basis"] = basis }
        return item
    }

    private static func cell(_ row: BreakdownRowPayload, metric: String) -> BreakdownMetricCellPayload?
    {
        switch metric {
        case segmentWaterfallMetricExternalSales: return row.externalSales
        case segmentWaterfallMetricProfit: return row.profitCell
        case segmentWaterfallMetricSegmentAssets: return row.segmentAssetsCell
        case segmentWaterfallMetricCapitalExpenditures: return row.capitalExpenditures
        case segmentWaterfallMetricNoncurrentAssetAdditions: return row.noncurrentAssetAdditions
        default: return nil
        }
    }

    private static func optionalSource(_ cell: BreakdownMetricCellPayload) -> String? {
        cell.source.isEmpty ? nil : cell.source
    }

    private static func optionalBasis(_ cell: BreakdownMetricCellPayload) -> String? {
        cell.basis.isEmpty ? nil : cell.basis
    }
}
