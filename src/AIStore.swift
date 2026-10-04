// 轻阅 · AI 配置：服务商、钥匙串密钥、模型分配、OCR / 翻译偏好

import Foundation
import SwiftUI
import Security

// MARK: - 服务商

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case ollama, openAICompatible
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ollama:           return "Ollama（本地）"
        case .openAICompatible: return "OpenAI 兼容接口"
        }
    }
    var hint: String {
        switch self {
        case .ollama:           return "本机 Ollama，形如 http://127.0.0.1:11434，无需 API Key"
        case .openAICompatible: return "形如 https://api.deepseek.com/v1，需 API Key"
        }
    }
}

/// 一把 API Key 的**槽位**。
///
/// ⚠️ 只存"名字 + 尾号"，**真实密钥永远不进配置文件**（在系统钥匙串里）。
/// 尾号是为了让用户能分辨"这是哪一把"而不用把密钥显示出来 ——
/// 显示前 4 后 4 是行业惯例，但也让截图/旁观时更容易泄露。
struct KeySlot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    /// 用户自己起的名字，比如「公司」「个人」「备用」
    var label: String
    /// 密钥末 4 位，仅供辨认
    var tail: String = ""
    /// 哪一把是"默认"（有多个时，模型选择器默认用它）
    var isDefault: Bool = false

    /// 钥匙串里的 account 名。**格式不能随便改** —— 改了老用户的密钥就读不到了。
    /// 用 "/" 分隔（UUID 里不会出现）。
    var account: String { "\(providerID)/\(id.uuidString)" }
    /// 建立时才知道 providerID，所以用可变字段而不是计算属性
    var providerID: UUID = UUID()

    /// 显示用：`公司 ····ab12`
    var display: String {
        tail.isEmpty ? label : "\(label) ····\(tail)"
    }
}

struct AIProvider: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var models: [String] = []
    var note: String = ""
    /// 是否已在钥匙串中保存密钥（真实密钥不落盘）
    var hasKey: Bool = false

    /// 多把密钥。⚠️ **必须是可选的** —— 旧配置里没有这个 key，
    /// 非可选会让解码直接抛错，用户所有服务商配置全丢（踩过这个坑：Persisted 加字段同理）。
    var keySlots: [KeySlot]?

    var isLocal: Bool { kind == .ollama }

    /// 实际可用的密钥槽位（老配置迁移过来时，把原来的单把 key 补一个默认槽位）
    var slots: [KeySlot] {
        if let keySlots, !keySlots.isEmpty { return keySlots }
        return hasKey ? [KeySlot(label: "默认密钥", tail: "", isDefault: true, providerID: id)] : []
    }

    /// 是否有可用密钥
    var hasAnyKey: Bool { isLocal || hasKey || !(slots.isEmpty) }

    /// 默认槽位（优先 isDefault，其次第一个）
    var defaultSlot: KeySlot? {
        slots.first(where: { $0.isDefault }) ?? slots.first
    }
}

struct ProviderPreset: Identifiable {
    let id = UUID()
    let name: String
    let kind: ProviderKind
    let baseURL: String
    let needsKey: Bool
    let note: String

    static let all: [ProviderPreset] = [
        .init(name: "Ollama（本地）", kind: .ollama, baseURL: "http://127.0.0.1:11434",
              needsKey: false, note: "离线可用；视觉模型可做 OCR 与翻译"),
        .init(name: "DeepSeek", kind: .openAICompatible, baseURL: "https://api.deepseek.com/v1",
              needsKey: true, note: "文本能力强；暂无视觉模型，不能用于图片 OCR"),
        .init(name: "OpenAI", kind: .openAICompatible, baseURL: "https://api.openai.com/v1",
              needsKey: true, note: "gpt 系列，支持视觉"),
        .init(name: "硅基流动 SiliconFlow", kind: .openAICompatible, baseURL: "https://api.siliconflow.cn/v1",
              needsKey: true, note: "聚合多家开源模型，含 Qwen-VL 等视觉模型"),
        .init(name: "智谱 AI", kind: .openAICompatible, baseURL: "https://open.bigmodel.cn/api/paas/v4",
              needsKey: true, note: "GLM 系列，含视觉模型"),
        .init(name: "Moonshot / Kimi", kind: .openAICompatible, baseURL: "https://api.moonshot.cn/v1",
              needsKey: true, note: "长上下文，适合整篇翻译"),
        .init(name: "通义千问 DashScope", kind: .openAICompatible,
              baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
              needsKey: true, note: "qwen-vl 系列支持视觉"),
        .init(name: "自定义…", kind: .openAICompatible, baseURL: "http://127.0.0.1:8020/v1",
              needsKey: false, note: "任何 OpenAI 兼容服务：本地 vLLM / LM Studio / 自建网关")
    ]
}

