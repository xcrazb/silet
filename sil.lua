-- ============================================================
--  ULTRA FISH FARMER - FINAL BRUTAL EDITION
--  Rapid Fire Multi-Bait (5 UID per burst, parallel chunks)
--  Token Bucket + Adaptive Ping Guard + Smart Sell
--  + AUTO FEEDER 5M + FOOD TRAY 1M + STORM HORN 3M
-- ============================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local VirtualUser       = game:GetService("VirtualUser")
local VIM               = game:GetService("VirtualInputManager")
local Lighting          = game:GetService("Lighting")
local StarterGui        = game:GetService("StarterGui")
local RunService        = game:GetService("RunService")

local player = Players.LocalPlayer

-- ============================================================
--  REMOTES
-- ============================================================
local container = ReplicatedStorage
    :WaitForChild("rbxts_include")
    :WaitForChild("node_modules")
    :WaitForChild("@rbxts")
    :WaitForChild("remo")
    :WaitForChild("src")
    :WaitForChild("container")

local collectAllFishRemote = container:WaitForChild("bait.collectAllFish")
local sellAllFishRemote    = container:WaitForChild("sellFish.sellAllFish")
local placeBuildingRemote  = container:WaitForChild("ponds.placeBuilding")
local stormHornRemote      = container:WaitForChild("gear.useStormHorn", 10)

-- ============================================================
--  PLAYER DATA
-- ============================================================
local playerDataMod
pcall(function()
    playerDataMod = require(ReplicatedStorage.TS.state["player-data"])
end)

local function getPlayerData()
    if not playerDataMod then return nil end
    local ok, d = pcall(function()
        return playerDataMod.getPlayerDataById(tostring(player.UserId))
    end)
    return ok and d or nil
end

local function fetchCurrentPondBaits(onlyWithFish)
    local pd = getPlayerData()
    if not pd or not pd.ponds then return {} end
    local pondId = pd.currentPond
    if not pondId then return {} end
    local pond = pd.ponds[pondId]
    if type(pond) ~= "table" or not pond.baits then return {} end
    local list = {}
    for baitId, baitData in pairs(pond.baits) do
        local fishCount = 0
        if type(baitData) == "table" and baitData.fishes then
            for _ in pairs(baitData.fishes) do fishCount += 1 end
        end
        if (not onlyWithFish) or fishCount > 0 then
            table.insert(list, { id = baitId, fishCount = fishCount })
        end
    end
    table.sort(list, function(a, b) return a.fishCount > b.fishCount end)
    return list
end

-- ============================================================
--  STATE (FINAL BRUTAL)
-- ============================================================
local State = {
    collectOn    = false,
    collectInt   = 0.05,
    collectBurst = 3,
    burstLoop    = 1,      -- chunk-based, tidak perlu burst loop
    fireGap      = 0.08,
    parallelOn   = true,
    collectCnt   = 0,
    collectFail  = 0,
    sellOn       = false,
    sellCnt      = 0,
    baitList     = {},
    lastCycleMs  = 0,

    -- ===== MULTI-BAIT RAPID FIRE =====
    multiBaitEnabled = true,
    multiBaitMin     = 1,
    multiBaitMax     = 2,
    multiBaitCount   = 2,     -- 5 UID per burst

    -- ===== PING GUARD =====
    maxConcurrent   = 4,      -- 4 chunk paralel
    remoteBudget    = 50,     -- 30 remote/detik
    remoteUsed      = 0,
    lastBudgetReset = os.clock(),
    pingMs          = 0,
    adaptiveGap     = 0.05,
    backoffUntil    = 0,

    feederOn     = false,
    foodTrayOn   = false,
    stormHornOn  = false,
}

-- ============================================================
--  ANTI AFK
-- ============================================================
local AntiAfk = { running = false }
local function fireAntiAfk()
    pcall(function()
        VIM:SendKeyEvent(true, Enum.KeyCode.Z, false, game)
        task.wait(0.03)
        VIM:SendKeyEvent(false, Enum.KeyCode.Z, false, game)
    end)
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new(0, 0))
    end)
end
local function startAntiAfk()
    if AntiAfk.running then return end
    AntiAfk.running = true
    task.spawn(function()
        task.wait(1); fireAntiAfk()
        while AntiAfk.running do
            task.wait(60)
            fireAntiAfk()
        end
    end)
end
task.spawn(startAntiAfk)

