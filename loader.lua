--[[
    KYRO OPTIMIZER | loader.lua  (v2.0)  -- Steal an Egg edition

    What this script is:
      * A client-side UI with visual/performance toggles (FPS Boost, Low/High Graphics,
        3D-rendering overlay) and an Egg-pickup "Anti-Hit" activation sequence.

    What it is NOT (read this):
      * The 3D overlay is a black frame drawn on top of the game. Roblox gives scripts no API
        to stop GPU rendering, so the GPU keeps rendering behind it.
      * The Anti-Hit sequence is a VISUAL INDICATOR. Monster damage / hit detection is decided
        by the game's server. A client script cannot make a player invulnerable, and this one
        does not try to. Do not rely on it as protection.
      * FPS gains depend on the device and the game. Nothing here guarantees higher FPS.

    Re-running the script is safe: the previous instance is cleaned up first.
]]

------------------------------------------------------------------------------------------
-- CONFIG
------------------------------------------------------------------------------------------
local CONFIG = {
    VERSION = "2.0",

    -- Kyro logo. Provide ONE of these (checked in this order):
    LOGO_ASSET_ID = "",           -- 1) uploaded image: "rbxassetid://123456789" (or just the number)
    LOGO_FILE     = "kyro_logo.png", -- 2) file in the executor's workspace folder (needs getcustomasset)
    LOGO_URL      = "",           -- 3) direct raw URL of kyro_logo.png; downloaded once into LOGO_FILE

    -- Anti-Hit activation
    ANTIHIT_DURATION    = 3.0,    -- total animation time in seconds
    PICKUP_TIMEOUT      = 8,      -- seconds to wait for the Egg Tool after pressing the prompt
    ALSO_WATCH_BACKPACK = false,  -- true if the game puts the Egg in the Backpack instead of the Character

    -- Flexible name matching (lowercase substrings)
    STEAL_WORDS   = { "steal", "stolen", "curi" },
    ACTION_WORDS  = { "grab", "take", "pick", "claim", "ambil" },
    EGG_WORDS     = { "egg", "telur", "huevo" },
    -- true: only prompts that look like "steal egg" arm the sequence.
    -- false: ANY prompt arms it (like the Virex reference); the new Egg Tool is then the only check.
    REQUIRE_STEAL_PROMPT = true,
    EXCLUDE_WORDS = { "sell", "buy", "hatch", "place", "shop", "purchase" },

    DEBUG = false,
}

------------------------------------------------------------------------------------------
-- SERVICES
------------------------------------------------------------------------------------------
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
while not player do
    task.wait()
    player = Players.LocalPlayer
end
local playerGui = player:WaitForChild("PlayerGui")

------------------------------------------------------------------------------------------
-- UTILS
------------------------------------------------------------------------------------------
local function dbg(...)
    if CONFIG.DEBUG then
        print("[Kyro]", ...)
    end
end

-- Janitor: tracks connections / instances / functions and cleans them in reverse order.
local Janitor = {}
Janitor.__index = Janitor

function Janitor.new()
    return setmetatable({ items = {} }, Janitor)
end

function Janitor:Add(item)
    table.insert(self.items, item)
    return item
end

function Janitor:Cleanup()
    local items = self.items
    self.items = {}
    for i = #items, 1, -1 do
        local item = items[i]
        local kind = typeof(item)
        if kind == "RBXScriptConnection" then
            pcall(function() item:Disconnect() end)
        elseif kind == "Instance" then
            pcall(function() item:Destroy() end)
        elseif kind == "function" then
            pcall(item)
        end
    end
end

-- Global environment table used to find/stop a previous run of this script.
local env = _G
do
    local ok, genv = pcall(function() return getgenv() end)
    if ok and type(genv) == "table" then
        env = genv
    end
end
if type(env.KyroOptimizerCleanup) == "function" then
    pcall(env.KyroOptimizerCleanup)
    env.KyroOptimizerCleanup = nil
end
for _, child in ipairs(playerGui:GetChildren()) do
    if child.Name == "KyroOptimizer" then
        pcall(function() child:Destroy() end)
    end
end

local J = Janitor.new()

------------------------------------------------------------------------------------------
-- THEME + GUI HELPERS
------------------------------------------------------------------------------------------
local C = {
    bg     = Color3.fromRGB(9, 12, 18),
    panel  = Color3.fromRGB(17, 22, 32),
    panel2 = Color3.fromRGB(28, 35, 50),
    rowOn  = Color3.fromRGB(14, 36, 50),
    stroke = Color3.fromRGB(44, 56, 78),
    cyan   = Color3.fromRGB(0, 229, 255),
    blue   = Color3.fromRGB(41, 121, 255),
    trackOn = Color3.fromRGB(0, 140, 190),
    white  = Color3.fromRGB(240, 246, 252),
    muted  = Color3.fromRGB(140, 152, 172),
    dim    = Color3.fromRGB(96, 108, 128),
}

local function make(className, props, parent)
    local obj = Instance.new(className)
    for k, v in pairs(props or {}) do
        obj[k] = v
    end
    obj.Parent = parent
    return obj
end

