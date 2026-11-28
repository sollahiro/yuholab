import BlueTickerCore
import FluentKit
import Foundation

/// 地域別売上（geography 軸）の年次推移。格納済みの複数年を正規化して返す。
/// 地域の行が無い年（same_as / not_applicable）は年に出さない。全年が空なら `.absent`。
package func loadStoredGeographyWaterfall(
    code: String, years: Int, fiscalYear: String?, db: Database
) async throws -> BreakdownLoadResult {
    let code4 = String(code.prefix(4))
    guard !code4.isEmpty, code4.allSatisfy({ $0.isLetter || $0.isNumber }) else { return .absent }
    if fiscalYear == nil, years <= 0 { return .absent }
    // 直近の有報の地域別が省略・未取得か。年次推移は省略された年を落とすので、
    // 古い年の実データを最新のように見せないよう、最新期の状態を応答に載せる
    // （呼び出し側が別に問い合わせなくて済む。年と同じ候補行から出すので DB の追加読みは無い）。
    let (snapshots, latest) = try await loadServableBreakdownYearsWithLatest(
        code: code4, axis: breakdownAxisGeography, db: db)
    let latestStatus = latest ?? geographyLatestStatusOk
    guard !snapshots.isEmpty else {
        return latestStatus == geographyLatestStatusOk
            ? .absent : .notApplicable(reason: latestStatus)
    }
    var object = GeographyWaterfall.jsonObject(
        code: code4, years: snapshots, fiscalYear: fiscalYear, limit: max(1, years))
    let returned = object["years"] as? [[String: Any]] ?? []
    guard !returned.isEmpty else {
        return latestStatus == geographyLatestStatusOk
            ? .absent : .notApplicable(reason: latestStatus)
    }
    object["latest_status"] = latestStatus
    return .found(object)
}

/// 最新期の地域別が実データとして読める。
let geographyLatestStatusOk = "ok"
/// 最新期の地域別が未取得（行が無い・公開できない）。省略（`domestic_dominant_90pct` など）以外の 404。
let geographyLatestStatusUnavailable = "unavailable"
