// 轻阅 · 应用状态（阅读器 + AI/OCR/翻译共享状态）

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 状态中枢

final class AppState: ObservableObject {
    @Published var document: PDFDocument?
    @Published var fileURL: URL?
    @Published var documentTitle: String = "轻阅"
    @Published var currentPage: Int = 1          // 1-based，展示用
    @Published var pageCount: Int = 0
    @Published var scalePercent: Int = 100
    @Published var sidebarVisible: Bool = true
    @Published var sidebarTab: SidebarTab = .thumbnails
    @Published var displayMode: PDFDisplayMode = .singlePageContinuous
    @Published var tool: Tool = .select
    @Published var autoScales: Bool = true

    /// 阅读色调（原色 / 暖纸 / 夜间）。全局设置，换文档不变 —— 见 ReadingExtras.swift。
    @Published var readingTint: ReadingTint = ReadingTint.saved

    @Published var searchText: String = ""
    @Published var searchHits: [SearchHit] = []
    @Published var searchCursor: Int = 0          // 当前停在第几个结果（0-based）
    @Published var isSearching: Bool = false
    @Published var searchFocusToken: UUID = UUID()

    @Published var recentFiles: [URL] = []
    /// 书签。跟文档路径走，`open` / `closeDocument` 时重新装载 —— 见 Bookmarks.swift
    @Published var bookmarks: [Bookmark] = []
    @Published var errorMessage: String?
    @Published var toast: String?

    // 编辑 / 框选 / 面板
    /// 文档结构变更计数，驱动缩略图与目录刷新。
    /// 一变就丢掉缩略图缓存 —— 缓存按 index 存，不清就会拿旧页面结构里的图。
    @Published var revision: Int = 0 {
        didSet { if revision != oldValue { thumbCache.removeAll() } }
    }

    /// 缩略图缓存条目：图像 + 页面宽高比（宽高比要带上旋转，见 PageEditorView.aspect）
    struct ThumbEntry {
        var image: NSImage
        var ratio: CGFloat
    }

    /// 缩略图缓存（不进 @Published：它是派生数据，靠视图自己触发重绘）。
    /// PDFKit 的页面光栅化不是线程安全的，只能在主线程做，所以更要在意"别重复做"——
    /// 侧栏滚出去再滚回来、页面管理里来回翻，都不该重新渲染。
    var thumbCache: [String: ThumbEntry] = [:]
    /// 缓存上限。单张侧栏缩略图约 0.45MB、管理页约 2.2MB（640×900），
    /// 120 张 ≈ 54MB —— 可见区通常不到 10 张，够覆盖来回滚动，又不至于把内存堆满
    private static let thumbCacheLimit = 120

    func cachedThumb(_ index: Int, kind: String) -> ThumbEntry? { thumbCache["\(kind)|\(index)"] }
    func storeThumb(_ index: Int, kind: String, image: NSImage, ratio: CGFloat) {
        if thumbCache.count > Self.thumbCacheLimit { thumbCache.removeAll() }
        thumbCache["\(kind)|\(index)"] = ThumbEntry(image: image, ratio: ratio)
    }

