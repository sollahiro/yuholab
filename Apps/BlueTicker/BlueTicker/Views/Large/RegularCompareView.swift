import SwiftUI

/// 大画面の同業比較。左に業種・指標チップ・ランキング（行でピン留め）、右に選択した指標の説明（見出し行の右側）、
/// ピン留めした銘柄の棒グラフ、過去の推移、指標の比較表。
/// 過去の推移は、現行の静的 JSON／REST が「会社ごとに最新の有報 1 期分」しか返さないため、枠だけ出して「準備中」と示す
/// （API の拡張が必要。ここで値を作らない）。
struct RegularCompareView: View {
    @Bindable var model: LargeScreenModel

    private enum Phase {
        case loading
        case loaded([BenchmarkCompany])
        case failed(String)
    }

    @State private var phase: Phase = .loading

    private var group: BenchmarkGroup? { BenchmarkCatalog.group(id: model.compareGroup) }

    private var metric: BenchmarkMetric? {
        guard let group else { return nil }
        return group.metrics.first { $0.key == model.compareMetric } ?? group.metrics.first
    }

    var body: some View {
        Group {
            if let group, let metric {
                HStack(spacing: 0) {
                    left(group: group, metric: metric)
                        .frame(width: 340)
                    Divider().overlay(Color.white.opacity(0.08))
                    right(group: group, metric: metric)
                        .frame(maxWidth: .infinity)
                }
            } else {
                ContentUnavailableView("比較できる業種がありません", systemImage: "chart.bar")
            }
        }
        .background(Theme.shell.ignoresSafeArea())
        .task(id: model.compareGroup) { await load() }
    }

    // MARK: 左

