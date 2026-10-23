-- WordWand · 文字魔杖
-- 选中任意文字 → 按一下快捷键 → 弹出面板选处理方式 → 原地替换
-- 依赖 Hammerspoon，走任意 OpenAI 兼容接口（默认示例为 TeamoRouter）
--
-- 项目主页：https://github.com/tangbonze/wordwand
-- 许可证：MIT
--
-- 快捷键：⌃⌥R 弹面板　⌃⌥X 暂停/启用

local HOME = os.getenv("HOME")

require("hs.ipc")

hs.autoLaunch(true)  -- 登录时自动启动 Hammerspoon；不需要可改成 false

-- ==========================================================================
-- 配置：只需要改这一块
-- ==========================================================================
local CFG = {
  -- 任何 OpenAI 兼容的 /v1/chat/completions 地址都行
  api_url      = "https://api.teamorouter.com/v1/chat/completions",

  temperature  = 0.3,
  timeout      = 60,

  -- API Key 的三种取法，按顺序尝试：环境变量 → 文件 → 钥匙串
  env_key      = "WORDWAND_API_KEY",
  key_file     = HOME .. "/.hammerspoon/secrets/teamorouter.key",
  keychain_svc = "hammerspoon-teamorouter",

  -- 菜单栏图标（矢量 PDF，模板图，自动适配明暗）
  icon         = HOME .. "/.hammerspoon/icons/rewrite.pdf",

  -- 拉不到线上模型列表时的兜底选项
  models = {
    "deepseek-v4-flash",
    "deepseek-v4-flash-free",
    "deepseek-flash-free",
    "glm-5.3-flash",
    "gemini-3.8-flash",
    "claude-haiku-4-5",
    "gpt-5.6-luna",
  },
}

CFG.model = hs.settings.get("rewriteModel") or CFG.models[1]

local MODES = {
  { name = "润色", hint = "修语法错字，去冗余，保持原意",
    prompt = "你是中英文写作编辑。修正语法、错别字和标点，删去冗余与重复，让表达清晰自然。保持原意、原语言、原有格式（换行、列表、Markdown 标记、代码块）。只输出改写后的正文，不要解释、不要前言、不要用引号包裹。" },
  { name = "精简", hint = "压缩到六成，保留关键信息",
    prompt = "把用户提供的文字压缩到原长度的六成左右，保留全部关键信息和语气，删掉铺垫、重复和客套。保持原语言和原有格式。只输出压缩后的正文，不要解释。" },
  { name = "正式", hint = "转商务书面语，去掉口语",
    prompt = "把用户提供的文字改写成正式、专业、克制的书面语，适合商务邮件或对外沟通：去掉口语词和语气助词，句子结构完整，不用感叹号。保持原意和原有格式。只输出改写后的正文，不要解释。" },
  { name = "中译英", hint = "地道英文，不是逐字直译",
    prompt = "Translate the user's text into natural, idiomatic English as a native professional would write it. Preserve the original meaning, tone, structure and formatting. Output only the translation, no explanations, no quotes." },
  { name = "英译中", hint = "自然中文，去掉翻译腔",
    prompt = "把用户提供的英文翻译成自然、地道的中文，术语准确，不要翻译腔，不要生硬直译。保持原有结构与格式。只输出译文，不要解释、不要引号。" },
  { name = "口语化", hint = "改成日常说话的语气",
    prompt = "把用户提供的文字改写成日常口语，自然、简短、像人随口说的，保留原意和关键信息。只输出改写后的正文，不要解释。" },
  { name = "自定义", hint = "自己输入指令再执行", custom = true, lastInput = "改成更口语的表达" },
}

local busy = false
local progressId = nil

local function trim(s)
  if not s then return nil end
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readFile(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function getKey()
  -- 1) 环境变量：适合从 launchd / shell 注入，不落盘
  local env = trim(os.getenv(CFG.env_key or ""))
  if env and #env > 10 then return env, "env" end

  -- 2) 文件：改完不用重载，每次请求现读
  local k = trim(readFile(CFG.key_file))
  if k and #k > 10 then return k, "file" end

  -- 3) 钥匙串：security add-generic-password -s hammerspoon-teamorouter -w <KEY>
  local out, ok = hs.execute("security find-generic-password -s '" .. CFG.keychain_svc .. "' -w 2>/dev/null")
  if ok then
    local kk = trim(out)
    if kk and #kk > 10 then return kk, "keychain" end
  end
  return nil
end

-- 统一提示样式：所有 toast 字号一致
local TOAST = {
  textSize    = 15,
  radius      = 12,
  strokeWidth = 0.5,
  strokeColor = { white = 1, alpha = 0.10 },
  padding     = 12,
  fillColor   = { white = 0.10, alpha = 0.92 },
  textColor   = { white = 1, alpha = 1 },
}

local function toast(msg, secs)
  if progressId then
    pcall(hs.alert.closeSpecific, progressId)
    progressId = nil
  end
  return hs.alert.show(msg, TOAST, nil, secs or 1.6)
end

local function showProgress(msg)
  if progressId then pcall(hs.alert.closeSpecific, progressId) end
  progressId = hs.alert.show(msg, TOAST, nil, 0)
end

local function hideProgress()
  if progressId then
    pcall(hs.alert.closeSpecific, progressId)
    progressId = nil
  end
