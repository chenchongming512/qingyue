// 轻阅 · 阅读学习核心（书签存储、文档取样、大纲解析）
//
// 单独成文件、只依赖 Foundation / PDFKit，**不引 SwiftUI、不碰 AppState** ——
// 这样测试台可以直接编译它跑真值测试（`build/qy-tests` 的编译列表里没有界面文件）。
// 界面部分在 Bookmarks.swift 与 ReadingExtras.swift 里。

import Foundation
import PDFKit
import CryptoKit

// MARK: - 书签

/// 一条书签。和"记住上次读到第几页"不是一回事：
/// 那是自动的、每条文档只有一条；书签是用户主动标的、可以有很多条，还能带标题与备注。
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var pageIndex: Int          // 0-based
    var title: String
    var note: String = ""
    var createdAt = Date()
    /// 页内纵向位置（0 = 页底，1 = 页顶）。用来回到"大致那一块"，不指望像素级精确。
    var y: Double = 1.0
}

enum BookmarkStore {
    static let prefix = "qingyue.bookmarks."

    /// 书签跟着**文档路径**走。还没落盘的新文档（没有 fileURL）没有 key，只在内存里留着。
    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        return prefix + url.standardizedFileURL.path
    }

    static func decode(_ data: Data?) -> [Bookmark] {
        guard let data, let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return [] }
        return sorted(list)
    }

    static func encode(_ list: [Bookmark]) -> Data? {
        try? JSONEncoder().encode(list)
    }

    /// 一律按页码排序 —— 列表、导出、跳转都依赖这个顺序
    static func sorted(_ list: [Bookmark]) -> [Bookmark] {
        list.sorted { a, b in
            a.pageIndex != b.pageIndex ? a.pageIndex < b.pageIndex : a.createdAt < b.createdAt
        }
    }

    static func load(for url: URL?) -> [Bookmark] {
        guard let key = key(for: url) else { return [] }
        return decode(UserDefaults.standard.data(forKey: key))
    }

    static func save(_ list: [Bookmark], for url: URL?) {
        guard let key = key(for: url) else { return }
        if list.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        if let data = encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 默认标题：优先用该页首行文字（比"第 12 页"有用得多）
    static func defaultTitle(pageText: String?, pageIndex: Int) -> String {
        guard let text = pageText else { return "第 \(pageIndex + 1) 页" }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count > 1 }
        guard let line = firstLine else { return "第 \(pageIndex + 1) 页" }
        let trimmed = String(line.prefix(28))
        return trimmed + (line.count > 28 ? "…" : "")
    }

    /// 导出成 Markdown 读书笔记
    static func markdown(_ list: [Bookmark], title: String, dateFormat: String = "yyyy-MM-dd HH:mm") -> String {
        guard !list.isEmpty else { return "" }
        var out = "# \(title) · 书签\n\n"
        for b in sorted(list) {
            out += "- **第 \(b.pageIndex + 1) 页** · \(b.title)"
            if !b.note.isEmpty {
                out += "\n    > " + b.note.replacingOccurrences(of: "\n", with: "\n    > ")
            }
            out += "\n"
        }
        return out
    }
}

// MARK: - 文档取样（给"整篇摘要 / 自动章节"喂料）

enum PageSampler {

    /// 每页取开头一小段，拼成给模型看的"目录骨架"。
    /// 直接丢整篇文本会超上下文；页首那几行恰好是章节标题最可能出现的位置。
    static func pageDigest(_ doc: PDFDocument, ocrText: ((Int) -> String)? = nil,
                           perPage: Int = 70, maxPages: Int = 400) -> String {
        var lines: [String] = []
        let n = min(doc.pageCount, maxPages)
        for i in 0..<n {
            var text = doc.page(at: i)?.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let ocrText {
                text = ocrText(i)
            }
            let firstLine = text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            lines.append("\(i + 1)|\(String(firstLine.prefix(perPage)))")
        }
        return lines.joined(separator: "\n")
    }

