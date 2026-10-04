// 轻阅 · OCR：本地 Vision 与视觉大模型两条通道，支持单页 / 整篇 / 框选区域
// 附带「带隐形文本层的可搜索 PDF」导出与结果缓存

import Foundation
import PDFKit
import Vision
import CoreText
import CryptoKit
import AppKit

// MARK: - 数据结构

struct OCRLine: Codable, Hashable {
    var text: String
    var x: Double       // 归一化，原点左下
    var y: Double
    var w: Double
    var h: Double
    var confidence: Double

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    init(text: String, rect: CGRect, confidence: Double) {
        self.text = text; self.x = rect.minX; self.y = rect.minY
        self.w = rect.width; self.h = rect.height; self.confidence = confidence
    }
}

struct OCRPageResult: Codable, Identifiable {
    var pageIndex: Int
    var text: String
    var lines: [OCRLine]
    var engine: String
    var seconds: Double
    var note: String?
    var id: Int { pageIndex }
}

// MARK: - 引擎

enum OCREngine {

    // ---------- 页面 → 位图（y 轴向上，1 单位 = 1 点）----------

    static func renderPageImage(_ page: PDFPage, scale: CGFloat, box: PDFDisplayBox = .cropBox) -> CGImage? {
        let bounds = page.bounds(for: box)
        let w = Int((bounds.width * scale).rounded()), h = Int((bounds.height * scale).rounded())
        guard w > 2, h > 2 else { return nil }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: box, to: ctx)
        return ctx.makeImage()
    }

    /// 按归一化矩形（**原点左下**，与 Vision 的 boundingBox、页面坐标一致）裁剪
    ///
    /// ⚠️ 坐标要翻一次：`CGImage.cropping(to:)` 的 rect 原点在**左上角**，
    /// 而这里传进来的归一化 y 是从底部量的。不翻的话裁出来的是**上下镜像**的区域——
    /// 框选页面上半部分的英文，实际识别到的是下半部分的字（实测过）。
    static func crop(_ image: CGImage, normalized rect: CGRect) -> CGImage? {
        let W = CGFloat(image.width), H = CGFloat(image.height)
        // 先把越界的归一化矩形夹回 [0,1]，避免 negative y 传给 cropping
        let n = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard n.width > 0.002, n.height > 0.002 else { return nil }
        let r = CGRect(x: n.minX * W,
                       y: (1 - n.minY - n.height) * H,
                       width: n.width * W,
                       height: n.height * H)
        return image.cropping(to: r.integral)
    }

    // ---------- Vision 识别 ----------

    static func visionLines(image: CGImage, languages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        var lines: [OCRLine] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let bbox = obs.boundingBox
            lines.append(OCRLine(text: candidate.string, rect: bbox, confidence: Double(candidate.confidence)))
        }
        // 自上而下、自左而右排序
        lines.sort { a, b in
            if abs(a.y - b.y) > 0.01 { return a.y > b.y }
            return a.x < b.x
        }
        return lines
    }

    static func visionPageResult(_ page: PDFPage, pageIndex: Int, settings: OCRSettings) -> OCRPageResult {
        let started = Date()
        guard let img = renderPageImage(page, scale: CGFloat(settings.renderScale)) else {
            return OCRPageResult(pageIndex: pageIndex, text: "", lines: [], engine: "Vision",
                                 seconds: 0, note: "无法渲染该页")
        }
        do {
            let lines = try visionLines(image: img, languages: settings.languages)
            let text = join(lines, format: settings.format)
            let lowConf = lines.filter { $0.confidence < 0.4 }.count
            return OCRPageResult(pageIndex: pageIndex, text: text, lines: lines, engine: "本地 Vision",
                                 seconds: Date().timeIntervalSince(started),
                                 note: lowConf > 0 ? "\(lowConf) 行置信度偏低，建议核对" : nil)
        } catch {
            return OCRPageResult(pageIndex: pageIndex, text: "", lines: [], engine: "本地 Vision",
                                 seconds: Date().timeIntervalSince(started),
                                 note: "识别失败：\(error.localizedDescription)")
        }
    }

    static func join(_ lines: [OCRLine], format: OCRFormat) -> String {
        if format == .plain {
            return lines.map(\.text).joined(separator: "\n")
        }
        // 版面模式：用缩进与空行近似还原块结构
        var out: [String] = []
        var lastY: Double?
        for l in lines {
            if let ly = lastY, abs(ly - l.y) > 0.028, !out.isEmpty, out.last != "" { out.append("") }
            out.append(l.text)
            lastY = l.y
        }
        return out.joined(separator: "\n")
    }

    /// 整篇 OCR 的批大小。
    ///
    /// ⚠️ 别写死 4。`withTaskGroup` 里跑的是**同步阻塞**的 Vision 调用，
    /// 它会一直占着 Swift 并发线程池的线程，而池子大小约等于 CPU 核数。
    /// 固定 4 在 10 核的 M4 上没事，到 4 核机器上就把池子占满了，
    /// 别的任务（连界面刷新）会被饿着。
    /// 视觉大模型是网络请求，本来就是异步等 IO，不用并行铺开。
    static func batchConcurrency(engine: OCREngineKind) -> Int {
        guard engine == .vision else { return 1 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(2, min(6, cores / 2))
    }

    // ---------- 视觉大模型 OCR ----------

    static func llmPrompt(format: OCRFormat) -> String {
        var p = """
        你是 OCR 引擎。请把图片中的文字完整、准确地提取出来。
        规则：只输出提取到的内容，不要翻译、不要总结、不要解释、不要加任何前后缀说明。
        保持原始阅读顺序；一行一行输出；被换行截断的句子按原文断行。
        看不清的字用 □ 代替，不要凭猜测补全。
        """
        if format == .markdown {
            p += "\n如果内容包含表格，用 Markdown 表格输出；标题用 # ## 标注层级；列表保留项目符号。"
        }
        return p
    }

    static func llmOCR(image: CGImage, provider: AIProvider, model: String, key: String,
                       format: OCRFormat, maxTokens: Int = 4096) async throws -> String {
        guard let png = pngData(from: image) else { throw AIError.decode("图片编码失败") }
        let messages: [ChatMessage] = [
            .system(llmPrompt(format: format)),
            .user("提取这张图片里的全部文字。", images: [png])
        ]
        let reply = try await AIClient.shared.chat(provider: provider, model: model, key: key,
                                                   messages: messages, temperature: 0, maxTokens: maxTokens)
        return clean(reply.text)
    }

    static func clean(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") { t = t.replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        for prefix in ["以下是", "图片中的文字：", "提取结果：", "OCR 结果：", "文字内容："] where t.hasPrefix(prefix) {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) } else { t = "" }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return t
    }

    static func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    // ---------- 导出：带隐形文本层的可搜索 PDF ----------

    /// 返回写入的页数；失败抛错
    @discardableResult
    static func writeSearchablePDF(doc: PDFDocument, results: [Int: OCRPageResult],
                                   to url: URL, scale: CGFloat = 1.7) throws -> Int {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "qingyue.pdf", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF 写入器"])
        }
        var firstBox = doc.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &firstBox, nil) else {
            throw NSError(domain: "qingyue.pdf", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建 PDF 上下文"])
        }
        var written = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            var mediaBox = CGRect(origin: .zero, size: box.size)
            let info: [CFString: Any] = [kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size) as CFData]
            ctx.beginPDFPage(info as CFDictionary)

            if let img = renderPageImage(page, scale: scale, box: .mediaBox) {
                ctx.draw(img, in: mediaBox)
            }
            let result = results[i]
            let lines = result?.lines ?? []
            if !lines.isEmpty {
                let W = mediaBox.width, H = mediaBox.height
                ctx.setTextDrawingMode(.invisible)
                for line in lines {
                    let rect = line.rect
                    let fontHeight = max(4, rect.height * H * 0.78)
                    let fontName: CFString = containsCJK(line.text) ? "PingFangSC-Regular" as CFString
                                                                   : "Helvetica" as CFString
                    let font = CTFontCreateWithName(fontName, fontHeight, nil)
                    let attr = NSAttributedString(string: line.text, attributes: [.font: font])
                    let ctLine = CTLineCreateWithAttributedString(attr)
                    ctx.textPosition = CGPoint(x: rect.minX * W, y: rect.minY * H + fontHeight * 0.20)
                    CTLineDraw(ctLine, ctx)
                }
            }
            ctx.endPDFPage()
            written += 1
        }
        ctx.closePDF()
        try (data as Data).write(to: url)
        return written
    }

    static func containsCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x2E80 && $0.value <= 0x9FFF }
    }

    /// 在**后台线程**用一份独立的文档副本写出可搜索 PDF。
    ///
    /// ⚠️ 两个原因必须复制副本：
    /// 1. `PDFDocument` / `PDFPage` 不是线程安全的，而导出期间用户还在翻页 —— 直接拿界面
    ///    正在用的那份进后台，等于两个线程同时读同一份对象。用 `Data` 复制出一个独立实例，
    ///    两个文档互不干扰。
    /// 2. 这个函数是 `nonisolated async`，从 `@MainActor` 的视图里 await 它会自动切到
    ///    全局执行器；之前把 `writeSearchablePDF` 直接放在 `Task {}` 里，那个 Task 继承
    ///    了 MainActor，整篇页面光栅化都压在主线程上，导出时界面会卡死。
    static func writeSearchablePDFIsolated(snapshot: Data?, results: [Int: OCRPageResult],
                                           to url: URL, scale: CGFloat = 1.7) async throws -> Int {
        guard let snapshot, let copy = PDFDocument(data: snapshot) else {
            throw NSError(domain: "qingyue.pdf", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法为导出创建文档副本"])
        }
        return try writeSearchablePDF(doc: copy, results: results, to: url, scale: scale)
    }
}

