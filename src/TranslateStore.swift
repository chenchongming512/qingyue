// 轻阅 · 翻译编排：逐页实时产出、并发控制、接缝质检与自动修复、流式选区翻译

import Foundation
import PDFKit
import CryptoKit
import AppKit

// MARK: - 结果模型

struct PageTranslation: Identifiable {
    var pageIndex: Int
    var sourceText: String
    var translatedText: String = ""
    var segments: [(source: String, target: String)] = []
    var state: TaskState = .running
    var qualityNote: String?
    var engine: String = ""
    var seconds: Double = 0
    var id: Int { pageIndex }
}

struct QuickCard: Identifiable {
    /// 卡片是哪种活儿：选区翻译 / 框选翻译 / AI 提问（解释、概括、追问）
    enum Source { case selection, region, ask }
    let id = UUID()
    var kind: Source
    var sourceText: String
    var output: String = ""
    var state: TaskState = .running
    var engine: String = ""
    var note: String?
    /// AI 提问卡片专用的标题（"解释这段" 等）。和 `note` 分开是因为
    /// `note` 在失败时会被写成错误信息，不能拿它当标题用。
    var askLabel: String?
    var region: CGRect?
    var pageIndex: Int?
    var startedAt = Date()
    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
}

struct TranslateContext {
    let pageCount: Int
    let pageText: (Int) -> String
    let page: (Int) -> PDFPage?
    let docTitle: String
    let identity: String
}

// MARK: - 缓存

