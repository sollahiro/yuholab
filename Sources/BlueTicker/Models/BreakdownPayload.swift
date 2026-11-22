// 内訳抽出結果の公開 Codable 型。BltServerFacade の breakdown 取り込みが使う。
// （旧 FilingSectionsContract.swift から、filing-sections 廃止後も使われるこの3型だけを残した）

import Foundation

/// ExtractedBreakdown（内部型）の公開 Codable 写経。toDictionary() は ExtractedBreakdown と同一キー構造。
public struct ExtractedBreakdownPayload: Codable, Sendable, Equatable {
    public var method: String
    public var tables: [BreakdownTablePayload]
    public var facts: [BreakdownFactPayload]

    public init(method: String, tables: [BreakdownTablePayload], facts: [BreakdownFactPayload]) {
        self.method = method
        self.tables = tables
        self.facts = facts
    }

    /// ExtractedBreakdown.toDictionary() と同じ形。
    public func toDictionary() -> [String: Any] {
        let tablesArr: [[String: Any]] = tables.map { t in
            var d: [String: Any] = ["heading": t.heading, "markdown": t.markdown]
            if let p = t.period { d["period"] = p }
            return d
        }
        let factsArr: [[String: Any]] = facts.map { f in
            var d: [String: Any] = [
                "tag": f.tag, "contextRef": f.contextRef,
                "dimensions": f.dimensions, "value": f.value,
            ]
            if let l = f.label { d["label"] = l }
            if let u = f.unitRef { d["unitRef"] = u }
            if let dec = f.decimals { d["decimals"] = dec }
            return d
        }
        return ["method": method, "tables": tablesArr, "facts": factsArr]
    }
}

public struct BreakdownTablePayload: Codable, Sendable, Equatable {
    public var heading: String
    public var markdown: String
    public var period: String?

    public init(heading: String, markdown: String, period: String?) {
        self.heading = heading
        self.markdown = markdown
        self.period = period
    }
}

public struct BreakdownFactPayload: Codable, Sendable, Equatable {
    public var tag: String
    public var contextRef: String
    public var dimensions: [String: String]
    public var value: Double
    public var label: String?
    public var unitRef: String?
    public var decimals: String?

    public init(
        tag: String, contextRef: String, dimensions: [String: String], value: Double,
        label: String?, unitRef: String?, decimals: String?
    ) {
        self.tag = tag
        self.contextRef = contextRef
        self.dimensions = dimensions
        self.value = value
        self.label = label
        self.unitRef = unitRef
        self.decimals = decimals
    }
}
