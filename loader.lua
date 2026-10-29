-- Kyro Optimizer | loader.lua
-- Client-side visual/performance toggles. Use only in experiences where you have permission.
-- Note: this is a client UI script, not a guarantee of higher FPS or a way to stop Roblox's renderer.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Avoid duplicate UIs after re-execution.
local old = playerGui:FindFirstChild("KyroOptimizer")
if old then old:Destroy() end

local gui = Instance.new("ScreenGui")
gui.Name = "KyroOptimizer"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.Parent = playerGui

local function make(className, props, parent)
    local obj = Instance.new(className)
    for k, v in pairs(props or {}) do obj[k] = v end
    obj.Parent = parent
    return obj
end

local function corner(parent, radius)
    make("UICorner", {CornerRadius = UDim.new(0, radius or 10)}, parent)
end

local function stroke(parent, color, thickness, transparency)
    make("UIStroke", {
        Color = color or Color3.fromRGB(0, 190, 255),
        Thickness = thickness or 1,
        Transparency = transparency or 0.2
    }, parent)
end

local bg = Color3.fromRGB(18, 19, 23)
local panel = Color3.fromRGB(29, 31, 37)
local panel2 = Color3.fromRGB(37, 40, 47)
local muted = Color3.fromRGB(160, 168, 180)
local cyan = Color3.fromRGB(0, 190, 255)
local white = Color3.fromRGB(242, 246, 250)

-- Floating K button stays visible when the main panel is hidden.
local iconButton = make("TextButton", {
    Name = "KyroIcon",
    Size = UDim2.fromOffset(52, 52),
    Position = UDim2.new(0, 18, 0.5, -26),
    BackgroundColor3 = Color3.fromRGB(16, 35, 49),
    Text = "K",
    TextColor3 = cyan,
    TextSize = 32,
    Font = Enum.Font.GothamBlack,
    AutoButtonColor = true,
    ZIndex = 10
}, gui)
corner(iconButton, 16)
stroke(iconButton, cyan, 2, 0.05)

local main = make("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(330, 390),
    Position = UDim2.new(0, 82, 0.5, -195),
    BackgroundColor3 = bg,
    BorderSizePixel = 0,
    Visible = true
}, gui)
corner(main, 16)
stroke(main, Color3.fromRGB(65, 76, 91), 1, 0.15)

local header = make("Frame", {
    Size = UDim2.new(1, 0, 0, 76),
    BackgroundColor3 = panel,
    BorderSizePixel = 0
}, main)
corner(header, 16)
make("Frame", {
    Size = UDim2.new(1, 0, 0, 16),
    Position = UDim2.new(0, 0, 1, -16),
    BackgroundColor3 = panel,
    BorderSizePixel = 0
}, header)

make("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(18, 11),
    Size = UDim2.new(1, -70, 0, 30),
    Text = "KYRO OPTIMIZER",
    TextColor3 = white,
    TextSize = 19,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left
}, header)

make("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(19, 42),
    Size = UDim2.new(1, -40, 0, 18),
    Text = "CLIENT PERFORMANCE CONTROL",
    TextColor3 = muted,
    TextSize = 10,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Left
}, header)

local close = make("TextButton", {
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -42, 0, 15),
    BackgroundColor3 = panel2,
    Text = "×",
    TextColor3 = white,
    TextSize = 22,
    Font = Enum.Font.GothamMedium,
    AutoButtonColor = true
}, header)
corner(close, 9)

local status = make("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(18, 83),
    Size = UDim2.new(1, -36, 0, 20),
    Text = "FEATURES",
    TextColor3 = cyan,
    TextSize = 11,
    Font = Enum.Font.GothamBold,
    TextXAlignment = Enum.TextXAlignment.Left
}, main)

local list = make("Frame", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(14, 108),
    Size = UDim2.new(1, -28, 0, 230)
}, main)
make("UIListLayout", {
    Padding = UDim.new(0, 8),
    SortOrder = Enum.SortOrder.LayoutOrder
}, list)

local blackOverlay = make("Frame", {
    Name = "RenderingOverlay",
    Size = UDim2.fromScale(1, 1),
    Position = UDim2.fromScale(0, 0),
    BackgroundColor3 = Color3.new(0, 0, 0),
    BackgroundTransparency = 0,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 50
}, gui)

-- Save original visual properties so modes can be switched off cleanly.
local savedLighting = {}
for _, prop in ipairs({"GlobalShadows", "FogEnd", "Brightness", "EnvironmentDiffuseScale", "EnvironmentSpecularScale"}) do
    pcall(function() savedLighting[prop] = Lighting[prop] end)
end

local savedEffects = {}
local function rememberAndSetEffect(effect, enabled)
    if savedEffects[effect] == nil then
        savedEffects[effect] = effect.Enabled
    end
    effect.Enabled = enabled
end

local function setPostEffects(enabled)
    for _, obj in ipairs(Lighting:GetDescendants()) do
        if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
            or obj:IsA("DepthOfFieldEffect") or obj:IsA("SunRaysEffect") then
            pcall(function() rememberAndSetEffect(obj, enabled) end)
        end
    end
end

local states = {
    fps = false,
    low = false,
    high = false,
    black = false
}
local buttons = {}
local applyMode

local function refreshButton(key)
    local button = buttons[key]
    if not button then return end
    local on = states[key]
    button.Toggle.Text = on and "ON" or "OFF"
    button.Toggle.BackgroundColor3 = on and Color3.fromRGB(0, 115, 155) or panel2
    button.Toggle.TextColor3 = on and Color3.fromRGB(230, 250, 255) or muted
    button.Row.BackgroundColor3 = on and Color3.fromRGB(24, 42, 51) or panel
