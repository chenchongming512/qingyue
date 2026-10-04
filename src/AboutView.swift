// 轻阅 · 关于 / 版权页
// 独立窗口（⌘ 菜单「关于轻阅」）+ AI 中心里的「关于」标签共用同一份内容。

import SwiftUI
import AppKit

enum AppInfo {
    /// 版本从 Info.plist 读；直接跑裸二进制（没有 plist）时回落到这里的常量
    static var versionString: String {
        let plist = Bundle.main.infoDictionary
        let short = plist?["CFBundleShortVersionString"] as? String ?? "2.2"
        let build = plist?["CFBundleVersion"] as? String ?? "4"
        return "\(short)（build \(build)）"
    }

    static let name = "轻阅 · QingYue"
    static let tagline = "轻快的原生 PDF 阅读器"
    /// 开发人员
    static let author = "陈宏明"
    static let copyright = "© 2026 陈宏明 保留所有权利"
    static let bundleID = "com.gezi.qingyue"

    /// 本版新增（只留最近一版，别让它长成一份变更日志）
    static let highlights: [String] = [
        "书签：⌘D 标记当前页，可加标题与备注，导出成 Markdown 读书笔记",
        "批注列表：全文档的高亮 / 便签汇总到一处，点击跳转，一键导出笔记",
        "阅读色调：原色 / 暖纸 / 夜间 / 夜间暖调，夜间用反相而不是叠色",
        "选中即问：选中文字直接让模型解释、概括、翻译或追问",
        "整篇摘要与自动章节：给没有目录的 PDF 补一份",
        "朗读：系统语音读选中文字或整页，扫描件也能读 OCR 结果",
        "搜索重写：300 页文档从 410ms 降到 10ms 量级"
    ]

    /// 一键复制给开发者的问题反馈信息（测试/排障用）
    static func diagnostics(modelCount: Int, providerCount: Int) -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let arch = ProcessInfo.processInfo.machineHardwareName
        return """
        轻阅 \(versionString)
        系统：\(os) · \(arch)
        服务商：\(providerCount) 个 · 模型：\(modelCount) 个
        包标识：\(bundleID)
        """
    }
}

extension ProcessInfo {
    /// 芯片型号（如 arm64 / x86_64）；sysctl 拿不到时回落到架构名
    var machineHardwareName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 {
                let s = String(cString: buf).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { return s }
            }
        }
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }
}

// MARK: - 菜单命令

/// 「关于轻阅」菜单项。放在这里而不是 App 结构体内：App 本身不是 View，
/// 拿不到 `openWindow` 这类 environment 值，得用一个 Commands 包一层。
struct AboutMenuCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于轻阅") { openWindow(id: "about") }
        }
    }
}

// MARK: - 独立窗口

struct AboutWindowView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var ai: AIStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("关闭")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView {
                AboutContent()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 26)
            }
        }
        .frame(width: 470, height: 600)
        .background(Design.windowBg(scheme))
    }
}

// MARK: - 公共内容

struct AboutContent: View {
    @EnvironmentObject var ai: AIStore
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            SectionCard(title: "版权") {
                VStack(alignment: .leading, spacing: 6) {
                    keyValue("开发人员", AppInfo.author)
                    keyValue("版本", AppInfo.versionString)
                    Text(AppInfo.copyright)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    Text("本软件为个人开发作品。文中提到的第三方服务（Ollama、DeepSeek、OpenAI 等）商标归各自所有者，此处仅作接入说明。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SectionCard(title: "技术栈") {
                VStack(alignment: .leading, spacing: 5) {
                    bullet("原生 macOS 应用，SwiftUI + AppKit + PDFKit，无 Electron、无 WebView")
                    bullet("OCR：Apple Vision 本地文字识别；翻译：任意 OpenAI 兼容接口或本地 Ollama")
                    bullet("排版与切片、接缝质检、退化输出判定均为本机实现，纯 Swift 无外部依赖")
                    bullet("朗读与摘要走系统语音合成与所选模型，不额外依赖第三方服务")
                }
            }

            SectionCard(title: "本版新增") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(AppInfo.highlights, id: \.self) { bullet($0) }
                }
            }

            SectionCard(title: "数据与隐私") {
                VStack(alignment: .leading, spacing: 5) {
                    bullet("API Key 只存系统钥匙串（服务名 \(AppInfo.bundleID).ai），不写入配置文件、不上传")
                    bullet("OCR 与翻译缓存位于 ~/Library/Caches/\(AppInfo.bundleID)/，可随时删除")
                    bullet("本地 Vision OCR 与 Ollama 全程离线，文档不出本机")
                    bullet("使用云端模型时，只有你主动选中的文本或页面图片会被发往该服务商")
                }
            }

            SectionCard(title: "快捷键") {
                VStack(alignment: .leading, spacing: 4) {
                    bullet("⌘O 打开 · ⌘S 保存 · ⇧⌘S 另存为 · ⌥⌘W 关闭文档")
                    bullet("⌘Z / ⇧⌘Z 撤销重做 · ⌘F 搜索 · ⌘G / ⇧⌘G 下一个 / 上一个结果")
                    bullet("⌘B 边栏 · ⌘= / ⌘- / ⌘0 缩放 · ⌘9 整页 · ⌘1 / ⌘2 单页 / 双页")
                    bullet("⌘D 加 / 取消书签 · ⇧⌘D 书签列表 · ⇧⌘L 批注列表")
                    bullet("⌥⌘S 朗读选中文字或当前页")
                    bullet("⇧⌘T 译文对照 · ⇧⌘U OCR 面板 · ⇧⌘J 任务中心")
                    bullet("⇧⌘O 识别当前页 · ⌥⌘O 识别整篇 · ⌥⌘R 框选识别翻译")
                    bullet("⌥⌘T 翻译选中 · ⇧⌘P 翻译当前页 · ⌥⌘P 翻译整篇")
                    bullet("⇧⌘E 页面管理 · ⇧⌘R 旋转当前页 · ⌘P 打印")
                }
            }

            SectionCard(title: "致谢") {
                Text("「去 AI 味」约束整理自 humanizer-zh 的编辑优先级与模式清单：不新增事实、不强化或弱化不确定程度、删掉空泛铺垫与拔高、保留作者声音。感谢所有把本地大模型跑起来的人。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button {
                    let text = AppInfo.diagnostics(modelCount: ai.providers.reduce(0) { $0 + $1.models.count },
                                                   providerCount: ai.providers.count)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制诊断信息", systemImage: copied ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .help("把版本与运行环境复制到剪贴板，反馈问题时附上")

                Spacer()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [Design.brandStart,
                                                      Design.brandEnd],
                                             startPoint: .top, endPoint: .bottom))
                        .shadow(color: Design.brandStart.opacity(0.35), radius: 12, y: 5)
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppInfo.name)
                        .font(.system(size: 20, weight: .bold))
                    Text(AppInfo.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("开发人员 \(AppInfo.author)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                }
                Spacer()
            }
        }
    }

    private func keyValue(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(v)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(.tertiary)
            Text(s).font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
