#!/bin/zsh
# 轻阅 · 一键构建
#   用法：scripts/build.sh            （只编译二进制）
#         scripts/build.sh --app      （编译 + 打包 .app）
set -e

cd "$(dirname "$0")/.."
ROOT="$PWD"

SRC=(
  src/QingYueApp.swift
  src/State.swift
  src/Design.swift
  src/SearchCore.swift
  src/StudyCore.swift
  src/Bookmarks.swift
  src/AnnotationCore.swift src/AnnotationPane.swift
  src/ReadingExtras.swift
  src/AIStore.swift
  src/AIClient.swift
  src/TaskCenter.swift
  src/TranslateCore.swift
  src/TranslateStore.swift
  src/OCREngine.swift
  src/Actions.swift
  src/PageEditor.swift
  src/ReaderUI.swift
  src/AICenterView.swift
  src/TaskCenterView.swift
  src/OCRPane.swift
  src/TranslatePane.swift
  src/PageEditorView.swift
  src/AboutView.swift
)

# ⚠️ 必须先建 build/ —— 它被 .gitignore 排掉了（20MB 的产物不该进仓库），
# 所以**新克隆的仓库没有这个目录**。少了这行，别人 clone 下来第一次编译
# 就会失败在 `ld: open() failed for 'build/QingYue'`。
mkdir -p build

echo "▸ 编译 ${#SRC[@]} 个源文件…"
# -parse-as-library：文件里有 @main，不加会被当成 top-level code 报错
#
# ⚠️ -Xfrontend -disable-sandbox：本机编译 Swift 宏（@State / @Published 等）时，
# swift 给宏插件套了一层沙箱然后拒了，于是**满屏假报错**——每个 @State 都报
# "external macro implementation type 'SwiftUIMacros.StateMacro' could not be found"，
# 与源码无关。解法就是这个选项。**别写进 pbxproj**（本项目也不用 pbxproj）。
# 症状复现过：不加就 8 个错，加了 0 个。
xcrun swiftc -O -parse-as-library -Xfrontend -disable-sandbox -o build/QingYue "${SRC[@]}"
echo "  ✓ build/QingYue  ($(stat -f%z build/QingYue) 字节)"

if [[ "$1" == "--app" ]]; then
  echo "▸ 打包 轻阅.app…"
  APP="build/轻阅.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp build/QingYue "$APP/Contents/MacOS/QingYue"
  [[ -f build/AppIcon.icns ]] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>轻阅</string>
	<key>CFBundleDisplayName</key><string>轻阅</string>
	<key>CFBundleExecutable</key><string>QingYue</string>
	<key>CFBundleIdentifier</key><string>com.gezi.qingyue</string>
	<key>CFBundleShortVersionString</key><string>2.2</string>
	<key>CFBundleVersion</key><string>4</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 陈宏明 保留所有权利</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key><string>PDF Document</string>
			<key>CFBundleTypeRole</key><string>Viewer</string>
			<key>LSHandlerRank</key><string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array><string>com.adobe.pdf</string></array>
		</dict>
	</array>
	<key>NSRequiresAquaSystemAppearance</key><false/>
</dict>
</plist>
PLIST

  cp "$ROOT/build/QingYue" "$APP/Contents/MacOS/QingYue"

  codesign --force --deep --sign - "$APP" 2>/dev/null || true
  echo "  ✓ $APP"
fi

echo "▸ 完成"
