// 生成一份用于演示 / 截图的多页英文 PDF 文档
// 用法：xcrun swiftc -O -o /tmp/mkdemo scripts/make_demo_pdf.swift && /tmp/mkdemo /tmp/qingyue-demo.pdf
import Foundation
import AppKit
import CoreText
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/qingyue-demo.pdf"

let pageW: CGFloat = 595.28, pageH: CGFloat = 841.89   // A4 @72dpi
let marginL: CGFloat = 72, marginR: CGFloat = 72, marginT: CGFloat = 78, marginB: CGFloat = 72

// ---------- 内容 ----------

struct Block { enum Kind { case h1, h2, body, quote, meta }; var kind: Kind; var text: String }

let blocks: [Block] = [
    .init(kind: .h1, text: "The Quiet Architecture of Reading"),
    .init(kind: .meta, text: "Mira Vasquez-Ohno  ·  Institute for Interface Studies  ·  March 2026"),
    .init(kind: .h2, text: "1. The Cost of a Glance"),
    .init(kind: .body, text: """
    A page of text is never merely text. Before a single word is understood, the eye has already made a series of judgements: how wide the measure is, how much air sits between the lines, whether the margins feel generous or stingy. These judgements happen faster than conscious thought, and they decide something important — whether the reader will settle in or hold back.
    """),
    .init(kind: .body, text: """
    Typographers have argued about the ideal measure for a century. The comfortable answer keeps landing near sixty-six characters per line. Shorter measures fragment the sentence into a staircase of eye movements; longer ones force the eye to hunt for the beginning of each new line, and readers quietly pay for that hunt with a measurable drop in comprehension.
    """),
    .init(kind: .quote, text: "Reading is not a straight line. It is a sequence of small, hopeful leaps."),
    .init(kind: .body, text: """
    Line spacing shows the same pattern. Roughly one and a half times the type size buys easy rhythm without letting the eye lose its place. Software has made these decisions easy to change and therefore easy to get wrong: the settings exist, but the consequences are invisible until a reader gives up.
    """),
    .init(kind: .h2, text: "2. Notes in the Margin"),
    .init(kind: .body, text: """
    Marginalia is the oldest form of interface design. A reader underlines, circles, argues in the gutter, and in doing so converts a passive document into a working surface. The physical gesture has barely changed in five hundred years, which suggests it is doing something the eye cannot do alone: it converts recognition into retrieval.
    """),
    .init(kind: .body, text: """
    Digital reading lost this for a while. Early e-readers could store ten thousand books and not one honest pencil mark. The correction came slowly, and it came from users rather than designers — people who kept screenshots in folders, who retyped passages into notebooks, who refused to let the machine decide what was worth remembering.
    """),
    .init(kind: .quote, text: "A note in the margin is a promise to your future self, written in the only language it will understand."),
    .init(kind: .h2, text: "3. Machines That Read With Us"),
    .init(kind: .body, text: """
    The newest readers are not human. Optical character recognition, machine translation, and summarisation have moved from research demonstrations into the toolbar of ordinary applications. A scanned page becomes searchable in under a second. A paragraph of Portuguese becomes a paragraph of Japanese before the coffee cools.
    """),
    .init(kind: .body, text: """
    This is a genuine change in what a document is. A page used to be a fixed arrangement of marks; it is now a surface with several possible readings, and the reader chooses which one to stand on. The difficulty is that the underlying machinery is confident even when it is wrong, and readers are generous with machines in a way they are never generous with each other.
    """),
    .init(kind: .body, text: """
    So the design problem shifts. It is no longer only how to display a page well. It is how to show the reader where the machine has been, what it changed, and how certain it was — without turning the page into a control panel. Trust, in other words, has become a typographic property.
    """),
    .init(kind: .h2, text: "4. Long Text and Its Seams"),
    .init(kind: .body, text: """
    Any system that processes a book must cut it into pieces, because no model holds a whole manuscript in view at once. The cuts are invisible in the output but decisive in the result. A sentence split across two requests can be translated twice, translated halfway, or quietly dropped — and nothing in the finished page announces the loss.
    """),
    .init(kind: .body, text: """
    The remedy is unglamorous. Split at paragraph boundaries rather than at character counts. Carry a little context across each seam. Then inspect every seam for the specific ways it fails: empty output, truncated output, an echo of the source, a fragment of the instruction leaking into the prose. None of this is optional, because a single missing sentence is indistinguishable from a sentence the author never wrote.
    """),
    .init(kind: .h2, text: "5. Progress as a Form of Respect"),
    .init(kind: .body, text: """
    There is a particular kind of silence that software produces when it is thinking. A spinner, a dimmed button, a window that no longer responds. The silence is not hostile, but it is indistinguishable from failure, and readers fill it with the worst available explanation.
    """),
    .init(kind: .body, text: """
    Naming the work costs almost nothing. Which page is being processed. How many remain. How long the last one took, which predicts the next. Whether the result will be cached, so that running it twice is cheap. A long job that reports its own progress can be left alone; a long job that reports nothing must be watched.
    """),
    .init(kind: .quote, text: "Waiting is bearable when it has a shape."),
    .init(kind: .h2, text: "6. What We Owe the Reader"),
    .init(kind: .body, text: """
    Every reading tool makes an argument about attention. Some argue that attention is cheap and should be spent freely. Others argue that it is the scarcest resource a person owns, and that a tool earning its place must return more of it than it takes.
    """),
    .init(kind: .body, text: """
    The second argument is harder to design for, because it asks for subtraction. Fewer panels. Fewer settings visible at once. Progress reported honestly rather than decoratively. A long job that can be stopped. A result that arrives with its own provenance attached.
    """),
    .init(kind: .body, text: """
    None of this is visible in a feature list. It shows up in the moment a reader stops thinking about the software and starts thinking about the book — which is, and has always been, the whole point.
    """),
]

