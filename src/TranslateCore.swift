// 轻阅 · 翻译核心：分段切片、提示词构建、输出解析、接缝质检
// 本文件不依赖任何 UI，可单独编译做真值测试。

import Foundation

// MARK: - 数据结构

struct TranslateChunk: Identifiable, Hashable {
    let id: String          // 例如 p12-c3
    let pageIndex: Int      // 0 基
    let index: Int          // 页内第几片，0 基
    let text: String        // 本片待译原文
    let context: String?    // 上文参考（不翻译，仅用于衔接）
    let isContinuation: Bool

    var shortID: String { "第 \(pageIndex + 1) 页 · 第 \(index + 1) 片" }
}

enum SeamIssueKind: String {
    case empty        = "空结果"
    case truncated    = "可能的截断"
    case echoPrevious = "重复了上一片内容"
    case formatLeak   = "格式串泄漏"
    case untranslated = "疑似未翻译"
    case tooShort     = "长度严重偏短"
}

struct SeamIssue: Identifiable {
    var id: String { "\(chunk.id)-\(kind.rawValue)" }
    let chunk: TranslateChunk
    let kind: SeamIssueKind
    let detail: String
    var isRepairable: Bool { kind != .untranslated }
}

// MARK: - 文本切分

enum TextSplitter {

    /// 段落切分：优先空行；PDF 常把每行单独成行，因此再按「行尾有终止标点」做二级合并
    static func paragraphs(_ raw: String) -> [String] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }

        var result: [String] = []
        for block in text.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // 二级合并：把「不以终止标点结尾的短行」与下一行拼接
            var buffer = ""
            let lines = trimmed.components(separatedBy: "\n")
            for line in lines {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.isEmpty { continue }
                if buffer.isEmpty {
                    buffer = l
                } else if endsWithTerminal(buffer) {
                    result.append(buffer); buffer = l
                } else if buffer.count < 200 {
                    buffer += (isCJK(buffer.last) || isCJK(l.first)) ? l : " " + l
                } else {
                    result.append(buffer); buffer = l
                }
            }
            if !buffer.isEmpty { result.append(buffer) }
        }
        return result.isEmpty ? (raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [raw]) : result
    }

    /// 句子切分（中英混排；带常见缩写与小数保护）
    static func sentences(_ raw: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "；", "…", "!", "?", ";", ":", "：", "."]
        let closes: Set<Character> = ["”", "’", "」", "』", "）", ")", "\"", "'", "】"]
        let abbreviations = ["Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "etc.", "e.g.", "i.e.", "vs.",
                             "Fig.", "No.", "St.", "Inc.", "Ltd.", "Co.", "U.S.", "U.K.",
                             "a.m.", "p.m.", "Jan.", "Feb.", "Mar.", "Apr.", "Jun.", "Jul.",
                             "Aug.", "Sep.", "Sept.", "Oct.", "Nov.", "Dec."]

        var out: [String] = []
        var current = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            current.append(c)
            if terminators.contains(c) {
                // 吃掉后续的收尾符号
                while i + 1 < chars.count, closes.contains(chars[i + 1]) {
                    i += 1; current.append(chars[i])
                }
                // 英文缩写保护：末尾是 "X." 形式且是常见缩写
                let isAbbrev = abbreviations.contains { current.hasSuffix($0) } || current.hasSuffix("..")
                // 十进制数字保护：如 3.14
                let isDecimal = c == "." && i + 1 < chars.count && chars[i + 1].isNumber
                    && current.count >= 2 && chars[i - 1].isNumber
                // 英文句点后紧跟小写字母时，通常不是句末（如文件名 x.y、缩写未收录）
                let lowercaseFollows = c == "." && i + 1 < chars.count && chars[i + 1].isLetter
                    && chars[i + 1].isLowercase
                if !isAbbrev && !isDecimal && !lowercaseFollows {
                    out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
            } else if c == "\n" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    static func endsWithTerminal(_ s: String) -> Bool {
        guard let last = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return "。！？；…!?;.：「」“”\"'".contains(last)
    }

    static func isCJK(_ c: Character?) -> Bool {
        guard let c else { return false }
        return c.unicodeScalars.contains { $0.value >= 0x3000 && $0.value <= 0x9FFF }
    }

    static func lastSentences(_ text: String, count: Int) -> String? {
        guard count > 0 else { return nil }
        let sents = sentences(text)
        guard sents.count > 0 else { return nil }
        return sents.suffix(count).joined(separator: "")
    }

    /// 按目标字符数把一页文本切成若干片，绝不切开段落；超长段落按句子切
    static func chunks(forPage text: String, pageIndex: Int,
                       previousContext: String?, target: Int, overlapSentences: Int) -> [TranslateChunk] {
        let target = max(200, target)
        let paras = paragraphs(text)
        var groups: [(String, Bool)] = []   // (文本, 是否为长段切出来的续片)
        for p in paras {
            if p.count <= target * 3 / 2 {
                groups.append((p, false))
            } else {
                let sents = sentences(p)
                var buf = ""
                for s in sents {
                    if buf.isEmpty { buf = s }
                    else if buf.count + s.count <= target { buf += s }
                    else { groups.append((buf, false)); buf = s }
                }
                if !buf.isEmpty { groups.append((buf, false)) }
            }
        }

        var chunks: [TranslateChunk] = []
        var buffer = ""
        var bufferParas: [String] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            let idx = chunks.count
            let ctx: String?
            if idx == 0 {
                ctx = previousContext
            } else if overlapSentences > 0 {
                ctx = lastSentences(chunks[idx - 1].text, count: overlapSentences)
            } else { ctx = nil }
            chunks.append(TranslateChunk(id: "p\(pageIndex)-c\(idx)", pageIndex: pageIndex, index: idx,
                                         text: buffer, context: ctx, isContinuation: idx > 0))
            buffer = ""; bufferParas = []
        }
        for (g, _) in groups {
            if buffer.isEmpty {
                buffer = g; bufferParas = [g]
            } else if buffer.count + g.count + 1 <= target {
                buffer += "\n\n" + g; bufferParas.append(g)
            } else {
                flush(); buffer = g; bufferParas = [g]
            }
        }
        flush()
        return chunks
    }
}