local function corner(parent, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function stroke(parent, color, thickness, transparency)
    return make("UIStroke", {
        Color = color,
        Thickness = thickness,
        Transparency = transparency,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, parent)
end

local function cyanGradient(parent, rotation)
    return make("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, C.cyan),
            ColorSequenceKeypoint.new(0.5, C.blue),
            ColorSequenceKeypoint.new(1, C.cyan),
        }),
        Rotation = rotation or 0,
    }, parent)
end

local function tween(obj, time, props, style, dir)
    local tw = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
    tw:Play()
    return tw
end

local function loopTween(obj, info, props)
    local tw = TweenService:Create(obj, info, props)
    tw:Play()
    J:Add(function() pcall(function() tw:Cancel() end) end)
    return tw
end

------------------------------------------------------------------------------------------
-- ROOT GUI (z-order, Sibling mode): overlay 50 < anti-hit 80 < panel 100 < icon 110
------------------------------------------------------------------------------------------
local gui = make("ScreenGui", {
    Name = "KyroOptimizer",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
J:Add(gui)

local function getViewport()
    local v = gui.AbsoluteSize
    if v.X <= 0 or v.Y <= 0 then
        local cam = workspace.CurrentCamera
        if cam then
            v = cam.ViewportSize
        else
            v = Vector2.new(800, 600)
        end
    end
    return v
end

local function isTouch()
    return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

------------------------------------------------------------------------------------------
-- LOGO (uses the real image; the "K" text only appears if no image could be loaded)
------------------------------------------------------------------------------------------
local Logo = { targets = {}, image = nil }

local function applyLogoImage(asset)
    Logo.image = asset
    for _, t in ipairs(Logo.targets) do
        if t.img.Parent then
            t.img.Image = asset
            t.img.Visible = true
            t.fallback.Visible = false
        end
    end
end

function Logo.attach(img, fallback)
    table.insert(Logo.targets, { img = img, fallback = fallback })
    if Logo.image then
        img.Image = Logo.image
        img.Visible = true
        fallback.Visible = false
    end
end

function Logo.resolve()
    local id = CONFIG.LOGO_ASSET_ID
    if type(id) == "string" and id ~= "" then
        if tonumber(id) then id = "rbxassetid://" .. id end
        applyLogoImage(id)
        return true
    end
    local ok, asset = pcall(function()
        local getAsset = getcustomasset or getsynasset
        if not getAsset then return nil end
        local hasFile = isfile and isfile(CONFIG.LOGO_FILE)
        if not hasFile and CONFIG.LOGO_URL ~= "" and writefile then
            writefile(CONFIG.LOGO_FILE, game:HttpGet(CONFIG.LOGO_URL))
            hasFile = isfile and isfile(CONFIG.LOGO_FILE)
        end
        if hasFile then return getAsset(CONFIG.LOGO_FILE) end
        return nil
    end)
    if ok and asset and asset ~= "" then
        applyLogoImage(asset)
        return true
    end
    warn("[Kyro] Logo image not found. Set CONFIG.LOGO_ASSET_ID, or put kyro_logo.png in your executor workspace folder. Showing placeholder.")
    return false
end

local function makeLogo(parent, props)
    props.BackgroundTransparency = 1
    local holder = make("Frame", props, parent)
    local img = make("ImageLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Image = "",
        ScaleType = Enum.ScaleType.Fit,
        Visible = false,
    }, holder)
    local fallback = make("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "K",
        TextColor3 = C.cyan,
        Font = Enum.Font.GothamBlack,
        TextScaled = true,
    }, holder)
    Logo.attach(img, fallback)
    return holder
end

------------------------------------------------------------------------------------------
-- FEATURE STATE
------------------------------------------------------------------------------------------
local states = { fps = false, low = false, high = false, black = false, antihit = true }
local ui = {}                 -- filled by the UI section (ui.refresh)
local Graphics, Overlay, AntiHit

local function setFeature(key, value)
    value = value and true or false
    if value then
        -- High Graphics conflicts with FPS Boost / Low Graphics; FPS Boost + Low can coexist (Low wins).
        if key == "high" then
            states.fps = false
            states.low = false
        elseif key == "fps" or key == "low" then
            states.high = false
        end
    end
    states[key] = value
    if key == "black" then
        Overlay.set(value)
    elseif key == "antihit" then
        AntiHit.setEnabled(value)
    else
        Graphics.apply(states)
    end
    if ui.refresh then ui.refresh() end
end