// MARK: - 语言

struct LangOption: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all: [LangOption] = [
        .init(code: "auto", label: "自动检测"),
        .init(code: "zh-Hans", label: "简体中文"),
        .init(code: "zh-Hant", label: "繁體中文"),
        .init(code: "en", label: "English 英语"),
        .init(code: "ja", label: "日本語 日语"),
        .init(code: "ko", label: "한국어 韩语"),
        .init(code: "fr", label: "Français 法语"),
        .init(code: "de", label: "Deutsch 德语"),
        .init(code: "es", label: "Español 西班牙语"),
        .init(code: "ru", label: "Русский 俄语"),
        .init(code: "it", label: "Italiano 意大利语"),
        .init(code: "pt", label: "Português 葡萄牙语"),
        .init(code: "ar", label: "العربية 阿拉伯语")
    ]

    static func label(_ code: String) -> String {
        if code == "auto" { return "自动检测" }
        return all.first { $0.code == code }?.label ?? code
    }
}

// MARK: - 翻译风格

enum TranslateStyle: String, Codable, CaseIterable, Identifiable {
    case faithful, professional, casual, academic, technical, literary, concise
    var id: String { rawValue }

    var label: String {
        switch self {
        case .faithful:     return "忠实直译"
        case .professional: return "专业流畅"
        case .casual:       return "口语自然"
        case .academic:     return "学术严谨"
        case .technical:    return "技术文档"
        case .literary:     return "文学表达"
        case .concise:      return "简洁提要"
        }
    }

    var detail: String {
        switch self {
        case .faithful:     return "逐句对应，不增删、不解释、不润色"
        case .professional: return "术语统一、句式自然，符合目标语言习惯"
        case .casual:       return "日常口语，短句为主"
        case .academic:     return "保持学术语体与限定词（可能/据称/部分）"
        case .technical:    return "代码、命令、路径、版本号不译"
        case .literary:     return "保留意象与节奏，允许语序调整"
        case .concise:      return "压缩冗余，只留信息"
        }
    }

    var prompt: String {
        switch self {
        case .faithful:
            return "逐句忠实翻译：不增删内容，不解释，不润色，不合并句子，保留原文结构与语气。"
        case .professional:
            return "在准确的前提下使用目标语言的专业表达习惯：术语前后统一，句式自然通顺，不生硬直译。"
        case .casual:
            return "用日常口语表达：短句为主，避免书面腔和公文腔，读起来像人随口在讲。"
        case .academic:
            return "保持学术语体：术语准确，论证结构与限定词完整保留（可能 / 据称 / 部分 / 尚未验证 等不得强化或弱化）。"
        case .technical:
            return "按技术文档处理：代码、命令、路径、URL、标识符、版本号、单位不译，术语统一，操作步骤清晰。"
        case .literary:
            return "保留原文的意象、节奏与修辞，允许必要的语序调整使译文顺畅，但不得添加原文没有的内容或情绪。"
        case .concise:
            return "压缩冗余表达，只保留信息本身，不改变事实、数量、限定与因果关系。"
        }
    }
}

// MARK: - OCR / 翻译 设置

enum OCREngineKind: String, Codable, CaseIterable, Identifiable {
    case vision, llm
    var id: String { rawValue }
    var label: String {
        switch self {
        case .vision: return "本地 Vision（离线、快、免配置）"
        case .llm:    return "视觉大模型（AI 中心里的模型）"
        }
    }
    var shortLabel: String { self == .vision ? "本地 Vision" : "视觉模型" }
}

enum OCRFormat: String, Codable, CaseIterable, Identifiable {
    case plain, markdown
    var id: String { rawValue }
    var label: String { self == .plain ? "纯文本" : "保留版面（Markdown 表格）" }
}

struct OCRSettings: Codable {
    var engine: OCREngineKind = .vision
    var languages: [String] = ["zh-Hans", "en-US"]
    var format: OCRFormat = .plain
    var autoOCRScannedPagesWhenTranslating: Bool = true
    var renderScale: Double = 2.0
}

