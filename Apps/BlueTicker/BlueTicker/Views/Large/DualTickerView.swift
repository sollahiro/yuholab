import SwiftUI

/// 2 つ表示。左右に別々の銘柄画面を並べる。ペインをタップするとフォーカスが移る。
/// 各ペインの検索アイコンで銘柄を入れ替える。外側（compact）へ閉じるときはフォーカス側が残る。
struct DualTickerView: View {
    @Bindable var model: LargeScreenModel
    var tab: Int
    @Binding var query: String

    @State private var pickingSide: LargeScreenModel.Side?

    var body: some View {
        let pane = model.pane(tab)
        HStack(spacing: 0) {
            tickerPane(pane.company, side: .left, focused: pane.focus == .left)
            Divider().overlay(Color.white.opacity(0.08))
            tickerPane(pane.second, side: .right, focused: pane.focus == .right)
        }
    }

    @ViewBuilder
    private func tickerPane(_ company: CompanyRef?, side: LargeScreenModel.Side, focused: Bool) -> some View {
        Group {
            if let company, pickingSide != side {
                RegularTickerPane(
                    company: company, layout: .single, mode: .dual,
                    // モード切替は左ペインだけに出す（選択中の「2つ表示」を押すと一覧＋詳細へ戻る）。
                    onSetMode: side == .left ? { mode in model.update(tab) { $0.mode = mode } } : nil,
                    onBack: nil,
                    onSearch: { pickingSide = side })
                    .id(company.code)
            } else {
                picker(side: side, hasCompany: company != nil)
            }
        }
        .frame(maxWidth: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent.opacity(focused ? 0.45 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            if focused {
                Text("操作中")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.accent, in: Capsule())
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
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
            .padding(.horizontal, 16)
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
