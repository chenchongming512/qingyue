// 轻阅 · 页面管理：插入、复制、删除、移动、旋转、提取导出（每一步都可撤销）

import SwiftUI
import PDFKit
import AppKit

struct PageEditorView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let doc = state.document {
                // 列数跟着页数走：页少时列少、缩略图就大，不会出现"三张小图 + 一大片空白"
                let cols = max(1, min(5, doc.pageCount))
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: cols),
                              spacing: 14) {
                        ForEach(0..<doc.pageCount, id: \.self) { i in
                            EditorThumb(index: i, selected: selection.contains(i), revision: state.revision)
                                .onTapGesture { toggle(i) }
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("没有打开的文档").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("页面管理").font(.system(size: 14, weight: .semibold))
            Text(state.document.map { "共 \($0.pageCount) 页" } ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Divider().frame(height: 16)

            group("选择") {
                Button("全选") { selection = Set(0..<(state.pageCount)) }.controlSize(.small)
                Button("反选") { selection = Set(0..<state.pageCount).subtracting(selection) }.controlSize(.small)
                Button("清空") { selection.removeAll() }.controlSize(.small)
                    .disabled(selection.isEmpty)
            }

            Spacer()

            Text(selection.isEmpty ? "未选中页面" : "已选 \(selection.count) 页")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selection.isEmpty ? Color.secondary : Color.accentColor)

            Button {
                dismiss()
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: 底部操作

    private var footer: some View {
        HStack(spacing: 10) {
            Menu {
                Button("旋转 90°（右）") { act { state.rotatePages(targets, by: 90) } }
                Button("旋转 90°（左）") { act { state.rotatePages(targets, by: -90) } }
                Button("旋转 180°") { act { state.rotatePages(targets, by: 180) } }
                Divider()
                Button("全部页面顺时针 90°") { act { state.rotatePages(Array(0..<state.pageCount), by: 90) } }
            } label: { Label("旋转", systemImage: "rotate.right") }
                .menuStyle(.borderlessButton).fixedSize()

            Button {
                act { state.duplicatePages(targets) }
            } label: { Label("复制", systemImage: "plus.square.on.square") }
                .disabled(selection.isEmpty)

            Button {
                act { state.insertBlankPage(after: targets.max() ?? state.currentPage - 1) }
            } label: { Label("插入空白页", systemImage: "rectangle.badge.plus") }

            Button {
                act { state.insertPagesFromFile() }
            } label: { Label("从 PDF 插入", systemImage: "doc.badge.plus") }

            Divider().frame(height: 18)

            Button {
                act { state.movePage(targets.first ?? 0, by: -1) }
            } label: { Label("上移", systemImage: "arrow.up") }
                .disabled(selection.count != 1 || (selection.first ?? 0) == 0)

            Button {
                act { state.movePage(targets.first ?? 0, by: 1) }
            } label: { Label("下移", systemImage: "arrow.down") }
                .disabled(selection.count != 1 || (selection.first ?? 0) >= state.pageCount - 1)

            Button {
                act { state.exportPages(targets) }
            } label: { Label("导出所选", systemImage: "square.and.arrow.up") }
                .disabled(selection.isEmpty)

            Spacer()

            HStack(spacing: 6) {
                Button {
                    state.undo()
                    selection = selection.filter { $0 < state.pageCount }
                } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                    .disabled(!state.canUndo)
                Button {
                    state.redo()
                    selection = selection.filter { $0 < state.pageCount }
                } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                    .disabled(!state.canRedo)
            }

            Button(role: .destructive) {
                act { state.deletePages(targets) }
            } label: { Label("删除", systemImage: "trash") }
                .disabled(selection.isEmpty || selection.count >= state.pageCount)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.primary.opacity(0.03))
    }

    private var targets: [Int] {
        selection.isEmpty ? [state.currentPage - 1] : Array(selection).sorted()
    }

    private func act(_ block: () -> Void) {
        block()
        selection = selection.filter { $0 < state.pageCount }
    }

    private func toggle(_ i: Int) {
        if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.tertiary)
            content()
        }
    }
}

struct EditorThumb: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    let index: Int
    let selected: Bool
    let revision: Int
    @State private var img: NSImage?
    /// 页面宽高比：让缩略图框永远和纸面同比例，随列宽自动放大
    @State private var ratio: CGFloat = 0.707

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Design.controlBg(scheme))
                if let img {
                    Image(nsImage: img).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack(spacing: 4) {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: selected ? .semibold : .regular, design: .rounded))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                if state.currentPage == index + 1 {
                    Text("· 当前")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9)
            .strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.primary.opacity(0.08),
                          lineWidth: selected ? 1.8 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .task(id: "\(index)-\(revision)") {
            // 命中缓存就别再渲染一遍：PDFKit 的页面光栅化只能在主线程做，
            // 页面管理里来回滚动、反复开关 sheet 都会重复触发这里。
            if let e = state.cachedThumb(index, kind: Self.thumbKind) {
                img = e.image
                ratio = e.ratio
                return
            }
            guard let page = state.page(at: index) else { img = nil; return }
            ratio = Self.aspect(of: page)
            let t = page.thumbnail(of: CGSize(width: 640, height: 900), for: .cropBox)
            state.storeThumb(index, kind: Self.thumbKind, image: t, ratio: ratio)
            img = t
        }
    }

    static let thumbKind = "editor"

    /// 页面宽高比要算上旋转：页面转了 90° 之后 thumbnail 返回的是横版图，
    /// 容器还按竖版比例的话，图上下会多出一大片空白。
    static func aspect(of page: PDFPage) -> CGFloat {
        let b = page.bounds(for: .cropBox)
        let r = ((page.rotation % 360) + 360) % 360
        let quarter = (r == 90 || r == 270)
        let w = quarter ? b.height : b.width
        let h = quarter ? b.width : b.height
        guard w > 1, h > 1 else { return 0.707 }
        return w / h
    }
}
