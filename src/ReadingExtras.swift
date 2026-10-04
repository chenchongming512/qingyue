// 轻阅 · 阅读增强：护眼/夜间色调、朗读、选中即问、整篇摘要与自动大纲

import SwiftUI
import PDFKit
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - 阅读色调（护眼 / 夜间）

/// 页面色调。
///
/// ⚠️ 实现方式**不是**在页面上叠一层半透明色，而是给 PDFView 的 layer 挂 Core Image 滤镜：
/// - 叠色法做不到夜间模式。黑字叠上深色底之后还是黑的，和深色背景几乎没有对比度，
///   字就"糊"在背景里了。夜间必须**反相**（白底变深、黑字变浅）。
/// - `CALayer.filters` 的作用域是「这一层**及其子层**」，正合适 ——
///   PDF 的页面层、批注层、选区层全在 PDFView 的层树里，一刀切全部生效，
///   而外面的浮动工具条、边栏不受影响。
enum ReadingTint: String, CaseIterable, Identifiable, Codable {
    case normal, sepia, night, nightWarm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal:    return "原色"
        case .sepia:     return "暖纸（护眼）"
        case .night:     return "夜间"
        case .nightWarm: return "夜间 · 暖调"
        }
    }
    var shortLabel: String {
        switch self {
        case .normal:    return "原色"
        case .sepia:     return "暖纸"
        case .night:     return "夜间"
        case .nightWarm: return "夜暖"
        }
    }
    var icon: String {
        switch self {
        case .normal:    return "circle.lefthalf.filled"
        case .sepia:     return "sun.haze"
        case .night:     return "moon.stars"
        case .nightWarm: return "moon.haze"
        }
    }
    var isDark: Bool { self == .night || self == .nightWarm }

    /// 挂到 PDFView 图层上的滤镜链（空数组 = 不处理，恢复原色）
    ///
    /// ⚠️ 调试这一块时**先把探针修对**：我们一度以为 sepia 没生效，
    /// 折腾了合成方式、换了滤镜，最后发现是读像素的小工具把字节序搞错了 ——
    /// PNG 解码出的 `CGImage` 不一定按 BGRA 排列，硬按 BGRA 读会把 R/B 读反，
    /// 于是暖白 (255,254,251) 被念成"冷白 (250,254,255)"。
    /// **滤镜没问题，是尺子错了。** 现在探针走 `NSBitmapImageRep.colorAt`。
    func makeFilters() -> [CIFilter] {
        func filter(_ name: String) -> CIFilter? { CIFilter(name: name) }
        switch self {
        case .normal:
            return []
        case .sepia:
            var list: [CIFilter] = []
            // 1. 经典的棕褐色偏
            if let t = filter("CISepiaTone") {
                t.setValue(0.72, forKey: "inputIntensity")
                list.append(t)
            }
            // 2. 再往纸黄推一把。
            //    光靠 CISepiaTone，白纸只走到 (255,254,251) —— 蓝分量才低 4 个色阶，
            //    肉眼基本看不出"暖"，等于白开。补一道压绿压蓝，落到 (255,246,228) 那种米黄。
            if let m = filter("CIColorMatrix") {
                m.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
                m.setValue(CIVector(x: 0, y: 0.968, z: 0, w: 0), forKey: "inputGVector")
                m.setValue(CIVector(x: 0, y: 0, z: 0.902, w: 0), forKey: "inputBVector")
                m.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                list.append(m)
            }
            return list
        case .night, .nightWarm:
            var list: [CIFilter] = []
            // 1. 反相：白纸 → 深色，黑字 → 浅色。这一步是夜间模式能读的关键。
            if let invert = filter("CIColorInvert") { list.append(invert) }
            // 2. 反相后整体偏亮偏蓝，压一点亮度、降一点饱和
            if let c = filter("CIColorControls") {
                c.setValue(-0.03, forKey: kCIInputBrightnessKey)
                c.setValue(self == .night ? 0.75 : 0.68, forKey: kCIInputSaturationKey)
                list.append(c)
            }
            if self == .nightWarm {
                // 3. 往暖色偏一点，压蓝光
                if let m = filter("CIColorMatrix") {
                    m.setValue(CIVector(x: 1.06, y: 0, z: 0, w: 0), forKey: "inputRVector")
                    m.setValue(CIVector(x: 0, y: 0.99, z: 0, w: 0), forKey: "inputGVector")
                    m.setValue(CIVector(x: 0, y: 0, z: 0.88, w: 0), forKey: "inputBVector")
                    list.append(m)
                }
            }
            return list
        }
    }

    /// 阅读区的底色（页面之外的留白区跟着一起变，不然夜间模式边缘会很刺眼）。
    /// 这是**滤镜之后**的颜色 —— PDFView 外层容器用。
    var canvasBackground: Color {
        switch self {
        case .normal:    return Color(nsColor: .windowBackgroundColor)
        case .sepia:     return Color(red: 0.93, green: 0.90, blue: 0.83)
        case .night:     return Color(red: 0.09, green: 0.10, blue: 0.12)
        case .nightWarm: return Color(red: 0.11, green: 0.10, blue: 0.10)
        }
    }

    // ---------- 整机外观 ----------

    /// 该色调是否要强制 App 走深色外观。
    ///
    /// 只反相正文是不够的 —— 顶栏、边栏、浮动工具条、缩略图还是惨白的话，
    /// 中间一块黑反而更晃眼，看着像半成品。夜间必须整机切深色。
    /// 原色 / 暖纸**不强制**（返回 nil = 跟随系统），
    /// 否则用户在系统深色模式下会看到一个雪白的 App。
    var forcedAppearance: NSAppearance.Name? { isDark ? .darkAqua : nil }

    /// 把外观应用到整个 App。切色调、以及 App 启动时各调一次。
    ///
    /// ⚠️ 只设 `NSApp.appearance` 不够 —— SwiftUI 的 `WindowGroup` 建出来的
    /// NSWindow 不会跟着变（实测：截出来的图和没设之前**字节数完全相同**）。
    /// 必须把 appearance 挨个压到已存在的窗口上。
    /// 传 nil 表示"跟随上层"，所以原色 / 暖纸时窗口会正确回到系统外观。
    ///
    /// 注意这里只管 **AppKit** 那一半（菜单、NSAlert、原生控件）。
    /// SwiftUI 那一半靠 `TintAppearance` 覆盖 `\.colorScheme` 环境，见下。
    func applyAppearance() {
        let ap = forcedAppearance.flatMap { NSAppearance(named: $0) }
        NSApp?.appearance = ap
        for w in NSApp?.windows ?? [] { w.appearance = ap }
    }

    /// PDFView **自身**的 backgroundColor。
    ///
    /// ⚠️ 这个值会被滤镜吃掉，所以要填**滤镜之前**的颜色：
    /// 夜间模式下填深色的话，反相之后反而变成浅色，页面和留白就颠倒了。
    /// 填 0.88 的浅灰 → 反相后约 0.12，比纯黑的页面略亮一点，正好留出一道页边。
    var pdfViewBackground: NSColor {
        switch self {
        case .normal:    return PDFKitView.dynamicBackground()
        case .sepia:     return NSColor(calibratedWhite: 1.0, alpha: 1)
        case .night:     return NSColor(calibratedWhite: 0.88, alpha: 1)
        case .nightWarm: return NSColor(calibratedWhite: 0.88, alpha: 1)
        }
    }

    /// 把同一套滤镜链作用到一张位图上（缩略图用）。
    ///
    /// ⚠️ 缩略图为什么不能走图层滤镜、也不能用 SwiftUI 的 `.colorInvert()`：
    /// - 它是 `Image(nsImage:)`，不是 PDFView，挂不上图层滤镜；
    /// - `.colorInvert()` 是**合成期**效果，`CALayer.render(in:)`（截图通道）抓不到，
    ///   而且它是另一套参数，没法保证和正文用的一致。
    /// 所以直接在像素上做，顺带把 `makeFilters()` 复用起来 —— 一处改、两处生效。
    func bake(_ image: NSImage) -> NSImage {
        let filters = makeFilters()
        guard !filters.isEmpty else { return image }
        guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return image }
        var out = ci
        for f in filters {
            f.setValue(out, forKey: kCIInputImageKey)
            if let o = f.outputImage { out = o }
        }
        guard let cg = CIContext(options: [.useSoftwareRenderer: false])
                .createCGImage(out, from: ci.extent) else { return image }
        return NSImage(cgImage: cg, size: image.size)
    }

    // ---------- 持久化（全局设置，不是按文档） ----------

    private static let key = "qingyue.readingTint"

    static var saved: ReadingTint {
        get { ReadingTint(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static func clearSaved() { UserDefaults.standard.removeObject(forKey: key) }
}

extension AppState {
    /// 换一种阅读色调并记住
    func setReadingTint(_ t: ReadingTint) {
        let changed = readingTint != t
        readingTint = t
        ReadingTint.saved = t
        // 外观无条件压一遍（幂等）。不能放在 `changed` 判断里面：
        // 重启后 `readingTint` 初值就是上次存的夜间，此时再传 .night 会被判成"没变化"
        // 而跳过应用，结果就是正文黑的、边栏白的。
        t.applyAppearance()
        if changed { showToast("阅读色调：\(t.label)") }
    }
}

/// 夜间色调要把 **SwiftUI** 的 `colorScheme` 也压成深色。
///
/// ⚠️ 试过两条都不行，记下来省得再踩：
/// 1. `NSApp.appearance = .darkAqua` —— 日志里 `effectiveAppearance` 已经是
///    DarkAqua 了，截图却**一个字节都没变**。它只管 AppKit 控件，管不到 SwiftUI。
/// 2. `.preferredColorScheme(.dark)` —— 同样没反应。它是"向窗口提请求"，
///    在截图这条路径上来不及传导。
///
/// 直接覆盖 `\.colorScheme` 环境才是立刻见效的做法 —— SwiftUI 里
/// `Color.primary`、`Color(nsColor: .controlBackgroundColor)` 这类语义色
/// 都按这个环境解析。非夜间时不覆盖，原样透传上层（也就是跟随系统深浅色）。
struct TintAppearance: ViewModifier {
    let isDark: Bool
    @Environment(\.colorScheme) private var inherited

    func body(content: Content) -> some View {
        content.environment(\.colorScheme, isDark ? .dark : inherited)
    }
}

// MARK: - 朗读（TTS）

/// 系统语音合成。扫描件也能用 —— 文本来源是「页面文字 → 没有就走 OCR 结果」。
///
/// 刻意**不加 `@MainActor`**：`@StateObject` 的属性初始化发生在非隔离上下文里，
/// 标注成 MainActor 会连带要求初始化器也是隔离的，白白多出一堆隔离报错。
/// 这里所有写入口都从界面调用（本来就在主线程），delegate 回调再显式切回主线程。
final class SpeechReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var speaking = false
    @Published var currentTitle = ""

    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, title: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        let utt = AVSpeechUtterance(string: String(trimmed.prefix(6000)))
        utt.voice = Self.voice(matching: trimmed)
        // 默认语速 0.5，中文听感偏快；0.47 稍慢一点更像朗读
        utt.rate = 0.47
        utt.postUtteranceDelay = 0.05
        currentTitle = title
        speaking = true
        synth.speak(utt)
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
        currentTitle = ""
    }

    func toggle(_ text: String, title: String) {
        if speaking { stop() } else { speak(text, title: title) }
    }

    /// 按文本里的汉字 / 拉丁字母占比挑中文或英文嗓音
    private static func voice(matching text: String) -> AVSpeechSynthesisVoice? {
        let han = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x7A).contains($0.value) }.count
        let lang = han >= latin ? "zh-CN" : "en-US"
        return AVSpeechSynthesisVoice(language: lang) ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.currentTitle = "" }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.currentTitle = "" }
    }
}