end

local pushRecentModel   -- 下面才定义，先声明避免全局变量
local showModelPicker   -- 同理：面板在 POP 那一段之后才定义

local function setModel(name)
  name = trim(name)
  if not name or name == "" then return end
  CFG.model = name
  hs.settings.set("rewriteModel", name)
  pushRecentModel(name)
  toast("模型已切换：" .. name, 1.2)
end

--------------------------------------------------------------------------
-- 模型列表：启动读本地缓存，后台向 /v1/models 刷新（12 小时有效）
--------------------------------------------------------------------------
local MODELS_CACHE = HOME .. "/.hammerspoon/models.cache.json"
local MODEL_TTL = 12 * 3600
local models = {}      -- 网关实际可用、且适合纯文本改写的模型
local modelsAt = 0

-- 图像类模型走 chat/completions 会报错，直接从列表里剔掉
local function chatOnly(id)
  local s = string.lower(id)
  if s:find("image", 1, true) then return false end
  if s:find("nano-banana", 1, true) then return false end
  return true
end

local function modelList()
  if #models > 0 then return models end
  return CFG.models   -- 还没拉到线上列表时用内置兜底
end

local function setModels(ids, at)
  table.sort(ids)
  models = ids
  modelsAt = at or os.time()
end

local function loadModelsCache()
  local raw = readFile(MODELS_CACHE)
  if not raw then return false end
  local ok, d = pcall(hs.json.decode, raw)
  if not ok or type(d) ~= "table" or type(d.ids) ~= "table" then return false end
  setModels(d.ids, d.ts)
  return true
end

local function saveModelsCache(ids)
  local f = io.open(MODELS_CACHE, "w")
  if not f then return end
  f:write(hs.json.encode({ ts = os.time(), ids = ids }))
  f:close()
end

local function fetchModels(cb)   -- cb(errText, count)
  local key = getKey()
  if not key then return cb("没有 API Key") end
  local url = (CFG.api_url:gsub("/chat/completions$", "/models"))
  local ok, err = pcall(hs.http.asyncGet, url,
    { ["Authorization"] = "Bearer " .. key },
    function(status, body)
      if status ~= 200 then return cb("HTTP " .. tostring(status)) end
      local okd, d = pcall(hs.json.decode, body or "")
      if not okd or type(d) ~= "table" or type(d.data) ~= "table" then
        return cb("返回内容无法解析")
      end
      local ids = {}
      for _, m in ipairs(d.data) do
        local id = m.id or m.name
        if id and chatOnly(id) then ids[#ids + 1] = id end
      end
      if #ids == 0 then return cb("列表为空") end
      setModels(ids)
      saveModelsCache(ids)
      cb(nil, #ids)
    end)
  if not ok then cb("请求异常：" .. tostring(err)) end
end

local function recentModels()
  local r = hs.settings.get("rewriteRecentModels")
  if type(r) ~= "table" then r = {} end
  return r
end

pushRecentModel = function(name)
  local out = { name }
  for _, v in ipairs(recentModels()) do
    if v ~= name and #out < 5 then out[#out + 1] = v end
  end
  hs.settings.set("rewriteRecentModels", out)
end

-- 模型多，用带搜索的自绘面板挑（和划词面板同一套视觉）
local function pickModel(list)
  showModelPicker(list, CFG.model, function(id)
    if id then setModel(id) end
  end)
end

local function refreshModels(verbose)
  if verbose then showProgress("刷新模型列表…") end
  fetchModels(function(err, n)
    if verbose then hideProgress() end
    if err then
      if verbose then toast("刷新失败：" .. err, 4) end
      print("模型列表刷新失败：" .. tostring(err))
    else
      print("模型列表已更新：" .. tostring(n) .. " 个")
      if verbose then toast("已更新：" .. n .. " 个模型", 1.5) end
    end
  end)
end

local function readSelection(cb)
  local pb = hs.pasteboard
  local before = pb.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "c", 0)
  local waited = 0
  local timer
  timer = hs.timer.doEvery(0.03, function()
    waited = waited + 0.03
    if hs.pasteboard.changeCount() ~= before then
      timer:stop()
      cb(hs.pasteboard.getContents())
    elseif waited > 0.7 then
      timer:stop()
      cb(nil)
    end
  end)
end

local function pasteText(txt)
  local pb = hs.pasteboard
  local prev = pb.getContents()
  pb.setContents(txt)
  hs.timer.doAfter(0.08, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  end)
  hs.timer.doAfter(0.9, function()
    if prev then pb.setContents(prev) end
  end)
end

local function request(text, systemPrompt, cb)
  local key = getKey()
  if not key then
    cb(nil, "没有找到 API Key，见菜单栏里的说明")
    return
  end
  local body = hs.json.encode({
    model = CFG.model,
    messages = {
      { role = "system", content = systemPrompt },
      { role = "user", content = text },
    },
    temperature = CFG.temperature,
    stream = false,
  })
  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. key,
  }

  local done = false
  local guard = hs.timer.doAfter(CFG.timeout + 5, function()
    if not done then
      done = true
      cb(nil, "请求超时（" .. CFG.timeout .. "s）")
    end
  end)

  local okCall, errCall = pcall(hs.http.asyncPost, CFG.api_url, body, headers, function(status, respBody)
    if done then return end
    done = true
    guard:stop()

    local okDecode, data = pcall(hs.json.decode, respBody or "")
    if status ~= 200 then
      local detail = nil
      if okDecode and data and data.error then
        detail = data.error.message or data.error.type
      end
      cb(nil, "HTTP " .. tostring(status) .. (detail and ("：" .. detail) or ""))
      return
    end
    if not okDecode or not data or not data.choices or not data.choices[1] then
      cb(nil, "返回内容无法解析")
      return
    end
    local msg = data.choices[1].message or {}
    local content = trim(msg.content)
    if not content or content == "" then
      cb(nil, "模型返回了空内容")
      return
    end
    cb(content, nil)
  end)
  if not okCall then
    done = true
    guard:stop()
    cb(nil, "请求异常：" .. tostring(errCall))
  end
