import Foundation

actor APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let cache: ResponseCache
    private let hapis: HAPISConsumerClient
    private let originGate: HAPISOriginGate
    private var inFlightGets: [String: InFlightGet] = [:]
    /// 404 の本文に `reason` があったときの理由（URL ごとの最新）。内訳の「該当なし」の見分けに使う。
    private var notFoundReasons: [String: String] = [:]

    private struct InFlightGet {
        let id: UUID
        let task: Task<Data, Error>
        var waiterCount: Int
    }

    init(
        session: URLSession? = nil,
        cache: ResponseCache = .shared,
        hapis: HAPISConsumerClient? = nil,
        originGate: HAPISOriginGate = HAPISOriginGate()
    ) {
        self.cache = cache
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config)
        }
        decoder = JSONDecoder()
        self.originGate = originGate
        self.hapis = hapis ?? HAPISConsumerClient(
            issuerURL: { APIConfiguration.hapisIssuerURL },
            session: URLSession(configuration: .ephemeral),
            store: Self.makeTokenStore(),
            attestation: HAPISAttestClientMode.make(
                mode: APIConfiguration.hapisAttestClientMode
            )
        )
    }

    func clearHAPISConsumerToken() async {
        await hapis.invalidate()
    }

    private static func makeTokenStore() -> any HAPISTokenStoring {
        #if canImport(Security)
            return KeychainHAPISTokenStore()
        #else
            return InMemoryHAPISTokenStore()
        #endif
    }

    func searchCompanies(query: String) async throws -> [CompanyHit] {
        var components = URLComponents(url: path("v1/companies"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw APIClientError.badURL }
        return try await get(url)
    }

    func cachedFinancials(code: String) async -> FinancialsResponse? {
        await peek(path("v1/companies/\(code)/financials"))
    }

    func cachedWaterfall(code: String) async -> FinancialsResponse? {
        await peek(path("v1/companies/\(code)/waterfall"))
    }

    func cachedOverview(code: String) async -> CompanyOverviewResponse? {
        await peek(path("v1/companies/\(code)/overview"))
    }

    func financials(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/financials"), cacheTTL: ttl(for: code))
    }

    func waterfall(code: String) async throws -> FinancialsResponse {
        try await get(path("v1/companies/\(code)/waterfall"), cacheTTL: ttl(for: code))
    }

    func overview(code: String) async throws -> CompanyOverviewResponse {
        try await get(path("v1/companies/\(code)/overview"), cacheTTL: ttl(for: code))
    }

    /// 報告セグメントの外部売上の年次推移（新しい年が先頭）。単一セグメントや未算出は 404。
    func segmentWaterfall(code: String, years: Int = APIClient.breakdownYears) async throws -> SegmentWaterfallResponse {
        try await get(try segmentWaterfallURL(code: code, years: years), cacheTTL: ttl(for: code))
    }

    /// 内訳カード（セグメント・地域）の年数。先読みとカードの取得で URL（＝キャッシュのキー）をそろえる。
    static let breakdownYears = 5

    private func segmentWaterfallURL(code: String, years: Int) throws -> URL {
        try queryURL(
            "v1/companies/\(code)/waterfall/segment",
            [("metric", "external_sales"), ("years", String(years))])
    }

    private func geographyWaterfallURL(code: String, years: Int) throws -> URL {
        try queryURL("v1/companies/\(code)/waterfall/geography", [("years", String(years))])
    }

    /// 地域別売上の年次推移（新しい年が先頭）。地域名は正規化され、比べられる年の塊に分かれる。未算出は 404。
    func geographyWaterfall(code: String, years: Int = APIClient.breakdownYears) async throws -> GeographyWaterfallResponse {
        try await get(try geographyWaterfallURL(code: code, years: years), cacheTTL: ttl(for: code))
    }

    /// 地域別の年次推移と、直近の有報の地域別が省略・未取得かの理由を 1 本の取得で返す。
    /// サーバーは応答の `latest_status`（200）または 404 の `reason` で伝える。どちらも無い古いサーバーは、
    /// 従来どおり `breakdown?axis=geography` を別に取って判定する。
    /// `missingReason` は `geographyMissingReason` と同じ意味（実データありは nil。省略は
    /// `domestic_dominant_90pct` / `no_overseas_sales` / `same_as_segment`、それ以外の 404 は `unavailable`、通信エラーなどは nil）。
    func geographyWaterfallResult(
        code: String, years: Int = APIClient.breakdownYears
    ) async -> (response: GeographyWaterfallResponse?, missingReason: String?) {
        guard let url = try? geographyWaterfallURL(code: code, years: years)
        else { return (nil, nil) }
        do {
            let response: GeographyWaterfallResponse = try await get(url, cacheTTL: ttl(for: code))
            guard let status = response.latestStatus else {
                return (response, await geographyMissingReason(code: code))
            }
            return (response, Self.geographyMissingReason(forStatus: status))
        } catch APIClientError.http(let status, _) where status == 404 {
            if let reason = notFoundReasons[url.absoluteString] {
                return (nil, Self.geographyMissingReason(forStatus: reason))
            }
            return (nil, await geographyMissingReason(code: code))
        } catch {
            return (nil, nil)
        }
    }

    private static func geographyMissingReason(forStatus status: String) -> String? {
        switch status {
        case "ok": return nil
        case "domestic_dominant_90pct", "no_overseas_sales", "same_as_segment": return status
        default: return "unavailable"
        }
    }

    /// 直近の `breakdown?axis=segment` が 404 だったときの理由。`single_segment_disclosed` なら単一セグメント。
    func segmentNotFoundReason(code: String) -> String? {
        guard let url = try? queryURL("v1/companies/\(code)/breakdown", [("axis", "segment")]) else { return nil }
        return notFoundReasons[url.absoluteString]
    }

    /// 最新の地域別内訳が 404 のときの理由。省略は `domestic_dominant_90pct` / `no_overseas_sales`、
    /// それ以外の 404（未算出・不明）は `unavailable`。取得失敗（通信エラーなど）は nil。
    func geographyMissingReason(code: String) async -> String? {
        do {
            _ = try await breakdown(code: code, axis: "geography")
            return nil
        } catch APIClientError.http(let status, _) where status == 404 {
            guard let url = try? queryURL("v1/companies/\(code)/breakdown", [("axis", "geography")]),
                let reason = notFoundReasons[url.absoluteString],
                reason == "domestic_dominant_90pct" || reason == "no_overseas_sales"
            else { return "unavailable" }
            return reason
        } catch {
            return nil
        }
    }

    /// 内訳（`axis` は `segment` / `geography`）。`docId` を省くと最新の有報。
    func breakdown(code: String, axis: String, docId: String? = nil) async throws -> BreakdownResponse {
        var items = [("axis", axis)]
        if let docId { items.append(("doc_id", docId)) }
        let url = try queryURL("v1/companies/\(code)/breakdown", items)
        return try await get(url, cacheTTL: ttl(for: code))
    }

    /// 関係（`type` は `supplier` / `investee` / `subsidiary` / `major_shareholder`）。公開できる行が無いと 404。
    func relations(code: String, type: String, limit: Int) async throws -> CompanyRelationsResponse {
        let url = try queryURL(
            "v1/companies/\(code)/relations", [("type", type), ("limit", String(limit))])
        return try await get(url, cacheTTL: ttl(for: code))
    }

    private func queryURL(_ suffix: String, _ items: [(String, String)]) throws -> URL {
        var components = URLComponents(url: path(suffix), resolvingAgainstBaseURL: false)
        components?.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw APIClientError.badURL }
        return url
    }

    func prefetchAnalysis(codes: [String]) async {
        for code in codes {
            guard !Task.isCancelled else { return }
            if await originGate.isCoolingDown() { return }
            if await prefetchFailedRateLimit({
                let _: FinancialsResponse = try await get(
                    path("v1/companies/\(code)/financials"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: FinancialsResponse = try await get(
                    path("v1/companies/\(code)/waterfall"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: CompanyOverviewResponse = try await get(
                    path("v1/companies/\(code)/overview"),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            // 内訳カード（セグメント・地域）。開いたときに取得待ちで遅れて出ないよう、ここで温めておく。
            // 404（単一セグメント・省略など）は取り直しを避けるためキャッシュされないが、先読みは続ける。
            if await prefetchFailedRateLimit({
                let _: SegmentWaterfallResponse = try await get(
                    try segmentWaterfallURL(code: code, years: Self.breakdownYears),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: GeographyWaterfallResponse = try await get(
                    try geographyWaterfallURL(code: code, years: Self.breakdownYears),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
            if await prefetchFailedRateLimit({
                let _: BreakdownResponse = try await get(
                    try queryURL("v1/companies/\(code)/breakdown", [("axis", "segment")]),
                    cacheTTL: ttl(for: code),
                    hapisClass: .prefetch)
            }) { return }
        }
    }

    private func prefetchFailedRateLimit(_ run: () async throws -> Void) async -> Bool {
        do {
            try await run()
            return false
        } catch is CancellationError {
            return true
        } catch APIClientError.http(let status, _) where status == 429 {
            return true
        } catch {
            return false
        }
    }

    private func ttl(for code: String) -> TimeInterval {
        ResponseCache.analysisTTL
    }

    private func path(_ suffix: String) -> URL {
        APIConfiguration.baseURL.appending(path: suffix)
    }

    private func peek<T: Decodable>(_ url: URL) async -> T? {
        let key = ResponseCache.key(for: url)
        guard let data = await cache.load(key: key, maxAge: nil) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    private func get<T: Decodable>(
        _ url: URL,
        cacheTTL: TimeInterval? = nil,
        hapisClass: HAPISOriginGate.RequestClass = .interactive
    ) async throws -> T {
        let key = ResponseCache.key(for: url)
        if let cacheTTL, let data = await cache.load(key: key, maxAge: cacheTTL),
            let decoded = try? decoder.decode(T.self, from: data)
        {
            return decoded
        }
        do {
            let data = try await fetchCoalesced(url, hapisClass: hapisClass)
            do {
                let decoded = try decoder.decode(T.self, from: data)
                if cacheTTL != nil {
                    await cache.store(key: key, data: data)
                }
                return decoded
            } catch {
                throw APIClientError.decoding(error)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let clientError = error as? APIClientError, case .http(let status, _) = clientError {
                if status == 404 {
                    if cacheTTL != nil {
                        await cache.remove(key: key)
                    }
                    throw clientError
                }
                // 429 を stale cache で握りつぶすと先読みが止まらない。
                if status == 429 {
                    throw clientError
                }
            }
            // 取り直しに失敗したときだけ古い応答を返す。上限は 7 日（それより古ければエラーにする）。
            if cacheTTL != nil,
                let data = await cache.load(key: key, maxAge: ResponseCache.staleFallbackLimit),
                let decoded = try? decoder.decode(T.self, from: data)
            {
                return decoded
            }
            throw error
        }
    }

    /// 同一 GET は 1 本にまとめる。待ちが残っている間は生かし、最後の待ちが消えたら中身をキャンセルする。
    /// map から外すのはその Task が完了したときだけ（新しい in-flight を消さない）。
    private func fetchCoalesced(
        _ url: URL,
        hapisClass: HAPISOriginGate.RequestClass
    ) async throws -> Data {
        try Task.checkCancellation()
        let key = "\(ResponseCache.key(for: url))|\(hapisClass)"
        let flight: InFlightGet
        if let existing = inFlightGets[key], existing.waiterCount > 0, !existing.task.isCancelled {
            var joined = existing
            joined.waiterCount += 1
            inFlightGets[key] = joined
            flight = joined
        } else {
            let id = UUID()
            let task = Task {
                try await self.fetchWithGate(url, hapisClass: hapisClass)
            }
            flight = InFlightGet(id: id, task: task, waiterCount: 1)
            inFlightGets[key] = flight
        }
        do {
            let data = try await withTaskCancellationHandler {
                try await flight.task.value
            } onCancel: {
                Task { await self.abandonWaiter(key: key, id: flight.id) }
            }
            finishInFlight(key: key, id: flight.id)
            return data
        } catch {
            finishInFlight(key: key, id: flight.id)
            throw error
        }
    }

    private func abandonWaiter(key: String, id: UUID) {
        guard var entry = inFlightGets[key], entry.id == id else { return }
        entry.waiterCount -= 1
        if entry.waiterCount <= 0 {
            entry.task.cancel()
        }
        inFlightGets[key] = entry
    }

    private func finishInFlight(key: String, id: UUID) {
        guard let entry = inFlightGets[key], entry.id == id else { return }
        inFlightGets[key] = nil
    }

    /// HAPIS は少数並列（`HAPISOriginGate`）。interactive の 429 はクールダウンのあと 1 回だけやり直す。
    /// mint / refresh はスロットを取る前に済ませ、スロット中は Keychain 読みだけにする。
    private func fetchWithGate(
        _ url: URL,
        hapisClass: HAPISOriginGate.RequestClass
    ) async throws -> Data {
        try await fetchWithGate(url, hapisClass: hapisClass, headers: [:]).data
    }

    private func fetchWithGate(
        _ url: URL,
        hapisClass: HAPISOriginGate.RequestClass,
        headers: [String: String]
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        guard APIConfiguration.usesHAPISConsumer(url) else {
            return try await fetchResponse(url, headers: headers, hapisClass: hapisClass)
        }
        try Task.checkCancellation()
        do {
            _ = try await hapis.validToken()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIClientError.hapisUnavailable
        }
        do {
            return try await originGate.withTurn(hapisClass) {
                try await self.fetchResponse(url, headers: headers, hapisClass: hapisClass)
            }
        } catch APIClientError.http(let status, _) where status == 429 && hapisClass == .interactive {
            try await originGate.waitTurn(.interactive)
            return try await originGate.withTurn(hapisClass) {
                try await self.fetchResponse(url, headers: headers, hapisClass: hapisClass)
            }
        }
    }

    /// `headers` は条件付き GET の検証子など。304 は成功として本文（空）と応答を返す。
    private func fetchResponse(
        _ url: URL,
        headers: [String: String] = [:],
        hapisRemintAttempted: Bool = false,
        hapisClass: HAPISOriginGate.RequestClass = .interactive
    ) async throws -> (data: Data, response: HTTPURLResponse?) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // HAPIS ゲートウェイだけ、制御面で mint した consumer JWT を Bearer に付ける。
        // Release と Debug の HAPIS 本番は App Attest。loopback / LAN `http` は付けない。
        if APIConfiguration.usesHAPISConsumer(url) {
            try Task.checkCancellation()
            do {
                request = try await hapis.authorize(request)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw APIClientError.hapisUnavailable
            }
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw APIClientError.transport(error)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401, APIConfiguration.usesHAPISConsumer(url), !hapisRemintAttempted {
            if GatewayErrorBody.parse(data)?.isTokenExpired == true {
                do {
                    _ = try await hapis.forceRemint()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw APIClientError.hapisUnavailable
                }
                return try await fetchResponse(
                    url, headers: headers, hapisRemintAttempted: true, hapisClass: hapisClass)
            }
        }
        if status == 429 {
            if APIConfiguration.usesHAPISConsumer(url) {
                await originGate.noteRateLimited(
                    retryAfterSeconds: HAPISRetryAfter.seconds(
                        from: http?.value(forHTTPHeaderField: "Retry-After"))
                )
            }
            let message = httpErrorMessage(data, fallback: "HTTP 429")
            throw APIClientError.http(status: 429, message: message)
        }
        if status == 404 {
            if let reason = (try? decoder.decode(APIErrorBody.self, from: data))?.reason {
                notFoundReasons[url.absoluteString] = reason
            } else {
                notFoundReasons[url.absoluteString] = nil
            }
            let message = httpErrorMessage(data, fallback: "見つかりません")
            throw APIClientError.http(status: 404, message: message)
        }
        if status == 503 {
            let message = httpErrorMessage(data, fallback: "サービスを利用できません")
            throw APIClientError.http(status: 503, message: message)
        }
        guard (200..<300).contains(status) || status == 304 else {
            let message = httpErrorMessage(data, fallback: "HTTP \(status)")
            throw APIClientError.http(status: status, message: message)
        }
        return (data, http)
    }

    private func httpErrorMessage(_ data: Data, fallback: String) -> String {
        if let body = GatewayErrorBody.parse(data), let message = body.message, !message.isEmpty {
            return message
        }
        return (try? decoder.decode(APIErrorBody.self, from: data))?.error ?? fallback
    }
}

extension APIClient {
    /// 業種ベンチマーク（業種グループの全社の KPI）。公開していない業種は 404。
    func benchmark(group: String) async throws -> BenchmarkResponse {
        try await get(
            APIConfiguration.baseURL.appending(path: "v1/benchmark/\(group)"),
            cacheTTL: ResponseCache.analysisTTL)
    }
}