// MARK: - 选中即问

enum AskMode: String, CaseIterable, Identifiable {
    case explain, summarize, translate, custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .explain:   return "解释这段"
        case .summarize: return "概括要点"
        case .translate: return "翻成中文"
        case .custom:    return "追问…"
        }
    }
    var icon: String {
        switch self {
        case .explain:   return "questionmark.circle"
        case .summarize: return "list.bullet.rectangle.portrait"
        case .translate: return "character.book.closed"
        case .custom:    return "bubble.left.and.text.bubble.right"
        }
    }
    var systemPrompt: String {
        switch self {
        case .explain:
            return """
            你是阅读助手。用户选中了一段文字，请把它**讲明白**。
            要求：先一句话说这段在讲什么，再逐点拆开其中的难点（术语、指代、隐含前提）；
            用中文、口语化、不要客套话、不要重复原文。控制在 300 字内。
            """
        case .summarize:
            return """
            你是阅读助手。请把用户选中的这段文字概括成**要点清单**。
            要求：3~6 条，每条一行，以「- 」开头；只保留原文有的事实，不要补充原文没有的信息。
            """
        case .translate:
            return """
            你是翻译。把用户选中的文字翻译成简体中文，只输出译文，不要解释、不要加引号。
            专有名词保留原文并加括号注释。
            """
        case .custom:
            return """
            你是阅读助手，正在陪用户读一份文档。user 消息里会给出一段原文，
            以及用户针对这段原文提出的问题。请只回答用户的问题，需要引用原文时简短引用。
            中文回答，不要客套话。
            """
        }
    }
    /// 输出是不是要解析 <T></T> 协议（翻译那条复用翻译协议，其余是纯文本）
    var usesTranslateProtocol: Bool { self == .translate }
}

