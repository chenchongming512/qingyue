// 轻阅 · 任务中心：每个长任务都有实时进度、当前步骤、日志与控制权

import Foundation
import SwiftUI

enum AITaskKind: String {
    case ocr, translate, export, misc
    var label: String {
        switch self {
        case .ocr:       return "OCR"
        case .translate: return "翻译"
        case .export:    return "导出"
        case .misc:      return "任务"
        }
    }
    var icon: String {
        switch self {
        case .ocr:       return "text.viewfinder"
        case .translate: return "character.book.closed"
        case .export:    return "square.and.arrow.up"
        case .misc:      return "gearshape.2"
        }
    }
}

enum TaskState: String {
    case running, done, failed, cancelled
    var label: String {
        switch self {
        case .running:   return "进行中"
        case .done:      return "已完成"
        case .failed:    return "已失败"
        case .cancelled: return "已取消"
        }
    }
    var color: Color {
        switch self {
        case .running:   return .accentColor
        case .done:      return Design.success
        case .failed:    return Design.danger
        case .cancelled: return .secondary
        }
    }
}

enum LogLevel: String {
    case info, warn, error, success
    var color: Color {
        switch self {
        case .info:    return .secondary
        case .warn:    return Design.warning
        case .error:   return Design.danger
        case .success: return Design.success
        }
    }
    var mark: String {
        switch self {
        case .info:    return "·"
        case .warn:    return "!"
        case .error:   return "✕"
        case .success: return "✓"
        }
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
    let level: LogLevel
}

/// 跨线程取消令牌（后台流水线安全读取）
final class CancelToken {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

final class AITask: ObservableObject, Identifiable {
    let id = UUID()
    let kind: AITaskKind
    let title: String
    let token = CancelToken()

    /// 由 `TaskCenter.add` 注入：返回那个每秒推进的时间戳。
    /// 弱引用由 TaskCenter 侧保证（闭包不捕获 self 强引用）。
    var heartbeat: (() -> Date)?

    @Published var detail: String = "准备中…"
    @Published var progress: Double = 0
    @Published var state: TaskState = .running
    @Published var logs: [LogLine] = []
    @Published var stats: String = ""
    @Published var errorText: String?
    let startedAt = Date()
    @Published var finishedAt: Date?

    init(kind: AITaskKind, title: String) {
        self.kind = kind
        self.title = title
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    func set(detail: String? = nil, progress: Double? = nil, stats: String? = nil) {
        onMain {
            if let detail { self.detail = detail }
            if let progress { self.progress = max(0, min(1, progress)) }
            if let stats { self.stats = stats }
        }
    }

    func log(_ text: String, level: LogLevel = .info) {
        onMain {
            self.logs.append(LogLine(time: Date(), text: text, level: level))
            if self.logs.count > 500 { self.logs.removeFirst(self.logs.count - 500) }
        }
    }

    func finish(_ state: TaskState, error: String? = nil) {
        onMain {
            self.state = state
            self.errorText = error
            self.finishedAt = Date()
            if state == .done { self.progress = 1 }
            self.log(state == .done ? "任务完成，用时 \(self.elapsedText)"
                    : (error.map { "任务结束：\($0)" } ?? "任务未完成"),
                    level: state == .done ? .success : (state == .cancelled ? .warn : .error))
        }
    }

    var elapsed: TimeInterval { (finishedAt ?? Date()).timeIntervalSince(startedAt) }
    var elapsedText: String {
        // ⚠️ 必须读一下 `heartbeat`（TaskCenter 每秒推进的那个 @Published）。
        // 不读它，编译器会把这整个计算属性当纯函数优化掉 —— 界面就不刷新了，
        // 表现为任务在等网络响应时"N 秒"冻结住，用户以为卡死了。
        // 任务自己拿不到 TaskCenter（避免循环引用），所以由 add 时注入读取器。
        _ = heartbeat?()
        let s = Int(elapsed)
        return s < 60 ? "\(s) 秒" : "\(s / 60) 分 \(s % 60) 秒"
    }
    var isCancelled: Bool { token.isCancelled }
    func cancel() { token.cancel(); set(detail: "正在停止…"); log("收到取消请求，等待当前请求结束", level: .warn) }
    var isRunning: Bool { state == .running }
}

final class TaskCenter: ObservableObject {
    @Published var tasks: [AITask] = []
    @Published var expanded = false
    @Published var showLogs = false

    /// 心跳：`isRunning` 时每秒推进一次。
    ///
    /// ⚠️ 为什么需要：`elapsedText` 是拿 `Date()` 现算的计算属性，
    /// 但**没有任何东西驱动它重算** —— 原来只在某个 `@Published` 变化时才顺带刷新。
    /// 而 OCR / 翻译这类任务经常要等网络响应好几秒、期间一个 `@Published` 都不动，
    /// 于是界面上的"N 秒"会**冻结在那儿**，用户以为任务卡死了。
    /// （截图 `5-任务中心.png` 里三条任务都显示"0 秒"就是征兆，但那张图
    ///  也可能只是任务刚起步 —— 代码层的缺驱动是确定的。）
    ///
    /// 1Hz 足够：计时器只要"每秒动一下"，用户不会盯着秒数看。
    @Published private var heartbeatTick: Date = Date()

    private var heartbeatTask: Task<Void, Never>?

    /// 给 `AITask` 用的读取器。**不捕获 self**（否则任务列表会互相强引用）。
    private var heartbeatReader: () -> Date { { [weak self] in self?.heartbeatTick ?? Date() } }

    private func startHeartbeatIfNeeded() {
        guard heartbeatTask == nil, tasks.contains(where: { $0.isRunning }) else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                // 全部结束就停掉循环，别空转一辈子
                if self.tasks.allSatisfy({ !$0.isRunning }) {
                    self.heartbeatTask = nil
                    return
                }
                self.heartbeatTick = Date()
            }
        }
    }

    func newTask(kind: AITaskKind, title: String) -> AITask {
        let t = AITask(kind: kind, title: title)
        t.heartbeat = heartbeatReader
        tasks.insert(t, at: 0)
        if tasks.count > 40 { tasks.removeLast(tasks.count - 40) }
        startHeartbeatIfNeeded()
        return t
    }

    func dismissFinished() {
        tasks.removeAll { $0.state != .running }
        // 没有在跑的任务了就停掉心跳，别每秒空转一次
        if !tasks.contains(where: { $0.isRunning }) { heartbeatTask?.cancel(); heartbeatTask = nil }
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        if !tasks.contains(where: { $0.isRunning }) { heartbeatTask?.cancel(); heartbeatTask = nil }
    }

    var active: [AITask] { tasks.filter { $0.state == .running } }
    var overallProgress: Double {
        let a = active
        guard !a.isEmpty else { return 1 }
        return a.map(\.progress).reduce(0, +) / Double(a.count)
    }
    var hasAny: Bool { !tasks.isEmpty }
}