    /// 整篇正文抽样（不超预算）。返回 (文本, 覆盖说明)
    static func bodySample(_ doc: PDFDocument, ocrText: ((Int) -> String)? = nil,
                           budget: Int = 14000) -> (text: String, note: String) {
        var pieces: [(Int, String)] = []
        for i in 0..<doc.pageCount {
            var t = doc.page(at: i)?.string ?? ""
            if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let ocrText { t = ocrText(i) }
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { pieces.append((i, clean)) }
        }
        guard !pieces.isEmpty else { return ("", "文档没有可读文本") }
        let total = pieces.reduce(0) { $0 + $1.1.count }
        if total <= budget {
            return (pieces.map(\.1).joined(separator: "\n\n"), "覆盖全部 \(pieces.count) 页")
        }
        let perPage = max(200, budget / max(1, pieces.count))
        let sampled = pieces.map { ($0.0, String($0.1.prefix(perPage))) }
        return (sampled.map(\.1).joined(separator: "\n\n"),
                "文档较长（约 \(total) 字），本摘要基于 \(sampled.count) 页每页前 \(perPage) 字的抽样")
    }
}

// MARK: - 自动大纲

/// AI 生成的章节条目。
///
/// ⚠️ `id` **刻意不编码**（CodingKeys 里不列它）—— 它只是个 SwiftUI 用的身份标识，
/// 每次解码都是新 UUID。如果把它编码进去，同一份 JSON 两次解码会得到**相同 id**，
/// 而 `OutlinePane` 用 `ForEach` 渲染时 id 撞车会漏渲染（不报错，界面少几行）。
/// 身份靠 `pageIndex + title` 就够唯一了。
struct AiOutlineItem: Identifiable, Hashable, Codable {
    public let id = UUID()
    var pageIndex: Int
    var title: String

    enum CodingKeys: String, CodingKey { case pageIndex, title }
}

enum OutlineParser {

    /// 容错解析模型输出：它经常带上序号、引号、`**`、或把分隔符写成全角。
    ///
    /// 约定格式是 `页码|标题`，但实际见到的花样包括：
    /// `- 12|系统设计` / `1. 12、系统设计` / `**12｜系统设计**` / 整段包在 ``` 里。
    /// 这里能救的都救，救不回来的行直接丢 —— 宁可少几条，也不要塞进错页码。
    static func parse(_ raw: String, pageCount: Int) -> [AiOutlineItem] {
        var out: [AiOutlineItem] = []
        var seen = Set<Int>()
        for rawLine in raw.split(separator: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }
            while let f = line.first, f == "-" || f == "*" || f == "•" || f == " " {
                line.removeFirst()
            }
            if let r = line.range(of: "^[0-9]+[.、)．]\\s*", options: .regularExpression) {
                line.removeSubrange(r)
            }
            let parts = line.split(whereSeparator: { $0 == "|" || $0 == "｜" })
            guard parts.count >= 2 else { continue }
            let pageStr = parts[0].trimmingCharacters(in: .whitespaces).filter { $0.isNumber }
            guard let page = Int(pageStr), page >= 1, page <= pageCount else { continue }
            var title = parts[1].trimmingCharacters(in: .whitespaces)
            title = title.replacingOccurrences(of: "**", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"'「」『』##"))
            guard !title.isEmpty, title.count <= 40 else { continue }
            let idx = page - 1
            guard !seen.contains(idx) else { continue }
            seen.insert(idx)
            out.append(AiOutlineItem(pageIndex: idx, title: title))
        }
        return out.sorted { $0.pageIndex < $1.pageIndex }
    }
}

// MARK: - 极简 Markdown 分块

/// 模型返回的摘要是 Markdown，但直接 `Text(...)` 显示的话
/// `## 一句话概括`、`- 列表项` 会连符号一起原样印出来 —— 看着像没渲染的日志。
/// 这里只解析摘要真正会用到的三种行（标题 / 列表项 / 普通段落），
/// 刻意**不引第三方 Markdown 库**：为了三行语法背一个依赖不值。
///
/// 单独放在核心文件里是为了能进测试台 —— 渲染错了要能测出来。
enum MiniMarkdown {
    enum Block: Equatable {
        case heading(String)   // `## 标题` / `### 小标题`
        case bullet(String)    // `- 项目` / `* 项目` / `1. 项目`
        case paragraph(String)

        /// 渲染时给不给左边距
        var indent: CGFloat {
            switch self {
            case .heading: return 0
            case .bullet:  return 13
            case .paragraph: return 0
            }
        }
    }

