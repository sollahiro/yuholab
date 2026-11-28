// 再編で、名称と金額では移り先が決まらない旧区分の「主な移り先」を、有報のセグメント注記の記載から Jev に判定させる。
// 旧区分 1 つにつき 1 問。選択肢は新区分と「決められない」。区分名の似ていることは根拠にしない。
// 段階: Api.openrouterReorgModels（liquid/d1.2 → liquid/d1.2-ultra）の順に聞き、
// 3 回一致・0.9 を満たして新区分を選べた段階で止める。どの段階でも選べなければ「決められない」にする。
// 取り込みのときだけ呼ぶ（配信の経路では呼ばない）。

import Foundation

/// 判定する再編 1 年分。`old` は聞く旧区分、`new` は当年の新区分。
public struct SegmentReorgQuestion: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var key: String
        public var label: String
        /// 旧区分は前年の有報の外部売上、新区分は当年の外部売上。
        public var sales: Double?
        /// 新区分の前年（当年の有報での組替後）の外部売上。旧区分では nil。
        public var priorSales: Double?

        public init(key: String, label: String, sales: Double? = nil, priorSales: Double? = nil) {
            self.key = key
            self.label = label
            self.sales = sales
            self.priorSales = priorSales
        }
    }

    public var fyEnd: String
    public var old: [Segment]
    public var new: [Segment]
    /// 前年の有報の区分（金額つき）の全体。聞かない旧区分も含む。
    public var allOld: [Segment]

    public init(fyEnd: String, old: [Segment], new: [Segment], allOld: [Segment]? = nil) {
        self.fyEnd = fyEnd
        self.old = old
        self.new = new
        self.allOld = allOld ?? old
    }
}

/// 旧区分 1 つの判定結果。`newKey` は主な移り先（決められないときは nil）。
/// `decision` は `segmentTransitionDecisionSuccessor`（移り先が決まった）か `…SuccessorReview`（決められない）。
public struct SegmentReorgVerdict: Equatable, Sendable {
    public var oldKey: String
    public var newKey: String?
    public var decision: String

    public init(oldKey: String, newKey: String?, decision: String) {
        self.oldKey = oldKey
        self.newKey = newKey
        self.decision = decision
    }
}

/// Jev に渡す 1 問と根拠。
struct SegmentReorgPair: Sendable {
    var fyEnd: String
    var oldLabel: String
    var filedOld: [SegmentReorgQuestion.Segment]
    var currentNew: [SegmentReorgQuestion.Segment]
    var previousFilingText: String
    var currentFilingText: String
}

protocol SegmentReorgDeciding: Sendable {
    /// `model` で 1 回聞く。選択肢は新区分のキーと `SegmentReorgJev.cannotDecide`。
    func chooseDestination(
        _ pair: SegmentReorgPair, options: [String], model: String
    ) async -> JevChoiceAggregate.Sample
}

enum SegmentReorgJev {
    static let question = "segment_reorg_destination"
    static let cannotDecide = "cannot_decide"
    static let jevPolicy = JevDecisionPolicy(
        kind: .select,
        question: question,
        noneOfTheseKey: cannotDecide,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// 聞く旧区分すべてを判定する。呼び出しに届かなかった旧区分は結果に含めない（次回に聞き直す）。
    static func judge(
        _ question: SegmentReorgQuestion, previousFilingText: String, currentFilingText: String,
        decider: any SegmentReorgDeciding, models: [String] = Api.openrouterReorgModels
    ) async -> [SegmentReorgVerdict] {
        let options = question.new.map(\.key) + [cannotDecide]
        var verdicts: [SegmentReorgVerdict] = []
        for old in question.old {
            let pair = SegmentReorgPair(
                fyEnd: question.fyEnd, oldLabel: old.label,
                filedOld: question.allOld, currentNew: question.new,
                previousFilingText: previousFilingText, currentFilingText: currentFilingText)
            var reached = false
            var chosen: String?
            for model in models {
                let result = await JevDecisionSampler.decide(policy: jevPolicy, options: options) {
                    await decider.chooseDestination(pair, options: options, model: model)
                }
                if result.calls.contains(where: { $0.selected != nil }) { reached = true }
                if case .accepted(let key) = result.status, key != cannotDecide {
                    chosen = key
                    break
                }
            }
            guard reached else { continue }
            verdicts.append(
                SegmentReorgVerdict(
                    oldKey: old.key, newKey: chosen,
                    decision: chosen == nil
                        ? segmentTransitionDecisionSuccessorReview : segmentTransitionDecisionSuccessor))
        }
        return verdicts
    }
}

struct OpenRouterSegmentReorgDecider: SegmentReorgDeciding {
    let client: any DecisionsCompleting

    func chooseDestination(
        _ pair: SegmentReorgPair, options: [String], model: String
    ) async -> JevChoiceAggregate.Sample {
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: options, model: model)
        var presented = pair.currentNew.map {
            JevPresentedCandidate(key: $0.key, criterion: $0.label)
        }
        presented.append(
            JevPresentedCandidate(
                key: SegmentReorgJev.cannotDecide,
                criterion: "the notes do not show which new segment received most of it"))
        func list(_ segments: [SegmentReorgQuestion.Segment], prior: Bool) -> [[String: Any]] {
            segments.map { segment in
                var row: [String: Any] = ["name": segment.label]
                row["sales_yen"] = segment.sales.map(breakdownJSONAmount) ?? NSNull()
                if prior { row["prior_year_sales_yen"] = segment.priorSales.map(breakdownJSONAmount) ?? NSNull() }
                return row
            }
        }
        let state: [String: Any] = [
            "fy_end": pair.fyEnd,
            "old_segment": pair.oldLabel,
            "previous_year_segments_as_filed": list(pair.filedOld, prior: false),
            "current_year_segments": list(pair.currentNew, prior: true),
            "previous_year_segment_note": pair.previousFilingText,
            "current_year_segment_note": pair.currentFilingText,
        ]
        let instructions = """
            A Japanese company reorganized its reportable segments. Decide which of the current-year \
            segments received the largest part of the business that old_segment ran in the previous \
            year. Use the two segment notes (what each segment sells, the subsidiaries that run it, \
            and the description of the change) and the three lists of segment names and sales: the \
            previous-year segments as filed, the current-year segments, and the current-year \
            segments' prior-year sales restated on the new basis. Names alone are not evidence; a \
            similar name does not decide the answer. Answer cannot_decide when the notes do not \
            show it.
            """
        guard let body = JevDecisionRequest.json(
            model: model, question: SegmentReorgJev.question,
            instructions: instructions, candidates: presented, state: state)
        else { return unavailable }
        guard let data = await JevDecisionTransport.decide(
            client: client, requestJSON: body,
            retries: SegmentReorgJev.jevPolicy.transportRetries,
            onFailure: "SegmentReorgJev: Jev呼び出し失敗")
        else { return unavailable }
        guard let choice = OpenRouterDecisionsCodec.answers(from: data)[SegmentReorgJev.question]?.choice
        else { return unavailable }
        return JevChoiceAggregate.Sample(
            selected: choice.selected,
            probability: OpenRouterSegmentNoteDecider.selectedProbability(
                selected: choice.selected, probabilities: choice.probabilities),
            probabilities: choice.probabilities, options: options, model: model)
    }
}
