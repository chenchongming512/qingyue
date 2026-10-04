// 轻阅 · 统一动作层：菜单、工具栏、面板按钮都调用这里，避免逻辑重复

import Foundation
import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

enum ReaderActions {

    // MARK: - 导出助手

    /// 统一的「选保存路径 → 写文件 → 给反馈」。
    ///
    /// 收敛之前这段在 7 个地方各写了一遍（OCR 面板、翻译面板、批注、书签、摘要、
    /// 识别文本、译文导出），失败分支还各不相同：有的 `try?` 把错误吞掉、
    /// 写完照样弹"已导出"，用户以为存下来了其实没写进去。
    @discardableResult
    static func exportText(_ text: String,
                           suggestedName: String,
                           fileExtension: String,
                           state: AppState,
                           successToast: String) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            state.showToast(successToast)
            return true
        } catch {
            state.errorMessage = "导出失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 可搜索 PDF 的前置校验 + 保存路径。返回 nil 表示前置条件不满足（已给出提示）。
    static func askSearchablePDFTarget(state: AppState, ocr: OCRStore) -> URL? {
        guard state.document != nil else {
            state.showToast("还没有打开文档")
            return nil
        }
        guard !ocr.results.isEmpty else {
            state.showToast("请先做 OCR（本地 Vision 才能生成文本层）")
            return nil
        }
        // 视觉大模型通道只回文字、没有每行的坐标，写不出隐形文本层。
        // 不拦的话会导出一个"看着成功、其实搜不到字"的 PDF。
        guard ocr.results.values.contains(where: { !$0.lines.isEmpty }) else {
            state.showToast("当前结果没有文字位置信息（视觉模型通道），无法生成文本层")
            return nil
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(state.documentTitle)-可搜索"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    // MARK: - 上下文

    static func ocrContext(_ state: AppState) -> OCRContext? {
        guard let doc = state.document else { return nil }
        let url = state.fileURL
        return OCRContext(pageCount: doc.pageCount,
                          page: { [weak doc] i in doc?.page(at: i) },
                          fileURL: url,
                          identity: OCRCache.identity(fileURL: url, pageCount: doc.pageCount))
    }

    static func translateContext(_ state: AppState) -> TranslateContext? {
        guard let doc = state.document else { return nil }
        let url = state.fileURL
        return TranslateContext(pageCount: doc.pageCount,
                                pageText: { [weak doc] i in doc?.page(at: i)?.string ?? "" },
                                page: { [weak doc] i in doc?.page(at: i) },
                                docTitle: state.documentTitle,
                                identity: OCRCache.identity(fileURL: url, pageCount: doc.pageCount))
    }

    // MARK: - OCR

    static func runOCRPage(state: AppState, ai: AIStore, tasks: TaskCenter, ocr: OCRStore) {
        guard let ctx = ocrContext(state) else { return }
        withAnimation(Design.animPanel) {
            state.sidebarVisible = true
            state.sidebarTab = .ocr
        }
        ocr.inspectedPage = max(0, state.currentPage - 1)
        ocr.runPage(max(0, state.currentPage - 1), ctx: ctx, ai: ai, tasks: tasks)
        tasks.expanded = true
    }

    static func runOCRDocument(state: AppState, ai: AIStore, tasks: TaskCenter, ocr: OCRStore) {
        guard let ctx = ocrContext(state) else { return }
        withAnimation(Design.animPanel) {
            state.sidebarVisible = true
            state.sidebarTab = .ocr
        }
        ocr.runDocument(ctx: ctx, ai: ai, tasks: tasks)
        tasks.expanded = true
    }

    static func exportOCRText(state: AppState, ocr: OCRStore) {
        guard let text = ocr.exportText(documentTitle: state.documentTitle) else {
            state.showToast("还没有识别结果")
            return
        }
        exportText(text, suggestedName: "\(state.documentTitle)-OCR",
                   fileExtension: "txt", state: state, successToast: "已导出识别文本")
    }

    static func exportSearchablePDF(state: AppState, ocr: OCRStore, tasks: TaskCenter) {
        guard let doc = state.document,
              let url = askSearchablePDFTarget(state: state, ocr: ocr) else { return }
        let task = tasks.newTask(kind: .export, title: "生成可搜索 PDF")
        tasks.expanded = true
        // 主线程拍快照 → 后台写盘。见 OCREngine.writeSearchablePDFIsolated 里的说明。
        let snapshot = doc.dataRepresentation()
        let results = ocr.results
        Task {
            do {
                task.set(detail: "写入隐形文本层…", progress: 0.3)
                let count = try await OCREngine.writeSearchablePDFIsolated(snapshot: snapshot,
                                                                          results: results, to: url)
                task.set(detail: "完成", progress: 1, stats: "\(count) 页")
                task.finish(.done)
                state.showToast("已导出可搜索 PDF（\(count) 页）")
            } catch {
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    // MARK: - 翻译

    static func translateSelection(state: AppState, ai: AIStore, tasks: TaskCenter, translate: TranslateStore) {
        guard let sel = state.pdfView?.currentSelection?.string,
              !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.showToast("请先在页面上选中要翻译的文字")
            return
        }
        tasks.expanded = true
        translate.translateSelection(sel, ai: ai, tasks: tasks)
    }

    static func translateCurrentPage(state: AppState, ai: AIStore, tasks: TaskCenter, translate: TranslateStore) {
        guard let ctx = translateContext(state) else { return }
        tasks.expanded = true
        translate.translatePage(max(0, state.currentPage - 1), ctx: ctx, ai: ai, tasks: tasks)
    }

    static func translateDocument(state: AppState, ai: AIStore, tasks: TaskCenter, translate: TranslateStore) {
        guard let ctx = translateContext(state) else { return }
        tasks.expanded = true
        translate.translateDocument(ctx: ctx, ai: ai, tasks: tasks)
    }

    /// 框选区域：先本地识别再翻译
    static func translateRegion(state: AppState, ai: AIStore, tasks: TaskCenter, translate: TranslateStore,
                                region: AppState.PendingRegion) {
        guard let page = state.page(at: region.pageIndex),
              let img = OCREngine.renderPageImage(page, scale: CGFloat(max(2.0, ai.ocr.renderScale))) else {
            state.showToast("无法截取该区域")
            return
        }
        guard let cropped = OCREngine.crop(img, normalized: region.normalized) else { return }
        tasks.expanded = true
        translate.translateRegion(image: cropped, pageIndex: region.pageIndex,
                                 rect: region.normalized, ai: ai, tasks: tasks)
    }

    /// 框选区域：只识别文字，不翻译
    static func ocrRegion(state: AppState, ai: AIStore, tasks: TaskCenter, translate: TranslateStore,
                          region: AppState.PendingRegion) {
        guard let page = state.page(at: region.pageIndex),
              let img = OCREngine.renderPageImage(page, scale: CGFloat(max(2.0, ai.ocr.renderScale))),
              let cropped = OCREngine.crop(img, normalized: region.normalized) else { return }
        var card = QuickCard(kind: .region, sourceText: "", engine: "本地 Vision")
        card.region = region.normalized
        card.pageIndex = region.pageIndex
        card.state = .running
        translate.quickCard = card
        let task = tasks.newTask(kind: .ocr, title: "识别框选区域（第 \(region.pageIndex + 1) 页）")
        tasks.expanded = true
        Task {
            do {
                task.set(detail: "本地 Vision 识别中…", progress: 0.4)
                let lines = try OCREngine.visionLines(image: cropped, languages: ai.ocr.languages)
                let text = OCREngine.join(lines, format: .plain).trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    var c = translate.quickCard ?? QuickCard(kind: .region, sourceText: "")
                    c.output = text.isEmpty ? "（这块区域没有识别到文字）" : text
                    c.state = .done
                    c.note = "\(lines.count) 行 · 置信度中位数 \(String(format: "%.2f", median(lines.map(\.confidence))))"
                    translate.quickCard = c
                }
                task.set(detail: "完成", progress: 1, stats: "\(lines.count) 行")
                task.finish(.done)
            } catch {
                task.finish(.failed, error: error.localizedDescription)
            }
        }
    }

    static func exportTranslation(state: AppState, ai: AIStore, translate: TranslateStore, bilingual: Bool) {
        let text = bilingual
            ? translate.exportBilingualMarkdown(title: state.documentTitle,
                                               targetLangLabel: LangOption.label(ai.translate.targetLang))
            : translate.exportMarkdown(title: state.documentTitle,
                                       targetLangLabel: LangOption.label(ai.translate.targetLang))
        guard let text else {
            state.showToast("还没有译文")
            return
        }
        exportText(text, suggestedName: "\(state.documentTitle)-译文",
                   fileExtension: "md", state: state, successToast: "已导出译文")
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
