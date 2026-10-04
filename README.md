<div align="center">

# 轻阅 QingYue

**一个把「安静阅读」当第一原则的 macOS PDF 阅读器**

本地 OCR · AI 翻译 · 批注与笔记 · 整篇摘要 · 护眼夜间模式

纯原生 · 无 Electron · 无第三方依赖 · 12,000 行 Swift

[![macOS](https://img.shields.io/badge/macOS-14.0%2B-0071e3?style=flat-square)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square)](https://swift.org/)
[![License](https://img.shields.io/badge/license-MIT-0071e3?style=flat-square)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-260%20passed-success?style=flat-square)](tests/main.swift)

</div>

---

## 这是什么

一个**为长文档阅读优化**的 macOS PDF 阅读器。它的设计目标不是"功能最多"，而是
**"读长文时不被打扰"** —— 所以有了四级护眼色调、只在你需要时浮现的浮动工具条、
以及不会在半夜把系统照亮的夜间模式。

功能上它覆盖了商业 PDF 阅读器该有的东西：双通道 OCR（本地 Vision / 视觉大模型）、
带接缝质检的整篇翻译、PDF 批注、书签、整篇摘要与自动章节、选中即问、TTS 朗读。

**所有能力都是可选的。** 不配任何 API 服务，它依然是一个能好好读 PDF 的阅读器。

---

## 快速开始

### 直接下载（推荐给普通用户）

**→ [Releases v2.2](https://github.com/chenchongming512/qingyue/releases/tag/v2.2)**

下载 `QingYue-2.2.zip`（约 1.8 MB），解压后把「轻阅.app」拖进「应用程序」。

**第一次打开请右键 → 「打开」**：本项目没有 Apple 付费开发者证书，
macOS 的 Gatekeeper 会拦下未验证的应用，这是正常现象。
（若右键也不行：系统设置 → 隐私与安全性 → 「仍要打开」，
或命令行 `xattr -dr com.apple.quarantine /Applications/轻阅.app`）

### 自己构建

无 Xcode 工程、无 SwiftPM、无第三方依赖 —— 一次 `swiftc` 就够：

```bash
git clone https://github.com/chenchongming512/qingyue.git
cd qingyue

# 编译 + 打包成 build/轻阅.app
./scripts/build.sh --app

# 打开
open build/轻阅.app
```

> **为什么不用 Xcode 工程？**
> 24 个 `.swift` 文件靠 `swiftc` 编译只需几秒，而 `.xcodeproj` 是易冲突的二进制格式。
> 源码即真相，diff 一目了然。
>
> 需要 Xcode 工程才能做的事（代码签名、公证、App Sandbox）确实做不了，
> 所以本项目走 ad-hoc 分发 —— 见下面的「已知限制」。

### 跑测试

```bash
# 编译测试台（注意那个 disable-sandbox，理由见 tests/main.swift 注释）
xcrun swiftc -O -Xfrontend -disable-sandbox -o build/qy-tests \
  tests/main.swift \
  src/TranslateCore.swift src/OCREngine.swift src/TaskCenter.swift \
  src/AIStore.swift src/AIClient.swift src/TranslateStore.swift \
  src/Design.swift src/SearchCore.swift src/StudyCore.swift src/AnnotationCore.swift

./build/qy-tests
```

**260 项断言**，覆盖搜索正确性、书签编解码、批注类型归一化、摘要持久化往返、
密钥槽位逻辑等。部分用例会真机调用 Vision OCR 与本地 Ollama。

---

## 功能

### 阅读

| | |
|---|---|
| 拖拽打开 | 把 PDF 拖进窗口即可，不用走「文件 → 打开」 |
| 导航 | 缩略图 / 目录 / 搜索三栏，页码胶囊，30+ 快捷键 |
| 搜索 | 逐页扫描 + 惰性构造选区，300 页文档高频查询 **2ms** |
| 阅读模式 | 单页连续 / 双页连续 / 整页 / 适合宽度 |
| 外观 | 四级色调：原色 / 暖纸 / 夜间 / 夜间暖黄；浮层工具条可设「按需浮现」或「始终显示」 |

### 批注与笔记

- 高亮、下划线、删除线、便签、方框、椭圆、直线、手绘、白框遮盖
- **批注列表面板**：全文档批注汇总成表，标的那段文字反查得出来，可导出 Markdown
- **书签**：按文档保存，标题取自页首文字，可导出 Markdown 笔记
- 涂白遮盖、文本框、页面编辑（增删重排）
- 撤销栈按**字节**设上限（192MB / 最多 8 步），扫描件也不会把内存吃穿

### OCR

- **双通道**：本地 Vision（离线、快、免配置）或视觉大模型（适合复杂版面 / 手写 / 表格）
- 9 种预设语言 + 自定义
- 三种输出格式、四档渲染精度
- 结果按「文档身份 + 页号 + 引擎 + 语言」缓存，重复识别不重复耗时
- 整篇 OCR 并发数跟着 CPU 核数走（`max(2, min(6, cores/2))`）

### 翻译

- 选区 / 框选区域 / 整页 / 整篇四种粒度
- **长文切片 + 接缝质检**：按段落切片不切开段落，跨页传递上文保证人称术语连贯，
  接缝处自动检查截断、重复、漏译并自动修复
- 五种风格 + 术语表 + 全文一致性校对
- **去 AI 味**：不加铺垫预告、不堆限定词、不做空泛拔高、不改变原文确定程度
- 三种呈现：仅译文 / 原文译文逐段对照 / 分页对照

### AI 助手

- **选中即问**：解释 / 概括 / 翻译 / 自由提问
- **整篇摘要 + 自动章节**：长文自动抽样，**生成后自动存盘**，下次打开直接读
- **TTS 朗读**：按中英文自动选嗓音

### 服务与密钥

- 预置 Ollama、DeepSeek、OpenAI、硅基流动、智谱、OpenRouter 等，也支持任意 OpenAI 兼容接口
- **一个服务商可存多把密钥**（公司 / 个人 / 备用），按用途挑选
- 密钥存在 `~/Library/Application Support/com.gezi.qingyue/secrets.json`，**权限 600**
- 存完密钥自动拉取模型列表；连接测试失败时给**可操作的中文诊断**（401/403/404/429 分别对应什么）

---

## 快捷键

| 键 | 作用 | 键 | 作用 |
|---|---|---|---|
| `⌘O` | 打开 | `⇧⌘D` | 书签列表 |
| `⇧⌘S` | 保存 | `⇧⌘L` | 批注列表 |
| `⌥⌘S` | 另存为 | `⌥⌘S` | 朗读 朗读/停止 |
| `⌘W` | 关闭文档 | `⌘Z` / `⇧⌘Z` | 撤销 / 重做 |
| `⌘+` / `⌘-` | 放大 / 缩小 | `⇧⌘F` | 适合宽度 |
| `⇧⌘G` / `⇧⌘T` | 跳到页 / 搜索 | `⇧⌘J` | 任务中心 |
| `⇧⌘U` | 识别当前页 | `⇧⌘O` | 识别整篇 |
| `⌥⌘T` | 翻译选中 | `⇧⌘P` | 翻译当前页 |
| `⌥⌘P` | 翻译整篇 | `⇧⌘E` | 框选识别 / 翻译 |
| `⌘D` | 加 / 取消书签 | `⇧⌘R` | 旋转页面 |
| `⇧⌘P` | 页面管理 | `⌘P` | 打印 |

---

## 架构

```
src/
├── QingYueApp.swift      应用入口、菜单、窗口，快照通道
├── State.swift           全局状态、文档生命周期、偏好
├── Design.swift          设计 token：颜色 / 动效 / 尺寸
│
├── ── 纯逻辑层（不依赖 SwiftUI，可进测试台）──
├── SearchCore.swift      搜索：命中模型 + 逐页扫描
├── StudyCore.swift       书签、取样、章节解析、摘要持久化、Markdown 分块
├── AnnotationCore.swift  批注扫描与类型归一化
├── TranslateCore.swift   切片、接缝质检、去 AI 味
├── OCREngine.swift       Vision / 视觉模型两条通道
│
├── ── 界面层 ──
├── ReaderUI.swift        顶栏 / 边栏 / 画布 / 浮动工具条
├── AICenterView.swift    AI 中心：服务商、密钥、模型分配
├── Bookmarks.swift / AnnotationPane.swift / ReadingExtras.swift
└── …
```

**为什么要分「纯逻辑层」**：这些文件只依赖 Foundation / PDFKit，不引 SwiftUI，
所以测试台能单独编译它们跑真值测试（`build/qy-tests` 里没有一行界面代码）。
**要测的逻辑必须住在这一层** —— 否则就得把整个 SwiftUI 界面编进测试台。

---

## 设计取向

这个项目修过一批**「不崩溃、不报错、日志干净、编译零警告，但功能就是不工作」**的缺陷。
它们有个共同点：看代码看不出来。

举几个真实例子，都写在了代码注释里：

- `PDFAnnotation.type` 是 `"Highlight"`，而 `PDFAnnotationSubtype.highlight.rawValue`
  是 `"/Highlight"` —— **差一个斜杠，永不相等**。后果：批注列表全变成"批注"、
  高亮的文字反查不出来、连弹窗和链接都被当成用户标注。
- SwiftUI 的 `colorScheme` 只管语义色。`NSApp.appearance` 改了
  `NSWindow.effectiveAppearance`，SwiftUI 那边**一个字节都没变**（截图字节数完全相同）。
- `Codable` 的属性默认值**对解码无效**。`var d: Date = Date()` 只在成员初始化器里生效，
  老文件缺这个 key 会抛 `keyNotFound` → **用户存的摘要"凭空消失"**。
- 编码器用 `.iso8601` 而解码器用默认策略 → 解码必抛错，而 `catch` 把它吞了。
  症状是**存盘报成功、文件真写出来了，只有读取永远 nil**。

所以这个项目配了一条规矩：

> **凡是 Codable 持久化，测试必须有「真的写进去再读出来」的往返断言。**
> 只测 `save` 返回 `true` 等于什么都没测。

---

## 已知限制

- **单文档**：一次只开一个 PDF。多窗口需要把按页号索引的数据（OCR / 译文 / 书签）
  改成按文档身份隔离 —— 现在已经有"代次守卫"作为第一步。
- **ad-hoc 签名**：没有 Xcode 工程，因此无法做代码签名与公证，
  首次打开需右键「打开」。也因为 ad-hoc 签名，**系统钥匙串不可用**
  （实测 `SecItemAdd` 返回成功但读回 `itemNotFound`），密钥改存 600 权限的文件。
- **只测过 Apple Silicon + macOS 14/15**：Intel 与更早版本未验证。
- **`.workbuddy/` 与 `.impeccable/` 不入库**：前者是 Agent 工作区状态（含绝对路径），
  后者是设计评审的原始快照（结论应写进文档，而不是留快照）。

---

## 参与

发现问题或想加功能，欢迎开 issue 或 PR。几条实际的入手点：

- `src/SearchCore.swift` —— 搜索核心，独立、可测、有性能基准
- `src/StudyCore.swift` —— 书签 / 摘要 / 章节解析，纯逻辑层
- `src/Design.swift` —— 所有设计 token 集中在这里，改配色不用满仓库找

改动前先跑 `./build/qy-tests`，**它比截图更早发现问题**。

---

## 许可

MIT © 2026 陈宏明
