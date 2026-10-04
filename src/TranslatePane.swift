// 轻阅 · 译文对照面板：仅译文 / 逐段对照 / 分页对照（跟随阅读位置）

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranslatePane: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var translate: TranslateStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var ocr: OCRStore
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if !translate.qualitySummary.isEmpty {
                qualityBanner
            }
            content
            footer
        }
        .background(VisualEffectBg().ignoresSafeArea())
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "character.book.closed.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                Text("译文对照").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    withAnimation(Design.animPanel) { translate.paneVisible = false }
                } label: { Image(systemName: "sidebar.right").font(.system(size: 12)) }
                    .buttonStyle(.plain).help("收起对照面板 (⇧⌘T)")
            }

            HStack(spacing: 6) {
                Text("\(LangOption.label(ai.translate.sourceLang)) → \(LangOption.label(ai.translate.targetLang))")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .foregroundStyle(Color.accentColor)
                Text(ai.translate.style.label).font(.system(size: 10)).foregroundStyle(.secondary)
                if ai.translate.deAI {
                    Text("去 AI 味").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.purple.opacity(0.15)))
                        .foregroundStyle(.purple)
                }
                Spacer()
                Button {
                    showSettings = true
                } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("翻译设置")
            }

            if !translate.engineLabel.isEmpty {
                Text(translate.engineLabel).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }

            // 呈现方式
            Picker("", selection: Binding(
                get: { ai.translate.outputMode },
                set: { ai.translate.outputMode = $0; ai.save() }
            )) {
                ForEach(TranslateOutputMode.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: ai.translate.outputMode) { }

            if ai.translate.outputMode == .bilingualPage {
                Toggle("跟随阅读位置自动切换", isOn: $translate.followPage)
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini)
            }

            HStack(spacing: 6) {
                smallButton("本页", "doc.text") { runPage() }
                smallButton("整篇", "doc.on.doc") { runDocument() }
                smallButton("导出", "square.and.arrow.up") { exportCurrent() }
                Spacer()
                if !translate.pages.isEmpty {
                    Button("清空") { translate.clear() }
                        .buttonStyle(.borderless).font(.system(size: 10))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .sheet(isPresented: $showSettings) {
            TranslateSettingsSheet()
                .environmentObject(ai)
                .environmentObject(state)
        }
    }

    private var qualityBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: translate.qualitySummary.contains("通过") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(translate.qualitySummary.contains("通过")
                                 ? Design.success : .orange)
            Text(translate.qualitySummary)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if translate.pages.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                Text("还没有译文").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("选中文字按 ⌥⌘T 即时翻译；\n或直接翻译整页 / 整篇。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                Text("扫描件会先用本地 Vision 自动识别文字。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            Spacer()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        let keys = visiblePages
                        ForEach(keys, id: \.self) { idx in
                            if let pt = translate.pages[idx] {
                                pageCard(pt)
                                    .id(idx)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onChange(of: state.currentPage) { _, newPage in
                    guard translate.followPage, ai.translate.outputMode == .bilingualPage else { return }
                    withAnimation(Design.animSmooth) { proxy.scrollTo(newPage - 1, anchor: .top) }
                }
            }
        }
    }

    private var visiblePages: [Int] {
        let all = translate.pages.keys.sorted()
        if ai.translate.outputMode == .bilingualPage {
            let cur = state.currentPage - 1
            if translate.pages[cur] != nil { return [cur] }
            if let nearest = all.min(by: { abs($0 - cur) < abs($1 - cur) }) { return [nearest] }
        }
        return all
    }

    @ViewBuilder
    private func pageCard(_ pt: PageTranslation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("第 \(pt.pageIndex + 1) 页")
                    .font(.system(size: 11, weight: .semibold))
                if pt.state == .running {
                    ProgressView().controlSize(.mini)
                }
                if let note = pt.qualityNote {
                    Text(note)
                        .font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    state.goToPage(pt.pageIndex + 1)
                } label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("跳到这一页")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pt.translatedText, forType: .string)
                    state.showToast("已复制本页译文")
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("复制本页译文")
                    .disabled(pt.translatedText.isEmpty)
                Button {
                    retranslate(pt.pageIndex)
                } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("重译这一页")
                    .disabled(pt.state == .running)
            }

            switch ai.translate.outputMode {
            case .translationOnly, .bilingualPage:
                if pt.state == .failed && pt.translatedText.isEmpty {
                    // 失败时原来落到 else 分支渲染一个空 Text，卡片一片空白、也看不出为什么
                    Label("这一页没翻成功，点右上角的重译再试一次", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if pt.translatedText.isEmpty && pt.state == .running {
                    Text("翻译中…").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    Text(pt.translatedText)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .bilingualParagraph:
                VStack(alignment: .leading, spacing: 10) {
                    if pt.segments.isEmpty {
                        Text(pt.translatedText).font(.system(size: 12)).textSelection(.enabled)
                    }
                    ForEach(Array(pt.segments.enumerated()), id: \.offset) { _, seg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(seg.source)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                            Text(seg.target)
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 2)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Design.controlBg(scheme).opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
            pt.pageIndex == state.currentPage - 1 ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.07)))
    }

    private var footer: some View {
        HStack {
            Text(translate.statusNote.isEmpty ? "就绪" : translate.statusNote)
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            Spacer()
            if !translate.pages.isEmpty {
                Text("\(translate.totalChars) 字")
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: 动作

    private func smallButton(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func context() -> TranslateContext? {
        guard let doc = state.document else { return nil }
        let url = state.fileURL
        return TranslateContext(pageCount: doc.pageCount,
                                pageText: { [weak doc] i in doc?.page(at: i)?.string ?? "" },
                                page: { [weak doc] i in doc?.page(at: i) },
                                docTitle: state.documentTitle,
                                identity: OCRCache.identity(fileURL: url, pageCount: doc.pageCount))
    }

    private func runPage() {
        guard let ctx = context() else { return }
        translate.translatePage(max(0, state.currentPage - 1), ctx: ctx, ai: ai, tasks: tasks)
    }

    private func runDocument() {
        guard let ctx = context() else { return }
        translate.translateDocument(ctx: ctx, ai: ai, tasks: tasks)
    }

    private func retranslate(_ index: Int) {
        guard let ctx = context() else { return }
        // 先确认有可用目标再清空：否则清完了才发现在 translatePages 里被挡回来，
        // 这一页已有的译文就白丢了
        guard ai.translateTarget != nil else {
            state.showToast("请先在 AI 中心选择翻译服务商与模型")
            return
        }
        translate.pages[index] = nil
        translate.translatePage(index, ctx: ctx, ai: ai, tasks: tasks)
    }

    private func exportCurrent() {
        let bilingual = ai.translate.outputMode == .bilingualParagraph
        let text = bilingual
            ? translate.exportBilingualMarkdown(title: state.documentTitle,
                                               targetLangLabel: LangOption.label(ai.translate.targetLang))
            : translate.exportMarkdown(title: state.documentTitle,
                                       targetLangLabel: LangOption.label(ai.translate.targetLang))
        guard let text else { state.showToast("还没有译文"); return }
        ReaderActions.exportText(text, suggestedName: "\(state.documentTitle)-译文",
                                 fileExtension: "md", state: state, successToast: "已导出译文")
    }
}

/// 从对照面板里直接打开翻译设置
struct TranslateSettingsSheet: View {
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("翻译设置").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                TranslateSettingsPane().padding(18)
            }
        }
        .frame(width: 620, height: 560)
    }
}

/// 选区 / 区域的即时翻译卡片（AI 提问也复用这一张）
struct QuickTranslateCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var translate: TranslateStore
    let card: QuickCard

    private var title: String {
        switch card.kind {
        case .region:    return "框选翻译"
        case .selection: return "选中文字翻译"
        case .ask:       return card.askLabel ?? "AI 回答"
        }
    }
    private var icon: String {
        switch card.kind {
        case .region:    return "crop"
        case .selection: return "text.cursor"
        case .ask:       return "sparkles"
        }
    }
    private var copyLabel: String { card.kind == .ask ? "复制回答" : "复制译文" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                if card.state == .running { ProgressView().controlSize(.mini) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.output, forType: .string)
                    state.showToast("已复制")
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help(copyLabel)
                    .disabled(card.output.isEmpty)
                Button {
                    withAnimation { translate.quickCard = nil }
                } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.borderless)
            }

            if card.kind != .ask, !card.sourceText.isEmpty, card.kind == .region {
                VStack(alignment: .leading, spacing: 2) {
                    Text("识别到的原文").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(card.sourceText)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                }
            }
            if card.kind == .ask, !card.sourceText.isEmpty {
                DisclosureGroup {
                    Text(card.sourceText)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("选中的原文（\(card.sourceText.count) 字）")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }

            if card.kind == .ask {
                ScrollView {
                    Text(card.output.isEmpty ? "…" : card.output)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
            } else {
                ScrollView {
                    Text(card.output.isEmpty ? "…" : card.output)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 190)
            }

            HStack {
                if let note = card.note, card.state == .failed || card.kind != .ask {
                    Text(note).font(.system(size: 9))
                        .foregroundStyle(card.state == .failed ? Design.danger : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(String(format: "%.1fs", card.elapsed))
                    .font(.system(size: 9, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: card.kind == .ask ? 390 : 340)
        .background(RoundedRectangle(cornerRadius: 13).fill(Design.barStyle(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 5)
    }
}
