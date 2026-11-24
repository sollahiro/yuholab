// geography 軸の欠測理由（国内売上 90% 超 / 海外売上なし / not_found）を文だけで分ける純関数のテスト。
// 文言は有報の関連情報「地域ごとの情報」の定型文。

import Foundation
import SwiftSoup
import Testing

@testable import BlueTickerCore

@Suite struct GeographyOmissionReasonTests {
    private func classify(_ sentences: [String]) -> String? {
        BreakdownExtractor.classifyGeographyOmission(sentences: sentences)
    }

    @Test func domesticNinetyPercentIsDomesticDominant() {
        #expect(classify(["本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        #expect(classify(["本邦の外部顧客への売上高が連結損益及び包括利益計算書の売上高の90%を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        // IFRS の言い回し
        #expect(classify(["日本の外部顧客からの売上収益が連結損益計算書の売上収益の90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
        // 売上と有形固定資産を1文で省略
        #expect(classify(["本邦の外部顧客への売上高及び本邦に所在している有形固定資産の金額がいずれも90％を超えるため、記載を省略しております。"])
            == breakdownNotApplicableDomesticDominant90pct)
    }

    /// 90% の数字を書かず「大部分を占める」と書く省略。
    /// source: code=2148 アイティメディア doc_id=S100YHX3 page=78 field=geography
    @Test func domesticMajorityWithoutNumberIsDomesticDominant() {
        #expect(classify([
            "（4）地域別に関する情報国内収益とされた外部顧客からの売上収益が連結損益計算書の売上収益の大部分を占めるため、地域別の売上収益の記載を省略しております。"
        ]) == breakdownNotApplicableDomesticDominant90pct)
        // 省略しない説明文、本邦以外の文は拾わない
        #expect(classify(["当社の売上収益は国内の顧客が大部分を占めております。"]) == nil)
        #expect(classify(["海外の外部顧客からの売上収益が大部分を占めるため、記載を省略しております。"]) == nil)
        // 有形固定資産だけの文
        #expect(classify(["本邦に所在している有形固定資産の金額が大部分を占めるため、記載を省略しております。"]) == nil)
    }

    @Test func noOverseasSalesWinsOverNinetyPercent() {
        #expect(classify(["本邦以外の外部顧客への売上高がないため、該当事項はありません。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify(["海外売上高がないため、記載を省略しております。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify(["外部顧客への売上高は、全て本邦の外部顧客への売上高であるため、記載を省略しております。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify([
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。",
            "本邦以外の外部顧客への売上高がないため、該当事項はありません。",
        ]) == breakdownNotApplicableNoOverseasSales)
    }

    /// のれん注記の「セグメント情報に同様」は地域ごとの情報ではない。本邦90%文だけを残す。
    /// source: code=6577 fy_end=2026-07-31 doc_id=S100Z940 page=77 field=geography
    @Test func goodwillSameAsSentenceIsNotGeographyDisclosure() {
        let ninety =
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"
        let goodwill =
            "（注）のれん償却額に関しては、セグメント情報に同様の情報を開示しているため、記載を省略しております。"
        #expect(!BreakdownExtractor.isGeographyDisclosureSentence(goodwill))
        #expect(BreakdownExtractor.isGeographyDisclosureSentence(ninety))
        #expect(
            BreakdownExtractor.geographyDisclosureSentences(from: [goodwill, ninety]) == [ninety])
        #expect(
            classify([goodwill, ninety]) == breakdownNotApplicableDomesticDominant90pct)
        #expect(
            BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableDomesticDominant90pct))
        #expect(
            BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableNoOverseasSales))
        #expect(
            !BreakdownExtractor.geographyOmissionTakesPriority(
                overSameAs: breakdownNotApplicableNotFound))
    }

    @Test func unrelatedNinetyPercentSentencesStayNil() {
        // 有形固定資産だけの 90% 文
        #expect(classify(["本邦に所在している有形固定資産の金額が連結貸借対照表の有形固定資産の金額の90％を超えるため、記載を省略しております。"]) == nil)
        // 製品 90% 文
        #expect(classify(["単一の製品・サービスの区分の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"]) == nil)
        // 本邦以外に拠点が無い（売上の文ではない）
        #expect(classify(["本邦以外の国又は地域に所在する連結子会社及び在外支店がないため、該当事項はありません。"]) == nil)
        // セグメントと同一の省略は same_as 側で扱う
        #expect(classify(["セグメント情報に同様の情報を開示しているため、記載を省略しています。"]) == nil)
        #expect(classify([]) == nil)
    }

    @Test func splitSentencesKeepsNonOmissionSentences() {
        let sentences = BreakdownExtractor.splitSentences("(1) 売上高\n本邦以外の外部顧客への売上高がないため、該当事項はありません。(2) 有形固定資産\n記載を省略しております。")
        #expect(sentences == [
            "(1) 売上高本邦以外の外部顧客への売上高がないため、該当事項はありません。",
            "(2) 有形固定資産記載を省略しております。",
        ])
    }

    @Test func newReasonsAreDeterministic() {
        #expect(isDeterministicBreakdownNotApplicableReason(breakdownNotApplicableDomesticDominant90pct))
        #expect(isDeterministicBreakdownNotApplicableReason(breakdownNotApplicableNoOverseasSales))
    }

    /// 省略文を 1 セルだけの表で包む有報（7963 興研）。表のセルでも地の文として拾う。
    @Test func omissionSentenceInsideSingleCellTableIsKept() {
        let html = """
            <p>(1）売上高</p><div><table><tbody><tr><td><p>本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。</p></td></tr></tbody></table></div>
            """
        let sentences = BreakdownExtractor.omissionSentenceSources(in: html)
            .flatMap(BreakdownExtractor.splitSentences)
        #expect(classify(sentences) == breakdownNotApplicableDomesticDominant90pct)
    }

    /// 空の余白セルがあっても、中身のあるセルが1つだけなら地の文（6549 の型）。
    @Test func omissionSentenceInTableWithEmptySpacerCellIsKept() {
        let html = """
            <table><tbody><tr><td/></tr><tr><td><p>本邦の外部顧客への売上高が損益計算書の売上高の90％を超えるため、記載を省略しております。</p></td></tr></tbody></table>
            """
        let sentences = BreakdownExtractor.omissionSentenceSources(in: html)
            .flatMap(BreakdownExtractor.splitSentences)
        #expect(classify(sentences) == breakdownNotApplicableDomesticDominant90pct)
    }

    /// 複数セルの表（数値の表）は地の文に混ぜない。
    @Test func multiCellTableIsNotMixedIntoProse() {
        let html = "<p>注記</p><table><tr><td>日本</td><td>本邦の売上高は90％を超える</td></tr></table>"
        let joined = BreakdownExtractor.omissionSentenceSources(in: html).joined()
        #expect(!joined.contains("90％"))
    }

    // MARK: 地域ごとの情報（売上）がセグメント情報への参照だけの書類 → same_as: segment

    private func sameAs(_ sentences: [String]) -> String? {
        BreakdownExtractor.geographySameAsSegmentStatement(in: sentences)
    }

    /// source: code=7928 旭化学工業 doc_id=S100ZJE8 page=58 field=geography
    @Test func sameAsSegmentStatementOmittedBySameInformation() {
        let sentence = "２．地域ごとの情報(１）売上高セグメント情報に同様の情報を開示しているため、記載を省略しております。"
        #expect(sameAs([sentence]) == sentence)
        // 積水化学 4204 S100YBAY の文言（「いる」止まり、空白あり）
        #expect(sameAs(["２．地域ごとの情報 (１）売上高 セグメント情報に同様の情報を開示しているため、記載を省略している。"]) != nil)
    }

    /// source: code=7637 白銅 doc_id=S100YI9D page=90 field=geography（報告セグメントが地域別）
    @Test func sameAsSegmentStatementWhenReportableSegmentsAreRegions() {
        let sentence =
            "２．地域ごとの情報（１）売上高当社グループは報告セグメントを地域別のセグメントとしていることから、地域ごとの売上高については、「セグメント情報　３．報告セグメントごとの売上高、利益又は損失、資産、負債その他の項目の金額に関する情報」をご参照下さい。"
        #expect(sameAs([sentence]) == sentence)
    }

    /// source: code=7972 イトーキ doc_id=S100XRIU page=97 field=geography（記載の通り）
    @Test func sameAsSegmentStatementWhenPointedToSegmentTable() {
        let sentence =
            "２．地域ごとの情報(1) 売上高「３．報告セグメントごとの売上高、利益又は損失、資産、負債その他の項目の金額に関する情報及び収益の分解情報」に記載の通りです。"
        #expect(sameAs([sentence]) != nil)
    }

    @Test func sameAsSegmentStatementIgnoresOtherSentences() {
        // 有形固定資産だけがセグメント情報と同様
        #expect(sameAs(["２．地域ごとの情報(１）売上高(２）有形固定資産セグメント情報に同様の情報を開示しているため、記載を省略している。"]) == nil)
        // 製品及びサービスごとの情報（地域の見出しが無い）
        #expect(sameAs(["１．製品及びサービスごとの情報セグメント情報に同様の情報を開示しているため、記載を省略している。"]) == nil)
        // のれん注記の同様文
        #expect(sameAs(["（注）のれん償却額に関しては、セグメント情報に同様の情報を開示しているため、記載を省略しております。"]) == nil)
        // 本邦90%超の省略文（same_as ではない）
        #expect(sameAs(["２．地域ごとの情報(１）売上高本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略しております。"]) == nil)
        #expect(sameAs([]) == nil)
    }

    // MARK: 前の表の脚注が、後続の売上表（当期）を資産表として落とさない

    /// source: code=6754 アンリツ doc_id=S100YH5E 地域別に関する情報（前期表・脚注・当期表の並び）
    @Test func footnoteBetweenTablesDoesNotMakeNextTableAnAssetTable() throws {
        let html = """
            <div>
            <p>(4) 地域別に関する情報</p>
            <p>売上収益及び非流動資産（金融商品、繰延税金資産及び退職給付に係る資産を除く）の地域別内訳は以下のとおりです。</p>
            <p>前連結会計年度（自　2024年４月１日　至　2025年３月31日）</p>
            <table><tr><td>日本</td><td>36,378</td></tr></table>
            <p>（注4）米国及び中国における非流動資産（金融商品、繰延税金資産及び退職給付に係る資産を除く）につきましては、重要性が乏しいため、記載を省略しております。</p>
            <p>当連結会計年度（自　2025年４月１日　至　2026年３月31日）</p>
            <table><tr><td>日本</td><td>39,885</td></tr></table>
            </div>
            """
        let doc = try SwiftSoup.parse(html)
        let tables = try doc.select("table").array()
        #expect(tables.count == 2)
        for table in tables {
            let caption = try #require(BreakdownExtractor.nearestGeographyMetricCaption(before: table))
            #expect(!BreakdownExtractor.isGeographyAssetMetricCaption(caption))
        }
    }

    @Test func numberedFootnoteLineDetection() {
        #expect(BreakdownExtractor.isNumberedFootnoteLine("（注4）米国及び中国における非流動資産"))
        #expect(BreakdownExtractor.isNumberedFootnoteLine("(注１)連結子会社"))
        #expect(BreakdownExtractor.isNumberedFootnoteLine("（注）１．調整額"))
        #expect(!BreakdownExtractor.isNumberedFootnoteLine("所在地別の非流動資産（注4）"))
        #expect(!BreakdownExtractor.isNumberedFootnoteLine("売上収益及び非流動資産の地域別内訳"))
    }
}