    private func left(group: BenchmarkGroup, metric: BenchmarkMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(BenchmarkCatalog.groups) { item in
                        Button {
                            selectGroup(item)
                        } label: {
                            Label(item.title, systemImage: item.id == group.id ? "checkmark" : item.symbol)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: group.symbol)
                        Text(group.title).font(.headline)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .foregroundStyle(Theme.text)
                }
                .accessibilityLabel("業種を選ぶ")
                .accessibilityValue(group.title)
                Spacer(minLength: 0)
                if case .loaded(let companies) = phase {
                    Text("\(companies.count)社")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.metrics) { item in
                        SectorTag(sector: item.title, selected: item.key == metric.key)
                            .onTapGesture { model.compareMetric = item.key }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .padding(.horizontal, 16)
            }
            switch phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
            case .failed(let message):
                ContentUnavailableView {
                    Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("再読み込み") { Task { await load() } }
                }
            case .loaded(let companies):
                ranking(companies, metric: metric)
            }
        }
    }

    private func rows(_ companies: [BenchmarkCompany], metric: BenchmarkMetric) -> [(BenchmarkCompany, Double)] {
        companies.compactMap { company -> (BenchmarkCompany, Double)? in
            guard let value = company.kpis[metric.key]?.value else { return nil }
            return (company, value)
        }
        .sorted { metric.higherIsBetter ? $0.1 > $1.1 : $0.1 < $1.1 }
    }

    private func ranking(_ companies: [BenchmarkCompany], metric: BenchmarkMetric) -> some View {
        let sorted = rows(companies, metric: metric)
        let maxValue = max(sorted.map { abs($0.1) }.max() ?? 1, .ulpOfOne)
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(sorted.enumerated()), id: \.element.0.id) { index, row in
                    rankingRow(rank: index + 1, company: row.0, value: row.1, maxValue: maxValue, metric: metric)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func rankingRow(
        rank: Int, company: BenchmarkCompany, value: Double, maxValue: Double, metric: BenchmarkMetric
    ) -> some View {
        let pinned = model.pinned.contains(company.code)
        return Button {
            togglePin(company.code)
        } label: {
            HStack(spacing: 9) {
                Text("\(rank)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 18)
                CompanyIconView(company.ref, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.displayName(company.name, fallback: company.code))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(metric.band.color(for: value))
                                    .frame(width: max(5, geo.size.width * min(abs(value) / maxValue, 1)))
                            }
                    }
                    .frame(height: 5)
                }
                Text(metric.formatted(value))
                    .font(.footnote.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 58, alignment: .trailing)
                Image(systemName: pinned ? "pin.circle.fill" : "pin.circle")
                    .font(.title3)
                    .foregroundStyle(pinned ? Theme.accent : Theme.idleTab)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(pinned ? Theme.accent.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(company.name) \(metric.formatted(value))")
        .accessibilityValue(pinned ? "ピン留め中" : "")
        .accessibilityHint("ピン留めして右で並べて比べます")
    }

    /// 業種を切り替える。指標とピン留めは業種ごとに意味が変わるので選び直す。
    private func selectGroup(_ item: BenchmarkGroup) {
        guard item.id != model.compareGroup else { return }
        model.compareGroup = item.id
        model.compareMetric = item.metrics.first?.key ?? ""
        model.pinned = []
        phase = .loading
    }

    private func togglePin(_ code: String) {
        if let index = model.pinned.firstIndex(of: code) {
            model.pinned.remove(at: index)
        } else if model.pinned.count < 5 {
            model.pinned.append(code)
        }
    }

    // MARK: 右

    private func right(group: BenchmarkGroup, metric: BenchmarkMetric) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardContentInset) {
                if case .loaded(let companies) = phase {
                    let pinnedCompanies = model.pinned.compactMap { code in companies.first { $0.code == code } }
                    metricCard(metric: metric, pinned: pinnedCompanies)
                    trendCard(metric: metric)
                    if !pinnedCompanies.isEmpty {
                        tableCard(group: group, pinned: pinnedCompanies)
                    }
                }
            }
            .padding(Theme.cardContentInset)
        }
        .scrollIndicators(.hidden)
    }

    /// 見出し行の左に指標名、右にその説明。下にピン留めした銘柄の棒グラフ。
    private func metricCard(metric: BenchmarkMetric, pinned: [BenchmarkCompany]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(metric.title)
                    .font(.title3.bold())
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(metric.caption)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.trailing)
            }
            if pinned.isEmpty {
                Text("左のランキングで銘柄をピン留めすると、ここに並べて表示します。")
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                let values = pinned.compactMap { $0.kpis[metric.key]?.value }
                let maxValue = max(values.map { abs($0) }.max() ?? 1, .ulpOfOne)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(pinned) { company in
                        if let value = company.kpis[metric.key]?.value {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    CompanyIconView(company.ref, size: 22)
                                    Text(Format.displayName(company.name, fallback: company.code))
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Theme.text)
                                }
                                HStack(spacing: 10) {
                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(metric.band.color(for: value))
                                            .frame(width: max(6, geo.size.width * min(abs(value) / maxValue, 1)))
                                    }
                                    .frame(height: 14)
                                    Text(metric.formatted(value))
                                        .font(.callout.weight(.bold).monospacedDigit())
                                        .foregroundStyle(Theme.text)
                                        .frame(minWidth: 84, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bltCardSurface()
    }

    private func trendCard(metric: BenchmarkMetric) -> some View {
        AnalysisCard(title: "過去の推移") {
            AnalysisNote(text: "この指標の過去 5 年の推移は準備中です。")
        }
    }

    /// 指標を行、ピン留めした銘柄を列に。各指標でいちばん良い値を緑にする。
    private func tableCard(group: BenchmarkGroup, pinned: [BenchmarkCompany]) -> some View {
        AnalysisCard(title: "指標の比較") {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    ForEach(pinned) { company in
                        VStack(alignment: .trailing, spacing: 4) {
                            CompanyIconView(company.ref, size: 26)
                            Text(Format.displayName(company.name, fallback: company.code))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(2)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                ForEach(group.metrics) { item in
                    Divider().overlay(Color.white.opacity(0.08))
                    GridRow {
                        Text(item.title)
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                            .gridColumnAlignment(.leading)
                        let values = pinned.map { $0.kpis[item.key]?.value }
                        let best: Double? = pinned.count < 2 ? nil : values.compactMap { $0 }.max { lhs, rhs in
                            item.higherIsBetter ? lhs < rhs : lhs > rhs
                        }
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, _ in
                            if let value = values[index] {
                                Text(item.formatted(value))
                                    .font(.footnote.monospacedDigit().weight(value == best ? .bold : .regular))
                                    .foregroundStyle(value == best ? Theme.positive : Theme.text)
                            } else {
                                Text("—").font(.footnote).foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 読み込み

    /// 静的 JSON（端末保存 → 条件付き GET）を先に使い、取れないときだけ REST に戻す。`BenchmarkRankingView` と同じ順。
    private func load() async {
        let id = model.compareGroup
        guard !id.isEmpty else { return }
        let store = BenchmarkStaticStore.shared
        if let cached = await store.cached(group: id) {
            phase = .loaded(cached.companies)
            guard await store.needsRevalidation(group: id) else { return }
            if let fresh = await store.revalidate(group: id) { phase = .loaded(fresh.companies) }
            return
        }
        phase = .loading
        if let fresh = await store.revalidate(group: id) {
            phase = .loaded(fresh.companies)
            return
        }
        if Task.isCancelled { return }
        do {
            phase = .loaded(try await APIClient.shared.benchmark(group: id).companies)
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
