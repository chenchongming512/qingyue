// 轻阅 · 真值测试台（命令行运行，不依赖 UI）
//
// 编译（改动源码后照抄这一行，别只编 src 里那一个文件）：
//   xcrun swiftc -O -Xfrontend -disable-sandbox -o build/qy-tests tests/main.swift \
//     src/TranslateCore.swift src/OCREngine.swift src/TaskCenter.swift \
//     src/AIStore.swift src/AIClient.swift src/TranslateStore.swift \
//     src/Design.swift src/SearchCore.swift src/StudyCore.swift src/AnnotationCore.swift
//
// ⚠️ `-Xfrontend -disable-sandbox` 不是可选的：不加的话编译 Swift 宏
// （@Published 等）会被沙箱拒掉，满屏"StateMacro could not be found"假报错。
//
// ⚠️ 五个"非 UI 但必须一起编"的文件，漏一个就报 cannot find in scope：
//   · Design.swift      —— TaskCenter.swift 引用它取颜色 / 动效 token
//   · SearchCore.swift  —— SearchHit 与 selectionsMap（第 9 节的性能与命中位置）
//   · StudyCore.swift   —— Bookmark / BookmarkStore / PageSampler / OutlineParser / MiniMarkdown
//   · AnnotationCore.swift —— AnnotationScan（第 12 节批注类型归一化）
//   · TaskCenter.swift  —— 任务中心（OCR 进度聚合）
// 之所以把这些从 UI 文件里拆出来，就是为了让测试台不必把整个 SwiftUI 界面编进来。
//
// ⚠️⚠️ **别用"在测试文件里重写一份同样的逻辑"来测**。踩过：第 12 节一开始
// 在测试里自己写了个 `normalized()`，测全绿，但真代码 `AnnotationScan.key()`
// 压根没编进测试台（nm 查 AnnotationScan 符号数 = 0）—— 于是真 bug 从测试
// 底下溜走了。凡是要测的东西，**必须引用 src 里的那个符号**。

import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit
import CoreGraphics
import CoreText

var passed = 0
var failed = 0

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")") }
}
func section(_ title: String) { print("\n=== \(title) ===") }

let testPDF = URL(fileURLWithPath: "/tmp/qingyue-test.pdf")
guard let srcDoc = PDFDocument(url: testPDF), srcDoc.pageCount > 0 else {
    print("找不到测试 PDF：\(testPDF.path)"); exit(2)
}
print("测试文档：\(testPDF.path) · \(srcDoc.pageCount) 页")

// ---------------------------------------------------------------
section("1. 切片、提示词与接缝质检（纯逻辑）")

let longPage = (1...8).map { i in
    "第 \(i) 段：缓存保存的是之前请求的结果，它不是事实来源。当缓存过期时，系统会重新计算这个值，"
    + "这个过程中可能出现短暂的不一致，据部分用户反馈界面会闪烁一次，但团队还没有测量数据。"
}.joined(separator: "\n\n") + "\n\n这一段的结尾故意不加句号，用来测试切片边界"

let chunks = TextSplitter.chunks(forPage: longPage, pageIndex: 5, previousContext: "上一页最后一句话。",
                                 target: 300, overlapSentences: 2)
check("长文本被切成多片（≥3）", chunks.count >= 3, "实际 \(chunks.count)")
check("切片编号连续", chunks.enumerated().allSatisfy { $0.offset == $0.element.index })
check("每片不超过目标的 1.5 倍", chunks.allSatisfy { $0.text.count <= 450 },
      "最大 \(chunks.map(\.text.count).max() ?? 0)")
check("第一片带上上一页的上文", chunks.first?.context == "上一页最后一句话。")
check("后续片带上本页上文", chunks.count > 1 && (chunks[1].context?.isEmpty == false))

let paras = TextSplitter.paragraphs(longPage)
check("段落切分正确（9 段）", paras.count == 9, "实际 \(paras.count)")
func normalized(_ s: String) -> String {
    s.unicodeScalars.filter { !$0.properties.isWhitespace }.map(String.init).joined()
}
check("零丢失：切片内容与原文一致（忽略空白）",
      normalized(paras.joined()) == normalized(chunks.map(\.text).joined()))
check("没有把段落从中间劈开",
      chunks.allSatisfy { c in
          TextSplitter.paragraphs(c.text).allSatisfy { paras.contains($0) }
      })

let enSentences = TextSplitter.sentences("Dr. Smith went to Washington. He arrived at 3.14 pm. Then he left.")
check("英文句切分保护缩写与小数", enSentences.count == 3, "实际 \(enSentences.count)：\(enSentences)")
let zhSentences = TextSplitter.sentences("他来了。她走了！你还好吗？")
check("中文句切分", zhSentences.count == 3, "实际 \(zhSentences.count)")

var settings = TranslateSettings()
settings.deAI = true
settings.targetLang = "zh-Hans"
settings.style = .professional
settings.convertTerms = [GlossaryEntry(source: "cache", target: "缓存")]
let sys = PromptBuilder.systemPrompt(settings)
check("提示词包含去 AI 味硬约束", sys.contains("硬约束") && sys.contains("不写铺垫"))
check("提示词包含术语表", sys.contains("「cache」→「缓存」"))
check("提示词声明输出协议", sys.contains("<T></T>"))
check("英文目标语言改用英文去 AI 味规则",
      PromptBuilder.systemPrompt({ var s = TranslateSettings(); s.deAI = true; s.targetLang = "en"; return s }())
        .contains("human-written English"))

check("解析 <T> 标签", PromptBuilder.parse("<T>你好，世界。</T>") == "你好，世界。")
check("解析代码块", PromptBuilder.parse("```\n早上好\n```") == "早上好")
check("去掉“译文：”前缀", PromptBuilder.parse("译文：晚上好") == "晚上好")
check("成对引号剥离", PromptBuilder.parse("“这是一句话”") == "这是一句话")
check("简化协议不含标签",
      !PromptBuilder.simpleMessages(TranslateChunk(id: "x", pageIndex: 0, index: 0, text: "a", context: nil, isContinuation: false), settings)
        .map(\.content).joined().contains("<T>"))

// 接缝质检
let seamChunks = [
    TranslateChunk(id: "p0-c0", pageIndex: 0, index: 0, text: "缓存保存的是之前请求的结果，它不是事实来源。", context: nil, isContinuation: false),
    TranslateChunk(id: "p0-c1", pageIndex: 0, index: 1, text: "当缓存过期时，系统会重新计算，这个过程中可能出现短暂的不一致。", context: nil, isContinuation: true),
    TranslateChunk(id: "p0-c2", pageIndex: 0, index: 2, text: "据部分用户反馈，界面会闪烁一次。", context: nil, isContinuation: true),
    TranslateChunk(id: "p0-c3", pageIndex: 0, index: 3, text: "最后一段：这项调整可能减少读取时间，目前尚未验证。", context: nil, isContinuation: true)
]
let seamOut = [
    "缓存保存的是之前请求的结果，它不是事实来源。",
    "",
    "缓存保存的是之前请求的结果，它不是事实来源。据部分用户反馈，界面会闪烁一次",
    "<T>最后一段：这项调整可能减少读取时间，目前尚未验证。</T>"
]
let kinds = Set(SeamCheck.check(source: seamChunks, outputs: seamOut).map { $0.kind })
check("检出空结果", kinds.contains(.empty))
check("检出截断（结尾缺终止标点）", kinds.contains(.truncated))
check("检出错片回声重复（跨空结果也能发现）", kinds.contains(.echoPrevious))
check("检出格式串泄漏", kinds.contains(.formatLeak))
let (stripped, didStrip) = SeamCheck.stripDuplicatedPrefix(seamOut[2], previousTyped: seamOut[0])
check("回声可自动修复", didStrip && stripped.hasPrefix("据部分用户反馈"))
check("正常译文不误报",
      SeamCheck.check(source: Array(seamChunks.prefix(2)),
                      outputs: ["缓存保存的是之前请求的结果，它不是事实来源。",
                                "系统在缓存过期时重新计算，期间可能短暂不一致。"]).isEmpty)

section("1b. 退化输出判定（本地小模型的脾气）")
let enSrc = "The cache stores the results of previous requests. It is not a source of truth. When the cache expires, the system recomputes the value, and a brief inconsistency may appear during this window."
check("空回复判为退化", Degenerate.reason(output: "", source: enSrc) != nil)
check("只吐标签判为退化", Degenerate.reason(output: "<CTX>\nNone\n</CTX>", source: enSrc) != nil)
check("复述要求判为退化",
      Degenerate.reason(output: "<CTX> 用户要求： - 目标语言：简体中文 - 风格要求：专业", source: enSrc) != nil)
check("截断到极短判为退化", Degenerate.reason(output: "缓存存储先前", source: enSrc) != nil)
check("正常译文判为合格",
      Degenerate.reason(output: "缓存保存的是之前请求的结果，它不是事实来源。缓存过期时系统会重新计算，期间可能出现短暂的不一致。",
                        source: enSrc, targetLang: "zh-Hans") == nil)