-- ============================================================
--  TOKEN BUCKET + PING GUARD
-- ============================================================
local function resetBudgetIfNeeded()
    local now = os.clock()
    if now - State.lastBudgetReset >= 1 then
        State.remoteUsed = 0
        State.lastBudgetReset = now
    end
end

local function canFire()
    resetBudgetIfNeeded()
    return State.remoteUsed < State.remoteBudget and os.clock() >= State.backoffUntil
end

local function consumeToken(n)
    State.remoteUsed += (n or 1)
end

-- ============================================================
--  MULTI-BAIT RAPID FIRE CORE
--  Server: FireServer(uid_string) per UID
--  Multi-bait: rapid fire 3-5 UID dalam 1 frame
-- ============================================================
local function fireMultiBait(baitIds)
    local success = 0
    for _, baitId in ipairs(baitIds) do
        local ok = pcall(function()
            collectAllFishRemote:FireServer(tostring(baitId))
        end)
        if ok then success += 1 end
        -- Tidak ada task.wait — rapid dalam 1 frame
    end
    return success > 0, success
end

local function buildBaitChunks(baits)
    local chunks = {}
    local n = math.clamp(State.multiBaitCount, State.multiBaitMin, State.multiBaitMax)
    local i = 1
    while i <= #baits do
        local chunk = {}
        for j = i, math.min(i + n - 1, #baits) do
            table.insert(chunk, baits[j].id)
        end
        table.insert(chunks, chunk)
        i += n
    end
    return chunks
end

-- ============================================================
--  AUTO PLACE FEEDER (5 MENIT LOOP)
-- ============================================================
local function startAutoFeederLoop()
    task.spawn(function()
        while State.feederOn do
            for _, pos in ipairs({
                Vector3.new(75.86299896240234, -0.012000083923339844, 41),
                Vector3.new(75.86299896240234, -0.012000083923339844, -41),
            }) do
                for i = 1, 3 do
                    if not State.feederOn then break end
                    pcall(function()
                        placeBuildingRemote:InvokeServer("booster", "GodlyAutoFeeder", pos)
                    end)
                    task.wait(0.25)
                end
            end
            if State.feederOn then task.wait(300) end
        end
    end)
end

-- ============================================================
--  AUTO PLACE SUPREME FOOD TRAY (1 MENIT LOOP)
-- ============================================================
local function startAutoFoodTrayLoop()
    task.spawn(function()
        while State.foodTrayOn do
            pcall(function()
                placeBuildingRemote:InvokeServer("booster", "SupremeFoodTray", Vector3.new(9.862998962402344, -0.012000083923339844, -10))
            end)
            task.wait(60)
        end
    end)
end

-- ============================================================
--  AUTO STORM HORN (3 MENIT LOOP)
-- ============================================================
local function startAutoStormHornLoop()
    task.spawn(function()
        while State.stormHornOn do
            if stormHornRemote and stormHornRemote:IsA("RemoteEvent") then
                pcall(function()
                    stormHornRemote:FireServer("StormHorn")
                end)
            end
            if State.stormHornOn then task.wait(180) end
        end
    end)
end

-- ============================================================
--  COLLECT BRUTAL — RAPID FIRE CHUNKS
-- ============================================================
local function fireChunkBrutal(chunk)
    if type(chunk) ~= "table" or #chunk == 0 then return end
    if not State.collectOn then return end

    local cost = #chunk
    local guard = 0
    while (State.remoteUsed + cost > State.remoteBudget or os.clock() < State.backoffUntil)
          and State.collectOn and guard < 50 do
        resetBudgetIfNeeded()
        task.wait(0.02); guard += 1
    end
    if not State.collectOn then return end

    consumeToken(cost)

    local t0 = os.clock()
    local ok, sent = fireMultiBait(chunk)
    local ms = (os.clock() - t0) * 1000

    State.pingMs = State.pingMs == 0 and ms or (State.pingMs * 0.7 + ms * 0.3)
    if State.pingMs > 150 then
        State.adaptiveGap = math.min(0.25, State.adaptiveGap + 0.01)
        State.remoteBudget = math.max(10, State.remoteBudget - 1)
    elseif State.pingMs < 80 then
        State.adaptiveGap = math.max(0.03, State.adaptiveGap - 0.005)
        State.remoteBudget = math.min(40, State.remoteBudget + 2)
    end

    if ok then
        State.collectCnt += sent
        State.collectFail = math.max(0, State.collectFail - 1)
    else
        State.collectFail += 1
        State.backoffUntil = os.clock() + 0.3
    end

    task.wait(State.adaptiveGap)
end

local function collectLoopBrutal()
    while State.collectOn do
        local t0 = os.clock()
        local baits = fetchCurrentPondBaits(true)
        State.baitList = baits

        if #baits == 0 then
            task.wait(0.3)
        elseif State.multiBaitEnabled then
            local chunks = buildBaitChunks(baits)

            if State.parallelOn then
                local i = 1
                while i <= #chunks and State.collectOn do
                    local threads = {}
                    local batchEnd = math.min(i + State.maxConcurrent - 1, #chunks)
                    for j = i, batchEnd do
                        if not State.collectOn then break end
                        local chunk = chunks[j]
                        threads[#threads + 1] = task.spawn(function()
                            fireChunkBrutal(chunk)
                        end)
                    end

                    local waited = 0
                    while waited < 2 and State.collectOn do
                        local alive = false
                        for _, th in ipairs(threads) do
                            if coroutine.status(th) ~= "dead" then alive = true; break end
                        end
                        if not alive then break end
                        task.wait(0.02); waited += 0.02
                    end

                    i = batchEnd + 1
                end
            else
                for _, chunk in ipairs(chunks) do
                    if not State.collectOn then break end
                    fireChunkBrutal(chunk)
                end
            end
        else
            for _, b in ipairs(baits) do
                if not State.collectOn then break end
                local guard = 0
                while not canFire() and State.collectOn and guard < 50 do
                    task.wait(0.02); guard += 1
                end
                if not State.collectOn then break end
                consumeToken(1)
                local ok = pcall(function()
                    collectAllFishRemote:FireServer(tostring(b.id))
                end)
                if ok then
                    State.collectCnt += 1
                    State.collectFail = math.max(0, State.collectFail - 1)
                else
                    State.collectFail += 1
                    State.backoffUntil = os.clock() + 0.3
                end
                task.wait(State.adaptiveGap)
            end
        end

        if State.sellOn and State.collectFail >= 3 then
            pcall(function() sellAllFishRemote:FireServer() end)
            State.sellCnt += 1
            State.collectFail = 0
        end

        State.lastCycleMs = (os.clock() - t0) * 1000
        task.wait(State.collectInt)
    end
end

-- ============================================================
--  SMART AUTO SELL
-- ============================================================
local function startAutoSellTimer()
    task.spawn(function()
        local lastSellAtCount = -1
        while State.collectOn do
            if State.sellOn and State.collectCnt ~= lastSellAtCount then
                pcall(function()
                    sellAllFishRemote:FireServer()
                    State.sellCnt += 1
                end)
                lastSellAtCount = State.collectCnt
            end
            task.wait(1)
        end
    end)
end

-- ============================================================
--  SUPER EXTRA FPS BOOST
-- ============================================================
local FPS = {
    active = false, hidden = {}, materials = {}, sounds = {},
    origLighting = {}, origTerrain = {}, origQuality = nil, origFOV = nil, hiddenFolders = {},
}

local Terrain = workspace:FindFirstChildOfClass("Terrain")
local Camera = workspace.CurrentCamera

local function saveLighting()
    FPS.origLighting = {
        GlobalShadows = Lighting.GlobalShadows, ShadowSoftness = Lighting.ShadowSoftness,
        Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
        FogEnd = Lighting.FogEnd, FogStart = Lighting.FogStart, FogColor = Lighting.FogColor,
        EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale, EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
        ExposureCompensation = Lighting.ExposureCompensation, ClockTime = Lighting.ClockTime,
    }
    pcall(function() FPS.origQuality = UserSettings().GameSettings.SavedQualityLevel.Value end)
    if Camera then pcall(function() FPS.origFOV = Camera.FieldOfView end) end
    if Terrain then
        pcall(function()
            FPS.origTerrain = {
                WaterWaveSize = Terrain.WaterWaveSize, WaterWaveSpeed = Terrain.WaterWaveSpeed,
                WaterReflectance = Terrain.WaterReflectance, WaterTransparency = Terrain.WaterTransparency, Decoration = Terrain.Decoration,
            }
        end)
    end
end

local function stripObject(o, char)
    if not o or not o.Parent then return end
    if char and (o == char or o:IsDescendantOf(char)) then return end
    pcall(function()
        local cls = o.ClassName
        if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam" or cls == "Fire" or cls == "Smoke"
           or cls == "Sparkles" or cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight"
           or cls == "Explosion" or cls == "Atmosphere" or cls == "Sky" or cls == "Highlight"
           or cls == "SelectionBox" or cls == "SelectionSphere" then
            if o.Enabled then table.insert(FPS.hidden, {obj = o, prop = "Enabled", val = true}); o.Enabled = false end
        elseif cls == "Decal" or cls == "Texture" then
            if o.Transparency < 1 then table.insert(FPS.hidden, {obj = o, prop = "Transparency", val = o.Transparency}); o.Transparency = 1 end
        elseif cls == "MeshPart" then
            if o.TextureID ~= "" then table.insert(FPS.hidden, {obj = o, prop = "TextureID", val = o.TextureID}); o.TextureID = "" end
            if o.Material ~= Enum.Material.SmoothPlastic then table.insert(FPS.materials, {obj = o, prop = "Material", val = o.Material}); o.Material = Enum.Material.SmoothPlastic end
            if o.CastShadow then table.insert(FPS.hidden, {obj = o, prop = "CastShadow", val = true}); o.CastShadow = false end
        elseif cls == "SurfaceAppearance" then
            if o.Enabled then table.insert(FPS.hidden, {obj = o, prop = "Enabled", val = true}); o.Enabled = false end
        elseif cls == "BasePart" or o:IsA("BasePart") then
            if o.Material ~= Enum.Material.SmoothPlastic then table.insert(FPS.materials, {obj = o, prop = "Material", val = o.Material}); o.Material = Enum.Material.SmoothPlastic end
            if o.CastShadow then table.insert(FPS.hidden, {obj = o, prop = "CastShadow", val = true}); o.CastShadow = false end
        elseif cls == "Sound" then
            if o.Playing then o.Playing = false; table.insert(FPS.sounds, o) end
        end
    end)
end

local function stripCharacter(char)
    if not char then return end
    for _, o in ipairs(char:GetDescendants()) do
        pcall(function()
            local cls = o.ClassName
            if cls == "ParticleEmitter" or cls == "Trail" or cls == "Beam" or cls == "Fire" or cls == "Smoke"
               or cls == "Sparkles" or cls == "PointLight" or cls == "SpotLight" or cls == "SurfaceLight" or cls == "Highlight" then
                if o.Enabled then table.insert(FPS.hidden, {obj = o, prop = "Enabled", val = true}); o.Enabled = false end
            elseif cls == "Decal" or cls == "Texture" then
                if o.Transparency < 1 then table.insert(FPS.hidden, {obj = o, prop = "Transparency", val = o.Transparency}); o.Transparency = 1 end
            end
        end)
    end
end

local function hideGameFolder()
    for _, name in ipairs({"Game", "Effects", "Particles", "VFX", "Decorations"}) do
        local f = workspace:FindFirstChild(name)
        if f then table.insert(FPS.hiddenFolders, {obj = f, parent = f.Parent}); pcall(function() f.Parent = nil end) end
    end
end

local function showGameFolder()
    for _, e in ipairs(FPS.hiddenFolders) do pcall(function() if e.obj then e.obj.Parent = e.parent or workspace end end) end
    FPS.hiddenFolders = {}
end

local function disableCoreGui()
    pcall(function()
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
    end)
end

local function restoreCoreGui()
    pcall(function()
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, true)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, true)
        StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, true)
    end)