    @Published var regionRect: CGRect?               // 正在拖拽的框选矩形（**PDFView 视图坐标**，内部计算用）
    @Published var pendingRegion: PendingRegion?     // 已完成的框选
    /// 拖拽中的框选矩形，**已换算到 SwiftUI 所在容器的坐标系**。
    ///
    /// ⚠️ 踩过的坑（"框选范围和鼠标范围不一致"就是它）：
    /// `ToolPDFView.mouseDragged` 拿到的 `convert(_:from: nil)` 是 **PDFView 自己的
    /// bounds 坐标**（原点 0,0，紧贴视图边缘），而画框的 `RegionOverlay` 挂在
    /// SwiftUI 的 `ZStack` 上、用 `.position()` 定位 —— **那两个坐标系原点不重合**：
    /// PDFView 内部有 `pageBreakMargins`（本项目设了四周 14pt）、页面居中留白、
    /// 页面阴影偏移，而 ZStack 拿的是 PDFView 的 **frame** 位置。
    /// 差多少随缩放、页数、窗口宽度变化 —— 所以偏移量不是常数，肉眼很难归因。
    ///
    /// 修法：不在 SwiftUI 那边猜偏移，而是让 PDFView 在拖拽时
    /// `convert(rect, to: nil)` 换算到 **window 坐标**，SwiftUI 那边再用
    /// 同一个 window → 容器变换换算回来。
    @Published var regionOverlayRect: CGRect?
    /// PDFView 相对 SwiftUI 宿主容器的偏移。
    ///
    /// 用途：把「PDFView 坐标」换算成「宿主容器坐标」——
    ///   容器坐标 = PDFView 坐标 + pdfViewOffset
    /// 拖拽中的框（`regionOverlayRect`）已经由 `ToolPDFView` 走 window 坐标换算好了；
    /// 但**框完之后**要摆动作卡（`RegionActionCard`）时手里只有 `PendingRegion.viewRect`
    /// （PDFView 坐标），那就用这个偏移换过去。
    ///
    /// 为什么不统一都走 window 坐标中转：动作卡的位置是 SwiftUI 自己算的
    /// （要夹在可视区域内），拿不到 NSView 再绕一圈；用偏移量更直接。
    /// 由 `PDFKitView.updateNSView` 每帧回写 —— 窗口缩放、侧栏开合都会让它变。
    @Published var pdfViewOffset: CGVector = .zero

    @Published var editorPresented = false
    @Published var ocrPaneVisible = false
    @Published var editingTextRegion: PendingRegion?
    @Published var textBoxDraft: String = ""
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var undoLabel: String?
    @Published var redoLabel: String?
    /// 页面结构改动（插入/删除/旋转/排序）只在内存里，需要 ⌘S 才落盘 —— 用它提示用户
    @Published var isDirty = false

    struct PendingRegion {
        var pageIndex: Int
        var normalized: CGRect     // 页内归一化坐标，原点左下
        var viewRect: CGRect
    }

    /// 撤销 / 重做快照（PDF 数据快照，最多保留 8 步）
    var undoStack: [(data: Data, label: String)] = []
    var redoStack: [(data: Data, label: String)] = []

    // 便签编辑
    @Published var noteDraftText: String = ""
    var noteDraftPage: PDFPage?
    var noteDraftPoint: CGPoint = .zero
    var noteDraftExisting: PDFAnnotation?
    @Published var noteEditing: Bool = false

    weak var pdfView: PDFView?

    /// 切换文档前由界面层接线的清理动作。
    /// OCR 结果、译文都按页号索引，不跟着文档走的话换文件后会串档。
    var onDocumentWillChange: (() -> Void)?
    /// 文档**打开成功后**回调（参数是文件 URL）。
    ///
    /// ⚠️ 与 `onDocumentWillChange` 的区别：那个是"要换了，先清干净"，
    /// 这个是"换好了，可以按新文档的身份读回该读的东西"（如存过的 AI 摘要）。
    /// 两者时机不同，别混用 —— 在 `willChange` 里读回是拿不到新文档身份的。
    var onDocumentDidOpen: ((URL) -> Void)?

    /// 由界面层接线：PDF 右键菜单里的「翻译选中文字」
    var translateSelectionAction: (() -> Void)?

    init() { loadRecents() }

    // ---------- 界面偏好 ----------

    private static let toolbarModeKey = "qingyue.toolbarMode"