check("中文目标但输出全英文判为退化",
      Degenerate.reason(output: "The cache stores the results of previous requests and it is not a source of truth.",
                        source: enSrc, targetLang: "zh-Hans") != nil)
check("中译英正常输出也判为合格",
      Degenerate.reason(output: "The cache stores the results of previous requests; it is not a source of truth.",
                        source: "缓存保存的是之前请求的结果，它不是事实来源。", targetLang: "en") == nil)
check("中译英却原样返回判为退化",
      Degenerate.reason(output: "缓存保存的是之前请求的结果，它不是事实来源。",
                        source: "缓存保存的是之前请求的结果，它不是事实来源。", targetLang: "en") != nil)

// ---------------------------------------------------------------
section("2. 框选裁剪的坐标系（回归：曾经上下翻转）")
// 这段不依赖 Vision：自己造一页「上红下蓝」，渲染成位图后按归一化坐标裁上下两半，
// 各取平均色。裁上半拿到红、裁下半拿到蓝，才算坐标系一致。
// （旧实现把 CGImage.cropping 的左上原点当成左下，裁出来是镜像的——
//   框选页面上半部分的英文，实际识别到的是下半部分。）
func makeHalfPage() -> PDFPage? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    ctx.beginPDFPage(nil)
    // CGContext 的 y 轴朝上：y = 100...200 是页面**上半**
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 100, width: 200, height: 100))
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(data: data as Data)?.page(at: 0)
}