end

local function boostFPS()
    if FPS.active then return false end
    FPS.active = true
    FPS.hidden = {}; FPS.materials = {}; FPS.sounds = {}; FPS.hiddenFolders = {}
    pcall(saveLighting)
    pcall(function()
        Lighting.GlobalShadows = false; Lighting.ShadowSoftness = 0
        Lighting.Brightness = 0.5; Lighting.Ambient = Color3.fromRGB(255,255,255)
        Lighting.OutdoorAmbient = Color3.fromRGB(255,255,255); Lighting.FogEnd = 1e6
        Lighting.FogStart = 1e6; Lighting.FogColor = Color3.fromRGB(255,255,255)
        Lighting.EnvironmentDiffuseScale = 0; Lighting.EnvironmentSpecularScale = 0
        Lighting.ExposureCompensation = 0; Lighting.ClockTime = 14
    end)
    for _, e in ipairs(Lighting:GetChildren()) do
        pcall(function()
            if e:IsA("PostEffect") or e:IsA("Atmosphere") or e:IsA("Sky") then
                if e.Enabled ~= nil then table.insert(FPS.hidden, {obj = e, prop = "Enabled", val = true}); e.Enabled = false end
            end
        end)
    end
    if Terrain then
        pcall(function()
            Terrain.WaterWaveSize = 0; Terrain.WaterWaveSpeed = 0
            Terrain.WaterReflectance = 0; Terrain.WaterTransparency = 1; Terrain.Decoration = false
        end)
    end
    pcall(function() UserSettings().GameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1 end)
    if Camera then pcall(function() Camera.FieldOfView = 70 end) end
    hideGameFolder()
    local char = player.Character
    for _, o in ipairs(workspace:GetDescendants()) do stripObject(o, char) end
    stripCharacter(char)
    for _, s in ipairs(workspace:GetDescendants()) do
        pcall(function() if s:IsA("Sound") and s.Playing then s.Playing = false; table.insert(FPS.sounds, s) end end)
    end
    disableCoreGui()
    return true