enum TranslateCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gezi.qingyue/translate", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func key(text: String, signature: String, model: String) -> String {
        let digest = SHA256.hash(data: Data("\(text)|\(signature)|\(model)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description
    }

    static func load(_ key: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("\(key).txt"), encoding: .utf8)
    }

    static func store(_ key: String, value: String) {
        try? value.write(to: dir.appendingPathComponent("\(key).txt"), atomically: true, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - 翻译仓库

final class TranslateStore: ObservableObject {
    @Published var paneVisible = false
    @Published var pages: [Int: PageTranslation] = [:]
    @Published var activePage: Int?          // 当前在看哪一页的译文
    @Published var quickCard: QuickCard?
    @Published var statusNote = ""
    @Published var qualitySummary = ""
    @Published var engineLabel = ""
    @Published var followPage = true

    /// 换文档代次（见 `clear()` 里的说明）。后台回写前一律比对它。
    /// 用 `&+=` 而不是 `+=`：Int 溢出在 release 下会回绕，虽然实际不可能到，
    /// 但后台任务会一直持有这个值，稳妥些。
    private var generation: Int = 0

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// 显隐快译卡。**必须走这个方法**，别直接赋 `quickCard`。
    ///
    /// ⚠️ 踩过的坑：卡片上写了 `.transition(.move(edge: .top).combined(with: .opacity))`，
    /// 但三处赋值点里有两处**没有动画事务**：
    ///   · `publish { self.quickCard = card; self.paneVisible = false }` —— publish
    ///     只负责切主线程，不带 `withAnimation`，于是 transition 退化成硬切；
    ///   · AI 问答失败那条（ReadingExtras）**连 `paneVisible` 都没碰**，必然不播。
    /// 表现是"关闭有动画、打开没动画"，而且行为取决于一个用户看不见的前置状态
    /// （翻译面板当时是开着还是关着）—— 同一个动作两种行为。
    ///
    /// 动画在这里统一加一次，三条路径（选区 / 框选 / 问答失败）就都对了。
    ///
    /// ⚠️ 为什么不写 `withAnimation` / `Transaction`：**本文件不能 import SwiftUI**
    /// —— 测试台要编译它（翻译流水线的接缝质检测试在第 7 节），而那两个都是 SwiftUI 的类型。
    /// 硬加 import 会把整个测试台的编译面拽进 UI 框架，得不偿失。
    ///
    /// 所以这里只管**状态**，动画交给视图层：`ReaderUI` 给 `QuickTranslateCard`
    /// 单独挂一个 `.animation(Design.animEnter, value: translate.quickCard != nil)`。
    /// 显隐天然有值变化，绑上去就够 —— 这比在每个赋值点包 `withAnimation` 更可靠
    /// （漏一处就是硬切，而且症状是"取决于一个用户看不见的前置状态"）。
    func showQuickCard(_ card: QuickCard?) {
        publish { self.quickCard = card }
    }

    func clear() {
        publish {
            self.pages = [:]
            self.qualitySummary = ""
            self.statusNote = ""
        }
        // ⚠️ 代次：换文档 / 手动清空都 +1。
        //
        // 整篇翻译要跑几十秒到几分钟，这期间用户完全可以再打开另一个文件。
        // 翻译任务里 `ctx` 闭包捕获的是**旧文档**，换文档只清了 `pages`、
        // 没停任务 → 老任务跑完照样往 `pages[i]` 写，而界面上开着的已经是 B 文档。
        // 结果按页号索引，页数相同就彻底串上（与 OCR / 缩略图那个坑同一类）。
        //
        // 回写前一律 `guard gen == self.generation`。跟搜索的 `searchGeneration`
        // 、OCR 的 generation 是同一套路，别新增第四种做法。
        generation &+= 1
    }

    var translatedPages: [Int] { pages.keys.sorted() }
    var totalChars: Int { pages.values.reduce(0) { $0 + $1.translatedText.count } }

    // ---------- 选区 / 区域：流式即时翻译 ----------

    func translateSelection(_ text: String, ai: AIStore, tasks: TaskCenter) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let target = ai.translateTarget else {
            showQuickCard(QuickCard(kind: .selection, sourceText: trimmed, output: "",
                                    state: .failed, note: "请先在 AI 中心选择翻译服务商与模型"))
            return
        }
        var card = QuickCard(kind: .selection, sourceText: trimmed, engine: "\(target.provider.name) · \(target.model)")
        card.state = .running
        showQuickCard(card)
        publish { self.paneVisible = false }

        let task = tasks.newTask(kind: .translate, title: "翻译所选文字（\(trimmed.count) 字）")
        tasks.expanded = true
        runSelectionFlow(text: trimmed, ai: ai, task: task)
    }

    /// 「翻译一段文字」的完整流水线：缓存命中 → 流式输出 → 退化判定 → 简化协议重试。
    /// 抽出来是为了让「翻译选中文字」和「框选区域翻译」走同一份实现、共用同一张任务卡。
    func runSelectionFlow(text trimmed: String, ai: AIStore, task: AITask) {
        guard let target = ai.translateTarget else {
            task.finish(.failed, error: "请先在 AI 中心选择翻译服务商与模型")
            return
        }
        let settings = ai.translate
        let signature = ai.translationSignature

        Task {
            let cacheKey = TranslateCache.key(text: trimmed, signature: signature, model: target.model)
            if let cached = TranslateCache.load(cacheKey) {
                task.log("命中缓存，无需重复调用", level: .success)
                publish {
                    if var c = self.quickCard { c.output = cached; c.state = .done; c.note = "来自缓存"; self.quickCard = c }
                }
                task.set(detail: "来自缓存", progress: 1)
                task.finish(.done)
                return
            }
            var received = ""
            let started = Date()
            do {
                let chunk = TranslateChunk(id: "sel", pageIndex: 0, index: 0, text: trimmed,
                                           context: nil, isContinuation: false)
                let messages = [ChatMessage.system(PromptBuilder.systemPrompt(settings)),
                                ChatMessage.user(PromptBuilder.userMessage(chunk))]
                var buffer = ""
                for try await piece in AIClient.shared.chatStream(provider: target.provider, model: target.model,
                                                                 key: target.key, messages: messages,
                                                                 temperature: settings.temperature,
                                                                 maxTokens: min(settings.maxTokensCap, max(1024, trimmed.count * 2 + 256))) {
                    buffer += piece
                    received = buffer
                    let parsed = PromptBuilder.parse(buffer)
                    let chars = parsed.count
                    publish {
                        if var c = self.quickCard { c.output = parsed; self.quickCard = c }
                    }
                    task.set(detail: "正在翻译…（已收到 \(chars) 字）", stats: String(format: "%.1fs", Date().timeIntervalSince(started)))
                }
                var final = PromptBuilder.parse(buffer)
                guard !final.isEmpty else { throw AIError.emptyReply }
                if let why = Degenerate.reason(output: final, source: trimmed, targetLang: settings.targetLang) {
                    task.log("首次输出异常（\(why)），改用简化协议重译", level: .warn)
                    task.set(detail: "简化协议重译中…")
                    let retryChunk = TranslateChunk(id: "sel-r", pageIndex: 0, index: 0, text: trimmed,
                                                    context: nil, isContinuation: false)
                    let reply = try await AIClient.shared.chat(provider: target.provider, model: target.model,
                                                              key: target.key,
                                                              messages: PromptBuilder.simpleMessages(retryChunk, settings),
                                                              temperature: 0,
                                                              maxTokens: min(settings.maxTokensCap, max(1024, trimmed.count * 2 + 256)))
                    final = PromptBuilder.parse(reply.text)
                    if let why2 = Degenerate.reason(output: final, source: trimmed, targetLang: settings.targetLang) {
                        task.log("简化协议仍异常：\(why2)", level: .error)
                    } else {
                        task.log("简化协议重译成功", level: .success)
                    }
                }
                TranslateCache.store(cacheKey, value: final)
                publish {
                    if var c = self.quickCard { c.output = final; c.state = .done; self.quickCard = c }
                }
                task.set(detail: "完成", progress: 1,
                         stats: String(format: "%.1fs · %d 字", Date().timeIntervalSince(started), final.count))
                task.finish(.done)
            } catch {
                let note = (received.isEmpty ? "" : "已收到部分内容；") + error.localizedDescription
                publish {
                    if var c = self.quickCard {
                        c.state = .failed; c.note = note
                        if c.output.isEmpty { c.output = "" }
                        self.quickCard = c
                    }
                }
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    /// 框选区域：先本地 Vision 识别，再翻译（扫描件也能用）
    func translateRegion(image: CGImage, pageIndex: Int, rect: CGRect, ai: AIStore, tasks: TaskCenter) {
        var card = QuickCard(kind: .region, sourceText: "(正在识别区域文字…)", engine: "本地 Vision")
        card.region = rect
        card.pageIndex = pageIndex
        publish { self.quickCard = card; self.paneVisible = false }
        let task = tasks.newTask(kind: .translate, title: "翻译框选区域（第 \(pageIndex + 1) 页）")
        tasks.expanded = true
        Task {
            do {
                task.set(detail: "本地 Vision 识别区域文字…", progress: 0.15)
                let lines = try OCREngine.visionLines(image: image, languages: ai.ocr.languages)
                let text = OCREngine.join(lines, format: .plain).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    publish {
                        if var c = self.quickCard { c.sourceText = ""; c.state = .failed; c.note = "这块区域里没识别到文字"; self.quickCard = c }
                    }
                    task.finish(.failed, error: "区域内未识别到文字")
                    return
                }
                publish {
                    if var c = self.quickCard { c.sourceText = text; c.engine = "本地 Vision → \(ai.translateModel)"; self.quickCard = c }
                }
                task.log("区域识别到 \(text.count) 字", level: .success)
                task.set(detail: "翻译中…", progress: 0.35)
                // 交给与「翻译选中文字」同一套流水线，并复用当前这张任务卡：
                // 原来这里另调 translateSelection（会再开一张卡），
                // 而且紧接着就 task.finish(.done)，翻译其实还没开始跑。
                self.runSelectionFlow(text: text, ai: ai, task: task)
            } catch {
                publish {
                    if var c = self.quickCard { c.state = .failed; c.note = error.localizedDescription; self.quickCard = c }
                }
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    // ---------- 单页 ----------

    func translatePage(_ index: Int, ctx: TranslateContext, ai: AIStore, tasks: TaskCenter) {
        translatePages([index], ctx: ctx, ai: ai, tasks: tasks, title: "翻译第 \(index + 1) 页")
    }

    // ---------- 整篇 ----------

    func translateDocument(ctx: TranslateContext, ai: AIStore, tasks: TaskCenter) {
        translatePages(Array(0..<ctx.pageCount), ctx: ctx, ai: ai, tasks: tasks,
                       title: "翻译整篇（\(ctx.pageCount) 页）")
    }

    private func translatePages(_ pageIndexes: [Int], ctx: TranslateContext, ai: AIStore,
                                tasks: TaskCenter, title: String) {
        guard let target = ai.translateTarget else {
            let t = tasks.newTask(kind: .translate, title: title)
            t.finish(.failed, error: "请先在 AI 中心选择翻译服务商与模型")
            tasks.expanded = true
            return
        }
        let settings = ai.translate
        let signature = ai.translationSignature

        let task = tasks.newTask(kind: .translate, title: title)
        tasks.expanded = true
        let started = Date()
        let engine = "\(target.provider.name) · \(target.model)"
        // 记下启动时的代次：整篇翻译要跑很久，期间用户完全可以再打开另一个文件。
        // 下面每一处回写都先比对它，换过文档就把结果整体丢掉（见 `clear()` 的说明）。
        let gen = self.generation

        publish {
            self.paneVisible = true
            self.engineLabel = engine
            self.statusNote = "准备中…"
            var updated = self.pages
            for i in pageIndexes where updated[i] == nil {
                updated[i] = PageTranslation(pageIndex: i, sourceText: "", state: .running, engine: engine)
            }
            self.pages = updated
        }
        task.log("目标语言：\(LangOption.label(settings.targetLang)) · 风格：\(settings.style.label)"
                 + (settings.deAI ? " · 去 AI 味开" : "")
                 + " · 并发 \(settings.concurrency) · 每片 ≤\(settings.chunkChars) 字", level: .info)

        Task {
            // 1. 取源文本（扫描页自动先做本地 OCR）
            var sourceTexts: [Int: String] = [:]
            let scanThreshold = 20
            var autoOCRPages: [Int] = []
            for (n, i) in pageIndexes.enumerated() {
                if task.isCancelled { break }
                var text = ctx.pageText(i)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < scanThreshold,
                   settingsOutputWantsOCR(ai) {
                    if let p = ctx.page(i) {
                        let ocrKey = OCRCache.key(identity: ctx.identity, page: i, engine: "vision",
                                                  languages: ai.ocr.languages, format: .plain)
                        let pageResult: OCRPageResult
                        if let cached = OCRCache.load(ocrKey) { pageResult = cached }
                        else {
                            pageResult = OCREngine.visionPageResult(p, pageIndex: i, settings: ai.ocr)
                            OCRCache.store(ocrKey, result: pageResult)
                        }
                        if pageResult.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
                            text = pageResult.text
                            autoOCRPages.append(i)
                        }
                    }
                }
                sourceTexts[i] = text
                task.set(detail: "准备文本 \(n + 1)/\(pageIndexes.count) 页",
                         progress: 0.05 * Double(n + 1) / Double(max(1, pageIndexes.count)))
            }
            if !autoOCRPages.isEmpty {
                task.log("扫描页已自动本地 OCR：第 \(autoOCRPages.map { String($0 + 1) }.joined(separator: "、")) 页", level: .warn)
            }

            // 2. 切片
            var allChunks: [TranslateChunk] = []
            var chunksByPage: [Int: [TranslateChunk]] = [:]
            for i in pageIndexes {
                let text = sourceTexts[i] ?? ""
                var prevContext: String? = nil
                if i > 0, let prevText = sourceTexts[i - 1], settings.overlapSentences > 0 {
                    prevContext = TextSplitter.lastSentences(prevText, count: settings.overlapSentences)
                }
                let chunks = TextSplitter.chunks(forPage: text, pageIndex: i, previousContext: prevContext,
                                                 target: settings.chunkChars,
                                                 overlapSentences: settings.overlapSentences)
                chunksByPage[i] = chunks
                allChunks.append(contentsOf: chunks)
                publish {
                    guard gen == self.generation else { return }   // 换过文档了，别写回
                    if var pt = self.pages[i] {
                        pt.sourceText = text
                        self.pages[i] = pt
                    }
                }
            }
            let work = allChunks
            task.log("共 \(pageIndexes.count) 页切成 \(work.count) 片", level: .info)
            if work.isEmpty {
                task.finish(.done); task.log("没有可翻译的文本（可能是空白页或未识别到文字）", level: .warn)
                publish { self.statusNote = "没有可翻译的文本" }
                return
            }

            // 3. 并发翻译
            var outputs: [String: String] = [:]
            var cacheHits = 0
            var failures: [String] = []
            var completed = 0
            let total = work.count
            let limit = max(1, min(8, settings.concurrency))

            await withTaskGroup(of: (TranslateChunk, Result<String, Error>, Bool).self) { group in
                var iterator = work.makeIterator()
                var running = 0
                func addNext() {
                    guard let chunk = iterator.next() else { return }
                    running += 1
                    group.addTask {
                        let cacheKey = TranslateCache.key(text: chunk.text, signature: signature, model: target.model)
                        if let cached = TranslateCache.load(cacheKey) {
                            return (chunk, .success(cached), true)
                        }
                        do {
                            let out = try await self.callTranslatePublic(chunk, settings: settings, target: target,
                                                                   task: task, cacheKey: cacheKey)
                            return (chunk, .success(out), false)
                        } catch {
                            return (chunk, .failure(error), false)
                        }
                    }
                }
                for _ in 0..<limit { addNext() }

                while let (chunk, result, fromCache) = await group.next() {
                    running -= 1
                    completed += 1
                    if fromCache { cacheHits += 1 }
                    switch result {
                    case .success(let text):
                        outputs[chunk.id] = text
                        task.log("\(chunk.shortID) 完成 · \(text.count) 字\(fromCache ? "（缓存）" : "")",
                                 level: fromCache ? .info : .success)
                    case .failure(let e):
                        failures.append(chunk.id)
                        task.log("\(chunk.shortID) 失败：\(e.localizedDescription)", level: .error)
                    }
                    let p = 0.05 + 0.85 * Double(completed) / Double(total)
                    let elapsed = Date().timeIntervalSince(started)
                    let eta = completed > 0 ? elapsed / Double(completed) * Double(total - completed) : nil
                    task.set(detail: "翻译 \(completed)/\(total) 片 · \(chunk.shortID) · 并发 \(min(limit, max(1, running + 1)))",
                             progress: p,
                             stats: String(format: "已用 %@", timeText(elapsed))
                                + (eta.map { String(format: " · 预计还需 %@", timeText($0)) } ?? "")
                                + (cacheHits > 0 ? " · 缓存 \(cacheHits)" : "")
                                + (failures.isEmpty ? "" : " · 失败 \(failures.count)"))
                    if task.isCancelled { group.cancelAll(); break }
                    if running < limit { addNext() }
                }
            }
            if task.isCancelled {
                task.finish(.cancelled)
                publish { self.statusNote = "已取消（已完成 \(outputs.count) 片）" }
                return
            }

            // 4. 逐页合并 + 接缝质检 + 自动修复
            var issuesTotal = 0, repairedTotal = 0, unresolved: [String] = []
            for i in pageIndexes {
                guard let chunks = chunksByPage[i], !chunks.isEmpty else { continue }
                var texts = chunks.map { outputs[$0.id] ?? "" }
                var issues = SeamCheck.check(source: chunks, outputs: texts)

                // 自动修复：回声去重（本地即可）
                for k in 0..<chunks.count where k > 0 {
                    if issues.contains(where: { $0.chunk.id == chunks[k].id && $0.kind == .echoPrevious }) {
                        let (stripped, did) = SeamCheck.stripDuplicatedPrefix(texts[k], previousTyped: texts[k - 1])
                        if did { texts[k] = stripped; repairedTotal += 1 }
                    }
                }
                // 自动修复：重译异常片（一次）
                let retryKinds: Set<SeamIssueKind> = [.empty, .truncated, .formatLeak, .tooShort]
                let retryIdx = issues.filter { retryKinds.contains($0.kind) }
                    .compactMap { issue in chunks.firstIndex(where: { $0.id == issue.chunk.id }) }
                if !retryIdx.isEmpty {
                    task.set(detail: "第 \(i + 1) 页接缝检查：重译 \(retryIdx.count) 片…", progress: 0.92)
                    for k in Set(retryIdx) {
                        if task.isCancelled { break }
                        let chunk = chunks[k]
                        let messages = PromptBuilder.simpleMessages(chunk, settings)
                            + [ChatMessage.user("注意：上一次的输出不完整或格式不合要求。请重新完整翻译上面那段内容的全部，不要截断、不要只输出标签。")]
                        do {
                            let maxTokens = min(settings.maxTokensCap, max(1200, chunk.text.count * 3 + 512))
                            let reply = try await AIClient.shared.chat(provider: target.provider, model: target.model,
                                                                       key: target.key, messages: messages,
                                                                       temperature: min(0.1, settings.temperature),
                                                                       maxTokens: maxTokens)
                            texts[k] = PromptBuilder.parse(reply.text)
                            repairedTotal += 1
                            task.log("\(chunk.shortID) 已重译", level: .success)
                        } catch {
                            task.log("\(chunk.shortID) 重译失败：\(error.localizedDescription)", level: .error)
                        }
                    }
                    issues = SeamCheck.check(source: chunks, outputs: texts)
                }
                issuesTotal += issues.count
                for issue in issues {
                    task.log("\(issue.chunk.shortID) · \(issue.kind.rawValue)：\(issue.detail)", level: .warn)
                    unresolved.append("\(issue.chunk.shortID) \(issue.kind.rawValue)")
                }

                let merged = texts.joined(separator: "\n\n")
                let segments = pairSegments(source: chunks.map(\.text), translated: texts)
                let note = issues.isEmpty ? nil : "\(issues.count) 处需留意：\(Set(issues.map { $0.kind.rawValue }).joined(separator: "、"))"
                publish {
                    guard gen == self.generation else { return }   // 换过文档了，别写回
                    self.pages[i] = PageTranslation(pageIndex: i,
                                                    sourceText: sourceTexts[i] ?? "",
                                                    translatedText: merged,
                                                    segments: segments,
                                                    state: issues.isEmpty ? .done : .done,
                                                    qualityNote: note,
                                                    engine: engine,
                                                    seconds: Date().timeIntervalSince(started))
                }
            }

            // 5. 可选：全文校对
            if settings.proofread && !task.isCancelled {
                task.set(detail: "全文一致性校对（第二遍）…", progress: 0.95)
                for i in pageIndexes {
                    guard var pt = await MainActor.run(body: { self.pages[i] }), !pt.translatedText.isEmpty,
                          !pt.sourceText.isEmpty else { continue }
                    let messages = [ChatMessage.system(PromptBuilder.proofreadSystemPrompt(settings)),
                                    ChatMessage.user("<SRC>\n\(pt.sourceText)\n</SRC>\n\n当前译文：\n\(pt.translatedText)\n\n请输出修正后的完整译文，放进 <T></T>。")]
                    do {
                        let reply = try await AIClient.shared.chat(provider: target.provider, model: target.model,
                                                                   key: target.key, messages: messages,
                                                                   temperature: 0.1,
                                                                   maxTokens: min(settings.maxTokensCap, max(1200, pt.sourceText.count * 3 + 512)))
                        pt.translatedText = PromptBuilder.parse(reply.text)
                        pt.segments = pairSegments(source: TextSplitter.paragraphs(pt.sourceText),
                                                   translated: [pt.translatedText])
                        let final = pt
                        publish {
                            guard gen == self.generation else { return }   // 换过文档了，别写回
                            self.pages[i] = final
                        }
                        task.log("第 \(i + 1) 页已校对", level: .success)
                    } catch {
                        task.log("第 \(i + 1) 页校对失败：\(error.localizedDescription)", level: .warn)
                    }
                }
            }

            let elapsed = Date().timeIntervalSince(started)
            let chars = await MainActor.run { self.totalChars }
            publish {
                guard gen == self.generation else { return }   // 换过文档了，别写回
                self.statusNote = "完成 \(pageIndexes.count) 页 · \(chars) 字 · 用时 \(timeText(elapsed))"
                self.qualitySummary = issuesTotal == 0
                    ? "接缝检查通过：未发现截断、重复或漏译"
                    : "接缝检查：发现 \(issuesTotal) 处异常，自动修复 \(repairedTotal) 处"
                      + (unresolved.isEmpty ? "" : "，待确认 \(unresolved.count) 处（\(unresolved.prefix(3).joined(separator: "；"))）")
            }
            task.set(detail: "完成", progress: 1,
                     stats: String(format: "%d 片 · 缓存 %d · 用时 %@ · %.1f 字/秒", total, cacheHits, timeText(elapsed),
                                   Double(chars) / max(0.1, elapsed)))
            if failures.count == total {
                task.finish(.failed, error: "全部切片失败，请检查服务商与密钥")
            } else {
                task.finish(.done)
            }
        }
    }

    private func settingsOutputWantsOCR(_ ai: AIStore) -> Bool { ai.ocr.autoOCRScannedPagesWhenTranslating }

    /// 带降级的单次翻译调用：完整协议 → 退化判定 → 简化协议重试
    /// 本地小模型（如 Ollama 上的 4B 级模型）经常把「要求」复述出来或只吐标签，这层兜住它。
    func callTranslatePublic(_ chunk: TranslateChunk, settings: TranslateSettings,
                               target: (provider: AIProvider, model: String, key: String),
                               task: AITask? = nil, cacheKey: String? = nil) async throws -> String {
        let maxTokens = min(settings.maxTokensCap, max(700, chunk.text.count * 2 + 320))
        var firstReason: String?
        do {
            let reply = try await AIClient.shared.chat(provider: target.provider, model: target.model,
                                                      key: target.key,
                                                      messages: [.system(PromptBuilder.systemPrompt(settings)),
                                                                 .user(PromptBuilder.userMessage(chunk))],
                                                      temperature: settings.temperature, maxTokens: maxTokens)
            let parsed = PromptBuilder.parse(reply.text)
            firstReason = Degenerate.reason(output: parsed, source: chunk.text, targetLang: settings.targetLang)
            if firstReason == nil {
                if let cacheKey { TranslateCache.store(cacheKey, value: parsed) }
                task?.log("\(chunk.shortID) 完成 \u{b7} \(parsed.count) 字", level: .success)
                return parsed
            }
            task?.log("\(chunk.shortID) 输出异常（\(firstReason!)），改用简化协议重试", level: .warn)
        } catch {
            firstReason = error.localizedDescription
            task?.log("\(chunk.shortID) 首次调用失败：\(error.localizedDescription)，改用简化协议重试", level: .warn)
        }

        // 简化协议 + 零温度
        let reply2 = try await AIClient.shared.chat(provider: target.provider, model: target.model,
                                                   key: target.key,
                                                   messages: PromptBuilder.simpleMessages(chunk, settings),
                                                   temperature: 0, maxTokens: maxTokens)
        let parsed2 = PromptBuilder.parse(reply2.text)
        if let why = Degenerate.reason(output: parsed2, source: chunk.text, targetLang: settings.targetLang) {
            task?.log("\(chunk.shortID) 简化协议仍异常：\(why)", level: .error)
        } else if let cacheKey {
            TranslateCache.store(cacheKey, value: parsed2)
            task?.log("\(chunk.shortID) 简化协议重试成功", level: .success)
        }
        return parsed2
    }

    /// 段落级对照：把源与译文都按空行切分后一一配对
    private func pairSegments(source: [String], translated: [String]) -> [(source: String, target: String)] {
        var pairs: [(String, String)] = []
        for (i, srcChunk) in source.enumerated() {
            let dstChunk = i < translated.count ? translated[i] : ""
            let srcParas = TextSplitter.paragraphs(srcChunk)
            let dstParas = TextSplitter.paragraphs(dstChunk)
            if srcParas.count == dstParas.count {
                for (a, b) in zip(srcParas, dstParas) { pairs.append((a, b)) }
            } else if dstParas.isEmpty {
                for a in srcParas { pairs.append((a, "")) }
            } else {
                // 数量对不上时按比例归并，宁可粗一点也不要错位
                pairs.append((srcParas.joined(separator: "\n\n"), dstParas.joined(separator: "\n\n")))
            }
        }
        return pairs
    }

    // ---------- 导出 ----------

    func exportMarkdown(title: String, targetLangLabel: String) -> String? {
        guard !pages.isEmpty else { return nil }
        var out = "# \(title) · 译文（\(targetLangLabel)）\n\n"
        out += "引擎：\(engineLabel)\n\n"
        for idx in pages.keys.sorted() {
            guard let pt = pages[idx] else { continue }
            out += "\n---\n\n## 第 \(idx + 1) 页\n\n"
            out += pt.translatedText + "\n"
        }
        return out
    }

    func exportBilingualMarkdown(title: String, targetLangLabel: String) -> String? {
        guard !pages.isEmpty else { return nil }
        var out = "# \(title) · 原文 / 译文对照（\(targetLangLabel)）\n\n"
        for idx in pages.keys.sorted() {
            guard let pt = pages[idx] else { continue }
            out += "\n---\n\n## 第 \(idx + 1) 页\n\n"
            for seg in pt.segments {
                out += "**原文**\n\n\(seg.source)\n\n**译文**\n\n\(seg.target)\n\n"
            }
            if pt.segments.isEmpty { out += pt.translatedText + "\n" }
        }
        return out
    }
}

// MARK: - 供测试与外部调用的单次翻译入口（走完整降级策略）

extension TranslateStore {
    func translateChunkOnce(_ chunk: TranslateChunk, settings: TranslateSettings,
                            target: (provider: AIProvider, model: String, key: String)) async throws -> String {
        try await callTranslatePublic(chunk, settings: settings, target: target)
    }
}
