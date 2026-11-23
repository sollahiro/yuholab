import SwiftData
import SwiftUI

/// 大画面のリスト。左に「あなたの追加した企業」、右に銘柄画面。
struct RegularListView: View {
    @Bindable var model: LargeScreenModel
    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]
    @Environment(\.modelContext) private var modelContext
    @State private var query = ""

    var body: some View {
        let pane = model.list
        Group {
            switch (pane.mode, pane.company) {
            case (.dual, .some):
                DualTickerView(model: model, tab: 1, query: $query)
                    .standardTopInset()
            case (.full, .some(let company)):
                RegularTickerPane(
                    company: company, layout: .waterfall, mode: .full,
                    onSetMode: { mode in model.update(1) { $0.mode = mode } },
                    onBack: { model.update(1) { $0.mode = .detail } },
                    usesSystemToolbar: true)
                    .id(company.code)
            default:
                split(pane).standardTopInset()
            }
        }
        .background(Theme.shell.ignoresSafeArea())
    }

    private func split(_ pane: LargeScreenModel.Pane) -> some View {
        AdaptiveSplit(fallbackWidth: 300) {
            leftList(selectedCode: pane.company?.code)
        } secondary: {
            if let company = pane.company {
                RegularTickerPane(
                    company: company, layout: .twoColumn, mode: .detail,
                    onSetMode: { mode in model.update(1) { $0.mode = mode } },
                    onBack: { model.update(1) { $0.company = nil } })
                    .id(company.code)
            } else {
                ContentUnavailableView(
                    "銘柄を選んでください", systemImage: "list.bullet",
                    description: Text("左のリストから選ぶと、ここに分析が出ます。"))
            }
        }
    }

    private func leftList(selectedCode: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("あなたの追加した企業")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.cardContentInset)
                .padding(.top, 14)
                .padding(.bottom, 8)
            if watched.isEmpty {
                Text("銘柄画面から追加できます。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, Theme.cardContentInset)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(watched) { item in
                        let company = CompanyRef(item)
                        Button {
                            model.open(company, tab: 1)
                        } label: {
                            HStack(spacing: 10) {
                                CompanyIconView(company, size: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(Format.displayName(company.name, fallback: company.code))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                        .lineLimit(1)
                                    Text(company.code)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textMuted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(company.code == selectedCode ? Theme.accent.opacity(0.18) : .clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.cardContentInset)
                        .contextMenu {
                            Button("リストから削除", systemImage: "bookmark.slash", role: .destructive) {
                                modelContext.delete(item)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}
