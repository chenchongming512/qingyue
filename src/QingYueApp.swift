// 轻阅 · App 入口（窗口、菜单与快捷键）

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import CoreImage

// MARK: - AppDelegate（接收"打开方式"传来的文件）

/// 启动参数（用于生成界面截图，也方便自动化）。
///
/// ⚠️ 两条硬规矩，实测踩过：
/// 1. **只能用 `--flag value` 成对的写法，绝不能传"裸"位置参数。**
///    AppKit 一旦在命令行里看到不属于任何 flag 的参数（哪怕是个不存在的路径），
///    SwiftUI 的 WindowGroup 就不会实例化窗口 —— 表现为 `NSApp.windows` 为空。
/// 2. **不要用 `open --args`**。走 LaunchServices 同样会让窗口不创建。
///    要传参就直接执行 `build/轻阅.app/Contents/MacOS/QingYue`。
///
/// 每一项都同时支持命令行参数与环境变量：`--snapshot /tmp/a.png` ⇔ `QY_SNAPSHOT=/tmp/a.png`
enum LaunchOptions {
    private static let args = CommandLine.arguments
    private static let env = ProcessInfo.processInfo.environment

    /// 取 `--flag value` 的值，缺失则回落到环境变量
    static func value(_ flag: String, env key: String) -> String? {
        if let i = args.firstIndex(of: flag), i + 1 < args.count { return args[i + 1] }
        if let v = env[key], !v.isEmpty { return v }
        return nil
    }

    /// 截图落盘路径
    static var snapshotPath: String? { value("--snapshot", env: "QY_SNAPSHOT") }

    /// 截图前切到哪个界面：
    /// main / ai / translate / translate-run / ocr / editor / tasks / toast
    static var pane: String? { value("--pane", env: "QY_PANE") }

    /// 截图前等待秒数（等界面渲染 + 异步任务出内容）
    static var delay: Double { Double(value("--delay", env: "QY_DELAY") ?? "") ?? 5 }

    /// 要打开的文档。必须是 `--doc 路径` 或 `QY_DOC=路径`，不能裸传路径（见上文第 1 条）
    static var document: String? { value("--doc", env: "QY_DOC") }
    /// AI 中心要开哪个标签页（providers / models / ocr / translate / about）
    static var aiTab: String? { value("--ai-tab", env: "QY_AI_TAB") }

    /// 截图前的窗口尺寸，形如 `1280x840`；不给就用系统默认尺寸
    static var size: NSSize? {
        guard let raw = value("--size", env: "QY_SIZE") else { return nil }
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
        return NSSize(width: w, height: h)
    }

    /// 截图方式：auto（默认，两种都试、取内容更丰富的）/ layer / cache
    static var capture: String? { value("--capture", env: "QY_CAPTURE") }

    /// 诊断：把视图 / 图层树写进 .log
    static var dumpView: Bool {
        CommandLine.arguments.contains("--dumpview") || env["QY_DUMPVIEW"] != nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    var pendingURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        if let st = state { st.open(url: urls[0]) }
        else { pendingURL = urls.first }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// 退出（⌘Q，或关掉最后一个窗口）前，若有没保存的页面改动，先问一句
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if LaunchOptions.snapshotPath != nil { return .terminateNow }
        guard let st = state, st.document != nil, st.isDirty else { return .terminateNow }
        switch askAboutUnsavedChanges() {
        case .cancel:
            return .terminateCancel
        case .saveAndClose:
            st.save()
            return st.isDirty ? .terminateCancel : .terminateNow
        case .discardAndClose:
            return .terminateNow
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 截图通道是一次一张、共用同一份 UserDefaults，色调会**跨张残留** ——
        // 上一张截了夜间，这一张 main 就会莫名其妙变成夜间图。
        // 所以除了明确要色调的那两个通道，其余一律先复位成原色。
        if LaunchOptions.snapshotPath != nil, let p = LaunchOptions.pane,
           !["night", "sepia"].contains(p) {
            ReadingTint.saved = .normal
        }

        // 上次用的阅读色调如果是夜间，整机外观要跟着起来 ——
        // 不然重启后正文是黑的、边栏还是白的，像刚崩过一半。
        ReadingTint.saved.applyAppearance()

        // 钥匙串自检 —— **只在快照模式下跑，且放到后台**。
        //
        // ⚠️ 踩过的坑：一开始放在启动主流程里同步跑，App 直接卡死不产物。
        // 原因是 `SecItemAdd` 在缺少访问组时会**弹一个系统授权窗**等用户点，
        // 无头环境下没人点 → 整个启动被挂住。
        // 改成后台 + 延后，既不挡启动，日志照样能拿到。
        if LaunchOptions.snapshotPath != nil {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                let r = SecretStore.selfTest()
                let line = "钥匙串自检：\(r.ok ? "OK" : "失败") — \(r.detail)"
                try? line.write(toFile: (LaunchOptions.snapshotPath ?? "/tmp/qy") + ".kc.log",
                               atomically: true, encoding: .utf8)
                NSLog("轻阅：%@", line)
            }
        }

        guard LaunchOptions.snapshotPath != nil else { return }
        if let doc = LaunchOptions.document {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.state?.open(url: URL(fileURLWithPath: doc))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchOptions.delay) { [weak self] in
            if let path = LaunchOptions.snapshotPath { self?.snapshot(to: path) }
            // 直接 exit：有 sheet（页面管理）时 NSApp.terminate 会被模态拦下，
            // 进程就赖着不走了（踩过，留了一堆僵尸进程）。
            exit(0)
        }
    }

