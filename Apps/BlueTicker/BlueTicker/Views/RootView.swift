import SwiftData
import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var tab = 0
    @State private var searchPath = NavigationPath()
    @State private var listPath = NavigationPath()
    @State private var comparePath = NavigationPath()
    @State private var searchQuery = ""
    @State private var feedSession = FeedSession()
    /// 大画面（regular 幅）の状態。開閉・回転でサイズクラスが変わっても失わないよう、ここで持つ。
    @State private var large = LargeScreenModel()
    private let router = IntentRouter.shared
    @Query(sort: \WatchedCompany.sortOrder) private var watched: [WatchedCompany]

    var body: some View {
        TabView(selection: $tab) {
            homeTab
                .tabItem { Label("ホーム", systemImage: "house") }
                .tag(0)

            listTab
                .tabItem { Label("リスト", systemImage: "list.bullet") }
                .tag(1)

            compareTab
                .tabItem { Label("比較", systemImage: "chart.bar") }
                .tag(2)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .toolbarBackground(.hidden, for: .tabBar)
        // 下へスクロールするとタブバーを丸く縮めて端へ寄せる。画面ごとに切り替えると、
        // 戻り終わりで縮んだバーがアニメーションなしで戻るので、全画面で同じにする。
        .tabBarMinimizeBehavior(.onScrollDown)
        .task(id: watched.map(\.code).joined(separator: ",")) {
            let codes = Array(Set(watched.map(\.code)))
            // 銘柄面など interactive GET を先に出す。先読みは 429 で止めて間引く。
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await APIClient.shared.prefetchAnalysis(codes: codes)
        }
        .onChange(of: router.pending, initial: true) { _, company in
            // Siri / ショートカットの「結果画面を開く」。ホームタブに銘柄面を積む。
            guard let company else { return }
            router.pending = nil
            tab = 0
            if isRegular {
                large.update(0) { $0.mode = .detail }
                large.open(company, tab: 0)
            } else {
                searchPath = NavigationPath([company])
            }
        }
        .onChange(of: isRegular) { _, regular in
            // 開く: 外側で開いていた画面に対応する内側の画面へ。閉じる: 内側の画面に対応する外側の画面へ。
            if regular {
                large.adoptCompact()
            } else {
                large.prepareForCompact()
                searchPath = Self.path(for: large.compactCompany[0])
                listPath = Self.path(for: large.compactCompany[1])
                comparePath = NavigationPath([CompareRoute.group(large.compareGroup)])
            }
        }
        .onChange(of: searchPath.count) { _, count in
            if count == 0 { large.compactCompany[0] = nil }
        }
        .onChange(of: listPath.count) { _, count in
            if count == 0 { large.compactCompany[1] = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            // フォアグラウンド復帰でも、前回の取得から 1 時間を過ぎていれば RSS を再検証する。
            guard phase == .active else { return }
            Task { await feedSession.refresh() }
        }
    }

    private var isRegular: Bool { horizontalSizeClass == .regular }

    private static func path(for company: CompanyRef?) -> NavigationPath {
        company.map { NavigationPath([$0]) } ?? NavigationPath()
    }

    @ViewBuilder
    private var homeTab: some View {
        if isRegular {
            RegularHomeView(model: large, feed: feedSession, query: $searchQuery)
        } else {
            NavigationStack(path: $searchPath) {
                TopView(query: $searchQuery, feed: feedSession)
                    .readableWidth()
                    .navigationDestination(for: CompanyRef.self) { ticker($0, tab: 0) }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var listTab: some View {
        if isRegular {
            RegularListView(model: large)
        } else {
            NavigationStack(path: $listPath) {
                WatchlistView(path: $listPath)
                    .readableWidth()
                    .navigationDestination(for: CompanyRef.self) { ticker($0, tab: 1) }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var compareTab: some View {
        if isRegular {
            RegularCompareView(model: large)
        } else {
            NavigationStack(path: $comparePath) {
                CompareView()
                    .readableWidth()
                    .navigationDestination(for: CompareRoute.self) { route in
                        switch route {
                        case .group(let id):
                            if let group = BenchmarkCatalog.group(id: id) {
                                BenchmarkRankingView(group: group, path: $comparePath)
                                    .readableWidth()
                            }
                        }
                    }
                    .navigationDestination(for: CompanyRef.self) { ticker($0, tab: 2) }
            }
            .toolbarTitleDisplayMode(.inline)
        }
    }

    private func ticker(_ company: CompanyRef, tab: Int) -> some View {
        TickerView(company: company)
            .readableWidth()
            .onAppear {
                if tab < 2 { large.compactCompany[tab] = company }
            }
    }
}