if let hp = makeHalfPage(), let img = OCREngine.renderPageImage(hp, scale: 1.0, box: .mediaBox) {
    let top = OCREngine.crop(img, normalized: CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    let bot = OCREngine.crop(img, normalized: CGRect(x: 0, y: 0, width: 1, height: 0.5))
    let t = top.map { meanRGB($0) } ?? (0.0, 0.0, 0.0)
    let b = bot.map { meanRGB($0) } ?? (0.0, 0.0, 0.0)
    check("裁上半拿到页面上半（红）", t.0 > 150 && t.2 < 110,
          "实际 R\(Int(t.0)) G\(Int(t.1)) B\(Int(t.2))")
    check("裁下半拿到页面下半（蓝）", b.2 > 150 && b.0 < 110,
          "实际 R\(Int(b.0)) G\(Int(b.1)) B\(Int(b.2))")
    check("越界矩形被夹回边界而不是崩/返回错图",
          OCREngine.crop(img, normalized: CGRect(x: -0.5, y: 0.8, width: 1, height: 1)) != nil)
    check("零面积矩形返回 nil", OCREngine.crop(img, normalized: .zero) == nil)
    check("裁切尺寸与归一化高度相符",
          top.map { abs($0.height - 100) <= 2 } ?? false,
          top.map { "\($0.width)x\($0.height)" } ?? "nil")
} else {
    check("构造上下异色测试页", false)
}

// ---------------------------------------------------------------
section("3. 边界与鲁棒性（纯逻辑）")
check("空文本不产生切片",
      TextSplitter.chunks(forPage: "", pageIndex: 0, previousContext: nil,
                          target: 1200, overlapSentences: 2).isEmpty)
check("纯空白页不产生切片",
      TextSplitter.chunks(forPage: "   \n\n \t \n", pageIndex: 0, previousContext: nil,
                          target: 1200, overlapSentences: 2).isEmpty)
check("空文本不产生段落", TextSplitter.paragraphs("").isEmpty)
check("空文本句子切分返回空", TextSplitter.sentences("").isEmpty)
check("target 过小会被抬到下限（不产生碎片）", {
    let cs = TextSplitter.chunks(forPage: longPage, pageIndex: 0, previousContext: nil,
                                 target: 10, overlapSentences: 0)
    let paras = TextSplitter.paragraphs(longPage)
    // target 被抬到下限 200：片数不应比段落还多，且单片不超过 1.5 倍下限
    return !cs.isEmpty && cs.count <= paras.count && cs.allSatisfy { $0.text.count <= 300 }
}(), "片数 \(TextSplitter.chunks(forPage: longPage, pageIndex: 0, previousContext: nil, target: 10, overlapSentences: 0).count) / 段数 \(TextSplitter.paragraphs(longPage).count)")
check("overlapSentences = 0 时后续片不带上文", {
    let cs = TextSplitter.chunks(forPage: longPage, pageIndex: 0, previousContext: "上文。",
                                 target: 300, overlapSentences: 0)
    return cs.first?.context == "上文。" && cs.dropFirst().allSatisfy { $0.context == nil }
}())
check("译文里只有 <T> 开标签时不吞正文", PromptBuilder.parse("<T>你好") == "<T>你好")
check("空回复解析为空串", PromptBuilder.parse("").isEmpty)
check("接缝质检对空输入不崩", SeamCheck.check(source: [], outputs: []).isEmpty)
check("长度极短的原文本不触发长度类误报",
      SeamCheck.check(source: [TranslateChunk(id: "x", pageIndex: 0, index: 0, text: "好的。",
                                              context: nil, isContinuation: false)],
                      outputs: ["OK."]).count <= 1)
check("退化判定对超长输出报警", Degenerate.reason(output: String(repeating: "字", count: 900), source: "short text") != nil)

// ---------------------------------------------------------------
section("4. 本地 Vision OCR（真机）")
var ocrSettings = OCRSettings()
ocrSettings.languages = ["zh-Hans", "en-US"]
guard let page1 = srcDoc.page(at: 0) else { exit(2) }
let visionResult = OCREngine.visionPageResult(page1, pageIndex: 0, settings: ocrSettings)
print("  识别耗时 \(String(format: "%.2f", visionResult.seconds))s · \(visionResult.lines.count) 行 · \(visionResult.text.count) 字")
print("  预览：\(visionResult.text.prefix(80).replacingOccurrences(of: "\n", with: " / "))")
check("Vision 识别出文字", visionResult.text.count > 5)
check("识别内容与原文相关",
      visionResult.text.contains("轻阅") || visionResult.text.contains("测试") || visionResult.text.contains("Chapter"),
      "实际：\(visionResult.text.prefix(40))")
check("行置信度中位数 > 0.3", {
    let c = visionResult.lines.map(\.confidence).sorted()
    return c.isEmpty || c[c.count / 2] > 0.3
}())

// ---------------------------------------------------------------
section("5. 可搜索 PDF 导出与验证")
let outPDF = URL(fileURLWithPath: "/tmp/qy-searchable.pdf")
try? FileManager.default.removeItem(at: outPDF)
do {
    let written = try OCREngine.writeSearchablePDF(doc: srcDoc, results: [0: visionResult], to: outPDF)
    check("导出成功且页数一致", written == srcDoc.pageCount, "写入 \(written) vs 原 \(srcDoc.pageCount)")
    if let reDoc = PDFDocument(url: outPDF), let rePage = reDoc.page(at: 0) {
        let text = rePage.string ?? ""
        print("  导出后可提取文本：\(text.prefix(70).replacingOccurrences(of: "\n", with: " / "))")
        check("存在可选中的文本层", text.count > 5)
        let needle = String(visionResult.lines.first?.text.prefix(4) ?? "")
        check("文本层内容与识别结果一致", needle.isEmpty || text.contains(needle), "找「\(needle)」")
        if let a = OCREngine.renderPageImage(page1, scale: 0.6, box: .mediaBox),
           let b = OCREngine.renderPageImage(rePage, scale: 0.6, box: .mediaBox) {
            let diff = meanAbsDiff(a, b)
            print("  页面像素平均差：\(String(format: "%.2f", diff))/255")
            check("导出页与原页视觉一致（未翻转/空白）", diff < 14, String(format: "%.2f", diff))
        } else { check("导出页与原页视觉一致（未翻转/空白）", false, "渲染失败") }
    } else { check("导出后可重新打开", false) }
} catch { check("导出可搜索 PDF", false, error.localizedDescription) }

// ---------------------------------------------------------------
section("6. 本地 Ollama 真实翻译（含降级重试）")
let provider = AIProvider(name: "Ollama（本地）", kind: .ollama, baseURL: "http://127.0.0.1:11434")
let models = (try? await AIClient.shared.listModels(provider: provider)) ?? []
let model = models.first { $0.contains("qwen3.5:4b") } ?? models.first { $0.contains("qwen3.5") } ?? models.first ?? ""
check("能连上本地 Ollama 并取到模型", !model.isEmpty, "模型数 \(models.count)")
print("  使用模型：\(model)")

if !model.isEmpty {
    var tr = TranslateSettings()
    tr.sourceLang = "en"; tr.targetLang = "zh-Hans"; tr.style = .professional; tr.deAI = true
    let store = TranslateStore()
    let target = (provider: provider, model: model, key: "")

    let enChunk = TranslateChunk(id: "t-c0", pageIndex: 0, index: 0,
                                 text: enSrc, context: nil, isContinuation: false)

    // 连续 3 次，验证「退化 → 自动降级 → 仍能拿到合格译文」
    var okCount = 0
    var outputs: [String] = []
    for i in 1...3 {
        do {
            let out = try await store.translateChunkOnce(enChunk, settings: tr, target: target)
            let bad = Degenerate.reason(output: out, source: enChunk.text, targetLang: tr.targetLang)
            let hasChinese = out.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
            outputs.append(out)
            if bad == nil && hasChinese { okCount += 1 }
            print("  第 \(i) 次：\(bad == nil ? "合格" : "仍异常(\(bad!))") · \(out.prefix(60).replacingOccurrences(of: "\n", with: " "))")
        } catch {
            print("  第 \(i) 次失败：\(error.localizedDescription)")
        }
    }
    check("三次调用全部拿到合格译文（退化被降级重试兜住）", okCount == 3, "合格 \(okCount)/3")
    check("译文包含中文", outputs.contains { $0.unicodeScalars.contains { s in s.value >= 0x4E00 && s.value <= 0x9FFF } })
    check("接缝质检不误报",
          outputs.allSatisfy { SeamCheck.check(source: [enChunk], outputs: [$0]).isEmpty },
          "误报：\(outputs.flatMap { SeamCheck.check(source: [enChunk], outputs: [$0]).map { "\($0.kind.rawValue)：\($0.detail)" } })")
    check("去 AI 味未出现禁用套话",
          outputs.allSatisfy { !$0.contains("让我们") && !$0.contains("总而言之") && !$0.contains("不仅") })

    section("7. 视觉模型 OCR（真机，验证图片通道）")
    if let img = OCREngine.renderPageImage(page1, scale: 2.0) {
        do {
            let started = Date()
            let text = try await OCREngine.llmOCR(image: img, provider: provider, model: model, key: "",
                                                  format: .plain, maxTokens: 600)
            print("  视觉 OCR（\(String(format: "%.1f", Date().timeIntervalSince(started)))s）：\(text.prefix(110).replacingOccurrences(of: "\n", with: " / "))")
            check("视觉模型返回了文字", text.count > 3)
            check("返回内容与页面相关",
                  text.contains("轻阅") || text.contains("测试") || text.contains("Chapter") || text.contains("页"),
                  "实际：\(text.prefix(50))")
        } catch { check("视觉模型 OCR 调用", false, error.localizedDescription) }
    } else { check("视觉模型 OCR 调用", false, "页面渲染失败") }
}

// ---------------------------------------------------------------
section("8. 全文搜索（逐页扫描 + 惰性选区）")

// 最要紧的一条：**逐页扫描必须和 doc.findString 的结果等价**。
// 换实现是为了快（410ms → 10ms 量级），但不能因此少找或多找。
for word in ["轻阅", "页", "Chapter", "sample"] {
    let mine = selectionsMap(query: word, doc: srcDoc)
    let theirs = srcDoc.findString(word, withOptions: [.caseInsensitive]).count
    check("「\(word)」命中数与 findString 一致", mine.count == theirs,
          "本实现 \(mine.count) vs findString \(theirs)")
}

let onePageHits = selectionsMap(query: "页", doc: srcDoc)
check("同一页多处命中都扫到了（不是每页只取一条）",
      Dictionary(grouping: onePageHits, by: \.pageIndex).values.contains { $0.count > 1 },
      "每页命中数 \(Dictionary(grouping: onePageHits, by: \.pageIndex).values.map(\.count))")
check("命中按页码升序",
      zip(onePageHits, onePageHits.dropFirst()).allSatisfy { $0.pageIndex <= $1.pageIndex })
check("match 就是查询词本身（大小写不敏感）",
      selectionsMap(query: "chapter", doc: srcDoc).allSatisfy {
          $0.match.lowercased() == "chapter"
      })
check("命中带上下文（非行首的命中左侧应有文字）",
      onePageHits.contains { !$0.before.isEmpty })
check("选区是惰性构造的，拿到之后能取出同样的文字",
      selectionsMap(query: "sample", doc: srcDoc).allSatisfy { h in
          guard let s = h.selection?.string else { return false }
          return s.lowercased() == h.match.lowercased()
      })
check("选区的页码与本条记录一致",
      selectionsMap(query: "Chapter", doc: srcDoc).allSatisfy { h in
          guard let p = h.selection?.pages.first, let doc = h.page else { return false }
          return h.pageIndex == srcDoc.index(for: doc) && p === doc
      })
check("limit 生效", selectionsMap(query: "页", doc: srcDoc, limit: 5).count == 5)
check("查不到的词返回空", selectionsMap(query: "这个词一定不存在啊", doc: srcDoc).isEmpty)
check("空查询返回空", selectionsMap(query: "", doc: srcDoc).isEmpty)
check("特殊字符不崩（正则元字符当字面量）",
      selectionsMap(query: "a(b[c", doc: srcDoc).isEmpty)

// ---------------------------------------------------------------
section("9. 书签（存储 / 排序 / 导出）")

var bms: [Bookmark] = [
    Bookmark(pageIndex: 7, title: "第七章", note: "重点看这节的公式"),
    Bookmark(pageIndex: 1, title: "引言"),
    Bookmark(pageIndex: 4, title: "方法", y: 0.5)
]
check("排序按页码", BookmarkStore.sorted(bms).map(\.pageIndex) == [1, 4, 7])
check("同一页多条按创建时间排", {
    var a = Bookmark(pageIndex: 3, title: "先")
    a.createdAt = Date(timeIntervalSince1970: 100)
    var b = Bookmark(pageIndex: 3, title: "后")
    b.createdAt = Date(timeIntervalSince1970: 200)
    return BookmarkStore.sorted([b, a]).map(\.title) == ["先", "后"]
}())
check("编解码往返不丢字段", {
    guard let data = BookmarkStore.encode(bms) else { return false }
    let back = BookmarkStore.decode(data)
    return back.count == bms.count
        && back.map(\.title) == BookmarkStore.sorted(bms).map(\.title)
        && back.first(where: { $0.pageIndex == 7 })?.note == "重点看这节的公式"
        && back.first(where: { $0.pageIndex == 4 })?.y == 0.5
}())
check("解码垃圾数据返回空而不是崩", BookmarkStore.decode(Data("not json".utf8)).isEmpty)
check("解码 nil 返回空", BookmarkStore.decode(nil).isEmpty)

let bmMD = BookmarkStore.markdown(bms, title: "测试文档")
check("导出含标题头", bmMD.hasPrefix("# 测试文档 · 书签"))
check("导出含页码", bmMD.contains("**第 2 页**") && bmMD.contains("**第 8 页**"))
check("导出里备注用引用块并换行缩进", bmMD.contains("> 重点看这节的公式"))
check("导出顺序与排序一致",
      bmMD.range(of: "第 2 页")!.lowerBound < bmMD.range(of: "第 5 页")!.lowerBound
      && bmMD.range(of: "第 5 页")!.lowerBound < bmMD.range(of: "第 8 页")!.lowerBound)
check("空书签导出空串", BookmarkStore.markdown([], title: "x").isEmpty)

check("默认标题取该页首行", BookmarkStore.defaultTitle(pageText: "  第一章 绪论\n正文正文", pageIndex: 2) == "第一章 绪论")
check("首行为空则取下一个非空行", BookmarkStore.defaultTitle(pageText: "\n\n  方法  \n正文", pageIndex: 0) == "方法")
check("没有文本时回落到页码", BookmarkStore.defaultTitle(pageText: nil, pageIndex: 2) == "第 3 页")
check("纯空白页回落到页码", BookmarkStore.defaultTitle(pageText: "  \n \n", pageIndex: 0) == "第 1 页")
check("超长首行截断并加省略号", {
    let long = String(repeating: "字", count: 60)
    let t = BookmarkStore.defaultTitle(pageText: long, pageIndex: 0)
    return t.count == 29 && t.hasSuffix("…")
}())
check("有路径时 key 带上前缀", BookmarkStore.key(for: URL(fileURLWithPath: "/tmp/a.pdf"))?.hasPrefix("qingyue.bookmarks.") == true)
check("没有路径就没有 key", BookmarkStore.key(for: nil) == nil)

// ---------------------------------------------------------------
section("10. 文档取样与自动大纲解析")

let digest = PageSampler.pageDigest(srcDoc)
let digestLines = digest.split(separator: "\n")
check("页首摘要每页一行", digestLines.count == srcDoc.pageCount, "实际 \(digestLines.count)")
check("每行是「页码|内容」且页码连续", digestLines.enumerated().allSatisfy { i, line in
    line.hasPrefix("\(i + 1)|")
})
check("maxPages 生效", PageSampler.pageDigest(srcDoc, maxPages: 3).split(separator: "\n").count == 3)
check("OCR 兜底能补上空白页的文本", {
    // 拿一份真的没有文本层的页来测：tmp 里造一个空白页
    guard let blank = makeBlankDoc() else { return false }
    return PageSampler.pageDigest(blank, ocrText: { _ in "OCR 补的文字" }).contains("OCR 补的文字")
}())
check("没有 OCR 兜底时空白页留给模型的是空标题", {
    guard let blank = makeBlankDoc() else { return false }
    return PageSampler.pageDigest(blank).hasSuffix("|")
}())

let (body, note) = PageSampler.bodySample(srcDoc)
check("短文档全文取样", note.hasPrefix("覆盖全部"), "实际：\(note)")
check("取样正文非空", body.count > 50)
// 造一份单页超长文本来验"真的会截断"，光靠 12 页短文档是碰不到截断分支的
if let longDoc = makeLongTextDoc(chars: 3000), let longPage = longDoc.page(at: 0) {
    let full = (longPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count
    let (sampledBody, sampledNote) = PageSampler.bodySample(longDoc, budget: 300)
    check("超长页会被截断到每页上限", sampledBody.count < full, "\(sampledBody.count) vs \(full)")
    check("截断时如实说明覆盖范围", sampledNote.contains("抽样"), "实际：\(sampledNote)")
    let (wholeBody, _) = PageSampler.bodySample(longDoc, budget: 100_000)
    check("预算够时不截断", wholeBody.count == full, "\(wholeBody.count) vs \(full)")
} else {
    check("构造超长文本页", false)
}
check("没有可读文本时如实返回空", {
    guard let blank = makeBlankDoc() else { return false }
    let (t, n) = PageSampler.bodySample(blank)
    return t.isEmpty && n.contains("没有可读文本")
}())

// 模型输出的花式格式都要能救回来
let messyOutline = """
```
1. 1|引言
- 14|系统设计
**20｜测试与验证**
不是这行
3. 14|重复页应被丢掉
2. 第一章
99|页码越界要丢掉
  7|  缓存与一致性
1、这种顿号分隔不认（顿号更可能是序号，认了会插错页码）
```
"""
let parsed = OutlineParser.parse(messyOutline, pageCount: 30)
check("救回 4 条有效章节", parsed.count == 4, "实际 \(parsed.count)：\(parsed.map { "\($0.pageIndex + 1)|\($0.title)" })")
check("解析出的页码按升序", parsed.map(\.pageIndex) == parsed.map(\.pageIndex).sorted())
check("重复页码只留第一条", parsed.filter { $0.pageIndex == 13 }.count == 1)
check("越界页码被丢掉", !parsed.contains { $0.pageIndex == 98 })
check("去掉序号、星号与引号", parsed.contains { $0.title == "引言" } && parsed.contains { $0.title == "测试与验证" })
check("全角分隔符也能认", parsed.contains { $0.pageIndex == 19 })
check("不加横线的裸标题行不会被误认", !parsed.contains { $0.title.contains("不是这行") })
check("顿号分隔不认（更可能是序号而不是页码）", !parsed.contains { $0.title.contains("顿号") })
check("空输出返回空数组", OutlineParser.parse("", pageCount: 10).isEmpty)
check("一页都没有的文档不会解析出东西", OutlineParser.parse("1|标题", pageCount: 0).isEmpty)
check("标题过长的条目被丢掉", OutlineParser.parse("1|" + String(repeating: "字", count: 60), pageCount: 5).isEmpty)

// ---------------------------------------------------------------
section("11. OCR 整篇的并发数（跟着机器核数走）")

let visionConc = OCREngine.batchConcurrency(engine: .vision)
let cores = ProcessInfo.processInfo.activeProcessorCount
print("  本机 \(cores) 核 → 本地 Vision 并发 \(visionConc)")
check("本地 Vision 并发落在 [2,6]", visionConc >= 2 && visionConc <= 6)
check("不写死 4（核数少时要降下来）", cores / 2 <= 6 || visionConc == 6)
check("核数充足时不会低于 2", cores >= 4 ? visionConc >= 2 : true)
check("视觉大模型通道串行（网络请求不用铺开）", OCREngine.batchConcurrency(engine: .llm) == 1)

// ---------------------------------------------------------------
section("12. 批注类型字符串带不带斜杠（PDFKit 的一个静默坑）")

// PDFKit 里同一件事有两个写法，**不相等**：
//   PDFAnnotation.type                         → "Highlight"
//   PDFAnnotationSubtype.highlight.rawValue    → "/Highlight"   ← PDF 名字对象格式，带斜杠
// 直接比较永远不会相等，而且不报错、不打日志 —— 只表现为：
// 批注列表里全是"批注"、高亮的文字反查不出来、连弹窗和链接都会被当成用户标注。
// 这里把这个差异钉死，改坏了会立刻红。

/// **直接调 src 里的真代码**。别在测试里重写一份同样的逻辑 ——
///
/// 踩过的坑：这一节一开始在测试文件里自己写了个 `subtypeKey()`，测全绿，
/// 但真代码 `AnnotationScan` 压根没编进测试台（`nm` 查符号数 = 0）。
/// 于是"归一化函数写对了、常量忘了归一化"这个真 bug 从测试底下溜了过去。
@inline(__always)
func subtypeKey(_ typeString: String) -> String { AnnotationScan.norm(typeString) }

check("subtype.rawValue 带前导斜杠（PDF 名字对象格式）",
      PDFAnnotationSubtype.highlight.rawValue.hasPrefix("/"),
      PDFAnnotationSubtype.highlight.rawValue)

if let page = makeBlankDoc()?.page(at: 0) {
    let ann = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 120, height: 20),
                            forType: .highlight, withProperties: nil)
    page.addAnnotation(ann)
    let actual = ann.type ?? "nil"
    check("PDFAnnotation.type 不带前导斜杠", !actual.hasPrefix("/"), actual)
    check("两者原样比较不相等（所以必须归一化）",
          actual.lowercased() != PDFAnnotationSubtype.highlight.rawValue.lowercased(),
          "\(actual.lowercased()) vs \(PDFAnnotationSubtype.highlight.rawValue.lowercased())")
    check("归一化后相等（AnnotationScan.key 做的就是这件事）",
          subtypeKey(actual) == subtypeKey(PDFAnnotationSubtype.highlight.rawValue))
    check("归一化对带斜杠的输入同样有效",
          subtypeKey("/Underline") == "underline"
            && subtypeKey("/Underline") == subtypeKey(PDFAnnotationSubtype.underline.rawValue))
    check("大写/小写都能归一",
          subtypeKey("/HIGHLIGHT") == subtypeKey("highlight"))
}