    /// 把窗口内容渲染成 PNG。
    ///
    /// 用 `CALayer.render(in:)` 而不是 `cacheDisplay`：SwiftUI 的毛玻璃、浮层
    /// 工具条都是图层型内容，`cacheDisplay` 抓不到。
    ///
    /// 两个必须处理的坑：
    /// 1. **坐标翻转**：NSView 支撑的图层被 AppKit 设成 `isGeometryFlipped = true`
    ///    （y 轴朝下），而 `CGContext` 位图原点在左下角（y 轴朝上），不翻转会得到
    ///    一张上下颠倒的图。
    /// 2. **PDF 页面空白**：PDFKit 把页面画在 `PDFPageLayer` 的 `drawInContext:` 里，
    ///    backing store 不在可读的位置，`render(in:)` 拿到的是一张白纸。解决办法是
    ///    用公开 API `PDFPage.draw(with:to:)` 把每一页重画成图，临时塞进页面所在的
    ///    图层里（在浮层工具条下面，z 序正确），截完再撤掉。
    func snapshot(to path: String) {
        var log = "窗口状态：\n"
        for w in NSApp.windows {
            log += " - title=\"\(w.title)\" visible=\(w.isVisible) size=\(Int(w.frame.width))x\(Int(w.frame.height))\n"
        }

        let pane = LaunchOptions.pane
        let candidates = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 }
        var win: NSWindow?
        if pane == "ai" {
            win = candidates.first { $0.title.contains("AI") }
        }
        if pane == "about" {
            win = candidates.first { $0.title.contains("关于") }
        }
        // 默认取面积最大的那个（主窗口通常最大，稳定且不受 AI 窗口影响）
        win = win ?? candidates.max { a, b in
            a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }

        guard let win, let view = win.contentView else {
            log += "结果：找不到可截图的窗口\n"
            try? log.write(toFile: path + ".log", atomically: true, encoding: .utf8)
            return
        }

        // 截图专用的窗口尺寸（真实 App 运行时窗口大小由用户决定）
        if let size = LaunchOptions.size {
            win.setContentSize(size)
            win.center()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }

        // 截图路径上窗口是后建的，`applicationDidFinishLaunching` 里那次
        // appearance 压不到它身上，这里再补一次。
        ReadingTint.saved.applyAppearance()
        log += " - 色调=\(ReadingTint.saved.rawValue)"
            + "  NSApp.appearance=\(NSApp?.appearance?.name.rawValue ?? "nil")"
            + "  win.appearance=\(win.appearance?.name.rawValue ?? "nil")"
            + "  effective=\(win.effectiveAppearance.name.rawValue)\n"

        // appearance 变了要强制重绘，否则图层 contents 还是旧外观画出来的
        view.needsDisplay = true

