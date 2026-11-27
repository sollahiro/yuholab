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

    /// same_as の取りこぼし(判定漏れ)の省略文。原文は実XBRLの「地域ごとの情報」節。
    /// source: code=2340 doc_id=S100LTT9 page=0 field=geography 報告セグメントは「日本」のみ
    @Test func staleSameAsOmissionWordings() {
        let noOverseas = [
            "当社グループの報告セグメントは「日本」のみであり、セグメント情報の開示の重要性が乏しいため、記載を省略しております。",
            "本邦以外の外部顧客への事業収益がないため、該当事項はありません。",
            "本邦以外の外部顧客への営業総収入がないため、該当事項はありません。",
            "連結損益計算書の営業収入の金額が、本邦における営業収入であるため、記載を省略しております。",
        ]
        for sentence in noOverseas {
            #expect(classify([sentence]) == breakdownNotApplicableNoOverseasSales, "\(sentence)")
        }
        let dominant = [
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90%を越えるため、記載を省略しております。",
            "当行グループは、本邦の外部顧客に対する経常収益に区分した金額が連結損益計算書の経常収益の90％を超えるため、記載を省略しています。",
            "本邦の外部顧客への売上高が損益計算書の売上高のほぼすべてを占めるため、記載を省略しております。",
            "本邦に所在している非流動資産および本邦の外部顧客売上高が大半を占めるため、記載を省略しております。",
            "本邦の外部顧客への営業収入が連結損益計算書の営業収入の90％を超えるため、記載を省略しております。",
        ]
        for sentence in dominant {
            #expect(classify([sentence]) == breakdownNotApplicableDomesticDominant90pct, "\(sentence)")
        }
        // 有形固定資産だけの文・売上の欄が「該当事項はありません」だけの文は拾わない
        #expect(classify(["本邦以外に所在している有形固定資産がないため、該当事項はありません。"]) == nil)
        #expect(classify(["本邦に所在している有形固定資産の金額が連結貸借対照表の有形固定資産の金額の90％を超えるため、記載を省略しております。"]) == nil)
        #expect(classify(["該当事項はありません。"]) == nil)
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
        // 本邦以外に拠点が無い文は、ユーザー判断で海外売上なし（売上の語は無いが、地域別を分ける対象が無い）
        #expect(classify(["本邦以外の国又は地域に所在する連結子会社及び在外支店がないため、該当事項はありません。"])
            == breakdownNotApplicableNoOverseasSales)
        #expect(classify(["本邦以外の国又は地域に所在する支店及び連結子会社がないため該当事項はありません。"])
            == breakdownNotApplicableNoOverseasSales)
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

    // MARK: 見出しごとの判定（製品及びサービスの省略文を地域と取り違えない）

    private func headedSameAs(_ sentences: [String]) -> String? {
        BreakdownExtractor.geographySameAsSegmentStatement(
            headed: BreakdownExtractor.headedSentences(from: sentences))
    }

    /// source: code=1959 クラフティア doc_id=S100YI0L 関連情報（製品の下の同様文、地域の下は本邦90%超）
    @Test func productHeadingSameAsSentenceIsNotGeography() {
        let sentences = [
            "１．製品及びサービスごとの情報",
            "セグメント情報に同様の情報を開示しているため、記載を省略している。",
            "２．地域ごとの情報",
            "(1)売上高",
            "本邦の外部顧客への売上高が連結損益計算書の売上高の90％を超えるため、記載を省略している。",
            "(2)有形固定資産",
            "本邦に所在している有形固定資産の金額が連結貸借対照表の有形固定資産の金額の90％を超えるため、記載を省略している。",
        ]
        #expect(headedSameAs(sentences) == nil)
        let headed = BreakdownExtractor.headedSentences(from: sentences)
        #expect(headed.map(\.heading) == [.product, .geographySales, .geographyAssets])
        #expect(
            BreakdownExtractor.sentencesOnlyUnderNonGeographyHeadings(headed)
                == ["セグメント情報に同様の情報を開示しているため、記載を省略している。"])
    }

    /// source: code=7928 旭化学 doc_id=S100ZJE8（見出しと本文が別の文）
    @Test func geographySameAsWhenHeadingAndBodyAreSeparateSentences() {
        let body = "セグメント情報に同様の情報を開示しているため、記載を省略しております。"
        #expect(headedSameAs(["１．製品及びサービスごとの情報", "セグメント情報に同様の情報を開示しているため、記載を省略しております。", "２．地域ごとの情報", body]) == body)
        #expect(headedSameAs(["２．地域ごとの情報", "(1)売上高", body]) == body)
    }

    /// source: code=7637 白銅 doc_id=S100YI9D（「地域ごとの売上高については…ご参照」）
    @Test func geographySameAsWhenSalesReferenceLacksInformationWord() {
        let body = "当社グループは報告セグメントを地域別のセグメントとしていることから、地域ごとの売上高については、「セグメント情報　３．報告セグメントごとの売上高、利益又は損失、資産、負債その他の項目の金額に関する情報」をご参照下さい。"
        #expect(headedSameAs(["２．地域ごとの情報", "(1)売上高", body]) == body)
    }

    @Test func geographyAssetsReferenceIsNotSameAs() {
        #expect(
            headedSameAs([
                "２．地域ごとの情報", "(1)売上高", "本邦以外の外部顧客への売上高がないため、該当事項はありません。",
                "(2)有形固定資産", "セグメント情報に同様の情報を開示しているため、記載を省略している。",
            ]) == nil)
    }

    @Test func selfContainedGeographySentenceStillWorksUnderProductHeading() {
        let sentence = "地域ごとの情報は、セグメント情報に同様の情報を開示しているため、記載を省略しております。"
        #expect(headedSameAs(["１．製品及びサービスごとの情報", sentence]) == sentence)
    }

    // MARK: 地域の表が前期のものだけのとき（ダイキン S100OG1V）

    @Test func priorPeriodOnlyGeographyTablesAreDetected() {
        let prior = BreakdownTable(heading: "地域ごとの情報", markdown: "| 日本 | 100 |", period: "前期")
        let current = BreakdownTable(heading: "地域ごとの情報", markdown: "| 日本 | 110 |", period: "当期")
        func extracted(_ tables: [BreakdownTable]) -> ExtractedBreakdown {
            ExtractedBreakdown(method: tables.isEmpty ? "not_found" : "html_table", tables: tables, facts: [])
        }
        #expect(BreakdownExtractor.geographyTablesAreAllPriorPeriod(extracted([prior])))
        #expect(!BreakdownExtractor.geographyTablesAreAllPriorPeriod(extracted([prior, current])))
        #expect(!BreakdownExtractor.geographyTablesAreAllPriorPeriod(extracted([current])))
        #expect(!BreakdownExtractor.geographyTablesAreAllPriorPeriod(extracted([])))
    }

    /// source: code=6367 ダイキン doc_id=S100W3XO（セグメント注記の表は売上の節の後に利益・資産・その他の項目が続く）
    @Test func segmentNoteTableIsTrimmedToSalesSection() {
        let markdown = """
            | | 空調・冷凍機事業 | 化学事業 | 計 | その他 | 合計 | 調整額 | 連結財務諸表計上額 |
            | --- | --- | --- | --- | --- | --- | --- | --- |
            | 売上高 | | | | | | | |
            | 日本 | 700,000 | 80,000 | 780,000 | 5,044 | 785,044 | | 785,044 |
            | 米国 | 1,600,000 | 30,000 | 1,630,000 | 6,043 | 1,636,043 | | 1,636,043 |
            | 外部顧客への売上高 | 4,600,000 | 140,000 | 4,740,000 | 12,335 | 4,752,335 | | 4,752,335 |
            | セグメント利益 | 500,000 | 20,000 | 520,000 | 1,000 | 521,000 | -1,000 | 520,000 |
            | その他の項目 | | | | | | | |
            | 減価償却費 | 190,000 | 7,000 | 197,000 | 431 | 197,431 | | 197,431 |
            """
        let trimmed = BreakdownExtractor.trimToSegmentSalesSection(markdown)
        #expect(trimmed.contains("日本"))
        #expect(trimmed.contains("外部顧客への売上高"))
        #expect(!trimmed.contains("セグメント利益"))
        #expect(!trimmed.contains("減価償却費"))
        // 区切りの行が無い表はそのまま。
        let plain = "| | 売上高 |\n| --- | --- |\n| 日本 | 100 |\n| 米国 | 200 |"
        #expect(BreakdownExtractor.trimToSegmentSalesSection(plain) == plain)
    }

    @Test func consolidatedColumnIsKeptWhenPresent() {
        let markdown = """
            | | 空調・冷凍機事業 | 化学事業 | 計 | その他 | 合計 | 調整額 | 連結財務諸表計上額 |
            | --- | --- | --- | --- | --- | --- | --- | --- |
            | 日本 | 700,000 | 80,000 | 780,000 | 5,044 | 785,044 | | 785,044 |
            | 米国 | 1,600,000 | 30,000 | 1,630,000 | 6,043 | 1,636,043 | | 1,636,043 |
            """
        let narrowed = BreakdownExtractor.keepingConsolidatedColumn(markdown)
        #expect(narrowed.contains("連結財務諸表計上額"))
        #expect(narrowed.contains("785,044"))
        #expect(!narrowed.contains("780,000"))
        #expect(!narrowed.contains("空調・冷凍機事業"))
        // 該当列が無い表はそのまま。
        let plain = "| | 売上高 |\n| --- | --- |\n| 日本 | 100 |\n| 米国 | 200 |"
        #expect(BreakdownExtractor.keepingConsolidatedColumn(plain) == plain)
    }

    /// source: code=4204 積水化学 doc_id=S100YBAY（「計」が報告セグメント小計と総合計の2列）
    @Test func rightmostTotalColumnIsKeptWhenNoConsolidatedColumn() {
        let markdown = """
            | | 住宅 | 環境 | 計 | その他 | 調整額 | 計 |
            | --- | --- | --- | --- | --- | --- | --- |
            | 日本 | 500,000 | 300,000 | 800,000 | 88,981 | 2,476 | 891,457 |
            | 北米 | 100,000 | 40,000 | 140,000 | 3,000 | 737 | 143,737 |
            """
        let narrowed = BreakdownExtractor.keepingConsolidatedColumn(markdown)
        #expect(narrowed.contains("891,457"))
        #expect(narrowed.contains("143,737"))
        #expect(!narrowed.contains("800,000"))
        #expect(!narrowed.contains("住宅"))
    }

    /// source: code=7972 イトーキ doc_id=S100XRIU（表の直前の「４．…増加額には、…」は脚注）
    @Test func numberedProseFootnoteIsNotAnAssetCaption() {
        #expect(BreakdownExtractor.isNumberedFootnoteLine(
            "４．減価償却費、有形固定資産及び無形固定資産の増加額には、長期前払費用とその償却額が含まれております。"))
        #expect(!BreakdownExtractor.isNumberedFootnoteLine("２．有形固定資産"))
        #expect(!BreakdownExtractor.isNumberedFootnoteLine("２．地域ごとの情報"))
    }

    /// source: code=7508 S100YI5T（句点が無いまま段落が2つに分かれた「90％超」の省略文）
    @Test func domesticDominantSentenceSplitAcrossParagraphs() {
        let sentences = [
            "本邦の売上高及び資産の金額は、全セグメントの売上高の合計及び資産の金額の合計に占める割合",
            "　がいずれも 90％超であるため、地域ごとの情報の記載を省略しております。",
        ]
        #expect(BreakdownExtractor.classifyGeographyOmission(sentences: sentences)
            == breakdownNotApplicableDomesticDominant90pct)
        // 句点で終わる文はつなげない。
        #expect(BreakdownExtractor.classifyGeographyOmission(sentences: [
            "本邦の売上高及び資産の金額は、全セグメントの売上高の合計に占める割合。",
            "がいずれも 90％超であるため、記載を省略しております。",
        ]) == nil)
    }

    @Test func regionRelatedInformationHeadingIsGeographyKeyword() {
        #expect(Xbrl.geographyHeadingKeywords.contains("地域に関する情報"))
        #expect(Xbrl.geographyRevenueDecompositionTextBlockTags.contains(
            "NotesRevenue2ConsolidatedFinancialStatementsIFRSTextBlock"))
        #expect(Xbrl.geographyRevenueDecompositionTextBlockTags.contains(
            "NotesRevenueConsolidatedFinancialStatementsIFRSTextBlock"))
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

    /// source: code=4324 doc_id=S100QHOJ fy_end=2022-12-31（収益の注記。「主要なサービス」の節の後に「地域市場別内訳」の節、列は事業・小計・内部取引調整・合計）
    @Test func regionMarketSectionIsNarrowedToSubtotalColumn() {
        let markdown = """
            | 当連結会計年度 | 当連結会計年度 | 当連結会計年度 | 当連結会計年度 | （単位：百万円） | （単位：百万円） |
            | --- | --- | --- | --- | --- | --- |
            | | セグメント | セグメント | セグメント | 内部取引調整 | 合計 |
            | | 国内事業 | 海外事業 | 小計 | 内部取引調整 | 合計 |
            | 主要なサービス | | | | | |
            | 広告業 | 421,126 | 714,948 | 1,136,075 | － | － |
            | 合計 | 530,133 | 714,948 | 1,245,082 | △1,198 | 1,243,883 |
            | 地域市場別内訳 | | | | | |
            | 日本 | 530,133 | － | 530,133 | － | － |
            | EMEA（欧州・中東・アフリカ） | － | 275,411 | 275,411 | － | － |
            | Americas（米州） | － | 324,013 | 324,013 | － | － |
            | APAC（アジア太平洋） | － | 115,523 | 115,523 | － | － |
            | 合計 | 530,133 | 714,948 | 1,245,082 | △1,198 | 1,243,883 |
            """
        let narrowed = BreakdownExtractor.narrowingToRegionMarketSection(markdown)
        #expect(narrowed.contains("日本"))
        #expect(narrowed.contains("275,411"))
        #expect(narrowed.contains("1,245,082"))
        #expect(!narrowed.contains("海外事業"))
        #expect(!narrowed.contains("広告業"))
        #expect(!narrowed.contains("1,243,883"))
        // 地域の節が無い表はそのまま。
        let plain = "| | 小計 |\n| --- | --- |\n| 日本 | 100 |\n| 合計 | 100 |"
        #expect(BreakdownExtractor.narrowingToRegionMarketSection(plain) == plain)
    }
}
