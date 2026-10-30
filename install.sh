#!/usr/bin/env bash
# WordWand 一键部署：把配置和图标放进 ~/.hammerspoon
set -euo pipefail

DEST="$HOME/.hammerspoon"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$DEST" ]; then
  echo "× 没找到 $DEST"
  echo "  请先安装并启动一次 Hammerspoon：brew install --cask hammerspoon"
  exit 1
fi

if [ -f "$DEST/init.lua" ]; then
  BAK="$DEST/init.lua.bak.$(date +%Y%m%d%H%M%S)"
  cp "$DEST/init.lua" "$BAK"
  echo "· 已备份原配置 → $BAK"
fi

cp "$SRC/init.lua" "$DEST/init.lua"
echo "· 已写入 init.lua"

mkdir -p "$DEST/icons"
cp "$SRC/icons/rewrite.pdf" "$DEST/icons/rewrite.pdf"
echo "· 已写入图标"

mkdir -p "$DEST/secrets"
chmod 700 "$DEST/secrets"
KEYFILE="$DEST/secrets/teamorouter.key"
if [ ! -f "$KEYFILE" ]; then
  : > "$KEYFILE"
  chmod 600 "$KEYFILE"
  echo "· 已创建 ${KEYFILE}（600）"
fi

if [ -s "$KEYFILE" ]; then
  echo "· API Key 已存在，保持不动"
else
  echo
  echo "下一步：填 API Key（二选一）"
  echo "  · 图形界面：重载后点菜单栏图标 → 设置…，粘贴后点「保存」，可当场「测试连接」"
  echo "  · 命令行：  printf '%s' 'sk-your-key' > \"$KEYFILE\""
fi

echo
echo "装好了。重载 Hammerspoon 即可（菜单栏图标 → 重新加载配置，或控制台 ⌘R）。"