end

local function execute(mode, text, targetApp)
  if busy then
    toast("上一个还在处理中…", 1.2)
    return
  end

  local prompt = mode.prompt
  if mode.custom then
    local btn, input = hs.dialog.textPrompt(
      "自定义指令",
      "对选中的 " .. #text .. " 个字符做什么？",
      mode.lastInput, "执行", "取消")
    if btn ~= "执行" then return end
    input = trim(input)
    if not input or input == "" then return end
    mode.lastInput = input
    prompt = input .. "\n\n只输出处理后的正文，不要解释，不要用引号包裹。"
  end

  busy = true
  showProgress(mode.name .. "中…")
  request(text, prompt, function(result, err)
    busy = false
    hideProgress()
    if err then
      toast(mode.name .. "失败：" .. err, 4)
      return
    end
    local function apply()
      pasteText(result)
      toast(mode.name .. "完成", 1.2)
    end
    local activated = false
    if targetApp then
      activated = pcall(function() targetApp:activate() end)
    end
    hs.timer.doAfter(activated and 0.25 or 0, apply)
  end)
end

--------------------------------------------------------------------------
-- macOS 27「Golden Gate」视觉变量
--
-- 27 对 Liquid Glass 的修正主线是「可读性优先」：加强背景扩散、把边缘压暗、
-- 把镜面高光提亮、统一收紧窗口圆角。hs.webview 拿不到 NSVisualEffectView，
-- 网页层做不了对桌面的 backdrop-filter（透明窗口里它只会模糊网页自身的空背景），
-- 所以玻璃感用「不透明度接近实心的染色渐变 + 双层边缘 + 镜面高光」在 CSS 层
-- 还原，而不是靠降低 alpha 让底下的文档透上来——那只会把面板弄脏。
--
-- 留白必须大于阴影扩散半径（约 3σ，σ≈模糊值/2），否则阴影尾巴会被窗口矩形
-- 切出硬边。当前最大层 0 12px 30px -8px → σ=15，侧向 3σ-8=37 ≤ 38，够用。
--------------------------------------------------------------------------
local GLASS = {
  radius     = 12,   -- 27 把各窗口圆角统一收紧，比 26 的小一号
  pad_top    = 36,
  pad_bottom = 64,
  pad_side   = 38,
}

--------------------------------------------------------------------------
-- 弹出面板（hs.webview，自绘 macOS 27 风格）
--------------------------------------------------------------------------
local POP = {
  w = 436,
  pad_top = GLASS.pad_top, pad_bottom = GLASS.pad_bottom, pad_side = GLASS.pad_side,
  row_h = 30, row_gap = 2, card_pad = 7, foot_h = 20,
  wv = nil, uc = nil,
  keyTap = nil, mouseTap = nil,
  onPick = nil, visible = false,
}

-- 按条目数算高度，加减模式时不用改数字
function POP.height()
  local n = #MODES
  local rows = n * POP.row_h + (n - 1) * POP.row_gap
  local card = POP.card_pad * 2 + rows + POP.foot_h
  return POP.pad_top + card + POP.pad_bottom
end