        // 让 AppKit 把该画的都画完（PDFKit 的页面图层是异步绘制的）
        win.displayIfNeeded()
        view.layoutSubtreeIfNeeded()
        for _ in 0..<6 {
            view.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }

        if LaunchOptions.dumpView { log += dump(view: view, depth: 0) }

        let bounds = view.bounds
        let scale: CGFloat = 2
        // 只有抓主窗口才需要补页面；抓 AI 中心时主窗口不在画面里，白费力气
        let injected = (pane == "ai") ? [] : injectPageImages(scale: scale, log: &log)

        var png: Data?
        if let ctx = CGContext(data: nil,
                               width: Int(bounds.width * scale),
                               height: Int(bounds.height * scale),
                               bitsPerComponent: 8,
                               bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)

            // ⚠️⚠️ 先给整块画布铺一层**不透明**底色，且必须在 `render(in:)` **之前**。
            //
            // 根因：独立窗口（AI 中心 / 关于）的内容视图在 `layer.render(in:)` 下
            // 是**完全透明**的 —— 窗口底色由 AppKit 画在 contentView **之外**，
            // 不在图层树里。落到不透明位图上就成了纯黑。
            //
            // 症状特别有欺骗性：整片右区全黑、内容看着"错位"；侧栏反而正常，
            // 因为它底下压着一个 `NSVisualEffectView`（那个自带图层内容）。
            // 屏幕上的真实效果是不错的 —— **这是截图通道的缺陷，不是 App 的 bug**。
            //
            // ⚠️ 试过"render 之后去找 NSVisualEffectView、在它位置补铺底色"：
            // 两个问题 —— 只能救侧栏，且因为铺在 render **之后**，会把已经画好的
            // 侧栏内容盖掉（左栏整个消失）。所以必须当最底层、在 render 之前铺。
            // ⚠️ `NSColor` 没有 `brightness` 属性（那是 CGColor 转换后才有的），
            // 而且它也不该被用来判断深浅色 —— 直接用 `bestMatch` 的结果，那里更可靠。
            let isDark = win.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fillBG: NSColor = isDark ? NSColor(white: 0.118, alpha: 1) : NSColor.windowBackgroundColor
            ctx.setFillColor(fillBG.cgColor)
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            log += " - 已铺窗口底色（\(isDark ? "深" : "浅")）\n"