end

local function unboostFPS()
    if not FPS.active then return false end
    FPS.active = false
    pcall(function() for k, v in pairs(FPS.origLighting) do pcall(function() Lighting[k] = v end) end end)
    if Terrain and FPS.origTerrain then
        pcall(function()
            local t = FPS.origTerrain
            Terrain.WaterWaveSize = t.WaterWaveSize or 0.15; Terrain.WaterWaveSpeed = t.WaterWaveSpeed or 10
            Terrain.WaterReflectance = t.WaterReflectance or 0.1; Terrain.WaterTransparency = t.WaterTransparency or 0.3
            Terrain.Decoration = t.Decoration ~= false
        end)
    end
    pcall(function() if FPS.origQuality then UserSettings().GameSettings.SavedQualityLevel = FPS.origQuality end end)
    if Camera and FPS.origFOV then pcall(function() Camera.FieldOfView = FPS.origFOV end) end
    for _, e in ipairs(FPS.hidden) do pcall(function() if e.obj and e.obj.Parent then e.obj[e.prop] = e.val end end) end
    FPS.hidden = {}
    for _, m in ipairs(FPS.materials) do pcall(function() if m.obj and m.obj.Parent then m.obj[m.prop] = m.val end end) end
    FPS.materials = {}
    for _, s in ipairs(FPS.sounds) do pcall(function() if s and s.Parent then s.Playing = true end end) end
    FPS.sounds = {}
    showGameFolder()
    restoreCoreGui()
    return true