--------------------------------------------------------------------------
-- 两个面板共用同一套卡片样式（圆角/阴影/页脚），保证观感一致
--------------------------------------------------------------------------
local CSS_BASE = ([[
*{box-sizing:border-box;margin:0;padding:0}
html,body{height:100%;background:transparent;overflow:hidden;
 font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;
 -webkit-font-smoothing:antialiased;user-select:none;cursor:default}

/* 玻璃本体：顶部受光的染色渐变，越往下越沉，模拟光从上穿下来。
   边缘三层——0.5px 压暗描边（27 的 darkened edge）、接触阴影、环境阴影；
   内侧再补一道 1px 镜面高光和一道底部压暗，把卡片和桌面「推」开。 */
.card{position:absolute;left:__PS__px;right:__PS__px;top:__PT__px;bottom:__PB__px;
 border-radius:__R__px;padding:7px;display:flex;flex-direction:column;
 background:
  radial-gradient(140% 72% at 50% -18%, rgba(255,255,255,.78), rgba(255,255,255,0) 56%),
  linear-gradient(180deg,#F5F6F9 0%,#F1F2F5 46%,#ECEDF1 100%);
 box-shadow:
  0 0 0 .5px rgba(0,0,0,.15),
  0 2px 5px -1px rgba(0,0,0,.12),
  0 14px 32px -10px rgba(0,0,0,.30),
  inset 0 1px 0 rgba(255,255,255,.92),
  inset 0 -1px 0 rgba(0,0,0,.05)}

/* 镜面高光：沿上边缘的一道窄亮线，两端渐隐，不参与布局 */
.card::after{content:"";position:absolute;left:0;right:0;top:0;height:1px;
 border-radius:inherit;pointer-events:none;
 background:linear-gradient(90deg,
  rgba(255,255,255,0) 3%, rgba(255,255,255,.96) 20%,
  rgba(255,255,255,.96) 80%, rgba(255,255,255,0) 97%)}

.foot{margin-top:auto;height:20px;display:flex;align-items:center;padding:0 9px;
 font-size:11px;color:#8A8F97;letter-spacing:.2px;border-top:1px solid rgba(0,0,0,.055)}

@media (prefers-color-scheme: dark){
 .card{background:
   radial-gradient(140% 72% at 50% -18%, rgba(255,255,255,.11), rgba(255,255,255,0) 58%),
   linear-gradient(180deg,#303136 0%,#28292E 46%,#222327 100%);
  box-shadow:
   0 0 0 .5px rgba(255,255,255,.13),
   0 2px 6px -1px rgba(0,0,0,.45),
   0 12px 30px -8px rgba(0,0,0,.62),
   inset 0 1px 0 rgba(255,255,255,.11),
   inset 0 -1px 0 rgba(0,0,0,.30)}
 .card::after{background:linear-gradient(90deg,
   rgba(255,255,255,0) 3%, rgba(255,255,255,.24) 20%,
   rgba(255,255,255,.24) 80%, rgba(255,255,255,0) 97%)}
 .foot{color:#8E939B;border-top:1px solid rgba(255,255,255,.07)}
}
]]):gsub("__PT__", tostring(GLASS.pad_top))
   :gsub("__PB__", tostring(GLASS.pad_bottom))
   :gsub("__PS__", tostring(GLASS.pad_side))
   :gsub("__R__",  tostring(GLASS.radius))

local CSS_MODE = [[
.rows{display:flex;flex-direction:column;gap:2px}
.row{display:flex;align-items:center;height:30px;padding:0 9px;border-radius:6px;gap:10px;
 transition:background .11s ease,box-shadow .11s ease}
.n{font-size:13px;font-weight:510;color:#1D1D1F;width:56px;flex:none;letter-spacing:-.1px}
.h{font-size:12px;color:#7E838C;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* 选中态不是一块死蓝：带顶部镜面高光的玻璃色块，和卡片本身的光感一致 */
.row.on{background:linear-gradient(180deg,#4AA0FF 0%,#0A7EF5 100%);
 box-shadow:inset 0 .5px 0 rgba(255,255,255,.48),0 1px 2.5px rgba(10,110,240,.30)}
.row.on .n{color:#fff}
.row.on .h{color:rgba(255,255,255,.80)}
@media (prefers-color-scheme: dark){
 .n{color:#F2F3F5}.h{color:#969BA4}
 .row.on{background:linear-gradient(180deg,#3D96FF 0%,#0B75E6 100%)}
}
]]

local function page(css, body)
  return '<!doctype html><html><head><meta charset="utf-8"><style>' ..
    CSS_BASE .. css .. '</style></head><body>' .. body .. '</body></html>'
end

local function buildHTML()
  local rows = {}
  for _, m in ipairs(MODES) do
    rows[#rows + 1] = '<div class="row"><span class="n">' .. m.name ..
      '</span><span class="h">' .. m.hint .. '</span></div>'
  end
  return page(CSS_MODE,
    '<div class="card"><div class="rows">' .. table.concat(rows) ..
    '</div><div class="foot">↑↓ 选择　⏎ 执行　esc 取消</div></div>' .. [[
<script>
var sel=0;
var rows=[].slice.call(document.querySelectorAll('.row'));
function paint(){rows.forEach(function(e,i){e.classList.toggle('on',i===sel)});}
function setSel(i){sel=(i+rows.length)%rows.length;paint();}
function move(d){setSel(sel+d);}
function exec(){window.webkit.messageHandlers.rewrite.postMessage(JSON.stringify({i:sel}));}
rows.forEach(function(e,i){
 e.addEventListener('mouseenter',function(){sel=i;paint();});
 e.addEventListener('click',function(){exec();});
});
paint();
</script>]])
end

local function popupStopWatchers()
  if POP.keyTap then POP.keyTap:stop(); POP.keyTap = nil end
  if POP.mouseTap then POP.mouseTap:stop(); POP.mouseTap = nil end
end

local function popupHide()
  popupStopWatchers()
  if POP.wv then pcall(function() POP.wv:hide() end) end
  POP.visible = false
end

local function popupClose(mode)
  if not POP.visible then return end
  popupHide()
  local cb = POP.onPick
  POP.onPick = nil
  if cb then cb(mode) end
end

local DIGITS = { [18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5, [22] = 6, [26] = 7, [28] = 8, [25] = 9 }

local function popupStartWatchers()
  POP.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local kc = e:getKeyCode()
    local f = e:getFlags()
    if f.cmd or f.ctrl or f.alt then return false end

    if kc == 53 then popupClose(nil); return true end
    if kc == 125 or kc == 48 then
      if POP.wv then pcall(function() POP.wv:evaluateJavaScript("move(1)") end) end
      return true
    end
    if kc == 126 then
      if POP.wv then pcall(function() POP.wv:evaluateJavaScript("move(-1)") end) end
      return true
    end
    if kc == 36 or kc == 76 then
      if POP.wv then pcall(function() POP.wv:evaluateJavaScript("exec()") end) end
      return true
    end
    local d = DIGITS[kc]
    if d and d <= #MODES then
      if POP.wv then
        pcall(function() POP.wv:evaluateJavaScript(string.format("setSel(%d);exec()", d - 1)) end)
      end
      return true
    end
    return true
  end)
  POP.keyTap:start()

  POP.mouseTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    if not POP.wv then return false end
    local ok, fr = pcall(function() return POP.wv:frame() end)
    if not ok or not fr then return false end
    -- 命中判定按卡片本身算，窗口四周的透明留白不算（否则面板外面有块点不动的死区）
    local left   = fr.x + POP.pad_side
    local right  = fr.x + fr.w - POP.pad_side
    local bottom = fr.y + POP.pad_bottom
    local top    = fr.y + fr.h - POP.pad_top
    local p = hs.mouse.getAbsolutePosition()
    local inside = p.x >= left and p.x <= right and p.y >= bottom and p.y <= top
    if not inside then popupClose(nil) end
    return false
  end)
  POP.mouseTap:start()
end

local function popupEnsure()
  if POP.wv then return true end

  local okAll, err = pcall(function()
    local uc = hs.webview.usercontent.new("rewrite")
    uc:setCallback(function(msg)
      local body = msg.body
      local idx = nil
      if type(body) == "table" then
        idx = body.i
      else
        local ok, d = pcall(hs.json.decode, body)
        if ok and d then idx = d.i end
      end
      popupClose(idx and MODES[idx + 1] or nil)
    end)

    local screen = hs.screen.mainScreen():frame()
    local h = POP.height()
    local x = math.floor(screen.x + (screen.w - POP.w) / 2)
    local y = math.floor(screen.y + screen.h * 0.26)
    local wv = hs.webview.new({ x = x, y = y, w = POP.w, h = h }, {}, uc)

    pcall(function() wv:windowStyle({ "borderless", "nonactivatingpanel" }) end)
    pcall(function() wv:level(8) end)
    pcall(function() wv:transparent(true) end)
    -- 原生窗口阴影只认矩形边界，会把方框套在圆角卡片外面，所以关掉、改用 CSS 阴影
    pcall(function() wv:shadow(false) end)
    pcall(function() wv:closeOnEscape(false) end)

    wv:html(buildHTML())
    POP.wv = wv
    POP.uc = uc
  end)

  if not okAll then
    print("webview popup failed: " .. tostring(err))
    return false
  end
  return true
end

local function showPopup(onPick)
  POP.onPick = onPick

  if not popupEnsure() then
    -- 兜底：退回系统 chooser
    local choices = {}
    for i, m in ipairs(MODES) do
      choices[i] = { text = m.name, subText = m.hint, idx = i }
    end
    local ch
    ch = hs.chooser.new(function(choice)
      if ch then ch:hide() end
      POP.onPick = nil
      if choice then onPick(MODES[choice.idx]) else onPick(nil) end
    end)
    ch:choices(choices)
    ch:placeholderText("选择处理方式")
    ch:show()
    return
  end

  POP.visible = true
  POP.wv:show()
  hs.timer.doAfter(0.05, function()
    if POP.wv then pcall(function() POP.wv:evaluateJavaScript("setSel(0)") end) end
  end)
  popupStartWatchers()
end

--------------------------------------------------------------------------
-- 模型选择面板（同一套卡片样式，带搜索框）
--------------------------------------------------------------------------
local MPICK = {
  w = 436,
  pad_top = GLASS.pad_top, pad_bottom = GLASS.pad_bottom, pad_side = GLASS.pad_side,
  card_pad = 7, search_h = 30, gap = 6, rows_visible = 8, row_h = 28, foot_h = 20,
  wv = nil, uc = nil, keyTap = nil, mouseTap = nil,
  onPick = nil, visible = false,
}

function MPICK.listH() return MPICK.rows_visible * MPICK.row_h + (MPICK.rows_visible - 1) * 2 end
function MPICK.cardH()
  return MPICK.card_pad * 2 + MPICK.search_h + MPICK.gap + MPICK.listH() + MPICK.foot_h
end
function MPICK.height() return MPICK.pad_top + MPICK.cardH() + MPICK.pad_bottom end

local CSS_PICK = [[
/* 搜索栏按 27 的「统一工具栏」处理：压进卡片顶部的凹槽，列表从它下面滚过 */
.sbox{height:30px;flex:none;display:flex;align-items:center;gap:6px;
 padding:0 9px;margin-bottom:6px;background:rgba(120,122,128,.11);border-radius:8px;
 box-shadow:inset 0 1px 2px rgba(0,0,0,.05),inset 0 -.5px 0 rgba(255,255,255,.65)}
.sbox svg{flex:none;opacity:.42}
.sbox input{flex:1;min-width:0;border:0;outline:0;background:transparent;
 font:inherit;font-size:13px;color:#1D1D1F;pointer-events:none}
.sbox input::placeholder{color:#9BA0A8}
.cnt{flex:none;font-size:11px;color:#8A8F97;font-variant-numeric:tabular-nums}
.list{height:238px;overflow-y:auto;display:flex;flex-direction:column;gap:2px}
.list::-webkit-scrollbar{display:none}
/* 27 的 scroll edge effect：内容滚到工具栏下面时顶端渐隐，而不是被硬切 */
.list.sfade{-webkit-mask-image:linear-gradient(180deg,transparent 0,#000 14px,#000 calc(100% - 14px),transparent 100%);
 mask-image:linear-gradient(180deg,transparent 0,#000 14px,#000 calc(100% - 14px),transparent 100%)}
.row{display:flex;align-items:center;height:28px;padding:0 9px;border-radius:6px;flex:none;
 transition:background .11s ease,box-shadow .11s ease}
.mn{font-size:13px;color:#1D1D1F;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
 letter-spacing:-.1px}
.ck{flex:none;font-size:12px;color:#0A84FF;padding-left:6px}
.row.on{background:linear-gradient(180deg,#4AA0FF 0%,#0A7EF5 100%);
 box-shadow:inset 0 .5px 0 rgba(255,255,255,.48),0 1px 2.5px rgba(10,110,240,.30)}
.row.on .mn,.row.on .ck{color:#fff}
.empty{padding:10px 9px;font-size:12px;color:#8A8F97}
@media (prefers-color-scheme: dark){
 .sbox{background:rgba(120,122,128,.24);
  box-shadow:inset 0 1px 2px rgba(0,0,0,.28),inset 0 -.5px 0 rgba(255,255,255,.08)}
 .sbox input{color:#F2F3F5}
 .mn{color:#F2F3F5}
 .row.on{background:linear-gradient(180deg,#3D96FF 0%,#0B75E6 100%)}
}
]]

local MAG = '<svg width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6"><circle cx="6.6" cy="6.6" r="4.6"/><path d="M10.2 10.2 14 14" stroke-linecap="round"/></svg>'

local PICK_JS = [[
<script>
var DATA = __DATA__, CUR = __CUR__;
var view = DATA.slice(), sel = 0, q = '';
var list = document.getElementById('list');
var box  = document.getElementById('q');
var cnt  = document.getElementById('cnt');
function esc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function render(){
  var needle = q.toLowerCase();
  view = DATA.filter(function(m){ return m.toLowerCase().indexOf(needle) >= 0; });
  box.value = q;
  cnt.textContent = view.length;
  if (!view.length) { list.innerHTML = '<div class="empty">没有匹配的模型</div>'; return; }
  if (sel > view.length - 1) sel = view.length - 1;
  if (sel < 0) sel = 0;
  var html = '';
  for (var i = 0; i < view.length; i++) {
    var m = view[i];
    html += '<div class="row' + (i === sel ? ' on' : '') + '" data-i="' + i + '">' +
            '<span class="mn">' + esc(m) + '</span>' +
            (m === CUR ? '<span class="ck">✓</span>' : '') + '</div>';
  }
  list.innerHTML = html;
  var el = list.querySelector('.row.on');
  if (el) {
    if (sel === 0) { list.scrollTop = 0; }        /* 回到顶部，避免首行被切 */
    else { el.scrollIntoView({ block: 'nearest' }); }
  }
  syncFade();
}
/* 27 的 scroll edge effect：滚动时才给列表加渐隐遮罩 */
function syncFade(){ list.classList.toggle('sfade', list.scrollTop > 2); }
list.addEventListener('scroll', syncFade);
function setQuery(t){ q = t; sel = 0; render(); }
function type(t){ setQuery(q + t); }
function back(){ setQuery(q.slice(0, -1)); }
function move(d){
  if (!view.length) return;
  sel = (sel + d + view.length) % view.length;
  render();
}
function exec(){
  if (!view.length) return;
  window.webkit.messageHandlers.modelpick.postMessage(JSON.stringify({ id: view[sel] }));
}
list.addEventListener('click', function(e){
  var r = e.target.closest ? e.target.closest('.row') : null;
  if (!r) return;
  sel = parseInt(r.getAttribute('data-i'), 10);
  exec();
});
/* 打开时落在当前模型那一行 */
sel = Math.max(0, DATA.indexOf(CUR));
render();
</script>
]]

-- hs.json.encode 只接受 table，字符串得自己转义成 JS 字面量
local function jsonStr(s)
  s = tostring(s or "")
  s = s:gsub('[\\"]', function(c) return "\\" .. c end)
  s = s:gsub("[%z\1-\31]", function(c) return string.format("\\u%04x", c:byte()) end)
  return '"' .. s .. '"'
end

local function buildModelHTML(list, current)
  local body = '<div class="card"><div class="sbox">' .. MAG ..
    '<input id="q" readonly placeholder="搜索模型"><span class="cnt" id="cnt"></span></div>' ..
    '<div class="list" id="list"></div>' ..
    '<div class="foot">↑↓ 选择　⏎ 确认　esc 取消</div></div>'
  local js = PICK_JS
    :gsub("__DATA__", function() return hs.json.encode(list) end)
    :gsub("__CUR__",  function() return jsonStr(current) end)
  return page(CSS_PICK, body .. js)
end

local function mpickStopWatchers()
  if MPICK.keyTap then MPICK.keyTap:stop(); MPICK.keyTap = nil end
  if MPICK.mouseTap then MPICK.mouseTap:stop(); MPICK.mouseTap = nil end
end

local function mpickHide()
  mpickStopWatchers()
  if MPICK.wv then pcall(function() MPICK.wv:hide() end) end
  MPICK.visible = false
end

local function mpickClose(model)
  if not MPICK.visible then return end
  mpickHide()
  local cb = MPICK.onPick
  MPICK.onPick = nil
  if cb then cb(model) end
end

local function mpickJS(code)
  if MPICK.wv then pcall(function() MPICK.wv:evaluateJavaScript(code) end) end
end

local function mpickStartWatchers()
  MPICK.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local f = e:getFlags()
    if f.cmd or f.ctrl or f.alt then return false end
    local kc = e:getKeyCode()

    if kc == 53 then mpickClose(nil); return true end                       -- esc
    if kc == 125 or kc == 48 then mpickJS("move(1)"); return true end       -- ↓ / space
    if kc == 126 then mpickJS("move(-1)"); return true end                  -- ↑
    if kc == 36 or kc == 76 then mpickJS("exec()"); return true end         -- ⏎
    if kc == 51 then mpickJS("back()"); return true end                     -- ⌫

    local ch = e:getCharacters()
    if ch and #ch > 0 and ch:byte() >= 32 then
      mpickJS("type(" .. jsonStr(ch) .. ")")
      return true
    end
    return true
  end)
  MPICK.keyTap:start()

  MPICK.mouseTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    if not MPICK.wv then return false end
    local ok, fr = pcall(function() return MPICK.wv:frame() end)
    if not ok or not fr then return false end
    local left   = fr.x + MPICK.pad_side
    local right  = fr.x + fr.w - MPICK.pad_side
    local bottom = fr.y + MPICK.pad_bottom
    local top    = fr.y + fr.h - MPICK.pad_top
    local p = hs.mouse.getAbsolutePosition()
    if not (p.x >= left and p.x <= right and p.y >= bottom and p.y <= top) then
      mpickClose(nil)
    end
    return false
  end)
  MPICK.mouseTap:start()
end

local function mpickEnsure()
  if MPICK.wv then return true end
  local okAll, err = pcall(function()
    local uc = hs.webview.usercontent.new("modelpick")
    uc:setCallback(function(msg)
      local body = msg.body
      local id = nil
      if type(body) == "table" then
        id = body.id
      else
        local ok, d = pcall(hs.json.decode, body)
        if ok and d then id = d.id end
      end
      mpickClose(id)
    end)

    local screen = hs.screen.mainScreen():frame()
    local x = math.floor(screen.x + (screen.w - MPICK.w) / 2)
    local y = math.floor(screen.y + screen.h * 0.18)
    local wv = hs.webview.new({ x = x, y = y, w = MPICK.w, h = MPICK.height() }, {}, uc)

    pcall(function() wv:windowStyle({ "borderless", "nonactivatingpanel" }) end)
    pcall(function() wv:level(8) end)
    pcall(function() wv:transparent(true) end)
    pcall(function() wv:shadow(false) end)
    pcall(function() wv:closeOnEscape(false) end)

    MPICK.wv = wv
    MPICK.uc = uc
  end)
  if not okAll then
    print("model picker failed: " .. tostring(err))
    return false
  end
  return true
end

showModelPicker = function(list, current, cb)
  list = list or modelList()
  if #list == 0 then
    toast("模型列表还是空的，先在菜单里点「刷新列表」", 2.5)
    return
  end

  if not mpickEnsure() then
    -- 兜底：退回系统 chooser
    local choices = {}
    for i, m in ipairs(list) do
      choices[i] = { text = m, subText = (m == current) and "当前" or nil, idx = i }
    end
    local ch
    ch = hs.chooser.new(function(choice)
      if ch then ch:hide() end
      if choice then cb(list[choice.idx]) else cb(nil) end
    end)
    ch:choices(choices)
    ch:placeholderText("搜索模型（共 " .. #list .. " 个）")
    ch:show()
    return
  end

  MPICK.onPick = cb
  MPICK.visible = true
  MPICK.wv:html(buildModelHTML(list, current))
  MPICK.wv:show()
  mpickStartWatchers()
end

--------------------------------------------------------------------------

local function runMode(mode)
  local app = hs.application.frontmostApplication()
  readSelection(function(raw)
    local text = trim(raw)
    if not text or text == "" then
      toast("先选中一段文字再按 ⌃⌥R", 1.8)
      return
    end
    execute(mode, text, app)
  end)
end

local function pick()
  if busy then
    toast("上一个还在处理中…", 1.2)
    return
  end
  if POP.visible then
    popupClose(nil)
    return
  end

  local app = hs.application.frontmostApplication()
  readSelection(function(raw)
    local text = trim(raw)
    if not text or text == "" then
      toast("先选中一段文字再按 ⌃⌥R", 1.8)
      return
    end
    showPopup(function(mode)
      if not mode then return end
      execute(mode, text, app)
    end)
  end)
end

local enabled = true

local hkPick = hs.hotkey.bind({ "ctrl", "alt" }, "R", pick)

hs.hotkey.bind({ "ctrl", "alt" }, "X", function()
  enabled = not enabled
  if enabled then hkPick:enable() else hkPick:disable() end
  toast(enabled and "已启用" or "已暂停", 1.5)
end)

local menu = hs.menubar.new()
_G.hsRewriteMenu = menu
if menu then
  pcall(function() menu:setIcon(CFG.icon, true) end)
  menu:setTooltip("划词改写 · ⌃⌥R")
  menu:setMenu(function()
    local items = {}

    items[#items + 1] = {
      title = "⌃⌥R  选择处理方式…",
      fn = function() hs.timer.doAfter(0.2, pick) end,
    }
    items[#items + 1] = { title = "-" }

    for _, mode in ipairs(MODES) do
      items[#items + 1] = {
        title = mode.name .. "   " .. mode.hint,
        fn = function()
          hs.timer.doAfter(0.2, function() runMode(mode) end)
        end,
      }
    end

    items[#items + 1] = { title = "-" }

    local list = modelList()
    local modelItems = {}

    local rec = recentModels()
    if #rec > 0 then
      for _, m in ipairs(rec) do
        modelItems[#modelItems + 1] = {
          title = m,
          checked = (m == CFG.model),
          fn = function() setModel(m) end,
        }
      end
      modelItems[#modelItems + 1] = { title = "-" }
    end

    modelItems[#modelItems + 1] = {
      title = "搜索模型…（" .. #list .. " 个可用）",
      fn = function() hs.timer.doAfter(0.15, function() pickModel() end) end,
    }
    modelItems[#modelItems + 1] = { title = "-" }

    local allItems = {}
    for _, m in ipairs(list) do
      allItems[#allItems + 1] = {
        title = m,
        checked = (m == CFG.model),
        fn = function() setModel(m) end,
      }
    end
    modelItems[#modelItems + 1] = { title = "全部模型", menu = allItems }
    modelItems[#modelItems + 1] = {
      title = "刷新列表",
      fn = function() hs.timer.doAfter(0.15, function() refreshModels(true) end) end,
    }
    modelItems[#modelItems + 1] = { title = "-" }
    modelItems[#modelItems + 1] = {
      title = "自定义模型…",
      fn = function()
        local btn, input = hs.dialog.textPrompt(
          "自定义模型",
          "输入 TeamoRouter 的模型 ID",
          CFG.model, "确定", "取消")
        if btn == "确定" then setModel(input) end
      end,
    }
    items[#items + 1] = { title = "模型：" .. CFG.model, menu = modelItems }

    local kk, src = getKey()
    items[#items + 1] = {
      title = kk and ("API Key：已配置（" .. tostring(src) .. "）") or "API Key：未配置",
      fn = function()
        toast("把 key 写进 " .. CFG.key_file .. " 即可，无需重载", 5)
      end,
    }
    items[#items + 1] = {
      title = "测试 API 连接 · " .. CFG.model,
      fn = function()
        showProgress("测试连接中…")
        request("你好", "只回复两个字：可用", function(res, err)
          hideProgress()
          if err then
            toast("连接失败：" .. err, 6)
          else
            toast("连接正常：" .. res, 3)
          end
        end)
      end,
    }

    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
      title = "打开配置文件",
      fn = function() hs.execute('open "' .. HOME .. '/.hammerspoon/init.lua"') end,
    }
    items[#items + 1] = {
      title = "重新加载配置",
      fn = function() hs.reload() end,
    }
    items[#items + 1] = {
      title = enabled and "暂停全部快捷键（⌃⌥X）" or "启用全部快捷键（⌃⌥X）",
      fn = function()
        enabled = not enabled
        if enabled then hkPick:enable() else hkPick:disable() end
        toast(enabled and "已启用" or "已暂停", 1)
      end,
    }
    return items
  end)
end

-- 后台预热面板，让首次 ⌃⌥R 也秒开
hs.timer.doAfter(3, function()
  local ok, err = pcall(popupEnsure)
  if not ok then print("prewarm failed: " .. tostring(err)) end
end)

-- 调试出口：在 Hammerspoon 控制台里可以直接调
--   _G.hsRewritePreview()   预览划词面板
--   _G.hsRewritePickModel() 打开模型选择面板
--   _G.hsRewriteMenu        菜单栏对象
_G.hsRewritePickModel = pickModel
_G.hsRewritePreview = function()
  showPopup(function() end)
  if POP.mouseTap then POP.mouseTap:stop(); POP.mouseTap = nil end
  return POP.height()
end

-- 先吃本地缓存，再按需向网关刷新（过期才拉，避免每次加载都打一次接口）
loadModelsCache()
hs.timer.doAfter(1.5, function()
  if os.time() - modelsAt > MODEL_TTL then refreshModels(false) end
end)

local k1, s1 = getKey()
print(string.format("WordWand 已就绪 · 模型 %s（列表 %d 个）· ⌃⌥R 弹面板 · API Key %s",
  CFG.model, #modelList(),
  k1 and ("已配置(" .. tostring(s1) .. ")")
     or ("未配置 → 写入 " .. CFG.key_file .. " 或设置环境变量 " .. CFG.env_key)))