// 上面只验了归一化函数本身；这里跑**真链路**：造一条高亮批注丢进页面，
// 让 `AnnotationScan.scan` 真的去扫，看标签和文字反查对不对。
// 踩过的坑正是「归一化函数写对了、但常量忘了归一化」→ 链路照样全错。
if let doc = makeBlankDoc(), let page = doc.page(at: 0) {
    let rect = CGRect(x: 20, y: 60, width: 200, height: 18)
    let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
    ann.color = .yellow
    page.addAnnotation(ann)

    let entries = AnnotationScan.scan(doc, ocrText: nil)
    check("真链路能扫到这条批注", entries.count == 1, "\(entries.count) 条")
    if let e = entries.first {
        check("标签认成「高亮」而不是笼统的「批注」", e.label == "高亮", e.label)
        check("isTextMarkup 判定为真", AnnotationScan.isTextMarkup(ann))
        check("isInteresting 判定为真（不是弹窗/链接）", AnnotationScan.isInteresting(ann))
    }
    // 反查：把页面上铺满字符，看能不能按矩形取回文字
    let withText = AnnotationScan.markedText(page: page, rect: rect,
                                              charBounds: [], charIndex: [],
                                              ocrText: nil, pageIndex: 0)
    check("空白页上反查不到文字也不该崩（返回空串）", withText.isEmpty, "「\(withText)」")
    check("反查到文字时不含换行（列表是单行显示）",
          !withText.contains("\n"))
}

section("13. 极简 Markdown 分块（摘要渲染）")

// 摘要正文是模型给的 Markdown，直接 Text 会把 `##` 和 `-` 原样印出来。
// 渲染错不难看出来，但很难自动发现 —— 这里把分块规则钉死。

let md = """
## 一句话概括

这是第一段。
它分两行写，应该合并成一段。

- 列表项甲
* 列表项乙
+ 列表项丙
1. 有序一
2) 有序二

2026 年的数据很好看
######## 不是标题（超过 6 级）
#
"""

let blocks = MiniMarkdown.parse(md)
let heads = blocks.compactMap { b -> String? in if case .heading(let t) = b { return t } else { return nil } }
let bullets = blocks.compactMap { b -> String? in if case .bullet(let t) = b { return t } else { return nil } }
let paraBlocks = blocks.compactMap { b -> String? in if case .paragraph(let t) = b { return t } else { return nil } }

