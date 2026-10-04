// 轻阅 · AI 中心：服务商、密钥、模型分配、OCR 与翻译偏好

import SwiftUI
import AppKit

struct AICenterView: View {
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var tasks: TaskCenter
    @State private var tab: Tab = .providers

    enum Tab: String, CaseIterable, Identifiable {
        case providers, models, ocr, translate, about
        var id: String { rawValue }
        var label: String {
            switch self {
            case .providers: return "服务商"
            case .models:    return "模型分配"
            case .ocr:       return "OCR 设置"
            case .translate: return "翻译设置"
            case .about:     return "关于"
            }
        }
        var icon: String {
            switch self {
            case .providers: return "server.rack"
            case .models:    return "cpu"
            case .ocr:       return "text.viewfinder"
            case .translate: return "character.book.closed"
            case .about:     return "info.circle"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左栏
            VStack(alignment: .leading, spacing: 2) {
                Text("AI 中心")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                ForEach(Tab.allCases) { t in
                    Button {
                        withAnimation(Design.animQuick) { tab = t }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: t.icon)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18)
                            Text(t.label).font(.system(size: 13, weight: tab == t ? .semibold : .regular))
                            Spacer()
                        }
                        .foregroundStyle(tab == t ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(tab == t ? Color.accentColor : Color.primary.opacity(0.0001)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }
                Spacer()
                if !tasks.active.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(tasks.active.count) 个任务进行中")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .frame(width: 176)
            .background(VisualEffectBg().ignoresSafeArea())

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .providers: ProvidersPane()
                    case .models:    ModelsPane()
                    case .ocr:       OCRSettingsPane()
                    case .translate: TranslateSettingsPane()
                    case .about:     AboutPane()
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        // 截图通道：直接落到某个标签页。
        // ⚠️ 这个面板的关键内容（服务商密钥、模型分配）默认在第一页，
        // 截图脚本不切页就只能截到第一页 —— 加通道比让脚本去点 UI 稳。
        //
        // 必须挂在 `onAppear` 上，**不能写在 `body` 里直接改 @State** ——
        // 那样改动发生在本次渲染过程中，不会触发新的渲染，
        // 结果就是"切了但没生效"（实测：两张截图字节数完全相同）。
        .onAppear { applyLaunchTab() }
        .onDisappear { ai.save() }
    }

    /// 幂等（`onAppear` 会触发多次）。
    private func applyLaunchTab() {
        guard let raw = LaunchOptions.aiTab, let target = Tab(rawValue: raw) else { return }
        guard tab != target else { return }
        tab = target
    }
}

// MARK: - 通用组件

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct FieldRow<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12))
                if let hint { Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            .frame(width: 128, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

struct Chip: View {
    let text: String
    var selected: Bool = false
    var action: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 11, weight: .medium))
            if let onDelete {
                Button { onDelete() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.10)))
        .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.8))
        .contentShape(Capsule())
        .onTapGesture { action?() }
    }
}

// MARK: - 服务商

