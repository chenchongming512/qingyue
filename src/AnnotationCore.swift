import SwiftUI
import PDFKit
import AppKit

// MARK: - 批注扫描（纯逻辑，可进测试台）
//
// 之前批注只能在页面里翻找 —— 加了高亮之后想回头看看"我标了哪些地方"是没有入口的。
// 这里把全文档的批注扫成一张表：类型、颜色、标的那段文字、所在页，点一下跳过去。
//
// ⚠️ 这里所有类型标识的比较都必须过 `AnnotationScan.norm`：
// `PDFAnnotation.type` 是 "Highlight"，而 `PDFAnnotationSubtype.highlight.rawValue`
// 是 "/Highlight"（PDF 名字对象格式，带斜杠）。**两者永不相等，且不报错**，
// 后果是所有批注静默退化成「批注 /（无文字内容）」。

// MARK: - 模型

struct AnnotationEntry: Identifiable {
    let id: String          // "\(pageIndex)|\(序号)"
    let pageIndex: Int
    let annotation: PDFAnnotation
    let label: String       // 高亮 / 下划线 / 便签 …
    let icon: String
    let color: Color
    /// 标住的文字（高亮类取被覆盖的正文，便签取内容）
    let text: String
    /// 用户自己写的备注（批注 contents）
    let note: String

    var isEmpty: Bool { text.isEmpty && note.isEmpty }
}

enum AnnotationScan {

    // ⚠️ `PDFAnnotation.type` 是 `String?`（nullable NSString），**不是** `PDFAnnotationSubtype`。
    // 那几个常量（`.highlight` 等）是另一套 `NS_STRING_ENUM`，要取 `rawValue` 才能比。
    //
    // ⚠️⚠️ 两边的字符串格式**不一样，必须先归一化**：
    //   PDFAnnotation.type                       → "Highlight"   （不带斜杠）
    //   PDFAnnotationSubtype.highlight.rawValue  → "/Highlight"  （PDF 名字对象格式）
    // 所以下面每个常量都要过一遍 `norm`，**不能只写 `.lowercased()`** ——
    // 踩过：只给 `key()` 归一化、常量没归一化，结果两边依然对不上，
    // 所有批注静默退化成「批注 /（无文字内容）」，不报错也不打日志。
    static func norm(_ s: String) -> String {
        var t = s.lowercased()
        if t.hasPrefix("/") { t.removeFirst() }
        return t
    }

    private static let kHighlight = norm(PDFAnnotationSubtype.highlight.rawValue)
    private static let kUnderline = norm(PDFAnnotationSubtype.underline.rawValue)
    private static let kStrikeOut = norm(PDFAnnotationSubtype.strikeOut.rawValue)
    // ⚠️ PDFKit 的 `PDFAnnotationSubtype` **没有** squiggly（头文件里明确写了
    // "Annotation subtypes not supported: … Squiggly …"）。但别的软件存下来的 PDF
    // 里可能有，读的时候照样能读到 → 用字面量兜一下，不指望它被渲染。
    private static let kSquiggly  = "squiggly"
    private static let kFreeText  = norm(PDFAnnotationSubtype.freeText.rawValue)
    private static let kSquare    = norm(PDFAnnotationSubtype.square.rawValue)
    private static let kCircle    = norm(PDFAnnotationSubtype.circle.rawValue)
    private static let kLine      = norm(PDFAnnotationSubtype.line.rawValue)
    private static let kInk       = norm(PDFAnnotationSubtype.ink.rawValue)
    private static let kStamp     = norm(PDFAnnotationSubtype.stamp.rawValue)
    private static let kPopup     = norm(PDFAnnotationSubtype.popup.rawValue)
    private static let kLink      = norm(PDFAnnotationSubtype.link.rawValue)
    private static let kWidget    = norm(PDFAnnotationSubtype.widget.rawValue)

    /// 取出批注的类型标识（已归一化：去斜杠 + 转小写）
    static func typeKey(_ a: PDFAnnotation) -> String { norm(a.type ?? "") }

    private static func key(_ a: PDFAnnotation) -> String {
        // ⚠️ 这里必须归一化掉前导斜杠，否则**永远匹配不上**：
        //   `PDFAnnotation.type`              → "Highlight"   （不带斜杠）
        //   `PDFAnnotationSubtype.highlight.rawValue` → "/Highlight"  （PDF 名字对象格式，带斜杠）
        // 不报错，只是所有批注静默退化成「批注 / （无文字内容）」——
        // 表现为：列表里全是"批注"、高亮的文字反查不出来、连弹窗和链接都会被当成用户标注收进来。
        var t = (a.type ?? "").lowercased()
        if t.hasPrefix("/") { t.removeFirst() }
        return t
    }