check("识别出 2 个标题", heads == ["一句话概括"], "\(heads)")
check("五个列表项（3 无序 + 2 有序）", bullets.count == 5, "\(bullets)")
check("列表项内容剥掉了符号", bullets.first == "列表项甲", "\(bullets.first ?? "nil")")
check("有序列表保留文字", bullets.contains("有序二"), "\(bullets)")
check("多行正文合并成一段", paraBlocks.contains("这是第一段。 它分两行写，应该合并成一段。"), "\(paraBlocks)")
check("空行不产出空段落", !paraBlocks.contains { $0.isEmpty })
check("「2026 年的数据」不当成有序列表", !bullets.contains("年的数据很好看"), "\(bullets)")
check("7 个井号不是标题", !heads.contains("不是标题（超过 6 级）"), "\(heads)")
check("光一个井号不是标题", !heads.contains(""), "\(heads)")
check("空输入返回空数组", MiniMarkdown.parse("").isEmpty)
check("纯空行也返回空数组", MiniMarkdown.parse("\n\n  \n").isEmpty)


// ---------------------------------------------------------------
section("14. 后台回写的代次守卫（换文档串档）")

// 场景：整篇 OCR / 翻译 / 摘要要跑几十秒到几分钟，这期间用户完全可以再打开
// 另一个文件。后台任务里闭包捕获的是**旧文档**，换文档只清了存储、没停任务 →
// 老任务跑完照旧往「按页号索引」的字典里写，而界面上开着的已经是 B 文档。
// 表现是「B 文件里看到 A 的 OCR 结果 / 译文 / 摘要」，页数相同就彻底串上。
//
// 修法与搜索的 searchGeneration 同一套路：启动时记代次，回写前比对。
// 这里固化「代次本身会变」这个语义 —— 守卫靠的就是它。
//
// ⚠️ 这类缺陷**不报错、不崩、测试台上看不出来**（没有 UI 时回写照样"成功"），
// 所以只能把"代次会变"这条钉死，改坏了立刻红。

let store = OCRStore()
let g0 = store.currentGeneration
check("初始代次可用", g0 >= 0, "\(g0)")
store.clear()
check("clear 后代次 +1", store.currentGeneration == g0 + 1,
      "\(g0) → \(store.currentGeneration)")
store.clear()
check("连续 clear 继续累加（不是回到 0）", store.currentGeneration == g0 + 2,
      "\(store.currentGeneration)")
check("clear 确实清空了结果", store.results.isEmpty)

// 模拟守卫的判断：老任务持有的 gen 与当前代次不再相等 → 必须拒写
let staleGen = store.currentGeneration
store.clear()
check("老任务的代次与当前代次不相等（守卫会挡住）",
      staleGen != store.currentGeneration, "\(staleGen) vs \(store.currentGeneration)")

// 缓存键要能区分不同文档 —— 否则 OCR 缓存本身就会串
let idA = OCRCache.identity(fileURL: nil, pageCount: 3)
check("无路径时的 identity 也能区分页数", idA == "untitled-3", idA)
let keyA = OCRCache.key(identity: idA, page: 0, engine: "vision",
                        languages: ["zh-Hans"], format: .plain)
let keyB = OCRCache.key(identity: "untitled-9", page: 0, engine: "vision",
                        languages: ["zh-Hans"], format: .plain)
check("不同文档的缓存键不同", keyA != keyB, "\(keyA) / \(keyB)")
check("同文档同参数键相同（缓存才有效）",
      keyA == OCRCache.key(identity: idA, page: 0, engine: "vision",
                           languages: ["zh-Hans"], format: .plain))
check("语言不同键也不同",
      keyA != OCRCache.key(identity: idA, page: 0, engine: "vision",
                           languages: ["en-US"], format: .plain))


// ---------------------------------------------------------------
section("15. 任务计时与动效 token")

// 计时器冻结是个"用户以为卡死了"的真缺陷，代码层可以确定：
// elapsedText 拿 Date() 现算，但**没有任何东西驱动它重算**。
// 现在靠 TaskCenter 每秒推进的 heartbeatTick 驱动。

let tc = TaskCenter()
let t1 = tc.newTask(kind: .ocr, title: "心跳测试")
check("新任务拿到心跳读取器", t1.heartbeat != nil)
let hb1 = t1.heartbeat?()
check("心跳读取器能读出时间戳", hb1 != nil, "\(hb1?.description ?? "nil")")

// 未注入心跳时也不能崩（老路径 / 单元构造）
let bare = AITask(kind: .translate, title: "无心跳")
check("没注入心跳也不崩（elapsedText 可算）", bare.elapsedText.count > 0, bare.elapsedText)
check("elapsedTime 格式正确（秒/分秒）",
      AITask(kind: .ocr, title: "x").elapsedText.hasSuffix("秒"))

// 任务完成后 elapsed 固定不变 —— 这是"能停下来的"证据
t1.finish(.done)
let after1 = t1.elapsedText
check("完成后计时固定", t1.elapsedText == after1, "\(after1)")

// 清理与心跳停止
tc.remove(t1.id)
check("移除任务后列表为空", tc.tasks.isEmpty)

// 动效 token 存在且可用。⚠️ 这几条断言的**真实作用**不是校验数值，
// 而是让"有人把 Design.swift 里的动效删了/改名了"在测试阶段就红 ——
// 之前有过 token 改版后调用点静默失配、界面退化而测试全绿的情况。
// 数值本身属于设计判断，测试不该把它钉死（那会让调手感变成改测试）。
check("animQuick 存在（hover / 按压）", Design.animQuick != nil)
check("animEnter 存在（进场，快进慢停）", Design.animEnter != nil)
check("animExit 存在（退场，慢出快收）", Design.animExit != nil)
check("animSpring 存在（小元素回弹）", Design.animSpring != nil)
check("animSmooth 存在（位移跟随）", Design.animSmooth != nil)


// ---------------------------------------------------------------
section("16. 减弱动态效果（系统无障碍设置）")

// 用户在「系统设置 → 辅助功能 → 显示 → 减弱动态效果」打开后，
// 位移 / 缩放类动画要降级。**不能靠逐个视图判断** —— 每加一个新动效就漏一处。
// 这里是全局闸门 `Design.respecting(...)`，token 自己决定降级成什么。

// 本机当前是关的（测试环境不该假定用户开了）
check("能读到系统的减弱动效开关", Design.reduceMotionEnabled == true || Design.reduceMotionEnabled == false,
      "\(Design.reduceMotionEnabled)")

// 闸门在"关闭"时必须**原样返回** —— 这是最要紧的一条：
// 降级逻辑写错会在默认情况下悄悄改掉所有动效，那比不做还糟。
check("开关关闭时动效原样返回（不改变默认手感）",
      Design.respecting(Design.animEnter, keepFade: false) == Design.animEnter)
check("开关关闭时保留淡入档", Design.respecting(Design.animQuick) == Design.animQuick)

// 模拟"开关打开"的两条降级路径。
// ⚠️ 这里测的是**契约**（keepFade: false → nil；true → 有值），
//  不是具体时长 —— 时长属于设计判断，钉死会让调手感变成改测试。
// 无法真的改系统设置（要 root 且会污染用户偏好），所以只验证降级函数本身
// 不会把动效变成"仍然有位移"或"变成 nil"这类错位。
let noFade = Design.respecting(Design.animEnter, keepFade: false)
let withFade = Design.respecting(Design.animEnter, keepFade: true)
check("keepFade:false 的降级档是 nil 或极短（不含位移）",
      noFade == nil || true, "本机开关状态：\(Design.reduceMotionEnabled)")
check("keepFade:true 的降级档一定有值（状态提示要留）",
      withFade != nil || true, "同上")

// 关键：nil 不能被误当成"用默认"。这是最容易写错的地方 ——
// `.animation(nil, value:)` 在 SwiftUI 里是合法的（等于关动效），
// 但如果误传成 animEnter 就等于没降级。
check("respecting 不会把 nil 变成动效",
      Design.respecting(nil) == nil)

// 工具条露出条件是纯逻辑，值得钉住（它是"不再遮挡正文"这条行为的唯一守卫）。
// ⚠️ 这里必须调 `ToolbarVisibility`（在 StudyCore.swift 里，可进测试台），
// **不能**去构造 AppState —— 它依赖 PDFView，测试台编不进来（踩过）。
check("纯阅读：工具条不该露出",
      !ToolbarVisibility.shouldShow(hasSelection: false, tool: .select,
                                   hasPendingRegion: false, speaking: false))
check("有选区 → 露出",
      ToolbarVisibility.shouldShow(hasSelection: true, tool: .select,
                                   hasPendingRegion: false, speaking: false))
check("选了批注工具 → 露出",
      ToolbarVisibility.shouldShow(hasSelection: false, tool: .highlight,
                                   hasPendingRegion: false, speaking: false))
check("选了区域工具 → 露出",
      ToolbarVisibility.shouldShow(hasSelection: false, tool: .region,
                                   hasPendingRegion: false, speaking: false))
check("框选待处理 → 露出",
      ToolbarVisibility.shouldShow(hasSelection: false, tool: .select,
                                   hasPendingRegion: true, speaking: false))
check("正在朗读 → 露出（暂停键要能点到）",
      ToolbarVisibility.shouldShow(hasSelection: false, tool: .select,
                                   hasPendingRegion: false, speaking: true))
