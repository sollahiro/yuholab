import Foundation
import Testing

@testable import SegmentBreakdown

/// U-NEXT 9418（本番 API 2026-11。値は億円）。24/08 → 25/08 は旧 5・新 4 の regroup。
struct ReorgLinksTests {
    static let json = """
        {"years":[
         {"fiscal_year":2026,"segments":[
          {"label":"通信・エネルギー事業","segment_key":"TE","value":1943,"prior":{"decision":"connect","segment_key":"TE"}},
          {"label":"コンテンツ配信事業","segment_key":"CONTENT","value":1440,"prior":{"decision":"connect","segment_key":"CONTENT"}},
          {"label":"金融・不動産・グローバル事業","segment_key":"FIN","value":238,"prior":{"decision":"connect","segment_key":"FIN"}},
          {"label":"店舗・施設ソリューション事業","segment_key":"SHOP","value":1077,"prior":{"decision":"connect","segment_key":"SHOP"}}]},
         {"fiscal_year":2025,"line_cut":true,"segments":[
          {"label":"通信・エネルギー事業","segment_key":"TE","value":1568,"prior":{"decision":"reorg"}},
          {"label":"コンテンツ配信事業","segment_key":"CONTENT","value":1280,"prior":{"decision":"break","segment_key":"CONTENT"}},
          {"label":"金融・不動産・グローバル事業","segment_key":"FIN","value":102,"prior":{"decision":"reorg"}},
          {"label":"店舗・施設ソリューション事業","segment_key":"SHOP","value":953,"prior":{"decision":"reorg"}}],
          "reorgs":[{"kind":"regroup",
            "from":[{"segment_key":"BIZ","value":288},{"segment_key":"TEL","value":597},{"segment_key":"ENE","value":601},
                    {"segment_key":"STORE","value":693},{"segment_key":"CONTENT","value":1089}],
            "to":[{"segment_key":"TE","value":1568},{"segment_key":"FIN","value":102},{"segment_key":"SHOP","value":953},
                  {"segment_key":"CONTENT","value":1280}]}],
          "reorg_links":[{"from":"TEL","to":"TE","basis":"name"},{"from":"ENE","to":"TE","basis":"name"},
                         {"from":"CONTENT","to":"CONTENT","basis":"same_key"}]},
         {"fiscal_year":2024,"segments":[
          {"label":"業務用システム事業","segment_key":"BIZ","value":288,"prior":{"decision":"connect","segment_key":"BIZ"}},
          {"label":"通信事業","segment_key":"TEL","value":597,"prior":{"decision":"connect","segment_key":"TEL"}},
          {"label":"コンテンツ配信事業","segment_key":"CONTENT","value":1089,"prior":{"decision":"connect","segment_key":"CONTENT"}},
          {"label":"エネルギー事業","segment_key":"ENE","value":601,"prior":{"decision":"connect","segment_key":"ENE"}},
          {"label":"店舗サービス事業","segment_key":"STORE","value":693,"prior":{"decision":"connect","segment_key":"STORE"}}]},
         {"fiscal_year":2023,"segments":[
          {"label":"業務用システム事業","segment_key":"BIZ","value":205},
          {"label":"通信事業","segment_key":"TEL","value":534},
          {"label":"コンテンツ配信事業","segment_key":"CONTENT","value":849},
          {"label":"エネルギー事業","segment_key":"ENE","value":548},
          {"label":"店舗サービス事業","segment_key":"STORE","value":627}]}]}
        """

    private func layout() throws -> BreakdownLayout {
        let response = try JSONDecoder().decode(SegmentWaterfallResponse.self, from: Data(Self.json.utf8))
        return StackedLayout.make(
            columns: BreakdownBuilder.collapsingReorgs(
                BreakdownBuilder.segmentColumns(response) { "FY\($0.fiscalYear ?? 0)" }))
    }

    @Test func pastYearsFollowTheLatestOrderThroughTheLinks() throws {
        let layout = try layout()
        func order(_ column: Int) -> [String] { layout.bars[column].sorted { $0.y > $1.y }.map(\.key) }
        #expect(order(3) == ["TE", "CONTENT", "SHOP", "FIN"])
        #expect(order(2) == ["TE", "CONTENT", "SHOP", "FIN"])
        // 通信・エネルギーの旧 2 区分が下（組の中は 24/08 の大きい順）、次にコンテンツ配信。移り先の分からない区分は上。
        #expect(order(1) == ["ENE", "TEL", "CONTENT", "STORE", "BIZ"])
        #expect(order(0) == ["ENE", "TEL", "CONTENT", "STORE", "BIZ"])
    }

    @Test func linkedSegmentsShareTheDestinationColorAndUnknownOnesAvoidTheLegendColors() throws {
        let layout = try layout()
        func color(_ column: Int, _ key: String) -> Int? {
            layout.bars[column].first { $0.key == key }?.colorIndex
        }
        #expect(color(1, "TEL") == color(3, "TE"))
        #expect(color(1, "ENE") == color(3, "TE"))
        #expect(color(1, "CONTENT") == color(3, "CONTENT"))
        let legend = Set(layout.bars[3].map(\.colorIndex))
        for key in ["STORE", "BIZ"] {
            #expect(!legend.contains(try #require(color(1, key))))
        }
    }
}