// MARK: - 缓存

enum OCRCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gezi.qingyue/ocr", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func identity(fileURL: URL?, pageCount: Int) -> String {
        guard let fileURL else { return "untitled-\(pageCount)" }
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(fileURL.lastPathComponent)-\(size)-\(Int(mtime))"
    }

    static func key(identity: String, page: Int, engine: String, languages: [String], format: OCRFormat) -> String {
        let raw = "\(identity)|\(page)|\(engine)|\(languages.joined(separator: ","))|\(format.rawValue)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
    }

    static func load(_ key: String) -> OCRPageResult? {
        let url = dir.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(OCRPageResult.self, from: data)
    }

    static func store(_ key: String, result: OCRPageResult) {
        let url = dir.appendingPathComponent("\(key).json")
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: url) }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - OCR 结果仓库 + 任务编排

struct OCRContext {
    let pageCount: Int
    let page: (Int) -> PDFPage?
    let fileURL: URL?
    var identity: String
}

final class OCRStore: ObservableObject {
    @Published var results: [Int: OCRPageResult] = [:]
    @Published var statusNote: String = ""
    @Published var inspectedPage: Int?

    /// 代次：每次换文档 / 手动清空都自增。
    ///
    /// ⚠️ 整篇 OCR 跑起来可能几十秒，这期间用户完全可以再打开另一个文件。
    /// 任务里 `ctx` 是**闭包捕获了旧 `doc`**（`page: (Int) -> PDFPage?`），
    /// 换文档只清了 `results`、**没取消任务** → 老任务跑完照样往 `results[i]` 写，
    /// 而界面上开着的已经是 B 文档了。表现就是「B 文件里看到 A 的 OCR 结果」，
    /// 而且按页号索引，页数相同就彻底串上（跟缩略图那个 `revision` 坑一模一样）。
    ///
    /// 修法与搜索的 `searchGeneration` 同一套路：启动时记下当前代次，
    /// 每轮回写前 `guard gen == self.generation`，代次变了就整段丢弃。
    private var generation = 0
    /// 取当前代次（启动任务时记一份，回写时比对）
    var currentGeneration: Int { generation }

