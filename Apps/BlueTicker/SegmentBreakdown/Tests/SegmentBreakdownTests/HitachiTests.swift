import Foundation
import Testing

@testable import SegmentBreakdown

/// 日立製作所 6501（本番 API 2026-11）: FY2023 に 5 区分 → 3 区分（regroup）、FY2026 に GEM → エナジー＋モビリティ（regroup）。
@Suite struct HitachiTests {
    static let json = """
        {"years":[
         {"fiscal_year":2026,"line_cut":true,"segments":[
          {"label":"コネクティブインダストリーズ","segment_key":"CI","value":3000,"prior":{"decision":"break","segment_key":"CI","from":["AUTO","GEM","CI"]}},
          {"label":"デジタルシステム＆サービス","segment_key":"DS","value":2756,"prior":{"decision":"connect","segment_key":"DS"}},
          {"label":"エナジー","segment_key":"EN","value":3200,"prior":{"decision":"reorg","from":["AUTO","GEM"]}},
          {"label":"モビリティ","segment_key":"MOB","value":1320,"prior":{"decision":"reorg","from":["AUTO","GEM"]}},
          {"label":"その他","segment_key":"OTH","value":275,"prior":{"decision":"connect","segment_key":"OTH"}}],
          "reorgs":[{"kind":"regroup","from":[{"segment_key":"AUTO","value":0},{"segment_key":"GEM","value":3849},{"segment_key":"CI","value":2969}],
           "to":[{"segment_key":"EN","value":3200},{"segment_key":"MOB","value":1320},{"segment_key":"CI","value":3000}]}]},
         {"fiscal_year":2025,"line_cut":true,"segments":[
          {"label":"オートモティブシステム","segment_key":"AUTO","value":0,"prior":{"decision":"connect","segment_key":"AUTO"}},
          {"label":"コネクティブインダストリーズ","segment_key":"CI","value":2969,"prior":{"decision":"connect","segment_key":"CI"}},
          {"label":"デジタルシステム＆サービス","segment_key":"DS","value":2653,"prior":{"decision":"connect","segment_key":"DS"}},
          {"label":"グリーンエナジー＆モビリティ","segment_key":"GEM","value":3849,"prior":{"decision":"connect","segment_key":"GEM"}},
          {"label":"その他","segment_key":"OTH","value":270,"prior":{"decision":"connect","segment_key":"OTH"}}]},
         {"fiscal_year":2024,"line_cut":false,"segments":[
          {"label":"オートモティブシステム","segment_key":"AUTO","value":1160,"prior":{"decision":"connect","segment_key":"AUTO"}},
          {"label":"コネクティブインダストリーズ","segment_key":"CI","value":2857,"prior":{"decision":"connect","segment_key":"CI"}},
          {"label":"デジタルシステム＆サービス","segment_key":"DS","value":2432,"prior":{"decision":"connect","segment_key":"DS"}},
          {"label":"グリーンエナジー＆モビリティ","segment_key":"GEM","value":2980,"prior":{"decision":"connect","segment_key":"GEM"}},
          {"label":"日立建機","segment_key":"CM","value":0,"prior":{"decision":"connect","segment_key":"CM"}},
          {"label":"日立金属","segment_key":"MT","value":0,"prior":{"decision":"connect","segment_key":"MT"}},
          {"label":"その他","segment_key":"OTH","value":267,"prior":{"decision":"connect","segment_key":"OTH"}}]},
         {"fiscal_year":2023,"line_cut":true,"segments":[
          {"label":"オートモティブシステム","segment_key":"AUTO","value":1915,"prior":{"decision":"connect","segment_key":"AUTO"}},
          {"label":"コネクティブインダストリーズ","segment_key":"CI","value":2759,"prior":{"decision":"reorg","from":["EG","IT","IND","MOBO","LIFE"]}},
          {"label":"デジタルシステム＆サービス","segment_key":"DS","value":2217,"prior":{"decision":"reorg","from":["EG","IT","IND","MOBO","LIFE"]}},
          {"label":"グリーンエナジー＆モビリティ","segment_key":"GEM","value":2432,"prior":{"decision":"reorg","from":["EG","IT","IND","MOBO","LIFE"]}},
          {"label":"日立建機","segment_key":"CM","value":474,"prior":{"decision":"connect","segment_key":"CM"}},
          {"label":"日立金属","segment_key":"MT","value":825,"prior":{"decision":"connect","segment_key":"MT"}},
          {"label":"その他","segment_key":"OTH","value":238,"prior":{"decision":"connect","segment_key":"OTH"}}],
          "reorgs":[{"kind":"regroup","from":[{"segment_key":"EG","value":1388},{"segment_key":"IT","value":1988},{"segment_key":"IND","value":737},{"segment_key":"MOBO","value":1420},{"segment_key":"LIFE","value":966}],
           "to":[{"segment_key":"CI","value":2759},{"segment_key":"DS","value":2217},{"segment_key":"GEM","value":2432}]}]},
         {"fiscal_year":2022,"line_cut":false,"segments":[
          {"label":"オートモティブシステム","segment_key":"AUTO","value":1591},
          {"label":"エネルギー","segment_key":"EG","value":1388},
          {"label":"日立建機","segment_key":"CM","value":1022},
          {"label":"日立金属","segment_key":"MT","value":915},
          {"label":"IT","segment_key":"IT","value":1988},
          {"label":"インダストリー","segment_key":"IND","value":737},
          {"label":"モビリティ","segment_key":"MOBO","value":1420},
          {"label":"その他","segment_key":"OTH","value":223},
          {"label":"ライフ","segment_key":"LIFE","value":966}]}]}
        """