------------------------------------------------------------------------------------------
-- GRAPHICS MODULE  (single resolver; every change is recorded so it can be restored)
------------------------------------------------------------------------------------------
Graphics = {}
do
    local lightBase, terrainBase = {}, {}
    local effectBase = setmetatable({}, { __mode = "k" })
    local particleBase = setmetatable({}, { __mode = "k" })
    local qualityBase = nil
    local watch = Janitor.new()
    local scanToken = 0
    local terrain = workspace:FindFirstChildOfClass("Terrain")

    local POST = { "BloomEffect", "BlurEffect", "ColorCorrectionEffect", "DepthOfFieldEffect", "SunRaysEffect" }
    local PARTICLES = { "ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles" }

    local function isAny(obj, list)
        for _, className in ipairs(list) do
            if obj:IsA(className) then return true end
        end
        return false
    end

    local function setLight(prop, value)
        pcall(function()
            if lightBase[prop] == nil then lightBase[prop] = Lighting[prop] end
            Lighting[prop] = value
        end)
    end

    local function setTerrain(prop, value)
        if not terrain then return end
        pcall(function()
            if terrainBase[prop] == nil then terrainBase[prop] = terrain[prop] end
            terrain[prop] = value
        end)
    end

    local function setTracked(tbl, obj, enabled)
        pcall(function()
            if tbl[obj] == nil then tbl[obj] = obj.Enabled end
            obj.Enabled = enabled
        end)
    end

    local function restoreTracked(tbl)
        for obj, value in pairs(tbl) do
            if obj.Parent then
                pcall(function() obj.Enabled = value end)
            end
            tbl[obj] = nil
        end
    end

    local function setQuality(level)
        pcall(function()
            local rendering = settings().Rendering
            if qualityBase == nil then qualityBase = rendering.QualityLevel end
            rendering.QualityLevel = level
        end)
    end

    local function restoreAll()
        scanToken = scanToken + 1
        watch:Cleanup()
        for prop, value in pairs(lightBase) do
            pcall(function() Lighting[prop] = value end)
            lightBase[prop] = nil
        end
        for prop, value in pairs(terrainBase) do
            pcall(function() terrain[prop] = value end)
            terrainBase[prop] = nil
        end
        restoreTracked(effectBase)
        restoreTracked(particleBase)
        if qualityBase ~= nil then
            local q = qualityBase
            qualityBase = nil
            pcall(function() settings().Rendering.QualityLevel = q end)
        end
    end

    local function disablePostEffects()
        for _, obj in ipairs(Lighting:GetDescendants()) do
            if isAny(obj, POST) then setTracked(effectBase, obj, false) end
        end
        local cam = workspace.CurrentCamera
        if cam then
            for _, obj in ipairs(cam:GetChildren()) do
                if isAny(obj, POST) then setTracked(effectBase, obj, false) end
            end
        end
        -- Effects the game adds later while the mode is on.
        watch:Add(Lighting.DescendantAdded:Connect(function(obj)
            if isAny(obj, POST) then task.defer(setTracked, effectBase, obj, false) end
        end))
    end

    local function disableParticles()
        local token = scanToken
        task.spawn(function()
            local n = 0
            for _, obj in ipairs(workspace:GetDescendants()) do
                if token ~= scanToken then return end
                if isAny(obj, PARTICLES) then setTracked(particleBase, obj, false) end
                n = n + 1
                if n % 1500 == 0 then task.wait() end
            end
        end)
        watch:Add(workspace.DescendantAdded:Connect(function(obj)
            if isAny(obj, PARTICLES) then task.defer(setTracked, particleBase, obj, false) end
        end))
    end

    function Graphics.apply(s)
        restoreAll() -- always start from the original look, then apply ONE resolved profile
        if s.low then
            setLight("GlobalShadows", false)
            setLight("EnvironmentDiffuseScale", 0)
            setLight("EnvironmentSpecularScale", 0)
            disablePostEffects()
            disableParticles()
            setTerrain("Decoration", false)
            setTerrain("WaterWaveSize", 0)
            setTerrain("WaterWaveSpeed", 0)
            setTerrain("WaterReflectance", 0)
            setQuality(Enum.QualityLevel.Level01)
        elseif s.fps then
            setLight("GlobalShadows", false)
            disablePostEffects()
        elseif s.high then
            -- Effects/lighting are already back to the game's originals; ask for the best quality the
            -- device allows. Roblox clamps this to what the device supports.
            setLight("GlobalShadows", true)
            setQuality(Enum.QualityLevel.Level21)
        end
    end

    Graphics.restoreAll = restoreAll
end

------------------------------------------------------------------------------------------
-- 3D RENDERING OVERLAY (visual only -- the GPU keeps rendering behind it)
------------------------------------------------------------------------------------------
local blackOverlay = make("Frame", {
    Name = "RenderingOverlay",
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Visible = false,
    Active = false,
    ZIndex = 50,
}, gui)
local overlayHint = make("TextLabel", {
    AnchorPoint = Vector2.new(0.5, 1),
    Position = UDim2.new(0.5, 0, 1, -18),
    Size = UDim2.new(1, -24, 0, 44),
    BackgroundTransparency = 1,
    Text = "3D RENDERING OVERLAY ON\nTap the Kyro logo to open the menu  -  GPU still renders behind this screen",
    TextColor3 = C.dim,
    TextSize = 11,
    Font = Enum.Font.GothamMedium,
    TextWrapped = true,
    ZIndex = 51,
}, blackOverlay)

Overlay = {}
do
    local overlayId = 0
    function Overlay.set(on)
        overlayId = overlayId + 1
        local id = overlayId
        if on then
            blackOverlay.Visible = true
            tween(blackOverlay, 0.25, { BackgroundTransparency = 0 })
        else
            tween(blackOverlay, 0.2, { BackgroundTransparency = 1 })
            task.delay(0.22, function()
                if overlayId == id then blackOverlay.Visible = false end
            end)
        end
    end
end