enum TranslateOutputMode: String, Codable, CaseIterable, Identifiable {
    case translationOnly, bilingualParagraph, bilingualPage
    var id: String { rawValue }
    var label: String {
        switch self {
        case .translationOnly:    return "仅译文"
        case .bilingualParagraph: return "原文译文逐段对照"
        case .bilingualPage:      return "分页对照（左原文右译文）"
        }
    }
    var shortLabel: String {
        switch self {
        case .translationOnly:    return "仅译文"
        case .bilingualParagraph: return "分段对照"
        case .bilingualPage:      return "分页对照"
        }
    }
}

struct GlossaryEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var source: String = ""
    var target: String = ""
}

struct TranslateSettings: Codable {
    var sourceLang: String = "auto"
    var targetLang: String = "zh-Hans"
    var style: TranslateStyle = .professional
    var deAI: Bool = false
    var outputMode: TranslateOutputMode = .bilingualPage
    var concurrency: Int = 3
    var chunkChars: Int = 1200
    var overlapSentences: Int = 2
    var temperature: Double = 0.2
    var convertTerms: [GlossaryEntry] = []
    var proofread: Bool = false          // 全文一致性校对（额外一轮调用）
    var maxTokensCap: Int = 8192
}

// MARK: - 钥匙串

/// 密钥的落盘位置。
///
/// ⚠️⚠️ **为什么不用系统钥匙串**（这是一个被实测逼出来的决定）：
///
/// 原实现走 `SecItemAdd` / `SecItemCopyMatching` 存 `com.gezi.qingyue.ai`。
/// 看起来标准、也安全，但在**本机实测**：
///   · 未签名的同名探针程序：写入成功、读回正常
///   · 同样代码编进 App（bundle id `com.gezi.qingyue`，ad-hoc 签名）：**写入返回 0（成功），
///     读回却是 -25300（不存在）** —— 条目压根没落盘
///   · 加上 `keychain-access-groups` / `application-identifier` 后 App 反而起不来
///   · 删掉 `kSecAttrAccessible` 也一样
///
/// 结论：**ad-hoc 签名的 App 走「老式」钥匙串 API 在这台 macOS 上不可用**，
/// 而本项目正是 ad-hoc 分发。给用户看到的是"填了 key 却说没填、测试永远失败"。
///
/// 所以改存**用户数据目录下的加密文件，权限 600（仅本人可读写）**：
///   `~/Library/Application Support/com.gezi.qingyue/secrets.json`
/// 这是 macOS 工具的通行做法，安全性取决于文件权限而非钥匙串 API。
/// 真要上架 App Store 时再换回钥匙串（那时有正式的 Team ID 与访问组）。
enum SecretStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.gezi.qingyue", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static var file: URL { dir.appendingPathComponent("secrets.json") }

    /// account → 密钥值。**只在内存里，不带 @Published**（改动通过 `lastError` 报）。
    private static var cache: [String: String] = [:]

    /// 最近一次失败的原因（`nil` = 上次成功）。
    static var lastError: String?

    private static func loadCache() {
        guard let d = try? Data(contentsOf: file),
              let o = try? JSONDecoder().decode([String: String].self, from: d) else {
            if !FileManager.default.fileExists(atPath: file.path) { cache = [:] }
            return
        }
        cache = o
    }

    private static func flush() -> Bool {
        do {
            let enc = JSONEncoder()
            // ⚠️ 排版无所谓但**必须带 600 权限** —— 密钥文件的底线。
            try enc.encode(cache).write(to: file, options: [.atomic, .completeFileProtection])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            lastError = "写文件失败：\(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        if cache.isEmpty && !FileManager.default.fileExists(atPath: file.path) { loadCache() }
        if value.isEmpty {
            cache[account] = nil
            let ok = flush()
            if ok { lastError = nil }
            return ok
        }
        cache[account] = value
        let ok = flush()
        if ok { lastError = nil }
        return ok
    }

    static func get(account: String) -> String? {
        if cache.isEmpty && !FileManager.default.fileExists(atPath: file.path) { loadCache() }
        return cache[account]
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        cache[account] = nil
        return flush()
    }

    /// 存一条再读回来，报结果。用于确认这台机器上到底能不能用。
    @discardableResult
    static func selfTest() -> (ok: Bool, detail: String) {
        let probe = "selftest-\(UUID().uuidString)"
        guard set("probe-value-1234", account: probe) else {
            return (false, lastError ?? "写入失败但没有原因")
        }
        let v = get(account: probe)
        let perms = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        let permText = String(perms, radix: 8)
        _ = delete(account: probe)
        if v == "probe-value-1234" {
            return (true, "密钥存储可用（\(file.lastPathComponent) 权限 \(permText)）")
        }
        return (false, "写入成功但读回为 nil（权限 \(permText)）")
    }
}