enum AskAI {

    /// 选中即问。结果复用翻译的快捷卡片（同一套流式 / 失败 / 复制逻辑），
    /// 只是换了个 `kind`，标题与图标跟着变。
    static func run(text: String, mode: AskMode, question: String = "",
                    ai: AIStore, tasks: TaskCenter, translate: TranslateStore) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let target = ai.askTarget else {
            var card = QuickCard(kind: .ask, sourceText: trimmed, output: "", state: .failed)
            card.note = "请先在 AI 中心配好服务商与模型"
            translate.showQuickCard(card)
            return
        }

        var card = QuickCard(kind: .ask, sourceText: trimmed,
                             engine: "\(target.provider.name) · \(target.model)")
        card.askLabel = mode.label
        card.state = .running
        translate.showQuickCard(card)
        translate.paneVisible = false

        let task = tasks.newTask(kind: .translate, title: "AI · \(mode.label)（\(trimmed.count) 字）")
        tasks.expanded = true

        Task {
            var received = ""
            let started = Date()
            do {
                let userText: String
                if mode == .custom {
                    userText = """
                    原文：
                    \(trimmed)

                    用户的问题：\(question.isEmpty ? "这段是什么意思？" : question)
                    """
                } else {
                    userText = trimmed
                }
                let messages = [ChatMessage.system(mode.systemPrompt), ChatMessage.user(userText)]
                var buffer = ""
                for try await piece in AIClient.shared.chatStream(
                    provider: target.provider, model: target.model, key: target.key,
                    messages: messages, temperature: mode == .translate ? 0.2 : 0.4,
                    maxTokens: 2048) {
                    buffer += piece
                    received = buffer
                    let shown = mode.usesTranslateProtocol ? PromptBuilder.parse(buffer) : buffer
                    await MainActor.run {
                        if var c = translate.quickCard { c.output = shown; translate.quickCard = c }
                    }
                    task.set(detail: "正在生成…（已收到 \(shown.count) 字）",
                             stats: String(format: "%.1fs", Date().timeIntervalSince(started)))
                }
                let final = mode.usesTranslateProtocol ? PromptBuilder.parse(buffer) : buffer
                guard !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AIError.emptyReply
                }
                await MainActor.run {
                    if var c = translate.quickCard {
                        c.output = final
                        c.state = .done
                        translate.quickCard = c
                    }
                }
                task.set(detail: "完成", progress: 1,
                         stats: String(format: "%.1fs · %d 字", Date().timeIntervalSince(started), final.count))
                task.finish(.done)
            } catch {
                let note = (received.isEmpty ? "" : "已收到部分内容；") + error.localizedDescription
                await MainActor.run {
                    if var c = translate.quickCard { c.state = .failed; c.note = note; translate.quickCard = c }
                }
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }
}