------------------------------------------------------------------------------------------
-- ANTI-HIT ACTIVATION VISUAL (Kyro identity)
------------------------------------------------------------------------------------------
local ah = {}
ah.root = make("CanvasGroup", {
    Name = "AntiHitOverlay",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    GroupTransparency = 1,
    Visible = false,
    ZIndex = 80,
}, gui)
make("Frame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundColor3 = Color3.fromRGB(3, 5, 10),
    BackgroundTransparency = 0.06,
    BorderSizePixel = 0,
}, ah.root)

ah.card = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(300, 262),
    BackgroundTransparency = 1,
}, ah.root)
ah.cardScale = make("UIScale", { Scale = 1 }, ah.card)

ah.ringWrap = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 0),
    Size = UDim2.fromOffset(116, 116),
    BackgroundColor3 = C.panel,
    BackgroundTransparency = 0.25,
}, ah.card)
corner(ah.ringWrap, 58)
ah.ringStroke = stroke(ah.ringWrap, C.cyan, 2.5, 0.1)
ah.logoScale = make("UIScale", { Scale = 1 }, ah.ringWrap)
makeLogo(ah.ringWrap, {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(74, 74),
})

local ahTitle = make("TextLabel", {
    Position = UDim2.fromOffset(0, 128),
    Size = UDim2.new(1, 0, 0, 30),
    BackgroundTransparency = 1,
    Text = "KYRO OPTIMIZER",
    TextColor3 = C.white,
    TextSize = 25,
    Font = Enum.Font.GothamBlack,
}, ah.card)
make("UIGradient", {
    Color = ColorSequence.new(C.white, C.cyan),
    Rotation = 0,
}, ahTitle)

make("TextLabel", {
    Position = UDim2.fromOffset(0, 158),
    Size = UDim2.new(1, 0, 0, 16),
    BackgroundTransparency = 1,
    Text = "STEAL AN EGG  -  ANTI-HIT SEQUENCE",
    TextColor3 = C.muted,
    TextSize = 10,
    Font = Enum.Font.GothamMedium,
}, ah.card)

ah.status = make("TextLabel", {
    Position = UDim2.fromOffset(0, 182),
    Size = UDim2.new(1, 0, 0, 22),
    BackgroundTransparency = 1,
    Text = "EGG DETECTED • ACTIVATING",
    TextColor3 = C.cyan,
    TextSize = 13,
    Font = Enum.Font.GothamBold,
}, ah.card)

local ahTrack = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, 214),
    Size = UDim2.new(1, -30, 0, 8),
    BackgroundColor3 = C.panel2,
    BorderSizePixel = 0,
}, ah.card)
corner(ahTrack, 4)
stroke(ahTrack, C.cyan, 1, 0.65)
ah.fill = make("Frame", {
    Size = UDim2.fromScale(0, 1),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
}, ahTrack)
corner(ah.fill, 4)
cyanGradient(ah.fill, 0)

make("TextLabel", {
    Position = UDim2.fromOffset(0, 232),
    Size = UDim2.new(1, 0, 0, 24),
    BackgroundTransparency = 1,
    Text = "Visual indicator only. Damage rules are controlled by the game server.",
    TextColor3 = C.dim,
    TextSize = 9,
    Font = Enum.Font.Gotham,
    TextWrapped = true,
}, ah.card)

