// 【廃止済み】company_filing_sections の機能は撤去した（読み書きするコードは無い）。
// 適用履歴（_fluent_migrations）と AddCodeSubmitDateTimeIndexes の前提のため migration だけ残す。
// company_filing_sections テーブルの作成。有報1件=1行の抽出済みセクション本文を JSONB 1 セルに持つ。
// payload は .json（Postgres では JSONB、SQLite では TEXT）。read は doc_id PK 一発、または
// code 一致＋submit_date_time 降順で最新1件を引く（JSONB 内部はクエリしない）。

import FluentKit

struct CreateCompanyFilingSections: AsyncMigration {
    // 適用済みの記録（_fluent_migrations）と一致させるため、移動前のモジュール名で固定する。
    var name: String { "BltServerCore.CreateCompanyFilingSections" }

    func prepare(on database: Database) async throws {
        try await database.schema("company_filing_sections")
            .field("doc_id", .string, .identifier(auto: false))
            .field("code", .string, .required)
            .field("submit_date_time", .string, .required)
            .field("payload", .json, .required)
            .field("cache_version", .string, .required)
            .field("section_keys", .string, .required)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema("company_filing_sections").delete()
    }
}