    /// 按行切块。空行只作分隔，不产出 `.paragraph("")`。
    static func parse(_ md: String) -> [Block] {
        var out: [Block] = []
        var buffer: [String] = []

        func flushParagraph() {
            guard !buffer.isEmpty else { return }
            out.append(.paragraph(buffer.joined(separator: " ")))
            buffer.removeAll()
        }

        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if let h = heading(in: line) {
                flushParagraph()
                out.append(.heading(h))
            } else if let b = bullet(in: line) {
                flushParagraph()
                out.append(.bullet(b))
            } else {
                // 段落内部按硬换行合并：模型给的正文常是每行一句，
                // 直接一行一个 Text 会碎成一片
                buffer.append(line)
            }
        }
        flushParagraph()
        return out
    }

    /// `#`~`######` 开头才算标题，井号后必须有内容（`#` 空行不是标题）。
    private static func heading(in line: String) -> String? {
        var hashes = 0
        while hashes < line.count, line[line.index(line.startIndex, offsetBy: hashes)] == "#" {
            hashes += 1
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let rest = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// `-` / `*` / `•` / `数字.` / `数字)` 开头。
    private static func bullet(in line: String) -> String? {
        for mark in ["- ", "* ", "• ", "+ "] {
            if line.hasPrefix(mark) {
                let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return rest.isEmpty ? nil : rest
            }
        }
        // 有序列表：只取"数字 + 句点/括号"，后面必须还有正文，
        // 否则「2026 年的数据」这种普通句子会被误判成列表项
        var digits = 0
        while digits < line.count, line[line.index(line.startIndex, offsetBy: digits)].isNumber {
            digits += 1
        }
        guard digits > 0, digits <= 3, digits + 1 < line.count else { return nil }
        let sep = line.index(line.startIndex, offsetBy: digits)
        let punct = line[sep]
        guard punct == "." || punct == ")" else { return nil }
        guard line.index(after: sep) < line.endIndex, line[line.index(after: sep)] == " " else { return nil }
        let rest = line.dropFirst(digits + 2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }
}


// MARK: - 浮动工具条的露出条件

/// 浮动批注工具条该不该显示。
///
/// ⚠️ 这条逻辑单独抽出来、放在可进测试台的核心文件里，原因有两个：
///   1. `AppState` 依赖 PDFView，测试台编不进来 → 逻辑留在那儿就测不到；
///   2. 它是「工具条不再遮挡正文」这条行为的**唯一守卫** ——
///      条件写错（比如把"常驻"改回来）没人会立刻发现，只会看到"字又被挡了"。
///
/// 条件（任一成立即显示）：
///   1. 页面里选了文字 —— 批注工具条的用武之地
///   2. 选中了某个工具 —— 工具条本身就是"当前工具"的可视化
///   3. 刚框选完一块区域、动作卡在等选择 —— 上下文相关
///   4. 正在朗读 —— 暂停 / 停止得能点到
///
/// 刻意**不做**的：不因为"鼠标在附近"就显示。工具条是操作，不是装饰；
/// 跟着光标飘的东西在阅读器里是干扰源（而且又得算一套悬停命中区）。
enum ToolbarVisibility {
    static func shouldShow(hasSelection: Bool,
                           tool: Tool,
                           hasPendingRegion: Bool,
                           speaking: Bool) -> Bool {
        hasSelection || tool != .select || hasPendingRegion || speaking
    }

    /// 加上「常驻模式」这个用户偏好后的最终结果。
    ///
    /// ⚠️ `always` 模式也要看 `hasDocument` —— 欢迎页没有文档时不该浮一条空工具条。
    static func shouldShow(mode: ToolbarMode,
                           hasDocument: Bool,
                           hasSelection: Bool,
                           tool: Tool,
                           hasPendingRegion: Bool,
                           speaking: Bool) -> Bool {
        if mode == .always { return hasDocument }
        return shouldShow(hasSelection: hasSelection, tool: tool,
                          hasPendingRegion: hasPendingRegion, speaking: speaking)
    }
}

/// 浮动工具条的露出方式。
///
/// - `auto`：有选区 / 选了工具 / 框选待处理 / 正在朗读时才浮现（默认）。
///   不遮挡正文，但用户得先选一下才知道工具条在。
/// - `always`：一直显示。看起来稳，但会压住页面底部两三行文字。
///
/// 做成枚举而不是 Bool：以后要加"仅朗读时"之类的第三种模式也不破坏存储格式
/// （`UserDefaults` 里存 rawValue，加 case 不会让旧值读不出来）。
/// 浮动工具条的露出方式。
///
/// - `auto`：有选区 / 选了工具 / 框选待处理 / 正在朗读时才浮现（默认）。
///   不遮挡正文，但用户得先选一下才知道工具条在。
/// - `always`：一直显示。看起来稳，但会压住页面底部两三行文字。
///
/// 做成枚举而不是 Bool：以后要加"仅朗读时"之类的第三种模式也不破坏存储格式
/// （`UserDefaults` 里存 rawValue，加 case 不会让旧值读不出来）。
enum ToolbarMode: String, CaseIterable, Identifiable {
    case auto, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:   return "按需浮现"
        case .always: return "始终显示"
        }
    }
    var icon: String {
        switch self {
        case .auto:   return "wand.and.stars"
        case .always: return "pin"
        }
    }
    var tip: String {
        switch self {
        case .auto:   return "工具条按需浮现（不遮挡正文）"
        case .always: return "工具条始终显示（会压住页面底部）"
        }
    }
}

