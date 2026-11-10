#!/usr/bin/env bash
# WordWand 一键安装 / 升级（从 GitHub 直接拉，不需要先 clone）
#
#   curl -fsSL https://raw.githubusercontent.com/tangbonze/wordwand/main/setup.sh | bash
#
# 做四件事：备份旧配置 → 装 init.lua 和图标 → 引导填 API Key → 重载 Hammerspoon
# 脚本本身不含任何密钥，Key 只写进本机 ~/.hammerspoon/secrets/。
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/tangbonze/wordwand/main"
DEST="$HOME/.hammerspoon"
HS_BIN="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
KEYFILE="$DEST/secrets/deepseek.key"

say() { printf '%s\n' "$*"; }
die() { printf '× %s\n' "$*" >&2; exit 1; }

# ---------- 1. 环境检查 ----------
[ -d /Applications/Hammerspoon.app ] || die "没装 Hammerspoon。先执行：brew install --cask hammerspoon"
[ -d "$DEST" ] || die "没找到 ${DEST}。请先打开一次 Hammerspoon，让它生成配置目录"

# ---------- 2. 备份 + 安装 ----------
if [ -f "$DEST/init.lua" ]; then
  BAK="$DEST/init.lua.bak.$(date +%Y%m%d%H%M%S)"
  cp "$DEST/init.lua" "$BAK"
  say "· 已备份原配置 → $BAK"
fi

curl -fsSL "$REPO_RAW/init.lua" -o "$DEST/init.lua" || die "下载 init.lua 失败，检查网络"
say "· 已写入 init.lua"

mkdir -p "$DEST/icons"
curl -fsSL "$REPO_RAW/icons/rewrite.pdf" -o "$DEST/icons/rewrite.pdf" || say "· 图标下载失败，不影响功能"
[ -s "$DEST/icons/rewrite.pdf" ] && say "· 已写入图标"

# ---------- 3. API Key ----------
mkdir -p "$DEST/secrets"
chmod 700 "$DEST/secrets"

KEY="${WORDWAND_KEY:-}"
if [ -z "$KEY" ]; then
  say ""
  say "粘贴 DeepSeek API Key（sk- 开头，直接回车跳过）："
  # curl | bash 时 stdin 是管道，必须从 /dev/tty 读
  if [ -r /dev/tty ]; then
    read -r -s KEY < /dev/tty || true
  else
    read -r -s KEY || true
  fi
  say ""
fi

if [ -n "$KEY" ]; then
  printf '%s' "$KEY" > "$KEYFILE"
  chmod 600 "$KEYFILE"
  say "· Key 已写入 ${KEYFILE}（600）"
elif [ -s "$KEYFILE" ]; then
  say "· 跳过，沿用已有的 Key"
else
  : > "$KEYFILE"
  chmod 600 "$KEYFILE"
  say "· 已建空 Key 文件，稍后在菜单栏 → 设置… 里填也可以"
fi

# ---------- 4. 清掉旧网关留下的 Key ----------
OLD="$DEST/secrets/teamorouter.key"
if [ -f "$OLD" ]; then
  TARGET="$HOME/.Trash/teamorouter.key"
  [ -e "$TARGET" ] && TARGET="$HOME/.Trash/teamorouter.$(date +%s).key"
  mv "$OLD" "$TARGET" 2>/dev/null && say "· 旧 Key 已移入废纸篓：$TARGET" \
    || say "· 旧 Key 移不动，可手动删除 $OLD"
fi

# ---------- 5. 重载 ----------
if [ -x "$HS_BIN" ]; then
  "$HS_BIN" -c 'hs.reload()' >/dev/null 2>&1 || true
  sleep 3
  say ""
  say "=== 启动日志 ==="
  "$HS_BIN" -c 'print(hs.console.getConsole())' 2>/dev/null \
    | grep -E "WordWand 已就绪|模型列表已更新|模型列表刷新失败" | tail -3 || true
else
  say "· 没找到 hs 命令行，请在 Hammerspoon 控制台按 ⌘R 重载"
fi

say ""
say "装好了。选中文字按 ⌃⌥R 试一下。"
