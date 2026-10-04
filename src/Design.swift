// 轻阅 · 设计常量（颜色 / 动效 / 尺寸 token）
//
// 单独成文件的原因有两个：
// 1. 之前这些值散在 5 个文件里各写一遍（`Color(red: 0.20, green: 0.66, blue: 0.42)`
//    出现 8 次、动效时长有 5 种），改一处配色要满仓库找。
// 2. 测试台要编译 TaskCenter.swift 之类的文件，它们引用了这些常量 ——
//    放在界面文件里的话，测试台得把整个 UI 都编进来。

import SwiftUI
import AppKit

// MARK: - 设计常量

/// 设计 token。
///
/// 之前这些值散在 5 个文件里各写一遍（`Color(red: 0.20, green: 0.66, blue: 0.42)`
/// 出现 8 次、动效时长有 5 种），改一处配色要满仓库找。集中到这里，改一次全局生效。
enum Design {

    // ---------- 语义色 ----------

    /// 成功 / 已就绪（本地服务在线、任务完成）
    static let success = Color(red: 0.20, green: 0.66, blue: 0.42)
    /// 失败 / 危险（任务失败、删除、温度过高的告警）
    static let danger  = Color(red: 0.86, green: 0.30, blue: 0.28)
    /// 注意（配置不完整、可能被忽略的提示）
    static let warning = Color(red: 0.85, green: 0.60, blue: 0.10)

    /// 品牌色（欢迎页图标、关于页图标）
    static let brandStart = Color(red: 0.42, green: 0.36, blue: 0.98)
    static let brandEnd   = Color(red: 0.62, green: 0.40, blue: 0.95)
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandStart, brandEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // ---------- 动效 ----------
    //
    // 名字按"什么时候用"取，不按数值取 —— 这样将来调时长不会把语义搅乱。
    // 数值上只保留四档：hover / panel / smooth / spring。

    // ---------- 减弱动态效果（系统无障碍设置） ----------
    //
    // 用户在「系统设置 → 辅助功能 → 显示 → 减弱动态效果」打开后，
    // 位移 / 缩放类动画应当降级甚至取消。**不能靠逐个视图判断** ——
    // 那样每加一个新动效就漏一处。这里做成一个全局闸门：
    // `Design.respecting(...)` 包一层，token 自己决定降级成什么。
    //
    // 读的是 AppKit 的开关（`accessibilityDisplayShouldReduceMotion`），
    // 它随系统设置变化，而且**不需要 SwiftUI 环境** —— 这点很重要，
    // 因为 `ReduceMotion` 环境值只在视图里才拿得到，而 token 常被
    // 非视图层（Design 被测试台编译）引用。
    static var reduceMotionEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 按系统设置决定某个动效该怎么退化。
    ///
    /// - `nil` → 关闭动效：适合**位移 / 缩放**（面板滑入、按钮按压、工具条浮现）
    /// - 短动画 → 只留轻微的颜色 / 透明度渐变：适合**状态提示**
    ///   （工具条与快译卡的淡入淡出保留，只去掉"从下方滑上来"那一段位移）
    static func respecting(_ animation: Animation?, keepFade: Bool = true) -> Animation? {
        guard reduceMotionEnabled else { return animation }
        return keepFade ? .easeOut(duration: 0.12) : nil
    }

    /// 悬停、按下、图标切换这类"跟手"的反馈
    static let animQuick = Animation.easeInOut(duration: 0.15)
    /// 面板展开、边栏显隐
    static let animPanel = Animation.easeInOut(duration: 0.21)
    /// 列表滚动跟随、内容位移（单向缓出）
    static let animSmooth = Animation.easeOut(duration: 0.22)
    /// 浮层（任务中心、卡片）弹出，带一点回弹
    static let animSpring = Animation.spring(response: 0.3, dampingFraction: 0.85)