------------------------------------------------------------------------------------------
-- ANTI-HIT LOGIC
--   prompt pressed -> wait for a NEW Egg Tool to enter the Character -> play 3s sequence
------------------------------------------------------------------------------------------
AntiHit = {}
do
    local enabled = true
    local busy = false          -- animation running
    local pending = false       -- armed, waiting for the Egg Tool
    local pendingId = 0
    local animId = 0
    local snapshot = {}         -- tools that already existed when the prompt was pressed
    local pendingJ = Janitor.new()
    local charJ = Janitor.new()
    local currentChar = nil
    local pulse = nil

    local function lower(s) return string.lower(tostring(s or "")) end

    local function hasAny(text, words)
        for _, w in ipairs(words) do
            if string.find(text, w, 1, true) then return true end
        end
        return false
    end

    local function setStatus(text, kind)
        if AntiHit.onStatus then pcall(AntiHit.onStatus, text, kind) end
    end

    local function idleStatus()
        if enabled then setStatus("READY", "idle") else setStatus("OFF", "off") end
    end

    local function isEggTool(tool)
        if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then return false end
        if hasAny(lower(tool.Name), CONFIG.EGG_WORDS) then return true end
        if hasAny(lower(tool.ToolTip), CONFIG.EGG_WORDS) then return true end
        local okAttr, attrs = pcall(function() return tool:GetAttributes() end)
        if okAttr and type(attrs) == "table" then
            for _, value in pairs(attrs) do
                if type(value) == "string" and hasAny(lower(value), CONFIG.EGG_WORDS) then return true end
            end
        end
        return false
    end

    local function isStealPrompt(prompt)
        local own = lower(prompt.Name) .. " " .. lower(prompt.ActionText) .. " " .. lower(prompt.ObjectText)
        if hasAny(own, CONFIG.EXCLUDE_WORDS) then return false end
        local chain = {}
        local p = prompt.Parent
        for _ = 1, 4 do
            if not p or p == workspace then break end
            table.insert(chain, lower(p.Name))
            p = p.Parent
        end
        local all = own .. " " .. table.concat(chain, " ")
        if hasAny(all, CONFIG.STEAL_WORDS) then return true end
        return hasAny(all, CONFIG.EGG_WORDS) and hasAny(all, CONFIG.ACTION_WORDS)
    end

    local function hideNow()
        if pulse then
            pcall(function() pulse:Cancel() end)
            pulse = nil
        end
        ah.root.Visible = false
        ah.root.GroupTransparency = 1
        ah.fill.Size = UDim2.fromScale(0, 1)
    end

    local function abort()
        animId = animId + 1
        busy = false
        hideNow()
    end

    local function clearPending()
        pending = false
        pendingId = pendingId + 1
        pendingJ:Cleanup()
        snapshot = {}
        if not busy then idleStatus() end
    end

    local function waitUntil(t, id)
        while os.clock() < t do
            if id ~= animId then return false end
            task.wait()
        end
        return id == animId
    end

    local function play(id)
        local dur = math.max(CONFIG.ANTIHIT_DURATION, 1.5)
        local fadeIn, fadeOut, hold = 0.3, 0.3, 0.25
        local progress = dur - fadeIn - fadeOut - hold
        local t0 = os.clock()

        ah.status.Text = "EGG DETECTED • ACTIVATING"
        ah.status.TextColor3 = C.cyan
        ah.fill.Size = UDim2.fromScale(0, 1)
        ah.logoScale.Scale = 0.8
        ah.ringStroke.Transparency = 0.1
        ah.root.GroupTransparency = 1
        ah.root.Visible = true

        tween(ah.root, fadeIn, { GroupTransparency = 0 })
        tween(ah.logoScale, 0.45, { Scale = 1 }, Enum.EasingStyle.Back)
        pulse = TweenService:Create(ah.ringStroke, TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.75 })
        pulse:Play()

        if not waitUntil(t0 + fadeIn, id) then return end
        tween(ah.fill, progress, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

        if not waitUntil(t0 + fadeIn + progress, id) then return end
        ah.status.Text = "EGG PICKUP DETECTED • KYRO ACTIVE"
        ah.status.TextColor3 = C.white
        tween(ah.status, 0.35, { TextColor3 = C.cyan })
        setStatus("ACTIVE", "active")

        if not waitUntil(t0 + dur - fadeOut, id) then return end
        tween(ah.root, fadeOut, { GroupTransparency = 1 })
        waitUntil(t0 + dur, id)
    end

    local function start()
        if busy or not enabled then return end
        busy = true
        pending = false
        pendingId = pendingId + 1
        pendingJ:Cleanup()
        snapshot = {}
        animId = animId + 1
        local id = animId
        setStatus("EGG DETECTED", "active")
        task.spawn(function()
            local ok, err = pcall(play, id)
            if not ok then dbg("anti-hit animation error:", err) end
            if id == animId then -- not aborted meanwhile -> reset state
                hideNow()
                busy = false
                idleStatus()
            end
        end)
    end

    local function inspect(tool)
        if not pending or busy or snapshot[tool] then return end
        if isEggTool(tool) then
            start()
            return
        end
        -- The Tool may be renamed right after it is parented; watch the name until the window ends.
        local id = pendingId
        pendingJ:Add(tool:GetPropertyChangedSignal("Name"):Connect(function()
            if pending and pendingId == id and isEggTool(tool) then start() end
        end))
    end

    local function onPrompt(prompt, who)
        if who ~= player or not enabled or busy or pending then return end
        if CONFIG.REQUIRE_STEAL_PROMPT then
            local okMatch, matched = pcall(isStealPrompt, prompt)
            if not okMatch or not matched then return end
        end
        local char = player.Character
        if not char then return end

        snapshot = {}
        for _, c in ipairs(char:GetChildren()) do
            if c:IsA("Tool") then snapshot[c] = true end
        end
        if CONFIG.ALSO_WATCH_BACKPACK then
            local bp = player:FindFirstChildOfClass("Backpack")
            if bp then
                for _, c in ipairs(bp:GetChildren()) do
                    if c:IsA("Tool") then snapshot[c] = true end
                end
            end
        end

        pending = true
        pendingId = pendingId + 1
        local id = pendingId
        setStatus("WAITING FOR EGG", "wait")
        task.delay(CONFIG.PICKUP_TIMEOUT, function()
            if pending and pendingId == id then clearPending() end
        end)
    end

    local function onCharacter(char)
        charJ:Cleanup()
        currentChar = char
        abort()
        clearPending()

        local function onChild(child)
            if child:IsA("Tool") then inspect(child) end
        end
        charJ:Add(char.ChildAdded:Connect(onChild))

        task.spawn(function()
            local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
            if hum and currentChar == char then
                charJ:Add(hum.Died:Connect(function()
                    abort()
                    clearPending()
                end))
            end
            if CONFIG.ALSO_WATCH_BACKPACK then
                local bp = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
                if bp and currentChar == char then
                    charJ:Add(bp.ChildAdded:Connect(onChild))
                end
            end
        end)
    end

    function AntiHit.setEnabled(value)
        enabled = value and true or false
        if not enabled then
            abort()
            clearPending()
        end
        idleStatus()
    end

    function AntiHit.init()
        J:Add(ProximityPromptService.PromptTriggered:Connect(onPrompt))
        J:Add(player.CharacterAdded:Connect(onCharacter))
        if player.Character then onCharacter(player.Character) end
        idleStatus()
    end

    function AntiHit.destroy()
        animId = animId + 1
        busy = false
        pending = false
        pendingId = pendingId + 1
        pendingJ:Cleanup()
        charJ:Cleanup()
    end
end

------------------------------------------------------------------------------------------
-- MAIN PANEL + FLOATING LOGO BUTTON
------------------------------------------------------------------------------------------
-- Floating logo button (always above the overlay, draggable, click = toggle panel)
local icon = make("TextButton", {
    Name = "KyroIcon",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromOffset(46, 200),
    Size = UDim2.fromOffset(54, 54),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.1,
    Text = "",
    AutoButtonColor = false,
    ZIndex = 110,
}, gui)
corner(icon, 16)
local iconStroke = stroke(icon, Color3.new(1, 1, 1), 2, 0.05)
local iconGrad = cyanGradient(iconStroke, 0)
makeLogo(icon, {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.new(1, -12, 1, -12),
})
local iconDot = make("Frame", {
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.new(1, -4, 0, 4),
    Size = UDim2.fromOffset(11, 11),
    BackgroundColor3 = C.cyan,
    Visible = false,
    ZIndex = 112,
}, icon)
corner(iconDot, 6)
stroke(iconDot, C.bg, 2, 0)
loopTween(iconGrad, TweenInfo.new(5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })

-- Main panel (CanvasGroup so the whole panel can fade)
local main = make("CanvasGroup", {
    Name = "Main",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromOffset(400, 300),
    Size = UDim2.fromOffset(320, 360),
    BackgroundColor3 = C.bg,
    BackgroundTransparency = 0.06,
    GroupTransparency = 1,
    Visible = false,
    ZIndex = 100,
}, gui)
corner(main, 18)
local mainStroke = stroke(main, Color3.new(1, 1, 1), 1.5, 0.1)
local mainGrad = cyanGradient(mainStroke, 0)
loopTween(mainGrad, TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Rotation = 360 })
local mainScale = make("UIScale", { Scale = 1 }, main)