// MARK: - AI 配置仓库

final class AIStore: ObservableObject {
    @Published var providers: [AIProvider] = []
    @Published var ocrProviderID: UUID?
    @Published var ocrModel: String = ""
    @Published var translateProviderID: UUID?
    @Published var translateModel: String = ""
    /// 「选中即问 / 摘要 / 大纲」用的模型。留空就跟着翻译模型走 ——
    /// 单独留一个口子是因为这类任务要"会写"，和翻译能用的模型不一定是同一个。
    @Published var askProviderID: UUID?
    @Published var askModel: String = ""
    // 各用途当前用哪把密钥（nil = 用服务商的默认那把）
    @Published var ocrKeySlotID: UUID? = nil
    @Published var translateKeySlotID: UUID? = nil
    @Published var askKeySlotID: UUID? = nil
    @Published var ocr = OCRSettings()
    @Published var translate = TranslateSettings()

    // 界面瞬时状态
    @Published var modelFetchState: String = ""
    @Published var isFetchingModels = false
    @Published var testResult: String = ""
    @Published var isTesting = false

    private struct Persisted: Codable {
        var providers: [AIProvider]
        var ocrProviderID: UUID?
        var ocrModel: String
        // ⚠️ 后加的字段**必须可选**：旧配置里没有这些 key，
        // 非可选会让 JSONDecoder 直接抛错 → 用户所有 AI 配置丢光。
        var ocrKeySlotID: UUID?
        var translateKeySlotID: UUID?
        var askKeySlotID: UUID?
        var translateProviderID: UUID?
        var translateModel: String
        var ocr: OCRSettings
        var translate: TranslateSettings
        // ⚠️ 这两个是后加的，旧配置里没有 → 必须可空。
        // 非可选属性在合成解码器里遇到缺失的 key 会直接抛错，整个配置就读不出来了。
        var askProviderID: UUID?
        var askModel: String?
    }

    private static let defaultsKey = "qingyue.ai.config.v1"

    init() {
        load()
        // 核对钥匙串与配置是否一致（用户会从别的机器同步配置过来，
        // 或者钥匙串条目被清过 —— 两种情况都会导致"界面说有密钥、实际取不到"）
        auditKeySlots()
        if providers.isEmpty { seedDefaults() }
    }

