// 有報(120)の取り込み候補選定。breakdowns / statements / statement-notes / industry-kpis の各取り込みステージが
// 共用する（旧 filing-sections ステージの廃止後も、候補選定ロジックだけここに残している）。
//
// 保持窓は「各社 提出日時降順の直近 years 件」（有報は通常年1件のため ≈ years 年）。

import BltStoreCore
import BlueTickerCore
import FluentKit
import Foundation
import Logging

/// 取り込みで対象にする有報の件数（1社あたり直近 N 件。有報は通常年1件のため ≈ N 年）。
/// 財務取り込みの financials 計算年数（6年）と揃える。
let annualReportIngestYears = 6

/// 保持窓内の1書類。`yearRank` は当該社の窓内での新しさ（0 が最新の会社有報）。
struct FilingDocCandidate: Equatable, Sendable {
    var docID: String
    var code: String
    var submitDateTime: String
    var yearRank: Int

    init(docID: String, code: String, submitDateTime: String, yearRank: Int = 0) {
        self.docID = docID
        self.code = code
        self.submitDateTime = submitDateTime
        self.yearRank = yearRank
    }
}

/// 取り込み候補（保持窓内。docID・4桁コード・提出日時・yearRank）と、保持窓を超えた既存書類の docID（purge 対象）。
struct FilingSectionCandidateSets {
    let keep: [FilingDocCandidate]
    let purge: [String]
}

/// 会社有報（120・府令010）の候補書類一覧を 1 回だけ読む。対象府令・書類種別は SQL で絞る。
/// ステージ間で候補集合を共有するときはこの一覧を `filingSectionCandidates(docs:...)` へ渡すと
/// DB 再往復しない。保持窓（社ごと直近 N 件）と purge は `filingSectionCandidates` が
/// この一覧の上で決める。種類・府令以外の行は SQL で落とす（全表 hydrate しない）。
func annualReportDisclosureDocs(db: Database, logger: Logger? = nil) async throws
    -> [EdinetDocumentListing]
{
    try await withDbRetry(logger: logger, context: "有報一覧") {
        try await EdinetDocumentListing.query(on: db)
            .filter(\.$docTypeCode == Api.docTypeAnnualReport)
            .filter(\.$ordinanceCode == Api.ordinanceCompanyDisclosure)
            .all()
    }
}

/// 取り込み候補（保持窓内）と purge 対象をまとめて返す。
/// 「上場（listedCodes）× 会社有報(120・府令010) × 各社 提出日時降順の直近 years 件」を keep、
/// それを超えた分を purge とする。docType 120 でも特定有価証券府令(030)の信託受益証券等は除外。
/// `explicitCodes` を渡すとさらにその集合へ絞る（`--codes` 手動指定。`nil` は絞り込みなし）。
/// `explicitDocIDs` を渡すと keep をその有報 docID だけにし、purge はしない（`--doc-ids`。
/// 訂正がある会社-FY だけの再 ingest 用。保持窓の外でも指定 doc は残す）。
/// `sec_code` が空の行は master の EDINETコード→証券コードで発行体を特定する。
func filingSectionCandidates(
    db: Database, listedCodes: Set<String>, explicitCodes: Set<String>? = nil, years: Int,
    logger: Logger? = nil, explicitDocIDs: Set<String>? = nil
) async throws -> FilingSectionCandidateSets {
    await filingSectionCandidates(
        docs: try annualReportDisclosureDocs(db: db, logger: logger),
        listedCodes: listedCodes, explicitCodes: explicitCodes, years: years,
        explicitDocIDs: explicitDocIDs)
}

/// `annualReportDisclosureDocs` の読み済み一覧から候補集合を組み立てる（DB 再往復なし）。
func filingSectionCandidates(
    docs: [EdinetDocumentListing], listedCodes: Set<String>, explicitCodes: Set<String>? = nil,
    years: Int, explicitDocIDs: Set<String>? = nil
) async -> FilingSectionCandidateSets {
    let listedSecByEdinet = await listedSecCodeByEdinetCode()

    // 4 桁コードごとに会社有報をまとめる。secCode は 5 桁（4 桁＋種別 1 桁 "0"）。
    // 空の secCode は listed な edinet_code があればその発行体に寄せる。
    var byCode: [String: [(docID: String, submitDateTime: String)]] = [:]
    for doc in docs {
        guard let docID = doc.id,
            let code = listedIssuerCode(
                secCode: doc.secCode, edinetCode: doc.edinetCode,
                listedSecCodeByEdinetCode: listedSecByEdinet)
        else { continue }
        guard listedCodes.contains(code) else { continue }
        if let explicit = explicitCodes, !explicit.contains(code) { continue }
        byCode[code, default: []].append((docID, doc.submitDateTime))
    }

    var keep: [FilingDocCandidate] = []
    var purge: [String] = []
    for (code, docs) in byCode {
        let sorted = docs.sorted { $0.submitDateTime > $1.submitDateTime }
        for (rank, d) in sorted.prefix(years).enumerated() {
            keep.append(
                FilingDocCandidate(
                    docID: d.docID, code: code, submitDateTime: d.submitDateTime, yearRank: rank))
        }
        for d in sorted.dropFirst(years) {
            purge.append(d.docID)
        }
    }
    if let ids = explicitDocIDs {
        var selected: [FilingDocCandidate] = []
        for (code, companyDocs) in byCode {
            let sorted = companyDocs.sorted { $0.submitDateTime > $1.submitDateTime }
            for (rank, d) in sorted.enumerated() where ids.contains(d.docID) {
                selected.append(
                    FilingDocCandidate(
                        docID: d.docID, code: code, submitDateTime: d.submitDateTime, yearRank: rank))
            }
        }
        selected.sort {
            if $0.yearRank != $1.yearRank { return $0.yearRank < $1.yearRank }
            if $0.submitDateTime != $1.submitDateTime { return $0.submitDateTime > $1.submitDateTime }
            return $0.docID < $1.docID
        }
        return FilingSectionCandidateSets(keep: selected, purge: [])
    }
    keep.sort {
        if $0.yearRank != $1.yearRank { return $0.yearRank < $1.yearRank }
        if $0.submitDateTime != $1.submitDateTime { return $0.submitDateTime > $1.submitDateTime }
        return $0.docID < $1.docID
    }
    return FilingSectionCandidateSets(keep: keep, purge: purge)
}