// MARK: - 提示词

enum PromptBuilder {

    /// 去 AI 味硬约束（中文目标语言；规则取自 humanizer-zh 的编辑优先级与 31 条模式）
    static let deAIRulesZh = """
    译文必须读起来像人写的，遵守以下硬约束（违反即为不合格）：
    1. 不写铺垫与预告：不出现「让我们」「接下来」「值得注意的是」「综上所述」「总而言之」这类句子。
    2. 不用「不仅……更是……」式假对比抬高语气；不为了凑三项而排比；不靠破折号制造悬念（「——」「——」连环使用）。
    3. 不堆叠限定词（「也许可能大概或许」「在一定程度上或许可能」）；原文的不确定程度照搬，既不强化成确定，也不弱化成含糊。
    4. 不用空泛拔高词：赋能、至关重要、深度融合、全新范式、标志着新纪元、彰显了……的不懈追求。
    5. 不写客服腔与自问自答（「好问题」「希望这对你有帮助」「需要我帮你……吗」）。
    6. 不添加原文没有的事实、数字、名称、日期、来源与结论；否定、范围、条件、时间、完成状态、归因必须与原文一致（「可以提供」不等于「已提供」，「可能相关」不等于「导致」）。
    7. 不重复同一信息，不把连贯段落拆成要点清单，也不为变化句长硬拆或硬合。
    8. 中文正文用全角标点与「」或“”引号；原文中的代码、命令、路径、URL、专有名词与数字格式保持原样。
    """

    /// 英文目标的去 AI 味约束
    static let deAIRulesEn = """
    The translation must read as human-written English (violating these is a failure):
    1. No throat-clearing openers ("Let's dive in", "It's worth noting that", "In conclusion").
    2. No "It's not just X, it's Y" constructions; no decorative triads; no em-dash suspense chains.
    3. Do not stack hedges ("may perhaps possibly"); preserve the source's exact degree of certainty.
    4. No promotional uplift ("plays a vital role", "marks a new era", "underscores a commitment to").
    5. No assistant/polite filler ("Great question", "I hope this helps").
    6. Add no facts, numbers, names, dates, sources or conclusions absent from the source; keep negation, scope, conditions, tense/aspect and attribution identical.
    7. Do not restate the same information or split flowing prose into bullet lists.
    8. Keep code, commands, paths, URLs and identifiers untouched.
    """

    static func systemPrompt(_ s: TranslateSettings) -> String {
        var lines: [String] = []
        lines.append("你是专业的文档翻译引擎，把 PDF 文档翻译成目标语言。只输出译文，不解释、不寒暄、不评论。")
        lines.append("源语言：\(LangOption.label(s.sourceLang))；目标语言：\(LangOption.label(s.targetLang))。")
        if s.sourceLang == "auto" {
            lines.append("若原文已是目标语言，则原样输出，不要改写。")
        }
        lines.append("风格要求：\(s.style.prompt)")
        if s.deAI {
            let isZhTarget = s.targetLang.hasPrefix("zh")
            lines.append(isZhTarget ? deAIRulesZh : deAIRulesEn)
        }
        let terms = s.convertTerms.filter { !$0.source.trimmingCharacters(in: .whitespaces).isEmpty
            && !$0.target.trimmingCharacters(in: .whitespaces).isEmpty }
        if !terms.isEmpty {
            let table = terms.map { "「\($0.source)」→「\($0.target)」" }.joined(separator: "；")
            lines.append("术语表（必须严格采用，优先级最高）：\(table)。")
        }
        lines.append("""
        输出协议（必须遵守）：
        - 用户消息里 <CTX>…</CTX> 是上文参考，只用于保持人称、术语与语气连贯，绝对不要翻译它，也不要把它写进结果。
        - 待翻译内容在 <SRC>…</SRC> 内。
        - 你的回复必须把译文放在 <T></T> 标签里，除了该标签之外不要输出任何字符。
        - 不要输出原文，不要加「译文：」之类前缀，不要用代码块包裹，不要解释。
        - 保留原文的段落划分：原文一段，译文一段，段落间用空行分隔。
        - 原文中的公式、代码、命令、URL、引用编号、图表编号原样保留。
        """)
        if s.targetLang.hasPrefix("zh") {
            lines.append("标点使用中文全角；数字与英文专有名词保持原样。")
        }
        return lines.joined(separator: "\n")
    }