-- soft inner glow
do
    local glow = make("Frame", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Active = false,
    }, main)
    corner(glow, 18)
    stroke(glow, C.cyan, 5, 0.88)
    make("UIGradient", {
        Color = ColorSequence.new(Color3.fromRGB(22, 30, 46), Color3.fromRGB(8, 10, 16)),
        Rotation = 90,
    }, main)
end

-- Header (also the drag handle for the panel)
local header = make("Frame", {
    Size = UDim2.new(1, 0, 0, 56),
    BackgroundTransparency = 1,
}, main)
makeLogo(header, {
    Position = UDim2.fromOffset(14, 10),
    Size = UDim2.fromOffset(36, 36),
})
local titleLabel = make("TextLabel", {
    Position = UDim2.fromOffset(58, 8),
    Size = UDim2.new(1, -108, 0, 22),
    BackgroundTransparency = 1,
    Text = "KYRO OPTIMIZER",
    TextColor3 = C.white,
    TextSize = 17,
    Font = Enum.Font.GothamBlack,
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)
make("UIGradient", { Color = ColorSequence.new(C.white, C.cyan) }, titleLabel)
make("TextLabel", {
    Position = UDim2.fromOffset(58, 31),
    Size = UDim2.new(1, -108, 0, 14),
    BackgroundTransparency = 1,
    Text = "ADVANCED PERFORMANCE CONTROL",
    TextColor3 = C.muted,
    TextSize = 9,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, header)
local closeBtn = make("TextButton", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -12, 0, 14),
    Size = UDim2.fromOffset(28, 28),
    BackgroundColor3 = C.panel2,
    BackgroundTransparency = 0.2,
    Text = "×",
    TextColor3 = C.white,
    TextSize = 20,
    Font = Enum.Font.GothamMedium,
    AutoButtonColor = true,
}, header)
corner(closeBtn, 9)

make("Frame", {
    Position = UDim2.fromOffset(14, 56),
    Size = UDim2.new(1, -28, 0, 1),
    BackgroundColor3 = C.cyan,
    BackgroundTransparency = 0.8,
    BorderSizePixel = 0,
}, main)

-- Status chips (one per feature)
local chipHolder = make("Frame", {
    Position = UDim2.fromOffset(12, 64),
    Size = UDim2.new(1, -24, 0, 24),
    BackgroundTransparency = 1,
}, main)
make("UIGridLayout", {
    CellSize = UDim2.new(0.2, -4, 1, 0),
    CellPadding = UDim2.fromOffset(4, 0),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, chipHolder)

local chips = {}
local function createChip(key, text, order)
    local chip = make("Frame", {
        LayoutOrder = order,
        BackgroundColor3 = C.panel2,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
    }, chipHolder)
    corner(chip, 8)
    local st = stroke(chip, C.stroke, 1, 0.5)
    local label = make("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = C.dim,
        TextSize = 9,
        Font = Enum.Font.GothamBold,
    }, chip)
    chips[key] = { frame = chip, label = label, stroke = st }
end
createChip("fps", "FPS", 1)
createChip("low", "LOW", 2)
createChip("high", "HIGH", 3)
createChip("black", "3D OFF", 4)
createChip("antihit", "ANTI-HIT", 5)

