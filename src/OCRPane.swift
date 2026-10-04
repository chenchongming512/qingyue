// 轻阅 · OCR 文字面板：识别结果逐页查看、编辑、导出

import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct OCRPane: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ai: AIStore
    @EnvironmentObject var ocr: OCRStore
    @EnvironmentObject var tasks: TaskCenter

    var body: some View {
        VStack(spacing: 0) {
            // 引擎提示
            HStack(spacing: 6) {
                Image(systemName: ai.ocr.engine == .vision ? "bolt.horizontal.circle" : "cloud")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text(ai.ocr.engine == .vision ? "本地 Vision（离线）"
                     : "\(ai.provider(ai.ocrProviderID)?.name ?? "未选") · \(ai.ocrModel.isEmpty ? "未选模型" : ai.ocrModel)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            // 操作
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    actionButton("本页识别", "text.viewfinder") { runPage() }
                    actionButton("整篇识别", "doc.text.magnifyingglass") { runDocument() }
                }
                HStack(spacing: 6) {
                    actionButton("导出文本", "square.and.arrow.up") { exportText() }
                    actionButton("可搜索 PDF", "doc.badge.gearshape") { exportSearchable() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            if !ocr.statusNote.isEmpty {
                Text(ocr.statusNote)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }

            Divider().opacity(0.5)

            if ocr.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("还没有识别结果").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("整篇识别会逐页显示进度，随时可以停。")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 30)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(ocr.results.keys.sorted(), id: \.self) { idx in
                            if let r = ocr.results[idx] {
                                OCRPageRow(result: r)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                HStack {
                    Text("\(ocr.results.count) 页 · \(ocr.totalChars) 字")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("清空") { ocr.clear() }.buttonStyle(.borderless).font(.system(size: 10))
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }

    private func actionButton(_ label: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10))
                Text(label).font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ---------- 动作 ----------

    private var context: OCRContext? {
        guard let doc = state.document else { return nil }
        let url = state.fileURL
        return OCRContext(pageCount: doc.pageCount,
                          page: { [weak doc] i in doc?.page(at: i) },
                          fileURL: url,
                          identity: OCRCache.identity(fileURL: url, pageCount: doc.pageCount))
    }

    private func runPage() {
        guard let ctx = context else { state.showToast("还没有打开文档"); return }
        ocr.runPage(max(0, state.currentPage - 1), ctx: ctx, ai: ai, tasks: tasks)
    }

    private func runDocument() {
        guard let ctx = context else { state.showToast("还没有打开文档"); return }
        ocr.runDocument(ctx: ctx, ai: ai, tasks: tasks)
    }

    private func exportText() {
        guard let text = ocr.exportText(documentTitle: state.documentTitle) else {
            state.showToast("还没有识别结果，先做一次识别")
            return
        }
        ReaderActions.exportText(text, suggestedName: "\(state.documentTitle)-OCR",
                                 fileExtension: "txt", state: state,
                                 successToast: "已导出识别文本")
    }

    private func exportSearchable() {
        // 与菜单里的「导出可搜索 PDF」走同一份实现，别在这儿再抄一遍
        ReaderActions.exportSearchablePDF(state: state, ocr: ocr, tasks: tasks)
    }
}

struct OCRPageRow: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var ocr: OCRStore
    let result: OCRPageResult
    @State private var expanded = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("第 \(result.pageIndex + 1) 页")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(result.text.count) 字")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if let note = result.note {
                    Text(note)
                        .font(.system(size: 9))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    state.goToPage(result.pageIndex + 1)
                    ocr.inspectedPage = result.pageIndex
                } label: { Image(systemName: "arrow.up.forward.square").font(.system(size: 10)) }
                    .buttonStyle(.borderless).help("跳到这一页")
                Button(expanded ? "收起" : "查看") {
                    draft = result.text
                    withAnimation(Design.animQuick) { expanded.toggle() }
                }
                .buttonStyle(.borderless).font(.system(size: 10))
            }

            Text(result.text.prefix(90).replacingOccurrences(of: "\n", with: " ") + (result.text.count > 90 ? "…" : ""))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.system(size: 11))
                        .frame(height: 150)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Design.textBg(scheme)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
                    HStack(spacing: 8) {
                        Button("保存修改") {
                            if var r = ocr.results[result.pageIndex] {
                                r.text = draft
                                ocr.results[result.pageIndex] = r
                                state.showToast("已更新第 \(result.pageIndex + 1) 页文本")
                            }
                        }
                        .controlSize(.small)
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft, forType: .string)
                            state.showToast("已复制")
                        }
                        .controlSize(.small)
                        Spacer()
                        Text(result.engine).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(ocr.inspectedPage == result.pageIndex ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.07)))
    }
}
