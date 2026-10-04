#!/bin/zsh
# 轻阅 · 生成界面截图（用于评审 / 交付）
# 用法：scripts/shots.sh [输出目录]   默认 screenshots/
#
# 注意：必须直接跑二进制，不要用 `open --args`（走 LaunchServices 会让
# SwiftUI 的 WindowGroup 不实例化窗口）；也不要传"裸"位置参数。
set -u
cd "$(dirname "$0")/.."

OUT="${1:-screenshots}"
BIN=build/QingYue
DOC="${QY_DEMO:-/tmp/qingyue-demo.pdf}"
SIZE=1360x880
mkdir -p "$OUT"

# ⚠️ 演示文档会被"批注"通道写花 —— 高亮是**存回原文件**的（这正是这个 App 该有的行为）。
# 直接复用上一轮跑剩的 /tmp/qingyue-demo.pdf，下一次截「批注列表」就会看到两条一模一样的高亮
# （文档自带的那条 + 这次新加的）。所以每次从 samples 里那份干净的重铺一份。
if [[ -z "${QY_DEMO:-}" ]]; then
  if [[ -f samples/轻阅-演示文档.pdf ]]; then
    cp samples/轻阅-演示文档.pdf "$DOC"
  elif [[ -f scripts/make_demo_pdf.swift ]]; then
    xcrun swiftc -O -o /tmp/mkdemo scripts/make_demo_pdf.swift && /tmp/mkdemo "$DOC"
  fi
fi

shot() {  # shot <文件名> <pane> <延迟秒> [窗口尺寸]
  echo -n "▸ $1 … "
  local t0=$SECONDS
  "$BIN" --snapshot "$OUT/$1" --pane "$2" --delay "$3" --size "${4:-$SIZE}" --doc "$DOC" >/dev/null 2>&1
  if [[ -f "$OUT/$1" ]]; then
    echo "✓ $((SECONDS-t0))s  $(stat -f%z "$OUT/$1") 字节"
  else
    echo "✗ 失败"; tail -3 "$OUT/$1.log" 2>/dev/null
  fi
}

# 关于页窗口是固定内容尺寸，不能用主窗口的 1360x880
shot "2-AI中心.png"   ai             6   1120x760
shot "4-OCR识别.png"  ocr            28
shot "5-任务中心.png" tasks          28
shot "6-页面管理.png" editor         9
shot "11-关于版权页.png" about        7   470x600
shot "1-主界面.png"   main           5
shot "3-翻译对照.png" translate-run  120

# 空状态与提示条：都不需要文档也能出图
echo -n "▸ 7-欢迎页.png … "
"$BIN" --snapshot "$OUT/7-欢迎页.png" --delay 4 --size 1180x760 >/dev/null 2>&1
[[ -f "$OUT/7-欢迎页.png" ]] && echo "✓ $(stat -f%z "$OUT/7-欢迎页.png") 字节" || echo "✗ 失败"

shot "8-操作反馈.png" toast          3   1180x760
# 最小窗口宽度：验证顶栏降级（标题不被截断、页码不丢）
shot "9-窄窗口.png"   main           5   940x700

# 批注：用副本跑，别把演示文档本身写花了
echo -n "▸ 10-批注高亮.png … "
cp "$DOC" "$OUT/demo-annotated.pdf" 2>/dev/null
"$BIN" --snapshot "$OUT/10-批注高亮.png" --pane highlight --delay 4 --size 1180x760 \
       --doc "$OUT/demo-annotated.pdf" >/dev/null 2>&1
[[ -f "$OUT/10-批注高亮.png" ]] && echo "✓ $(stat -f%z "$OUT/10-批注高亮.png") 字节" || echo "✗ 失败"

# ── 2.2 新增的四个面板 / 两组阅读色调 ────────────────────────────────
# 书签：通道里会先自动造 3 条，否则截到的是空状态
shot "12-书签.png"      bookmarks   6
# 批注列表：同样用副本，通道会真的加一条高亮，列表才有内容
echo -n "▸ 13-批注列表.png … "
cp "$DOC" "$OUT/demo-annotated2.pdf" 2>/dev/null
"$BIN" --snapshot "$OUT/13-批注列表.png" --pane annotations --delay 6 --size 1180x760 \
       --doc "$OUT/demo-annotated2.pdf" >/dev/null 2>&1
[[ -f "$OUT/13-批注列表.png" ]] && echo "✓ $(stat -f%z "$OUT/13-批注列表.png") 字节" || echo "✗ 失败"
# 搜索：通道里会真的搜一个文档里存在的词（"reading"）
shot "14-搜索面板.png"  search      8
# 摘要与章节：通道里注入一份成品内容（真机调模型要几十秒，截图等不起）
shot "15-摘要与章节.png" summary    6
# 阅读色调：同一页的两种色偏，放在一起能看出区别
shot "16-夜间模式.png"  night       6
shot "17-暖纸模式.png"  sepia       6

# 截图过程会在输出目录留下 .log（含窗口与页面注入的诊断信息），交付前清掉
rm -f "$OUT"/*.png.log "$OUT"/demo-annotated.pdf "$OUT"/demo-annotated2.pdf

echo "▸ 完成，输出在 $OUT"
