// 轻阅 · 文档编辑：撤销/重做、页面管理、内容批注工具

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

extension AppState {

    // MARK: - 撤销 / 重做

    /// 撤销栈的内存预算。每一步都是一份**完整文档快照**，
    /// 对上百 MB 的 PDF，8 步就是 800MB —— 必须按字节数兜底，淘汰最旧的几步。
    private static let undoMemoryBudget = 192 * 1024 * 1024

    /// 在任何破坏性操作前调用：记下当前文档快照
    func pushUndo(_ label: String) {
        guard let doc = document, let data = doc.dataRepresentation() else { return }
        undoStack.append((data, label))
        if undoStack.count > 8 { undoStack.removeFirst(undoStack.count - 8) }
        // 超过预算就从最旧的开始丢，但至少保留最近一步，否则撤销会整体失效
        var total = undoStack.reduce(0) { $0 + $1.data.count }
        while total > Self.undoMemoryBudget, undoStack.count > 1 {
            total -= undoStack.removeFirst().data.count
        }
        redoStack.removeAll()
        refreshUndoState()
    }

    func undo() {
        guard let last = undoStack.popLast(), let doc = document else { return }
        if let current = doc.dataRepresentation() {
            redoStack.append((current, last.label))
        }
        guard let restored = PDFDocument(data: last.data) else { return }
        replaceDocument(restored, label: last.label)
        showToast("已撤销：\(last.label)")
        refreshUndoState()
    }

    func redo() {
        guard let last = redoStack.popLast(), let doc = document else { return }
        if let current = doc.dataRepresentation() {
            undoStack.append((current, last.label))
        }
        guard let restored = PDFDocument(data: last.data) else { return }
        replaceDocument(restored, label: last.label)
        showToast("已重做：\(last.label)")
        refreshUndoState()
    }

    private func replaceDocument(_ doc: PDFDocument, label: String) {
        let targetPage = min(max(0, currentPage - 1), max(0, doc.pageCount - 1))
        document = doc
        pageCount = doc.pageCount
        isDirty = true
        pdfView?.document = doc
        pdfView?.layoutDocumentView()
        revision += 1
        if let p = doc.page(at: targetPage) { pdfView?.go(to: p) }
        currentPage = targetPage + 1
    }

