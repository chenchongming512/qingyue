// 轻阅 · 阅读器界面（顶栏 / 边栏 / 画布 / 浮动工具条 / 空状态）

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - 数据模型

enum SidebarTab: String, CaseIterable, Identifiable {
    case thumbnails, outline, summary, bookmarks, annotations, ocr, search
    var id: String { rawValue }

    var label: String {
        switch self {
        case .thumbnails:  return "缩略图"
        case .outline:     return "目录"
        case .summary:     return "摘要"
        case .bookmarks:   return "书签"
        case .annotations: return "批注"
        case .ocr:         return "文字"
        case .search:      return "搜索"
        }
    }
    var icon: String {
        switch self {
        case .thumbnails:  return "square.grid.2x2"
        case .outline:     return "list.bullet.indent"
        case .summary:     return "doc.text.magnifyingglass"
        case .bookmarks:   return "bookmark"
        case .annotations: return "highlighter"
        case .ocr:         return "text.viewfinder"
        case .search:      return "magnifyingglass"
        }
    }
    /// 悬停提示（竖排图标栏上只有图标，没有文字）
    var tip: String { label }
}

// MARK: - 主布局

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var ocr: OCRStore
    @EnvironmentObject var translate: TranslateStore
    @EnvironmentObject var summary: SummaryStore
    @EnvironmentObject var speech: SpeechReader
    @Environment(\.openWindow) private var openWindow
    /// ⚠️ `onAppear` 在 SwiftUI 里**会被调用不止一次**（视图重建、窗口状态变化都会触发）。
    /// 截图通道里的动作很多是"副作用"（加高亮、跑 OCR），重复执行会加倍 ——
    /// 踩过：批注列表里凭空出现两条一模一样的高亮。用一个标记吃掉重复调用。
    @State private var launchOptionsApplied = false
    /// 拖放悬停中（用于画那层提示）
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            HStack(spacing: 0) {
                if state.sidebarVisible && state.document != nil {
                    SidebarView()
                        .frame(width: 264)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        .zIndex(2)
                    Divider().opacity(0.6)
                }
                if state.document != nil {
                    ReaderCanvas()
                } else {
                    EmptyStateView()
                }
            }
        }
        .background(Design.windowBg(scheme))
        .frame(minWidth: 940, minHeight: 640)
        .background(WindowTitleSetter(title: state.document == nil ? "轻阅" : state.documentTitle))
        // 拖 PDF 进来直接打开。**必须挂在窗口根上**（而不是 ReaderCanvas / EmptyStateView）——
        // 挂在子视图上，已打开文档时从画布上拖就落不到。
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { items in
            openFirstPDF(in: items)
        }
        .overlay {
            // 悬在上面的拖放提示：没这个的话用户不知道松手会不会生效
            if isDropTargeted {
                DropOverlay()
            }
        }
        // 操作反馈：原来 showToast 只是改状态、没人画，用户点了按钮什么也看不到
        .overlay(alignment: .top) {
            if let text = state.toast {
                ToastView(text: text)
                    .padding(.top, 62)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(200)
            }
        }
        .sheet(isPresented: $state.editorPresented) {
            PageEditorView()
                .environmentObject(state)
        }
        .alert("出错了", isPresented: .init(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .onAppear {
            // AppDelegate 里那次调用时 SwiftUI 的窗口还没建出来，
            // appearance 压不上去。窗口就绪后再补一次（幂等）。
            state.readingTint.applyAppearance()
            // 换文档时清掉按页号索引的旧结果，否则 OCR / 译文会串档
            state.onDocumentWillChange = {
                ocr.clear()
                translate.clear()
                translate.quickCard = nil
                // ⚠️ 摘要的清理走 `switchDocument(nil:)` 而不是 `clear()`：
                // 它要顺带把上一份的 documentIdentity 归零，否则新文档可能会
                // 读到旧文档存的那份笔记（键虽然不同，但状态时机不对）。
                // 真正的读回在 `open` 之后（那里才知道新文档的身份）。
                summary.switchDocument(identity: nil, currentSource: ai.askTargetDescription)
                speech.stop()
                tasks.dismissFinished()
            }
            // 文档打开后把存过的摘要读回来（不用重新生成）
            state.onDocumentDidOpen = { url in
                let identity = OCRCache.identity(fileURL: url, pageCount: state.pageCount)
                summary.switchDocument(identity: identity, currentSource: ai.askTargetDescription)
            }
            state.translateSelectionAction = {
                ReaderActions.translateSelection(state: state, ai: ai, tasks: tasks, translate: translate)
            }
            applyLaunchOptions()
        }
    }

    // MARK: - 拖放打开

    /// 拖进来的第一份 PDF 直接打开。
    ///
    /// ⚠️ 两个坑：
    /// 1. **只取第一个**。用户可能一次拖好几份进来（ Finder 支持多选拖）。
    ///    逐个打开需要多窗口，而本项目是单文档设计 —— 打开最后一个、
    ///    或干脆只取第一份并提示，都比"静默只开一个"好。
    /// 2. **必须是 fileURL**。拖进来还可能是文本、图片、别的东西；
    ///    `loadObject` 拿不到 URL 就返回 false，交给系统默认行为（不会有）。
    private func openFirstPDF(in items: [NSItemProvider]) -> Bool {
        let pdfs = items.filter { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) }
        guard let first = pdfs.first ?? items.first else { return false }

        // 有多份时明确告诉用户"只打开了第一个"，而不是让他以为全打开了
        if pdfs.count > 1 {
            state.showToast("一次只能打开一份，已打开第一份（\(pdfs.count) 份）")
        }
        // _ = : loadObject 有返回值（Progress）没人用，要显式丢弃否则出 NoUsage 警告
        _ = first.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            // `loadObject` 的回调**不一定在主线程**，而 open(url:) 会动 @Published
            DispatchQueue.main.async { state.open(url: url) }
        }
        return true
    }

    /// 支持用启动参数直接打开某个面板（用于生成界面截图 / 自动化）。
    /// 注意：这里的动作必须在文档加载之后再触发，否则依赖文档的界面是空的。
    private func applyLaunchOptions() {
        guard let pane = LaunchOptions.pane else { return }
        // 只认第一次。见 `launchOptionsApplied` 的说明：重复执行会把副作用做两遍。
        guard !launchOptionsApplied else { return }
        launchOptionsApplied = true

        // 文档打开是异步的（applicationDidFinishLaunching 里延后 1 秒），
        // 所以这里等一小会儿再切界面。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            switch pane {
            case "translate":
                withAnimation(Design.animPanel) { translate.paneVisible = true }
            case "ocr":
                withAnimation(Design.animPanel) { state.sidebarVisible = true }
                state.sidebarTab = .ocr
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let ctx = ReaderActions.ocrContext(state) {
                        ocr.runPage(max(0, state.currentPage - 1), ctx: ctx, ai: ai, tasks: tasks)
                    }
                }
            case "bookmarks":
                state.sidebarVisible = true
                state.sidebarTab = .bookmarks
                // 造几条书签出来，否则截到的是空状态
                if state.bookmarks.isEmpty {
                    for p in [0, 2, 4] where p < state.pageCount {
                        state.addBookmark(pageIndex: p)
                    }
                }
            case "annotations":
                state.sidebarVisible = true
                state.sidebarTab = .annotations
                highlightFirstParagraph(forScreenshot: true)
            case "summary":
                state.sidebarVisible = true
                state.sidebarTab = .summary
                // 截图模式下塞一份成品内容：真机调模型要几十秒，截图等不起，
                // 不塞的话永远只能截到"还没生成"的引导语。
                if LaunchOptions.snapshotPath != nil { summary.injectDemo() }
            case "search":
                state.sidebarVisible = true
                state.sidebarTab = .search
                // 给一个文档里确实存在的词，好让搜索结果列表有内容
                state.searchText = "reading"
                state.runSearch()
            case "night":
                state.setReadingTint(.night)
            case "sepia":
                state.setReadingTint(.sepia)
            case "editor":
                state.editorPresented = true
            case "tasks":
                // 整篇 OCR 会产出一条带逐页日志的长任务，正好展示任务中心
                tasks.expanded = true
                withAnimation(Design.animPanel) { state.sidebarVisible = true }
                state.sidebarTab = .ocr
                ReaderActions.runOCRDocument(state: state, ai: ai, tasks: tasks, ocr: ocr)
            case "ai":
                openWindow(id: "ai-center")
            case "about":
                // 版权页（独立窗口），也用于截图核验
                openWindow(id: "about")
            case "toast":
                // 只用于截图核对提示条（--pane 是给自动化/截图用的通道）
                state.showToast("已加高亮并保存到原文件")
            case "highlight":
                highlightFirstParagraph(forScreenshot: true)
            case "translate-run":
                withAnimation(Design.animPanel) { translate.paneVisible = true }
                ReaderActions.translateCurrentPage(state: state, ai: ai, tasks: tasks, translate: translate)
            default:
                break
            }
        }
    }

    /// 走一遍「选中文字 → 加高亮」的真实链路。
    /// `--pane highlight` 用它做自检（这条链路以前是死的：`applySelectionTool` 没有任何调用点）；
    /// `--pane annotations` 用它先把批注列表填出内容，否则只能截到空状态。
    private func highlightFirstParagraph(forScreenshot: Bool) {
        guard let v = state.pdfView, let doc = state.document else { return }
        let needle = "The Quiet Architecture of Reading"
        let sel = doc.findString(needle, withOptions: [.caseInsensitive]).first
            ?? doc.page(at: 0).flatMap { page -> PDFSelection? in
                guard let text = page.string, text.count > 40 else { return nil }
                return page.selection(for: NSRange(location: 0, length: min(120, text.count)))
            }
        guard let sel else { return }
        v.setCurrentSelection(sel, animate: false)
        v.go(to: sel)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            state.applySelectionTool(.highlight)
            if !forScreenshot { state.showToast("已加高亮") }
        }
    }
}