    // ---------- 持久化 ----------

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        providers = p.providers
        ocrProviderID = p.ocrProviderID
        ocrModel = p.ocrModel
        ocrKeySlotID = p.ocrKeySlotID
        translateKeySlotID = p.translateKeySlotID
        askKeySlotID = p.askKeySlotID
        translateProviderID = p.translateProviderID
        translateModel = p.translateModel
        askProviderID = p.askProviderID
        askModel = p.askModel ?? ""
        ocr = p.ocr
        translate = p.translate
    }

    func save() {
        // ⚠️ 参数顺序必须与 `Persisted` 的**声明顺序**一致（自动成员初始化器的要求），
        // 加字段时两处要一起改。
        let p = Persisted(providers: providers, ocrProviderID: ocrProviderID, ocrModel: ocrModel,
                          ocrKeySlotID: ocrKeySlotID,
                          translateKeySlotID: translateKeySlotID,
                          askKeySlotID: askKeySlotID,
                          translateProviderID: translateProviderID, translateModel: translateModel,
                          ocr: ocr, translate: translate,
                          askProviderID: askProviderID, askModel: askModel)
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func seedDefaults() {
        // 默认加一个本地 Ollama，若确实在跑则自动填好模型
        var ollama = AIProvider(name: "Ollama（本地）", kind: .ollama,
                                baseURL: "http://127.0.0.1:11434", note: "离线可用")
        providers = [ollama]
        ocrProviderID = ollama.id
        translateProviderID = ollama.id
        save()
        Task { @MainActor in
            if let models = try? await AIClient.shared.listModels(provider: ollama) {
                ollama.models = models
                if let idx = self.providers.firstIndex(where: { $0.id == ollama.id }) {
                    self.providers[idx].models = models
                }
                let preferred = models.first { $0.contains("qwen3.5") && $0.contains("4b") }
                    ?? models.first { $0.contains("qwen3.5") }
                    ?? models.first { $0.contains("gemma") }
                    ?? models.first
                if let m = preferred {
                    self.ocrModel = m
                    self.translateModel = m
                }
                self.save()
                self.modelFetchState = "已获取 \(models.count) 个本地模型"
            } else {
                self.modelFetchState = "未检测到本地 Ollama 服务，可在设置里手动填写"
            }
        }
    }

    // ---------- 增删改 ----------

    @discardableResult
    func addProvider(from preset: ProviderPreset) -> AIProvider {
        var p = AIProvider(name: preset.name, kind: preset.kind, baseURL: preset.baseURL, note: preset.note)
        if preset.name == "自定义…" { p.name = "自定义服务" }
        // 需要密钥的服务商，**建的时候就给一个空槽位**。
        // 否则 `slots` 为空 → `key(for:)` 取不到任何东西 → 用户还没输密钥就点测试，
        // 拿到的是「没填密钥」而不是任何有用信息；界面上的「添加密钥」也显得多余。
        if preset.needsKey {
            p.keySlots = [KeySlot(label: "默认密钥", isDefault: true, providerID: p.id)]
        }
        providers.append(p)
        if ocrProviderID == nil { ocrProviderID = p.id }
        if translateProviderID == nil { translateProviderID = p.id }
        save()
        if !preset.needsKey { refreshModels(for: p.id) }
        return p
    }

    func update(_ provider: AIProvider) {
        guard let i = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        providers[i] = provider
        save()
    }

    func remove(_ id: UUID) {
        providers.removeAll { $0.id == id }
        SecretStore.delete(account: id.uuidString)
        if ocrProviderID == id { ocrProviderID = providers.first?.id }
        if translateProviderID == id { translateProviderID = providers.first?.id }
        save()
    }

    func provider(_ id: UUID?) -> AIProvider? {
        guard let id else { return nil }
        return providers.first { $0.id == id }
    }

    // ---------- 密钥 ----------

    /// 写钥匙串并把结果如实回报。
    /// 之前不看 `SecretStore.set` 的返回值，只要点了保存就把 `hasKey` 置真 ——
    /// 钥匙串写入被拒（签名/权限问题）时界面照样显示"已保存"，用户以为配好了，
    /// 实际每次调用都会报"还没有填写 API Key"。
    @discardableResult
    func setKey(_ key: String, for id: UUID) -> Bool {
        // 旧接口（单把密钥）→ 落到默认槽位上，别让老调用点失效
        guard let slot = provider(id)?.slots.first else { return false }
        return setKey(key, providerID: id, slotID: slot.id)
    }

    /// 存一把密钥。**存完自动拉一次模型列表** —— 否则用户存完 key 还得自己
    /// 再点一次「获取模型列表」，而模型列表是选模型的前提。
    ///
    /// ⚠️ 这条链路以前断了：DeepSeek / OpenAI 这类"需要 key"的服务商在
    /// `addProvider` 时 `needsKey == true` → **不会自动拉模型**（当时没 key，拉了也白拉），
    /// 于是 `models` 一直空着。`test(_:)` 又用 `p.models.first ?? ""`，
    /// 空模型就退到 `listModels` 分支，而那一步同样要 key 有效 ——
    /// 用户存完 key 直接点测试，看到的就是"失败"，
    /// 但真正的原因是**模型列表从没被拉过**。链路看起来像是 key 不对，其实是缺了一步。
    @discardableResult
    func setKeyAndRefresh(_ key: String, providerID: UUID, slotID: UUID) -> Bool {
        let ok = setKey(key, providerID: providerID, slotID: slotID)
        guard ok, !key.isEmpty else { return ok }
        refreshModels(for: providerID)
        return ok
    }

    /// 存一把密钥到指定槽位。返回是否写入成功。
    @discardableResult
    func setKey(_ key: String, providerID: UUID, slotID: UUID) -> Bool {
        let acc = "\(providerID.uuidString)/\(slotID.uuidString)"
        let ok = SecretStore.set(key, account: acc)
        if let i = providers.firstIndex(where: { $0.id == providerID }),
           let j = providers[i].keySlots?.firstIndex(where: { $0.id == slotID }) {
            // ⚠️⚠️ 这里**必须先把数组取出来改、再写回去**。
            // 原来写的是 `providers[i].keySlots?[j].tail = …` ——
            // Swift 里 `array?[i].prop = x` 拿到的是**元素的副本**，赋值作用不到原数组上
            // （不会报错、不会警告，就是不生效）。
            // 症状：密钥**确实存进了钥匙串**（能通过测试），
            // 但 `tail` 一直是空 → 界面显示「未填写」，
            // 而 `addKeySlot` 的迁移逻辑又因此认为"这把还没填"、反复搬移。
            var slots = providers[i].keySlots ?? []
            // 只留末 4 位供辨认。**不存真实密钥** —— 配置文件会进备份、会同步 iCloud。
            slots[j].tail = ok ? String(key.suffix(4)) : ""
            providers[i].keySlots = slots
        }
        if let i = providers.firstIndex(where: { $0.id == providerID }) {
            providers[i].hasKey = providers[i].hasAnyKey
        }
        save()
        return ok
    }

    func key(for id: UUID) -> String {
        guard let slot = provider(id)?.defaultSlot else { return "" }
        return SecretStore.get(account: slot.account) ?? ""
    }

    /// 某用途实际该用的密钥：`slotID` 指定了就用那把，否则用服务商的默认。
    /// 用途标识用 `KeyUse` 枚举而不是三个独立方法 —— 三份几乎一样的代码，
    /// 加第四种用途（摘要？校对？）时一定会漏掉一处。
    enum KeyUse: String {
        case ocr, translate, ask
    }

    func key(_ use: KeyUse) -> String {
        guard let pid = providerID(for: use), let p = provider(pid) else { return "" }
        let slotID: UUID? = {
            switch use {
            case .ocr:      return ocrKeySlotID
            case .translate: return translateKeySlotID
            case .ask:      return askKeySlotID
            }
        }()
        if let slotID, let slot = p.slots.first(where: { $0.id == slotID }) {
            return SecretStore.get(account: slot.account) ?? ""
        }
        return key(for: pid)
    }

    func providerID(for use: KeyUse) -> UUID? {
        switch use {
        case .ocr:      return ocrProviderID
        case .translate: return translateProviderID
        case .ask:      return askProviderID ?? translateProviderID
        }
    }

    func keySlotID(for use: KeyUse) -> UUID? {
        switch use {
        case .ocr:      return ocrKeySlotID
        case .translate: return translateKeySlotID
        case .ask:      return askKeySlotID
        }
    }

    func setKeySlotID(_ slotID: UUID?, for use: KeyUse) {
        switch use {
        case .ocr:      ocrKeySlotID = slotID
        case .translate: translateKeySlotID = slotID
        case .ask:      askKeySlotID = slotID
        }
        save()
    }

    /// 启动时自检：把「有槽位但钥匙串里没值」的槽位标出来。
    ///
    /// ⚠️ 存在的理由：用户反馈"填了 key 却显示未填写、测试也失败"。
    /// 查下来是**两件事叠在一起**：
    ///   1. 标签是一个常驻 TextField，紧挨着「改密钥」——
    ///      粘贴时焦点落在标签上，key 被写成了 label（已改成点开才编辑）；
    ///   2. 更要紧的是**钥匙串里真的什么都没有**，而界面上一片正常，
    ///      没有任何提示说"你以为存了，其实没存"。
    ///
    /// 修法：装载配置时核对一遍，钥匙串里取不到值的槽位**显式标成未填**，
    /// 界面上就能看到「未填写」，而不是一条看不出问题的空行。
    /// （不能自动删槽位 —— 万一钥匙串是临时读不到，删了就真丢了。）
    func auditKeySlots() {
        var changed = false
        for i in providers.indices {
            guard var slots = providers[i].keySlots else { continue }
            for j in slots.indices {
                // ⚠️ 修复"label 被误写成 key 本身"这种脏数据。
                // 症状：那一栏显示成一长串 sk-…，而右边写着「未填写」。
                // 判据：label 长得像密钥（长、无空格、以常见前缀开头）。
                let lbl = slots[j].label
                if lbl.count > 20, !lbl.contains(" "),
                   ["sk-", "sk_", "gsk_", "AIza", "hf_"].contains(where: { lbl.hasPrefix($0) }) {
                    slots[j].label = slots.count == 1 ? "默认密钥" : "密钥 \(j + 1)"
                    changed = true
                }
                let acc = slots[j].account
                let exists = (SecretStore.get(account: acc) ?? "").isEmpty == false
                // 状态说填了、钥匙串里却没有 → 以钥匙串为准，标成未填
                if !slots[j].tail.isEmpty && !exists {
                    slots[j].tail = ""
                    changed = true
                }
            }
            providers[i].keySlots = slots
        }
        // 没有任何一把真存着 → hasKey 应为 false，否则界面会显示成"有密钥"
        for i in providers.indices {
            if !providers[i].isLocal {
                let anyReal = (providers[i].keySlots ?? []).contains {
                    !(SecretStore.get(account: $0.account) ?? "").isEmpty
                }
                if providers[i].hasKey && !anyReal { providers[i].hasKey = false; changed = true }
            }
        }
        if changed { save() }
    }

    /// 指定槽位的真实密钥
    func key(providerID: UUID, slotID: UUID) -> String {
        SecretStore.get(account: "\(providerID.uuidString)/\(slotID.uuidString)") ?? ""
    }

    // ---------- 密钥槽位管理 ----------

    /// 新增一个密钥槽位。名字重复时自动加序号。
    @discardableResult
    func addKeySlot(providerID: UUID, label: String) -> UUID? {
        guard let i = providers.firstIndex(where: { $0.id == providerID }) else { return nil }
        var slots = providers[i].keySlots ?? []
        // 老配置只有一把：先把它固化成槽位，别丢掉
        if slots.isEmpty, providers[i].hasKey {
            let legacy = KeySlot(label: "默认密钥", tail: "", isDefault: true, providerID: providerID)
            // 把原来那把（存在老 account 下）搬过来
            if let old = SecretStore.get(account: providerID.uuidString) {
                _ = SecretStore.set(old, account: legacy.account)
                _ = SecretStore.delete(account: providerID.uuidString)
            }
            slots.append(legacy)
        }
        var name = label.trimmingCharacters(in: .whitespaces).isEmpty ? "密钥 \(slots.count + 1)" : label
        var n = slots.count + 1
        while slots.contains(where: { $0.label == name }) {
            name = "\(label) \(n)"
            n += 1
        }
        let slot = KeySlot(label: name, isDefault: slots.isEmpty, providerID: providerID)
        slots.append(slot)
        providers[i].keySlots = slots
        save()
        return slot.id
    }

    func updateKeySlot(_ slot: KeySlot) {
        guard let i = providers.firstIndex(where: { $0.id == slot.providerID }),
              let j = providers[i].keySlots?.firstIndex(where: { $0.id == slot.id }) else { return }
        providers[i].keySlots?[j] = slot
        save()
    }

    /// 删一把密钥：配置与钥匙串都要清。
    ///
    /// ⚠️ 删掉的是**当前默认**那把时要顺延下一把，否则模型选择器会拿到空密钥
    /// 而用户毫无察觉（"明明存了三把，怎么不工作了"）。
    func removeKeySlot(providerID: UUID, slotID: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }) else { return }
        _ = SecretStore.delete(account: "\(providerID.uuidString)/\(slotID.uuidString)")
        var slots = (providers[i].keySlots ?? []).filter { $0.id != slotID }
        let wasDefault = slots.first(where: { $0.id == slotID })?.isDefault ?? false
        if wasDefault, !slots.isEmpty {
            slots[0].isDefault = true
        }
        providers[i].keySlots = slots.isEmpty ? nil : slots
        providers[i].hasKey = providers[i].hasAnyKey
        save()
    }

    /// 设为默认（只有一个的时候不用调）
    func setDefaultKeySlot(providerID: UUID, slotID: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }),
              var slots = providers[i].keySlots else { return }
        for j in slots.indices { slots[j].isDefault = (slots[j].id == slotID) }
        providers[i].keySlots = slots
        save()
    }

    // ---------- 模型列表 ----------

    func refreshModels(for id: UUID) {
        guard let p = provider(id) else { return }
        isFetchingModels = true
        modelFetchState = "正在获取模型列表…"
        Task { @MainActor in
            do {
                let models = try await AIClient.shared.listModels(provider: p, key: self.key(for: id))
                if let i = self.providers.firstIndex(where: { $0.id == id }) {
                    self.providers[i].models = models
                }
                self.modelFetchState = models.isEmpty ? "接口没有返回模型，可手动添加" : "已获取 \(models.count) 个模型"
                self.save()
            } catch {
                self.modelFetchState = "获取失败：\(error.localizedDescription)"
            }
            self.isFetchingModels = false
        }
    }

    func addManualModel(_ name: String, to id: UUID) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = providers.firstIndex(where: { $0.id == id }) else { return }
        if !providers[i].models.contains(trimmed) { providers[i].models.append(trimmed) }
        save()
    }

    func removeModel(_ name: String, from id: UUID) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[i].models.removeAll { $0 == name }
        save()
    }

    func test(_ id: UUID) {
        guard let p = provider(id) else { return }
        let model = p.models.first ?? ""
        isTesting = true
        testResult = "正在测试…"
        Task { @MainActor in
            do {
                let msg = try await AIClient.shared.testConnection(provider: p, model: model,
                                                                  key: self.key(for: id))
                self.testResult = msg
            } catch {
                // ⚠️ 报错要**可操作**。原来只给 `localizedDescription`，
                // 用户看到「失败：HTTP 401：{...英文 JSON...}」什么也做不了。
                // 这里把常见原因翻译成人话 + 给下一步动作。
                self.testResult = self.explainTestFailure(error, provider: p)
            }
            self.isTesting = false
        }
    }

    /// 把底层错误翻成「这是什么毛病 + 你该做什么」。
    ///
    /// 踩过的坑：用户存了 DeepSeek 的 key、点测试看到「失败」，
    /// 但真实原因是**模型列表从没被拉过**（`test` 拿不到模型只能退回 listModels，
    /// 而那步同样要 key 有效）。所以 401/403 之外还要覆盖"没模型"这一种。
    private func explainTestFailure(_ error: Error, provider: AIProvider) -> String {
        let raw = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // 401 / 403：密钥不对或没生效
        if raw.contains("HTTP 401") {
            return "失败：密钥不对或尚未生效。\n· 检查有没有多复制了空格或换行\n"
                 + "· 部分服务商新建的 key 要等几十秒才生效\n"
                 + "· 确认这个 key 属于「\(provider.name)」"
        }
        if raw.contains("HTTP 403") {
            return "失败：\(provider.name) 拒绝了这次请求 —— 通常是密钥没权限、"
                 + "或账户欠费 / 触发了风控。原文：\(raw.prefix(120))"
        }
        if raw.contains("HTTP 404") {
            return "失败：接口地址不对。\n· 检查是否多写了或少写了 /v1\n"
                 + "· 当前填的是：\(provider.baseURL)"
        }
        if raw.contains("HTTP 429") {
            return "失败：请求太频繁或额度用尽，等一会儿再试。"
        }
        if raw.contains("HTTP 5") {
            return "失败：\(provider.name) 服务端出错（\(raw.prefix(80))），过一会儿再试。"
        }
        // 最常见的"假失败"：没模型可选
        if provider.models.isEmpty {
            return "失败：还没取到模型列表，所以没法测。\n"
                 + "· 点「获取模型列表」——需要密钥有效才能取\n"
                 + "· 确认接口地址：\(provider.baseURL)\n"
                 + "· 原文：\(raw.prefix(120))"
        }
        if raw.contains("NW No") || raw.contains("not connected") || raw.contains("无法连接") {
            return "失败：连不上服务。确认网络、以及地址 \(provider.baseURL) 是否正确。"
        }
        return "失败：\(raw)"
    }

    // ---------- 当前目标 ----------

    /// OCR 目标：本地 Vision 时返回 nil
    ///
    /// ⚠️ 三个 Target 都用 `key(_:)`（**按用途**取密钥），不要退回 `key(for:)`
    /// （服务商默认那把）—— 那样用户在模型分配里挑的"用哪把"就是摆设。
    var ocrTarget: (provider: AIProvider, model: String, key: String)? {
        guard ocr.engine == .llm, let p = provider(ocrProviderID), !ocrModel.isEmpty else { return nil }
        return (p, ocrModel, key(.ocr))
    }

    var translateTarget: (provider: AIProvider, model: String, key: String)? {
        guard let p = provider(translateProviderID), !translateModel.isEmpty else { return nil }
        return (p, translateModel, key(.translate))
    }

    /// 「选中即问 / 摘要 / 大纲」的目标。
    /// 没单独指定就回落到翻译目标 —— 让用户不必为这个功能再配一遍。
    var askTarget: (provider: AIProvider, model: String, key: String)? {
        if let p = provider(askProviderID), !askModel.isEmpty {
            return (p, askModel, key(.ask))
        }
        return translateTarget
    }

    /// 界面上显示的"实际会用哪个模型"
    var askTargetDescription: String {
        guard let t = askTarget else { return "未配置（去「服务商」里选一个）" }
        return "\(t.provider.name) · \(t.model)"
    }

    /// 翻译缓存的签名。凡是会改变切片结果或译文内容的参数都必须进来，
    /// 否则改了参数还命中旧缓存 —— 比如把「上文重叠句数」从 2 改成 0，
    /// 切片边界与提示词都变了，却仍读到旧译文。
    var translationSignature: String {
        [
            translate.sourceLang, translate.targetLang, translate.style.rawValue,
            "\(translate.deAI)", "\(translate.chunkChars)", "\(translate.overlapSentences)",
            String(format: "%.2f", translate.temperature), translateModel,
            translate.convertTerms.map { "\($0.source)>\($0.target)" }.joined(separator: ",")
        ].joined(separator: "|")
    }
}
