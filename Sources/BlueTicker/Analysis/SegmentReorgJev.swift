// 再編で区分名と segment_key からは移り先が決まらない旧区分を、有報のセグメント注記の記載から Jev に判定させる。
// 旧区分 × 新区分の組ごとに閉じた Choice {moved, not_moved}。多対多を許す。金額は扱わない。
// 3 回一致・0.9 を満たした moved だけを対応にする。満たさなければ対応を作らない。

import Foundation

/// 判定する再編 1 年分。`old` は移り先が未定の旧区分、`new` は当年の再編の新区分。
public struct SegmentReorgQuestion: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var key: String
        public var label: String

        public init(key: String, label: String) {
            self.key = key
            self.label = label
        }
    }

    public var fyEnd: String
    public var old: [Segment]
    public var new: [Segment]

    public init(fyEnd: String, old: [Segment], new: [Segment]) {
        self.fyEnd = fyEnd
        self.old = old
        self.new = new
    }
}

/// 1 組の判定結果。`decision` は `segmentTransitionDecisionSuccessor*`。
public struct SegmentReorgVerdict: Equatable, Sendable {
    public var oldKey: String
    public var newKey: String
    public var decision: String

    public init(oldKey: String, newKey: String, decision: String) {
        self.oldKey = oldKey
        self.newKey = newKey
        self.decision = decision
    }
}

/// Jev に渡す 1 組と根拠の文。
struct SegmentReorgPair: Sendable {
    var oldLabel: String
    var newLabel: String
    var allOldLabels: [String]
    var allNewLabels: [String]
    var previousFilingText: String
    var currentFilingText: String
    var fyEnd: String
}

protocol SegmentReorgDeciding: Sendable {
    func chooseReorg(_ pair: SegmentReorgPair) async -> JevChoiceAggregate.Sample
}

enum SegmentReorgJev {
    static let question = "segment_reorg"
    static let moved = "moved"
    static let notMoved = "not_moved"
    static let options = [moved, notMoved]
    static let jevPolicy = JevDecisionPolicy(
        kind: .classify,
        question: question,
        noneOfTheseKey: nil,
        confidenceThreshold: SegmentNoteDecision.applyProbabilityThreshold)

    /// 全部の組を判定する。呼び出しに届かなかった組は結果に含めない（次回に聞き直す）。
    static func judge(
        _ question: SegmentReorgQuestion, previousFilingText: String, currentFilingText: String,
        skipping judged: Set<[String]>, decider: any SegmentReorgDeciding
    ) async -> [SegmentReorgVerdict] {
        var verdicts: [SegmentReorgVerdict] = []
        for old in question.old {
            for new in question.new where !judged.contains([old.key, new.key]) {
                let pair = SegmentReorgPair(
                    oldLabel: old.label, newLabel: new.label,
                    allOldLabels: question.old.map(\.label), allNewLabels: question.new.map(\.label),
                    previousFilingText: previousFilingText, currentFilingText: currentFilingText,
                    fyEnd: question.fyEnd)
                let result = await JevDecisionSampler.decide(policy: jevPolicy, options: options) {
                    await decider.chooseReorg(pair)
                }
                guard result.calls.contains(where: { $0.selected != nil }) else { continue }
                let decision: String
                switch result.status {
                case .accepted(let key) where key == moved:
                    decision = segmentTransitionDecisionSuccessor
                case .accepted(let key) where key == notMoved:
                    decision = segmentTransitionDecisionSuccessorNone
                default:
                    decision = segmentTransitionDecisionSuccessorReview
                }
                verdicts.append(
                    SegmentReorgVerdict(oldKey: old.key, newKey: new.key, decision: decision))
            }
        }
        return verdicts
    }
}

struct OpenRouterSegmentReorgDecider: SegmentReorgDeciding {
    let client: any DecisionsCompleting
    var model: String = Api.openrouterDecisionsModel

    func chooseReorg(_ pair: SegmentReorgPair) async -> JevChoiceAggregate.Sample {
        let unavailable = JevChoiceAggregate.Sample(
            selected: nil, probability: nil, options: SegmentReorgJev.options, model: model)
        let presented = SegmentReorgJev.options.map { JevPresentedCandidate(key: $0, criterion: $0) }
        let state: [String: Any] = [
            "fy_end": pair.fyEnd,
            "old_segment": pair.oldLabel,
            "new_segment": pair.newLabel,
            "all_old_segments": pair.allOldLabels,
            "all_new_segments": pair.allNewLabels,
            "previous_year_segment_note": pair.previousFilingText,
            "current_year_segment_note": pair.currentFilingText,
        ]
        let instructions = """
            A Japanese company reorganized its reportable segments. Using only the two segment \
            notes (products and services of each segment, the subsidiaries that run them, and the \
            description of the change), decide whether business that belonged to old_segment in the \
            previous year now belongs to new_segment. Answer moved when the notes show that at \
            least a clear part of old_segment (a service, product or subsidiary) is in new_segment. \
            Answer not_moved otherwise. Similar names alone are not evidence. One old segment may \
            move into several new segments.
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
            probabilities: choice.probabilities, options: SegmentReorgJev.options, model: model)
    }
}