end

local function setState(key, value)
    states[key] = value
    if applyMode then applyMode(key) end
    refreshButton(key)
end

local function createToggle(key, title, description, order)
    local row = make("Frame", {
        Name = key,
        Size = UDim2.new(1, 0, 0, 51),
        BackgroundColor3 = panel,
        BorderSizePixel = 0,
        LayoutOrder = order
    }, list)
    corner(row, 10)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 6),
        Size = UDim2.new(1, -86, 0, 20),
        Text = title,
        TextColor3 = white,
        TextSize = 13,
        Font = Enum.Font.GothamSemibold,
        TextXAlignment = Enum.TextXAlignment.Left
    }, row)

    make("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(12, 27),
        Size = UDim2.new(1, -86, 0, 15),
        Text = description,
        TextColor3 = muted,
        TextSize = 9,
        Font = Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left
    }, row)

    local toggle = make("TextButton", {
        Name = "Toggle",
        Size = UDim2.fromOffset(48, 27),
        Position = UDim2.new(1, -59, 0.5, -13),
        BackgroundColor3 = panel2,
        Text = "OFF",
        TextColor3 = muted,
        TextSize = 10,
        Font = Enum.Font.GothamBold,
        AutoButtonColor = true
    }, row)
    corner(toggle, 8)
    buttons[key] = {Row = row, Toggle = toggle}
    toggle.Activated:Connect(function()
        setState(key, not states[key])
    end)
end

createToggle("fps", "FPS Boost", "Reduce visual effects and shadows", 1)
createToggle("low", "Low Graphics", "Simplified lighting and effects", 2)
createToggle("high", "High Graphics", "Best available client quality", 3)
createToggle("black", "Turn Off 3D Rendering", "Black overlay; game still renders", 4)

make("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 16, 1, -39),
    Size = UDim2.new(1, -32, 0, 26),
    Text = "KYRO  •  VISUAL SETTINGS",
    TextColor3 = Color3.fromRGB(111, 122, 137),
    TextSize = 10,
    Font = Enum.Font.GothamMedium,
    TextXAlignment = Enum.TextXAlignment.Center
}, main)

local originalQuality
pcall(function() originalQuality = settings().Rendering.QualityLevel end)

local function restoreLighting()
    for prop, value in pairs(savedLighting) do
        pcall(function() Lighting[prop] = value end)
    end
    for effect, value in pairs(savedEffects) do
        if effect and effect.Parent then
            pcall(function() effect.Enabled = value end)
        end
    end
end

local function setQuality(level)
    pcall(function()
        settings().Rendering.QualityLevel = level
    end)
end

applyMode = function(key)
    if key == "fps" and states.fps then
        Lighting.GlobalShadows = false
        setPostEffects(false)
    elseif key == "low" and states.low then
        Lighting.GlobalShadows = false
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        setPostEffects(false)
        setQuality(Enum.QualityLevel.Level01)
    elseif key == "high" and states.high then
        -- High settings are limited by Roblox/device settings and may be ignored.
        Lighting.GlobalShadows = true
        Lighting.EnvironmentDiffuseScale = 1
        Lighting.EnvironmentSpecularScale = 1
        setPostEffects(true)
        setQuality(Enum.QualityLevel.Level21)
    elseif key == "black" then
        blackOverlay.Visible = states.black
    end

    -- If a graphics mode is turned off, restore the original client-side visual values.
    if (key == "fps" or key == "low" or key == "high") and not states[key] then
        restoreLighting()
        if originalQuality then setQuality(originalQuality) end
        -- Re-apply any other mode that remains active.
        if states.fps then
            Lighting.GlobalShadows = false
            setPostEffects(false)
        end
        if states.low then
            Lighting.GlobalShadows = false
            Lighting.EnvironmentDiffuseScale = 0
            Lighting.EnvironmentSpecularScale = 0
            setPostEffects(false)
            setQuality(Enum.QualityLevel.Level01)
        end
        if states.high then
            Lighting.GlobalShadows = true
            Lighting.EnvironmentDiffuseScale = 1
            Lighting.EnvironmentSpecularScale = 1
            setPostEffects(true)
            setQuality(Enum.QualityLevel.Level21)
        end
    end
end

-- Re-apply a mode to visual effects added later during gameplay.
local effectWatcher
effectWatcher = Lighting.DescendantAdded:Connect(function(obj)
    if states.fps or states.low then
        if obj:IsA("BloomEffect") or obj:IsA("BlurEffect") or obj:IsA("ColorCorrectionEffect")
            or obj:IsA("DepthOfFieldEffect") or obj:IsA("SunRaysEffect") then
            task.defer(function()
                if obj.Parent and (states.fps or states.low) then
                    pcall(function()
                        if savedEffects[obj] == nil then savedEffects[obj] = obj.Enabled end
                        obj.Enabled = false
                    end)
                end
            end)
        end
    end
end)

local function togglePanel()
    main.Visible = not main.Visible
end
iconButton.Activated:Connect(togglePanel)
close.Activated:Connect(function() main.Visible = false end)

-- Make the floating icon draggable on touch or mouse.
do
    local dragging = false
    local dragStart, startPos
    iconButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = iconButton.Position
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            iconButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

-- Hide the overlay if the UI is destroyed by the game.
gui.Destroying:Connect(function()
    if effectWatcher then effectWatcher:Disconnect() end
    restoreLighting()
end)