    /// 扫描全文档的批注。
    ///
    /// 只处理**真的有批注的页**：给高亮反查文字要逐字符比对 `characterBounds`，
    /// 300 页文档每页都建一遍字符表是几十万次调用，没必要。
    static func scan(_ doc: PDFDocument, ocrText: ((Int) -> String)? = nil) -> [AnnotationEntry] {
        var out: [AnnotationEntry] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let anns = page.annotations.filter { isInteresting($0) }
            guard !anns.isEmpty else { continue }

            // 这一页需要反查文字时才建字符表（只建一次，别在循环里反复建）
            var charBounds: [CGRect] = []
            var charIndex: [Int] = []
            if anns.contains(where: { isTextMarkup($0) }) {
                let n = page.numberOfCharacters
                charBounds.reserveCapacity(n)
                for c in 0..<n {
                    charBounds.append(page.characterBounds(at: c))
                    charIndex.append(c)
                }
            }

            for (k, ann) in anns.enumerated() {
                let kind = describe(ann)
                var text = ""
                if isTextMarkup(ann), !charBounds.isEmpty {
                    text = markedText(page: page, rect: ann.bounds,
                                      charBounds: charBounds, charIndex: charIndex,
                                      ocrText: ocrText, pageIndex: i)
                }
                out.append(AnnotationEntry(id: "\(i)|\(k)", pageIndex: i, annotation: ann,
                                           label: kind.label, icon: kind.icon, color: kind.color,
                                           text: text, note: ann.contents ?? ""))
            }
        }
        return out
    }

    /// 弹窗类、链接、表单控件不是"用户标注"，别混进列表
    static func isInteresting(_ a: PDFAnnotation) -> Bool {
        let k = key(a)
        return k != kPopup && k != kLink && k != kWidget
    }

    static func isTextMarkup(_ a: PDFAnnotation) -> Bool {
        let k = key(a)
        return k == kHighlight || k == kUnderline || k == kStrikeOut || k == kSquiggly
    }

    static func describe(_ a: PDFAnnotation) -> (label: String, icon: String, color: Color) {
        switch key(a) {
        case kHighlight:  return ("高亮", "highlighter", Color(nsColor: a.color))
        case kUnderline:  return ("下划线", "underline", Color(nsColor: a.color))
        case kStrikeOut:  return ("删除线", "strikethrough", Color(nsColor: a.color))
        case kSquiggly:   return ("波浪线", "scribble", Color(nsColor: a.color))
        case kFreeText:   return ("便签", "text.bubble.fill", Color(nsColor: a.color))
        case kSquare:     return ("方框", "square", Color(nsColor: a.color))
        case kCircle:     return ("椭圆", "circle", Color(nsColor: a.color))
        case kLine:       return ("直线", "line.diagonal", Color(nsColor: a.color))
        case kInk:        return ("手绘", "pencil.tip", Color(nsColor: a.color))
        case kStamp:      return ("图章", "seal", Color(nsColor: a.color))
        default:          return ("批注", "text.bubble", Color(nsColor: a.color))
        }
    }

    /// 反查高亮覆盖到的文字。
    ///
    /// 两条路，先用精确的、再退到省事的：
    /// 1. **逐字符比对**：找出中心落在批注矩形里的字符，取连续的那一段。
    ///    用"字符中心在框内"而不是矩形相交 —— 换行处的字符框会跨行，相交会有很多误收。
    /// 2. **`page.selection(for:)`**（`selectionForRect:`）：PDFKit 自己的矩形取文字。
    ///    字符层和批注坐标对不上的 PDF（比如 Core Text 逐行画出来的）走这条。
    static func markedText(page: PDFPage, rect: CGRect, charBounds: [CGRect], charIndex: [Int],
                           ocrText: ((Int) -> String)?, pageIndex: Int) -> String {
        var first: Int?
        var last: Int?
        for (k, b) in charBounds.enumerated() {
            let center = CGPoint(x: b.midX, y: b.midY)
            let inside = rect.insetBy(dx: -1.5, dy: -1.5).contains(center)
            if inside {
                if first == nil { first = charIndex[k] }
                last = charIndex[k]
            }
        }
        if let f = first, let l = last, l >= f,
           let sel = page.selection(for: NSRange(location: f, length: l - f + 1)),
           let s = sel.string, !s.isEmpty {
            return s.replacingOccurrences(of: "\n", with: " ")
        }
        // 退路一：让 PDFKit 自己按矩形取
        if let sel = page.selection(for: rect), let s = sel.string,
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.replacingOccurrences(of: "\n", with: " ")
        }
        // 退路二：扫描件没有字符层 → 给整页 OCR 文本的开头，至少比一片空白强
        if let ocrText {
            let t = ocrText(pageIndex).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return String(t.prefix(120)) }
        }
        return ""
    }

    // ---------- 导出 ----------

    static func markdown(_ entries: [AnnotationEntry], title: String) -> String {
        guard !entries.isEmpty else { return "" }
        var out = "# \(title) · 批注与笔记\n\n共 \(entries.count) 条。\n\n"
        var lastPage = -1
        for e in entries {
            if e.pageIndex != lastPage {
                out += "\n## 第 \(e.pageIndex + 1) 页\n\n"
                lastPage = e.pageIndex
            }
            out += "- **\(e.label)**"
            if !e.text.isEmpty { out += "：\(e.text)" }
            out += "\n"
            if !e.note.isEmpty { out += "    > \(e.note.replacingOccurrences(of: "\n", with: "\n    > "))\n" }
        }
        return out
    }
}