local statusLine = make("TextLabel", {
    Position = UDim2.fromOffset(14, 92),
    Size = UDim2.new(1, -28, 0, 16),
    BackgroundTransparency = 1,
    Text = "0 ACTIVE  •  ANTI-HIT READY",
    TextColor3 = C.cyan,
    TextSize = 10,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)

-- Feature list
local scroll = make("ScrollingFrame", {
    Position = UDim2.fromOffset(10, 114),
    Size = UDim2.new(1, -20, 1, -114 - 32),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.cyan,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, main)
make("UIListLayout", {
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, scroll)
make("UIPadding", { PaddingBottom = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, scroll)

local rows = {}
local function createRow(key, title, desc, order)
    local row = make("TextButton", {
        Name = key,
        Size = UDim2.new(1, 0, 0, 54),
        BackgroundColor3 = C.panel,
        BackgroundTransparency = 0.2,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = order,
    }, scroll)
    corner(row, 12)
    local st = stroke(row, C.stroke, 1, 0.55)
    local accent = make("Frame", {
        Position = UDim2.new(0, 0, 0.5, -13),
        Size = UDim2.fromOffset(3, 26),
        BackgroundColor3 = C.cyan,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
    }, row)
    corner(accent, 2)
    make("TextLabel", {
        Position = UDim2.fromOffset(14, 8),
        Size = UDim2.new(1, -82, 0, 18),
        BackgroundTransparency = 1,
        Text = title,
        TextColor3 = C.white,
        TextSize = 13,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    make("TextLabel", {
        Position = UDim2.fromOffset(14, 28),
        Size = UDim2.new(1, -82, 0, 16),
        BackgroundTransparency = 1,
        Text = desc,
        TextColor3 = C.muted,
        TextSize = 10,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    local track = make("Frame", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -10, 0.5, 0),
        Size = UDim2.fromOffset(54, 26),
        BackgroundColor3 = C.panel2,
        BorderSizePixel = 0,
    }, row)
    corner(track, 13)
    local label = make("TextLabel", {
        Position = UDim2.fromOffset(6, 0),
        Size = UDim2.new(1, -12, 1, 0),
        BackgroundTransparency = 1,
        Text = "OFF",
        TextColor3 = C.dim,
        TextSize = 9,
        Font = Enum.Font.GothamBold,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, track)
    local knob = make("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 3, 0.5, 0),
        Size = UDim2.fromOffset(20, 20),
        BackgroundColor3 = C.muted,
        BorderSizePixel = 0,
    }, track)
    corner(knob, 10)
    rows[key] = { row = row, stroke = st, accent = accent, track = track, knob = knob, label = label }
    row.Activated:Connect(function()
        setFeature(key, not states[key])
    end)
end

createRow("fps", "FPS Boost", "Fewer effects, no shadows, no post-FX", 1)
createRow("low", "Low Graphics", "Lowest quality, no particles/shadows", 2)
createRow("high", "High Graphics", "Best quality your device supports", 3)
createRow("black", "Turn Off 3D Rendering", "Black overlay only; GPU still renders", 4)
createRow("antihit", "Anti-Hit Activation", "Egg pickup sequence (visual only)", 5)

-- Footer
make("TextLabel", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 14, 1, -6),
    Size = UDim2.new(1, -90, 0, 18),
    BackgroundTransparency = 1,
    Text = "KYRO  •  STEAL AN EGG  •  v" .. CONFIG.VERSION,
    TextColor3 = C.dim,
    TextSize = 9,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left,
}, main)
local unloadBtn = make("TextButton", {
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -12, 1, -6),
    Size = UDim2.fromOffset(62, 20),
    BackgroundColor3 = C.panel2,
    BackgroundTransparency = 0.2,
    Text = "UNLOAD",
    TextColor3 = C.muted,
    TextSize = 9,
    Font = Enum.Font.GothamBold,
    AutoButtonColor = true,
}, main)
corner(unloadBtn, 7)

------------------------------------------------------------------------------------------
-- UI STATE VISUALS
------------------------------------------------------------------------------------------
local ahStatusText = "READY"
local activeCount = 0

local function setRowVisual(r, on)
    tween(r.track, 0.18, { BackgroundColor3 = on and C.trackOn or C.panel2 })
    tween(r.knob, 0.2, {
        Position = on and UDim2.new(1, -23, 0.5, 0) or UDim2.new(0, 3, 0.5, 0),
        BackgroundColor3 = on and C.white or C.muted,
    }, Enum.EasingStyle.Back)
    r.label.Text = on and "ON" or "OFF"
    r.label.TextXAlignment = on and Enum.TextXAlignment.Left or Enum.TextXAlignment.Right
    r.label.TextColor3 = on and C.white or C.dim
    tween(r.accent, 0.18, { BackgroundTransparency = on and 0 or 1 })
    tween(r.stroke, 0.18, { Color = on and C.cyan or C.stroke, Transparency = on and 0.35 or 0.55 })
    tween(r.row, 0.18, { BackgroundColor3 = on and C.rowOn or C.panel })
end

local function setChipVisual(c, on)
    c.label.TextColor3 = on and C.cyan or C.dim
    tween(c.frame, 0.18, { BackgroundColor3 = on and C.rowOn or C.panel2 })
    tween(c.stroke, 0.18, { Color = on and C.cyan or C.stroke, Transparency = on and 0.25 or 0.5 })
end

function ui.refresh()
    local count = 0
    for key, r in pairs(rows) do
        setRowVisual(r, states[key])
        if states[key] then count = count + 1 end
    end
    for key, c in pairs(chips) do
        setChipVisual(c, states[key])
    end
    activeCount = count
    statusLine.Text = string.format("%d ACTIVE  •  ANTI-HIT %s", count, ahStatusText)
    iconDot.Visible = count > 0
end

AntiHit.onStatus = function(text)
    ahStatusText = text
    statusLine.Text = string.format("%d ACTIVE  •  ANTI-HIT %s", activeCount, text)
end

------------------------------------------------------------------------------------------
-- LAYOUT, DRAGGING, OPEN/CLOSE
------------------------------------------------------------------------------------------
local function setCenter(target, x, y)
    local vp = getViewport()
    local halfW = target.Size.X.Offset / 2
    local halfH = target.Size.Y.Offset / 2
    x = math.clamp(x, halfW, math.max(halfW, vp.X - halfW))
    y = math.clamp(y, halfH, math.max(halfH, vp.Y - halfH))
    target.Position = UDim2.fromOffset(x, y)
end

local placed = false
local function layout()
    local vp = getViewport()
    local touch = isTouch()
    local w = math.clamp(vp.X - 24, 250, touch and 300 or 340)
    local h = math.clamp(math.floor(vp.Y * (touch and 0.8 or 0.7)), 250, touch and 340 or 450)
    main.Size = UDim2.fromOffset(w, h)
    ah.cardScale.Scale = math.clamp(math.min((vp.X - 24) / 300, (vp.Y - 24) / 262), 0.5, 1)
    if not placed then
        placed = true
        icon.Position = UDim2.fromOffset(46, vp.Y * 0.4)
        local mx = touch and (vp.X - w / 2 - 12) or (vp.X / 2)
        main.Position = UDim2.fromOffset(mx, vp.Y / 2)
    end
    setCenter(main, main.Position.X.Offset, main.Position.Y.Offset)
    setCenter(icon, icon.Position.X.Offset, icon.Position.Y.Offset)
end

local activeDrag = nil
local function makeDraggable(handle, target, onClick)
    handle.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
        if activeDrag then return end
        activeDrag = {
            input = input,
            target = target,
            onClick = onClick,
            startX = input.Position.X,
            startY = input.Position.Y,
            baseX = target.Position.X.Offset,
            baseY = target.Position.Y.Offset,
            moved = false,
        }
    end)
end

J:Add(UserInputService.InputChanged:Connect(function(input)
    local d = activeDrag
    if not d then return end
    local t = input.UserInputType
    if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == d.input) then
        local dx = input.Position.X - d.startX
        local dy = input.Position.Y - d.startY
        if not d.moved and (dx * dx + dy * dy) > 36 then d.moved = true end
        if d.moved then setCenter(d.target, d.baseX + dx, d.baseY + dy) end
    end
end))

J:Add(UserInputService.InputEnded:Connect(function(input)
    local d = activeDrag
    if not d then return end
    local isEnd = input == d.input
        or (input.UserInputType == Enum.UserInputType.MouseButton1 and d.input.UserInputType == Enum.UserInputType.MouseButton1)
    if isEnd then
        activeDrag = nil
        if not d.moved and d.onClick then d.onClick() end
    end
end))

local panelOpen = false
local panelId = 0
local function setPanel(open)
    panelOpen = open
    panelId = panelId + 1
    local id = panelId
    if open then
        if not main.Visible then
            main.GroupTransparency = 1
            mainScale.Scale = 0.9
            main.Visible = true
        end
        tween(main, 0.25, { GroupTransparency = 0 })
        tween(mainScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
    else
        tween(main, 0.18, { GroupTransparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        tween(mainScale, 0.18, { Scale = 0.94 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        task.delay(0.2, function()
            if panelId == id then main.Visible = false end
        end)
    end
end
local function togglePanel() setPanel(not panelOpen) end

makeDraggable(icon, icon, togglePanel)
makeDraggable(header, main, nil)
closeBtn.Activated:Connect(function() setPanel(false) end)

J:Add(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        togglePanel()
    end
end))

gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)

------------------------------------------------------------------------------------------
-- CLEANUP + BOOT
------------------------------------------------------------------------------------------
local cleaned = false
local function cleanup()
    if cleaned then return end
    cleaned = true
    pcall(AntiHit.destroy)
    pcall(Graphics.restoreAll)
    if env.KyroOptimizerCleanup == cleanup then
        env.KyroOptimizerCleanup = nil
    end
    J:Cleanup()
end
env.KyroOptimizerCleanup = cleanup
J:Add(gui.Destroying:Connect(cleanup))
unloadBtn.Activated:Connect(cleanup)

layout()
ui.refresh()
AntiHit.init()
setPanel(true)
task.defer(layout)
task.spawn(function()
    local ok, err = pcall(Logo.resolve)
    if not ok then dbg("logo error:", err) end
end)