    private func layout() throws -> BreakdownLayout {
        let response = try JSONDecoder().decode(SegmentWaterfallResponse.self, from: Data(Self.json.utf8))
        return StackedLayout.make(
            columns: BreakdownBuilder.collapsingReorgs(
                BreakdownBuilder.segmentColumns(response) { "FY\($0.fiscalYear ?? 0)" }))
    }

    /// 凡例（最新期）の色は区分ごとに別。系列が多くてパレットを一周しても、同じ列でかぶらない。
    @Test func latestColumnColorsAreDistinct() throws {
        let layout = try layout()
        let colors = layout.bars[4].map(\.colorIndex)
        #expect(Set(colors).count == colors.count)
        // 旧区分が多い FY2022 でも、再編先に寄せた色以外はかぶらない（その他・オートモティブ・建機・金属は別の色）。
        let other = ["OTH", "AUTO", "MT", "CM"].compactMap { key in layout.bars[0].first { $0.key == key }?.colorIndex }
        #expect(Set(other).count == other.count)
        #expect(Set(layout.bars[0].map(\.colorIndex)).count >= 7)
    }

    /// GEM → エナジー・モビリティの血筋は、毎年同じ位置（下端）に積まれ、帯は引かない。
    @Test func latestIsLargestFirstAndPastFollowsIt() throws {
        let layout = try layout()
        func order(_ column: Int) -> [String] { layout.bars[column].sorted { $0.y > $1.y }.map(\.key) }
        // 最新は大きい順に下から。古い年は最新の序列に合わせる（GEM・CI は行き先の位置、終了した区分は上）。
        #expect(order(4) == ["EN", "CI", "DS", "MOB", "OTH"])
        #expect(order(3) == ["GEM", "CI", "DS", "OTH"])
        // 26/03 の再編は GEM・コネクティブインダストリーズ → エナジー・モビリティ・コネクティブインダストリーズ（regroup）。
        // 対応が分からないので帯は引かず、「再編」の印も棒の中には出さない。
        #expect(layout.bars[4].allSatisfy { $0.mark == .none })
    }
}