    /// 进场：快进慢停。
    ///
    /// ⚠️ 为什么不能拿 `animPanel` 顶替：easeInOut 的起步加速度是 0，
    /// 也就是**先慢后快再慢停**。UI 元素进场应该"一动手就已经在动、然后减速停住"
    /// 才跟手；easeInOut 用在 264pt 的侧栏上，起步那一下的迟滞很明显，
    /// 大位移量把它放大了，读起来像"卡了一下才滑出来"。
    static let animEnter = Animation.easeOut(duration: 0.22)
    /// 退场：慢出快收。退场没有"要赶路"的压力，起点慢一点反而更自然。
    static let animExit = Animation.easeIn(duration: 0.16)

    // ---------- 尺寸 ----------

    /// 顶栏高度（截图通道定位也依赖它，别改单处）
    static let headerHeight: CGFloat = 52
    /// 侧栏图标栏宽度
    static let tabRailWidth: CGFloat = 40

    // ---------- 分隔线 ----------

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
    }
    static func headerBackground(_ scheme: ColorScheme) -> Color {
        windowBg(scheme)
    }

    // ---------- 随深浅色变化的底色 ----------
    //
    // ⚠️ 这里必须**显式**给深色值，不能只写 `Color(nsColor: .windowBackgroundColor)`。
    // AppKit 动态色**不跟随 SwiftUI 的 `\.colorScheme` 环境** —— 它是在 NSAppearance
    // 上下文里解析的。`NSApp.appearance = .darkAqua` 也救不了它：
    // 实测日志里 `effectiveAppearance` 明明已经是 DarkAqua，那块底色照样是白的。
    // 更坑的是**不报错**，只是夜间模式下界面里留着一大块刺眼的白。
    //
    // 深色取值对着 macOS darkAqua 的观感调过（窗口底略暗、输入框略亮）。

    /// 窗口底（ContentView 的根背景、关于页背景）
    static func windowBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.118, green: 0.118, blue: 0.129)
                        : Color(nsColor: .windowBackgroundColor)
    }
    /// 控件底（搜索框、页码框、缩略图槽位）
    static func controlBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.176)
                        : Color(nsColor: .controlBackgroundColor)
    }
    /// 文本底（便签、OCR 结果、书签备注这类"可编辑区域"）
    static func textBg(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.208)
                        : Color(nsColor: .textBackgroundColor)
    }

    /// 浮层 / 工具条这类"材质底"。
    ///
    /// ⚠️ `.regularMaterial` 同样是 AppKit 材质，**也不跟随 SwiftUI 的 `\.colorScheme`**。
    /// 夜间模式下正文和边栏都变深了，浮动工具条还挂着一条亮白胶囊，格外扎眼。
    /// 返回 `AnyShapeStyle` 是为了让「材质」和「纯色」两种类型能塞进同一个 `fill(_:)`。
    static func barStyle(_ scheme: ColorScheme) -> AnyShapeStyle {
        scheme == .dark
            ? AnyShapeStyle(Color(white: 0.175).opacity(0.97))
            : AnyShapeStyle(Material.regular)
    }
}

// MARK: - 按压反馈

/// 给 `.plain` 按钮补上"按下"的视觉反馈。
///
/// ⚠️ 为什么要专门做：`.buttonStyle(.plain)` 在 macOS 上**不给任何按压反馈** ——
/// 不缩放、不变暗、不高亮。而这个 App 里顶栏、悬浮工具条、边栏图标全部走 `.plain`
/// （工具条那 12 个按钮是最高频的交互面：选高亮 / 下划线 / 白框 / 橡皮 / 朗读 / 旋转 / 打印）。
/// 表现是：hover 时图标会亮（`.onHover` + 动画），**按下时却毫无变化** ——
/// 用户点下去会有一瞬间怀疑"没点到吗"。
///
/// 幅度刻意压得很小（0.96 + 轻微变暗）：这是"确认收到了点击"，不是"要被按扁"，
/// 幅度大了反而像玩具。跟已有的 hover 动画是两件事，不要叠加成双重位移。
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            // 跟 hover 用同一个 token，别让按压显得比 hover 更黏
            .animation(Design.animQuick, value: configuration.isPressed)
    }
}