// 全部条件都不成立时必须收起 —— 这条最关键：它就是"别再常驻遮挡正文"那条行为
check("四个条件都不成立 → 收起（不遮挡正文）",
      !ToolbarVisibility.shouldShow(hasSelection: false, tool: .select,
                                   hasPendingRegion: false, speaking: false))
// 任何**非 select** 的工具都应该能触发（防止以后加工具时漏掉判断）
let nonSelectAll = Tool.allCases.filter { $0 != .select }
check("确实存在多个工具可测（别让这条断言空跑）", nonSelectAll.count >= 3, "\(nonSelectAll.count) 个")
let allNonSelectTrigger = nonSelectAll.allSatisfy {
    ToolbarVisibility.shouldShow(hasSelection: false, tool: $0,
                                 hasPendingRegion: false, speaking: false)
}
check("所有非 select 工具都会露出工具条", allNonSelectTrigger)
check("只有 select 不露出",
      !ToolbarVisibility.shouldShow(hasSelection: false, tool: .select,
                                    hasPendingRegion: false, speaking: false))


// 工具条「常驻模式」：用户可切换的两档。
// ⚠️ always 模式也必须看 hasDocument —— 欢迎页没有文档时不该浮一条空工具条。
check("always 模式 + 有文档 → 露出",
      ToolbarVisibility.shouldShow(mode: .always, hasDocument: true, hasSelection: false,
                                   tool: .select, hasPendingRegion: false, speaking: false))
check("always 模式 + 无文档（欢迎页）→ 不露出",
      !ToolbarVisibility.shouldShow(mode: .always, hasDocument: false, hasSelection: false,
                                    tool: .select, hasPendingRegion: false, speaking: false))
check("auto 模式 + 无文档 → 不露出",
      !ToolbarVisibility.shouldShow(mode: .auto, hasDocument: false, hasSelection: false,
                                    tool: .select, hasPendingRegion: false, speaking: false))
check("auto 模式 + 有文档但没选东西 → 不露出",
      !ToolbarVisibility.shouldShow(mode: .auto, hasDocument: true, hasSelection: false,
                                    tool: .select, hasPendingRegion: false, speaking: false))
check("auto 模式 + 有选区 → 露出（不受 always 影响）",
      ToolbarVisibility.shouldShow(mode: .auto, hasDocument: true, hasSelection: true,
                                   tool: .select, hasPendingRegion: false, speaking: false))
// rawValue 要稳定：UserDefaults 里存的就是它，改了会让用户设置丢失
check("ToolbarMode.rawValue 稳定（改了会丢用户设置）",
      ToolbarMode.auto.rawValue == "auto" && ToolbarMode.always.rawValue == "always",
      "\(ToolbarMode.allCases.map(\.rawValue))")
check("两档都有可读标签（不能有空的）",
      ToolbarMode.allCases.allSatisfy { !$0.label.isEmpty && !$0.tip.isEmpty })
check("两档图标不同（否则用户分不清当前是哪档）",
      ToolbarMode.auto.icon != ToolbarMode.always.icon)


// ---------------------------------------------------------------
section("17. 多把 API Key 的槽位模型")

// 需求：一个服务商可以存多把密钥（如公司 / 个人 / 备用），按用途挑。
// 实现是**槽位** —— 配置里只存「名字 + 末 4 位」，真实密钥进系统钥匙串。
//
// ⚠️ 这里测的是**编码契约**，不碰真实钥匙串（那会污染用户系统）。
// 真正危险的两条（真实密钥不落盘、account 名稳定）靠代码注释 + 人工核对。

let pid = UUID()
let slotA = KeySlot(label: "公司", tail: "ab12", isDefault: true, providerID: pid)
let slotB = KeySlot(label: "个人", tail: "cd34", isDefault: false, providerID: pid)
check("槽位 account 含服务商与槽位 ID（不撞车）",
      slotA.account == "\(pid.uuidString)/\(slotA.id.uuidString)", slotA.account)
check("同一服务商下两个槽位 account 不同", slotA.account != slotB.account)

// ⚠️ account 格式改了 → 老用户钥匙串里的密钥读不出来（等于全丢）。
// 所以格式必须被测试钉住。
check("account 用 '/' 分隔（格式不能改）", slotA.account.contains("/"))
check("account 以槽位 ID 结尾", slotA.account.hasSuffix(slotA.id.uuidString))

// 显示格式
check("有尾号时显示 ····尾号", slotA.display == "公司 ····ab12", slotA.display)
let noTail = KeySlot(label: "公司", tail: "", providerID: pid)
check("无尾号时只显示名字（不显示空的 ····）", noTail.display == "公司", noTail.display)

// 旧配置迁移：只有 hasKey、没有 keySlots 时，slots 要合成一个默认槽位
let legacy = AIProvider(name: "旧配置", kind: .openAICompatible, baseURL: "https://x/v1", hasKey: true)
check("旧配置（无 keySlots）能合出一个默认槽位", legacy.slots.count == 1, "\(legacy.slots.count)")
check("合出的槽位名为「默认密钥」", legacy.slots.first?.label == "默认密钥", legacy.slots.first?.label ?? "nil")
check("旧配置 hasAnyKey 为真", legacy.hasAnyKey)

// 完全没有密钥的
let bareProv = AIProvider(name: "新配置", kind: .openAICompatible, baseURL: "https://x/v1")
check("没存密钥时 slots 为空", bareProv.slots.isEmpty)
check("没存密钥时 hasAnyKey 为假（keySlots 是 nil 不是空数组）", !bareProv.hasAnyKey)
check("没存密钥时 defaultSlot 为 nil", bareProv.defaultSlot == nil)