end

-- ============================================================
--  HIDE FISH
-- ============================================================
local HideFish = { active = false, hidden = {}, count = 0 }

local function isFishModel(obj)
    if not obj:IsA("Model") or not obj.Parent then return false end
    local pName = obj.Parent.Name:lower()
    if not pName:find("pond") then return false end
    local n = obj.Name:lower()
    if n == "sardine" or n == "cod" or n == "salmon" or n:find("_gold") or n:find("_silver")
       or n:find("_diamond") or n:find("_radiant") or n:find("_huge") or n:find("_tiny") or n:find("fish") then
        return true
    end
    return false
end

local function hideFish()
    if HideFish.active then return 0 end
    HideFish.hidden = {}
    local count = 0
    for _, obj in ipairs(workspace:GetDescendants()) do
        pcall(function()
            if isFishModel(obj) then
                table.insert(HideFish.hidden, {obj = obj, parent = obj.Parent})
                obj.Parent = nil; count += 1
            end
        end)
    end
    HideFish.active = true; HideFish.count = count; return count
end

local function showFish()
    if not HideFish.active then return 0 end
    local count = 0
    for _, entry in ipairs(HideFish.hidden) do
        pcall(function() if entry.obj then entry.obj.Parent = entry.parent or workspace; count += 1 end end)
    end
    HideFish.hidden = {}; HideFish.active = false; HideFish.count = 0; return count
end

-- ============================================================
--  GUI THEME
-- ============================================================
local C = {
    Bg = Color3.fromRGB(10, 10, 16), Panel = Color3.fromRGB(20, 20, 32),
    Element = Color3.fromRGB(32, 32, 48), Accent = Color3.fromRGB(140, 110, 255),
    Accent2 = Color3.fromRGB(90, 210, 255), Text = Color3.fromRGB(255, 255, 255),
    Sub = Color3.fromRGB(160, 160, 195), Stroke = Color3.fromRGB(60, 60, 90),
    Success = Color3.fromRGB(100, 240, 160), Danger = Color3.fromRGB(255, 100, 120),
    Warn = Color3.fromRGB(255, 180, 80),
}

