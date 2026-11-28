import SwiftUI

/// 銘柄ページ最下部の「関連企業」カード。有報の記載に基づく取引先（顧客・仕入先をバッジで区別）・出資先・被保有・大株主を、
/// 種別ごとに上位 10 件まで出す。上場企業に名寄せできた相手はタップでその銘柄へ進む。
/// 取得は選んだ種別だけ（`GET /v1/companies/{code}/relations?type=`）。
struct RelationsCard: View {
    var code: String

    @State private var kind: RelationKind = .trading
    @State private var states: [RelationKind: RelationsLoadState] = [:]

    var body: some View {
        AnalysisCard(title: "関連企業") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("関係の種類", selection: $kind) {
                    ForEach(RelationKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

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

    /// 取引先は顧客（customer）と仕入先（supplier）を別々に取り、1 つのリストにまとめる。
    /// どちらか片方が 404（記載なし）でももう片方は出す。
    private func fetchRows(_ kind: RelationKind) async throws -> [RelationRow] {
        let code = code
        var items: [CompanyRelationItem] = []
        var firstError: Error?
        var hadSuccess = false
        for type in kind.apiTypes {
            do {
                let response = try await APIClient.shared.relations(
                    code: code, type: type, limit: kind.fetchLimit)
                items += response.relations
                hadSuccess = true
            } catch APIClientError.http(let status, _) where status == 404 {
                hadSuccess = true
            } catch {
                firstError = firstError ?? error
            }
        }
        if !hadSuccess, let firstError { throw firstError }
        return RelationRow.rows(from: items, kind: kind)
    }

    private func load(_ kind: RelationKind) async {
        if case .loaded = states[kind] { return }
        states[kind] = .loading
        do {
            let rows = try await fetchRows(kind)
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

enum RelationTag: String {
    case customer, supplier

    var title: String { self == .customer ? "顧客" : "仕入先" }
    var color: Color { self == .customer ? Theme.accent : Theme.textMuted }
}

enum RelationKind: String, CaseIterable, Identifiable {
    case trading, investee, heldBy, majorShareholder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trading: "取引先"
        case .investee: "出資先"
        case .heldBy: "被保有"
        case .majorShareholder: "大株主"
        }
    }

    /// REST の `type`。
    var apiTypes: [String] {
        switch self {
        case .trading: ["customer", "supplier"]
        case .investee: ["investee"]
        case .heldBy: ["investee_of"]
        case .majorShareholder: ["major_shareholder"]
        }
    }

    /// REST の並び（金額・順位の降順）の先頭から。同じ会社が複数行のぶんを見込んで多めに取る。
    var fetchLimit: Int { RelationRow.maxCount * 2 }

    var emptyText: String {
        switch self {
        case .trading: "顧客・仕入先の記載はありません"
        case .investee: "政策保有株式の記載はありません"
        case .heldBy: "他社の有報の政策保有株式に、この会社の株式が載っている記載はありません"
        case .majorShareholder: "大株主の記載はありません"
        }
    }

    var note: String {
        switch self {
        case .trading: "顧客は、この会社の有報の「主要な顧客」。仕入先は、他社の有報の「主要な顧客」にこの会社が載っている相手。金額は売上のうち顧客向け・仕入先の売上のうちこの会社向け（開示があるときのみ）。"
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
    /// 取引先の区分（顧客 / 仕入先）。取引先以外は nil。
    var tag: RelationTag?

    static let maxCount = 10

    static func rows(from items: [CompanyRelationItem], kind: RelationKind) -> [RelationRow] {
        var seen = Set<String>()
        var result: [RelationRow] = []
        // 取引先は顧客・仕入先を金額の降順で 1 リストにする（安定ソート）。
        let ordered = kind == .trading
            ? items.enumerated().sorted {
                ($0.element.amountYen ?? -1, -$0.offset) > ($1.element.amountYen ?? -1, -$1.offset)
            }.map(\.element)
            : items
        for (index, item) in ordered.enumerated() {
            // 同じ上場会社が複数行（例: みなし保有）のときは先頭だけ。取引先は区分ごとに数える。
            if let code = item.company?.code,
                !seen.insert("\(item.type)|\(code)").inserted
            { continue }
            result.append(
                RelationRow(
                    id: "\(kind.rawValue)|\(index)",
                    name: item.company?.name ?? item.nameRaw,
                    company: item.company.map {
                        CompanyRef(code: $0.code, name: $0.name, sector: "")
                    },
                    value: value(item, kind: kind),
                    tag: kind == .trading ? RelationTag(rawValue: item.type) : nil))
            if result.count == maxCount { break }
        }
        return result
    }

    private static func value(_ item: CompanyRelationItem, kind: RelationKind) -> String? {
        switch kind {
        case .trading:
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
                HStack(spacing: 6) {
                    if let tag = row.tag {
                        Text(tag.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(tag.color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .overlay(
                                Capsule().stroke(tag.color.opacity(0.6), lineWidth: 1))
                    }
                    if let company = row.company {
                        Text(company.code)
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
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