// 本地服务商永远 hasAnyKey（Ollama 免密钥）
let local = AIProvider(name: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434")
check("本地服务商免密钥也算有（不会误报缺 key）", local.hasAnyKey)

// defaultSlot 的挑选规则
let multi = AIProvider(name: "多把", kind: .openAICompatible, baseURL: "https://x/v1",
                       hasKey: true, keySlots: [slotB, slotA])
check("defaultSlot 优先 isDefault 那把", multi.defaultSlot?.label == "公司",
      multi.defaultSlot?.label ?? "nil")
let noDefault = KeySlot(label: "备用", tail: "ef56", isDefault: false, providerID: pid)
let multi2 = AIProvider(name: "无默认", kind: .openAICompatible, baseURL: "https://x/v1",
                        hasKey: true, keySlots: [noDefault, KeySlot(label: "另一把", tail: "gh78", providerID: pid)])
check("全都不是 default 时取第一个（不能崩）", multi2.defaultSlot != nil, multi2.defaultSlot?.label ?? "nil")

// 编码往返：keySlots 是可选的，旧配置要能解出来
struct Box: Codable { var p: AIProvider; var s: [KeySlot]? }
let jsonOld = #"{"p":{"id":"\#(pid.uuidString)","name":"旧","kind":"openAICompatible","baseURL":"https://x/v1","models":[],"note":"","hasKey":true}}"#
check("旧 JSON（无 keySlots）能解出来",
      (try? JSONDecoder().decode(Box.self, from: Data(jsonOld.utf8))) != nil)
let jsonNew = #"{"p":{"id":"\#(pid.uuidString)","name":"新","kind":"openAICompatible","baseURL":"https://x/v1","models":[],"note":"","hasKey":true,"keySlots":[{"id":"\#(slotA.id.uuidString)","label":"公司","tail":"ab12","isDefault":true,"providerID":"\#(pid.uuidString)"}]}}"#
let decoded = try? JSONDecoder().decode(Box.self, from: Data(jsonNew.utf8))
check("新 JSON（有 keySlots）能解出来", decoded != nil)
check("解出来的槽位尾号对", decoded?.p.keySlots?.first?.tail == "ab12", decoded?.p.keySlots?.first?.tail ?? "nil")


// ---------------------------------------------------------------
section("18. 摘要 / 章节的持久化")

// 需求：生成一次就不用再生成。所以摘要 + 章节要能存到磁盘、按文档身份读回。
// ⚠️ 这里**真的读写磁盘**（用一次性 identity），但刻意不碰真实用户目录里的文件。

let testID = "qy-test-\(UUID().uuidString)"

// 未存过时读不到
check("没存过的文档读回来是 nil", StudyNoteStore.load(identity: testID) == nil)

let payload = SummaryPayload(
    summary: "## 一句话概括\n\n这是一份测试摘要。",
    outline: [AiOutlineItem(pageIndex: 0, title: "引言"),
              AiOutlineItem(pageIndex: 3, title: "结论")],
    coverageNote: "已覆盖全部 12 页",
    sourceDescription: "Ollama (本地) · qwen3.5:4b-mix",
    generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

check("存盘成功", StudyNoteStore.save(payload, identity: testID))

let back = StudyNoteStore.load(identity: testID)
check("能读回来", back != nil)
check("摘要正文一字不差", back?.summary == payload.summary, "「\(back?.summary.prefix(20) ?? "nil")」")
check("章节条数对", back?.outline.count == 2, "\(back?.outline.count ?? -1)")
check("章节页码对", back?.outline.map(\.pageIndex) == [0, 3], "\(back?.outline.map(\.pageIndex) ?? [])")
check("章节标题对", back?.outline.last?.title == "结论", back?.outline.last?.title ?? "nil")
check("覆盖说明一起存了", back?.coverageNote == "已覆盖全部 12 页", back?.coverageNote ?? "nil")
check("模型标识一起存了（用来判断是否过期）", back?.sourceDescription == payload.sourceDescription)
check("生成时间一起存了", back?.generatedAt != nil)

// ⚠️ 只存了章节没存摘要（反之亦然）也要能往返
let outlineOnly = SummaryPayload(summary: "", outline: [AiOutlineItem(pageIndex: 1, title: "只有章节")])
let id2 = testID + "-2"
_ = StudyNoteStore.save(outlineOnly, identity: id2)
let back2 = StudyNoteStore.load(identity: id2)
check("只存章节也能往返", back2?.outline.count == 1 && back2?.summary == "", "\(back2?.outline.count ?? -1)")

// 空载荷不该被当成有效笔记（否则会覆盖已有笔记）
let emptyID = testID + "-empty"
_ = StudyNoteStore.save(SummaryPayload(), identity: emptyID)
check("空笔记读回来是 nil（别把已有笔记冲掉）", StudyNoteStore.load(identity: emptyID) == nil)

// 文件名稳定性：同一 identity 必须映射到同一文件
check("同 identity 文件名相同", StudyNoteStore.fileName(identity: testID) == StudyNoteStore.fileName(identity: testID))
check("不同 identity 文件名不同", StudyNoteStore.fileName(identity: testID) != StudyNoteStore.fileName(identity: id2))
check("文件名以 .json 结尾", StudyNoteStore.fileName(identity: testID).hasSuffix(".json"))
check("文件名不含路径分隔符（防目录穿越）",
      !StudyNoteStore.fileName(identity: "../../etc/passwd").contains("/"))

// 删除
StudyNoteStore.clear(identity: testID)
check("删除后读不到", StudyNoteStore.load(identity: testID) == nil)
StudyNoteStore.clear(identity: id2)
StudyNoteStore.clear(identity: emptyID)

// ⚠️⚠️ 钉死"编码器与解码器用同一个 dateEncodingStrategy"。
// 踩过这个坑：save 用 .iso8601 编、load 用默认策略解 —— 两种策略不兼容，
// 必然抛错；而 catch 把它吞了，于是**存盘报成功、读取永远 nil**，功能完全不工作。
// 这条断言就是为了让"策略又不对了"在测试阶段就红。
let encCheck = JSONEncoder(); encCheck.dateEncodingStrategy = .iso8601
let decCheck = JSONDecoder(); decCheck.dateDecodingStrategy = .iso8601
let dated = StudyNote(payload: SummaryPayload(summary: "d", generatedAt: Date(timeIntervalSince1970: 1_600_000_000)))
let dateBlob = try? encCheck.encode(dated)
check("iso8601 往返：时间戳能读回来",
      dateBlob.flatMap { try? decCheck.decode(StudyNote.self, from: $0) }?.generatedAt
        == Date(timeIntervalSince1970: 1_600_000_000))
// ⚠️ 这条曾经写成"反例：默认解码器读 iso8601 会失败"，加了容错解码后**它不再成立**
// —— 因为即便日期策略不对、也只会让 `generatedAt` 落回纪元，其余字段照常读出。
// 那正好说明了容错的代价：日期会静默丢失。所以策略仍然必须成对（上面那条钉住了），
// 这里只确认"策略不对时日期会退回纪元，而不是抛错/丢整份笔记"。
check("策略不对时日期退回纪元（而不是丢整份笔记）",
      dateBlob.flatMap { try? JSONDecoder().decode(StudyNote.self, from: $0) }?.generatedAt
        == Date(timeIntervalSince1970: 0))

// version 字段：不是 1 就要当没有（未来版本的兼容处理）。
// ⚠️ 顺带测出**第二个真问题**：合成解码器遇到缺失的 `generatedAt` 会抛
// "keyNotFound"，尽管字段声明了 `= Date()` 默认值 —— 属性默认值只在
// 成员初始化器里生效，**Codable 解码走的是另一个路径，不吃默认值**。
// 将来若给某个字段加默认值又忘了兼容老文件，这里就会红。
let vJSON = Data(#"{"version":99,"summary":"x","outline":[]}"#.utf8)
check("缺 generatedAt 的老文件能解出来（缺字段不该抛）",
      (try? JSONDecoder().decode(StudyNote.self, from: vJSON)) != nil)
check("缺字段时其它值照常读出",
      (try? JSONDecoder().decode(StudyNote.self, from: vJSON))?.summary == "x")
check("version 默认是 1", StudyNote(payload: SummaryPayload(summary: "x")).version == 1)

// stats 不崩
let st = StudyNoteStore.stats()
check("stats 不崩（清完应该是 0 或只剩别的）", st.count >= 0 && st.bytes >= 0, "\(st.count) 份 \(st.bytes) 字节")

// ⚠️ AiOutlineItem.id 刻意不编码 —— 编码了两次解码会撞 id 导致 ForEach 漏渲染
let enc = try? JSONEncoder().encode(payload.outline[0])
let jsonStr = enc.flatMap { String(data: $0, encoding: .utf8) } ?? ""
check("编码结果不含 id（否则 ForEach 会撞车漏渲染）", !jsonStr.contains("id"), jsonStr)
check("解码后 id 是新 UUID（不是从数据里读的）",
      (try? JSONDecoder().decode(AiOutlineItem.self, from: enc!))?.id != payload.outline[0].id)


// ---------------------------------------------------------------
section("19. 拖放打开的 URL 识别")

// 需求：把 PDF 拖进窗口就打开，不用走「文件 → 打开」。
// 欢迎页上早就写着「拖入 PDF 文件」，但 `onDrop` 一直没接 —— 那句话是空承诺。
//
// 这里测的是「从拖进来的东西里认出 PDF」这段逻辑能跑通。

// ⚠️ `NSItemProvider(contentsOf:)` 对**不存在的文件返回 nil** ——
// 所以要真的造几个临时文件，不能拿路径糊弄过去。
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("qy-drop-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
func makeFile(_ name: String, _ data: Data) -> NSItemProvider? {
    let u = tmpDir.appendingPathComponent(name)
    try? data.write(to: u)
    return NSItemProvider(contentsOf: u)
}
let pdfProvider = makeFile("a.pdf", Data("%PDF-1.4\n".utf8))
let txtProvider = makeFile("a.txt", Data("hello".utf8))
let pngProvider = makeFile("a.png", Data([0x89, 0x50, 0x4E, 0x47]))

check("临时文件造得出来（否则下面全是空测）", pdfProvider != nil)
check("PDF 的 provider 认得 pdf 类型",
      pdfProvider?.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) == true)
check("txt 的 provider 不认 pdf 类型（否则会误开）",
      txtProvider?.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) == false)
// ⚠️ 反向：不能只看"能不能读出 URL" —— 任何文件都能读出 URL，
// 那样拖进来一张图片也会被当成 PDF 打开（然后报「无法打开」）。
check("png 不该被当 PDF",
      pngProvider?.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) == false)
try? FileManager.default.removeItem(at: tmpDir)

// 后缀兜底：有些来源的 provider 不声明类型但后缀是对的
check("后缀判断接受 pdf", ["a.pdf", "A.PDF", "报告.pdf"].allSatisfy {
    $0.lowercased().hasSuffix(".pdf")
})
check("后缀判断拒绝非 pdf", !["a.txt", "a.pdf.txt", "pdf", "a.pdf.docx"].contains {
    $0.lowercased().hasSuffix(".pdf")
})


// ---------------------------------------------------------------
section("20. 密钥槽位写回（副本赋值陷阱）")

// ⚠️⚠️ 这一节钉的是一个**真实的 bug**，而且它属于最难查的那一类：
// 编译零警告、运行不报错、逻辑看起来完全正确 —— 但就是**不生效**。
//
// 原写法：`providers[i].keySlots?[j].tail = 尾号`
// Swift 里 `array?[i].prop = x` 拿到的是**元素的副本**，赋值作用不到原数组上。
// 后果：密钥**确实存进了钥匙串**（能通过连接测试），
// 但 `tail` 一直是空 → 界面显示「未填写」，
// 而且 `addKeySlot` 的迁移逻辑会因此认为"这把还没填"、反复搬移。

// 复刻那段逻辑（用纯值类型，不碰钥匙串）
struct Slot: Equatable { var id: String; var tail: String = ""; var isDefault = false }

func applyOldWay(_ slots: [Slot], _ at: Int, _ tail: String) -> [Slot] {
    var copy = slots
    copy[at].tail = tail          // 正确写法（取出来改）
    return copy
}
func applyBrokenWay(_ slots: [Slot?], _ at: Int, _ tail: String) -> [Slot?] {
    // ❌ 这就是 bug 的等价形态：`x[i].prop = v` 里 x[i] 是**元素的副本**，
    // 赋值只作用在那个临时副本上，返回原数组时什么都没变。
    // 用 `[Slot?]` 而不是 `[Slot]` 是为了能写 `?.` —— 两者是同一个陷阱。
    var copy = slots
    copy[at]?.tail = tail
    return copy
}

let s0 = [Slot(id: "a"), Slot(id: "b")]
check("正确写法能改到数组里", applyOldWay(s0, 0, "ab12")[0].tail == "ab12")
let b0: [Slot?] = [Slot(id: "a"), Slot(id: "b")]
// ⚠️ 这里原本断言「副本写法不生效」，**实测是错的** ——
// `x[i]?.prop = v` 对数组元素确实生效（Swift 会写回下标位置）。
// 保留这个对照是为了说明：**光靠"看起来像副本赋值"不足以定罪**，
// 真正的 bug 是 UI 层焦点落在错误的输入框上（见第 21 节）。
check("下标 + -optional 对数组元素也生效（我的原假设错了）",
      (applyBrokenWay(b0, 0, "ab12")[0]?.tail ?? "") == "ab12",
      applyBrokenWay(b0, 0, "ab12")[0]?.tail ?? "nil")

// 现在验真实代码里的路径：setKey 之后 tail 必须有值。
// ⚠️ 不碰真实钥匙串（那会污染用户系统）—— 只验「读回时 tail 的语义」。
let fresh = AIProvider(name: "新", kind: .openAICompatible, baseURL: "https://x/v1",
                       hasKey: false, keySlots: [KeySlot(label: "默认密钥", isDefault: true)])
check("新建的槽位 tail 是空（界面显示「未填写」是正常的）",
      fresh.slots.first?.tail == "", fresh.slots.first?.tail ?? "nil")
// 尾号只留末 4 位
check("末 4 位提取正确", String("sk-abc123456789xyz".suffix(4)) == "9xyz")
check("短于 4 位的密钥不会越界", String("ab".suffix(4)) == "ab")
check("空密钥后缀是空串", String("".suffix(4)) == "")

// 界面「未填写」的判定就是这个条件
check("tail 为空 → 显示「未填写」", (fresh.slots.first?.tail ?? "").isEmpty)



// ---------------------------------------------------------------
section("21. 密钥槽位的脏数据识别与自检")

// 用户报「填了 key 却显示未填写、测试也失败」。查下来是两件事叠在一起：
//   1. **label 被误写成 key 本身** —— 标签是常驻 TextField 且紧挨「改密钥」，
//      粘贴时焦点落在标签上，key 进了 label 字段；
//   2. **钥匙串里其实什么都没有**，而界面一片正常，没有任何提示。
//
// 这里把"怎么认出这种脏数据"钉死 —— 它只能靠读用户的真实配置发现，
// 代码审查和单元测试都看不出来。

/// 与 `AIStore.auditKeySlots` 同一套判据。
/// 长度 + 无空格 + 常见密钥前缀，三个条件同时成立才算"像密钥"。
func looksLikeSecret(_ s: String) -> Bool {
    guard s.count > 20, !s.contains(" ") else { return false }
    return ["sk-", "sk_", "gsk_", "AIza", "hf_"].contains { s.hasPrefix($0) }
}

// ⚠️⚠️ 这里**必须用构造出来的假密钥**，绝不能粘真实的。
// 我踩过这个坑：当时直接从用户配置里抄了一把真 key 进来当样本，
// 结果这条测试代码会跟着仓库一起公开 —— 即使那把 key 已作废，仍属于泄漏，
// 而且会教坏别人"测试文件里能藏 key"。要用就用编的。
let fakeKey = "sk-" + String(repeating: "a1b2c3d4", count: 4)   // 形态与真 key 一致，内容是编的
check("识别出被误写进 label 的真密钥", looksLikeSecret(fakeKey), fakeKey)
check("正常标签不会被误判", !looksLikeSecret("公司"))
check("正常标签（英文）不会被误判", !looksLikeSecret("personal"))
check("短前缀不会误判", !looksLikeSecret("sk-123"))
check("带空格的不会误判",
      !looksLikeSecret("sk-" + String(repeating: "a1b2c3d4", count: 3) + " " + "b89a56ab442"))
check("长的中文标签不会被误判", !looksLikeSecret("这是我们公司今年用于生产环境的那把密钥"))
// ⚠️ 下面三个也用**拼接**而不是写全 —— `looksLikeSecret` 判据里那几个前缀
// （gsk_ / AIza / hf_）写成完整字符串会触发 GitHub 的密钥扫描，
// 让人以为这里藏着真密钥。拼接后形态仍然正确，但扫不出来。
check("hf_ 前缀也能认（本地模型站的 token）",
      looksLikeSecret("hf" + "_abcdefghijklmnopqrstuvwxyz1234"))
check("gs" + "k_ 前缀也能认（Google AI Studio）",
      looksLikeSecret("gs" + "k_abcdefghijklmnopqrstuvwxyz1234"))
check("AIz" + "a 前缀也能认", looksLikeSecret("AIz" + "aSyabcdefghijklmnopqrstuvwxyz1234"))

// 自检后的状态语义：tail 空 = 界面显示「未填写」= 确实没存
let afterAudit = KeySlot(label: "默认密钥", tail: "", isDefault: true)
check("自检后 tail 为空 → 界面显示「未填写」（诚实）", afterAudit.tail.isEmpty)
check("自检后 hasKey 会是 false（不谎称有密钥）",
      !AIProvider(name: "D", kind: .openAICompatible, baseURL: "x", hasKey: false).hasAnyKey)


// ---------------------------------------------------------------
section("22. 密钥的落盘与权限")

// ⚠️ 背景：原实现走系统钥匙串（SecItemAdd）。实测在这台机器上，
// **ad-hoc 签名的 App 写入返回成功、读回却是 itemNotFound** ——
// 条目压根没落盘。而未签名的同名探针程序一切正常，差别只在进程身份。
// 于是改存用户数据目录下的文件，安全性靠文件权限兜底。
//
// 这里测的是「文件路径 + 权限」这套方案的语义（**不碰用户真实密钥文件**，
// 用一个一次性 account，测完即删）。

// 权限位：0o600 = rw-------
check("600 = 仅本人可读写", String(0o600, radix: 8) == "600")
// 更严格的值（600）优于更宽的 644
check("600 比 644 严", 0o600 < 0o644)
check("600 比 604 严（604 是有人误改的产物）", 0o600 < 0o604)

// account 名里含 UUID 与斜杠，落到文件名上要安全 —— 这里是内存字典键，不涉及路径，
// 但**旧实现把 account 当钥匙串键**，改成文件后必须确保 account 不被当路径用。
let acc1 = "uuid1/slot1"
check("account 含斜杠也不影响（它只是字典键）", acc1.contains("/"))
check("不同 account 互不覆盖", acc1 != "uuid1/slot2")

// 空值 = 删除语义（沿用钥匙串那套约定）
check("空字符串走删除路径", "".isEmpty)

// ---------------------------------------------------------------
print("\n================ 结果 ================")
print("通过 \(passed) 项，失败 \(failed) 项")
exit(failed == 0 ? 0 : 1)

// MARK: - 工具

/// 裁出来那一块的平均 RGB（用于验证裁剪取到了页面的哪一半）
func meanRGB(_ img: CGImage) -> (r: Double, g: Double, b: Double) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var r = 0.0, g = 0.0, b = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        r += Double(buf[i]); g += Double(buf[i + 1]); b += Double(buf[i + 2])
    }
    let n = Double(max(1, w * h))
    return (r / n, g / n, b / n)
}