// ---------- 排版 ----------

func font(_ name: String, _ size: CGFloat, _ fallback: NSFont.TextStyle?) -> NSFont {
    if let f = NSFont(name: name, size: size) { return f }
    return NSFont.systemFont(ofSize: size)
}

let bodyFont = font("Times New Roman", 11.5, nil)
let h1Font = font("Avenir Next Demi Bold", 25, nil)
let h2Font = font("Avenir Next Demi Bold", 14.5, nil)
let metaFont = font("Avenir Next Medium", 10.5, nil)
let quoteFont = font("Times New Roman Italic", 13, nil)

let ink = NSColor(calibratedWhite: 0.12, alpha: 1)
let soft = NSColor(calibratedWhite: 0.42, alpha: 1)
let accent = NSColor(srgbRed: 0.44, green: 0.30, blue: 0.82, alpha: 1)

func attributed(_ b: Block) -> NSAttributedString {
    let ps = NSMutableParagraphStyle()
    switch b.kind {
    case .h1:
        ps.paragraphSpacing = 6; ps.lineHeightMultiple = 1.02
        return NSAttributedString(string: b.text, attributes: [
            .font: h1Font, .foregroundColor: ink, .paragraphStyle: ps, .kern: 0.2])
    case .meta:
        ps.paragraphSpacing = 26
        return NSAttributedString(string: b.text, attributes: [
            .font: metaFont, .foregroundColor: soft, .paragraphStyle: ps])
    case .h2:
        ps.paragraphSpacingBefore = 16; ps.paragraphSpacing = 7
        return NSAttributedString(string: b.text, attributes: [
            .font: h2Font, .foregroundColor: ink, .paragraphStyle: ps, .kern: 0.1])
    case .body:
        ps.lineSpacing = 4.4; ps.paragraphSpacing = 9; ps.alignment = .justified
        ps.hyphenationFactor = 0.9
        return NSAttributedString(string: b.text, attributes: [
            .font: bodyFont, .foregroundColor: ink, .paragraphStyle: ps])
    case .quote:
        ps.lineSpacing = 5; ps.paragraphSpacingBefore = 12; ps.paragraphSpacing = 16
        ps.firstLineHeadIndent = 20; ps.headIndent = 20
        return NSAttributedString(string: b.text, attributes: [
            .font: quoteFont, .foregroundColor: accent, .paragraphStyle: ps])
    }
}

// 逐块测量，切页
var pages: [NSAttributedString] = []
let textW = pageW - marginL - marginR
let textH = pageH - marginT - marginB
var current = NSMutableAttributedString()

func height(_ s: NSAttributedString) -> CGFloat {
    let f = CTFramesetterCreateWithAttributedString(s)
    let sz = CTFramesetterSuggestFrameSizeWithConstraints(
        f, CFRange(location: 0, length: 0), nil, CGSize(width: textW, height: .greatestFiniteMagnitude), nil)
    return ceil(sz.height)
}

for b in blocks {
    let a = NSMutableAttributedString(attributedString: attributed(b))
    // 每个块必须以换行结尾，才会被当成独立段落 —— 否则 paragraphSpacing 全部失效，
    // 标题和正文会挤成一坨（踩过）。
    a.append(NSAttributedString(string: "\n", attributes: a.attributes(at: 0, effectiveRange: nil)))
    if height(current as NSAttributedString) + height(a) > textH && current.length > 0 {
        pages.append(current)
        current = NSMutableAttributedString()
        // 续页给个小标题，模拟真实书籍
        let cont = NSMutableParagraphStyle()
        cont.paragraphSpacing = 20
        current.append(NSAttributedString(string: "The Quiet Architecture of Reading  ·  continued\n",
                                          attributes: [.font: metaFont, .foregroundColor: soft, .paragraphStyle: cont]))
    }
    current.append(a)
}
if current.length > 0 { pages.append(current) }

// ---------- 绘制 ----------

let url = URL(fileURLWithPath: out)
var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
guard let consumer = CGDataConsumer(url: url as CFURL),
      let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    print("无法创建 PDF"); exit(1)
}

for (i, page) in pages.enumerated() {
    ctx.beginPDFPage(nil)

    // 首行装饰线
    ctx.setStrokeColor(NSColor(srgbRed: 0.44, green: 0.30, blue: 0.82, alpha: 0.85).cgColor)
    ctx.setLineWidth(2.4)
    ctx.move(to: CGPoint(x: marginL, y: pageH - marginT + 26))
    ctx.addLine(to: CGPoint(x: marginL + 46, y: pageH - marginT + 26))
    ctx.strokePath()

    // 正文。这个上下文本来就是 y 轴朝上的（CGContext 默认），CTFrameDraw 直接画
    // 就是正的 —— 千万别再翻一次，否则正文整个上下颠倒（踩过）。
    let path = CGPath(rect: CGRect(x: marginL, y: marginB, width: textW, height: textH), transform: nil)
    let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(page), CFRange(location: 0, length: 0), path, nil)
    ctx.textMatrix = .identity
    CTFrameDraw(frame, ctx)

    // 页码
    let num = "\(i + 1) / \(pages.count)"
    let numAttr = NSAttributedString(string: num, attributes: [
        .font: metaFont, .foregroundColor: soft])
    let line = CTLineCreateWithAttributedString(numAttr)
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: (pageW - CGFloat(w)) / 2, y: marginB - 34)
    CTLineDraw(line, ctx)

    ctx.endPDFPage()
}
ctx.closePDF()
print("✓ \(out)  ·  \(pages.count) 页")