    func clear() { results = [:]; statusNote = ""; generation += 1 }

    var doneCount: Int { results.count }
    var totalChars: Int { results.values.reduce(0) { $0 + $1.text.count } }

    // ---------- 单页 ----------

    func runPage(_ index: Int, ctx: OCRContext, ai: AIStore, tasks: TaskCenter) {
        let task = tasks.newTask(kind: .ocr, title: "OCR 第 \(index + 1) 页")
        tasks.expanded = true
        let gen = generation
        Task {
            do {
                task.set(detail: "渲染页面…", progress: 0.1)
                let result = try await recognizePage(index, ctx: ctx, ai: ai, task: task)
                // 换过文档就丢弃：这份结果是上一个文件的
                guard gen == self.generation else {
                    task.finish(.cancelled)
                    return
                }
                await MainActor.run {
                    self.results[index] = result
                    self.inspectedPage = index
                    self.statusNote = "第 \(index + 1) 页识别完成（\(result.engine)）"
                }
                task.set(detail: "完成", progress: 1, stats: String(format: "耗时 %.2fs · %d 字", result.seconds, result.text.count))
                task.finish(.done)
            } catch {
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    // ---------- 整篇 ----------

    func runDocument(ctx: OCRContext, ai: AIStore, tasks: TaskCenter) {
        let total = ctx.pageCount
        guard total > 0 else { return }
        let task = tasks.newTask(kind: .ocr, title: "OCR 整篇（\(total) 页）")
        tasks.expanded = true
        let started = Date()
        let engineLabel = ai.ocr.engine == .vision ? "本地 Vision" : "视觉模型 \(ai.ocrModel)"
        let gen = generation

        Task {
            var completed = 0
            var failedPages: [Int] = []
            let concurrency = OCREngine.batchConcurrency(engine: ai.ocr.engine)
            task.log("并发 \(concurrency)（按本机 \(ProcessInfo.processInfo.activeProcessorCount) 核计算）", level: .info)
            for batchStart in stride(from: 0, to: total, by: concurrency) {
                if task.isCancelled { break }
                // ⚠️ 换过文档就整段停掉，别把上一个文件的结果写进当前文档。
                // 每批都查一次：用户可能跑到一半才切文件，不必等这一批跑完。
                if gen != self.generation {
                    task.log("文档已切换，本次整篇 OCR 的结果不再写回", level: .warn)
                    task.finish(.cancelled)
                    return
                }
                let batch = Array(batchStart..<min(batchStart + concurrency, total))
                let results: [(Int, Result<OCRPageResult, Error>)] = await withTaskGroup(of: (Int, Result<OCRPageResult, Error>).self) { group in
                    for i in batch {
                        group.addTask {
                            do {
                                let r = try await self.recognizePage(i, ctx: ctx, ai: ai, task: task)
                                return (i, .success(r))
                            } catch {
                                return (i, .failure(error))
                            }
                        }
                    }
                    var collected: [(Int, Result<OCRPageResult, Error>)] = []
                    for await item in group { collected.append(item) }
                    return collected
                }
                for (i, res) in results.sorted(by: { $0.0 < $1.0 }) {
                    switch res {
                    case .success(let r):
                        completed += 1
                        await MainActor.run {
                            guard gen == self.generation else { return }
                            self.results[i] = r
                        }
                        task.log("第 \(i + 1) 页完成 · \(r.text.count) 字 · \(String(format: "%.2fs", r.seconds))\(r.note.map { " · \($0)" } ?? "")",
                                 level: r.note == nil ? .info : .warn)
                    case .failure(let e):
                        completed += 1
                        failedPages.append(i)
                        task.log("第 \(i + 1) 页失败：\(e.localizedDescription)", level: .error)
                    }
                    let p = Double(completed) / Double(total)
                    let elapsed = Date().timeIntervalSince(started)
                    let eta = p > 0.02 ? elapsed / p - elapsed : nil
                    task.set(detail: "已完成 \(completed)/\(total) 页 · 引擎 \(engineLabel)",
                             progress: p,
                             stats: String(format: "已用 %@", timeText(elapsed))
                                + (eta.map { String(format: " · 预计还需 %@", timeText($0)) } ?? "")
                                + (failedPages.isEmpty ? "" : " · 失败 \(failedPages.count) 页"))
                }
            }
            let totalChars = await MainActor.run { self.totalChars }
            // 先固化成 let 再交给 MainActor，避免在并发闭包里捕获可变变量
            let failed = failedPages
            if task.isCancelled {
                task.finish(.cancelled)
            } else if failed.isEmpty {
                task.finish(.done)
                task.log("全部 \(total) 页识别完成，共 \(totalChars) 字", level: .success)
            } else {
                task.finish(.failed, error: "\(failed.count) 页失败：第 \(failed.map { String($0 + 1) }.joined(separator: "、")) 页")
            }
            await MainActor.run {
                self.statusNote = failed.isEmpty ? "整篇识别完成，共 \(totalChars) 字"
                                                 : "\(total - failed.count)/\(total) 页完成"
            }
        }
    }

    // ---------- 共用：识别一页（含缓存与两条通道）----------

    func recognizePage(_ index: Int, ctx: OCRContext, ai: AIStore, task: AITask) async throws -> OCRPageResult {
        let engineKey = ai.ocr.engine == .vision ? "vision" : "llm:\(ai.ocrModel)"
        let key = OCRCache.key(identity: ctx.identity, page: index, engine: engineKey,
                               languages: ai.ocr.languages, format: ai.ocr.format)
        if let cached = OCRCache.load(key) {
            task.log("第 \(index + 1) 页命中缓存", level: .info)
            return cached
        }
        guard let page = ctx.page(index) else {
            throw NSError(domain: "qingyue.ocr", code: 1, userInfo: [NSLocalizedDescriptionKey: "取不到第 \(index + 1) 页"])
        }
        var result: OCRPageResult
        switch ai.ocr.engine {
        case .vision:
            let started = Date()
            guard let img = OCREngine.renderPageImage(page, scale: CGFloat(ai.ocr.renderScale)) else {
                throw NSError(domain: "qingyue.ocr", code: 2, userInfo: [NSLocalizedDescriptionKey: "页面渲染失败"])
            }
            let lines = try OCREngine.visionLines(image: img, languages: ai.ocr.languages)
            let lowConf = lines.filter { $0.confidence < 0.4 }.count
            result = OCRPageResult(pageIndex: index, text: OCREngine.join(lines, format: ai.ocr.format),
                                   lines: lines, engine: "本地 Vision",
                                   seconds: Date().timeIntervalSince(started),
                                   note: lowConf > 0 ? "\(lowConf) 行置信度偏低" : nil)
        case .llm:
            guard let target = ai.ocrTarget else {
                throw NSError(domain: "qingyue.ocr", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "请先在 AI 中心为 OCR 选择服务商与模型"])
            }
            let started = Date()
            guard let img = OCREngine.renderPageImage(page, scale: CGFloat(ai.ocr.renderScale)) else {
                throw NSError(domain: "qingyue.ocr", code: 2, userInfo: [NSLocalizedDescriptionKey: "页面渲染失败"])
            }
            let text = try await OCREngine.llmOCR(image: img, provider: target.provider,
                                                  model: target.model, key: target.key, format: ai.ocr.format)
            result = OCRPageResult(pageIndex: index, text: text, lines: [], engine: "视觉模型 \(target.model)",
                                   seconds: Date().timeIntervalSince(started),
                                   note: text.contains("□") ? "含无法识别的字符" : nil)
        }
        OCRCache.store(key, result: result)
        return result
    }

    // ---------- 导出 ----------

    func exportText(documentTitle: String) -> String? {
        guard !results.isEmpty else { return nil }
        var out = "# \(documentTitle) · OCR 识别结果\n\n"
        out += "共 \(results.count) 页 · \(totalChars) 字\n\n"
        for idx in results.keys.sorted() {
            out += "\n---\n\n## 第 \(idx + 1) 页\n\n"
            out += (results[idx]?.text ?? "") + "\n"
        }
        return out
    }
}

func timeText(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    if s < 60 { return "\(s) 秒" }
    return "\(s / 60) 分 \(s % 60) 秒"
}
