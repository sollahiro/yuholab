import SwiftData
import SwiftUI

/// 大画面のホーム。左に常設の検索（未入力は履歴、入力中は候補）、右に更新フィード。
/// 行を選ぶと右ペインが銘柄画面に切り替わり、‹ でフィードに戻る。
struct RegularHomeView: View {
    @Bindable var model: LargeScreenModel
    @Bindable var feed: FeedSession
    @Binding var query: String

    var body: some View {
        let pane = model.home
        Group {
            switch (pane.mode, pane.company) {
            case (.dual, .some):
                DualTickerView(model: model, tab: 0, query: $query)
            case (.full, .some(let company)):
                RegularTickerPane(
                    company: company, layout: .waterfall, mode: .full,
                    onSetMode: { mode in model.update(0) { $0.mode = mode } },
                    onBack: { model.update(0) { $0.mode = .detail } })
                    .id(company.code)
            default:
                split(pane)
            }
        }
        .background(Theme.shell.ignoresSafeArea())
        .task { await feed.refresh() }
    }

    private func split(_ pane: LargeScreenModel.Pane) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.frame(height: 8)
                CompanySearchPanel(query: $query, selectedCode: pane.company?.code) { company in
                    model.open(company, tab: 0)
                }
            }
            .frame(width: 300)
            Divider().overlay(Color.white.opacity(0.08))
            Group {
                if let company = pane.company {
                    RegularTickerPane(
                        company: company, layout: .twoColumn, mode: .detail,
                        onSetMode: { mode in model.update(0) { $0.mode = mode } },
                        onBack: { model.update(0) { $0.company = nil } })
                        .id(company.code)
                } else {
                    FeedListPane(feed: feed) { company in model.open(company, tab: 0) }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
