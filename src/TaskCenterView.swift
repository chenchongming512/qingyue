// 轻阅 · 任务中心：随时看得到在做什么、做到哪了、还剩多久

import SwiftUI

struct TaskCenterView: View {
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject var tasks: TaskCenter
    @State private var logTaskID: UUID?
    /// 列表内容的实测高度，用来让面板"按内容撑开"而不是永远占满 300pt
    @State private var listHeight: CGFloat = 0
    private static let maxListHeight: CGFloat = 300

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if tasks.expanded {
                expandedPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if tasks.hasAny {
                collapsedPill
                    // ⚠️ 原来是 .scale：药丸(≈200pt 宽) ↔ 面板(384pt 宽) 两个尺寸交叉淡变，
                    // 中间帧会出现位置与尺寸的突跳。统一成从底部来，视觉才连续。
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 16)
        .padding(.bottom, 16)
        // 只在「没任务且已收起」时才放行点击穿透。
        // 原来写的是 hasAny：按 ⇧⌘J 在没有任务时展开面板，整块变成不可点击，
        // 连收起按钮都按不动 —— 面板直接卡死在那儿。
        .allowsHitTesting(tasks.hasAny || tasks.expanded)
    }

    // 收起状态：一颗药丸，点开看详情
    private var collapsedPill: some View {
        Button {
            // 进场用 animEnter（easeOut，快进慢停）。
            // ⚠️ 原来用 animSpring：dampingFraction 0.85 欠阻尼会有一次可见过冲，
            // 用在 384pt 宽的大面板上，视觉重量很大，读起来像"没对齐又晃了一下"。
            // 回弹只适合小元素（药丸、角标），不适合大面板。
            withAnimation(Design.respecting(Design.animEnter, keepFade: false)) { tasks.expanded = true }
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: max(0.02, tasks.active.isEmpty ? 1 : tasks.overallProgress))
                        .stroke(tasks.active.isEmpty ? Design.success : Color.accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 17, height: 17)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tasks.active.isEmpty ? "任务已结束" : "\(tasks.active.count) 个任务进行中")
                        .font(.system(size: 11, weight: .semibold))
                    Text(tasks.active.first?.detail ?? "点击查看日志")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 190, alignment: .leading)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Capsule().fill(Design.barStyle(scheme)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
    }

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                Text("任务中心").font(.system(size: 12, weight: .semibold))
                if !tasks.active.isEmpty {
                    Text("\(tasks.active.count) 进行中")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if tasks.tasks.contains(where: { $0.state != .running }) {
                    Button("清理") { withAnimation { tasks.dismissFinished() } }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
                Button {
                    // 退场用 animExit（easeIn 0.16）：比进场短、且不带回弹。
                    // 收起是用户主动关掉的东西，不该"弹回去"。
                    withAnimation(Design.respecting(Design.animExit, keepFade: false)) { tasks.expanded = false }
                } label: { Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider().opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if tasks.tasks.isEmpty {
                        Text("还没有任务。识别或翻译时会在这里显示实时进度。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    ForEach(tasks.tasks) { task in
                        TaskRow(task: task, logTaskID: $logTaskID)
                    }
                }
                .padding(.vertical, 10)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: TaskListHeightKey.self, value: geo.size.height)
                })
            }
            // 按内容高度撑开，超过上限才滚动 —— 否则一条任务也会占满 300pt，下面一片空白
            .frame(height: min(max(listHeight, 44), Self.maxListHeight))
            .onPreferenceChange(TaskListHeightKey.self) { listHeight = $0 }
        }
        .frame(width: 384)
        .background(RoundedRectangle(cornerRadius: 14).fill(Design.barStyle(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.20), radius: 18, y: 6)
    }
}

private struct TaskListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct TaskRow: View {
    @ObservedObject var task: AITask
    @Binding var logTaskID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: task.kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(task.state.color)
                Text(task.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text(task.state.label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(task.state.color.opacity(0.15)))
                    .foregroundStyle(task.state.color)
                if task.isRunning {
                    Button {
                        task.cancel()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 13))
                            .foregroundStyle(Design.danger)
                    }
                    .buttonStyle(.plain).help("停止这个任务")
                }
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(task.state == .failed ? Design.danger
                              : (task.state == .running ? Color.accentColor : Design.success))
                        .frame(width: max(3, geo.size.width * task.progress))
                        // 语义就是"内容位移单向缓出"，直接用 animSmooth，
                        // 别硬编码 —— 否则以后统一调手感时这条会留在旧数值上。
                        .animation(Design.respecting(Design.animSmooth), value: task.progress)
                }
            }
            .frame(height: 4)

            Text(task.detail)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(2)
            if !task.stats.isEmpty {
                Text(task.stats)
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let err = task.errorText {
                Text(err).font(.system(size: 10)).foregroundStyle(Design.danger).lineLimit(2)
            }

            HStack(spacing: 10) {
                Button(logTaskID == task.id ? "收起日志" : "日志（\(task.logs.count)）") {
                    withAnimation(Design.animQuick) {
                        logTaskID = (logTaskID == task.id) ? nil : task.id
                    }
                }
                .buttonStyle(.borderless).font(.system(size: 10))
                Spacer()
                Text(task.elapsedText).font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            if logTaskID == task.id {
                LogConsole(task: task)
            }
        }
        .padding(.horizontal, 12)
    }
}

struct LogConsole: View {
    @ObservedObject var task: AITask

    /// 复用同一个 formatter：原来每条日志、每次 body 求值都 new 一个 DateFormatter，
    /// 500 行日志时这块开销相当可观（DateFormatter 构造很贵）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(task.logs) { line in
                        HStack(alignment: .top, spacing: 5) {
                            Text(line.level.mark)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(line.level.color)
                                .frame(width: 10)
                            Text(timeString(line.time))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(line.level == .info ? Color.secondary : line.level.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(line.id)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 130)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            .onChange(of: task.logs.count) {
                if let last = task.logs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func timeString(_ d: Date) -> String {
        Self.timeFormatter.string(from: d)
    }
}
