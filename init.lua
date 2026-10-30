-- WordWand · 文字魔杖
-- 选中任意文字 → 按一下快捷键 → 弹出面板选处理方式 → 原地替换
-- 依赖 Hammerspoon，走任意 OpenAI 兼容接口（默认示例为 TeamoRouter）
--
-- 项目主页：https://github.com/tangbonze/wordwand
-- 许可证：MIT
--
-- 快捷键：⌃⌥R 弹面板　⌃⌥X 暂停/启用（都可以在菜单栏 → 设置… 里重新录）

local HOME = os.getenv("HOME")

require("hs.ipc")

-- 登录时自动启动：首次运行默认打开，之后以设置面板里的开关为准
local autoPref = hs.settings.get("autoLaunch")
hs.autoLaunch(autoPref == nil and true or autoPref)

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
-- 设置面板里改过的接口地址优先于上面写死的默认值
CFG.api_url = hs.settings.get("apiUrl") or CFG.api_url
-- 温度 / 超时也只在这里给默认值，实际取值以设置面板存的为准
CFG.temperature = tonumber(hs.settings.get("temperature")) or CFG.temperature
CFG.timeout     = tonumber(hs.settings.get("timeout"))     or CFG.timeout

-- ==========================================================================
-- 快捷键：默认 ⌃⌥R 划词改写、⌃⌥X 暂停/启用，设置面板里可以重新录
--
-- 存成 "ctrl+alt|R" 这样的字符串而不是 table：hs.settings 只保证字符串能存，
-- table 的编码方式跟 Hammerspoon 版本有关，用最朴素的形式升级也不会失效。
-- 真正的 bind 放在文件末尾——要等 pick() 定义出来才能当回调。
-- ==========================================================================
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }
local MOD_SYM   = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }
-- 单独按下不算组合键的键码：caps lock、fn，以及左右各四个修饰键
local MOD_ONLY  = { [54] = 1, [55] = 1, [56] = 1, [57] = 1,
                    [58] = 1, [59] = 1, [60] = 1, [61] = 1, [62] = 1, [63] = 1 }

local function hkLoad(name, dm, dk)
  local s = hs.settings.get("hotkey:" .. name)
  local mods, key
  if type(s) == "string" then mods, key = s:match("^([%w+]*)|(.+)$") end
  if key and key ~= "" then
    local set = {}
    for m in mods:gmatch("[^+]+") do
      if MOD_SYM[m] then set[m] = true end
    end
    local out = {}
    for _, m in ipairs(MOD_ORDER) do          -- 按固定顺序排，显示位置才稳定
      if set[m] then out[#out + 1] = m end
    end
    if #out > 0 then return { mods = out, key = key } end
  end
  return { mods = dm, key = dk }
end

local HK = {
  pick   = hkLoad("pick",   { "ctrl", "alt" }, "R"),
  toggle = hkLoad("toggle", { "ctrl", "alt" }, "X"),
}

local hotkeys = { pick = nil, toggle = nil }
local enabled = true      -- ⌃⌥X 的开关：false 时只有划词快捷键停用
local hkApply             -- 真正去 bind，定义在文件末尾

local function hkLabel(h)
  local s = ""
  for _, m in ipairs(h.mods) do s = s .. MOD_SYM[m] end
  if #h.key == 1 then return s .. h.key:upper() end
  return s .. h.key:sub(1, 1):upper() .. h.key:sub(2):lower()
end

local function hkSame(a, b)
  if #a.mods ~= #b.mods then return false end
  for i = 1, #a.mods do
    if a.mods[i] ~= b.mods[i] then return false end
  end
  return a.key:lower() == b.key:lower()
end

local function hkSave(name, h)
  HK[name] = h
  hs.settings.set("hotkey:" .. name, table.concat(h.mods, "+") .. "|" .. h.key)
end

-- 录音期间要临时把全局快捷键摘掉，否则「按新组合键」这一步会先触发旧快捷键
local function hkSuspend()
  for _, n in ipairs({ "pick", "toggle" }) do
    local o = hotkeys[n]
    if o then pcall(function() o:disable() end) end
  end
end

local function hkResume()
  for _, n in ipairs({ "pick", "toggle" }) do
    local o = hotkeys[n]
    if o and (n ~= "pick" or enabled) then pcall(function() o:enable() end) end
  end
end

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

-- 三种来源各自单独取，设置面板要分别知道「哪几处有值」「最终在用哪个」
local function envKey()
  local e = trim(os.getenv(CFG.env_key or ""))
  if e and #e > 10 then return e end
  return nil
end

local function fileKey()
  local k = trim(readFile(CFG.key_file))
  if k and #k > 10 then return k end
  return nil
end

local function readKeychain()
  local out, ok = hs.execute("security find-generic-password -s '" .. CFG.keychain_svc .. "' -w 2>/dev/null")
  if not ok then return nil end
  local k = trim(out)
  if k and #k > 10 then return k end
  return nil
end

local function getKey()
  -- 1) 环境变量：适合从 launchd / shell 注入，不落盘
  local env = envKey()
  if env then return env, "env" end

  -- 2) 文件：改完不用重载，每次请求现读
  local k = fileKey()
  if k then return k, "file" end

  -- 3) 钥匙串：security add-generic-password -s hammerspoon-teamorouter -w <KEY>
  local kc = readKeychain()
  if kc then return kc, "keychain" end
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

-- 从接口地址里取出主机名，用于报错和诊断
local function apiHost(url)
  return (tostring(url or CFG.api_url):gsub("^https?://", ""):gsub("/.*$", ""))
end

-- 网络层失败要和人话说清楚：hs.http 在连不上时给的是 status<=0 且 body 为空，
-- 以前会一路走到 hs.json.decode，只在控制台刷一句「Error deserialising JSON」，
-- 用户看到的是「HTTP 0」，完全看不出是 DNS 被污染还是 Key 失效。
local function netFail(status, body, url)
  if (status or 0) > 0 and body and #tostring(body) > 0 then return nil end
  return "网络连不上 " .. apiHost(url) ..
         "（DNS 被污染或连接被重置，请求根本没发出去；不是 Key 或额度的问题）"
end

