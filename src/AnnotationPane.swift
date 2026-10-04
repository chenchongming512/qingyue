import SwiftUI
import AppKit
import PDFKit

// MARK: - 批注列表的界面部分
// 纯逻辑（AnnotationEntry / AnnotationScan）在 AnnotationCore.swift ——
// 拆开是为了让测试台不必把整个 SwiftUI 界面编进来。

struct AnnotationPane: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ocr: OCRStore
    @State private var entries: [AnnotationEntry] = []
    @State private var scanning = false
    @State private var onlyCurrentPage = false

    private var shown: [AnnotationEntry] {
        onlyCurrentPage ? entries.filter { $0.pageIndex == state.currentPage - 1 } : entries
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            // ⚠️ 三个分支（扫描中 / 空态 / 列表）高度差很大，又没有统一框高：
            // `rescan()` 一开始，列表被整条提示替换成两行细字，整个面板内容会向下塌陷一下，
            // 扫完再弹回来。宽度不变所以横向不跳，纵向这个"抽一下"很明显。
            //
            // 给内容区一个固定的最小高度，把占位与首屏对齐。
            // （同样的道理可以套到别的"三分支"面板上 —— 这类塌陷都是同一根因。）
            Group {
                if scanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在统计批注…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if shown.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .top)
            if !entries.isEmpty { footer }
        }
        // revision 一变（加 / 删批注、改页面结构、换文档）就重扫
        .task(id: state.revision) { await rescan() }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $onlyCurrentPage) {
                Text("只看本页").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .disabled(entries.isEmpty)
            Spacer()
            Button {
                Task { await rescan() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("重新统计")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "highlighter")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("这份文档还没有批注")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("选中文字后按高亮 / 下划线 / 删除线，\n或者用便签工具写点东西，\n都会汇总到这里。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(shown) { e in
                    row(e)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
        }
    }

    private func row(_ e: AnnotationEntry) -> some View {
        Button {
            jump(to: e)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: e.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(e.color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(e.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(e.color)
                        Text("第 \(e.pageIndex + 1) 页")
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if !e.text.isEmpty {
                        Text(e.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    if !e.note.isEmpty {
                        Text(e.note)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    if e.isEmpty {
                        Text("（无文字内容）")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(e.label)，第 \(e.pageIndex + 1) 页，\(e.text)")
        .contextMenu {
            Button("跳转") { jump(to: e) }
            Button("复制内容") { copy(e) }
            Divider()
            Button("删除这条批注", role: .destructive) { remove(e) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Text("\(shown.count) / \(entries.count) 条")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    exportMarkdown()
                } label: {
                    Label("导出笔记", systemImage: "square.and.arrow.up").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("把批注整理成 Markdown 读书笔记")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // ---------- 动作 ----------

    private func rescan() async {
        guard let doc = state.document else { entries = []; return }
        scanning = true
        let snapshotOCR: (Int) -> String = { [weak ocr] i in ocr?.results[i]?.text ?? "" }
        // 反查文字要逐字符比对，几百毫秒的事，放后台。
        // ⚠️ PDFDocument 不是线程安全 —— 按本项目统一的规矩：
        // 主线程先拍一份独立快照，后台只碰这份副本（导出路径也是这么做的）。
        let snapshot = doc.dataRepresentation()
        let result = await Task.detached(priority: .userInitiated) { () -> [AnnotationEntry] in
            guard let snapshot, let copy = PDFDocument(data: snapshot) else { return [] }
            return AnnotationScan.scan(copy, ocrText: snapshotOCR)
        }.value
        entries = result
        scanning = false
    }

    private func jump(to e: AnnotationEntry) {
        state.goToPage(e.pageIndex + 1)
        state.saveLastPage()
        guard let v = state.pdfView, let doc = state.document,
              let page = doc.page(at: e.pageIndex) else { return }
        // 把这一条批注选中并滚到视野里
        if AnnotationScan.isTextMarkup(e.annotation) {
            let b = e.annotation.bounds
            let sel = page.selection(for: b)
            if let sel {
                v.setCurrentSelection(sel, animate: true)
                v.go(to: sel)
                return
            }
        }
        let dest = PDFDestination(page: page,
                                  at: CGPoint(x: 0, y: e.annotation.bounds.maxY + 60))
        v.go(to: dest)
    }

    private func copy(_ e: AnnotationEntry) {
        var s = "\(e.label)（第 \(e.pageIndex + 1) 页）"
        if !e.text.isEmpty { s += "\n\(e.text)" }
        if !e.note.isEmpty { s += "\n备注：\(e.note)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        state.showToast("已复制")
    }

    private func remove(_ e: AnnotationEntry) {
        guard let doc = state.document, let page = doc.page(at: e.pageIndex) else { return }
        page.removeAnnotation(e.annotation)
        entries.removeAll { $0.id == e.id }
        state.revision += 1
        let saved = state.persistIfPossible()
        state.showToast(saved ? "已删除这条批注" : "已删除（原文件写不进去）")
    }

    private func exportMarkdown() {
        let md = AnnotationScan.markdown(entries, title: state.documentTitle)
        guard !md.isEmpty else { return }
        ReaderActions.exportText(md, suggestedName: "\(state.documentTitle)-批注",
                                 fileExtension: "md", state: state, successToast: "已导出批注笔记")
    }
}