    func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
        undoLabel = undoStack.last?.label
        redoLabel = redoStack.last?.label
    }

    /// 结构变更后统一收尾
    func documentDidChange(label: String) {
        pageCount = document?.pageCount ?? 0
        if currentPage > pageCount { currentPage = max(1, pageCount) }
        revision += 1
        // 结构改动只在内存里，必须让用户看到"还没保存"
        isDirty = true
        pdfView?.layoutDocumentView()
        saveLastPage()
    }

    // MARK: - 框选拖拽收尾

    /// 由 ToolPDFView 在鼠标释放时调用；viewRect 是 PDFView 视图坐标
    func finishRegionDrag(_ viewRect: CGRect) {
        defer { regionRect = nil }
        guard let v = pdfView, viewRect.width > 8, viewRect.height > 8 else { return }
        let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
        guard let page = v.page(for: center, nearest: true),
              let doc = document else { return }
        let pageIndex = doc.index(for: page)
        let bounds = page.bounds(for: .cropBox)
        let p1 = v.convert(CGPoint(x: viewRect.minX, y: viewRect.minY), to: page)
        let p2 = v.convert(CGPoint(x: viewRect.maxX, y: viewRect.maxY), to: page)
        let minX = min(p1.x, p2.x), maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y), maxY = max(p1.y, p2.y)
        var norm = CGRect(x: (minX - bounds.minX) / bounds.width,
                          y: (minY - bounds.minY) / bounds.height,
                          width: (maxX - minX) / bounds.width,
                          height: (maxY - minY) / bounds.height)
        norm = norm.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard norm.width > 0.004, norm.height > 0.004 else { return }

        let pending = PendingRegion(pageIndex: pageIndex, normalized: norm, viewRect: viewRect)
        switch tool {
        case .whiteout:
            addWhiteout(normalized: norm, on: page)
            tool = .select
        case .textbox:
            textBoxDraft = ""
            editingTextRegion = pending
        default:
            pendingRegion = pending
        }
    }

    // MARK: - 页面操作

    private func makeBlankPage(size: CGSize) -> PDFPage? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    func referencePageSize() -> CGSize {
        if let p = document?.page(at: 0) { return p.bounds(for: .mediaBox).size }
        return CGSize(width: 595, height: 842)
    }

    /// 在指定索引之后插入空白页（-1 表示插到最前）
    func insertBlankPage(after index: Int) {
        guard let doc = document else { return }
        pushUndo("插入空白页")
        guard let blank = makeBlankPage(size: referencePageSize()) else { return }
        let at = max(0, min(doc.pageCount, index + 1))
        doc.insert(blank, at: at)
        documentDidChange(label: "插入空白页")
        // at 是 0 基插入位置，对用户要说"第 at+1 页"（原来少加 1，插在第 3 页却说第 2 页）
        showToast("已在第 \(at + 1) 页位置插入空白页")
    }

    /// 从另一个 PDF 插入页面
    func insertPagesFromFile() {
        guard let doc = document else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.title = "选择要插入的 PDF"
        guard panel.runModal() == .OK, let url = panel.url,
              let other = PDFDocument(url: url) else { return }
        pushUndo("插入 \(other.pageCount) 页")
        var at = max(0, min(doc.pageCount, currentPage))
        for i in 0..<other.pageCount {
            if let p = other.page(at: i) {
                doc.insert(p, at: at)
                at += 1
            }
        }
        documentDidChange(label: "插入页面")
        showToast("已插入 \(other.pageCount) 页：\(url.deletingPathExtension().lastPathComponent)")
    }

    func duplicatePages(_ indexes: [Int]) {
        guard let doc = document, !indexes.isEmpty else { return }
        pushUndo("复制 \(indexes.count) 页")
        var at = indexes.max()! + 1
        for i in indexes.sorted() {
            guard let src = doc.page(at: i),
                  let copyData = singlePageDocument(src),
                  let copy = PDFDocument(data: copyData)?.page(at: 0) else { continue }
            doc.insert(copy, at: min(at, doc.pageCount))
            at += 1
        }
        documentDidChange(label: "复制页面")
        showToast("已复制 \(indexes.count) 页")
    }

    private func singlePageDocument(_ page: PDFPage) -> Data? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var box = page.bounds(for: .mediaBox)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    func deletePages(_ indexes: [Int]) {
        guard let doc = document else { return }
        // 先按"实际有效的页号"去重再判断，否则 [0,1,999] 这种带越界索引的入参
        // 会因为 indexes.count 算多了而误报「不能删除全部页面」（明明还剩页面）
        let valid = Set(indexes.filter { $0 >= 0 && $0 < doc.pageCount })
        guard !valid.isEmpty else { return }
        guard valid.count < doc.pageCount else {
            errorMessage = "不能删除全部页面"
            return
        }
        pushUndo("删除 \(valid.count) 页")
        for i in valid.sorted(by: >) { doc.removePage(at: i) }
        documentDidChange(label: "删除页面")
        showToast("已删除 \(valid.count) 页")
    }

    func movePage(_ index: Int, by delta: Int) {
        guard let doc = document, index >= 0, index < doc.pageCount else { return }
        let target = index + delta
        guard target >= 0, target < doc.pageCount else { return }
        pushUndo("移动页面")
        guard let page = doc.page(at: index) else { return }
        doc.removePage(at: index)
        doc.insert(page, at: target)
        documentDidChange(label: "移动页面")
    }

    func rotatePages(_ indexes: [Int], by degrees: Int) {
        guard let doc = document, !indexes.isEmpty else { return }
        pushUndo("旋转 \(indexes.count) 页")
        for i in indexes where i >= 0 && i < doc.pageCount {
            if let p = doc.page(at: i) {
                p.rotation = ((p.rotation + degrees) % 360 + 360) % 360
            }
        }
        documentDidChange(label: "旋转页面")
        showToast("已旋转 \(indexes.count) 页")
    }

    /// 把所选页导出为新的 PDF 文件（保留批注）
    func exportPages(_ indexes: [Int]) {
        guard let doc = document, !indexes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(documentTitle)-节选-\(indexes.count)页"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let out = PDFDocument()
        var at = 0
        for i in indexes.sorted() {
            guard let src = doc.page(at: i), let data = singlePageDocument(src),
                  let page = PDFDocument(data: data)?.page(at: 0) else { continue }
            out.insert(page, at: at)
            at += 1
        }
        if out.write(to: url) { showToast("已导出 \(at) 页到 \(url.lastPathComponent)") }
        else { errorMessage = "导出失败" }
    }

    /// 页面管理：取出某页（用于缩略图面板）
    func page(at index: Int) -> PDFPage? { document?.page(at: index) }

    // MARK: - 内容批注工具

    /// 只在有磁盘文件时回写（内存文档等用户按 ⌘S 再保存）
    @discardableResult
    func persistIfPossible() -> Bool {
        guard let doc = document, let url = fileURL else { return false }
        return doc.write(to: url)
    }

    /// 涂白遮盖：用白色方块盖住内容（水印 / 隐私信息）
    func addWhiteout(normalized: CGRect, on page: PDFPage) {
        guard document != nil else { return }
        pushUndo("涂白遮盖")
        let bounds = page.bounds(for: .cropBox)
        let r = CGRect(x: normalized.minX * bounds.width + bounds.minX,
                       y: normalized.minY * bounds.height + bounds.minY,
                       width: max(4, normalized.width * bounds.width),
                       height: max(4, normalized.height * bounds.height))
        let ann = PDFAnnotation(bounds: r, forType: .square, withProperties: nil)
        ann.color = NSColor.white
        ann.interiorColor = NSColor.white
        let border = PDFBorder()
        border.lineWidth = 0
        ann.border = border
        page.addAnnotation(ann)
        let saved = persistIfPossible()
        revision += 1
        showToast(saved ? "已遮盖该区域并保存" : "已遮盖该区域（原文件写不进去，可「另存为」）")
    }

    /// 文本框：在页面上放一段可再次编辑的文字
    func addTextBox(normalized: CGRect, text: String, on page: PDFPage) {
        guard document != nil else { return }
        pushUndo("添加文本框")
        let bounds = page.bounds(for: .cropBox)
        let r = CGRect(x: normalized.minX * bounds.width + bounds.minX,
                       y: normalized.minY * bounds.height + bounds.minY,
                       width: max(60, normalized.width * bounds.width),
                       height: max(20, normalized.height * bounds.height))
        let ann = PDFAnnotation(bounds: r, forType: .freeText, withProperties: nil)
        ann.contents = text
        ann.font = NSFont.systemFont(ofSize: max(9, min(18, r.height * 0.5)))
        ann.fontColor = NSColor.black
        ann.color = NSColor.systemYellow.withAlphaComponent(0.25)
        ann.alignment = .left
        page.addAnnotation(ann)
        persistIfPossible()
        revision += 1
    }

    /// 清空本页所有批注
    func clearAnnotations(on page: PDFPage) {
        guard document != nil else { return }
        guard !page.annotations.isEmpty else {
            showToast("这一页没有批注")
            return
        }
        pushUndo("清除本页批注")
        for ann in page.annotations { page.removeAnnotation(ann) }
        let saved = persistIfPossible()
        revision += 1
        showToast(saved ? "已清除本页批注" : "已清除本页批注（原文件写不进去）")
    }

    func clearAllAnnotations() {
        guard let doc = document else { return }
        var count = 0
        for i in 0..<doc.pageCount {
            count += doc.page(at: i)?.annotations.count ?? 0
        }
        guard count > 0 else {
            showToast("这份文档还没有批注")
            return
        }
        pushUndo("清除全部批注")
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for ann in page.annotations { page.removeAnnotation(ann) }
        }
        let saved = persistIfPossible()
        revision += 1
        showToast(saved ? "已清除 \(count) 条批注" : "已清除 \(count) 条批注（原文件写不进去）")
    }

    // MARK: - 统一的“填充”入口（供框选工具调用）

    func fillRegion(_ region: PendingRegion, tool: Tool, on page: PDFPage) {
        switch tool {
        case .whiteout:
            addWhiteout(normalized: region.normalized, on: page)
        case .textbox:
            editingTextRegion = region
        default:
            break
        }
    }

    // MARK: - 关闭文档

    /// 关闭文档；有未保存的页面结构改动先问一句。
    /// 顶栏菜单与主菜单都走这里，避免两处逻辑走偏。
    func requestClose() {
        guard document != nil else { return }
        if isDirty {
            switch askAboutUnsavedChanges() {
            case .saveAndClose:
                save()
                if isDirty { return }     // 保存失败就别关，否则改动真丢了
            case .discardAndClose:
                break
            case .cancel:
                return
            }
        }
        closeDocument()
    }
}
