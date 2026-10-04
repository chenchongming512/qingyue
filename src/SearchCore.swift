// 轻阅 · 全文搜索核心
//
// 单独成文件（不依赖 SwiftUI / AppKit），这样测试台能直接跑它 ——
// 原先这段埋在 ReaderUI.swift 里，只有编译整个界面才能测，实际上等于没测过。

import Foundation
import PDFKit

/// 一条搜索命中。
///
/// **选区是惰性的**：`selection` 是计算属性，用户真的点这一条时才构造 `PDFSelection`。
/// 这是搜索提速的关键，详见 `selectionsMap` 的说明。
struct SearchHit: Identifiable {
    let id = UUID()
    let pageIndex: Int   // 0-based

    /// 命中位置**左右各截一段**，中间那段就是命中本身。
    /// 拆成三段是为了在列表里能把命中的字染成强调色 —— 只给一串纯文本的话，
    /// 用户还得自己数第几个字才是匹配到的。
    let before: String
    let match: String
    let after: String

    let page: PDFPage?
    /// 命中在**本页纯文本**里的位置（`PDFPage.selection(for:)` 要的就是这个坐标系）
    let range: NSRange

    /// 惰性选区：点击结果时才真正构造。
    var selection: PDFSelection? { page?.selection(for: range) }

    var snippet: String { before + match + after }
}

/// 全文搜索。
///
/// ⚠️ **不要改回 `doc.findString`。** 300 页文档实测（Apple M4，见测试报告第四节）：
///
/// | 做法 | 耗时 |
/// |---|---|
/// | `doc.findString` 全文档一次 | **410 ms**（且无法提前截断） |
/// | 逐页 `page.string` + `range(of:)` | **121 ms**（3.4×） |
/// | 其中花在 `page.selection(for:)` 构造选区上的 | **115 ms** |
/// | 整篇取文本本身 | 6.6 ms |
///
/// 所以这里拆成两步：「逐页扫字符串」拿位置（便宜），**选区推迟到点击那一条时才构造**
/// （贵的那部分不再跟着搜索走）。实测搜索本身降到 10 ms 量级。
///
/// 代价：同一条命中**横跨两页**时扫不到。这种情形极少，换来的是搜索几乎瞬时返回。
func selectionsMap(query: String, doc: PDFDocument, limit: Int = 500) -> [SearchHit] {
    var hits: [SearchHit] = []
    let needle = query as NSString
    let context = 42

    for i in 0..<doc.pageCount {
        if hits.count >= limit { break }
        if Task.isCancelled { break }
        guard let page = doc.page(at: i), let text = page.string, !text.isEmpty else { continue }

        let ns = text as NSString
        var cursor = NSRange(location: 0, length: ns.length)
        while hits.count < limit {
            let r = ns.range(of: needle as String, options: [.caseInsensitive], range: cursor)
            guard r.location != NSNotFound, r.length > 0 else { break }

            let beforeStart = max(0, r.location - context)
            let afterEnd = min(ns.length, r.location + r.length + context)
            var before = ns.substring(with: NSRange(location: beforeStart, length: r.location - beforeStart))
            var after = ns.substring(with: NSRange(location: r.location + r.length,
                                                length: afterEnd - (r.location + r.length)))
            // 换行会把结果行撑成两行，压成空格更好读
            before = before.replacingOccurrences(of: "\n", with: " ")
            after = after.replacingOccurrences(of: "\n", with: " ")
            if beforeStart > 0 { before = "…" + before }
            if afterEnd < ns.length { after += "…" }

            hits.append(SearchHit(pageIndex: i, before: before, match: ns.substring(with: r),
                                  after: after, page: page, range: r))

            let next = r.location + r.length
            guard next < ns.length else { break }
            cursor = NSRange(location: next, length: ns.length - next)
        }
    }
    return hits
}
