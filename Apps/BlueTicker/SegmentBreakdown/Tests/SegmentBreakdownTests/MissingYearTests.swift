import Foundation
import Testing

@testable import SegmentBreakdown

/// 酉島製作所 6363 の形（値は億円）。23/03・24/03 の地域別が無い。
struct MissingYearTests {
    static let json = """
        {"years":[
         {"fy_end":"2026-03-31","comparable_group":0,"comparable_regions":[
           {"region":"japan","value":364},{"region":"middle_east","value":248},{"region":"asia","value":119},{"region":"africa","value":74}]},
         {"fy_end":"2025-03-31","comparable_group":0,"comparable_regions":[
           {"region":"japan","value":326},{"region":"middle_east","value":159},{"region":"asia","value":143},{"region":"africa","value":148}]},
         {"fy_end":"2022-03-31","comparable_group":1,"comparable_regions":[
           {"region":"japan","value":285},{"region":"asia","value":83},{"region":"middle_east","value":106}]}],
         "missing_years":[
           {"fy_end":"2024-03-31","fiscal_year":2024,"sales":811},
           {"fy_end":"2023-03-31","fiscal_year":2023,"sales":647}]}
        """

    private func columns() throws -> [BreakdownColumnInput] {
        let response = try JSONDecoder().decode(GeographyWaterfallResponse.self, from: Data(Self.json.utf8))
        return BreakdownBuilder.geographyColumns(response) { String(($0.fyEnd ?? "").prefix(4)) }
    }

    @Test func missingYearsBecomeOneNeutralSalesBarInYearOrder() throws {
        let columns = try columns()
        #expect(columns.map(\.label) == ["2022", "2023", "2024", "2025", "2026"])
        let layout = StackedLayout.make(columns: columns)
        #expect(layout.columnTotals[1] == 647)
        #expect(layout.columnTotals[2] == 811)
        #expect(layout.bars[1].map(\.colorIndex) == [-1])
        #expect(layout.bars.joined().allSatisfy { $0.mark == .none })
        #expect(columns.map(\.reorged) == [false, false, false, true, false])
    }

    @Test func stackOrderSkipsTheMissingYears() throws {
        let layout = StackedLayout.make(columns: try columns())
        func order(_ column: Int) -> [String] { layout.bars[column].sorted { $0.y > $1.y }.map(\.key) }
        #expect(order(4) == ["japan", "middle_east", "asia", "africa"])
        #expect(order(0) == ["japan", "middle_east", "asia"])
    }
}