for _, n in ipairs({"UltraFishGUI", "BrutalFishGUI", "AutoFishGUI"}) do
    local o = player.PlayerGui:FindFirstChild(n)
    if o then o:Destroy() end
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "UltraFishGUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.DisplayOrder = 999
ScreenGui.Parent = player:WaitForChild("PlayerGui")

local Main = Instance.new("Frame")
Main.Size = UDim2.new(0, 340, 0, 0); Main.Position = UDim2.new(0, 20, 0, 20)
Main.BackgroundColor3 = C.Bg; Main.BorderSizePixel = 0; Main.ClipsDescendants = true
Main.Parent = ScreenGui
Instance.new("UICorner", Main).CornerRadius = UDim.new(0, 16)
local ms = Instance.new("UIStroke", Main)
ms.Color = C.Stroke; ms.Thickness = 1.5; ms.Transparency = 0.25

local TopBar = Instance.new("Frame")
TopBar.Size = UDim2.new(1, 0, 0, 54); TopBar.BackgroundColor3 = C.Panel; TopBar.BorderSizePixel = 0; TopBar.Parent = Main
Instance.new("UICorner", TopBar).CornerRadius = UDim.new(0, 16)

local Title = Instance.new("TextLabel", TopBar)
Title.Size = UDim2.new(1, -100, 0, 22); Title.Position = UDim2.new(0, 16, 0, 8)
Title.BackgroundTransparency = 1; Title.Text = "⚡ ULTRA FARMER"
Title.TextColor3 = C.Text; Title.Font = Enum.Font.GothamBlack; Title.TextSize = 16
Title.TextXAlignment = Enum.TextXAlignment.Left

local Subtitle = Instance.new("TextLabel", TopBar)
Subtitle.Size = UDim2.new(1, -100, 0, 14); Subtitle.Position = UDim2.new(0, 16, 0, 32)
Subtitle.BackgroundTransparency = 1; Subtitle.Text = "Rapid Fire x5 UID + Ping Safe"
Subtitle.TextColor3 = C.Sub; Subtitle.Font = Enum.Font.GothamBold; Subtitle.TextSize = 10
Subtitle.TextXAlignment = Enum.TextXAlignment.Left

local FpsCounter = Instance.new("TextLabel", TopBar)
FpsCounter.Size = UDim2.new(0, 44, 0, 22); FpsCounter.Position = UDim2.new(1, -100, 0.5, -11)
FpsCounter.BackgroundColor3 = C.Element; FpsCounter.Text = "-- FPS"
FpsCounter.TextColor3 = C.Success; FpsCounter.Font = Enum.Font.GothamBold; FpsCounter.TextSize = 10; FpsCounter.BorderSizePixel = 0
Instance.new("UICorner", FpsCounter).CornerRadius = UDim.new(0, 6)

local MinBtn = Instance.new("TextButton", TopBar)
MinBtn.Size = UDim2.new(0, 26, 0, 26); MinBtn.Position = UDim2.new(1, -34, 0.5, -13)
MinBtn.BackgroundColor3 = C.Element; MinBtn.Text = "—"; MinBtn.TextColor3 = C.Sub
MinBtn.Font = Enum.Font.GothamBold; MinBtn.TextSize = 14; MinBtn.BorderSizePixel = 0; MinBtn.AutoButtonColor = false
Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(1, 0)

local Body = Instance.new("Frame")
Body.Size = UDim2.new(1, -20, 0, 0); Body.Position = UDim2.new(0, 10, 0, 62)
Body.BackgroundTransparency = 1; Body.Parent = Main
local BodyLayout = Instance.new("UIListLayout", Body)
BodyLayout.Padding = UDim.new(0, 8); BodyLayout.SortOrder = Enum.SortOrder.LayoutOrder

local order = 0
local function nextOrder() order += 1; return order end