local function fetchModels(cb)   -- cb(errText, count)
  local key = getKey()
  if not key then return cb("没有 API Key（菜单栏 → 设置…）") end
  local url = (CFG.api_url:gsub("/chat/completions$", "/models"))
  local ok, err = pcall(hs.http.asyncGet, url,
    { ["Authorization"] = "Bearer " .. key },
    function(status, body)
      local nf = netFail(status, body, url)
      if nf then return cb(nf) end
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

-- opt 可在调用时临时指定 key / url：设置面板的「测试连接」要能在保存前
-- 用输入框里还没落盘的 key 试一把，而不用先写文件再测。
local function request(text, systemPrompt, cb, opt)
  opt = opt or {}
  local key = opt.key or getKey()
  if not key then
    cb(nil, "没有 API Key：菜单栏图标 → 设置… 填一个")
    return
  end
  local url = opt.url or CFG.api_url
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

  local okCall, errCall = pcall(hs.http.asyncPost, url, body, headers, function(status, respBody)
    if done then return end
    done = true
    guard:stop()

    local nf = netFail(status, respBody, url)
    if nf then cb(nil, nf); return end

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

-- hs.mouse.getAbsolutePosition 在新版里被标记废弃（每次点击都往控制台刷一行警告），
-- 统一走这个兼容入口：新版用 absolutePosition，老版回退到旧函数。
local function mousePoint()
  if hs.mouse.absolutePosition then
    local ok, p = pcall(hs.mouse.absolutePosition)
    if ok and p then return p end
  end
  return hs.mouse.getAbsolutePosition()
end

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
    local p = mousePoint()
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
    local p = mousePoint()
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
-- 设置面板：在图形界面里填 / 换 / 清 API Key（顺带能改接口地址）
--
-- 视觉和划词面板、模型面板同一套：透明无边框窗口 + 玻璃卡片 + CSS 阴影，
-- 同样是非激活浮层，弹出来不抢当前 App 的焦点。代价是这种窗口收不到键盘
-- （NSWindow 非激活时不给键盘焦点），所以按键和另外两个面板一样走 eventtap
-- 转发：对 Key / URL 这种纯 ASCII 输入足够，⌘V 直接读剪贴板补上。
--------------------------------------------------------------------------
local SET = {
  w = 436,
  pad_top = GLASS.pad_top, pad_bottom = GLASS.pad_bottom, pad_side = GLASS.pad_side,
  card_h = 580,
  wv = nil, uc = nil, keyTap = nil, mouseTap = nil, visible = false,
  rec = nil,   -- 正在录哪一项快捷键（"pick" / "toggle"），nil = 不在录
}

-- 这两个在文件更后面才定义（面板要调它们，所以先声明成 upvalue）
local setHide, openInEditor

function SET.height() return SET.pad_top + SET.card_h + SET.pad_bottom end

-- 任意字符串 → 安全的 shell 单引号参数（key 里出现单引号也不会把命令拆坏）
local function shq(s)
  return "'" .. tostring(s or ""):gsub("'", [['\'']]) .. "'"
end

local function saveKeyToFile(key)
  local dir = CFG.key_file:match("^(.*)/[^/]+$")
  if dir and dir ~= "" then
    hs.execute("mkdir -p " .. shq(dir) .. " && chmod 700 " .. shq(dir))
  end
  local f = io.open(CFG.key_file, "w")
  if not f then return false end
  f:write(key)
  f:close()
  hs.execute("chmod 600 " .. shq(CFG.key_file))
  return true
end

local function saveKeyToKeychain(key)
  -- -U 表示同名条目直接覆盖；security 只从命令行拿密码，没有 stdin 的口子
  local _, ok = hs.execute("security add-generic-password -U -s " .. shq(CFG.keychain_svc) ..
    " -a " .. shq(os.getenv("USER") or "wordwand") .. " -w " .. shq(key) .. " 2>&1")
  return ok and readKeychain() ~= nil
end

-- 清空内容而不是 rm 文件：对 getKey 来说两者等价（空串长度不够），
-- 但清空不会误伤目录里可能存在的其他东西
local function truncateKeyFile()
  local f = io.open(CFG.key_file, "w")
  if f then f:close(); return true end
  return false
end

local function clearKeychain()
  local _, ok = hs.execute("security delete-generic-password -s " .. shq(CFG.keychain_svc) .. " >/dev/null 2>&1")
  return ok
end

-- 面板每次刷新都用这一份状态重建：只给 key 的尾号，完整 key 不进 DOM，
-- 免得被截图或者 webview 调试带出去
local function settingsState(msg, cls)
  local key, src = getKey()
  return {
    url   = CFG.api_url,
    src   = src,
    tail  = key and key:sub(-4) or nil,
    env   = (envKey() ~= nil),
    hk    = { pick = hkLabel(HK.pick), toggle = hkLabel(HK.toggle) },
    rec   = SET.rec,
    model = CFG.model,
    temp  = tostring(CFG.temperature),
    ot    = tostring(CFG.timeout),
    auto  = hs.autoLaunch() and true or false,
    msg   = msg,
    cls   = cls,
  }
end

local CSS_SET = [[
/* 设置项都挤在这一页里，内容超出高度时可以滚，但不显示滚动条 */
.card{overflow-y:auto;overflow-x:hidden}
.card::-webkit-scrollbar{width:0;height:0}
.hd{padding:1px 9px 7px;flex:none}
.hd h1{font-size:13px;font-weight:590;color:#1D1D1F;letter-spacing:-.1px}
.hd p{font-size:11px;color:#8A8F97;margin-top:3px}

/* 分栏：一组选项一张卡片，组内每行之间一条发丝线 */
.grp{margin:0 2px 7px;flex:none;border-radius:10px;overflow:hidden;
 background:rgba(255,255,255,.52);
 box-shadow:inset 0 0 0 .5px rgba(0,0,0,.07),0 .5px 1px rgba(0,0,0,.03)}
.gt{display:flex;align-items:center;font-size:10px;font-weight:600;letter-spacing:.5px;
 color:#9AA0A8;padding:7px 10px 1px}
.gt .mini{margin-left:auto;font-weight:400;letter-spacing:0;font-size:10.5px}
.r{display:flex;align-items:center;gap:8px;padding:5px 10px;min-height:37px}
.r+.r{box-shadow:inset 0 .5px 0 rgba(0,0,0,.07)}
.rl{flex:none;width:58px;font-size:11.5px;color:#3A3D42;letter-spacing:-.1px}

/* 输入框：凹槽样式，和模型面板的搜索框同源 */
.fld{flex:1;min-width:0;height:27px;display:flex;align-items:center;gap:6px;padding:0 8px;
 background:rgba(120,122,128,.11);border-radius:7px;
 box-shadow:inset 0 1px 2px rgba(0,0,0,.05),inset 0 -.5px 0 rgba(255,255,255,.65);
 transition:box-shadow .12s ease}
.fld.on{box-shadow:inset 0 1px 2px rgba(0,0,0,.05),0 0 0 1.5px rgba(10,132,255,.55)}
.fld input{flex:1;min-width:0;border:0;outline:0;background:transparent;font:inherit;
 font-size:12.5px;color:#1D1D1F;letter-spacing:-.1px;pointer-events:none}
.fld input::placeholder{color:#9BA0A8}
.pill{flex:none;font-size:9.5px;font-weight:500;padding:1px 6px;border-radius:5px;
 background:rgba(10,132,255,.13);color:#0A63CC}
.pill.none{background:rgba(255,159,10,.18);color:#8F5500}
.mini{flex:none;font-size:11px;color:#0A84FF;cursor:pointer}

.seg{display:flex;gap:6px;flex:1}
.seg .opt{flex:1;height:24px;display:flex;align-items:center;justify-content:center;
 border-radius:7px;font-size:11px;color:#6E737C;cursor:pointer;
 background:rgba(120,122,128,.10);box-shadow:inset 0 -.5px 0 rgba(255,255,255,.6)}
.seg .opt.on{color:#fff;background:linear-gradient(180deg,#4AA0FF 0%,#0A7EF5 100%);
 box-shadow:inset 0 .5px 0 rgba(255,255,255,.45),0 1px 2.5px rgba(10,110,240,.30)}

/* 快捷键：两块押在同一行里的键帽 */
.hks{display:flex;gap:7px;flex:1}
.hk{flex:1;height:32px;display:flex;flex-direction:column;align-items:center;justify-content:center;
 border-radius:8px;cursor:pointer;background:rgba(120,122,128,.11);
 box-shadow:inset 0 1px 2px rgba(0,0,0,.05),inset 0 -.5px 0 rgba(255,255,255,.65);
 transition:box-shadow .12s ease,background .12s ease}
.hk b{font-size:12px;font-weight:600;color:#1D1D1F;letter-spacing:.6px;line-height:1.15}
.hk span{font-size:9px;color:#8A8F97;margin-top:2px}
.hk.on{background:rgba(10,132,255,.10);box-shadow:inset 0 0 0 1.5px rgba(10,132,255,.55)}
.hk.on b,.hk.on span{color:#0A63CC}

/* 开关：登录自启这类「开/关」比两个按钮更像系统设置 */
.sw{width:36px;height:21px;border-radius:11px;flex:none;position:relative;cursor:pointer;
 background:rgba(120,122,128,.30);transition:background .16s ease}
.sw::after{content:"";position:absolute;top:2px;left:2px;width:17px;height:17px;border-radius:50%;
 background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.28);transition:transform .16s ease}
.sw.on{background:#34C759}
.sw.on::after{transform:translateX(15px)}

.note{font-size:10.5px;line-height:1.4;color:#8A8F97;padding:0 9px;margin-top:1px;flex:none}
.msg{font-size:10.5px;line-height:1.4;color:#8A8F97;padding:0 9px;margin-top:4px;flex:none;
 white-space:pre-wrap;word-break:break-all;overflow:hidden;
 display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2}
.msg.ok{color:#0B7A3C}.msg.err{color:#C0392B}
.btns{display:flex;align-items:center;gap:7px;padding:0 2px 2px;margin-top:auto;flex:none}
.btns .b1{flex:1}
.sp{flex:1}
.grow{flex:1}
button{font-family:inherit;font-size:11.5px;font-weight:500;height:27px;padding:0 12px;
 border:0;border-radius:7px;cursor:pointer;transition:filter .12s ease,background .12s ease}
button:active{filter:brightness(.94)}
.b2{background:rgba(120,122,128,.14);color:#3A3D42;box-shadow:inset 0 -.5px 0 rgba(255,255,255,.5)}
.b2:hover{background:rgba(120,122,128,.20)}
.b1{background:linear-gradient(180deg,#4AA0FF 0%,#0A7EF5 100%);color:#fff;
 box-shadow:inset 0 .5px 0 rgba(255,255,255,.45),0 1px 2.5px rgba(10,110,240,.30)}

/* 页脚：配置文件相关两个动作 */
.foot{display:flex;align-items:center;justify-content:center;gap:7px;flex:none;
 font-size:10.5px;color:#9BA0A8;padding:6px 0 1px}
.lk{color:#0A84FF;cursor:pointer}
.lk:hover{text-decoration:underline}

@media (prefers-color-scheme: dark){
 .hd h1{color:#F2F3F5}
 .hd p,.gt,.rl,.note,.msg,.foot{color:#8E939B}
 .rl{color:#E8E9EB}
 .grp{background:rgba(255,255,255,.05);
  box-shadow:inset 0 0 0 .5px rgba(255,255,255,.09),0 .5px 1px rgba(0,0,0,.2)}
 .r+.r{box-shadow:inset 0 .5px 0 rgba(255,255,255,.07)}
 .fld{background:rgba(120,122,128,.24);
  box-shadow:inset 0 1px 2px rgba(0,0,0,.28),inset 0 -.5px 0 rgba(255,255,255,.08)}
 .fld.on{box-shadow:inset 0 1px 2px rgba(0,0,0,.28),0 0 0 1.5px rgba(10,132,255,.65)}
 .fld input{color:#F2F3F5}
 .pill{background:rgba(10,132,255,.22);color:#7FB9FF}
 .pill.none{background:rgba(255,159,10,.20);color:#F0B04C}
 .seg .opt{background:rgba(120,122,128,.24);color:#9BA0A8;box-shadow:none}
 .hk{background:rgba(120,122,128,.24);
  box-shadow:inset 0 1px 2px rgba(0,0,0,.28),inset 0 -.5px 0 rgba(255,255,255,.08)}
 .hk b{color:#F2F3F5}
 .hk.on{background:rgba(10,132,255,.18);box-shadow:inset 0 0 0 1.5px rgba(10,132,255,.65)}
 .hk.on b,.hk.on span{color:#7FB9FF}
 .sw{background:rgba(120,122,128,.42)}
 .b2{background:rgba(120,122,128,.24);color:#E8E9EB;box-shadow:none}
 .b2:hover{background:rgba(120,122,128,.32)}
}
]]

local SET_BODY = [[
<div class="card">
  <div class="hd">
    <h1>WordWand 设置</h1>
    <p>Key 只存在本机，请求时现读，不写进配置文件。</p>
  </div>

  <div class="grp">
    <div class="gt">接口</div>
    <div class="r">
      <span class="rl">地址</span>
      <div class="fld" id="f0"><input id="url" spellcheck="false" autocomplete="off"></div>
    </div>
    <div class="r">
      <span class="rl">Key</span>
      <div class="fld" id="f1">
        <input id="key" type="password" spellcheck="false" autocomplete="off">
        <span class="mini" id="eye">显示</span>
      </div>
      <span class="pill" id="src"></span>
    </div>
    <div class="r">
      <span class="rl">保存到</span>
      <div class="seg" id="seg">
        <div class="opt on" data-v="file">secrets 文件（600）</div>
        <div class="opt" data-v="keychain">系统钥匙串</div>
      </div>
    </div>
    <div class="r">
      <span class="rl"></span>
      <button class="b2 grow" id="clear">清除 Key</button>
      <button class="b2 grow" id="test">测试连接</button>
    </div>
  </div>

  <div class="grp">
    <div class="gt">快捷键<span class="mini" id="hkreset">恢复默认</span></div>
    <div class="r">
      <div class="hks">
        <div class="hk" id="hk0"><b>⌃⌥R</b><span>划词改写</span></div>
        <div class="hk" id="hk1"><b>⌃⌥X</b><span>暂停 / 启用</span></div>
      </div>
    </div>
  </div>

  <div class="grp">
    <div class="gt">生成</div>
    <div class="r">
      <span class="rl">模型</span>
      <div class="fld" id="f3"><input id="mdl" readonly spellcheck="false"></div>
      <span class="mini" id="mdlgo">选择…</span>
    </div>
    <div class="r">
      <span class="rl">温度</span>
      <div class="seg" id="segT">
        <div class="opt" data-v="0">严谨 0</div>
        <div class="opt" data-v="0.3">标准 0.3</div>
        <div class="opt" data-v="0.7">发散 0.7</div>
      </div>
    </div>
    <div class="r">
      <span class="rl">超时</span>
      <div class="seg" id="segO">
        <div class="opt" data-v="30">30s</div>
        <div class="opt" data-v="60">60s</div>
        <div class="opt" data-v="120">120s</div>
      </div>
    </div>
  </div>

  <div class="grp">
    <div class="gt">通用</div>
    <div class="r">
      <span class="rl">登录自启</span>
      <span class="sp"></span>
      <span class="sw" id="auto"></span>
    </div>
  </div>

  <div class="note" id="note"></div>
  <div class="msg" id="msg"></div>

  <div class="btns">
    <button class="b1" id="save">保存</button>
  </div>

  <div class="foot">
    <span class="lk" id="openfile">打开配置文件</span>
    <span>·</span>
    <span class="lk" id="reload">重新加载</span>
  </div>
</div>
]]

local SET_JS = [[
<script>
var S = __STATE__, ENVNAME = __ENV__, A = 1;   /* A = 当前编辑的字段：0 地址 / 1 Key */
function $(i){ return document.getElementById(i); }
function flds(){ return [$('url'), $('key')]; }
function ring(){
  $('f0').classList.toggle('on', A === 0);
  $('f1').classList.toggle('on', A === 1);
}
function ins(t){
  var el = flds()[A];
  el.value = el.value + t;
  el.scrollLeft = el.scrollWidth;
}
function del(){
  var el = flds()[A];
  el.value = el.value.slice(0, -1);
  el.scrollLeft = el.scrollWidth;
}
function clearField(){ flds()[A].value = ''; }
function nextField(){ A = 1 - A; ring(); }
function pick(i){ A = i; ring(); }
function store(){
  var o = $('seg').querySelector('.opt.on');   /* 页面上不止一个分段控件，必须限定范围 */
  return o ? o.getAttribute('data-v') : 'file';
}
function msg(t, c){ var m = $('msg'); m.textContent = t || ''; m.className = 'msg' + (c ? ' ' + c : ''); }
function send(o){ window.webkit.messageHandlers.settings.postMessage(JSON.stringify(o)); }
/* 快捷键两块键帽：录音时变蓝并清空显示，等 Lua 那边把新组合键回推过来 */
var REC = null, CHIPS = [];
CHIPS.push({ id: 'hk0', key: 'pick',   role: '划词改写' });
CHIPS.push({ id: 'hk1', key: 'toggle', role: '暂停 / 启用' });
function hkPaint(){
  REC = S.rec || null;
  for (var i = 0; i < CHIPS.length; i++) {
    var c = CHIPS[i], el = $(c.id), on = (REC === c.key);
    el.classList.toggle('on', on);
    el.querySelector('b').textContent = on ? '按下新组合键' : ((S.hk && S.hk[c.key]) || '—');
    el.querySelector('span').textContent = on ? 'esc 取消' : c.role;
  }
}
function hkState(o){
  S.hk = o.hk; S.rec = o.rec || null;
  hkPaint();
  if (o.msg) msg(o.msg, o.cls);
}
function hkMsg(t){ msg(t, 'err'); }
function rec(k){ send({ act:'rec', which:k }); }
/* 分段控件：温度 / 超时这类立刻生效的设置，点完不用再按保存 */
function segOn(id, v){
  var c = $(id).children;
  for (var i = 0; i < c.length; i++) {
    c[i].classList.toggle('on', c[i].getAttribute('data-v') === String(v));
  }
}
function segPick(id, act){
  $(id).addEventListener('mousedown', function(e){
    var o = e.target.closest ? e.target.closest('.opt') : null;
    if (!o) return;
    segOn(id, o.getAttribute('data-v'));
    send({ act: act, v: o.getAttribute('data-v') });
  });
}
/* Lua 改完某一项只回推这一项，不整页重绘——否则会把还没保存的 Key 冲掉 */
function quick(o){
  if (o.auto !== undefined) $('auto').classList.toggle('on', !!o.auto);
  if (o.temp !== undefined) segOn('segT', o.temp);
  if (o.ot !== undefined) segOn('segO', o.ot);
  if (o.model) $('mdl').value = o.model;
  if (o.msg !== undefined) msg(o.msg, o.cls);
}
function save(){ send({ act:'save', url:$('url').value.trim(), key:$('key').value.trim(), store:store() }); }
function test(){ send({ act:'test', url:$('url').value.trim(), key:$('key').value.trim() }); }
function paint(){
  $('url').value = S.url || '';
  $('key').value = '';
  $('key').placeholder = S.tail ? ('已保存 ····' + S.tail) : '⌘V 粘贴 API Key';
  var p = $('src');
  if (S.src) { p.textContent = '生效来源 ' + S.src; p.className = 'pill'; }
  else { p.textContent = '未配置'; p.className = 'pill none'; }
  var n = $('note');
  if (S.env) {
    n.textContent = '环境变量 ' + ENVNAME + ' 优先级最高，这里保存的不会生效（需先 launchctl unsetenv）';
    n.style.color = '#8F5500';
  } else {
    n.textContent = 'Key 留空不改动 · 取值顺序 环境变量 → 文件 → 钥匙串';
    n.style.color = '';
  }
  if (S.msg) msg(S.msg, S.cls);
  $('mdl').value = S.model || '';
  segOn('segT', S.temp);
  segOn('segO', S.ot);
  $('auto').classList.toggle('on', !!S.auto);
  ring(); hkPaint();
}
$('f0').addEventListener('mousedown', function(){ pick(0); });
$('f1').addEventListener('mousedown', function(){ pick(1); });
$('eye').addEventListener('mousedown', function(e){
  e.stopPropagation();
  var k = $('key'), on = (k.type === 'password');
  k.type = on ? 'text' : 'password';
  this.textContent = on ? '隐藏' : '显示';
});
$('seg').addEventListener('mousedown', function(e){
  var o = e.target.closest ? e.target.closest('.opt') : null;
  if (!o) return;
  [].forEach.call(this.children, function(c){ c.classList.remove('on'); });
  o.classList.add('on');
});
$('save').addEventListener('click', function(){ save(); });
$('test').addEventListener('click', function(){ test(); });
$('clear').addEventListener('click', function(){ msg('', ''); send({ act:'clear' }); });
CHIPS.forEach(function(c){
  $(c.id).addEventListener('mousedown', function(){ if (!REC) rec(c.key); });
});
$('hkreset').addEventListener('mousedown', function(){ if (!REC) send({ act:'hkreset' }); });
segPick('segT', 'temp');
segPick('segO', 'ot');
$('auto').addEventListener('mousedown', function(){
  var on = !this.classList.contains('on');
  this.classList.toggle('on', on);
  send({ act:'auto', v: on ? '1' : '0' });
});
$('mdlgo').addEventListener('mousedown', function(){ send({ act:'model' }); });
$('f3').addEventListener('mousedown', function(){ send({ act:'model' }); });
$('openfile').addEventListener('mousedown', function(){ send({ act:'open' }); });
$('reload').addEventListener('mousedown', function(){ send({ act:'reload' }); });
function apply(st){ S = st; paint(); }
paint();
</script>
]]

local function buildSettingsHTML()
  local js = SET_JS
    :gsub("__STATE__", function() return hs.json.encode(settingsState()) end)
    :gsub("__ENV__",   function() return jsonStr(CFG.env_key or "WORDWAND_API_KEY") end)
  return page(CSS_SET, SET_BODY .. js)
end

local function setJS(code)
  if SET.wv then pcall(function() SET.wv:evaluateJavaScript(code) end) end
end

local function settingsReply(msg, cls)
  if not SET.wv then return end
  setJS("apply(" .. hs.json.encode(settingsState(msg, cls)) .. ")")
end

-- 只回推改动的那一项：整页重绘会把没保存的 Key 输入框清空
local function settingsQuick(t)
  if not SET.wv then return end
  setJS("quick(" .. hs.json.encode(t) .. ")")
end

local function settingsSave(d)
  local notes = {}

  -- 接口地址：换了就落盘，并把模型缓存作废（旧列表是另一个网关的）
  local url = trim(d.url or "")
  if url ~= "" and url ~= CFG.api_url then
    if not url:match("^https?://") then
      return settingsReply("接口地址要以 http:// 或 https:// 开头", "err")
    end
    CFG.api_url = url
    hs.settings.set("apiUrl", url)
    models = {}
    saveModelsCache({})
    notes[#notes + 1] = "接口地址已更新"
  end

  local key = trim(d.key or "")
  local store = (d.store == "keychain") and "keychain" or "file"
  if key ~= "" then
    if #key <= 10 then
      return settingsReply("Key 太短了，看着像没粘全（至少要 11 个字符）", "err")
    end
    if store == "keychain" then
      if not saveKeyToKeychain(key) then
        return settingsReply("写入系统钥匙串失败（可能是钥匙串被锁）", "err")
      end
      -- 文件优先级高于钥匙串：文件里还留着旧 key 的话，存到钥匙串也不会生效
      if fileKey() then
        truncateKeyFile()
        notes[#notes + 1] = "已清空 secrets 文件里的旧 key（文件优先级高于钥匙串）"
      end
      notes[#notes + 1] = "Key 已存入系统钥匙串"
    else
      if not saveKeyToFile(key) then
        return settingsReply("写不进 " .. CFG.key_file, "err")
      end
      notes[#notes + 1] = "Key 已写入 secrets 文件（600）"
    end
  elseif #notes == 0 then
    return settingsReply("没有改动：Key 留空表示保持原样", "")
  end

  if envKey() then
    notes[#notes + 1] = "但环境变量 " .. CFG.env_key .. " 优先级更高，实际生效的是它"
  end

  settingsReply(table.concat(notes, "；"), "ok")

  -- Key 现在能用了，顺手把还没拉到的模型列表补上
  if getKey() and #models == 0 then
    hs.timer.doAfter(0.2, function() refreshModels(false) end)
  end
end

local function settingsTest(d)
  local key = trim(d.key or "")
  local url = trim(d.url or "")
  if key == "" then key = nil end           -- 留空 = 用已经保存的那把
  if url == "" then url = nil end
  if not (key or getKey()) then
    return settingsReply("还没有 Key，先填一个再测", "err")
  end
  settingsReply("正在请求接口…", "")
  request("你好", "只回复两个字：可用", function(res, err)
    if err then
      settingsReply("连接失败：" .. tostring(err), "err")
    else
      settingsReply("连接正常，模型回了：" .. tostring(res), "ok")
    end
  end, { key = key, url = url })
end

local function settingsClear()
  local notes = {}
  if truncateKeyFile() then notes[#notes + 1] = "已清空 secrets 文件" end
  if clearKeychain() then notes[#notes + 1] = "已删除钥匙串条目" end
  if envKey() then
    notes[#notes + 1] = "环境变量 " .. CFG.env_key .. " 还在，它优先级最高，仍然会被使用"
  end
  settingsReply(#notes > 0 and table.concat(notes, "；") or "本来就没有可清的 Key", "ok")
end

-- 快捷键录制：面板本身就是非激活浮层、键盘已经走 eventtap，所以不用另开 tap，
-- 只把 SET.rec 挂上，下一个非修饰键连同当时的修饰键就当作新组合键。
local HK_ROLE = { pick = "划词改写", toggle = "暂停 / 启用" }

local function settingsHkPush(msg, cls)
  if not SET.wv then return end
  setJS("hkState(" .. hs.json.encode({
    hk  = { pick = hkLabel(HK.pick), toggle = hkLabel(HK.toggle) },
    rec = SET.rec,
    msg = msg,
    cls = cls,
  }) .. ")")
end

local function settingsRecordStop(h)
  local which = SET.rec
  SET.rec = nil
  hkResume()
  if not which then return end
  if not h then                                   -- esc 取消，保持原样
    settingsHkPush("已取消，快捷键没变", "")
    return
  end
  local other = (which == "pick") and "toggle" or "pick"
  if hkSame(h, HK[other]) then
    settingsHkPush(hkLabel(h) .. " 已经给了「" .. HK_ROLE[other] .. "」，换一个组合", "err")
    return
  end
  local old = HK[which]
  hkSave(which, h)
  local ok, err = hkApply()
  if not ok then                                  -- 绑不上就退回原来那组，别留个半残状态
    hkSave(which, old)
    hkApply()
    settingsHkPush(tostring(err), "err")
    return
  end
  settingsHkPush(HK_ROLE[which] .. " 已改为 " .. hkLabel(HK[which]), "ok")
end

local function settingsRecord(which)
  if which ~= "pick" and which ~= "toggle" then return end
  if SET.rec == which then return end
  SET.rec = which
  hkSuspend()          -- 录音期间先摘掉全局快捷键，否则按 ⌃⌥X 会直接切暂停
  settingsHkPush(nil, nil)
end

local function settingsHkReset()
  SET.rec = nil
  hkSave("pick",   { mods = { "ctrl", "alt" }, key = "R" })
  hkSave("toggle", { mods = { "ctrl", "alt" }, key = "X" })
  local ok, err = hkApply()
  if ok then
    settingsHkPush("已恢复默认：" .. hkLabel(HK.pick) .. " / " .. hkLabel(HK.toggle), "ok")
  else
    settingsHkPush(tostring(err), "err")
  end
end

local function settingsHandle(body)
  local d = body
  if type(d) ~= "table" then
    local ok, dec = pcall(hs.json.decode, tostring(body))
    d = (ok and type(dec) == "table") and dec or nil
  end
  if not d then return end

  local act = d.act
  if act == "close" then
    SET.rec = nil
    hkResume()
    local wv = SET.wv
    SET.wv, SET.uc = nil, nil
    if wv then pcall(function() wv:close() end) end
  elseif act == "save" then
    settingsSave(d)
  elseif act == "test" then
    settingsTest(d)
  elseif act == "clear" then
    settingsClear()
  elseif act == "rec" then
    settingsRecord(d.which)
  elseif act == "hkreset" then
    settingsHkReset()
  elseif act == "temp" then
    local v = tonumber(d.v)
    if v then
      CFG.temperature = v
      hs.settings.set("temperature", tostring(v))
      settingsQuick({ temp = tostring(v), msg = "温度 " .. tostring(v) .. "，下次改写生效", cls = "ok" })
    end
  elseif act == "ot" then
    local v = tonumber(d.v)
    if v then
      CFG.timeout = v
      hs.settings.set("timeout", tostring(v))
      settingsQuick({ ot = tostring(v), msg = "超时 " .. tostring(v) .. "s", cls = "ok" })
    end
  elseif act == "auto" then
    local on = (d.v == "1")
    hs.settings.set("autoLaunch", on)
    hs.autoLaunch(on)
    settingsQuick({ auto = on, msg = on and "登录时会自动启动" or "已取消登录自启", cls = "ok" })
  elseif act == "model" then
    -- 模型选择用自己那个带搜索的面板，先把设置关掉，免得两个浮层叠着
    setHide()
    hs.timer.doAfter(0.25, function() pickModel() end)
  elseif act == "open" then
    setHide()
    hs.timer.doAfter(0.2, function()
      local ok, app = openInEditor(HOME .. "/.hammerspoon/init.lua")
      if not ok then
        toast("打不开编辑器，已在 Finder 里显示", 3)
      elseif app then
        toast("已用 " .. app .. " 打开（.lua 没有默认程序）", 2.5)
      end
    end)
  elseif act == "reload" then
    setHide()
    hs.timer.doAfter(0.2, function() hs.reload() end)
  end
end

--------------------------------------------------------------------------
local function setStopWatchers()
  if SET.keyTap then SET.keyTap:stop(); SET.keyTap = nil end
  if SET.mouseTap then SET.mouseTap:stop(); SET.mouseTap = nil end
end

function setHide()
  -- 面板关掉时如果还在等按键，就当取消处理，否则全局快捷键会一直处于摘除状态
  if SET.rec then SET.rec = nil; hkResume() end
  setStopWatchers()
  if SET.wv then pcall(function() SET.wv:hide() end) end
  SET.visible = false
end

-- 非激活浮层收不到键盘，按键按面板自己的规矩转成动作：
-- 可打印字符追加、⌫ 退格、Tab 切字段、⌘A 清空、⌘V 粘贴、⏎ 保存、esc 关
local function setStartWatchers()
  SET.keyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    local kc = e:getKeyCode()
    local f = e:getFlags()

    ----------------------------------------------------------------------
    -- 录音态：这一次按键就是新的组合键。只按修饰键不算数（等真正那个键），
    -- esc 退出，没有 ⌃⌥⇧⌘ 的裸键也不收——否则会抢走全局字母键。
    ----------------------------------------------------------------------
    if SET.rec then
      if MOD_ONLY[kc] then return true end
      if kc == 53 and not (f.ctrl or f.alt or f.cmd or f.shift) then
        settingsRecordStop(nil)
        return true
      end
      local mods = {}
      if f.ctrl  then mods[#mods + 1] = "ctrl" end
      if f.alt   then mods[#mods + 1] = "alt" end
      if f.shift then mods[#mods + 1] = "shift" end
      if f.cmd   then mods[#mods + 1] = "cmd" end
      local key = hs.keycodes.map[kc]
      if not key then
        setJS("hkMsg(" .. jsonStr("这个键不认识，换一个") .. ")")
        return true
      end
      if #mods == 0 then
        setJS("hkMsg(" .. jsonStr("至少要有 ⌃ ⌥ ⇧ ⌘ 里的一个") .. ")")
        return true
      end
      settingsRecordStop({ mods = mods, key = key })
      return true
    end

    if f.cmd then
      if kc == 9 then                                     -- ⌘V
        local clip = hs.pasteboard.getContents()
        if type(clip) == "string" and #clip > 0 then
          setJS("ins(" .. jsonStr((clip:gsub("[\r\n]+", ""))) .. ")")
        end
        return true
      end
      if kc == 0 then setJS("clearField()"); return true end   -- ⌘A
      if kc == 1 then setJS("save()"); return true end         -- ⌘S
      if kc == 36 or kc == 76 then setJS("test()"); return true end
      return false
    end
    if f.ctrl or f.alt then return false end

    if kc == 53 then setHide(); return true end             -- esc
    if kc == 48 then setJS("nextField()"); return true end  -- Tab
    if kc == 51 then setJS("del()"); return true end        -- ⌫
    if kc == 36 or kc == 76 then setJS("save()"); return true end

    local ch = e:getCharacters()
    if ch and #ch > 0 and ch:byte() >= 32 then
      setJS("ins(" .. jsonStr(ch) .. ")")
      return true
    end
    return true
  end)
  SET.keyTap:start()

  SET.mouseTap = hs.eventtap.new({ hs.eventtap.event.types.leftMouseDown }, function()
    if not SET.wv then return false end
    local ok, fr = pcall(function() return SET.wv:frame() end)
    if not ok or not fr then return false end
    -- 和另外两个面板一样：只有卡片本身算「里面」，四周透明留白点一下就关
    local left   = fr.x + SET.pad_side
    local right  = fr.x + fr.w - SET.pad_side
    local bottom = fr.y + SET.pad_bottom
    local top    = fr.y + fr.h - SET.pad_top
    local p = mousePoint()
    if not (p.x >= left and p.x <= right and p.y >= bottom and p.y <= top) then
      setHide()
    end
    return false
  end)
  SET.mouseTap:start()
end

local function openSettings()
  if SET.wv then
    SET.visible = true
    pcall(function() SET.wv:show() end)
    setStartWatchers()
    return
  end

  local okAll, err = pcall(function()
    local uc = hs.webview.usercontent.new("settings")
    uc:setCallback(function(m) settingsHandle(m.body) end)

    local screen = hs.screen.mainScreen():frame()
    local x = math.floor(screen.x + (screen.w - SET.w) / 2)
    -- 面板比以前高，20% 的起始位置在小屏上可能顶出屏幕底边，这里夹一下
    local y = math.floor(math.min(screen.y + screen.h * 0.20,
                                  screen.y + screen.h - SET.height() - 24))
    local wv = hs.webview.new({ x = x, y = y, w = SET.w, h = SET.height() }, {}, uc)

    -- 与 POP / MPICK 完全一致的四件套：无边框浮层 + 置顶 + 透明 + 自绘阴影
    pcall(function() wv:windowStyle({ "borderless", "nonactivatingpanel" }) end)
    pcall(function() wv:level(8) end)
    pcall(function() wv:transparent(true) end)
    pcall(function() wv:shadow(false) end)
    pcall(function() wv:closeOnEscape(false) end)

    wv:html(buildSettingsHTML())
    SET.wv, SET.uc = wv, uc
    SET.visible = true
    wv:show()
  end)

  if not okAll then
    print("settings panel failed: " .. tostring(err))
    -- 兜底：webview 起不来时退回系统输入框，至少能填进去
    local btn, input
    local okDlg = pcall(function()
      btn, input = hs.dialog.textPrompt("WordWand · API Key",
        "粘贴 Key 后点「保存」，会写入 " .. CFG.key_file, "", "保存", "取消", true)
    end)
    if not okDlg then
      btn, input = hs.dialog.textPrompt("WordWand · API Key",
        "粘贴 Key 后点「保存」", "", "保存", "取消")
    end
    if btn == "保存" then
      local k = trim(input or "")
      if k and #k > 10 and saveKeyToFile(k) then
        toast("Key 已保存", 1.5)
        hs.timer.doAfter(0.3, function() refreshModels(false) end)
      elseif k and k ~= "" then
        toast("Key 太短，没保存", 2)
      end
    end
    return
  end

  setStartWatchers()
end

--------------------------------------------------------------------------

local function runMode(mode)
  local app = hs.application.frontmostApplication()
  readSelection(function(raw)
    local text = trim(raw)
    if not text or text == "" then
      toast("先选中一段文字再按 " .. hkLabel(HK.pick), 1.8)
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
      toast("先选中一段文字再按 " .. hkLabel(HK.pick), 1.8)
      return
    end
    showPopup(function(mode)
      if not mode then return end
      execute(mode, text, app)
    end)
  end)
end

-- 网络诊断：把「是网不通还是 Key 不对」一次问清楚。
-- 用 hs.task 异步跑，避免阻塞主线程（快捷键在诊断期间仍然可用）。
local function netDiag()
  showProgress("诊断中…")
  local host = apiHost(CFG.api_url)
  local cmd = "dig +short " .. host .. " A | head -1; " ..
              "curl -s -o /dev/null -w '%{http_code}' --max-time 8 " ..
              "https://" .. host .. "/v1/models"
  local t = hs.task.new("/bin/sh", function(a, b, c)
    local out = (type(b) == "string") and b or c or ""
    local lines = {}
    for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
    local dns  = (lines[1] or ""):match("%d+%.%d+%.%d+%.%d+") or "无记录"
    local code = (lines[#lines] or ""):match("%d%d%d") or "000"
    hideProgress()
    local msg
    if code == "401" then
      msg = "网络正常，服务端有响应（401 = Key 没带上或无效）"
    elseif code == "200" then
      msg = "网络正常，接口通"
    elseif code == "000" then
      msg = "连不上 " .. host .. "｜解析到 " .. dns .. "｜被挡了，需要代理"
    else
      msg = host .. " 返回 " .. code .. "｜解析到 " .. dns
    end
    toast(msg, 8)
    print("[netDiag] " .. msg .. "｜curl=" .. code .. "｜dns=" .. dns)
  end, { "-c", cmd })
  t:start()
end

-- ⌃⌥X：只停划词快捷键，暂停键本身要一直可用，否则就没法再打开了
local function toggleEnabled()
  enabled = not enabled
  if hotkeys.pick then
    if enabled then pcall(function() hotkeys.pick:enable() end)
    else pcall(function() hotkeys.pick:disable() end) end
  end
  toast(enabled and "已启用" or "已暂停", 1.5)
end

-- 绑定 / 换绑：先 delete 再 bind。组合键非法时 bind 会抛错，把错误交回去，
-- 由调用方决定要不要回滚（设置面板就靠这个回滚，避免留个半残状态）。
hkApply = function()
  for _, n in ipairs({ "pick", "toggle" }) do
    local o = hotkeys[n]
    if o then pcall(function() o:delete() end) end
    hotkeys[n] = nil
  end

  local errs = {}
  local ok1, e1 = pcall(function()
    hotkeys.pick = hs.hotkey.bind(HK.pick.mods, HK.pick.key, pick)
  end)
  if not ok1 then
    errs[#errs + 1] = "划词快捷键 " .. hkLabel(HK.pick) .. " 绑不上：" .. tostring(e1)
  end

  local ok2, e2 = pcall(function()
    hotkeys.toggle = hs.hotkey.bind(HK.toggle.mods, HK.toggle.key, toggleEnabled)
  end)
  if not ok2 then
    errs[#errs + 1] = "暂停快捷键 " .. hkLabel(HK.toggle) .. " 绑不上：" .. tostring(e2)
  end

  -- 处于暂停状态时重绑，仍然只放行暂停键
  if hotkeys.pick and not enabled then pcall(function() hotkeys.pick:disable() end) end
  -- 菜单栏的提示文字跟着新组合键走
  local m = _G.hsRewriteMenu
  if m then pcall(function() m:setTooltip("划词改写 · " .. hkLabel(HK.pick)) end) end
  return #errs == 0, table.concat(errs, "；")
end

hkApply()

--------------------------------------------------------------------------
-- 打开配置文件
--
-- .lua 在 macOS 上没有默认关联，`open file.lua` 会直接返回
-- kLSApplicationNotFoundErr（这台机器就是），菜单点下去毫无反应。
-- 所以按「系统默认程序 → 常见编辑器 → 文本编辑」逐级兜底，最后退回 Finder。
--------------------------------------------------------------------------
local EDITORS = {
  "Visual Studio Code", "Cursor", "Sublime Text", "Zed", "Nova",
  "BBEdit", "TextMate", "CotEditor", "MacVim",
}

function openInEditor(path)
  local _, ok = hs.execute("open " .. shq(path) .. " 2>&1")
  if ok then return true, nil end

  for _, app in ipairs(EDITORS) do
    local _, has = hs.execute("open -Ra " .. shq(app) .. " 2>/dev/null")
    if has then
      local _, ok2 = hs.execute("open -a " .. shq(app) .. " " .. shq(path) .. " 2>&1")
      if ok2 then return true, app end
    end
  end

  local _, ok3 = hs.execute("open -a TextEdit " .. shq(path) .. " 2>&1")
  if ok3 then return true, "TextEdit" end

  hs.execute("open -R " .. shq(path) .. " 2>&1")   -- 最差也在 Finder 里把人送过去
  return false, nil
end

local menu = hs.menubar.new()
_G.hsRewriteMenu = menu
if menu then
  pcall(function() menu:setIcon(CFG.icon, true) end)
  menu:setTooltip("划词改写 · " .. hkLabel(HK.pick))
  menu:setMenu(function()
    local items = {}

    items[#items + 1] = {
      title = hkLabel(HK.pick) .. "  选择处理方式…",
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

    -- 设置项统一收进设置面板，菜单里只留这一个入口：
    -- 接口 / Key / 快捷键 / 模型 / 温度 / 超时 / 自启 / 配置文件，都在那一页里。
    -- 暂停快捷键也只留热键（⌃⌥X），不在菜单里占一行。
    items[#items + 1] = { title = "-" }
    items[#items + 1] = {
      title = "设置…",
      fn = function() hs.timer.doAfter(0.15, openSettings) end,
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
--   hsRewritePreview()                 预览划词面板
--   hsRewritePickModel()               打开模型选择面板
--   hsRewriteSettings()                打开设置面板
--   hsRewriteSettingsHTML()            导出设置页 HTML（查排版用）
--   hsRewriteSettingsAct{act=…}        给设置面板发一条消息，等价于点一下
--   hsRewriteHotkeys()                 当前快捷键
--   hsRewriteHotkeySet("pick", {"ctrl","alt"}, "K")   直接设快捷键（走同一套校验）
--   hsRewriteResetHotkeys()            快捷键复位到 ⌃⌥R / ⌃⌥X
--   hsRewriteMenu                      菜单栏对象
_G.hsRewritePickModel = pickModel
_G.hsRewriteNetDiag = netDiag
_G.hsRewriteSettings = openSettings
_G.hsRewriteSettingsHTML = buildSettingsHTML
-- 直接给面板发一条消息，等价于在界面上点了一下（调试用）
_G.hsRewriteSettingsAct = function(t) settingsHandle(t) end
_G.hsRewriteHotkeys = function()
  return { pick = hkLabel(HK.pick), toggle = hkLabel(HK.toggle), enabled = enabled }
end
_G.hsRewriteResetHotkeys = function()
  hs.settings.set("hotkey:pick", nil)
  hs.settings.set("hotkey:toggle", nil)
  HK.pick   = { mods = { "ctrl", "alt" }, key = "R" }
  HK.toggle = { mods = { "ctrl", "alt" }, key = "X" }
  local ok, err = hkApply()
  return ok and "已恢复默认" or tostring(err)
end
-- 录音态是面板内部的，留个口子方便脚本化验证
_G.hsRewriteHotkeyRecord = function(which) settingsRecord(which) end
-- 不经键盘直接设快捷键（走和录音同一条校验/回滚路径）：
--   hsRewriteHotkeySet("pick", {"ctrl","alt"}, "K")
_G.hsRewriteHotkeySet = function(which, mods, key)
  if type(mods) ~= "table" or type(key) ~= "string" then
    return "用法：hsRewriteHotkeySet('pick', {'ctrl','alt'}, 'K')"
  end
  if which ~= "pick" and which ~= "toggle" then
    return "第一个参数只能是 pick 或 toggle"
  end
  SET.rec = which
  settingsRecordStop({ mods = mods, key = key })
  return hkLabel(HK[which])
end
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
print(string.format("WordWand 已就绪 · 模型 %s（列表 %d 个）· %s 弹面板 · API Key %s",
  CFG.model, #modelList(), hkLabel(HK.pick),
  k1 and ("已配置(" .. tostring(s1) .. ")")
     or ("未配置 → 写入 " .. CFG.key_file .. " 或设置环境变量 " .. CFG.env_key)))
