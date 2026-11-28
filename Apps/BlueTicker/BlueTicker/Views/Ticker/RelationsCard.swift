import SwiftUI

/// 銘柄ページ最下部の「関連企業」カード。有報の記載に基づく取引先（販売先・仕入先）・出資先・被保有・大株主を、
/// 種別ごとに上位 10 件まで出す。上場企業に名寄せできた相手はタップでその銘柄へ進む。
/// 取得は選んだ種別だけ（`GET /v1/companies/{code}/relations?type=`）。
struct RelationsCard: View {
    var code: String

    @State private var group: RelationGroup = .trading
    @State private var tradingKind: RelationKind = .customer
    @State private var states: [RelationKind: RelationsLoadState] = [:]

    /// 画面で選んでいる種別。取引先は販売先・仕入先の切り替えに従う。
    private var kind: RelationKind {
        group == .trading ? tradingKind : group.kind ?? .investee
    }

    var body: some View {
        AnalysisCard(title: "関連企業") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("関係の種類", selection: $group) {
                    ForEach(RelationGroup.allCases) { group in
                        Text(group.title).tag(group)
                    }
                }
                .pickerStyle(.segmented)

                if group == .trading {
                    Picker("取引先の分類", selection: $tradingKind) {
                        Text(RelationKind.customer.title).tag(RelationKind.customer)
                        Text(RelationKind.supplier.title).tag(RelationKind.supplier)
                    }
                    .pickerStyle(.segmented)
                }

                switch states[kind] ?? .loading {
                case .loading:
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 120)
                case .empty:
                    AnalysisNote(text: kind.emptyText)
                        .frame(minHeight: 60, alignment: .center)
                case .failed(let message):
                    AnalysisNote(text: message)
                        .frame(minHeight: 60, alignment: .center)
                case .loaded(let rows):
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            RelationRowView(row: row)
                            if row.id != rows.last?.id {
                                Divider().overlay(Theme.textMuted.opacity(0.25))
                            }
                        }
                    }
                }
                AnalysisNote(text: kind.note)
            }
        }
        .task(id: "\(code)|\(kind.rawValue)") { await load(kind) }
        .onChange(of: code) { states = [:] }
    }

    private func load(_ kind: RelationKind) async {
        if case .loaded = states[kind] { return }
        states[kind] = .loading
        do {
            let response = try await APIClient.shared.relations(
                code: code, type: kind.apiType, limit: kind.fetchLimit)
            let rows = RelationRow.rows(from: response.relations, kind: kind)
            states[kind] = rows.isEmpty ? .empty : .loaded(rows)
        } catch APIClientError.http(let status, _) where status == 404 {
            states[kind] = .empty
        } catch is CancellationError {
            states[kind] = nil
        } catch {
            states[kind] = .failed(error.localizedDescription)
        }
    }
}

// MARK: - モデル

enum RelationsLoadState {
    case loading
    case empty
    case failed(String)
    case loaded([RelationRow])
}

/// 上段のタブ。取引先は販売先（customer）と仕入先（supplier）をまとめる。
enum RelationGroup: String, CaseIterable, Identifiable {
    case trading, investee, heldBy, majorShareholder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trading: "取引先"
        case .investee: RelationKind.investee.title
        case .heldBy: RelationKind.heldBy.title
        case .majorShareholder: RelationKind.majorShareholder.title
        }
    }

    /// 取引先以外は 1 種別に対応する。
    var kind: RelationKind? {
        switch self {
        case .trading: nil
        case .investee: .investee
        case .heldBy: .heldBy
        case .majorShareholder: .majorShareholder
        }
    }
}

