import SwiftData
import SwiftUI

/// 大画面の銘柄画面。銘柄ピルではなく、アイコン・社名・コード/業種の見出しと Overview（最大 5 行）を常に出す。
/// 右上に星（リスト追加）と、全画面／2 つ表示の切替アイコン。共有ボタンは付けない。
/// 分析カードは `AnalysisView` を使う（compact の銘柄面とは別の枠。ナビバーのガラスには触らない）。
struct RegularTickerPane: View {
    var company: CompanyRef
    var layout: AnalysisLayout
    var mode: LargeScreenModel.Mode
    /// `nil` なら切替アイコンを出さない（2 つ表示の各ペイン）。
    var onSetMode: ((LargeScreenModel.Mode) -> Void)?
    /// 左上の ‹。一覧（リスト・フィード）へ戻る。
    var onBack: (() -> Void)?
    /// 2 つ表示のペインで、銘柄を入れ替える検索。
    var onSearch: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query private var watched: [WatchedCompany]
    @State private var resolvedSector = ""
    @State private var overview: String?
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if let overview {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .lineSpacing(3)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            AnalysisView(code: company.code, layout: effectiveLayout)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Theme.shell)
        // 同じペインで銘柄だけが変わっても、読み込み直す。
        .task(id: company.code) {
            resolvedSector = ""
            overview = nil
            await hydrate()
        }
        .task(id: company.code) { await loadOverview() }
    }

    /// 幅が足りないペインでは 2 列にしない。
    private var effectiveLayout: AnalysisLayout {
        layout == .twoColumn && width < 640 ? .single : layout
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.11), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("戻る")
            }
            CompanyIconView(displayCompany, size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.displayName(company.name, fallback: company.code))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let onSearch {
                iconButton("magnifyingglass", label: "銘柄を入れ替える", action: onSearch)
            }
            if let onSetMode {
                modeSwitch(onSetMode)
            }
            iconButton(isWatched ? "bookmark.fill" : "bookmark",
                label: isWatched ? "リストから削除" : "リストに追加", action: toggleWatch)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func modeSwitch(_ onSetMode: @escaping (LargeScreenModel.Mode) -> Void) -> some View {
        HStack(spacing: 2) {
            modeButton(.full, symbol: "arrow.up.left.and.arrow.down.right", label: "全画面で見る", onSetMode)
            modeButton(.dual, symbol: "rectangle.split.2x1", label: "2 銘柄を並べる", onSetMode)
        }
        .padding(3)
        .background(Color.white.opacity(0.09), in: Capsule())
    }

    private func modeButton(
        _ target: LargeScreenModel.Mode, symbol: String, label: String,
        _ onSetMode: @escaping (LargeScreenModel.Mode) -> Void
    ) -> some View {
        let selected = mode == target
        return Button {
            // 選択中をもう一度押すと、一覧＋詳細に戻る。
            onSetMode(selected ? .detail : target)
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                .frame(width: 36, height: 30)
                .background(selected ? Theme.elevated : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.11), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var subtitle: String {
        let sector = displayCompany.sector
        return sector.isEmpty ? company.code : "\(company.code) · \(sector)"
    }

    private var displayCompany: CompanyRef {
        CompanyRef(
            code: company.code, name: company.name,
            sector: company.sector.isEmpty ? resolvedSector : company.sector,
            iconURL: company.iconURL)
    }

    private var matchingRows: [WatchedCompany] { watched.filter { $0.code == company.code } }
    private var isWatched: Bool { !matchingRows.isEmpty }

    private func toggleWatch() {
        let matching = matchingRows
        if matching.isEmpty {
            modelContext.insert(
                WatchedCompany(
                    code: company.code, name: company.name, sector: displayCompany.sector,
                    iconURL: company.iconURL, sortOrder: WatchedCompany.nextSortOrder(among: watched)))
        } else {
            for item in matching { modelContext.delete(item) }
        }
    }

    private func hydrate() async {
        if company.sector.isEmpty {
            if let cached = await APIClient.shared.cachedFinancials(code: company.code), !cached.sector.isEmpty {
                resolvedSector = cached.sector
            } else if let loaded = try? await APIClient.shared.financials(code: company.code), !loaded.sector.isEmpty {
                resolvedSector = loaded.sector
            }
        }
        for existing in watched where existing.code == company.code && existing.sector.isEmpty {
            if !displayCompany.sector.isEmpty { existing.sector = displayCompany.sector }
        }
        CompanyHistory.record(displayCompany)
    }

    private func loadOverview() async {
        func clean(_ text: String) -> String? {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let cached = await APIClient.shared.cachedOverview(code: company.code) {
            overview = clean(cached.overview)
        }
        if let loaded = try? await APIClient.shared.overview(code: company.code) {
            overview = clean(loaded.overview)
        }
    }
}