// MARK: - 整篇摘要 / 自动大纲

enum SummaryState: Equatable {
    case idle, running, done, failed(String)
}

@MainActor
final class SummaryStore: ObservableObject {
    @Published var summary: String = ""
    @Published var summaryState: SummaryState = .idle
    @Published var outline: [AiOutlineItem] = []
    @Published var outlineState: SummaryState = .idle
    /// 长文档会抽样，如实告诉用户摘要覆盖了多少
    @Published var coverageNote: String = ""
    /// 笔记**生成时用的模型**，用来判断"当前设置变了、这份摘要还合不合用"
    @Published var sourceDescription: String = ""
    /// 生成时间（从磁盘读回时显示"这份是几号生成的"）
    @Published var generatedAt: Date?

    /// 当前文档的身份（文件名 + 字节数 + mtime）。**每次打开文档都会变**，
    /// 所以存/取都要跟着它走；为 nil 表示当前没有打开文档。
    private var documentIdentity: String?

    /// 从磁盘读回来的摘要，所用的模型与当前设置不一致 → 提示用户是否重新生成。
    /// 为 nil 表示一致（或从未读过）。
    @Published var staleSourceDescription: String?

    /// 这份摘要是从磁盘读出来的（vs 刚生成）—— 界面上给个"已保存"的标记
    @Published var loadedFromDisk = false