    /// 存 `AppState` 只是为了和 `toolbarModeKey` 放在一起；类型本体在 StudyCore。
    var toolbarMode: ToolbarMode {
        get {
            ToolbarMode(rawValue: UserDefaults.standard.string(forKey: Self.toolbarModeKey) ?? "") ?? .auto
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.toolbarModeKey) }
    }

    // ---------- 打开 / 保存 ----------

    func open(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let doc = PDFDocument(url: url) else {
            errorMessage = "无法打开这个文件：\(url.lastPathComponent)"
            return
        }
        // 有密码的 PDF 直接打开只会得到一片空白，必须说清楚
        if doc.isLocked {
            if !doc.unlock(withPassword: "") {
                errorMessage = "「\(url.lastPathComponent)」有密码保护，轻阅暂时无法解锁它。"
                return
            }
        }
        if doc.pageCount == 0 {
            errorMessage = "「\(url.lastPathComponent)」里没有可显示的页面。"
            return
        }

        // 换文档前清掉上一个文档留下的 OCR 结果 / 译文 / 任务
        onDocumentWillChange?()

        document = doc
        fileURL = url
        documentTitle = url.deletingPathExtension().lastPathComponent
        pageCount = doc.pageCount
        currentPage = 1
        scalePercent = 100
        autoScales = true
        searchHits = []
        searchText = ""
        searchCursor = 0
        searchGeneration += 1          // 换文档：作废上一个文档还在飞的搜索
        searchTask?.cancel()
        noteEditing = false
        pendingRegion = nil
        editingTextRegion = nil
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoState()
        isDirty = false
        tool = .select
        // 缩略图 / 目录按 revision 刷新；换文件但页数相同也必须 +1，否则会一直显示上一份的图
        revision += 1
        // 书签按文档路径存，换文档必须重新装载，否则会看到上一个文件的标记
        bookmarks = BookmarkStore.load(for: url)
        clearSelectionState()   // 旧文档的选区不该让新文档的工具条亮着
        addRecent(url)
        restoreLastPage(for: url)
        // 让界面按新文档的身份读回该读的东西（存过的摘要 / 笔记）。
        // 放在最后：此时 pageCount 等状态都已就绪，读回逻辑能拿到完整信息。
        onDocumentDidOpen?(url)
    }

    /// 关掉当前文档，回到欢迎页
    func closeDocument() {
        onDocumentWillChange?()
        document = nil
        fileURL = nil
        documentTitle = "轻阅"
        pageCount = 0
        currentPage = 1
        scalePercent = 100
        searchText = ""
        searchHits = []
        searchCursor = 0
        searchGeneration += 1
        searchTask?.cancel()
        noteEditing = false
        pendingRegion = nil
        editingTextRegion = nil
        undoStack.removeAll()
        redoStack.removeAll()
        refreshUndoState()
        isDirty = false
        tool = .select
        pdfView?.document = nil
        bookmarks = []
        clearSelectionState()
        revision += 1
    }

    private func restoreLastPage(for url: URL) {
        let key = Self.lastPageKey(for: url)
        guard let saved = UserDefaults.standard.object(forKey: key) as? Int else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.fileURL == url else { return }
            self.goToPage(saved + 1)
        }
    }

    static func lastPageKey(for url: URL) -> String {
        "qingyue.lastPage." + url.path
    }

    func saveLastPage() {
        guard let url = fileURL else { return }
        UserDefaults.standard.set(currentPage - 1, forKey: Self.lastPageKey(for: url))
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "打开 PDF"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func save() {
        guard let doc = document, let url = fileURL else {
            showToast("还没有打开的文档")
            return
        }
        if doc.write(to: url) {
            isDirty = false
            showToast("已保存")
        } else {
            errorMessage = "保存失败：写不进「\(url.lastPathComponent)」，可能是只读文件或没有权限。"
        }
    }

    func saveAs() {
        guard let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? documentTitle) + "-副本"
        if panel.runModal() == .OK, let url = panel.url {
            if doc.write(to: url) {
                fileURL = url
                documentTitle = url.deletingPathExtension().lastPathComponent
                isDirty = false
                addRecent(url)
                showToast("已另存为「\(url.lastPathComponent)」")
            } else {
                errorMessage = "另存失败"
            }
        }
    }

    // ---------- 最近文件 ----------

    private func loadRecents() {
        let paths = UserDefaults.standard.stringArray(forKey: "qingyue.recents") ?? []
        recentFiles = paths.compactMap { URL(string: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addRecent(_ url: URL) {
        var list = recentFiles.filter { $0.standardizedFileURL != url.standardizedFileURL }
        list.insert(url, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentFiles = list
        UserDefaults.standard.set(list.map { $0.absoluteString }, forKey: "qingyue.recents")
    }

    // ---------- 导航 / 缩放 ----------

    func goToPage(_ n: Int) {
        guard let doc = document, let view = pdfView else { return }
        let idx = min(max(0, n - 1), doc.pageCount - 1)
        if let page = doc.page(at: idx) {
            view.go(to: page)
            currentPage = idx + 1
        }
    }

    func nextPage() { goToPage(currentPage + 1) }
    func prevPage() { goToPage(currentPage - 1) }

    /// 当前页的文本层内容（扫描件会返回空串，调用方自己决定要不要退回 OCR 结果）
    func currentPageText() -> String {
        pdfView?.currentPage?.string ?? document?.page(at: currentPage - 1)?.string ?? ""
    }

    func zoomIn() {
        guard let v = pdfView else { return }
        v.autoScales = false
        autoScales = false
        v.scaleFactor = min(max(v.maxScaleFactor, v.scaleFactor), v.scaleFactor * 1.15)
        scalePercent = Int(round(v.scaleFactor * 100))
    }

    func zoomOut() {
        guard let v = pdfView else { return }
        v.autoScales = false
        autoScales = false
        v.scaleFactor = max(min(v.minScaleFactor, v.scaleFactor), v.scaleFactor / 1.15)
        scalePercent = Int(round(v.scaleFactor * 100))
    }

    func fitWidth() {
        autoScales = true
        if let v = pdfView {
            v.autoScales = true
            if displayMode == .singlePage { displayMode = .singlePageContinuous }
        }
    }

    func fitPage() {
        displayMode = .singlePage
        autoScales = true
    }

    func toggleDisplayMode() {
        displayMode = (displayMode == .twoUp || displayMode == .twoUpContinuous)
            ? .singlePageContinuous : .twoUpContinuous
    }

    /// 旋转当前页。
    /// 必须走 `rotatePages`：那里有撤销快照、会标 `isDirty`、会 bump `revision` 让缩略图跟着转。
    /// 原实现直接改 `page.rotation`，结果是「页面转了但缩略图没变、关掉就丢、还撤不回来」。
    func rotateCurrentPage() {
        guard let doc = document, let page = pdfView?.currentPage else { return }
        let idx = doc.index(for: page)
        guard idx >= 0, idx < doc.pageCount else { return }
        rotatePages([idx], by: 90)
    }

    // ---------- 搜索 ----------

    /// 搜索代次：每发起一次 +1，后台结果回来时只有代次仍是最新的才允许写回。
    /// 否则"边打边搜"时先发后到的旧结果会盖掉新结果 —— 输入框写着 b、列表却是 a 的命中。
    private var searchGeneration = 0
    /// 在飞的那次搜索。改关键词时直接取消上一次，不用等它扫完整个文档再丢掉结果。
    private var searchTask: Task<Void, Never>?

    func runSearch() {
        guard let doc = document else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchGeneration += 1          // 让还在飞的搜索作废
            searchHits = []
            searchCursor = 0
            isSearching = false
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchCursor = 0
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            // 逐页扫字符串（快），选区留到用户点结果时再造 —— 见 selectionsMap 的注释
            let hits: [SearchHit] = selectionsMap(query: query, doc: doc)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.searchGeneration == generation else { return }
                self.searchHits = hits
                self.isSearching = false
            }
        }
    }

    /// 跳到某个结果：不只是翻页，还要把匹配处选中并滚到视野里
    func goTo(hit: SearchHit) {
        if let i = searchHits.firstIndex(where: { $0.id == hit.id }) { searchCursor = i }
        guard let v = pdfView else {
            goToPage(hit.pageIndex + 1)
            return
        }
        if let sel = hit.selection {
            v.setCurrentSelection(sel, animate: true)
            v.go(to: sel)
            currentPage = min(max(1, hit.pageIndex + 1), max(1, pageCount))
        } else {
            goToPage(hit.pageIndex + 1)
        }
    }

    func nextHit() {
        guard !searchHits.isEmpty else { return }
        searchCursor = (searchCursor + 1) % searchHits.count
        goTo(hit: searchHits[searchCursor])
    }

    func prevHit() {
        guard !searchHits.isEmpty else { return }
        searchCursor = (searchCursor - 1 + searchHits.count) % searchHits.count
        goTo(hit: searchHits[searchCursor])
    }

    // ---------- 批注 ----------

    /// 当前是否有可用的文字选区
    /// 当前是否有非空选区。
    ///
    /// ⚠️ 这是一个**显式的 @Published 状态**，不是从 `pdfView.currentSelection`
    /// 现算的。踩过的坑：原来写的是 `var hasTextSelection: Bool { pdfView?.currentSelection... }`，
    /// 那个 getter **没有任何变更通知来源** —— PDFView 的选区变化不发 SwiftUI 的
    /// `@Published`，`updateNSView` 也不会因为选区变了而重跑。于是
    /// 「选中即问」按钮的高亮**永远不亮**，它只会在别的 `@Published` 变化
    /// 恰好触发 body 重算时才顺带刷新（表现为「有时候会亮」）。
    ///
    /// 现在由 `Coordinator.selectionChanged`（监听 `.PDFViewSelectionChanged`）回写。
    /// 真值仍由 `computeSelectionActive()` 现算，避免两处逻辑跑偏。
    @Published var selectionActive: Bool = false

    func computeSelectionActive() -> Bool {
        guard let s = pdfView?.currentSelection?.string else { return false }
        return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 换文档 / 收起选区时把状态归零
    func clearSelectionState() {
        if selectionActive { selectionActive = false }
    }

    /// 此刻该不该露出浮动工具条。
    ///
    /// ⚠️ 原来是**无条件**显示的（`ReaderUI.swift` 里一个 `if` 都没有），
    /// 于是那条 12 个按钮的胶囊一直压在页面底部、正文两三行文字被盖住
    /// —— 三张截图里都能看到。用户每次要读底部那几行都得先把它挪开。
    ///
    /// 判定本身放在 `StudyCore.ToolbarVisibility`（纯函数、可进测试台）：
    /// `AppState` 依赖 PDFView，测试台编不进它，逻辑留这儿就测不到。
    ///
    /// 刻意**不做**的：不因为"鼠标在附近"就显示。工具条是操作，不是装饰，
    /// 跟着光标飘的东西在阅读器里是干扰源（而且又得算一套悬停命中区）。
    var floatingToolbarVisible: Bool {
        if toolbarMode == .always { return document != nil }
        return ToolbarVisibility.shouldShow(hasSelection: selectionActive,
                                            tool: tool,
                                            hasPendingRegion: pendingRegion != nil,
                                            speaking: isSpeaking)
    }

    /// 朗读状态。`SpeechReader` 是另一个对象，视图层读到后回写一份到这里 ——
    /// 因为 `floatingToolbarVisible` 要参与 SwiftUI 的依赖追踪（得是 @Published），
    /// 而 `speaking` 在 `SpeechReader` 上，body 里直接读不会因为它变化而重算。
    @Published var isSpeaking = false


    /// 把当前选区变成批注（高亮 / 下划线 / 删除线）。
    /// 注意：这个函数由浮动工具条与右键菜单共同调用，不能设成 private。
    @discardableResult
    func applySelectionTool(_ t: Tool) -> Bool {
        guard let view = pdfView, let sel = view.currentSelection,
              !sel.selectionsByLine().isEmpty else {
            showToast("先在页面上选中文字，再点\(t.label)")
            return false
        }
        let subtype: PDFAnnotationSubtype
        let color: NSColor
        switch t {
        case .highlight:
            subtype = .highlight; color = NSColor.systemYellow.withAlphaComponent(0.55)
        case .underline:
            subtype = .underline; color = NSColor.systemIndigo
        case .strikeout:
            subtype = .strikeOut; color = NSColor.systemRed
        default:
            return false
        }
        var added = 0
        // 批注改动也要能撤销。不加这句，⌘Z 只对页面结构生效，
        // 用户加错一条高亮就再也回不去了。
        let name = t == .highlight ? "高亮" : (t == .underline ? "下划线" : "删除线")
        pushUndo(name)
        for line in sel.selectionsByLine() {
            guard let page = line.pages.first else { continue }
            var bounds = line.bounds(for: page)
            guard bounds.width > 0.5, bounds.height > 0.5 else { continue }
            bounds = bounds.insetBy(dx: -1, dy: -1)
            let ann = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            ann.color = color
            page.addAnnotation(ann)
            added += 1
        }
        guard added > 0 else {
            _ = undoStack.popLast()      // 一条都没落上，撤销栈不该多出这一步
            refreshUndoState()
            showToast("没能在选区上落下批注")
            return false
        }
        // 批注直接写回原文件，避免"改了却没保存"；写不进去（只读/无权限）就明确告知
        let saved = persistIfPossible()
        view.clearSelection()
        revision += 1                 // 让缩略图与目录跟着刷新，侧栏能看到刚加的高亮
        showToast(saved ? "已加\(name)并保存到原文件" : "已加\(name)，但原文件写不进去（可「另存为」）")
        refreshUndoState()
        return true
    }

    func beginNewNote(at point: CGPoint, on page: PDFPage) {
        noteDraftPage = page
        noteDraftPoint = point
        noteDraftExisting = nil
        noteDraftText = ""
        noteEditing = true
    }

    func beginEditNote(_ ann: PDFAnnotation, on page: PDFPage) {
        noteDraftPage = page
        noteDraftPoint = ann.bounds.origin
        noteDraftExisting = ann
        noteDraftText = ann.contents ?? ""
        noteEditing = true
    }

    func commitNote() {
        guard let page = noteDraftPage else { noteEditing = false; return }
        let text = noteDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = noteDraftExisting {
            if text.isEmpty {
                page.removeAnnotation(existing)
            } else {
                existing.contents = text
            }
        } else if !text.isEmpty {
            let bounds = CGRect(origin: noteDraftPoint, size: CGSize(width: 230, height: 54))
            let ann = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            ann.contents = text
            ann.font = NSFont.systemFont(ofSize: 12)
            ann.fontColor = NSColor.black
            ann.color = NSColor.systemYellow.withAlphaComponent(0.4)
            ann.alignment = .left
            page.addAnnotation(ann)
        }
        noteEditing = false
        noteDraftPage = nil
        noteDraftExisting = nil
    }

    func cancelNote() {
        noteEditing = false
        noteDraftPage = nil
        noteDraftExisting = nil
    }

    // ---------- 其他 ----------

    func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            withAnimation { if self?.toast == msg { self?.toast = nil } }
        }
    }

    func focusSearch() {
        sidebarVisible = true
        sidebarTab = .search
        searchFocusToken = UUID()
    }

    func printDocument() {
        guard let v = pdfView else { return }
        let op = NSPrintOperation(view: v)
        op.showsPrintPanel = true
        op.run()
    }
}