struct ProvidersPane: View {
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var state: AppState
    @State private var editingID: UUID?
    @State private var draftKey: String = ""
    @State private var newModel: String = ""
    @State private var showPresets = false
    /// 刚存过密钥的服务商。AI 中心是独立窗口，主窗口的提示条根本看不到，所以在这里就地反馈
    @State private var keyJustSaved: UUID?
    /// 钥匙串写入失败要如实显示：之前无论成败都提示「已存入」，
    /// 用户带着一个空 Key 去翻译，只会拿到「还没有填写 API Key」。
    @State private var keySaveFailed = false
    /// 正在编辑哪一把密钥的输入框。**按槽位 ID 记**，不能按服务商 ID ——
    /// 那样同一服务商的两个槽位会共用一个输入框，存 A 的内容却写进 B。
    @State private var editingKeySlotID: UUID?
    /// 密钥写入失败的具体原因。
    /// ⚠️ 不能只说"请检查系统权限"—— -34018（没签名）和 -25293（用户拒绝）
    /// 是完全不同的两件事，笼统提示等于让人瞎猜。
    @State private var keySaveFailureDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("服务商").font(.system(size: 18, weight: .bold))
                Spacer()
                Menu {
                    ForEach(ProviderPreset.all) { p in
                        Button {
                            let created = ai.addProvider(from: p)
                            editingID = created.id
                        } label: {
                            Text("\(p.name)\(p.needsKey ? " · 需密钥" : " · 免密钥")")
                        }
                    }
                } label: {
                    Label("添加服务商", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if ai.providers.isEmpty {
                Text("还没有服务商。点右上角「添加服务商」，本地 Ollama 与常见云服务都有预置模板。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            ForEach(ai.providers) { p in
                section(for: p)
            }
        }
        .onAppear { if editingID == nil { editingID = ai.providers.first?.id } }
    }

    @ViewBuilder
    private func section(for provider: AIProvider) -> some View {
        let binding = Binding<AIProvider>(
            get: { ai.providers.first { $0.id == provider.id } ?? provider },
            set: { ai.update($0) }
        )
        let expanded = editingID == provider.id

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(provider.hasKey || provider.isLocal ? Design.success : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Text(provider.kind.label).font(.system(size: 11)).foregroundStyle(.secondary)
                if !provider.models.isEmpty {
                    Text("\(provider.models.count) 个模型").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    withAnimation(Design.animQuick) { editingID = expanded ? nil : provider.id }
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    FieldRow(label: "名称") {
                        TextField("", text: binding.name).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    FieldRow(label: "协议") {
                        Picker("", selection: binding.kind) {
                            ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().frame(width: 220)
                        Text(provider.kind.hint).font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    FieldRow(label: "接口地址", hint: "含版本路径，如 /v1") {
                        TextField("", text: binding.baseURL).textFieldStyle(.roundedBorder).frame(width: 320)
                    }
                    if !provider.isLocal {
                        keySlotsSection(for: provider)
                    }
                    FieldRow(label: "操作") {
                        HStack(spacing: 8) {
                            Button(ai.isFetchingModels ? "获取中…" : "获取模型列表") { ai.refreshModels(for: provider.id) }
                                .controlSize(.small).disabled(ai.isFetchingModels)
                            Button(ai.isTesting ? "测试中…" : "测试连接") { ai.test(provider.id) }
                                .controlSize(.small).disabled(ai.isTesting)
                            Button(role: .destructive) { ai.remove(provider.id) } label: { Text("删除服务商") }
                                .controlSize(.small)
                        }
                    }
                    if !ai.testResult.isEmpty {
                        Text(ai.testResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !ai.modelFetchState.isEmpty {
                        Text(ai.modelFetchState).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    // 模型区永远显示（原来写着 `!provider.models.isEmpty || true`，
                    // 条件恒真，等于没写；模型为空时反而更需要手动添加入口）
                    Divider().padding(.vertical, 2)
                    Text("模型（点选可设为当前用途）").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if provider.models.isEmpty {
                        Text("还没有模型。点「获取模型列表」，或手动填写模型名。")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    FlowRow(items: provider.models) { m in
                        Chip(text: m,
                             selected: ai.ocrModel == m || ai.translateModel == m,
                             action: {
                                 if ai.ocrProviderID == provider.id { ai.ocrModel = m }
                                 if ai.translateProviderID == provider.id { ai.translateModel = m }
                                 ai.save()
                             },
                             onDelete: { ai.removeModel(m, from: provider.id) })
                    }
                    HStack(spacing: 6) {
                        TextField("手动添加模型名，如 qwen3.5:4b-mlx", text: $newModel)
                            .textFieldStyle(.roundedBorder).frame(width: 260)
                        Button("添加") {
                            ai.addManualModel(newModel, to: provider.id)
                            newModel = ""
                        }.controlSize(.small)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            expanded ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
    }

    // MARK: - 多把 API Key

    /// 一个服务商的密钥管理区。
    ///
    /// 需求是「可以保存多把、按任务挑」——比如同一个服务有两张卡（公司 / 个人），
    /// 或者主账号额度用完了切备用。实现是**槽位**：配置里存槽位（名字 + 末 4 位），
    /// 真实密钥在系统钥匙串（account = `服务商UUID/槽位UUID`）。
    ///
    /// ⚠️ 为什么只显示末 4 位：配置文件会进 Time Machine、会同步到别的 Mac。
    /// 真实密钥不落盘是这个方案的底线，尾号只够用户分辨"这是哪一把"。
    @ViewBuilder
    private func keySlotsSection(for provider: AIProvider) -> some View {
        let slots = provider.slots
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("API Key")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .leading)
                Text("可存多把，默认那把会被自动使用；密钥存在你自己的用户目录里（仅本人可读）")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button {
                    _ = ai.addKeySlot(providerID: provider.id, label: "")
                } label: { Label("添加密钥", systemImage: "plus") }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }

            if slots.isEmpty {
                Text("还没有密钥。点「添加密钥」存第一把。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.leading, 52)
            }

            ForEach(slots) { slot in
                keySlotRow(slot, provider: provider)
            }

            if keySaveFailed {
                // ⚠️ 把**真实原因**显示出来。原来只有一句笼统的"请检查系统权限"，
                // 而 -34018（App 没签名/签名变了）和 -25293（用户拒绝了授权弹窗）
                // 完全是两回事，用户只能瞎猜。
                VStack(alignment: .leading, spacing: 2) {
                    Label("密钥没存上", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                    if let d = keySaveFailureDetail {
                        Text(d)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                    .padding(.leading, 52)
            }
        }
    }

    /// 一把密钥的一行。
    ///
    /// ⚠️⚠️ 这里**只有密钥输入框，没有任何"名字"输入框**。
    ///
    /// 这是用户明确要求的（「密钥1之类的名字就不要自定义设置了，直接就输入密钥」），
    /// 但更重要的是它**修掉了一个真实的 bug**：
    /// 原来标签是一个可编辑 TextField，紧挨着「改密钥」。
    /// 用户点「改密钥」准备粘贴时焦点有时还落在标签框上 →
    /// key 被写成了 label，界面显示「未填写」，而钥匙串里什么都没有。
    /// 少一个输入框就从根上消除了误输入的可能。
    ///
    /// 名字仍会自动生成（"默认密钥" / "密钥 2"），只用于界面显示与区分，不需用户操心。
    @ViewBuilder
    private func keySlotRow(_ slot: KeySlot, provider: AIProvider) -> some View {
        HStack(spacing: 6) {
            if editingKeySlotID == slot.id {
                SecureField("在这里粘贴 API Key", text: $draftKey)
                    .textFieldStyle(.roundedBorder).frame(width: 300)
                    .onSubmit { commitKey(slot, provider: provider) }
                Button("保存") { commitKey(slot, provider: provider) }
                    .controlSize(.small)
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消") {
                    draftKey = ""
                    editingKeySlotID = nil
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            } else {
                Image(systemName: slot.isDefault ? "checkmark.seal.fill" : "key")
                    .font(.system(size: 11))
                    .foregroundStyle(slot.isDefault ? Design.success : Color.secondary)
                    .help(slot.isDefault ? "默认密钥" : "点「设为默认」改用这把")
                // 只显示名字与末 4 位，**不可编辑**（要改名不如重建一把）
                Text(slot.display)
                    .font(.system(size: 12))
                    .frame(minWidth: 130, alignment: .leading)
                    .help("名字由轻阅自动生成，只用于区分多把密钥")
                if !slot.isDefault {
                    Button("设为默认") { ai.setDefaultKeySlot(providerID: provider.id, slotID: slot.id) }
                        .controlSize(.small).buttonStyle(.borderless)
                }
                if keyJustSaved == provider.id {
                    Label("已存入", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundStyle(Design.success)
                }
                Spacer(minLength: 0)
                Button("输入密钥") {
                    draftKey = ""
                    editingKeySlotID = slot.id
                }
                .controlSize(.small).buttonStyle(.borderless)
                if !slot.tail.isEmpty {
                    Button(role: .destructive) {
                        ai.removeKeySlot(providerID: provider.id, slotID: slot.id)
                        if editingKeySlotID == slot.id { editingKeySlotID = nil }
                    } label: { Image(systemName: "trash") }
                        .controlSize(.small).buttonStyle(.borderless)
                        .help("删除这把密钥")
                }
            }
        }
        .padding(.leading, 52)
    }

    /// 保存这把密钥，并如实报告结果。
    ///
    /// ⚠️ 失败时**必须把钥匙串的原始原因显示出来** ——
    /// `errSecMissingEntitlement`（没签名/签名变了）和 `errSecAuthFailed`
    /// （用户拒绝授权）是完全不同的两件事，笼统说"请检查系统权限"等于让人瞎猜。
    /// macOS 上用 ad-hoc 签名的 App 尤其容易撞上 -34018。
    private func commitKey(_ slot: KeySlot, provider: AIProvider) {
        let k = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        let ok = ai.setKeyAndRefresh(k, providerID: provider.id, slotID: slot.id)
        keySaveFailed = !ok
        if !ok { keySaveFailureDetail = SecretStore.lastError }
        guard ok else { return }
        draftKey = ""
        editingKeySlotID = nil
        keyJustSaved = provider.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if keyJustSaved == provider.id { keyJustSaved = nil }
        }
    }

}

/// 自动换行的芯片容器
struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let rows = chunk(items, per: 3)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in content(item) }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chunk(_ arr: [Item], per: Int) -> [[Item]] {
        stride(from: 0, to: arr.count, by: per).map { Array(arr[$0..<min($0 + per, arr.count)]) }
    }
}

// MARK: - 模型分配

struct ModelsPane: View {
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型分配").font(.system(size: 18, weight: .bold))

            SectionCard(title: "OCR 使用哪个引擎",
                        subtitle: "本地 Vision 离线、快、免配置，适合印刷体；视觉大模型更适合复杂版面、手写与表格") {
                Picker("", selection: $ai.ocr.engine) {
                    ForEach(OCREngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: ai.ocr.engine) { ai.save() }

                if ai.ocr.engine == .llm {
                    Divider()
                    providerModelPicker(title: "视觉模型",
                                        providerID: $ai.ocrProviderID,
                                        model: $ai.ocrModel,
                                        requireVision: true, keyUse: .ocr)
                }
            }

            SectionCard(title: "翻译使用哪个模型",
                        subtitle: "长文档建议选上下文长的模型；本地模型不产生费用") {
                providerModelPicker(title: "翻译模型",
                                    providerID: $ai.translateProviderID,
                                    model: $ai.translateModel,
                                    requireVision: false, keyUse: .translate)
                HStack(spacing: 8) {
                    Button(ai.isTesting ? "测试中…" : "测试连接") {
                        if let id = ai.translateProviderID { ai.test(id) }
                    }
                    .controlSize(.small).disabled(ai.isTesting)
                    if !ai.testResult.isEmpty {
                        Text(ai.testResult).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }

            SectionCard(title: "AI 助手使用哪个模型",
                        subtitle: "「选中即问」「整篇摘要」「自动章节」共用这一个。留空就跟着翻译模型走") {
                providerModelPicker(title: "助手模型",
                                    providerID: $ai.askProviderID,
                                    model: $ai.askModel,
                                    requireVision: false, keyUse: .ask)
                HStack(spacing: 8) {
                    Text("实际生效：\(ai.askTargetDescription)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if ai.askProviderID != nil || !ai.askModel.isEmpty {
                        Button("跟随翻译模型") {
                            ai.askProviderID = nil
                            ai.askModel = ""
                            ai.save()
                        }
                        .controlSize(.small)
                    }
                }
            }

            SectionCard(title: "当前生效", subtitle: "改完立即生效，无需重启") {
                HStack(spacing: 16) {
                    Label {
                        Text("OCR：" + (ai.ocr.engine == .vision ? "本地 Vision"
                              : "\(ai.provider(ai.ocrProviderID)?.name ?? "未选") · \(ai.ocrModel.isEmpty ? "未选模型" : ai.ocrModel)"))
                            .font(.system(size: 12))
                    } icon: { Image(systemName: "text.viewfinder").foregroundStyle(Color.accentColor) }
                    Label {
                        Text("翻译：\(ai.provider(ai.translateProviderID)?.name ?? "未选") · \(ai.translateModel.isEmpty ? "未选模型" : ai.translateModel)")
                            .font(.system(size: 12))
                    } icon: { Image(systemName: "character.book.closed").foregroundStyle(Color.accentColor) }
                    Label {
                        Text("助手：\(ai.askTargetDescription)")
                            .font(.system(size: 12))
                    } icon: { Image(systemName: "sparkles").foregroundStyle(Color.accentColor) }
                }
            }
        }
    }

    @ViewBuilder
    private func providerModelPicker(title: String, providerID: Binding<UUID?>,
                                     model: Binding<String>, requireVision: Bool,
                                     keyUse: AIStore.KeyUse? = nil) -> some View {
        let models = ai.provider(providerID.wrappedValue)?.models ?? []
        FieldRow(label: title) {
            Picker("", selection: providerID) {
                Text("未选择").tag(UUID?.none)
                ForEach(ai.providers) { p in Text(p.name).tag(Optional(p.id)) }
            }
            .labelsHidden().frame(width: 200)

            Picker("", selection: model) {
                Text("未选择模型").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(width: 240)
            .onChange(of: providerID.wrappedValue) {
                if let id = providerID.wrappedValue, let first = ai.provider(id)?.models.first,
                   !(ai.provider(id)?.models.contains(model.wrappedValue) ?? false) {
                    model.wrappedValue = first
                }
                // 换服务商时该用途的密钥选择要重置 —— 槽位是挂在服务商下的，
                // 留着上一个服务商的 slotID 会指向一把不存在的钥匙。
                if let use = keyUse { ai.setKeySlotID(nil, for: use) }
                ai.save()
            }
            .onChange(of: model.wrappedValue) { ai.save() }
        }
        // 密钥选择：只有该服务商存了多把时才显示（只有一把没得选）
        if let use = keyUse, let p = ai.provider(providerID.wrappedValue), p.slots.count > 1 {
            FieldRow(label: "") {
                Picker("", selection: Binding(
                    get: { ai.keySlotID(for: use) },
                    set: { ai.setKeySlotID($0, for: use) })) {
                    Text("默认密钥（\(p.defaultSlot?.display ?? "—")）").tag(UUID?.none)
                    ForEach(p.slots) { s in Text(s.display).tag(Optional(s.id)) }
                }
                .labelsHidden().frame(width: 260)
                Text("切换这枚用途用哪把密钥")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        if requireVision, let p = ai.provider(providerID.wrappedValue),
           p.kind == .openAICompatible, p.name.contains("DeepSeek") {
            Text("提示：DeepSeek 目前没有视觉模型，做图片 OCR 请换用含视觉能力的服务或本地 Ollama。")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
        if let p = ai.provider(providerID.wrappedValue), !p.isLocal, !p.hasKey {
            Text("该服务商还没有保存 API Key，请到「服务商」页补上。")
                .font(.system(size: 11)).foregroundStyle(.orange)
        }
    }
}

// MARK: - OCR 设置

struct OCRSettingsPane: View {
    @EnvironmentObject var ai: AIStore
    @State private var customLang = ""

    private let presetLangs: [(String, String)] = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("en-US", "English"),
        ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("fr-FR", "Français"), ("de-DE", "Deutsch"),
        ("es-ES", "Español"), ("ru-RU", "Русский")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("OCR 设置").font(.system(size: 18, weight: .bold))

            // 引擎与模型放在这一页的**最上面**，而不是只藏在「模型分配」里。
            // 用户来 OCR 设置就是要改 OCR，配置项却找不到 —— 这是最常见的可用性问题。
            // 「模型分配」那份保留（它管的是跨页的分配总表），两处指向同一份状态。
            SectionCard(title: "识别引擎",
                        subtitle: "本地 Vision 离线、快、免配置；视觉大模型更适合复杂版面、手写与表格") {
                Picker("", selection: $ai.ocr.engine) {
                    ForEach(OCREngineKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .onChange(of: ai.ocr.engine) { ai.save() }
                if ai.ocr.engine == .llm {
                    Divider()
                    Text("在「模型分配」页选服务商与模型；也可以在「服务商」页新增服务商与密钥。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if ai.ocrTarget == nil {
                        Label("还没选服务商或模型，视觉模型 OCR 现在用不了", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    } else if let t = ai.ocrTarget {
                        Label("当前：\(t.provider.name) · \(t.model)", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Design.success)
                    }
                }
            }

            SectionCard(title: "识别语言", subtitle: "按优先级排列；中英混排建议同时选中「简体中文」与「English」") {
                FlowRow(items: presetLangs.map(\.0)) { code in
                    Chip(text: presetLangs.first { $0.0 == code }?.1 ?? code,
                         selected: ai.ocr.languages.contains(code),
                         action: {
                             if let i = ai.ocr.languages.firstIndex(of: code) { ai.ocr.languages.remove(at: i) }
                             else { ai.ocr.languages.append(code) }
                             ai.save()
                         })
                }
                HStack(spacing: 6) {
                    TextField("其它语言代码，如 it-IT", text: $customLang)
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                    Button("添加") {
                        let t = customLang.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty, !ai.ocr.languages.contains(t) { ai.ocr.languages.append(t); ai.save() }
                        customLang = ""
                    }.controlSize(.small)
                }
                Text("当前：\(ai.ocr.languages.joined(separator: "、"))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            SectionCard(title: "输出格式") {
                Picker("", selection: $ai.ocr.format) {
                    ForEach(OCRFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 320)
                .onChange(of: ai.ocr.format) { ai.save() }
            }

            SectionCard(title: "渲染精度", subtitle: "越高越准，也越慢；扫描件建议 2.5 以上") {
                HStack(spacing: 10) {
                    Slider(value: $ai.ocr.renderScale, in: 1.0...4.0, step: 0.5)
                        .frame(width: 240)
                        .onChange(of: ai.ocr.renderScale) { ai.save() }
                    Text(String(format: "%.1f×", ai.ocr.renderScale))
                        .font(.system(size: 12, design: .rounded).monospacedDigit())
                }
                Toggle("翻译时对无文字的扫描页自动先做本地 OCR", isOn: $ai.ocr.autoOCRScannedPagesWhenTranslating)
                    .onChange(of: ai.ocr.autoOCRScannedPagesWhenTranslating) { ai.save() }
                    .font(.system(size: 12))
            }

            SectionCard(title: "识别结果缓存") {
                HStack(spacing: 8) {
                    Text("同一文件同一页重复识别会直接读缓存，省时间也不重复计费。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("清空缓存") { OCRCache.clear(); TranslateCache.clear() }.controlSize(.small)
                }
            }
        }
    }
}

// MARK: - 翻译设置

struct TranslateSettingsPane: View {
    @EnvironmentObject var ai: AIStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("翻译设置").font(.system(size: 18, weight: .bold))

            SectionCard(title: "语言") {
                HStack(spacing: 10) {
                    FieldRow(label: "源语言") {
                        Picker("", selection: $ai.translate.sourceLang) {
                            ForEach(LangOption.all) { Text($0.label).tag($0.code) }
                        }.labelsHidden().frame(width: 190)
                    }
                }
                FieldRow(label: "目标语言") {
                    Picker("", selection: $ai.translate.targetLang) {
                        ForEach(LangOption.all.filter { $0.code != "auto" }) { Text($0.label).tag($0.code) }
                    }.labelsHidden().frame(width: 190)
                    Button {
                        let s = ai.translate.sourceLang
                        if s != "auto" {
                            ai.translate.sourceLang = ai.translate.targetLang
                            ai.translate.targetLang = s
                        } else {
                            ai.translate.sourceLang = ai.translate.targetLang
                            ai.translate.targetLang = "zh-Hans"
                        }
                        ai.save()
                    } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.borderless).help("互换源语言与目标语言")
                }
                .onChange(of: ai.translate.sourceLang) { ai.save() }
                .onChange(of: ai.translate.targetLang) { ai.save() }
            }

            SectionCard(title: "风格") {
                Picker("", selection: $ai.translate.style) {
                    ForEach(TranslateStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                .onChange(of: ai.translate.style) { ai.save() }
                Text(ai.translate.style.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            SectionCard(title: "去 AI 味",
                        subtitle: "把译文里「像机器写的」痕迹压掉：不加铺垫与预告、不堆限定词、不做空泛拔高、不改变原文的确定程度") {
                Toggle("开启去 AI 味", isOn: $ai.translate.deAI)
                    .onChange(of: ai.translate.deAI) { ai.save() }
                Text("规则取自 humanizer-zh：不新增原文没有的事实与结论，保留否定、范围、条件、时间与归因；中文输出用全角标点。目标语言不是中文时自动改用对应的英文规则。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            SectionCard(title: "结果呈现") {
                Picker("", selection: $ai.translate.outputMode) {
                    ForEach(TranslateOutputMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                .onChange(of: ai.translate.outputMode) { ai.save() }
            }

            SectionCard(title: "长文切片与接缝检查",
                        subtitle: "按段落切片，绝不切开段落；跨页传递上文，保证人称与术语连贯；接缝处自动检查截断、重复、漏译并重试") {
                FieldRow(label: "每片字数", hint: "越小越稳，调用次数越多") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(get: { Double(ai.translate.chunkChars) },
                                              set: { ai.translate.chunkChars = Int($0); ai.save() }),
                               in: 400...4000, step: 100)
                            .frame(width: 220)
                        Text("\(ai.translate.chunkChars) 字")
                            .font(.system(size: 12, design: .rounded).monospacedDigit())
                    }
                }
                FieldRow(label: "并发数", hint: "本地模型建议 1–2") {
                    Stepper("\(ai.translate.concurrency)", value: Binding(get: { ai.translate.concurrency },
                                                                         set: { ai.translate.concurrency = max(1, min(8, $0)); ai.save() }),
                            in: 1...8)
                        .frame(width: 120)
                }
                FieldRow(label: "上文重叠句数", hint: "每一片带上几前句作参考") {
                    Stepper("\(ai.translate.overlapSentences)", value: Binding(get: { ai.translate.overlapSentences },
                                                                              set: { ai.translate.overlapSentences = max(0, min(6, $0)); ai.save() }),
                            in: 0...6).frame(width: 120)
                }
                FieldRow(label: "采样温度", hint: "越低越稳定，翻译建议 0.1–0.3") {
                    HStack(spacing: 8) {
                        Slider(value: $ai.translate.temperature, in: 0...1, step: 0.05)
                            .frame(width: 200)
                            .onChange(of: ai.translate.temperature) { ai.save() }
                        Text(String(format: "%.2f", ai.translate.temperature))
                            .font(.system(size: 12, design: .rounded).monospacedDigit())
                    }
                }
                Toggle("完成后做一遍全文一致性校对（额外调用，费用与耗时增加）", isOn: $ai.translate.proofread)
                    .font(.system(size: 12))
                    .onChange(of: ai.translate.proofread) { ai.save() }
            }

            SectionCard(title: "术语表", subtitle: "这些词会被强制按指定译法翻译，优先级最高") {
                // ⚠️ 不能拿 enumerated 的下标当 Binding 的下标：删掉一行后数组变短，
                // 只要 SwiftUI 还求值一次旧 Binding 就会下标越界崩掉。统一按 id 查。
                ForEach(ai.translate.convertTerms) { entry in
                    HStack(spacing: 6) {
                        TextField("原文词", text: Binding(
                            get: { ai.translate.convertTerms.first { $0.id == entry.id }?.source ?? "" },
                            set: { v in
                                guard let i = ai.translate.convertTerms.firstIndex(where: { $0.id == entry.id }) else { return }
                                ai.translate.convertTerms[i].source = v; ai.save()
                            }))
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                        Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(.secondary)
                        TextField("指定译法", text: Binding(
                            get: { ai.translate.convertTerms.first { $0.id == entry.id }?.target ?? "" },
                            set: { v in
                                guard let i = ai.translate.convertTerms.firstIndex(where: { $0.id == entry.id }) else { return }
                                ai.translate.convertTerms[i].target = v; ai.save()
                            }))
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                        Button {
                            ai.translate.convertTerms.removeAll { $0.id == entry.id }; ai.save()
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button {
                    ai.translate.convertTerms.append(GlossaryEntry()); ai.save()
                } label: { Label("添加术语", systemImage: "plus") }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 关于

/// AI 中心里的「关于」页。内容与独立窗口（菜单「关于轻阅」）完全共用一份，
/// 避免两处各写一套、改了一处忘了另一处。
struct AboutPane: View {
    var body: some View { AboutContent() }
}