// MARK: - 阅读工具

enum Tool: String, CaseIterable, Identifiable {
    case select, region, highlight, underline, strikeout, note, textbox, whiteout, erase
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .select:    return "cursorarrow"
        case .region:    return "crop"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .note:      return "text.bubble"
        case .textbox:   return "text.cursor"
        case .whiteout:  return "rectangle.fill"
        case .erase:     return "eraser"
        }
    }
    var label: String {
        switch self {
        case .select:    return "选择文字"
        case .region:    return "框选：识别 / 翻译这块区域"
        case .highlight: return "高亮"
        case .underline: return "下划线"
        case .strikeout: return "删除线"
        case .note:      return "便签"
        case .textbox:   return "文本框（拖出区域后输入）"
        case .whiteout:  return "涂白遮盖"
        case .erase:     return "橡皮（点击批注删除）"
        }
    }
    /// 需要用拖拽画矩形的工具
    var isDragTool: Bool {
        self == .region || self == .textbox || self == .whiteout
    }
}


// MARK: - 摘要 / 自动章节的持久化

/// 一份文档的「AI 阅读笔记」：整篇摘要 + 自动章节。
///
/// ⚠️ 为什么存 **Application Support** 而不是 Caches：
/// Caches 会被系统在空间紧张时清掉，摘要生成一次要几十秒、还花了 token，
/// 被静默清掉的话用户只会觉得"这软件怎么这么慢 / 老是要重新生成"。
/// Application Support 不会被系统自动清理（用户手动清缓存才会没），语义上更贴。
/// ⚠️ 刻意**不用 `enum` + 自定义 Codable**。
/// 踩过：`case v1(SummaryPayload)` 手写 `init(from:)` 时先 `container(keyedBy:)`
/// 读版本号、再拿**同一个 decoder** 调 `SummaryPayload(from: decoder)` ——
/// 两次解码抢同一个底层容器，写出来的 JSON 自己都读不回来（存盘报成功、读取全 nil）。
///
/// 改成扁平的 `struct`：版本号就是一个普通字段，`Codable` 合成器一次搞定，
/// 永远不会出这种"自己写自己读不回来"的问题。
/// 将来结构变了就把 `version` 提上去、`init(from:)` 里分派 —— 那时再自定义也来得及。
struct StudyNote: Codable {
    /// 版本号。1 = 初始结构。解出来不是 1 就当没有（用户重新生成一次即可）。
    var version: Int = 1
    var summary: String = ""
    var outline: [AiOutlineItem] = []
    var coverageNote: String = ""
    var sourceDescription: String = ""
    var generatedAt: Date = Date()

    init(payload: SummaryPayload) {
        version = 1
        summary = payload.summary
        outline = payload.outline
        coverageNote = payload.coverageNote
        sourceDescription = payload.sourceDescription
        generatedAt = payload.generatedAt
    }

    var payload: SummaryPayload {
        SummaryPayload(summary: summary, outline: outline, coverageNote: coverageNote,
                       sourceDescription: sourceDescription, generatedAt: generatedAt)
    }