enum RelationKind: String, CaseIterable, Identifiable {
    case customer, supplier, investee, heldBy, majorShareholder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .customer: "販売先"
        case .supplier: "仕入先"
        case .investee: "出資先"
        case .heldBy: "被保有"
        case .majorShareholder: "大株主"
        }
    }

    /// REST の `type`。
    var apiType: String {
        switch self {
        case .customer: "customer"
        case .supplier: "supplier"
        case .investee: "investee"
        case .heldBy: "investee_of"
        case .majorShareholder: "major_shareholder"
        }
    }

    /// REST の並び（金額・順位の降順）の先頭から。同じ会社が複数行のぶんを見込んで多めに取る。
    var fetchLimit: Int { RelationRow.maxCount * 2 }

    var emptyText: String {
        switch self {
        case .customer: "この会社の有報に、主要な顧客の記載はありません"
        case .supplier: "他社の有報で、主要な顧客として載っている記載はありません"
        case .investee: "政策保有株式の記載はありません"
        case .heldBy: "他社の有報の政策保有株式に、この会社の株式が載っている記載はありません"
        case .majorShareholder: "大株主の記載はありません"
        }
    }

    var note: String {
        switch self {
        case .customer: "この会社の有報の「主要な顧客」に載っている販売先。金額はこの会社の売上のうちその相手向け（開示があるときのみ）。"
        case .supplier: "他社の有報の「主要な顧客」に、この会社が載っている相手。金額は相手の売上のうちこの会社向け。"
        case .investee: "政策保有株式（純投資以外）の銘柄。金額は貸借対照表計上額。"
        case .heldBy: "他社の有報の政策保有株式に、この会社の株式が載っている上場会社。金額は相手が持つこの会社の株式の計上額。載るのは各社の開示の範囲（主に保有額の上位）のみ。"
        case .majorShareholder: "名義上の上位株主。割合は発行済株式に対する持株比率。"
        }
    }
}

struct RelationRow: Identifiable {
    var id: String
    var name: String
    /// 上場企業に名寄せできた相手。nil は非上場・未名寄せ（遷移しない）。
    var company: CompanyRef?
    var value: String?

    static let maxCount = 10

    static func rows(from items: [CompanyRelationItem], kind: RelationKind) -> [RelationRow] {
        var seen = Set<String>()
        var result: [RelationRow] = []
        for (index, item) in items.enumerated() {
            // 同じ上場会社が複数行（例: みなし保有）のときは先頭だけ。
            if let code = item.company?.code, !seen.insert(code).inserted { continue }
            result.append(
                RelationRow(
                    id: "\(kind.rawValue)|\(index)",
                    name: item.company?.name ?? item.nameRaw,
                    company: item.company.map {
                        CompanyRef(code: $0.code, name: $0.name, sector: "")
                    },
                    value: value(item, kind: kind)))
            if result.count == maxCount { break }
        }
        return result
    }

    private static func value(_ item: CompanyRelationItem, kind: RelationKind) -> String? {
        switch kind {
        case .customer, .supplier:
            return item.amountYen.map { Format.okuYen($0) }
        case .investee, .heldBy:
            return item.investee?.bookValueYen.map { Format.okuYen($0) }
        case .majorShareholder:
            return item.majorShareholder?.ratio.map { Format.percent($0 * 100) }
        }
    }
}

// MARK: - 行

private struct RelationRowView: View {
    var row: RelationRow

    var body: some View {
        if let company = row.company {
            NavigationLink(value: company) {
                content(isLink: true)
            }
            .buttonStyle(.plain)
        } else {
            content(isLink: false)
                .accessibilityElement(children: .combine)
        }
    }

    private func content(isLink: Bool) -> some View {
        HStack(spacing: 12) {
            if let company = row.company {
                CompanyIconView(company, size: 32)
            } else {
                // 名寄せできない相手（非上場など）。アイコンは取りに行かない。
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.elevated)
                    Image(systemName: "building.2")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.displayName(row.name, fallback: row.name))
                    .font(.subheadline)
                    .foregroundStyle(row.company == nil ? Theme.textMuted : Theme.text)
                    .lineLimit(2)
                if let company = row.company {
                    Text(company.code)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            Spacer(minLength: 8)
            if let value = row.value {
                Text(value)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
            if isLink {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
