import SwiftUI

/// 大画面（`horizontalSizeClass == .regular`。iPhone Duo を開いた内側など）の UI 状態。
/// `RootView` が持ち、サイズクラスが変わってもタブ・選択中の銘柄・表示モードを失わない。
/// compact の `NavigationPath` は読み戻せないので、閉じる／開くときの対応づけはここの型付き状態で行う。
@MainActor
@Observable
final class LargeScreenModel {
    enum Side { case left, right }

    /// 銘柄を開いているときの見せ方。
    enum Mode {
        /// 左に一覧（検索・リスト）、右に銘柄画面（分析カード 2 列）。
        case detail
        /// 銘柄画面だけを全面に。収益構造のウォーターフォールを大きく出す。
        case full
        /// 左右に別々の銘柄画面。
        case dual
    }

    /// ホーム・リストそれぞれの、開いている銘柄と見せ方。
    struct Pane: Equatable {
        var company: CompanyRef?
        var mode: Mode = .detail
        /// `.dual` の右ペイン。
        var second: CompanyRef?
        var focus: Side = .left

        /// 閉じて外側（compact）へ戻すときに残す銘柄。2 つ表示ならフォーカス側。
        var focusedCompany: CompanyRef? {
            if mode == .dual, focus == .right, let second { return second }
            return company
        }
    }

    var home = Pane()
    var list = Pane()

    /// 同業比較。選択中の業種・指標とピン留めした銘柄コード。
    var compareGroup: String = BenchmarkCatalog.groups.first?.id ?? ""
    var compareMetric: String = ""
    var pinned: [String] = []

    /// compact で最後に開いていた銘柄（タブ番号 → 銘柄）。開く（compact → regular）ときに右ペインへ引き継ぐ。
    var compactCompany: [Int: CompanyRef] = [:]

    func pane(_ tab: Int) -> Pane { tab == 0 ? home : list }

    func update(_ tab: Int, _ change: (inout Pane) -> Void) {
        if tab == 0 { change(&home) } else { change(&list) }
    }

    /// 銘柄を開く。2 つ表示ならフォーカス側のペインを入れ替える。
    func open(_ company: CompanyRef, tab: Int) {
        update(tab) { pane in
            if pane.mode == .dual {
                if pane.focus == .right { pane.second = company } else { pane.company = company }
            } else {
                pane.company = company
            }
        }
    }

    /// 閉じる（regular → compact）。内側の画面に対応する外側の画面へ。
    func prepareForCompact() {
        compactCompany[0] = home.focusedCompany
        compactCompany[1] = list.focusedCompany
        home.mode = .detail
        list.mode = .detail
    }

    /// 開く（compact → regular）。外側で開いていた銘柄を右ペインへ。
    func adoptCompact() {
        for tab in [0, 1] {
            let company = compactCompany[tab]
            update(tab) {
                $0.company = company
                $0.mode = .detail
                $0.second = nil
                $0.focus = .left
            }
        }
    }
}


private struct SideControlsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// ツールバー・タブバーが画面の側面に縦に並んでいるか（iPhone Duo の外側・内側横向きなど）。
    /// 機種や画面の縦横比は見ず、ウィンドウの safe area の左右の非対称（片側だけ大きい）で判定する。
    /// 通常の iPhone は縦向きで左右とも 0、横向きでも左右対称（切り欠き分が同じ）なので対象外になる。
    var hasSideControls: Bool {
        get { self[SideControlsKey.self] }
        set { self[SideControlsKey.self] = newValue }
    }
}

enum SideControls {
    /// 左右の safe area の差がこれ以上なら、側面にコントロールがあるとみなす（pt）。Duo のレールは 84pt。
    static let asymmetryThreshold: CGFloat = 40

    static func isPresent(_ insets: EdgeInsets) -> Bool {
        abs(insets.leading - insets.trailing) >= asymmetryThreshold
    }
}


/// 大画面の左右の余白をそろえるための定数。要素の端の余白は `Theme.cardContentInset`（12pt）に統一し、
/// ペインの外側に `paneEdge`（8pt）を足して、画面の端から 20pt（iOS 27.1 の `contentMargins(for: .container)` の
/// leading 値と同じ）にする。レール側の safe area はこれとは別にシステムが確保する。
/// 左右の端だけに足す（ペイン間は足さない）。通常の iPhone（compact）には使わない。
enum LargeMetrics {
    static let paneEdge: CGFloat = 8
}

/// 一覧（プライマリ）と詳細（セカンダリ）の 2 ペイン。iOS 27.1 以降は標準の `ArrangementView`（`.split`）で、
/// 向きに応じた左右／上下の分割と、折り目・余白の回避をシステムに任せる。それ以前は自前の左右分割（固定幅）。
struct AdaptiveSplit<Primary: View, Secondary: View>: View {
    /// プライマリが占める割合（`ArrangementView` の分割比）。フォールバックでは固定幅 `fallbackWidth` を使う。
    var ratio: CGFloat = 0.36
    var fallbackWidth: CGFloat = 300
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    var body: some View {
        if #available(iOS 27.1, *) {
            // 分割比は、プライマリ側のビューに付けて伝える（ArrangementView 自体ではなく）。
            ArrangementView(
                primary: { primary.splitArrangementLayoutRatio(ratio).safeAreaPadding(.leading, LargeMetrics.paneEdge) },
                secondary: { secondary.safeAreaPadding(.trailing, LargeMetrics.paneEdge) }
            )
            .arrangementViewStyle(.split)
        } else {
            HStack(spacing: 0) {
                primary.safeAreaPadding(.leading, LargeMetrics.paneEdge).frame(width: fallbackWidth)
                Divider().overlay(Color.white.opacity(0.08))
                secondary.safeAreaPadding(.trailing, LargeMetrics.paneEdge).frame(maxWidth: .infinity)
            }
        }
    }
}


/// 大画面の各画面の上端を、全画面モードの標準ツールバー画面（`NavigationStack`）と同じ高さにそろえる。
/// 側面にコントロールがあるとき（Duo の横向きなど）、標準のバーがある画面は上に 24pt の safe area が付き、
/// コンテンツの上端がステータスバーの時刻の高さに合う。項目の無い画面（ホーム・リスト・同業比較）は
/// バー自体が無いので、この値を safe area として足す（空のバーや見えない項目では領域が付かない／別の項目が出るため）。
/// 値は、全画面モードで `safeAreaInsets.top` を実測したもの（Duo 内側の横向き）。
private struct StandardTopInset: ViewModifier {
    static let statusLineInset: CGFloat = 24
    @Environment(\.hasSideControls) private var hasSideControls

    func body(content: Content) -> some View {
        content.safeAreaPadding(.top, hasSideControls ? Self.statusLineInset : 0)
    }
}

extension View {
    func standardTopInset() -> some View { modifier(StandardTopInset()) }
}
