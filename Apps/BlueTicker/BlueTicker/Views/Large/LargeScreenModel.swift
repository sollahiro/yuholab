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