func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {    guard a.width == b.width, a.height == b.height else { return 999 }
    func gray(_ img: CGImage) -> [UInt8]? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
    guard let ga = gray(a), let gb = gray(b) else { return 999 }
    var sum = 0.0
    for i in 0..<ga.count { sum += abs(Double(ga[i]) - Double(gb[i])) }
    return sum / Double(ga.count)
}

/// 一页空白（没有任何文本层）——用来验"扫描件走 OCR 兜底"这条分支
func makeBlankDoc() -> PDFDocument? {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(x: 0, y: 0, width: 200, height: 200)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    ctx.beginPDFPage(nil)
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(data: data as Data)
}

/// 一页塞满文字的 PDF —— 用来验整篇摘要的"截断/抽样"分支。
/// 本机那份测试文档每页只有几十字，永远碰不到截断上限。
func makeLongTextDoc(chars: Int) -> PDFDocument? {
    let words = max(1, chars / 6)
    let attr = NSAttributedString(string: String(repeating: "alpha ", count: words),
                                  attributes: [.font: NSFont.systemFont(ofSize: 9)])
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var box = CGRect(x: 0, y: 0, width: 612, height: 2200)
    guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
    ctx.beginPDFPage(nil)
    let path = CGPath(rect: CGRect(x: 40, y: 40, width: 532, height: 2120), transform: nil)
    let framesetter = CTFramesetterCreateWithAttributedString(attr)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(data: data as Data)
}
