import SwiftUI

/// 2 つ表示。左右に別々の銘柄画面を並べる。ペインをタップするとフォーカスが移る。
/// 各ペインの検索アイコンで銘柄を入れ替える。外側（compact）へ閉じるときはフォーカス側が残る。
struct DualTickerView: View {
    @Bindable var model: LargeScreenModel
    var tab: Int
    @Binding var query: String

    @State private var pickingSide: LargeScreenModel.Side?

    /// 操作中のペインの背景。枠ではなく、半分の画面の色で示す。
    private static let focusedFill = Color(red: 0.07, green: 0.11, blue: 0.16)

    var body: some View {
        let pane = model.pane(tab)
        if #available(iOS 27.1, *) {
            // 標準の ArrangementView（iOS 27.1+）。画面の向きに応じて左右／上下に分け、折り目（division の予約領域）と
            // 余白を自動で避ける。ナビゲーションは外側（TabView）に置く。
            ArrangementView(
                primary: {
                    tickerPane(pane.company, side: .left, focused: pane.focus == .left, edgeMargin: 0)
                        .safeAreaPadding(.leading, LargeMetrics.paneEdge)
                },
                secondary: {
                    tickerPane(pane.second, side: .right, focused: pane.focus == .right, edgeMargin: 0)
                        .safeAreaPadding(.trailing, LargeMetrics.paneEdge)
                }
            )
            .arrangementViewStyle(.split)
        } else {
            fallback(pane)
        }
    }

    /// iOS 27.1 より前: 自前の左右分割。左端は safeAreaInsets と最小余白で欠けないようにする。
    private func fallback(_ pane: LargeScreenModel.Pane) -> some View {
        GeometryReader { proxy in
            let leading = max(proxy.safeAreaInsets.leading, Self.minimumEdgeMargin)
            HStack(spacing: 0) {
                tickerPane(pane.company, side: .left, focused: pane.focus == .left, edgeMargin: leading)
                Divider().overlay(Color.white.opacity(0.08))
                tickerPane(pane.second, side: .right, focused: pane.focus == .right, edgeMargin: 0)
            }
            .ignoresSafeArea(edges: .leading)
        }
    }

    /// 端末の角丸で文字・アイコンが欠けない最小の左余白（フォールバックのみ）。
    private static let minimumEdgeMargin: CGFloat = 14

    @ViewBuilder
    private func tickerPane(
        _ company: CompanyRef?, side: LargeScreenModel.Side, focused: Bool, edgeMargin: CGFloat
    ) -> some View {
        Group {
            if let company, pickingSide != side {
                RegularTickerPane(
                    company: company, layout: .single, mode: .dual,
                    // モード切替は左ペインだけに出す（選択中の「2つ表示」を押すと一覧＋詳細へ戻る）。
                    onSetMode: side == .left ? { mode in model.update(tab) { $0.mode = mode } } : nil,
                    onBack: nil,
                    onSearch: { pickingSide = side },
                    background: focused ? Self.focusedFill : Theme.shell)
                    .id(company.code)
            } else {
                picker(side: side, hasCompany: company != nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, edgeMargin)
        .background(focused ? Self.focusedFill : Theme.shell)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { model.update(tab) { $0.focus = side } }
        )
    }

    private func picker(side: LargeScreenModel.Side, hasCompany: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("銘柄を選ぶ")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                if hasCompany {
                    Button("キャンセル") { pickingSide = nil }
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, Theme.cardContentInset)
            .padding(.top, 12)
            .padding(.bottom, 8)
            CompanySearchPanel(query: $query, selectedCode: nil) { company in
                model.update(tab) { pane in
                    if side == .left { pane.company = company } else { pane.second = company }
                    pane.focus = side
                }
                pickingSide = nil
                query = ""
            }
        }
        .background(Theme.shell)
    }
}
