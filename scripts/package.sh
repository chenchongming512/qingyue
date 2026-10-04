#!/bin/zsh
# 轻阅 · 打包可安装的 zip（给 Releases 用）
#
# 用法：scripts/package.sh [版本号]   默认读 build.sh 里的版本
#
# 产出：build/轻阅-<版本>.zip
#
# ⚠️ 分发出去的 zip 会被别人下载 → Git 资源下载不产生隔离标记，
# 但**浏览器下载的文件会带 com.apple.quarantine**。所以这里做两件事：
#   1. 打包时 `xattr -cr` 清掉本地可能存在的隔离属性
#   2. 附一份「怎么打开」的说明，把绕过 Gatekeeper 的正当做法写清楚
#      （右键 → 打开，或 系统设置 → 隐私与安全性 → 仍要打开）
set -e
cd "$(dirname "$0")/.."

APP="build/轻阅.app"
if [[ ! -d "$APP" ]]; then
  # ⚠️ 提示要说清**为什么**失败：裸 `build.sh` 只编二进制，不产出 .app。
  # 我自己在验证时就在这儿踩了一次（没加 --app，包没打出来还以为脚本坏了）。
  echo "✗ 还没有 $APP"
  echo "  先跑：scripts/build.sh --app   ← 注意要带 --app，只编二进制是不够的"
  exit 1
fi

# 版本号：优先取命令行参数，否则从 build.sh 里抠出来
VER="${1:-}"
if [[ -z "$VER" ]]; then
  VER=$(grep -oE '<key>CFBundleShortVersionString</key><string>[^<]+' scripts/build.sh | head -1 | sed 's/.*<string>//')
  [[ -n "$VER" ]] || VER="0.0.0"
fi

# ⚠️ zip 文件名用 **ASCII**，不要用中文。
# 实测：中文名 `轻阅-2.2.zip` 上传后 GitHub 把它截成了 `-2.2.zip`（"轻阅" 被吃掉），
# 下载的人会看到一个莫名其妙的名字。包**里面**的文件夹名可以保留中文（Finder 显示友好）。
OUT="build/QingYue-${VER}.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "▸ 打包 轻阅 $VER…"

# 1. 清隔离属性
# ⚠️ 这一步对"自己的机器"是必要的：构建过的 App 可能残留 quarantine，
# 打进 zip 发出去会让别人连"我自己编的"都打不开。
xattr -cr "$APP" 2>/dev/null || true

# 2. 复制到暂存区
mkdir -p "$STAGE/轻阅"
cp -R "$APP" "$STAGE/轻阅/"
# ⚠️ 用 zsh 的 null_glob 语义清残留：目录里本来就没有该文件时，
# `rm -f xxx/*` 会报 "no matches found" 并中止脚本（zsh 的通配符默认行为）。

# 3. 附安装说明
cat > "$STAGE/轻阅/安装说明.txt" <<'TXT'
轻阅 QingYue 2.2 — 安装说明
═══════════════════════════════════════════════════════

【怎么打开】

  1. 双击「轻阅.app」
  2. 如果 macOS 提示「无法打开，因为无法验证开发者」——
     这是因为这个 App 没有苹果的付费开发者证书（我没有），
     属于**正常现象**，不是 App 坏了。

  解决办法（任选其一）：

  A. 右键点「轻阅.app」→ 选「打开」→ 弹窗里再点「打开」
     ← 最简单，推荐

  B. 如果 A 也不行：
     打开「系统设置 → 隐私与安全性」，
     往下翻会看到「已阻止使用轻阅」，点「仍要打开」

  C. 命令行（一次就永久放行）：
     xattr -dr com.apple.quarantine /Applications/轻阅.app

【放到哪里】

  建议拖进「应用程序」文件夹：
     把「轻阅.app」拖到 /Applications 即可。

【首次启动】

  直接把 PDF 拖进窗口就能打开，不用走「文件 → 打开」。

  想用 OCR / 翻译 / 摘要等 AI 功能，需要在
  「AI 中心」里配一个服务商：
    · 本地免费：装好 Ollama 后选它，拉模型列表即可
    · 云端：填 API Key（存在你自己用户目录里，权限 600）

  完全不配也能当普通 PDF 阅读器用 —— 所有 AI 功能都是可选的。

【系统要求】

  macOS 14 或更高 · Apple Silicon 与 Intel 都可

【遇到问题】

  项目主页：https://github.com/chenchongming512/qingyue
TXT

# 4. 打 zip
# ⚠️ 用 ditto 而不是 zip：它会保留 __MACOSX 之外的资源分支/扩展属性，
# 而 zip 会把 .app 里的符号链接和权限搞乱，解压后可能打不开。
cd "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "轻阅" "$OLDPWD/$OUT"
cd - >/dev/null

SIZE=$(du -h "$OUT" | cut -f1)
echo "  ✓ $OUT（$SIZE）"
echo ""
echo "下一步："
echo "  gh release create v$VER "$OUT" --title \"轻阅 $VER\" --notes-file <说明文件>"