    /// ⚠️ 必须手写解码，不能用合成器。
    ///
    /// 原因：**Swift 的属性默认值对 `Codable` 解码无效**。
    /// 合成解码器是 `decodeIfPresent` 之外的路径 —— 遇到 JSON 里缺失的 key
    /// 会直接抛 `keyNotFound`，**根本不会用 `= Date()` 这个默认值**。
    ///
    /// 后果很实际：将来给某个字段加了默认值、或者用户手里是结构更老的笔记文件，
    /// 解码就抛错 → `load` 返回 nil → **用户存的摘要"凭空消失"**，
    /// 而且没有任何提示（外面 catch 只 log 一行）。
    ///
    /// 全部用 `decodeIfPresent(... ) ?? 默认值`，缺字段就缺、不影响读出其余内容。
    /// 反过来编码仍用合成器（字段都有值，编码不会缺）。
    enum CodingKeys: String, CodingKey { case version, summary, outline, coverageNote,
                                        sourceDescription, generatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` 让"字段缺失"和"类型不对"都变成 nil，然后落到默认值。
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        outline = (try? c.decode([AiOutlineItem].self, forKey: .outline)) ?? []
        coverageNote = (try? c.decode(String.self, forKey: .coverageNote)) ?? ""
        sourceDescription = (try? c.decode(String.self, forKey: .sourceDescription)) ?? ""
        // 老文件没有这个字段。给纪元而不是 now —— 用 now 会误导成"刚刚生成"。
        generatedAt = (try? c.decode(Date.self, forKey: .generatedAt)) ?? Date(timeIntervalSince1970: 0)
    }
}

/// 摘要 + 章节的载荷。`summary` 允许为空（可能只生成了章节，反之亦然）。
struct SummaryPayload: Codable, Equatable {
    var summary: String = ""
    var outline: [AiOutlineItem] = []
    /// 抽样覆盖说明（"已覆盖全部 12 页"之类），要一起存否则会空着
    var coverageNote: String = ""
    /// 生成时用的模型标识，如 `Ollama (本地) · qwen3.5:4b-mix`。
    ///
    /// ⚠️ 为什么必须存：换了模型或语言后，**旧摘要就不再对应**了。
    /// 存下来是为了能告诉用户"这是用旧模型生成的，要重新生成吗"，
    /// 而不是默默给一份不对应当前设置的结论。
    var sourceDescription: String = ""
    /// 落盘时间（显示"生成于 …"）
    var generatedAt: Date = Date()

    var isEmpty: Bool { summary.isEmpty && outline.isEmpty }
}

/// 摘要 / 章节的磁盘存储。
///
/// 键 = 文档身份（`OCRCache.identity`：文件名 + 字节数 + mtime）。
/// ⚠️ **包含 mtime** 是有意的：文件被改过就该重新生成，旧摘要对不上新内容。
enum StudyNoteStore {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gezi.qingyue/studynotes", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func fileName(identity: String) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(40).description + ".json"
    }

    static func load(identity: String) -> SummaryPayload? {
        let url = dir.appendingPathComponent(fileName(identity: identity))
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            // ⚠️⚠️ **解码器必须跟编码器用同一个 dateEncodingStrategy**。
            // 踩过：上面 save 用 `.iso8601` 编，这里用默认策略解 ——
            // 两种策略不兼容，`generatedAt` 一定解不出来，整个解码抛错。
            // 症状极有欺骗性：**存盘返回 true、文件也确实写出来了**，
            // 只有 load 静默返回 nil（外层 catch 吞掉了错误，不打日志）。
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let note = try dec.decode(StudyNote.self, from: data)
            guard note.version == 1 else { return nil }   // 未来版本的读不了就当没有
            let p = note.payload
            return p.isEmpty ? nil : p
        } catch {
            // 解不出来（结构改过 / 文件损坏 / **日期策略不匹配**）就当没有，
            // 用户重新生成一次即可。刻意**不删文件**：留着它便于事后查为什么没读到。
            // ⚠️ 这条曾经静默了很久（存盘报成功、读取永远 nil），
            // 所以这里留一句诊断 —— 宁可吵一点，也不要"不报错但功能不工作"。
            NSLog("轻阅：AI 笔记读取失败（\(error.localizedDescription)）：\(url.lastPathComponent)")
            return nil
        }
    }

    @discardableResult
    static func save(_ payload: SummaryPayload, identity: String) -> Bool {
        let url = dir.appendingPathComponent(fileName(identity: identity))
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(StudyNote(payload: payload)).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func clear(identity: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName(identity: identity)))
    }

    /// 清掉全部（AI 中心里的"清除所有 AI 笔记"用）
    static func clearAll() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 已保存的笔记数量 + 占用空间（设置页显示"清缓存"时用）
    static func stats() -> (count: Int, bytes: Int64) {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        let bytes = items.reduce(Int64(0)) { acc, u in
            acc + Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (items.count, bytes)
    }
}
