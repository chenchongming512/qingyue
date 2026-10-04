// 轻阅 · 书签（阅读位置标记）
//
// 和"记住上次读到第几页"不是一回事：那是自动的、只有一条；书签是用户主动标的、可以有很多条，
// 还能带标题与备注。按文档路径存 UserDefaults，换文档不串档。

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - AppState 接线

extension AppState {

    /// 当前页是否有书签
    var hasBookmarkOnCurrentPage: Bool {
        bookmarks.contains { $0.pageIndex == currentPage - 1 }
    }

    func isBookmarked(_ pageIndex: Int) -> Bool {
        bookmarks.contains { $0.pageIndex == pageIndex }
    }

    /// ⌘D：当前页有书签就取消，没有就加上
    func toggleBookmark() {
        guard document != nil else { return }
        let idx = currentPage - 1
        if let existing = bookmarks.first(where: { $0.pageIndex == idx }) {
            bookmarks.removeAll { $0.id == existing.id }
            persistBookmarks()
            showToast("已移除第 \(idx + 1) 页的书签")
        } else {
            addBookmark(pageIndex: idx)
        }
    }

    @discardableResult
    func addBookmark(pageIndex: Int, title: String? = nil, note: String = "") -> Bookmark? {
        guard let doc = document, pageIndex >= 0, pageIndex < doc.pageCount else { return nil }
        guard !isBookmarked(pageIndex) else {
            showToast("第 \(pageIndex + 1) 页已经有书签了")
            return nil
        }
        let name = title ?? defaultBookmarkTitle(pageIndex: pageIndex)
        let bm = Bookmark(pageIndex: pageIndex, title: name, note: note, y: currentScrollFraction())
        bookmarks.append(bm)
        bookmarks.sort { $0.pageIndex < $1.pageIndex }
        persistBookmarks()
        showToast("已加书签：\(name)")
        return bm
    }

    /// 默认标题：优先用该页首行文字（比"第 12 页"有用得多）
    private func defaultBookmarkTitle(pageIndex: Int) -> String {
        guard let text = document?.page(at: pageIndex)?.string else { return "第 \(pageIndex + 1) 页" }
        let firstLine = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.count > 1 }
        guard let line = firstLine else { return "第 \(pageIndex + 1) 页" }
        let trimmed = String(line.prefix(28))
        return trimmed + (line.count > 28 ? "…" : "")
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persistBookmarks()
    }

    func updateBookmark(id: UUID, title: String, note: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks[i].note = note
        if bookmarks[i].title.isEmpty { bookmarks[i].title = "第 \(bookmarks[i].pageIndex + 1) 页" }
        persistBookmarks()
    }

    func goToBookmark(_ b: Bookmark) {
        goToPage(b.pageIndex + 1)
        saveLastPage()
        // 再往页内挪一点，回到当初标书签时看的那一块
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let v = self.pdfView,
                  let page = self.document?.page(at: b.pageIndex) else { return }
            let bounds = page.bounds(for: v.displayBox)
            let clamped = min(max(b.y, 0), 1)
            let dest = PDFDestination(page: page,
                                      at: CGPoint(x: 0, y: bounds.minY + bounds.height * clamped))
            v.go(to: dest)
        }
    }

    func persistBookmarks() {
        BookmarkStore.save(bookmarks, for: fileURL)
    }

    /// 当前页在可见区域里的纵向比例（1 = 页顶），用来记书签位置
    func currentScrollFraction() -> Double {
        guard let v = pdfView, let page = v.currentPage else { return 1 }
        let pageBounds = page.bounds(for: v.displayBox)
        guard pageBounds.height > 1 else { return 1 }
        let visible = v.convert(v.bounds, to: page)
        let top = visible.maxY
        let f = (top - pageBounds.minY) / pageBounds.height
        return min(max(Double(f), 0), 1)
    }
}

// MARK: - 边栏面板

struct BookmarksPane: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var editing: Bookmark?
    @State private var draftTitle = ""
    @State private var draftNote = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if state.bookmarks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(state.bookmarks) { b in
                            row(b)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
            }

            if !state.bookmarks.isEmpty { footer }
        }
        .sheet(item: $editing) { b in
            editor(for: b)
        }
    }

    // 顶部：为当前页加书签
    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                state.toggleBookmark()
            } label: {
                Label(state.hasBookmarkOnCurrentPage ? "取消本页书签" : "为第 \(state.currentPage) 页加书签",
                      systemImage: state.hasBookmarkOnCurrentPage ? "bookmark.slash" : "bookmark")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut("d", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bookmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("还没有书签")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("按 ⌘D 把当前页标下来。\n书签会跟着文件保存在本机，\n下次打开还在。")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }

    private func row(_ b: Bookmark) -> some View {
        Button {
            state.goToBookmark(b)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !b.note.isEmpty {
                        Text(b.note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text("第 \(b.pageIndex + 1) 页")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("书签 \(b.title)，第 \(b.pageIndex + 1) 页")
        .contextMenu {
            Button("跳转") { state.goToBookmark(b) }
            Button("编辑标题与备注…") { beginEdit(b) }
            Divider()
            Button("删除书签", role: .destructive) { state.removeBookmark(id: b.id) }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            HStack(spacing: 8) {
                Text("\(state.bookmarks.count) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    exportMarkdown()
                } label: {
                    Label("导出笔记", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("把书签导出成 Markdown 读书笔记")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    private func beginEdit(_ b: Bookmark) {
        draftTitle = b.title
        draftNote = b.note
        editing = b
    }

    private func editor(for b: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑书签")
                .font(.system(size: 14, weight: .semibold))
            Text("第 \(b.pageIndex + 1) 页")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("标题", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextEditor(text: $draftNote)
                .font(.system(size: 12))
                .frame(height: 90)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Design.textBg(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))

            HStack {
                Spacer()
                Button("取消") { editing = nil }
                    .buttonStyle(.borderless)
                Button("保存") {
                    state.updateBookmark(id: b.id, title: draftTitle, note: draftNote)
                    editing = nil
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 380)
    }

    private func exportMarkdown() {
        let md = BookmarkStore.markdown(state.bookmarks, title: state.documentTitle)
        guard !md.isEmpty else { return }
        ReaderActions.exportText(md, suggestedName: "\(state.documentTitle)-书签",
                                 fileExtension: "md", state: state, successToast: "已导出书签笔记")
    }
}