// MARK: - 顶栏

struct HeaderBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var ocr: OCRStore
    @EnvironmentObject var translate: TranslateStore
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        GeometryReader { geo in
            // 用实测宽度明确切换，不用 ViewThatFits：
            // 后者按"理想宽度"判断、和实际布局的弹性压缩对不上，
            // 结果就是在 940 宽时仍选宽版，然后「/ 3」被悄悄丢掉。
            let narrow = geo.size.width < 1120
            HStack(spacing: 10) {
                // 红绿灯留白
                Color.clear.frame(width: 72, height: 1)

                if state.document != nil {
                    GhostIconButton(systemName: "sidebar.left", tip: "边栏 (⌘B)") {
                        withAnimation(Design.animPanel) { state.sidebarVisible.toggle() }
                    }
                    // 标签切换在边栏左侧的竖排图标栏上；这里不再放一排 segmented，
                    // 省下的 150pt 让窄窗口不再把页码与缩放挤没
                    bookmarkButton
                    tintMenu
                }

                Spacer(minLength: 4)

                // 标题优先拿空间，否则窄窗口会被两侧控件挤成「qing…mo」
                HStack(spacing: 5) {
                    if state.isDirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .help("页面改动还没保存（⌘S）")
                    }
                    Text(state.document == nil ? "轻阅" : state.documentTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(1)
                .frame(maxWidth: narrow ? 160 : 260)

                Spacer(minLength: 4)

                if state.document != nil {
                    pageNav.fixedSize()
                    zoomGroup(includeFitWidth: !narrow).fixedSize()

                    if narrow {
                        // 窄窗口：识别 / 翻译 / 页面 / 任务 / AI 全收进一个菜单
                        compactMenu
                    } else {
                        Divider().frame(height: 18)
                        ocrMenu
                        translateMenu
                        editorButton
                        tasksButton
                        aiButton
                    }

                    Divider().frame(height: 18)
                    moreMenu
                }

                folderMenu
            }
            .padding(.horizontal, 12)
            .frame(width: geo.size.width, height: 52)
            .background(
                Design.headerBackground(scheme)
                    .overlay(DragRegion())
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Design.hairline(scheme)).frame(height: 1)
                    }
            )
        }
        .frame(height: 52)
    }

    // MARK: 顶栏零件

    /// 书签：有书签时图标实心，点一下在"加 / 取消"之间切换
    private var bookmarkButton: some View {
        GhostIconButton(
            systemName: state.hasBookmarkOnCurrentPage ? "bookmark.fill" : "bookmark",
            tip: state.hasBookmarkOnCurrentPage ? "取消本页书签 (⌘D)" : "为第 \(state.currentPage) 页加书签 (⌘D)",
            size: 28
        ) { state.toggleBookmark() }
    }

    /// 阅读色调：原色 / 暖纸 / 夜间 / 夜间暖调
    private var tintMenu: some View {
        Menu {
            // 工具条露出方式：放在这儿而不是单独一个顶栏按钮 ——
            // 顶栏已经有 7 个控件，再加会触发窄屏降级；而且这两件事都是"阅读偏好"。
            Section("工具条") {
                ForEach(ToolbarMode.allCases) { m in
                    Button {
                        state.toolbarMode = m
                        state.showToast("工具条：\(m.label)")
                    } label: {
                        if state.toolbarMode == m {
                            Label(m.label, systemImage: "checkmark")
                        } else {
                            Text(m.label)
                        }
                    }
                }
            }
            Divider()
            Section("阅读色调") {
                ForEach(ReadingTint.allCases) { t in
                    Button {
                        state.setReadingTint(t)
                    } label: {
                        if state.readingTint == t {
                            Label(t.label, systemImage: "checkmark")
                        } else {
                            Text(t.label)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: state.readingTint.icon)
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("阅读色调：\(state.readingTint.label) · 工具条：\(state.toolbarMode.label)")
    }



    private var pageNav: some View {
        HStack(spacing: 4) {
            GhostIconButton(systemName: "chevron.left", tip: "上一页", size: 24) { state.prevPage() }
            PageNumberField()
            Text("/ \(state.pageCount)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
            GhostIconButton(systemName: "chevron.right", tip: "下一页", size: 24) { state.nextPage() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Design.controlBg(scheme)))
        .overlay(Capsule().strokeBorder(Design.hairline(scheme), lineWidth: 1))
    }

    private func zoomGroup(includeFitWidth: Bool) -> some View {
        HStack(spacing: 2) {
            GhostIconButton(systemName: "minus.magnifyingglass", tip: "缩小 (⌘-)", size: 24) { state.zoomOut() }
            Text("\(state.scalePercent)%")
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .frame(width: 38)
                .foregroundStyle(.secondary)
            GhostIconButton(systemName: "plus.magnifyingglass", tip: "放大 (⌘+)", size: 24) { state.zoomIn() }
            if includeFitWidth {
                GhostIconButton(systemName: "arrow.down.right.and.arrow.up.left", tip: "适合宽度 (⌘0)", size: 24) { state.fitWidth() }
            }
        }
    }

    private var ocrMenu: some View {
        Menu { ocrMenuItems } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.viewfinder").font(.system(size: 13, weight: .medium))
                if !ocr.results.isEmpty {
                    Text("\(ocr.results.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
        .help("OCR 文字识别")
    }

    private var translateMenu: some View {
        Menu { translateMenuItems } label: {
            HStack(spacing: 4) {
                Image(systemName: "character.book.closed").font(.system(size: 13, weight: .medium))
                if !translate.pages.isEmpty {
                    Text("\(translate.pages.count)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .frame(width: 34)
        .help("翻译")
    }

    private var editorButton: some View {
        GhostIconButton(systemName: "rectangle.stack", tip: "页面管理（⇧⌘E）", size: 28) {
            state.editorPresented = true
        }
    }

    private var tasksButton: some View {
        ZStack(alignment: .topTrailing) {
            GhostIconButton(systemName: "list.bullet.rectangle", tip: "任务中心（⇧⌘J）", size: 28) {
                withAnimation(Design.animSpring) { tasks.expanded.toggle() }
            }
            if !tasks.active.isEmpty {
                Text("\(tasks.active.count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .offset(x: 4, y: -2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var aiButton: some View {
        GhostIconButton(systemName: "sparkles", tip: "AI 中心（服务商 / 模型 / 参数）", size: 28) {
            openWindow(id: "ai-center")
        }
    }

    private var moreMenu: some View {
        Menu { fileMenuItems } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("更多")
    }

    /// 窄窗口时把 OCR / 翻译 / 页面 / 任务 / AI 收进这里
    private var compactMenu: some View {
        Menu {
            ocrMenuItems
            Divider()
            translateMenuItems
            Divider()
            Button("页面管理…（⇧⌘E）") { state.editorPresented = true }
            Button(tasks.expanded ? "收起任务中心" : "任务中心（⇧⌘J）") {
                withAnimation(Design.animSpring) { tasks.expanded.toggle() }
            }
            Button("AI 中心…") { openWindow(id: "ai-center") }
        } label: {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("识别 / 翻译 / 页面 / 任务 / AI")
    }

    private var folderMenu: some View {
        Menu {
            Button("打开… (⌘O)") { state.openPanel() }
            if !state.recentFiles.isEmpty {
                Divider()
                Menu("最近打开") {
                    ForEach(state.recentFiles.prefix(8), id: \.absoluteString) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { state.open(url: url) }
                    }
                }
                Divider()
                Button("清除最近打开记录") {
                    state.recentFiles = []
                    UserDefaults.standard.removeObject(forKey: "qingyue.recents")
                }
            }
            if state.document != nil {
                Divider()
                Button("关闭文档 (⌥⌘W)") { state.requestClose() }
            }
        } label: {
            Image(systemName: "folder").font(.system(size: 14, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("打开 / 最近打开 / 关闭")
    }

    // MARK: 菜单内容

    @ViewBuilder private var ocrMenuItems: some View {
        Button("识别当前页（⇧⌘O）") {
            ReaderActions.runOCRPage(state: state, ai: ai, tasks: tasks, ocr: ocr)
        }
        Button("识别整篇（⌥⌘O）") {
            ReaderActions.runOCRDocument(state: state, ai: ai, tasks: tasks, ocr: ocr)
        }
        Divider()
        Button("框选区域识别 / 翻译") { state.tool = .region }
        Divider()
        Button("导出识别文本…") { ReaderActions.exportOCRText(state: state, ocr: ocr) }
        Button("导出可搜索 PDF…") {
            ReaderActions.exportSearchablePDF(state: state, ocr: ocr, tasks: tasks)
        }
    }

    @ViewBuilder private var translateMenuItems: some View {
        Button("翻译选中文字（⌥⌘T）") {
            ReaderActions.translateSelection(state: state, ai: ai, tasks: tasks, translate: translate)
        }
        Button("翻译当前页（⇧⌘P）") {
            ReaderActions.translateCurrentPage(state: state, ai: ai, tasks: tasks, translate: translate)
        }
        Button("翻译整篇（⌥⌘P）") {
            ReaderActions.translateDocument(state: state, ai: ai, tasks: tasks, translate: translate)
        }
        Divider()
        Button(translate.paneVisible ? "隐藏译文对照（⇧⌘T）" : "显示译文对照（⇧⌘T）") {
            withAnimation(Design.animPanel) { translate.paneVisible.toggle() }
        }
        Divider()
        Button("导出译文…") {
            ReaderActions.exportTranslation(state: state, ai: ai, translate: translate, bilingual: false)
        }
        Button("导出原文译文对照…") {
            ReaderActions.exportTranslation(state: state, ai: ai, translate: translate, bilingual: true)
        }
    }

    @ViewBuilder private var fileMenuItems: some View {
        Button(state.isDirty ? "保存 ● (⌘S)" : "保存 (⌘S)") { state.save() }
            .disabled(!state.isDirty)
        Button("另存为… (⇧⌘S)") { state.saveAs() }
        Divider()
        Button("旋转当前页 (⇧⌘R)") { state.rotateCurrentPage() }
        Button("打印… (⌘P)") { state.printDocument() }
        Divider()
        Button("重新打开这个文件") { if let u = state.fileURL { state.open(url: u) } }
            .disabled(state.fileURL == nil)
        Divider()
        Button("关闭文档 (⌥⌘W)") { state.requestClose() }
        Divider()
        Button("关于轻阅") { openWindow(id: "about") }
    }
}

/// 有未保存改动时的确认框（关文档 / 换文档前用）。只在主线程调用。
enum DiscardChoice { case saveAndClose, discardAndClose, cancel }

func askAboutUnsavedChanges() -> DiscardChoice {
    let alert = NSAlert()
    alert.messageText = "还有没保存的页面改动"
    alert.informativeText = "继续下去，这次的插入 / 删除 / 旋转 / 排序就没了。"
    alert.alertStyle = .warning
    alert.addButton(withTitle: "保存并继续")
    alert.addButton(withTitle: "丢弃改动")
    alert.addButton(withTitle: "取消")
    switch alert.runModal() {
    case .alertFirstButtonReturn:  return .saveAndClose
    case .alertSecondButtonReturn: return .discardAndClose
    default:                       return .cancel
    }
}

/// 页码输入框。用本地状态而不是直接绑 currentPage：
/// 原来清空输入框时 `Int("")` 是 nil，绑定值不变 → 文字又弹回去，像卡住了。
struct PageNumberField: View {
    @EnvironmentObject var state: AppState
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
            .multilineTextAlignment(.center)
            .frame(width: 34)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, on in if !on { commit() } }
            .onChange(of: state.currentPage) { _, page in
                if !focused { text = String(page) }
            }
            .onAppear { text = String(state.currentPage) }
    }

    private func commit() {
        if let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1 {
            state.goToPage(n)
            state.saveLastPage()
        }
        text = String(state.currentPage)
    }
}

// MARK: - 边栏

struct SidebarView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            // 竖排图标栏。原来用的是顶栏那排 segmented 选择器，
            // 标签从 4 个涨到 7 个之后横排放不下了 —— 竖排还能顺手把顶栏腾出来，
            // 顶栏少了 148pt，窄窗口的挤压也跟着缓解。
            tabRail
            Divider().opacity(0.6)
            VStack(spacing: 0) {
                HStack {
                    Text(state.sidebarTab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(VisualEffectBg().ignoresSafeArea())
        .onChange(of: state.ocrPaneVisible) { _, on in
            if on { state.sidebarTab = .ocr }
        }
    }

    @ViewBuilder private var content: some View {
        switch state.sidebarTab {
        case .thumbnails:  ThumbsPane()
        case .outline:     OutlinePane()
        case .summary:     SummaryPane()
        case .bookmarks:   BookmarksPane()
        case .annotations: AnnotationPane()
        case .ocr:         OCRPane()
        case .search:      SearchPane()
        }
    }

    private var tabRail: some View {
        VStack(spacing: 2) {
            ForEach(SidebarTab.allCases) { tab in
                let active = state.sidebarTab == tab
                Button {
                    withAnimation(Design.animQuick) { state.sidebarTab = tab }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.6))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(active ? Color.accentColor : Color.primary.opacity(0.0001))
                            )
                        if let n = badgeCount(tab), n > 0 {
                            Text("\(n)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3.5).padding(.vertical, 0.5)
                                .background(Capsule().fill(Color.accentColor.opacity(active ? 0.9 : 1)))
                                .offset(x: 5, y: -4)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .help(tab.tip)
                .accessibilityLabel(tab.label)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 5)
        .frame(width: 40)
    }

    /// 图标角标：书签 / 批注条数。0 就不显示，免得一屏都是小圆点。
    private func badgeCount(_ tab: SidebarTab) -> Int? {
        switch tab {
        case .bookmarks:   return state.bookmarks.count
        default:           return nil
        }
    }
}

// 缩略图
struct ThumbsPane: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let doc = state.document {
                        ForEach(0..<doc.pageCount, id: \.self) { i in
                            PageThumb(index: i)
                                .id(i)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .overlay(alignment: .top) {
                // 没有文档时这里原本是一片空白，看着像加载失败。
                if state.document == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("还没有打开文档")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("打开一份 PDF 后，这里会列出每一页的缩略图。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 28)
                }
            }
            .onChange(of: state.currentPage) { _, target in
                withAnimation(Design.animSmooth) { proxy.scrollTo(target - 1, anchor: .center) }
            }
        }
    }
}

struct PageThumb: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    let index: Int
    @State private var img: NSImage?

    var isCurrent: Bool { state.currentPage == index + 1 }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Design.controlBg(scheme))
                if let img {
                    // 绘制用的图已经按当前色调烘焙过了（见 .task），这里不用再套 colorInvert
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 156)

            Text("\(index + 1)")
                .font(.system(size: 10, weight: isCurrent ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { state.goToPage(index + 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.isBookmarked(index)
                            ? "第 \(index + 1) 页，有书签" : "第 \(index + 1) 页")
        .accessibilityAddTraits(isCurrent ? [.isSelected, .isButton] : .isButton)
        // 有书签的页在缩略图右上角挂一条小书签角标，翻页时一眼能看见
        .overlay(alignment: .topTrailing) {
            if state.isBookmarked(index) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .padding(4)
                    .background(Circle().fill(Design.barStyle(scheme)))
                    .offset(x: 5, y: -4)
                    .allowsHitTesting(false)
            }
        }
        // id 必须带上 revision 与色调：换文档 / 改页面结构后只按 index 不会重跑 task，
        // 结果就是新文档里显示着上一份的缩略图（踩过）；色调同理，不带上就会
        // 在切到夜间后继续显示亮白的那一版。
        .task(id: "\(index)-\(state.revision)-\(state.readingTint.rawValue)") {
            // 缓存命中就直接用：PDFKit 的光栅化只能在主线程做，
            // 侧栏滚出去再滚回来不该重新渲染一遍。
            // 缓存 key 也要带色调 —— 夜间版和原色版是两张不同的图，混用会串。
            let kind = state.readingTint.isDark ? "side-night" : "side"
            if let e = state.cachedThumb(index, kind: kind) { img = e.image; return }
            guard let page = state.document?.page(at: index) else {
                img = nil
                return
            }
            let raw = page.thumbnail(of: CGSize(width: 300, height: 390), for: .mediaBox)
            // 夜间把缩略图一起反相：它是整页白纸渲染出来的，不处理的话
            // 边栏一条惨白，和反相过的主视图并排，比干脆不开夜间还刺眼。
            let t = state.readingTint.bake(raw)
            state.storeThumb(index, kind: kind, image: t, ratio: 0)
            img = t
        }
    }
}

// 目录
struct OutlinePane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var summary: SummaryStore

    private var hasPdfOutline: Bool {
        (state.document?.outlineRoot?.numberOfChildren ?? 0) > 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if hasPdfOutline, let root = state.document?.outlineRoot {
                    ForEach(0..<root.numberOfChildren, id: \.self) { i in
                        if let n = root.child(at: i) {
                            OutlineRow(node: n, depth: 0)
                        }
                    }
                } else if summary.outline.isEmpty {
                    // 没有自带目录，也没生成过 → 引导去做一次自动章节
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本文档没有目录")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("可以让 AI 按每页的开头自动分出章节。")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Button {
                            withAnimation(Design.animQuick) { state.sidebarTab = .summary }
                        } label: {
                            Label("去「摘要」生成", systemImage: "list.bullet.indent")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }

                // AI 生成的章节，跟在自带目录后面
                if !summary.outline.isEmpty {
                    if hasPdfOutline {
                        Text("AI 生成的章节")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 2)
                    }
                    ForEach(summary.outline) { item in
                        Button {
                            state.goToPage(item.pageIndex + 1)
                            state.saveLastPage()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                    .frame(width: 14)
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .foregroundStyle(Color.primary)
                                Spacer(minLength: 4)
                                Text("\(item.pageIndex + 1)")
                                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .accessibilityLabel("第 \(item.pageIndex + 1) 页，\(item.title)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
    }
}

struct OutlineRow: View {
    @EnvironmentObject var state: AppState
    let node: PDFOutline
    let depth: Int
    @State private var expanded = true

    private var kidCount: Int { node.numberOfChildren }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if kidCount > 0 {
                    Button {
                        withAnimation(Design.animQuick) { expanded.toggle() }
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
                Text(node.label ?? "（未命名）")
                    .font(.system(size: 12, weight: depth == 0 ? .medium : .regular))
                    .lineLimit(1)
                    .foregroundStyle(depth == 0 ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.0001))
            )
            .contentShape(Rectangle())
            .onTapGesture { goToDest() }
            .padding(.leading, CGFloat(depth) * 14)

            if expanded && kidCount > 0 {
                ForEach(0..<kidCount, id: \.self) { i in
                    if let kid = node.child(at: i) {
                        OutlineRow(node: kid, depth: depth + 1)
                    }
                }
            }
        }
    }

    private func goToDest() {
        if let dest = node.destination {
            state.pdfView?.go(to: dest)
        }
    }
}

// 搜索
struct SearchPane: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @FocusState private var fieldFocused: Bool
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索全文…", text: $state.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit { commitSearch() }
                if !state.searchText.isEmpty {
                    GhostIconButton(systemName: "xmark.circle.fill", tip: "清除", size: 18) {
                        state.searchText = ""
                        state.searchHits = []
                        state.searchCursor = 0
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Design.controlBg(scheme)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
            .padding(.horizontal, 14)
            // 边打边搜（防抖 0.3 秒），不用每次都按回车
            .onChange(of: state.searchText) { scheduleSearch() }

            HStack(spacing: 6) {
                if state.isSearching {
                    ProgressView().controlSize(.mini)
                    Text("搜索中…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !state.searchHits.isEmpty {
                    Text("\(state.searchHits.count) 个结果")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(state.searchCursor + 1) / \(state.searchHits.count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.accentColor)
                    GhostIconButton(systemName: "chevron.up", tip: "上一个 (⇧⌘G)", size: 20) {
                        state.prevHit()
                    }
                    GhostIconButton(systemName: "chevron.down", tip: "下一个 (⌘G)", size: 20) {
                        state.nextHit()
                    }
                } else if !state.searchText.isEmpty {
                    Text("没有找到「\(state.searchText)」")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // 没输关键词时原来的列表区是纯白的 —— 用户得自己猜到"这里能搜"。
            // 给一句提示 + 两个立刻能试的动作，比留白强。
            if state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchHint
                Spacer(minLength: 0)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(state.searchHits.enumerated()), id: \.element.id) { i, hit in
                            SearchRow(hit: hit, current: i == state.searchCursor)
                                .id(hit.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
                .onChange(of: state.searchCursor) { _, i in
                    guard i >= 0, i < state.searchHits.count else { return }
                    withAnimation(Design.animSmooth) {
                        proxy.scrollTo(state.searchHits[i].id, anchor: .center)
                    }
                }
            }
            }   // 结束「有输入」分支
        }
        .onChange(of: state.searchFocusToken) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
        }
        .onDisappear { debounce?.cancel() }
    }

    /// 搜索框还空着的时候顶上来的引导。
    private var searchHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text("搜索全文")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text("输入关键词，边打边搜。命中的字会高亮，点一条就跳过去。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if state.document != nil {
                // 拿当前文档的头一段文字做个现成的查询词，省得用户干瞪眼想搜什么
                if let sample = quickSampleWord {
                    Button {
                        state.searchText = sample
                        state.runSearch()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9))
                            Text("试试搜「\(sample)」").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text("先打开一份 PDF 再来搜。")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// 从首页正文里挑一个高频词当示范。挑不出来就不出这个按钮。
    private var quickSampleWord: String? {
        guard let text = state.document?.page(at: 0)?.string, !text.isEmpty else { return nil }
        let isCJK = text.unicodeScalars.contains { $0.properties.isIdeographic }
        var tally: [String: Int] = [:]

        if isCJK {
            // 中文没有词边界，用 2~3 字的滑窗统计
            let chars = Array(text)
            for len in [3, 2] {
                guard chars.count > len else { continue }
                for i in 0...(chars.count - len) {
                    let slice = chars[i..<(i + len)]
                    guard slice.allSatisfy({
                        $0.unicodeScalars.first.map { $0.properties.isIdeographic } ?? false
                    }) else { continue }
                    // 以虚字开头的窗口基本都是噪音
                    if let head = String(slice).first, "的了是在和与有不这那".contains(head) { continue }
                    tally[String(slice), default: 0] += 1
                }
            }
        } else {
            // 英文按词切。只收 5 个字母以上的 —— 短的几乎全是 the / and / for 这类虚词，
            // 推荐出去搜出来一屏都是它，反而像坏了。
            let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted)
            for w in words where w.count >= 5 && w.count <= 12 { tally[w, default: 0] += 1 }
        }

        // 至少要出现 2 次才值得推荐，否则搜出来一条还不如不推荐
        return tally.filter { $0.value >= 2 }
                    .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .first?.key
    }

    private func scheduleSearch() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await MainActor.run { state.runSearch() }
        }
    }

    private func commitSearch() {
        debounce?.cancel()
        state.runSearch()
    }
}

struct SearchRow: View {
    @EnvironmentObject var state: AppState
    let hit: SearchHit
    var current: Bool = false

    private var base: Color { current ? .primary : .secondary }

    private var attributedSnippet: AttributedString {
        var out = AttributedString(hit.before)
        out.foregroundColor = base
        var m = AttributedString(hit.match)
        m.foregroundColor = .accentColor
        m.inlinePresentationIntent = .stronglyEmphasized
        out.append(m)
        var tail = AttributedString(hit.after)
        tail.foregroundColor = base
        out.append(tail)
        return out
    }

    var body: some View {
        Button {
            state.goTo(hit: hit)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text("第 \(hit.pageIndex + 1) 页")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                // 命中的那几个字单独染成强调色，扫一眼列表就知道对在哪。
                // 用 AttributedString 显式指定每一段的颜色，不靠外层样式继承 ——
                // 外层 foregroundStyle 对已带颜色的 run 不生效，容易看着像没上色。
                Text(attributedSnippet)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(current ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.0001)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(current ? Color.accentColor.opacity(0.5) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 逐段染色的 AttributedString 在 VoiceOver 里读不出"哪个词是命中"，
        // 直接把整条摘要按三段连起来念，并说明它在第几页。
        .accessibilityLabel("第 \(hit.pageIndex + 1) 页，\(hit.snippet)")
        .accessibilityHint(current ? "当前结果，回车跳到这一页" : "跳到这一页")
    }
}

// MARK: - 阅读区

struct ReaderCanvas: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var translate: TranslateStore
    /// 「正在朗读」是工具条的露出条件之一（暂停 / 停止得能点到）
    @EnvironmentObject var speech: SpeechReader
    @State private var paneWidth: CGFloat = 410

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                PDFKitView()

                // 框选区域的实时矩形
                // ⚠️ 用 `regionOverlayRect`（已换算到本容器坐标），**不是** `regionRect`
                // （PDFView bounds 坐标）。两者原点不重合，用错就是"框选范围和鼠标范围不一致"。
                if let rect = state.regionOverlayRect, rect.width > 4, rect.height > 4 {
                    RegionOverlay(rect: rect)
                }

                // 框选完成后的动作卡
                if let pr = state.pendingRegion {
                    // 位置也必须在**本容器坐标**里算，否则动作卡会跟框错开。
                    // viewRect 是 PDFView 坐标 —— 用 pdfView 在 window 里的 frame 换算：
                    // 容器坐标 = viewRect 相对 PDFView 的位置 + PDFView 在容器里的位置。
                    RegionActionCard(region: pr)
                        .position(x: min(max(pr.viewRect.midX + state.pdfViewOffset.dx, 150),
                                         max(160, canvasSafeWidth - 150)),
                                  y: max(52, pr.viewRect.minY + state.pdfViewOffset.dy - 26))
                }

                // 浮动批注工具条：**有选区 / 选了工具 / 框选待处理 / 正在朗读时才浮现**。
                //
                // ⚠️ 原来是无条件显示的，于是那条 12 个按钮的胶囊一直压在页面底部，
                // 正文两三行文字被盖住（`1-主界面.png` / `9-窄窗口.png` 里都能看到）。
                // 纯阅读时它既没用又挡字，是这个界面最显眼的干扰源。
                //
                // 动效：从底部上浮 + 淡入。用 `animEnter`（easeOut，快进慢停）——
                // 从下方进入就该"一动手就已经在动、然后减速停住"，easeInOut 的
                // 起步迟滞在这个方向上尤其明显（读起来像"卡了一下才冒出来"）。
                // 条件本身在 `ToolbarVisibility`（纯函数、可进测试台），
                // 这里只把视图里才有的 `speaking` 喂进去。
                if ToolbarVisibility.shouldShow(mode: state.toolbarMode,
                                               hasDocument: state.document != nil,
                                               hasSelection: state.selectionActive,
                                               tool: state.tool,
                                               hasPendingRegion: state.pendingRegion != nil,
                                               speaking: speech.speaking) {
                    VStack {
                        Spacer()
                        FloatingToolbar()
                            .padding(.bottom, 20)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    // 与快译卡同一个套路：显隐天然是一次值变化，绑上去就够，
                    // 不依赖调用点有没有包 withAnimation（那才是漏一处的根源）。
                    // 减弱动态效果时去掉"从下方滑上来"，只留淡入 ——
                    // 位移类动画是前庭功能障碍用户的主要不适来源。
                    .animation(Design.respecting(Design.animEnter),
                               value: ToolbarVisibility.shouldShow(
                                    mode: state.toolbarMode,
                                    hasDocument: state.document != nil,
                                    hasSelection: state.selectionActive,
                                    tool: state.tool,
                                    hasPendingRegion: state.pendingRegion != nil,
                                    speaking: speech.speaking))
                }

                // 页码胶囊
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("\(state.currentPage) / \(state.pageCount)")
                            .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Design.barStyle(scheme)))
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                            .padding(.trailing, 14)
                            .padding(.bottom, 22)
                    }
                }
                .allowsHitTesting(false)

                // 选区 / 区域即时翻译卡片
                VStack {
                    HStack {
                        Spacer()
                        if let card = translate.quickCard {
                            QuickTranslateCard(card: card)
                                .padding(14)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    // ⚠️ 这条绑定是快译卡能正常淡入淡出的**唯一保障**。
                    // 原来只有 `.transition`、没有对应的动画事务 → transition 退化成硬切，
                    // 表现为「关闭有动画、打开没动画」；而且行为取决于翻译面板当时开没开
                    // （外层那个 `value: translate.paneVisible` 会偶尔"顺手"救回来），
                    // 同一个动作两种行为，纯属巧合。
                    //
                    // 绑在"卡片在不在"而不是任何别的状态上：显隐天然是一次值变化，
                    // 不依赖调用点有没有包 withAnimation —— 那才是漏一处的根源。
                    .animation(Design.respecting(Design.animEnter),
                               value: translate.quickCard != nil)
                    Spacer()
                }

                // 任务中心（左下）
                TaskCenterView()

                if state.noteEditing {
                    NoteEditorCard()
                }
                if state.editingTextRegion != nil {
                    TextBoxCard()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 页面之外的留白跟着色调一起变，否则夜间模式下页面四周还是一圈白光
            .background(state.readingTint.canvasBackground)

            if translate.paneVisible {
                PaneDivider(width: $paneWidth)
                TranslatePane()
                    .frame(width: paneWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Design.animPanel, value: translate.paneVisible)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            guard u.pathExtension.lowercased() == "pdf" else {
                state.showToast("只能打开 PDF，「\(u.lastPathComponent)」不是")
                return false
            }
            state.open(url: u)
            return true
        }
    }

    private var canvasSafeWidth: CGFloat {
        900
    }
}

/// 框选矩形
struct RegionOverlay: View {
    let rect: CGRect

    var body: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

/// 框选完成后的动作卡
struct RegionActionCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var translate: TranslateStore
    let region: AppState.PendingRegion

    var body: some View {
        HStack(spacing: 6) {
            Button {
                ReaderActions.translateRegion(state: state, ai: ai, tasks: tasks, translate: translate, region: region)
                state.pendingRegion = nil
            } label: {
                Label("翻译这块", systemImage: "character.book.closed")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                ReaderActions.ocrRegion(state: state, ai: ai, tasks: tasks, translate: translate, region: region)
                state.pendingRegion = nil
            } label: {
                Label("只识别文字", systemImage: "text.viewfinder").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                state.pendingRegion = nil
                state.tool = .select
            } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                .buttonStyle(PressableButtonStyle())
                .help("取消")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(Design.barStyle(scheme)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}

/// 可拖拽调节宽度的分隔条
struct PaneDivider: View {
    @Binding var width: CGFloat
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12))
            .frame(width: hovering ? 2 : 1)
            .overlay(
                Rectangle()
                    .fill(Color.primary.opacity(0.001))
                    .frame(width: 12)
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                width = min(720, max(320, width - value.translation.width * 0.9))
                            }
                    )
            )
            .onHover { hovering = $0 }
            .animation(Design.animQuick, value: hovering)
    }
}

/// 文本框输入卡
struct TextBoxCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.cursor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("添加文本框").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("第 \((state.editingTextRegion?.pageIndex ?? 0) + 1) 页")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            TextEditor(text: $state.textBoxDraft)
                .font(.system(size: 13))
                .frame(width: 300, height: 80)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Design.textBg(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .focused($focused)
            HStack {
                Spacer()
                Button("取消") { state.editingTextRegion = nil; state.tool = .select }
                    .buttonStyle(.borderless).font(.system(size: 12))
                Button("添加") {
                    if let region = state.editingTextRegion,
                       let page = state.page(at: region.pageIndex) {
                        state.addTextBox(normalized: region.normalized, text: state.textBoxDraft, on: page)
                    }
                    state.editingTextRegion = nil
                    state.textBoxDraft = ""
                    state.tool = .select
                    state.showToast("已插入文本框")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Design.barStyle(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.0001))
        .onTapGesture { }
        .onAppear { focused = true }
    }
}

// MARK: - PDFKit 桥接

final class ToolPDFView: PDFView {
    weak var appState: AppState?
    private var dragStart: CGPoint?
    /// 最近一次右键的位置（视图坐标），供菜单动作使用
    private var contextPoint: CGPoint = .zero

    /// 拖拽类工具用十字光标，否则用户不知道"现在能框选"
    override func resetCursorRects() {
        super.resetCursorRects()
        if let st = appState, st.tool.isDragTool {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let st = appState else { return super.mouseDown(with: event) }
        let loc = convert(event.locationInWindow, from: nil)

        // 拖拽类工具：框选、文本框、涂白遮盖
        if st.tool.isDragTool {
            dragStart = loc
            st.regionRect = CGRect(origin: loc, size: .zero)
            st.regionOverlayRect = nil
            return
        }

        // 双击编辑已有便签 / 文本框
        if st.tool == .select && event.clickCount == 2 {
            if let page = self.page(for: loc, nearest: true) {
                let pp = convert(loc, to: page)
                if let ann = page.annotation(at: pp), ann.type == "FreeText" {
                    st.beginEditNote(ann, on: page)
                    return
                }
            }
        }

        switch st.tool {
        case .note:
            if let page = page(for: loc, nearest: true) {
                let pp = convert(loc, to: page)
                st.beginNewNote(at: pp, on: page)
            }
            return
        case .erase:
            if let page = page(for: loc, nearest: true) {
                let pp = convert(loc, to: page)
                if let ann = page.annotation(at: pp) {
                    page.removeAnnotation(ann)
                    st.revision += 1
                    let saved = st.persistIfPossible()
                    st.showToast(saved ? "已删除这条批注" : "已删除这条批注（原文件写不进去）")
                }
            }
            return
        default:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let st = appState, let start = dragStart, st.tool.isDragTool else {
            return super.mouseDragged(with: event)
        }
        let loc = convert(event.locationInWindow, from: nil)
        let rect = CGRect(x: min(start.x, loc.x), y: min(start.y, loc.y),
                          width: abs(loc.x - start.x), height: abs(loc.y - start.y))
        st.regionRect = rect
        st.regionOverlayRect = overlayRect(for: rect)
    }

    /// 把 PDFView 视图坐标的矩形换算到 **SwiftUI 宿主容器坐标**。
    ///
    /// ⚠️ 这就是"框选范围和鼠标范围不一致"的修法。
    /// 画框的 `RegionOverlay` 挂在 SwiftUI 的 ZStack 上、用 `.position()` 定位，
    /// 而这里的鼠标坐标是 PDFView **bounds** 坐标 —— 两者原点不重合
    /// （`pageBreakMargins` 14pt + 页面居中留白 + 页面阴影，偏移量随缩放/页数/窗口宽度变化）。
    ///
    /// 走 window 坐标中转，而不是自己减偏移量 —— 偏移不是常数，猜不出来。
    func overlayRect(for rect: CGRect) -> CGRect? {
        guard let sup = superview else { return nil }
        let inWindow = convert(rect, to: nil)              // bounds → window
        return sup.convert(inWindow, from: nil)           // window → 宿主容器
    }

    override func mouseUp(with event: NSEvent) {
        guard let st = appState else { return super.mouseUp(with: event) }

        // 拖拽框选
        if st.tool.isDragTool, let start = dragStart {
            let loc = convert(event.locationInWindow, from: nil)
            let rect = CGRect(x: min(start.x, loc.x), y: min(start.y, loc.y),
                              width: abs(loc.x - start.x), height: abs(loc.y - start.y))
            dragStart = nil
            st.regionOverlayRect = nil
            if rect.width < 10 || rect.height < 10 {
                st.regionRect = nil
                return
            }
            st.finishRegionDrag(rect)
            return
        }

        super.mouseUp(with: event)

        // 标记类工具：松开鼠标就把拖出来的选区变成批注。
        // 之前这里什么也没做，`applySelectionTool` 是个没人调用的死函数，
        // 所以工具条上的高亮 / 下划线 / 删除线按了等于没按。
        if st.tool == .highlight || st.tool == .underline || st.tool == .strikeout {
            st.applySelectionTool(st.tool)
        }
    }

    /// 右键菜单：选中文字后的自然操作（复制 / 标记 / 翻译），点到批注时给删除入口
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let st = appState else { return super.menu(for: event) }
        let loc = convert(event.locationInWindow, from: nil)
        contextPoint = loc
        guard let page = page(for: loc, nearest: true) else { return super.menu(for: event) }
        let pp = convert(loc, to: page)
        let ann = page.annotation(at: pp)
        // 右键菜单是**打开那一刻**现算的：菜单不订阅任何 @Published，
        // 用缓存的 selectionActive 会读到"菜单上一次打开时"的状态。
        let hasSelection = st.computeSelectionActive()

        var items: [NSMenuItem] = []
        func add(_ title: String, _ action: Selector) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
            it.target = self
            items.append(it)
        }

        if let ann {
            if ann.type == "FreeText" {
                add("编辑这段文字…", #selector(menuEditAnnotation))
            }
            add("删除这个批注", #selector(menuDeleteAnnotation))
        }

        if hasSelection {
            if !items.isEmpty { items.append(.separator()) }
            add("复制", #selector(menuCopy))
            add("高亮选中文字", #selector(menuHighlight))
            add("下划线", #selector(menuUnderline))
            add("翻译选中文字", #selector(menuTranslate))
        }

        guard !items.isEmpty else { return super.menu(for: event) }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    // MARK: 右键菜单动作

    @objc private func menuCopy() {
        guard let s = currentSelection?.string, !s.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        appState?.showToast("已复制选中文字")
    }

    @objc private func menuHighlight() { appState?.applySelectionTool(.highlight) }
    @objc private func menuUnderline() { appState?.applySelectionTool(.underline) }
    @objc private func menuTranslate() { appState?.translateSelectionAction?() }

    @objc private func menuDeleteAnnotation() {
        guard let st = appState else { return }
        let loc = contextPoint
        guard let page = page(for: loc, nearest: true) else { return }
        guard let ann = page.annotation(at: convert(loc, to: page)) else { return }
        page.removeAnnotation(ann)
        st.revision += 1
        let saved = st.persistIfPossible()
        st.showToast(saved ? "已删除这条批注" : "已删除这条批注（原文件写不进去）")
    }

    @objc private func menuEditAnnotation() {
        guard let st = appState else { return }
        let loc = contextPoint
        guard let page = page(for: loc, nearest: true),
              let ann = page.annotation(at: convert(loc, to: page)) else { return }
        st.beginEditNote(ann, on: page)
    }
}

struct PDFKitView: NSViewRepresentable {
    @EnvironmentObject var state: AppState

    static func dynamicBackground() -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.92, alpha: 1)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ToolPDFView {
        let v = ToolPDFView()
        v.autoScales = true
        v.displayMode = state.displayMode
        v.displaysPageBreaks = true
        v.pageBreakMargins = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        v.backgroundColor = Self.dynamicBackground()
        v.minScaleFactor = 0.1
        v.maxScaleFactor = 8.0
        v.document = state.document
        v.appState = state
        state.pdfView = v

        let c = context.coordinator
        c.state = state
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged(_:)),
                                               name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.scaleChanged(_:)),
                                               name: .PDFViewScaleChanged, object: v)
        // ⚠️ 选区变化**必须**单独监听。少了这一条，「选中即问」按钮的高亮就永远不亮：
        // `currentSelection` 变了不会让 `updateNSView` 重跑、也没有别的 @Published 跟着变，
        // 于是 SwiftUI 压根不知道要把工具条重画一遍（表现是「有时候会亮」——
        // 取决于别的状态有没有恰好变过）。这是个不报错的静默失效。
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.selectionChanged(_:)),
                                               name: .PDFViewSelectionChanged, object: v)
        return v
    }

    func updateNSView(_ v: ToolPDFView, context: Context) {
        // 每帧回写「PDFView 相对宿主容器的偏移」。
        // 窗口缩放 / 侧栏开合 / 顶栏高度变化都会让它变，所以不能在初始化时算一次。
        // ⚠️ 只在真的变了才写：它一改就是一次 @Published 触发，会引起额外重算。
        if let sup = v.superview {
            let f = sup.convert(v.frame, from: v.superview)
            let off = CGVector(dx: f.minX, dy: f.minY)
            if state.pdfViewOffset != off {
                DispatchQueue.main.async { state.pdfViewOffset = off }
            }
        }
        if v.document !== state.document {
            v.document = state.document
        }
        if v.displayMode != state.displayMode {
            v.displayMode = state.displayMode
        }
        if v.autoScales != state.autoScales {
            v.autoScales = state.autoScales
        }
        v.appState = state
        context.coordinator.state = state
        // 阅读色调（护眼 / 夜间）。见 ReadingTint 的说明：走图层滤镜而不是叠色，
        // 因为夜间要的是**反相**（白底变深、黑字变浅），叠一层半透明色做不到。
        applyTint(to: v)
        // 换了工具就刷新光标（框选类工具要变十字）
        if context.coordinator.lastTool != state.tool {
            context.coordinator.lastTool = state.tool
            v.window?.invalidateCursorRects(for: v)
        }
    }

    /// `CALayer.filters` 的作用域是「本层及其子层」，PDF 的页面层、批注层、
    /// 选区层都在 PDFView 的层树里，所以一刀切全生效；而外面的浮动工具条、
    /// 边栏不在这棵树里，不受影响 —— 正是想要的效果。
    ///
    /// ⚠️ 两个坑，少一个都"静默不生效"（不报错、不打日志、图还是原色）：
    /// 1. **AppKit 默认不启用图层滤镜**，必须显式 `layerUsesCoreImageFilters = true`。
    ///    这是历史遗留的性能开关，`wantsLayer = true` 并不包含它。
    /// 2. 这个属性会重建图层树，要在设 `filters` **之前**赋值，否则那一帧的滤镜会被丢掉。
    private func applyTint(to v: ToolPDFView) {
        let wanted = state.readingTint
        let key = "qingyueTint"
        // 只在色调真的变了时才动图层：`backgroundColor` 是动态色，
        // 每次都比较会一直判不相等，导致 updateNSView 里反复触发重绘。
        guard (v.layer?.value(forKey: key) as? String) != wanted.rawValue else { return }
        v.wantsLayer = true
        // 底色要填"滤镜之前"的颜色 —— 夜间模式填深色的话反相后会变浅，页面和留白就颠倒了
        v.backgroundColor = wanted.pdfViewBackground
        let filters = wanted.makeFilters()
        // 关掉滤镜时要连开关一起复位，否则留着一层空的 CI 合成路径白耗性能
        v.layerUsesCoreImageFilters = !filters.isEmpty
        v.layer?.setValue(wanted.rawValue, forKey: key)
        v.layer?.filters = filters.isEmpty ? nil : filters
        v.layer?.setNeedsDisplay()
    }

    static func dismantleNSView(_ v: ToolPDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        weak var state: AppState?
        var lastTool: Tool?

        @objc func pageChanged(_ n: Notification) {
            guard let v = n.object as? PDFView, let st = state,
                  let doc = v.document, let page = v.currentPage else { return }
            let idx = doc.index(for: page) + 1
            if st.currentPage != idx {
                st.currentPage = idx
                st.saveLastPage()
            }
        }

        @objc func scaleChanged(_ n: Notification) {
            guard let v = n.object as? PDFView, let st = state else { return }
            let pct = Int(round(v.scaleFactor * 100))
            if st.scalePercent != pct { st.scalePercent = pct }
        }

        /// 选区变了 → 回写 `@Published selectionActive`。
        ///
        /// 真值用 `computeSelectionActive()` 现算（与右键菜单同一条逻辑），
        /// 这里只负责"发现变化就通知界面"，不自己判断选区是否有效。
        @objc func selectionChanged(_ n: Notification) {
            guard let st = state else { return }
            let active = st.computeSelectionActive()
            // 只在真的变了才写：选区在一次拖拽里会连发好几条通知，
            // 每次都赋值会让工具条反复重算（虽然无害，但没必要）。
            if st.selectionActive != active {
                withAnimation(Design.animQuick) { st.selectionActive = active }
            }
        }
    }
}

// MARK: - 拖放提示

/// 拖 PDF 悬在窗口上时盖的那层提示。
///
/// 少了它用户不知道松手会不会生效 —— 而"松手了却没反应"是拖放最常见的困惑。
struct DropOverlay: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color.black.opacity(0.32)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 40, weight: .light))
                Text("松手即打开")
                    .font(.system(size: 15, weight: .medium))
                Text("一次一份 · 只支持 PDF")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
        // 不吃掉鼠标事件，否则悬停态会立刻消失、提示一闪而过
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - 浮动工具条

struct FloatingToolbar: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var tasks: TaskCenter
    @EnvironmentObject var translate: TranslateStore
    @EnvironmentObject var speech: SpeechReader
    @EnvironmentObject var ocr: OCRStore

    var body: some View {
        HStack(spacing: 3) {
            // 显示模式
            GhostIconButton(
                systemName: state.displayMode == .twoUp || state.displayMode == .twoUpContinuous
                    ? "rectangle.righthalf.inset.filled" : "rectangle",
                tip: "单页 / 双页 (⌘2)", size: 30
            ) { state.toggleDisplayMode() }

            toolbarDivider

            ForEach([Tool.select, .region, .highlight, .underline, .strikeout, .note, .textbox, .whiteout, .erase]) { t in
                toolButton(t)
            }

            toolbarDivider

            // 选中即问：选中一段文字后，除了翻译还能让它解释 / 概括 / 追问
            askMenu

            // 朗读：读选中的文字，没选中就读当前页
            GhostIconButton(systemName: speech.speaking ? "stop.circle.fill" : "speaker.wave.2",
                            tip: speech.speaking ? "停止朗读" : "朗读选中文字 / 本页 (⌥⌘S)",
                            size: 30) {
                toggleSpeech()
            }
            .foregroundStyle(speech.speaking ? Color.accentColor : Color.primary.opacity(0.72))

            toolbarDivider

            GhostIconButton(systemName: "rotate.right", tip: "旋转当前页 (⇧⌘R)", size: 30) {
                state.rotateCurrentPage()
            }
            GhostIconButton(systemName: "printer", tip: "打印 (⌘P)", size: 30) {
                state.printDocument()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Design.barStyle(scheme)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 4)
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }

    private var askMenu: some View {
        Menu {
            ForEach(AskMode.allCases) { mode in
                Button(mode.label) { runAsk(mode) }
            }
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.selectionActive ? Color.accentColor : Color.primary.opacity(0.4))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30)
        .help("对选中文字用 AI：解释 / 概括 / 翻译 / 追问")
    }

    private func runAsk(_ mode: AskMode) {
        guard let sel = state.pdfView?.currentSelection?.string,
              !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.showToast("先在页面上选中一段文字")
            return
        }
        if mode == .custom {
            // 追问：拿系统弹窗要一句话，不想为这个再搭一套输入框
            let alert = NSAlert()
            alert.messageText = "追问这段文字"
            alert.informativeText = "选中了 \(sel.count) 个字。想问什么？"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "例如：这里的「一致性」具体指什么？"
            alert.accessoryView = field
            alert.addButton(withTitle: "提问")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return }
            AskAI.run(text: sel, mode: .custom, question: q, ai: ai, tasks: tasks, translate: translate)
            return
        }
        AskAI.run(text: sel, mode: mode, ai: ai, tasks: tasks, translate: translate)
    }

    private func toggleSpeech() {
        if speech.speaking { speech.stop(); return }
        if let sel = state.pdfView?.currentSelection?.string,
           !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speech.speak(sel, title: "选中文字（第 \(state.currentPage) 页）")
            return
        }
        // 没选中：读当前页。扫描件没有文本层时退回 OCR 结果
        var text = state.currentPageText()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = ocr.results[state.currentPage - 1]?.text ?? ""
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state.showToast("这一页没有可读的文字，先做一次 OCR 吧")
            return
        }
        speech.speak(text, title: "第 \(state.currentPage) 页")
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func toolButton(_ t: Tool) -> some View {
        let active = state.tool == t
        Button {
            state.tool = active ? .select : t
        } label: {
            Image(systemName: t.icon)
                .font(.system(size: 13, weight: .medium))
            .foregroundStyle(active ? Color.white : Color.primary.opacity(0.72))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(active ? Color.accentColor : Color.primary.opacity(0.0001))
            )
        }
        .buttonStyle(PressableButtonStyle())
        .help(t.label)
        .accessibilityLabel(t.label)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
        .animation(Design.animQuick, value: active)
    }
}

// MARK: - 便签编辑卡片

struct NoteEditorCard: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "text.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(state.noteDraftExisting == nil ? "新便签" : "编辑便签")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                GhostIconButton(systemName: "xmark", tip: "取消", size: 18) { state.cancelNote() }
            }

            TextEditor(text: $state.noteDraftText)
                .font(.system(size: 13))
                .frame(width: 280, height: 84)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Design.controlBg(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .focused($focused)

            HStack {
                if state.noteDraftExisting != nil {
                    Button(role: .destructive) {
                        if let page = state.noteDraftPage, let ann = state.noteDraftExisting {
                            page.removeAnnotation(ann)
                        }
                        state.cancelNote()
                    } label: {
                        Text("删除").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button {
                    state.cancelNote()
                } label: {
                    Text("取消").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                Button {
                    state.commitNote()
                } label: {
                    Text(state.noteDraftExisting == nil ? "添加" : "保存")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Design.barStyle(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.0001))
        .onTapGesture { }  // 吞掉点击，防止误触页面
        .onAppear { focused = true }
        .onSubmit { state.commitNote() }
    }
}

// MARK: - 空状态（启动页）

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack {
            // 柔和渐变底
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.13, green: 0.12, blue: 0.22), Design.windowBg(scheme)]
                    : [Color(red: 0.93, green: 0.92, blue: 1.0), Design.windowBg(scheme)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.42, green: 0.36, blue: 0.98),
                                         Color(red: 0.62, green: 0.40, blue: 0.95)],
                                startPoint: .top, endPoint: .bottom))
                            .shadow(color: Color(red: 0.42, green: 0.36, blue: 0.98).opacity(0.4), radius: 18, y: 8)
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 86, height: 86)

                    VStack(spacing: 5) {
                        Text("轻阅")
                            .font(.system(size: 26, weight: .bold))
                        Text("轻快的 PDF 阅读器")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                // 拖放区
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                    Text("拖入 PDF 文件")
                        .font(.system(size: 14, weight: .medium))
                    Text("或")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button {
                        state.openPanel()
                    } label: {
                        Text("打开文件")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: 340)
                .padding(.vertical, 30)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Design.controlBg(scheme).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(
                            Color.primary.opacity(0.16),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                        )
                )

                // 最近文件
                if !state.recentFiles.isEmpty {
                    VStack(spacing: 6) {
                        Text("最近打开")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        ForEach(state.recentFiles.prefix(5), id: \.absoluteString) { url in
                            Button {
                                state.open(url: url)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                    Text(url.deletingPathExtension().lastPathComponent)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.primary.opacity(0.05)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 版权入口：启动页是最容易被看到的地方，开发人员信息放这儿
                HStack(spacing: 8) {
                    Button("关于轻阅") { openWindow(id: "about") }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    Text("·").foregroundStyle(.tertiary)
                    Text("开发人员 \(AppInfo.author)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            }
            .padding(40)
        }
        .dropDestination(for: URL.self) { urls, _ in
            if let u = urls.first, u.pathExtension.lowercased() == "pdf" {
                state.open(url: u)
                return true
            }
            return false
        }
    }
}

// MARK: - 基础组件

/// 操作反馈条。所有 `showToast(...)` 都落到这里，
/// 之前这个状态只被写、没人画，用户点了按钮完全没反馈。
struct ToastView: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    /// 提示里带这些词的是"没做成"，不该打绿勾
    private var isWarning: Bool {
        ["请先", "不能", "无法", "失败", "还没有", "没有", "写不进去", "没能", "没在"].contains { text.contains($0) }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isWarning ? Color.orange : Color(red: 0.20, green: 0.66, blue: 0.42))
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Design.barStyle(scheme)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
    }
}

/// 把窗口标题设成文档名。
/// 不设的话，Mission Control / 窗口菜单 / 程序切换器里显示的是可执行文件名 "QingYue"。
struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { v.window?.title = title }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            if v.window?.title != title { v.window?.title = title }
        }
    }
}

struct GhostIconButton: View {
    let systemName: String
    var tip: String = ""
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .medium))
                .foregroundStyle(hover ? Color.primary : Color.primary.opacity(0.62))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.26)
                        .fill(Color.primary.opacity(hover ? 0.08 : 0.0001))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hover = $0 }
        .animation(Design.animQuick, value: hover)
        .help(tip)
        // 纯图标按钮在 VoiceOver 下原本只能读出 "button"。
        // tip 是现成的人话描述，直接拿来当无障碍标签；没写 tip 的退回图标名，
        // 好歹能听出是个什么东西，不至于变成一串无意义的控件。
        .accessibilityLabel(tip.isEmpty ? systemName : tip)
    }
}

struct VisualEffectBg: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// 标题栏拖拽区
final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct DragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView {
        let v = DragView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }
    func updateNSView(_ v: DragView, context: Context) {}
}
