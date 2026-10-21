# WordWand

> Select text, hit ⌃⌥R, pick a tone, done — in place.

A select-to-rewrite tool for macOS. It wraps [Hammerspoon](https://www.hammerspoon.org/), talks to **any OpenAI-compatible endpoint**, and collapses "select → copy → call the model → paste back" into two key presses. Your text only goes to the endpoint you configure — never through a third party.

[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](#)
[![License](https://img.shields.io/badge/license-MIT-3DA639)](#license)
[![Made with](https://img.shields.io/badge/made%20with-Hammerspoon-2C2C2E)](https://www.hammerspoon.org/)

[中文](README.md) · **English**

![Mode panel](docs/screenshots/modes.png)

---

## Why

I wanted something like **Myna** — select a sentence, press a key, and it reads better. But Myna is Windows-only, and most alternatives either require a subscription, lock you into one model, or quietly ship your text to their own servers.

WordWand takes a different route: **own the UI, own the model.**

- The panel is hand-drawn (not a system component) and follows macOS visual language
- Models are pulled from your endpoint; the key stays in your hands
- Everything lives in one `init.lua` — change behavior by editing it

## Features

| | |
|---|---|
| **One shortcut** | No seven-combo memory game. ⌃⌥R opens the panel, ↑↓ picks, ⏎ runs |
| **Seven presets** | Polish / Condense / Formal / ZH→EN / EN→ZH / Casual / Custom |
| **In-place replace** | Result is pasted back over your selection — no window switching, no manual copy/paste |
| **Any model** | Reads `/v1/models` from your gateway; dozens of models, searchable |
| **Remembers** | Recently used models float to the top across restarts; current one is checked |
| **Never steals focus** | The panel is a non-activating overlay, so the original app stays frontmost and paste-back works |
| **Light & dark** | Follows the system appearance; the menu bar icon is a vector template image |
| **Key never in config** | Env var / `chmod 600` file / Keychain, tried in that order |
| **Real error messages** | HTTP status, parse failures and timeouts surface instead of failing silently |

## Screenshots

**Mode panel** — appears on ⌃⌥R. Arrow keys move, ⏎ runs, digits 1–7 jump straight to an item.

![Mode panel](docs/screenshots/modes.png)

**Model panel** — from the menu bar: *搜索模型…*. Type to filter (no need to click the field first); the active model is checked.

![Model panel](docs/screenshots/models.png)

## Install

### 1. Hammerspoon

```bash
brew install --cask hammerspoon
```

On first launch it asks for **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable Hammerspoon. Without it, simulated ⌘C can't read your selection.

### 2. Deploy

```bash
git clone https://github.com/tangbonze/wordwand.git
cd wordwand
./install.sh
```

The script copies `init.lua` and the icon into `~/.hammerspoon/`, backing up any existing `init.lua` as `init.lua.bak.<timestamp>`.

Manual alternative:

```bash
cp init.lua ~/.hammerspoon/init.lua
mkdir -p ~/.hammerspoon/icons && cp icons/rewrite.pdf ~/.hammerspoon/icons/
```

### 3. API key

Pick one. Lookup order is **env → file → Keychain**.

**A. File (simplest)**

```bash
mkdir -p ~/.hammerspoon/secrets && chmod 700 ~/.hammerspoon/secrets
printf '%s' 'sk-your-key-here' > ~/.hammerspoon/secrets/teamorouter.key
chmod 600 ~/.hammerspoon/secrets/teamorouter.key
```

Takes effect immediately — the file is re-read on every request, no reload needed.

**B. Environment variable**

```bash
launchctl setenv WORDWAND_API_KEY 'sk-your-key-here'
```

`launchctl setenv` does not affect already-running apps; restart Hammerspoon.

**C. Keychain**

```bash
security add-generic-password -s hammerspoon-teamorouter -w 'sk-your-key-here'
```

### 4. Point it at your endpoint (optional)

The default is TeamoRouter. To use OpenAI, DeepSeek, Moonshot, a local vLLM or Ollama, edit one line at the top of `init.lua`:

```lua
local CFG = {
  api_url = "https://api.openai.com/v1/chat/completions",
  ...
}
```

Anything OpenAI-compatible on `/v1/chat/completions` works. Afterwards refresh the list: menu bar → 模型 → 刷新列表.

### 5. Reload

Menu bar icon → **重新加载配置**, or ⌘R in the Hammerspoon console.

You should see:

```
WordWand 已就绪 · 模型 deepseek-v4-flash（列表 53 个）· ⌃⌥R 弹面板 · API Key 已配置(file)
```

## Usage

| Action | Shortcut |
|---|---|
| Open panel on selection | `⌃⌥R` |
| Move | `↑` `↓` |
| Run | `⏎` |
| Jump to item N | `1`–`7` |
| Cancel | `esc` |
| Pause / resume all shortcuts | `⌃⌥X` |

Typical flow:

1. Select text in any app (Mail, Slack, Notes, browser — anything)
2. Press `⌃⌥R`
3. Pick a mode with `↑↓`, press `⏎`
4. A "润色中…" toast appears, then the selection is replaced and you get a "润色完成" confirmation

The menu bar menu also offers: run a mode directly, switch model, search models, test the API connection, open the config, reload, and pause.

## Customizing

### Add a mode

Append to the `MODES` table. The panel grows automatically (window height is computed from the item count):

```lua
{ name = "译成日文", hint = "自然日语，敬语得体",
  prompt = "把下面的文字翻译成自然的日语，敬语得体，不要翻译腔。只输出译文。" },
```

### Change the default model

Pick one from the menu once — it's persisted via `hs.settings`. Or edit `CFG.models[1]`.

### Change the shortcut

```lua
local hkPick = hs.hotkey.bind({ "ctrl", "alt" }, "R", pick)
```

## FAQ

**Nothing happens**
Check Hammerspoon's Accessibility permission, then open the console (menu bar → Console) for Lua errors.

**"先选中一段文字再按 ⌃⌥R"**
Selection is read by simulating `⌘C`. Apps that don't support `⌘C` (some terminals, remote desktops, games) won't work.

**HTTP 401 / 403**
Wrong or missing key. The menu item "API Key：…" shows which source was used (env / file / keychain).

**Model not found / 400**
Try another model. Not every model listed by `/v1/models` is callable; image models (name contains `image`) are filtered out automatically since they can't serve chat completions.

**My clipboard changed**
The clipboard is used to carry the result, then restored after 0.9 s. Non-text clipboard contents may not survive intact.

**Empty model list / odd panel**
Delete `~/.hammerspoon/models.cache.json` and reload to re-fetch.

## Project layout

```
wordwand/
├── init.lua                 # all logic, single file, ~1000 lines
├── icons/rewrite.pdf        # menu bar icon (18×18 vector template)
├── install.sh               # deploy to ~/.hammerspoon
├── docs/screenshots/        # documentation images
├── README.md                # 中文
└── README.en.md             # English
```

Sections inside `init.lua`:

- `CFG` — configuration (endpoint, key sources, fallback models)
- `MODES` — the seven prompts
- `request()` — request building, timeout guard, error classification
- `readSelection()` / `pasteText()` — grab the selection, paste it back
- `POP` / `MPICK` — the two hand-drawn panels

## Known limitations

- **macOS only**, depends on Hammerspoon
- Selection capture relies on simulated `⌘C`; a few apps won't cooperate
- Long text is bounded by the model's context window — it errors instead of chunking
- The panel is fixed at horizontal center, ~26% down the screen; it doesn't follow the cursor

## Credits

- [Hammerspoon](https://www.hammerspoon.org/) — none of this exists without it
- Myna — the original inspiration (Windows only, unfortunately)

## License

[MIT](LICENSE) © 2026 Ke Feng
