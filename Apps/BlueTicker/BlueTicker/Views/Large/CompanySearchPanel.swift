import SwiftUI

/// 大画面の検索。常設の検索バーと、未入力なら履歴・入力中なら候補。行は `onSelect` で返す（画面遷移はしない）。
struct CompanySearchPanel: View {
    @Binding var query: String
    var selectedCode: String?
    var onSelect: (CompanyRef) -> Void

    @State private var history: [CompanyRef] = []
    @State private var results: [CompanyHit] = []
    @State private var errorMessage: String?
    @State private var isSearching = false
    @State private var task: Task<Void, Never>?
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if trimmed.isEmpty {
                        sectionTitle("最近あなたが調べた企業")
                        if history.isEmpty {
                            Text("調べた企業がここに並びます")
                                .font(.footnote)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Theme.cardContentInset)
                        }
                        ForEach(history) { row($0) }
                    } else {
                        sectionTitle("検索候補")
                        if isSearching && results.isEmpty && errorMessage == nil {
                            ProgressView().padding(16)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Theme.textMuted)
                                .padding(.horizontal, Theme.cardContentInset)
                        }
                        ForEach(results) { row(CompanyRef($0)) }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .onAppear { history = CompanyHistory.load() }
        .onChange(of: query) { _, value in schedule(value, debounce: .milliseconds(280)) }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textMuted)
                .accessibilityHidden(true)
            TextField("会社名・銘柄コード", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .foregroundStyle(Theme.text)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("クリア")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.control, in: Capsule())
        .padding(.horizontal, Theme.cardContentInset)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textMuted)
            .padding(.horizontal, Theme.cardContentInset)
            .padding(.vertical, 6)
    }

    private func row(_ company: CompanyRef) -> some View {
        Button {
            onSelect(company)
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
    }

    private func schedule(_ raw: String, debounce: Duration) {
        task?.cancel()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let current = generation
        if text.isEmpty {
            results = []
            errorMessage = nil
            isSearching = false
            task = nil
            return
        }
        task = Task {
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await run(text, generation: current)
        }
    }

    private func run(_ text: String, generation current: Int) async {
        guard current == generation else { return }
        isSearching = true
        defer { if current == generation { isSearching = false } }
        do {
            let hits = try await APIClient.shared.searchCompanies(query: text)
            guard current == generation, !Task.isCancelled else { return }
            results = hits
            errorMessage = hits.isEmpty ? "該当する会社はありません" : nil
        } catch is CancellationError {
            return
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
        }
    }
}

/// 更新フィード（最近有報が更新された企業）を縦に並べる。右ペインの既定。
struct FeedListPane: View {
    @Bindable var feed: FeedSession
    var onSelect: (CompanyRef) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近有報が更新された企業")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                    Spacer(minLength: 8)
                    if feed.isFirstLoading {
                        ProgressView().controlSize(.small).tint(Theme.textMuted)
                    }
                }
                .padding(.horizontal, 4)
                if feed.items.isEmpty {
                    if !feed.isFirstLoading {
                        Text("まだ表示できる有報がありません")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                            .padding(.horizontal, 4)
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(feed.items.enumerated()), id: \.element.id) { offset, item in
                            if offset > 0 { Divider().overlay(Theme.elevated) }
                            row(item)
                        }
                    }
                    .padding(.horizontal, Theme.cardContentInset)
                    .padding(.vertical, 6)
                    .bltCardSurface()
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ item: FeedRSS.Item) -> some View {
        let company = CompanyRef(item)
        return Button {
            onSelect(company)
        } label: {
            HStack(spacing: 12) {
                CompanyIconView(company, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Format.displayName(company.name, fallback: company.code))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text(company.code)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 8)
                if !item.submittedAt.isEmpty {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("提出日").font(.caption2).foregroundStyle(Theme.textMuted)
                        Text(Format.submittedDate(item.submittedAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.text)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityHidden(true)
            }
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