local function makeSection(text)
    local f = Instance.new("Frame", Body)
    f.Size = UDim2.new(1, 0, 0, 22); f.BackgroundTransparency = 1; f.LayoutOrder = nextOrder()
    local bar = Instance.new("Frame", f)
    bar.Size = UDim2.new(0, 3, 0, 12); bar.Position = UDim2.new(0, 0, 0.5, -6); bar.BackgroundColor3 = C.Accent2; bar.BorderSizePixel = 0
    Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
    local l = Instance.new("TextLabel", f)
    l.Size = UDim2.new(1, -10, 1, 0); l.Position = UDim2.new(0, 10, 0, 0)
    l.BackgroundTransparency = 1; l.Text = text:upper(); l.TextColor3 = C.Sub; l.Font = Enum.Font.GothamBlack; l.TextSize = 10; l.TextXAlignment = Enum.TextXAlignment.Left
end

local function makeToggle(text, default, callback)
    local toggled = default and true or false
    local f = Instance.new("Frame", Body)
    f.Size = UDim2.new(1, 0, 0, 44); f.BackgroundColor3 = C.Element; f.BackgroundTransparency = 0.25; f.BorderSizePixel = 0; f.LayoutOrder = nextOrder()
    Instance.new("UICorner", f).CornerRadius = UDim.new(0, 9)
    local stroke = Instance.new("UIStroke", f)
    stroke.Color = C.Stroke; stroke.Thickness = 1; stroke.Transparency = 0.5
    local lbl = Instance.new("TextLabel", f)
    lbl.Size = UDim2.new(1, -76, 1, 0); lbl.Position = UDim2.new(0, 14, 0, 0); lbl.BackgroundTransparency = 1
    lbl.Text = text; lbl.TextColor3 = C.Text; lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 12; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextWrapped = true
    local tb = Instance.new("TextButton", f)
    tb.Size = UDim2.new(0, 44, 0, 22); tb.Position = UDim2.new(1, -56, 0.5, -11); tb.BackgroundColor3 = C.Stroke; tb.Text = ""; tb.BorderSizePixel = 0; tb.AutoButtonColor = false
    Instance.new("UICorner", tb).CornerRadius = UDim.new(1, 0)
    local circle = Instance.new("Frame", tb)
    circle.Size = UDim2.new(0, 16, 0, 16); circle.Position = UDim2.new(0, 3, 0.5, -8); circle.BackgroundColor3 = Color3.new(1, 1, 1); circle.BorderSizePixel = 0
    Instance.new("UICorner", circle).CornerRadius = UDim.new(1, 0)
    local function visual(a)
        local pos = toggled and UDim2.new(1, -19, 0.5, -8) or UDim2.new(0, 3, 0.5, -8)
        local col = toggled and C.Accent or C.Stroke
        if a then
            TweenService:Create(circle, TweenInfo.new(0.22, Enum.EasingStyle.Back), {Position=pos}):Play()
            TweenService:Create(tb, TweenInfo.new(0.18), {BackgroundColor3=col}):Play()
            TweenService:Create(stroke, TweenInfo.new(0.18), {Color=toggled and C.Accent or C.Stroke, Transparency=toggled and 0.3 or 0.5}):Play()
        else circle.Position = pos; tb.BackgroundColor3 = col end
    end
    visual(false)
    tb.MouseButton1Click:Connect(function()
        toggled = not toggled; visual(true)
        if callback then callback(toggled) end
    end)
    return {Set=function(v) toggled=v; visual(true) end, Get=function() return toggled end}
end

local function makeStatus(height)
    local l = Instance.new("TextLabel", Body)
    l.Size = UDim2.new(1, 0, 0, height or 50); l.BackgroundColor3 = C.Element; l.BackgroundTransparency = 0.55; l.BorderSizePixel = 0
    l.Text = "..."; l.TextColor3 = C.Success; l.Font = Enum.Font.GothamBold; l.TextSize = 11; l.TextWrapped = true; l.LayoutOrder = nextOrder()
    Instance.new("UICorner", l).CornerRadius = UDim.new(0, 9)
    local pad = Instance.new("UIPadding", l)
    pad.PaddingLeft = UDim.new(0, 10); pad.PaddingRight = UDim.new(0, 10); pad.PaddingTop = UDim.new(0, 4); pad.PaddingBottom = UDim.new(0, 4)
    return l
end

-- ============================================================
--  ISI GUI
-- ============================================================
makeSection("Control Panel")

local toggleCollect = makeToggle("Auto Collect & Auto-Sell", false, function(v)
    State.collectOn = v
    State.sellOn = v
    if v then
        task.spawn(collectLoopBrutal)
        startAutoSellTimer()
    end
end)