    static func userMessage(_ chunk: TranslateChunk) -> String {
        var parts: [String] = []
        if let ctx = chunk.context, !ctx.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("<CTX>\n\(ctx)\n</CTX>")
        }
        parts.append("""
        <SRC>
        \(chunk.text)
        </SRC>
        请只翻译 <SRC> 中的内容（共 \(chunk.text.count) 字符），译文放进 <T></T>。
        """)
        return parts.joined(separator: "\n\n")
    }

    /// 全文校对（第二遍）提示词
    static func proofreadSystemPrompt(_ s: TranslateSettings) -> String {
        systemPrompt(s) + "\n\n这是校对环节：只修正术语不一致、指代错误、与原文不符之处，保持原有译文风格，不要重写润色，不要新增内容。"
    }

    // MARK: 输出解析

    static func parse(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 代码块
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // <T>…</T>
        if let closeRange = t.range(of: "</T>", options: .backwards) {
            let head = t[..<closeRange.lowerBound]
            if let openRange = head.range(of: "<T", options: .backwards) {
                var body = String(head[openRange.upperBound...])
                if let gt = body.firstIndex(of: ">") { body = String(body[body.index(after: gt)...]) }
                t = body
            }
        }
        // 前缀残留
        for prefix in ["译文：", "译文:", "翻译：", "翻译:", "Translation:", "translated:"] {
            if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // 整体被成对引号包裹
        if t.count > 2 {
            let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("「", "」"), ("'", "'"), ("‘", "’"), ("《", "》")]
            if let f = t.first, let l = t.last, f != l || f == "\"" || f == "'" {
                if pairs.contains(where: { $0.0 == f && $0.1 == l }) {
                    t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return t
    }

    /// 简化协议（降级用）：不带任何标签与上文参考，只要求输出译文。小模型对长协议容易跑偏。
    static func simpleMessages(_ chunk: TranslateChunk, _ s: TranslateSettings) -> [ChatMessage] {
        var sys = "你是翻译引擎。把用户给的内容翻译成\(LangOption.label(s.targetLang))，只输出译文，不要解释，不要输出原文。\(s.style.prompt)"
        if s.deAI {
            sys += (s.targetLang.hasPrefix("zh") ? "译文要像人写的：不加铺垫、不堆限定词、不空泛拔高、不添加原文没有的信息。"
                                                 : "Write it like a human would: no filler openers, no stacked hedges, no added facts.")
        }
        return [.system(sys), .user(chunk.text)]
    }
}

// MARK: - 接缝质检

enum SeamCheck {

    static let terminalChars: Set<Character> = ["。", "！", "？", "…", "!", "?", "；", ";", ":", "：", ".", "、", ")", "）", "”", "」", "\"", "。"]

    /// 检查同一页内相邻分片的接缝是否正常
    static func check(source: [TranslateChunk], outputs: [String]) -> [SeamIssue] {
        var issues: [SeamIssue] = []
        for (i, chunk) in source.enumerated() {
            let out = i < outputs.count ? outputs[i] : ""
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            let src = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.isEmpty {
                issues.append(SeamIssue(chunk: chunk, kind: .empty, detail: "这一片没有返回任何内容"))
                continue
            }
            // 长度严重偏短
            if src.count > 60 && trimmed.count < max(12, src.count / 6) {
                issues.append(SeamIssue(chunk: chunk, kind: .tooShort,
                                        detail: "原文 \(src.count) 字符，译文仅 \(trimmed.count) 字符"))
            }
            // 截断
            if let lastSrc = src.last, terminalChars.contains(lastSrc),
               let lastOut = trimmed.last, !terminalChars.contains(lastOut) {
                issues.append(SeamIssue(chunk: chunk, kind: .truncated,
                                        detail: "原文以「\(lastSrc)」收尾，译文结尾是「\(lastOut)」"))
            }
            // 格式串泄漏
            for leak in ["<SRC>", "</SRC>", "<CTX>", "</CTX>", "<T>", "</T>"] where trimmed.contains(leak) {
                issues.append(SeamIssue(chunk: chunk, kind: .formatLeak, detail: "译文里残留 \(leak)"))
                break
            }
            // 与上一个非空邻片重复（中间有空结果时也要能发现回声）
            if i > 0 {
                let prev = nearestPreviousNonEmpty(outputs, before: i)
                if let dup = duplicatedPrefixLength(prev: prev, current: trimmed), dup >= 12 {
                    issues.append(SeamIssue(chunk: chunk, kind: .echoPrevious,
                                            detail: "开头约 \(dup) 个字符与上一片译文重复"))
                }
            }
            // 疑似未翻译（原文有明显拉丁/汉字差异时）
            if src.count > 30, normalized(src) == normalized(trimmed) {
                issues.append(SeamIssue(chunk: chunk, kind: .untranslated, detail: "译文与原文完全一致"))
            }
        }
        return issues
    }

    static func nearestPreviousNonEmpty(_ outputs: [String], before index: Int) -> String {
        var i = index - 1
        while i >= 0 {
            let t = outputs[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
            i -= 1
        }
        return ""
    }

    /// 上一片结尾与当前开头的最长重复长度（用于回显检测）
    static func duplicatedPrefixLength(prev: String, current: String) -> Int? {
        guard prev.count >= 8, current.count >= 8 else { return nil }
        let prevTail = String(prev.suffix(80))
        let maxCheck = min(current.count, 80)
        var best = 0
        for len in stride(from: maxCheck, through: 8, by: -1) {
            let candidate = String(current.prefix(len))
            if prevTail.hasSuffix(candidate) || prev.contains(candidate) {
                best = len
                break
            }
        }
        return best > 0 ? best : nil
    }

    /// 去掉与上一片重复的开头
    static func stripDuplicatedPrefix(_ current: String, previousTyped: String) -> (String, Bool) {
        guard let dup = duplicatedPrefixLength(prev: previousTyped, current: current), dup >= 12 else {
            return (current, false)
        }
        var rest = String(current.dropFirst(dup))
        rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return (current, false) }
        return (rest, true)
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { !$0.properties.isWhitespace }.map(String.init).joined()
    }
}

// MARK: - 退化输出判定（本地小模型常见：空回复、复述要求、只输出标签）

enum Degenerate {

    /// 返回退化原因，nil 表示看起来正常
    static func reason(output: String, source: String, targetLang: String? = nil) -> String? {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "空回复" }
        let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let srcLen = max(1, src.count)

        // 把要求复述出来了
        let echoMarkers = ["用户要求", "目标语言", "风格要求", "输出协议", "硬约束",
                           "Translation:", "translate the", "以下是翻译", "翻译如下"]
        for m in echoMarkers where t.contains(m) {
            return "把要求或说明当成了译文（命中「\(m)」）"
        }
        // 只吐了协议标签或占位内容
        if t.count < 60 {
            for token in ["<CTX", "<SRC", "</T", "None"] where t.contains(token) {
                return "只输出了协议标签或占位内容（\(token)）"
            }
        }
        // 长度严重不符
        if srcLen > 40, t.count < max(8, srcLen / 8) { return "长度严重偏短（\(t.count)/\(srcLen)）" }
        if t.count > srcLen * 6 { return "长度异常偏长（\(t.count)/\(srcLen)）" }

        // 与原文几乎一致（真正的“没翻译”）
        let a = normalized(src), b = normalized(t)
        if srcLen > 30, a == b { return "与原文完全相同，没有翻译" }

        // 目标语言检查
        let outCJK = cjkRatio(t)
        if let target = targetLang {
            if target.hasPrefix("zh"), srcLen > 20, outCJK < 0.15 {
                return "目标语言是中文，但译文里几乎没有中文"
            }
            if !target.hasPrefix("zh"), target != "auto", srcLen > 20, cjkRatio(src) > 0.5, outCJK > 0.35 {
                return "目标语言不是中文，但译文仍以中文为主"
            }
        }
        return nil
    }

    static func needsSimplifiedRetry(output: String, source: String, targetLang: String? = nil) -> Bool {
        reason(output: output, source: source, targetLang: targetLang) != nil
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { !$0.properties.isWhitespace }.map(String.init).joined()
    }

    private static func cjkRatio(_ s: String) -> Double {
        let scalars = s.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard !scalars.isEmpty else { return 0 }
        let cjk = scalars.filter { ($0.value >= 0x4E00 && $0.value <= 0x9FFF) || ($0.value >= 0x3000 && $0.value <= 0x303F) }.count
        return Double(cjk) / Double(scalars.count)
    }
}