            view.layer?.render(in: ctx)
            // sheet（页面管理）是独立窗口，主窗口的图层里没有它 —— 按屏幕坐标拼上去，
            // 这样截图才和用户实际看到的一致。
            if let sheet = win.attachedSheet, let sheetView = sheet.contentView,
               let sheetImage = renderLayerImage(sheetView, scale: scale) {
                let contentRect = win.convertToScreen(view.convert(view.bounds, to: nil))
                let f = sheet.frame
                let dx = f.minX - contentRect.minX
                let dy = contentRect.maxY - f.maxY
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24,
                              color: CGColor(gray: 0, alpha: 0.28))
                // sheet 的底色是窗口自己画的，contentView 图层里没有 —— 先铺一层，
                // 否则拼出来是透明的、底下正文透上来
                ctx.setFillColor((sheet.backgroundColor ?? .windowBackgroundColor).cgColor)
                ctx.fill(CGRect(x: dx, y: dy, width: f.width, height: f.height))
                // 这里**必须**再翻一次：renderLayerImage 的输出是「row0 = 顶部」的图，
                // 而主 ctx 此刻是 y-down，Quartz 的 CGContextDrawImage 会把 row0 放到 rect 底部。
                // 试过不翻（QY_SHEET_NOFLIP 对照实验）：整张 sheet 连同文字一起颠倒，
                // 而只翻一次时框架与缩略图都正立 —— 结论是「翻」，别再改。
                ctx.translateBy(x: dx, y: dy + f.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(sheetImage, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
                ctx.restoreGState()
                log += " - 已拼上 sheet：\(Int(f.width))x\(Int(f.height))\n"
            }
            if let cg = ctx.makeImage() {
                let final = bakeReadingTint(into: cg, windowView: view, log: &log)
                png = NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:])
            }
        }
        for l in injected { l.removeFromSuperlayer() }

        if let png {
            try? png.write(to: URL(fileURLWithPath: path))
            log += "结果：已保存 \(png.count) 字节（\(Int(bounds.width))x\(Int(bounds.height))@\(Int(scale))x）到 \(path)\n"
        } else {
            log += "结果：渲染失败\n"
        }
        try? log.write(toFile: path + ".log", atomically: true, encoding: .utf8)
    }

    /// 把阅读色调（护眼 / 夜间）烘焙进截图。
    ///
    /// ⚠️ 为什么需要这一步：真机运行时色调靠 `CALayer.filters` 实现，那是
    /// **Core Animation 合成期**的事；而截图走的是 `CALayer.render(in:)` —— 它
    /// 直接渲染图层内容，**不经过合成管线，图层滤镜天然被跳过**。不补这一刀，
    /// `--pane night` 截出来永远是原色白纸，看着像功能压根没做。
    /// （对照实验：修好 `layerUsesCoreImageFilters` 之后截图字节数与修之前**完全一致**，
    ///   这才确认问题出在渲染路径，而不是滤镜没设上。）
    ///
    /// 这里对最终位图里「PDFView 所占的那块矩形」重跑一遍同一套滤镜链（复用
    /// `ReadingTint.makeFilters()`），保证截图与真机是同一套参数。
    /// 贴回去用 `composited(over:)`，位置由 CIImage 自带的 extent 决定，不用手算拼接。
    private func bakeReadingTint(into image: CGImage, windowView view: NSView,
                                log: inout String) -> CGImage {
        let tint = ReadingTint.saved
        guard tint != .normal else { return image }
        guard let pdf = firstDescendant(of: PDFView.self, in: view) else {
            log += " - 色调：没找到 PDFView，跳过烘焙\n"
            return image
        }
        let filters = tint.makeFilters()
        guard !filters.isEmpty else { return image }

        let scale = CGFloat(image.width) / max(1, view.bounds.width)
        // PDFView 的矩形换算到 contentView 坐标（AppKit y 朝上）
        let r = pdf.convert(pdf.bounds, to: view)
        // CIImage 坐标系原点在**左下**，所以 y 要翻一次；x 一一对应
        let region = CGRect(x: r.minX * scale,
                            y: (view.bounds.height - r.maxY) * scale,
                            width: r.width * scale,
                            height: r.height * scale)
        guard region.width > 1, region.height > 1 else { return image }

        let full = CIImage(cgImage: image)
        let ci = CIContext(options: [.useSoftwareRenderer: false])
        // 只对 PDFView 那一块跑滤镜，再盖回原图。
        // ⚠️ 别用 `CIBlendWithMask` 之类更"显式"的写法：一开始怀疑
        // `composited(over:)` 会因 extent 对不齐而只贴上一部分，换成遮罩混合证明是白折腾 ——
        // 真正的毛病在我的像素探针上（见下）。`cropped + composited` 本来就对，且只跑一块、更快。
        var patch = full.cropped(to: region)
        for f in filters {
            f.setValue(patch, forKey: kCIInputImageKey)
            if let out = f.outputImage { patch = out }
        }
        guard let result = ci.createCGImage(patch.composited(over: full), from: full.extent) else {
            log += " - 色调：CIContext 渲染失败，退回原图\n"
            return image
        }
        log += " - 色调：已烘焙 \(tint.rawValue)（区域 \(Int(region.width))x\(Int(region.height)) 像素）\n"
        return result
    }

    /// 在视图树里找第一个指定类型的子视图（截图时用来定位 PDFView）
    private func firstDescendant<T: NSView>(of type: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let hit = sub as? T { return hit }
            if let hit = firstDescendant(of: type, in: sub) { return hit }
        }
        return nil
    }

    /// 把任意视图的图层渲染成 CGImage（供 sheet 拼接等场合复用）
    private func renderLayerImage(_ v: NSView, scale: CGFloat) -> CGImage? {
        let b = v.bounds
        guard b.width > 1, b.height > 1,
              let ctx = CGContext(data: nil,
                                  width: Int(b.width * scale),
                                  height: Int(b.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: 0, y: b.height)
        ctx.scaleBy(x: 1, y: -1)
        v.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    /// 把当前 PDF 视图里可见的每一页，用 `PDFPage.draw(with:to:)` 重画成图层，
    /// 临时插入到 PDF 内部文档视图的图层里。返回插入的图层，方便截完撤掉。
    ///
    /// 为什么插在那：z 序要刚好在页面层之上、浮层工具条之下 —— 插进文档视图正是
    /// 这个位置，所以截图里书页有内容、工具条也不会被盖住。
    @discardableResult
    private func injectPageImages(scale: CGFloat, log: inout String) -> [CALayer] {
        var made: [CALayer] = []
        guard let pdfView = state?.pdfView, let doc = pdfView.document, doc.pageCount > 0 else { return made }

        // 找 PDFKit 内部的文档视图（class 名是 PDFDocumentView，非公开 API）
        var docView: NSView?
        func locate(_ v: NSView) {
            if docView != nil { return }
            if String(describing: type(of: v)) == "PDFDocumentView" { docView = v; return }
            v.subviews.forEach(locate)
        }
        locate(pdfView)

        guard let host = docView?.layer else {
            log += " - 页面注入：找不到 PDFDocumentView，跳过\n"
            return made
        }

        let cs = max(2, host.contentsScale)
        let box = pdfView.displayBox
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            // 页面 → PDFView 坐标 → 文档视图坐标
            let inView = pdfView.convert(page.bounds(for: box), from: page)
            let inDoc = docView!.convert(inView, from: pdfView)
            guard inDoc.width > 4, inDoc.height > 4,
                  inDoc.intersects(docView!.bounds) else { continue }

            let w = Int(inDoc.width * cs), h = Int(inDoc.height * cs)
            guard w > 0, h > 0,
                  let ctx = CGContext(data: nil, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: cs, y: cs)
            // PDFPage.draw 落笔方向跟位图上下文一致（都是 y 轴朝上），不用翻。
            page.draw(with: box, to: ctx)
            guard let cg = ctx.makeImage() else { continue }

            let l = CALayer()
            l.frame = inDoc
            l.contents = cg
            l.contentsGravity = .resize
            l.contentsScale = cs
            host.addSublayer(l)
            made.append(l)
        }
        log += " - 页面注入：\(made.count) 页（contentsScale=\(cs)）\n"
        return made
    }

    /// 诊断用：把视图 + 图层树按缩进打出来，用来定位"内容画在哪儿"
    private func dump(view: NSView, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(type(of: view)) frame=\(Int(view.frame.origin.x)),\(Int(view.frame.origin.y)) "
            + "\(Int(view.frame.width))x\(Int(view.frame.height)) wantsLayer=\(view.wantsLayer) "
            + "drawsAsync=\(view.layer?.drawsAsynchronously ?? false)"
        if let l = view.layer {
            line += " layer=\(type(of: l)) contents=\(l.contents == nil ? "nil" : "有") "
                + "needsDisplay=\(l.needsDisplay()) sublayers=\(l.sublayers?.count ?? 0)"
        } else {
            line += " layer=nil"
        }
        var out = line + "\n"
        for sub in view.subviews {
            out += self.dump(view: sub, depth: depth + 1)
        }
        return out
    }
}