    /// OCR 结果按页取（扫描件没有文本层时兜底）
    var ocrText: ((Int) -> String)?
    /// 换文档代次。跟 OCR / 翻译 / 搜索是同一套路：
    /// 生成摘要要几十秒，这期间用户完全可以再打开另一个文件；
    /// 老任务的流式回写（`summary = buffer` 每来一块就写一次）会把
    /// 上一个文件的内容灌进当前文档的面板 —— 而且是**持续**灌，最难察觉。
    private var generation = 0

    func clear() {
        summary = ""
        summaryState = .idle
        outline = []
        outlineState = .idle
        coverageNote = ""
        sourceDescription = ""
        generatedAt = nil
        staleSourceDescription = nil
        loadedFromDisk = false
        documentIdentity = nil
        generation &+= 1
    }

    // ---------- 持久化 ----------

    /// 换文档时调用：把上一份的痕迹清掉，并尝试读回这份文档存过的摘要。
    ///
    /// ⚠️ 读回**不能**放在 `makeSummary` 前面做，那会让"点生成"按钮看似无效
    /// （读到旧的就把状态设成 done，用户以为没反应）。所以读回只在**打开文档**时做，
    /// 界面会明确显示"这是保存的，要重新生成请点按钮"。
    func switchDocument(identity: String?, currentSource: String) {
        clear()
        documentIdentity = identity
        guard let identity, let payload = StudyNoteStore.load(identity: identity) else { return }
        summary = payload.summary
        outline = payload.outline
        coverageNote = payload.coverageNote
        sourceDescription = payload.sourceDescription
        generatedAt = payload.generatedAt
        loadedFromDisk = true
        if !payload.summary.isEmpty { summaryState = .done }
        if !payload.outline.isEmpty { outlineState = .done }
        // 模型换了就提示一句 —— 不是拦住，只是告诉用户"这份是用别的模型生成的"
        staleSourceDescription = payload.sourceDescription.isEmpty
            || payload.sourceDescription == currentSource ? nil : payload.sourceDescription
    }

    /// 存回磁盘。**每次生成成功都自动存**，用户不用点"保存"。
    @discardableResult
    func persist(currentSource: String) -> Bool {
        guard let identity = documentIdentity, !summary.isEmpty || !outline.isEmpty else { return false }
        let payload = SummaryPayload(summary: summary, outline: outline,
                                     coverageNote: coverageNote,
                                     sourceDescription: currentSource,
                                     generatedAt: Date())
        let ok = StudyNoteStore.save(payload, identity: identity)
        if ok {
            sourceDescription = currentSource
            generatedAt = payload.generatedAt
            loadedFromDisk = false   // 刚生成的，不是从磁盘读的
            staleSourceDescription = nil
        }
        return ok
    }