local toggleMulti = makeToggle("Multi-Bait Rapid (x5 UID)", true, function(v)
    State.multiBaitEnabled = v
end)

local toggleFeeder = makeToggle("Auto Place Feeder (5m)", false, function(v)
    State.feederOn = v
    if v then startAutoFeederLoop() end
end)

local toggleFoodTray = makeToggle("Auto Place Food Tray (1m)", false, function(v)
    State.foodTrayOn = v
    if v then startAutoFoodTrayLoop() end
end)

local toggleStormHorn = makeToggle("Auto Storm Horn (3m)", false, function(v)
    State.stormHornOn = v
    if v then startAutoStormHornLoop() end
end)

local toggleFPS = makeToggle("Ultra FPS Boost & Hide Fish", false, function(v)
    if v then
        boostFPS()
        hideFish()
    else
        unboostFPS()
        showFish()
    end
end)

local statusLabel = makeStatus(120)

-- ============================================================
--  AUTO ENABLE ALL TOGGLES ON EXECUTE
-- ============================================================
task.spawn(function()
    task.wait(0.5)

    toggleCollect.Set(true)
    State.collectOn = true
    State.sellOn = true
    task.spawn(collectLoopBrutal)
    startAutoSellTimer()
    task.wait(0.1)

    toggleMulti.Set(true)
    State.multiBaitEnabled = true
    task.wait(0.1)

    toggleFeeder.Set(true)
    State.feederOn = true
    startAutoFeederLoop()
    task.wait(0.1)

    toggleFoodTray.Set(true)
    State.foodTrayOn = true
    startAutoFoodTrayLoop()
    task.wait(0.1)

    toggleStormHorn.Set(true)
    State.stormHornOn = true
    startAutoStormHornLoop()
    task.wait(0.1)

    toggleFPS.Set(true)
    boostFPS()
    hideFish()
end)

-- ============================================================
--  LOOP UI & FPS COUNTER
-- ============================================================
local fpsFrames, fpsTime = 0, os.clock()
RunService.RenderStepped:Connect(function()
    fpsFrames += 1
    local now = os.clock()
    if now - fpsTime >= 1 then
        local fpsValue = math.floor(fpsFrames / (now - fpsTime))
        fpsFrames = 0; fpsTime = now
        FpsCounter.Text = fpsValue .. " FPS"
        FpsCounter.TextColor3 = fpsValue >= 50 and C.Success or (fpsValue >= 30 and C.Warn or C.Danger)
    end
end)

task.spawn(function()
    while ScreenGui.Parent do
        statusLabel.Text = string.format(
            "Collected: %d | Sold: %d\nMulti-Bait: %s (%d UID/burst)\nPing: %.0fms | Budget: %d/s | Gap: %.2fs\nBackoff: %s\nFeeder: %s | FoodTray: %s\nStormHorn: %s | FPS: %s",
            State.collectCnt, State.sellCnt,
            State.multiBaitEnabled and "ON" or "OFF",
            State.multiBaitCount,
            State.pingMs, State.remoteBudget, State.adaptiveGap,
            (os.clock() < State.backoffUntil) and "YES" or "no",
            State.feederOn and "ACTIVE" or "OFF",
            State.foodTrayOn and "ACTIVE" or "OFF",
            State.stormHornOn and "ACTIVE" or "OFF",
            FPS.active and "ON" or "OFF"
        )
        task.wait(0.4)
    end
end)

-- ============================================================
--  DRAG + MINIMIZE
-- ============================================================
local dragging, dragStart, startPos
TopBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true; dragStart = input.Position; startPos = Main.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
end)

local minimized = false
local function refreshHeight()
    local h = BodyLayout.AbsoluteContentSize.Y
    local target = minimized and 54 or (62 + h + 12)
    TweenService:Create(Main, TweenInfo.new(0.25, Enum.EasingStyle.Quart), {
        Size = UDim2.new(0, 340, 0, target),
    }):Play()
end
BodyLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(refreshHeight)

MinBtn.MouseButton1Click:Connect(function()
    minimized = not minimized; Body.Visible = not minimized
    MinBtn.Text = minimized and "+" or "—"; refreshHeight()
end)

Main.Size = UDim2.new(0, 0, 0, 0)
task.wait(0.05); refreshHeight()

ScreenGui.AncestryChanged:Connect(function()
    if not ScreenGui.Parent then
        pcall(unboostFPS); pcall(showFish)
    end
end)