@main
struct QingYueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var ai = AIStore()
    @StateObject private var tasks = TaskCenter()
    @StateObject private var ocr = OCRStore()
    @StateObject private var translate = TranslateStore()
    @StateObject private var summary = SummaryStore()
    @StateObject private var speech = SpeechReader()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(ai)
                .environmentObject(tasks)
                .environmentObject(ocr)
                .environmentObject(translate)
                .environmentObject(summary)
                .environmentObject(speech)
                // ⚠️ 夜间模式要让 **SwiftUI** 变深色，靠 `NSApp.appearance` 是没用的 ——
                // 那只管 AppKit 控件。SwiftUI 的语义色按 `\.colorScheme` 环境解析，
                // 而这个环境既不跟窗口 appearance、也不认 `preferredColorScheme`。
                // 见 `TintAppearance` 的说明。
                .modifier(TintAppearance(isDark: state.readingTint.isDark))
                .onAppear {
                    appDelegate.state = state
                    if let u = appDelegate.pendingURL {
                        appDelegate.pendingURL = nil
                        state.open(url: u)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            AboutMenuCommands()
            CommandGroup(replacing: .newItem) {
                Button("打开…") { state.openPanel() }.keyboardShortcut("o")
                Divider()
                Button("保存") { state.save() }.keyboardShortcut("s")
                Button("另存为…") { state.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("关闭文档") { state.requestClose() }
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(state.document == nil)
                Menu("最近打开") {
                    if state.recentFiles.isEmpty {
                        Text("还没有记录")
                    }
                    ForEach(state.recentFiles.prefix(8), id: \.absoluteString) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { state.open(url: url) }
                    }
                }
                .disabled(state.recentFiles.isEmpty)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(state.undoLabel.map { "撤销：\($0)" } ?? "撤销") { state.undo() }
                    .keyboardShortcut("z", modifiers: [.command]).disabled(!state.canUndo)
                Button(state.redoLabel.map { "重做：\($0)" } ?? "重做") { state.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedo)
            }
            CommandMenu("视图") {
                Button("放大") { state.zoomIn() }.keyboardShortcut("=", modifiers: .command)
                Button("缩小") { state.zoomOut() }.keyboardShortcut("-", modifiers: .command)
                Button("适合宽度") { state.fitWidth() }.keyboardShortcut("0", modifiers: .command)
                Button("整页显示") { state.fitPage() }.keyboardShortcut("9", modifiers: .command)
                Divider()
                Button("单页连续") { state.displayMode = .singlePageContinuous }.keyboardShortcut("1", modifiers: .command)
                Button("双页连续") { state.displayMode = .twoUpContinuous }.keyboardShortcut("2", modifiers: .command)
                Divider()
                Menu("阅读色调") {
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
                Divider()
                Button(state.sidebarVisible ? "隐藏边栏" : "显示边栏") {
                    withAnimation(Design.animPanel) { state.sidebarVisible.toggle() }
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(state.document == nil)
                Button("搜索") { state.focusSearch() }.keyboardShortcut("f", modifiers: .command)
                Button("查找下一个") { state.nextHit() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(state.searchHits.isEmpty)
                Button("查找上一个") { state.prevHit() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(state.searchHits.isEmpty)
                Divider()
                Button(translate.paneVisible ? "隐藏译文对照" : "显示译文对照") {
                    withAnimation(Design.animPanel) { translate.paneVisible.toggle() }
                }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("OCR 文字面板") {
                    withAnimation(Design.animPanel) { state.ocrPaneVisible = true }
                    state.sidebarVisible = true
                }.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("任务中心") { tasks.expanded.toggle() }.keyboardShortcut("j", modifiers: [.command, .shift])
            }
            CommandMenu("阅读") {
                Button(state.hasBookmarkOnCurrentPage ? "取消本页书签" : "为当前页加书签") {
                    state.toggleBookmark()
                }.keyboardShortcut("d", modifiers: .command).disabled(state.document == nil)

                Button("书签列表") {
                    withAnimation(Design.animPanel) { state.sidebarVisible = true }
                    state.sidebarTab = .bookmarks
                }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(state.document == nil)

                Button("批注列表") {
                    withAnimation(Design.animPanel) { state.sidebarVisible = true }
                    state.sidebarTab = .annotations
                }.keyboardShortcut("l", modifiers: [.command, .shift]).disabled(state.document == nil)
                Divider()
                Menu("选中即问") {
                    ForEach(AskMode.allCases) { mode in
                        Button(mode.label) { askSelection(mode) }
                    }
                }
                .disabled(state.document == nil)
                Divider()
                Button(speech.speaking ? "停止朗读" : "朗读（选中文字 / 当前页）") {
                    toggleSpeech()
                }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(state.document == nil)
                Divider()
                Button("生成整篇摘要") { makeSummary() }.disabled(state.document == nil)
                Button("生成章节目录") { makeOutline() }.disabled(state.document == nil)
            }
            CommandMenu("OCR") {
                Button("识别当前页") { runOCRPage() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("识别整篇") { runOCRDocument() }.keyboardShortcut("o", modifiers: [.command, .option])
                Divider()
                Button("框选识别 / 翻译") { state.tool = .region }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("清除识别结果") { ocr.clear() }
                Divider()
                Button("导出识别文本…") { exportOCRText() }
                Button("导出可搜索 PDF…") { exportSearchablePDF() }
            }
            CommandMenu("翻译") {
                Button("翻译选中文字") { translateSelection() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("翻译当前页") { runTranslatePage() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("翻译整篇") { runTranslateDocument() }.keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("清空译文") { translate.clear() }
                Button("导出译文（Markdown）…") { exportTranslation(bilingual: false) }
                Button("导出原文译文对照（Markdown）…") { exportTranslation(bilingual: true) }
            }
            CommandMenu("编辑") {
                Button("页面管理…") { state.editorPresented = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("插入空白页") { state.insertBlankPage(after: state.currentPage - 1) }
                Button("从 PDF 插入页面…") { state.insertPagesFromFile() }
                Divider()
                Button("复制当前页") { state.duplicatePages([state.currentPage - 1]) }
                Button("删除当前页") { state.deletePages([state.currentPage - 1]) }
                Divider()
                Button("清除本页批注") {
                    if let p = state.pdfView?.currentPage { state.clearAnnotations(on: p) }
                }
                Button("清除全部批注") { state.clearAllAnnotations() }
            }
            CommandMenu("页面") {
                Button("旋转当前页") { state.rotateCurrentPage() }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("打印…") { state.printDocument() }.keyboardShortcut("p", modifiers: [.command])
            }
        }

        Window("AI 中心", id: "ai-center") {
            AICenterView()
                .environmentObject(ai)
                .environmentObject(state)
                .environmentObject(tasks)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 880, height: 640)

        Window("关于轻阅", id: "about") {
            AboutWindowView()
                .environmentObject(ai)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 470, height: 600)
    }

    // MARK: - 菜单动作

    private func ocrContext() -> OCRContext? { ReaderActions.ocrContext(state) }
    private func translateContext() -> TranslateContext? { ReaderActions.translateContext(state) }

    private func runOCRPage() {
        ReaderActions.runOCRPage(state: state, ai: ai, tasks: tasks, ocr: ocr)
    }

    private func runOCRDocument() {
        ReaderActions.runOCRDocument(state: state, ai: ai, tasks: tasks, ocr: ocr)
    }

    private func translateSelection() {
        ReaderActions.translateSelection(state: state, ai: ai, tasks: tasks, translate: translate)
    }

    private func runTranslatePage() {
        ReaderActions.translateCurrentPage(state: state, ai: ai, tasks: tasks, translate: translate)
    }

    private func runTranslateDocument() {
        ReaderActions.translateDocument(state: state, ai: ai, tasks: tasks, translate: translate)
    }

    private func exportOCRText() {
        ReaderActions.exportOCRText(state: state, ocr: ocr)
    }

    private func exportSearchablePDF() {
        ReaderActions.exportSearchablePDF(state: state, ocr: ocr, tasks: tasks)
    }

    private func exportTranslation(bilingual: Bool) {
        ReaderActions.exportTranslation(state: state, ai: ai, translate: translate, bilingual: bilingual)
    }

    // MARK: - 阅读增强

    private func selectedText() -> String? {
        guard let s = state.pdfView?.currentSelection?.string,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private func askSelection(_ mode: AskMode) {
        guard let sel = selectedText() else {
            state.showToast("先在页面上选中一段文字")
            return
        }
        if mode == .custom {
            let alert = NSAlert()
            alert.messageText = "追问这段文字"
            alert.informativeText = "选中了 \(sel.count) 个字。想问什么？"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
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
        if let sel = selectedText() {
            speech.speak(sel, title: "选中文字（第 \(state.currentPage) 页）")
            return
        }
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

    private func makeSummary() {
        guard let doc = state.document else { return }
        summary.ocrText = { [weak ocr] i in ocr?.results[i]?.text ?? "" }
        summary.makeSummary(doc: doc, ai: ai, tasks: tasks, title: state.documentTitle)
        withAnimation(Design.animPanel) { state.sidebarVisible = true }
        state.sidebarTab = .summary
    }

    private func makeOutline() {
        guard let doc = state.document else { return }
        summary.ocrText = { [weak ocr] i in ocr?.results[i]?.text ?? "" }
        summary.makeOutline(doc: doc, ai: ai, tasks: tasks)
        withAnimation(Design.animPanel) { state.sidebarVisible = true }
        state.sidebarTab = .summary
    }
}