    /// 删掉这份文档存的笔记（界面上「删除笔记」用）
    func discardNote() {
        if let identity = documentIdentity { StudyNoteStore.clear(identity: identity) }
        clear()
        documentIdentity = nil
    }

    // ---------- 生成 ----------

    func makeSummary(doc: PDFDocument, ai: AIStore, tasks: TaskCenter, title: String) {
        guard let target = ai.askTarget else {
            summaryState = .failed("请先在 AI 中心配好服务商与模型")
            return
        }
        guard summaryState != .running else { return }
        let (body, note) = PageSampler.bodySample(doc, ocrText: ocrText)
        guard !body.isEmpty else {
            summaryState = .failed("这份文档没有可读文本，先做一次 OCR 吧")
            return
        }
        coverageNote = note
        summaryState = .running
        // 记下代次，回写前比对（见 clear() 的说明）
        let gen = generation
        summary = ""
        let task = tasks.newTask(kind: .translate, title: "生成整篇摘要")
        tasks.expanded = true
        task.log(note, level: .info)

        Task {
            do {
                let prompt = """
                下面是文档《\(title)》的正文节选。请写一份**导读式摘要**，用 Markdown：
                ## 一句话概括
                （一句话说清这份文档在讲什么）
                ## 主要内容
                （3~7 条要点，每条一行，以「- 」开头）
                ## 值得注意的地方
                （1~3 条：结论、易被忽略的前提、或是明显的问题）
                只依据给出的文本，不要编造。总长控制在 600 字以内。
                """
                let messages = [ChatMessage.system(prompt), ChatMessage.user(body)]
                var buffer = ""
                for try await piece in AIClient.shared.chatStream(
                    provider: target.provider, model: target.model, key: target.key,
                    messages: messages, temperature: 0.3, maxTokens: 2048) {
                    buffer += piece
                    // 流式回写：每来一块就写一次，换过文档就整段丢弃
                    await MainActor.run {
                        guard gen == self.generation else { return }
                        self.summary = buffer
                    }
                    task.set(detail: "正在生成摘要…（\(buffer.count) 字）")
                }
                let final = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { throw AIError.emptyReply }
                await MainActor.run {
                    guard gen == self.generation else { return }   // 换过文档了，别写回
                    self.summary = final
                    self.summaryState = .done
                    // 生成成功就自动存盘 —— 用户不该再多点一次"保存"，
                    // 否则下次重开还得等几十秒重新生成。
                    self.persist(currentSource: ai.askTargetDescription)
                }
                task.set(detail: "完成", progress: 1, stats: "\(final.count) 字")
                task.finish(.done)
            } catch {
                await MainActor.run { self.summaryState = .failed(error.localizedDescription) }
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    func makeOutline(doc: PDFDocument, ai: AIStore, tasks: TaskCenter) {
        guard let target = ai.askTarget else {
            outlineState = .failed("请先在 AI 中心配好服务商与模型")
            return
        }
        guard outlineState != .running else { return }
        guard doc.pageCount > 0 else { return }
        let digest = PageSampler.pageDigest(doc, ocrText: ocrText)
        outlineState = .running
        outline = []
        let gen = generation
        let task = tasks.newTask(kind: .translate, title: "生成章节目录（\(doc.pageCount) 页）")
        tasks.expanded = true

        Task {
            do {
                let prompt = """
                下面是文档每一页的**页首文字**，格式为 `页码|该页开头`。
                请判断哪些页是**新章节 / 新小节的起始页**，为它们各起一个简短标题。
                输出格式（严格遵守，一行一条，不要序号、不要解释、不要代码块）：
                页码|标题
                例如：
                1|引言
                14|系统设计
                要求：标题 4~14 个汉字；页码必须来自上面给出的列表；最多 25 条；
                宁可少也不要给每一页都编标题 —— 只标真正另起一节的地方。
                """
                let reply = try await AIClient.shared.chat(
                    provider: target.provider, model: target.model, key: target.key,
                    messages: [ChatMessage.system(prompt), ChatMessage.user(digest)],
                    temperature: 0.2, maxTokens: 2048)
                let items = OutlineParser.parse(reply.text, pageCount: doc.pageCount)
                guard !items.isEmpty else {
                    throw NSError(domain: "qingyue.ai", code: 7,
                                  userInfo: [NSLocalizedDescriptionKey: "模型没有返回可用的章节，换个模型再试"])
                }
                await MainActor.run {
                    guard gen == self.generation else { return }   // 换过文档了，别写回
                    self.outline = items
                    self.outlineState = .done
                    self.persist(currentSource: ai.askTargetDescription)   // 同上，自动存
                }
                task.set(detail: "完成", progress: 1, stats: "\(items.count) 个章节")
                task.finish(.done)
            } catch {
                await MainActor.run { self.outlineState = .failed(error.localizedDescription) }
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    /// 只给截图通道用：填一份成品摘要 + 章节，好让 `--pane summary` 截到"用起来是什么样"，
    /// 而不是永远只有一句引导语。真机调模型要几十秒，截图等不起。
    /// 内容按演示文档（《The Quiet Architecture of Reading》，3 页英文）拟。
    func injectDemo() {
        guard summaryState == .idle else { return }
        summary = """
        ## 一句话概括
        这份文档讨论的是「安静阅读」为何正在从现代阅读器里消失，以及界面设计该怎样把注意力还给内容本身。

        ## 主要内容
        - 阅读器的竞争点长期集中在格式兼容与标注能力，忽略了「不打扰」这一基本体验。
        - 弹窗、角标与进度提示会在用户尚未读完一段时就把注意力切走。
        - 分页与滚动两种模式各有代价：分页给确定感，滚动给连续性，混用则两头落空。
        - 排版密度比字号更影响长时间阅读的疲劳度，行距与页边距的收益被普遍低估。
        - 批注应当随手可得但默认隐形，而不是常驻在屏幕上等待被使用。

        ## 值得注意的地方
        - 文中「安静」的定义只覆盖了视觉与交互层，未涉及通知系统，结论有边界。
        - 作者引用的几组阅读时长数据来自小样本实验，不宜直接外推。
        """
        summaryState = .done
        coverageNote = "已覆盖全部 3 页（共 5,266 字，未抽样）"

        outline = [
            .init(pageIndex: 0, title: "一眼的代价"),
            .init(pageIndex: 1, title: "注意力为何成了稀缺资源"),
            .init(pageIndex: 2, title: "结论：把注意力当预算"),
        ]
        outlineState = .done
    }
}

// MARK: - 摘要 / 大纲面板

struct SummaryPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var summary: SummaryStore
    @EnvironmentObject var ocrStore: OCRStore

    var body: some View {
        VStack(spacing: 0) {
            actionBar
            noteStatusBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summaryBlock
                    outlineBlock
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    runSummary()
                } label: {
                    Label(summary.summaryState == .running ? "生成中…" : "生成整篇摘要",
                          systemImage: "text.append")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(summary.summaryState == .running || state.document == nil)

                Button {
                    runOutline()
                } label: {
                    Label(summary.outlineState == .running ? "生成中…" : "生成章节",
                          systemImage: "list.bullet.indent")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(summary.outlineState == .running || state.document == nil)
            }
            HStack(spacing: 5) {
                Image(systemName: "cpu").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(ai.askTargetDescription)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockTitle("整篇摘要", icon: "doc.text.magnifyingglass")
            switch summary.summaryState {
            case .idle:
                hint("让模型读完这份文档，给你一段导读：一句话概括 + 主要内容 + 值得注意的地方。\n扫描件会先看 OCR 结果。")
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在生成…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .failed(let why):
                Text(why).font(.system(size: 11))
                    .foregroundStyle(Design.danger)
            case .done:
                // 走极简 Markdown 分块：`## 标题`、`- 列表项` 要变成真正的
                // 标题和项目符号，直接 Text 会把符号原样印出来
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(MiniMarkdown.parse(summary.summary).enumerated()), id: \.offset) { _, b in
                        blockView(b)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button {
                        copy(summary.summary)
                    } label: { Label("复制", systemImage: "doc.on.doc").font(.system(size: 10)) }
                        .buttonStyle(.borderless)
                    Button {
                        export(summary.summary, suffix: "摘要")
                    } label: { Label("导出", systemImage: "square.and.arrow.up").font(.system(size: 10)) }
                        .buttonStyle(.borderless)
                    Spacer()
                }
            }
            if !summary.coverageNote.isEmpty {
                Text(summary.coverageNote)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var outlineBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            blockTitle("自动章节", icon: "list.bullet.indent")
            switch summary.outlineState {
            case .idle:
                hint("按每页的页首文字，让模型挑出真正另起一节的地方。\n生成后也会出现在「目录」里。")
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在分析…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            case .failed(let why):
                Text(why).font(.system(size: 11))
                    .foregroundStyle(Design.danger)
            case .done:
                ForEach(summary.outline) { item in
                    Button {
                        state.goToPage(item.pageIndex + 1)
                        state.saveLastPage()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(item.pageIndex + 1)")
                                .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24, alignment: .trailing)
                            Text(item.title)
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳到第 \(item.pageIndex + 1) 页，\(item.title)")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    // ---------- 零件 ----------

    @ViewBuilder private func blockView(_ b: MiniMarkdown.Block) -> some View {
        switch b {
        case .heading(let t):
            Text(t)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.top, 3)
        case .bullet(let t):
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 3.5, height: 3.5)
                Text(t)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .paragraph(let t):
            Text(t)
                .font(.system(size: 11))
                .lineSpacing(2.5)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 摘要/章节的保存状态条。
    ///
    /// 需求是"生成一次、以后不用重来"，那就得让用户**看见**它真的存下来了 ——
    /// 否则下次打开时突然出现一份摘要，用户会怀疑是不是自己记错了。
    /// 同时给一个删除入口（AI 内容可能不准，用户要能扔掉重来）。
    @ViewBuilder
    private var noteStatusBar: some View {
        VStack(spacing: 0) {
            if summary.loadedFromDisk, let at = summary.generatedAt {
                HStack(spacing: 5) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9))
                    Text("已保存 · 生成于 \(Self.dateText(at))")
                    Spacer(minLength: 0)
                    Button("重新生成") {
                        summary.discardNote()
                    }
                    .controlSize(.mini)
                    .help("丢弃这份摘要与章节，下次打开时不再显示")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
            // 模型换了才提示 —— 摘要还能看，只是不一定合当前口径
            if let stale = summary.staleSourceDescription {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text("这份是用「\(stale)」生成的，当前设置已不同")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
    }

    /// 「2026-10-04 09:20」这种形式。刻意**不显示年份之外的东西** ——
    /// 摘要笔记没有"精确到分"的价值，占一整行不值。
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: d)
    }

    private func blockTitle(_ t: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Color.accentColor)
            Text(t).font(.system(size: 11, weight: .semibold))
        }
    }

    private func hint(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ---------- 动作 ----------

    private func runSummary() {
        guard let doc = state.document else { return }
        summary.ocrText = { [weak ocr = ocrStore] i in ocr?.results[i]?.text ?? "" }
        summary.makeSummary(doc: doc, ai: ai, tasks: tasks, title: state.documentTitle)
    }

    private func runOutline() {
        guard let doc = state.document else { return }
        summary.ocrText = { [weak ocr = ocrStore] i in ocr?.results[i]?.text ?? "" }
        summary.makeOutline(doc: doc, ai: ai, tasks: tasks)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        state.showToast("已复制")
    }

    private func export(_ s: String, suffix: String) {
        ReaderActions.exportText(s, suggestedName: "\(state.documentTitle)-\(suffix)",
                                 fileExtension: "md", state: state, successToast: "已导出")
    }
}
