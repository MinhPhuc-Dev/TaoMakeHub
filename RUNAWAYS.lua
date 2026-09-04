if type(gethui) ~= "function" or typeof(gethui()) ~= "Instance" then
    error("[UJ RUNAWAYS] gethui() unavailable - refusing to run.", 0)
end

if _G.UJRunaways and type(_G.UJRunaways.Unload) == "function" then
    pcall(_G.UJRunaways.Unload)
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local Lib = _G.SpeedUiLibrary or loadstring(game:HttpGet("https://raw.githubusercontent.com/MinhPhuc-Dev/TaoMakeHub/refs/heads/main/SpeedUi.lua"), "=SpeedUi")()
_G.SpeedUiLibrary = Lib
local Flow = require(ReplicatedStorage:WaitForChild("FlowClient"))

local WALK_DEFAULT, JUMP_DEFAULT, JUMP_HEIGHT = 15, 50, 7.2
local ACCENT_A = Color3.fromRGB(64, 220, 255)
local ACCENT_B = Color3.fromRGB(150, 110, 255)
local TOGGLE_IMAGE = "rbxassetid://136890595976124"

local F = {
    walkSpeed = WALK_DEFAULT,
    jumpPower = JUMP_DEFAULT,
    flySpeed = 90,
    infJump = false,
    noclip = false,
    fly = false,
    godmode = false,
    antiYeetOff = false,
    fullBright = false,
    aura = false,
    auraRadius = 250,
    steal = false,
    stealCat = "All",
    stealCap = 10,
    bringCat = "All",
    bringCount = 8,
    sellRadius = 400,
    buyName = "",
    buyCount = 1,
    autoWin = false,
    orbital = false,
    orbCat = "All",
    orbCount = 8,
    orbRadius = 16,
    orbSpeed = 6,
    orbRings = 3,
    orbTrails = true,
}
local Stats = {
    blocked = 0,
    saved = nil,
    yeetOff = 0,
    killed = 0,
    stolen = 0,
    brought = 0,
    sold = 0,
    bought = 0,
    orbiting = 0,
}
local UI = {}
local syncToggle
local conns = {}

local function track(c)
    conns[#conns + 1] = c
    return c
end

local SELF_SRC = select(1, debug.info(track, "s"))

local function notify(title, content, time)
    task.spawn(function()
        pcall(function()
            Lib:SetNotification({
                Title = title,
                Description = "UJ RUNAWAYS",
                Content = content,
                Time = time or 4,
            })
        end)
    end)
end
local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do
        o[k] = v
    end
    o.Parent = parent
    return o
end

local function grad(parent, rotation, a, b)
    return mk("UIGradient", { Rotation = rotation, Color = ColorSequence.new(a, b) }, parent)
end

local Hum, Root, HeadCol, RagFlag

local function bindChar(c)
    if not c then
        Hum, Root, HeadCol, RagFlag = nil, nil, nil, nil
        return
    end
    Hum = c:FindFirstChildOfClass("Humanoid")
    Root = c:FindFirstChild("HumanoidRootPart")
    HeadCol = c:FindFirstChild("HeadCollision")
    RagFlag = c:FindFirstChild("IsRagdoll")
end

local RAGDOLL_STATE = Enum.HumanoidStateType.Ragdoll
local FALL_STATE = Enum.HumanoidStateType.FallingDown
local UP_STATE = Enum.HumanoidStateType.GettingUp

local function setRagdollLock(h, locked)
    if not h then return end
    pcall(function()
        h:SetStateEnabled(RAGDOLL_STATE, not locked)
        h:SetStateEnabled(FALL_STATE, not locked)
        h:SetStateEnabled(UP_STATE, true)
    end)
end

local ragConn

local function bindRagWatch()
    if ragConn then
        ragConn:Disconnect()
        ragConn = nil
    end
    if not F.godmode or not RagFlag then return end
    ragConn = RagFlag:GetPropertyChangedSignal("Value"):Connect(function()
        task.defer(function()
            if not F.godmode then return end
            local h = Hum
            if not h or not h.Parent then return end
            setRagdollLock(h, true)
            local st = h:GetState()
            if st == RAGDOLL_STATE or st == FALL_STATE then
                h:ChangeState(UP_STATE)
            end
        end)
    end)
end

bindChar(LP.Character)

local pulse

local function step()
    local h = Hum
    if not h or not h.Parent then return end
    if F.godmode then
        if h.Health < h.MaxHealth then
            h.Health = h.MaxHealth
        end
        local st = h:GetState()
        if st == RAGDOLL_STATE or st == FALL_STATE then
            h:ChangeState(UP_STATE)
        end
    end
    if F.walkSpeed ~= WALK_DEFAULT and h.WalkSpeed ~= F.walkSpeed then
        h.WalkSpeed = F.walkSpeed
    end
    if F.jumpPower ~= JUMP_DEFAULT then
        if not h.UseJumpPower then h.UseJumpPower = true end
        if h.JumpPower ~= F.jumpPower then h.JumpPower = F.jumpPower end
    end
    if F.noclip then
        if Root and Root.CanCollide then Root.CanCollide = false end
        if HeadCol and HeadCol.CanCollide then HeadCol.CanCollide = false end
    end
end
local function syncPulse()
    local want = F.godmode or F.noclip
        or F.walkSpeed ~= WALK_DEFAULT or F.jumpPower ~= JUMP_DEFAULT
    if want and not pulse then
        pulse = RunService.Heartbeat:Connect(step)
    elseif not want and pulse then
        pulse:Disconnect()
        pulse = nil
    end
end

local origTakeDamage

local function setGodmode(on)
    local pd = Flow and Flow.PlayerDamage
    if type(pd) ~= "table" or type(pd.TakeDamage) ~= "function" then
        F.godmode = false
        syncPulse()
        return false
    end
    F.godmode = on and true or false
    if F.godmode then
        if not origTakeDamage then
            origTakeDamage = pd.TakeDamage
            local ok = pcall(function()
                pd.TakeDamage = function()
                    Stats.blocked += 1
                end
            end)
            if not ok then
                origTakeDamage = nil
                F.godmode = false
                syncPulse()
                return false
            end
        end
        if Hum then
            pcall(function() Hum.Health = Hum.MaxHealth end)
        end
        setRagdollLock(Hum, true)
    elseif origTakeDamage then
        pcall(function() pd.TakeDamage = origTakeDamage end)
        origTakeDamage = nil
        setRagdollLock(Hum, false)
    else
        setRagdollLock(Hum, false)
    end
    bindRagWatch()
    syncPulse()
    return true
end

local CollectionService = game:GetService("CollectionService")

local function npcList()
    local list, seen = {}, {}
    local folder = workspace:FindFirstChild("NPCs")
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            local h = m:FindFirstChildOfClass("Humanoid")
            if h and not seen[h] then
                seen[h] = true
                list[#list + 1] = { h, m }
            end
        end
    end
    for _, m in ipairs(CollectionService:GetTagged("NPC")) do
        if m:IsDescendantOf(workspace) then
            local h = m:FindFirstChildOfClass("Humanoid")
            if h and not seen[h] then
                seen[h] = true
                list[#list + 1] = { h, m }
            end
        end
    end
    return list
end

local function killNear(radius)
    local root = Root
    local npcs = Flow and Flow.NPCs
    if not root or not root.Parent then return 0 end
    if type(npcs) ~= "table" or type(npcs.Damage) ~= "function" then return 0 end
    local origin = root.Position
    local hit = 0
    for _, e in ipairs(npcList()) do
        local h, m = e[1], e[2]
        local pp = m.PrimaryPart or m:FindFirstChild("HumanoidRootPart") or h.RootPart
        if h.Health > 0 and pp and (pp.Position - origin).Magnitude <= radius then
            if pcall(npcs.Damage, h, h.Health + 25) then
                hit += 1
                Stats.killed += 1
            end
        end
    end
    return hit
end

local function setNoclip(on)
    F.noclip = on and true or false
    if not F.noclip then
        if Root then Root.CanCollide = true end
        if HeadCol then HeadCol.CanCollide = true end
    end
    syncPulse()
end

local function setWalkSpeed(n)
    F.walkSpeed = math.clamp(tonumber(n) or WALK_DEFAULT, 5, 350)
    if F.walkSpeed == WALK_DEFAULT and Hum then
        Hum.WalkSpeed = WALK_DEFAULT
    end
    syncPulse()
end

local function setJumpPower(n)
    F.jumpPower = math.clamp(tonumber(n) or JUMP_DEFAULT, 20, 350)
    if F.jumpPower == JUMP_DEFAULT and Hum then
        Hum.UseJumpPower = false
        Hum.JumpHeight = JUMP_HEIGHT
    end
    syncPulse()
end

local hopping = false

local function jumpVelocity()
    local h = Hum
    if not h then return 0 end
    if h.UseJumpPower then return h.JumpPower end
    return math.sqrt(2 * math.max(workspace.Gravity, 1) * h.JumpHeight)
end

local function hop()
    if hopping then return end
    hopping = true
    local vel = jumpVelocity()
    local y = Root and Root.Position.Y or 0
    local t0 = os.clock()
    while os.clock() - t0 < 0.25 do
        if not F.infJump or F.fly then break end
        local r = Root
        if not r or not r.Parent then break end
        local dt = RunService.Heartbeat:Wait()
        y += vel * dt
        local p = r.Position
        r.CFrame = CFrame.new(p.X, y, p.Z) * r.CFrame.Rotation
    end
    hopping = false
end

track(UIS.JumpRequest:Connect(function()
    if not F.infJump or F.fly or hopping then return end
    if Hum and Root and Hum.Health > 0 then
        Hum:ChangeState(Enum.HumanoidStateType.Jumping)
        task.spawn(hop)
    end
end))

local Controls do
    local ok, res = pcall(function()
        return require(LP.PlayerScripts:WaitForChild("PlayerModule", 10)):GetControls()
    end)
    Controls = ok and res or nil
end

local function moveVector()
    if Controls then
        local ok, v = pcall(function() return Controls:GetMoveVector() end)
        if ok and typeof(v) == "Vector3" then return v end
    end
    local v = Vector3.zero
    if UIS:IsKeyDown(Enum.KeyCode.W) then v -= Vector3.zAxis end
    if UIS:IsKeyDown(Enum.KeyCode.S) then v += Vector3.zAxis end
    if UIS:IsKeyDown(Enum.KeyCode.A) then v -= Vector3.xAxis end
    if UIS:IsKeyDown(Enum.KeyCode.D) then v += Vector3.xAxis end
    return v
end
local function keyDown(...)
    for _, k in ipairs({ ... }) do
        if UIS:IsKeyDown(k) then return true end
    end
    return false
end

local flyConn, flyPos

local function flyStep(dt)
    local root = Root
    if not root or not root.Parent then return end
    if not flyPos or (root.Position - flyPos).Magnitude > 25 then
        flyPos = root.Position
    end
    local camCF = workspace.CurrentCamera.CFrame
    local mv = moveVector()
    local dir = camCF.RightVector * mv.X - camCF.LookVector * mv.Z
    if keyDown(Enum.KeyCode.Space, Enum.KeyCode.E) then dir += Vector3.yAxis end
    if keyDown(Enum.KeyCode.LeftControl, Enum.KeyCode.Q) then dir -= Vector3.yAxis end
    local speed = F.flySpeed * (keyDown(Enum.KeyCode.LeftShift) and 2 or 1)
    if dir.Magnitude > 0.05 then
        flyPos += dir.Unit * (speed * math.min(dt, 0.1))
    end
    root.CFrame = CFrame.new(flyPos) * root.CFrame.Rotation
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
end

local function setFly(on)
    if on then
        if not Hum or not Root then
            F.fly = false
            return false
        end
        F.fly = true
        flyPos = nil
        Hum.PlatformStand = true
        if not flyConn then
            flyConn = RunService.RenderStepped:Connect(flyStep)
        end
    else
        F.fly = false
        flyPos = nil
        if flyConn then
            flyConn:Disconnect()
            flyConn = nil
        end
        if Hum then
            Hum.PlatformStand = false
            Hum:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end
    return true
end
local yeetOff = {}

local function setAntiYeet(on)
    if not on then
        for c in pairs(yeetOff) do
            pcall(function() c:Enable() end)
        end
        yeetOff = {}
        Stats.yeetOff = 0
        F.antiYeetOff = false
        return true
    end
    if type(getconnections) ~= "function" then return false end
    local ok, cs = pcall(getconnections, RunService.Heartbeat)
    if not ok then return false end
    local n = 0
    for _, c in ipairs(cs) do
        if type(c.Function) == "function" then
            local ok2, src = pcall(debug.info, c.Function, "s")
            if ok2 and type(src) == "string" and src:find("AntiYeetClient", 1, true) then
                if yeetOff[c] or pcall(function() c:Disable() end) then
                    yeetOff[c] = true
                end
            end
        end
    end
    for _ in pairs(yeetOff) do n += 1 end
    Stats.yeetOff = n
    F.antiYeetOff = n > 0
    return F.antiYeetOff
end

local lightBackup

local function setFullBright(on)
    F.fullBright = on and true or false
    if F.fullBright then
        if not lightBackup then
            lightBackup = {
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                Brightness = Lighting.Brightness,
                ClockTime = Lighting.ClockTime,
                FogStart = Lighting.FogStart,
                FogEnd = Lighting.FogEnd,
                GlobalShadows = Lighting.GlobalShadows,
            }
        end
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogStart = 0
        Lighting.FogEnd = 1e6
        Lighting.GlobalShadows = false
    elseif lightBackup then
        for k, v in pairs(lightBackup) do
            pcall(function() Lighting[k] = v end)
        end
        lightBackup = nil
    end
end
local function savePos()
    if not Root then return end
    Stats.saved = Root.CFrame
    local p = Root.Position
    notify("Position saved", ("%d, %d, %d"):format(p.X, p.Y, p.Z), 3)
end

local function returnPos()
    if not Root or not Stats.saved then return end
    Root.CFrame = Stats.saved + Vector3.new(0, 3, 0)
    Root.AssemblyLinearVelocity = Vector3.zero
end

local LOOT_TYPES = {
    "All",
    "Valuable",
    "Painting",
    "Electronic",
    "BigElectronic",
    "Household",
    "Junk",
    "Food",
    "Medical",
    "Tool",
}
local GATE_Z = 83700
local GATE_PAST = 80
local GATE_STOP = 120
local GATE_LIFT = 5
local GATE_POLL = 0.5
local ROAD_TTL = 1
local ROAD_NEAR = 800
local STEP_Z = 200
local STEP_WAIT = 0.05
local STEP_LIFT = 4
local RUN_MAX = 150
local HOLD_WAIT = 0.06
local HOLD_MAX = 420
local ARM_MAX = 6
local ARM_TRIES = 2
local ARM_WAIT = 0.3
local ARM_IDLE = 6
local ARM_SPOTS = {
    Vector3.new(3, 2, 2),
    Vector3.new(3, 2, -2),
    Vector3.new(0, 2, 3),
    Vector3.new(-3, 2, 2),
    Vector3.new(6, 2, 0),
}
local SELL = {
    max = 40,
    place = 10,
    step = 0.05,
    enable = 25,
    pay = 30,
    tries = 2,
    off = Vector3.new(2, 1, 3),
}
local SHOP = {
    keep = 500,
    tries = 3,
    wait = 0.45,
    pay = 25,
    off = Vector3.new(0, 3, 0),
}
local FINISH = {
    past = 600,
    back = 200,
    step = 45,
    wait = 0.25,
    jog = 6,
    max = 90,
}

local LootData
pcall(function()
    LootData = require(ReplicatedStorage:WaitForChild("Data")).Loot
end)

local function firePrompt(p)
    if type(fireproximityprompt) ~= "function" or not p or not p.Parent then return false end
    pcall(function()
        p.RequiresLineOfSight = false
        p.HoldDuration = 0
    end)
    return (pcall(fireproximityprompt, p))
end

local function lootFn(name)
    local t = Flow and Flow.Loot
    if type(t) ~= "table" or type(t[name]) ~= "function" then return nil end
    return t[name]
end

local function itemInfo(name)
    if not LootData then return nil, 0 end
    local cat, val
    pcall(function() cat = LootData.GetCategory(name) end)
    pcall(function() val = LootData.GetItemValue(name) end)
    return cat, tonumber(val) or 0
end

local function partOf(m)
    if m:IsA("BasePart") then return m end
    local h = m:FindFirstChild("Handle")
    if h and h:IsA("BasePart") then return h end
    return m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")
end

local function lootList()
    local out = {}
    for _, m in ipairs(CollectionService:GetTagged("Equippable")) do
        if m:IsDescendantOf(workspace) and not m:IsA("Tool") then
            local p = partOf(m)
            if p then
                local cat, val = itemInfo(m.Name)
                out[#out + 1] = { model = m, part = p, cat = cat, val = val }
            end
        end
    end
    return out
end

local pawnCache, buyCache

local function shopList()
    local map = workspace:FindFirstChild("Map")
    local b = map and map:FindFirstChild("Buildings")
    local out = {}
    for _, m in ipairs(b and b:GetChildren() or {}) do
        if m.Name == "PawnShop" then
            local ok, cf = pcall(function() return m:GetPivot() end)
            local d = math.huge
            if ok and Root then d = (cf.Position - Root.Position).Magnitude end
            out[#out + 1] = { model = m, dist = d }
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

local function pawnShop()
    local list = shopList()
    for _, s in ipairs(list) do
        if s.model:FindFirstChild("CallBell", true) then return s.model end
    end
    return list[1] and list[1].model
end

local function pawnRefs()
    if pawnCache and pawnCache.volume.Parent and pawnCache.prompt.Parent then
        if not Root or (pawnCache.volume.Position - Root.Position).Magnitude < SHOP.keep then
            return pawnCache
        end
    end
    for _, s in ipairs(shopList()) do
        local counter = s.model:FindFirstChild("PawnCounter", true)
        local volume = counter and counter:FindFirstChild("Volume", true)
        local bell = s.model:FindFirstChild("CallBell", true)
        local prompt = bell and bell:FindFirstChildWhichIsA("ProximityPrompt", true)
        if volume and prompt then
            pawnCache = { shop = s.model, volume = volume, prompt = prompt, counter = counter }
            return pawnCache
        end
    end
    return nil
end

local function buyRefs()
    if buyCache and buyCache.count > 0 and buyCache.probe.Parent then
        if not Root or (buyCache.probe.Position - Root.Position).Magnitude < SHOP.keep then
            return buyCache
        end
    end
    for _, s in ipairs(shopList()) do
        local map, order, n, probe = {}, {}, 0, nil
        for _, d in ipairs(s.model:GetDescendants()) do
            if d:IsA("BasePart") and d.Name == "BuyableItem" then
                local name = d:GetAttribute("ItemName")
                local prompt = d:FindFirstChildWhichIsA("ProximityPrompt", true)
                if name and prompt and not map[name] then
                    map[name] = { part = d, prompt = prompt }
                    order[#order + 1] = name
                    probe = d
                    n += 1
                end
            end
        end
        if n > 0 then
            table.sort(order)
            buyCache = { map = map, order = order, count = n, shop = s.model, probe = probe }
            return buyCache
        end
    end
    return nil
end

local function ownLoot(part)
    local own = lootFn("OwnNetworkRequestAsync") or lootFn("OwnNetworkRequest")
    if not own then return false end
    return (pcall(own, part, true))
end

local function pickLoot(cat, count, radius, skip)
    local picks = {}
    local origin = Root and Root.Position
    for _, e in ipairs(lootList()) do
        local ok = cat == "All" or e.cat == cat
        if ok and skip and skip[e.model] then ok = false end
        if ok and radius and origin and (e.part.Position - origin).Magnitude > radius then ok = false end
        if ok then picks[#picks + 1] = e end
    end
    table.sort(picks, function(a, b) return a.val > b.val end)
    while #picks > count do
        table.remove(picks)
    end
    return picks
end

local function promptPos(p)
    local host = p.Parent
    if not host then return nil end
    if host:IsA("Attachment") then return host.WorldPosition end
    if host:IsA("BasePart") then return host.Position end
    return nil
end

local function backpackCount()
    local n = 0
    local b = LP:FindFirstChildOfClass("Backpack")
    for _, t in ipairs(b and b:GetChildren() or {}) do
        if t:IsA("Tool") then n += 1 end
    end
    for _, t in ipairs(LP.Character and LP.Character:GetChildren() or {}) do
        if t:IsA("Tool") then n += 1 end
    end
    return n
end

local function dropBackpack()
    local unequip = lootFn("LootUnequip")
    local b = LP:FindFirstChildOfClass("Backpack")
    if not unequip or not b then return 0 end
    if Hum then pcall(function() Hum:UnequipTools() end) end
    local n = 0
    for _, t in ipairs(b:GetChildren()) do
        if t:IsA("Tool") and not t:HasTag("Undroppable") then
            if pcall(unequip, t, t:HasTag("RemoteOnly")) then n += 1 end
            task.wait(0.12)
        end
    end
    return n
end

local function partsOf(m)
    local out = {}
    if m:IsA("BasePart") then
        out[1] = m
        return out
    end
    if m.PrimaryPart then out[#out + 1] = m.PrimaryPart end
    for _, d in ipairs(m:GetChildren()) do
        if d:IsA("BasePart") and d ~= m.PrimaryPart then out[#out + 1] = d end
    end
    return out
end

local function reachPart(p)
    if not Root then return false end
    for _ = 1, 10 do
        if not p.Parent or not Root.Parent then return false end
        Root.CFrame = CFrame.new(p.Position + Vector3.new(0, 3.5, 2.5), p.Position)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.15)
        if (p.Position - Root.Position).Magnitude < 6 then return true end
    end
    return false
end

local grabFull = false

local function grabOnce(cat, radius, skip)
    local equip = lootFn("LootEquip")
    if not equip or not Root then return false end
    local picks = pickLoot(cat, 1, radius, skip)
    local e = picks[1]
    if not e then return false end
    if skip then skip[e.model] = true end
    if not reachPart(e.part) then return false end
    for _, p in ipairs(partsOf(e.model)) do
        local ok, res = pcall(equip, p)
        if ok and res == "Success" then return true end
        if ok and res == "InventoryFull" then
            grabFull = true
            return false
        end
        task.wait(0.1)
    end
    return false
end

local function cashValue()
    local ls = LP:FindFirstChild("leaderstats")
    if not ls then return 0 end
    for _, s in ipairs(ls:GetChildren()) do
        if string.find(s.Name, "Cash", 1, true) then return tonumber(s.Value) or 0 end
    end
    return 0
end

local function sellStand(refs)
    local p = promptPos(refs.prompt) or refs.volume.Position
    return CFrame.new(p + SELL.off, refs.volume.Position)
end

local function sellList(cat, radius, refs, origin)
    local out, seen = {}, {}
    local shop = (refs and refs.shop) or pawnShop()
    origin = origin or (Root and Root.Position) or (refs and refs.volume.Position)
    local folder = workspace:FindFirstChild("Loot")
    local function push(m)
        if seen[m] or m:IsA("Tool") or not m:IsDescendantOf(workspace) then return end
        seen[m] = true
        if m:HasTag("BuyableLoot") or m:HasTag("Undroppable") then return end
        if shop and m:IsDescendantOf(shop) then return end
        local p = partOf(m)
        if not p or p.Anchored then return end
        local c, v = itemInfo(m.Name)
        if cat ~= "All" and c ~= cat then return end
        if radius and origin and (p.Position - origin).Magnitude > radius then return end
        out[#out + 1] = { model = m, part = p, cat = c, val = v }
    end
    for _, m in ipairs(folder and folder:GetChildren() or {}) do
        if not m:IsA("BasePart") then push(m) end
    end
    for _, m in ipairs(CollectionService:GetTagged("Draggable")) do
        push(m)
    end
    table.sort(out, function(a, b) return a.val > b.val end)
    return out
end

local function sellOne(refs, e)
    local own = lootFn("OwnNetworkRequestAsync")
    local release = lootFn("OwnNetworkRequest")
    if not own or not Root then return false end
    local stand = sellStand(refs)
    for _ = 1, SELL.tries do
        local part = e.part
        if not (part and part.Parent and Root and Root.Parent) then return false end
        if not reachPart(part) then return false end
        local ok, res = pcall(own, part, true)
        if ok and res then
            local c0 = cashValue()
            for _ = 1, SELL.place do
                if not (part.Parent and Root and Root.Parent) then break end
                Root.CFrame = stand
                Root.AssemblyLinearVelocity = Vector3.zero
                part.CFrame = refs.volume.CFrame
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
                task.wait(SELL.step)
            end
            local ready = false
            for _ = 1, SELL.enable do
                if not refs.prompt.Parent then return false end
                if refs.prompt.Enabled then
                    ready = true
                    break
                end
                if part.Parent then part.CFrame = refs.volume.CFrame end
                task.wait(0.1)
            end
            if ready then
                firePrompt(refs.prompt)
                for _ = 1, SELL.pay do
                    task.wait(0.1)
                    local c = cashValue()
                    if c ~= c0 then return true, c - c0 end
                    if not part.Parent then return true, 0 end
                end
            end
        end
        if release and e.part and e.part.Parent then pcall(release, e.part, nil) end
        task.wait(0.2)
    end
    return false
end

local bringRunning = false

local function homeReturn(cf)
    if not cf or not Root or not Root.Parent then return end
    for _ = 1, 6 do
        Root.CFrame = cf
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        task.wait(0.12)
        if (cf.Position - Root.Position).Magnitude < 6 then break end
    end
end

local function bringItems(cat, count)
    if bringRunning or not Root then return 0 end
    bringRunning = true
    local home = Root.CFrame
    local want = math.max(tonumber(count) or 1, 1)
    local skip, fetched, dropped, dry = {}, 0, 0, 0
    while fetched < want do
        grabFull = false
        local got = 0
        while fetched + got < want and backpackCount() < 10 and not grabFull do
            if not grabOnce(cat, nil, skip) then break end
            got += 1
            task.wait(0.1)
        end
        fetched += got
        if backpackCount() == 0 then break end
        homeReturn(home)
        task.wait(0.25)
        dropped += dropBackpack()
        if got == 0 then
            dry += 1
            if dry > 1 then break end
        else
            dry = 0
        end
    end
    homeReturn(home)
    Stats.brought += dropped
    bringRunning = false
    return dropped
end

local function sellLoot(cat, dropFirst)
    local refs = pawnRefs()
    if not refs then return 0, "pawn shop not loaded" end
    if not Root then return 0, "no character" end
    if not lootFn("OwnNetworkRequestAsync") then return 0, "loot api missing" end
    local back = Root.CFrame
    local stand = sellStand(refs)
    local radius = math.max(tonumber(F.sellRadius) or 400, 150)
    local seen, picks = {}, {}
    local function add(list)
        for _, e in ipairs(list) do
            if not seen[e.model] then
                seen[e.model] = true
                picks[#picks + 1] = e
            end
        end
    end
    add(sellList(cat, radius, refs, back.Position))
    if dropFirst or backpackCount() > 0 then
        homeReturn(stand)
        dropBackpack()
        task.wait(0.45)
        add(sellList(cat, 150, refs, refs.volume.Position))
    end
    table.sort(picks, function(a, b) return a.val > b.val end)
    local sold, gained = 0, 0
    for i = 1, math.min(#picks, SELL.max) do
        if not (Root and Root.Parent) then break end
        local ok, delta = sellOne(refs, picks[i])
        if ok then
            sold += 1
            gained += delta or 0
        end
    end
    homeReturn(back)
    Stats.sold += sold
    if sold == 0 then
        return 0, (#picks == 0) and "no loot in range" or "counter refused the items"
    end
    return sold, nil, gained
end

local function buyItem(name, count)
    local function entryOf()
        local refs = buyRefs()
        return refs and refs.map[name] or nil
    end
    local function priceOf(prompt)
        local d = string.gsub(prompt.ActionText or "", "%D", "")
        return tonumber(d) or 0
    end
    local function once()
        local err = "shop not loaded"
        for _ = 1, SHOP.tries do
            local e = entryOf()
            if not e then
                task.wait(0.5)
            elseif not (Root and Root.Parent) then
                return false, 0, "no character"
            else
                local price = priceOf(e.prompt)
                local c0 = cashValue()
                if price > 0 and c0 < price then return false, 0, "need $" .. price end
                Root.CFrame = CFrame.new(e.part.Position + SHOP.off)
                Root.AssemblyLinearVelocity = Vector3.zero
                task.wait(SHOP.wait)
                if e.prompt.Parent and e.prompt.Enabled then
                    firePrompt(e.prompt)
                    for _ = 1, SHOP.pay do
                        task.wait(0.1)
                        local c = cashValue()
                        if c < c0 then return true, c0 - c end
                    end
                    err = "purchase refused"
                else
                    err = "prompt off"
                end
            end
        end
        return false, 0, err
    end
    if not Root then return 0, "no character" end
    local refs = buyRefs()
    if not refs then return 0, "shop not loaded" end
    if not refs.map[name] then return 0, "item not found" end
    local back = Root.CFrame
    local n, spent, err = 0, 0, nil
    for _ = 1, math.max(tonumber(count) or 1, 1) do
        local ok, cost, e = once()
        if not ok then
            err = e
            break
        end
        n += 1
        spent += cost
    end
    if Root and Root.Parent then
        Root.CFrame = back
        Root.AssemblyLinearVelocity = Vector3.zero
    end
    Stats.bought += n
    if n == 0 then return 0, err end
    return n, nil, spent
end

local orbItems = {}
local orbConn = nil
local orbClock = 0

local function orbPartsOf(m)
    local out = {}
    if m:IsA("BasePart") then
        out[1] = m
        return out
    end
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("BasePart") then out[#out + 1] = d end
    end
    return out
end

local function orbPose(m, cf)
    if m:IsA("BasePart") then
        m.CFrame = cf
    else
        m:PivotTo(cf)
    end
end

local function orbSettle(it)
    local first = it.parts[1] and it.parts[1].part
    if not first or not first.Parent then return end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ex = { it.model }
    if LP.Character then ex[#ex + 1] = LP.Character end
    params.FilterDescendantsInstances = ex
    local r = workspace:Raycast(first.Position, Vector3.new(0, -800, 0), params)
    if not r then return end
    pcall(orbPose, it.model, CFrame.new(r.Position + Vector3.new(0, 2, 0)))
end

local function orbRelease()
    if orbConn then
        orbConn:Disconnect()
        orbConn = nil
    end
    local n = #orbItems
    for _, it in ipairs(orbItems) do
        orbSettle(it)
        for _, r in ipairs(it.parts) do
            if r.part.Parent then
                pcall(function()
                    r.part.Anchored = r.anchored
                    r.part.CanCollide = r.collide
                    r.part.AssemblyLinearVelocity = Vector3.zero
                    r.part.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
        for _, o in ipairs(it.fx) do
            pcall(function() o:Destroy() end)
        end
    end
    orbItems = {}
    Stats.orbiting = 0
    return n
end

local function orbTrail(main)
    local fx = {}
    if not F.orbTrails or not main then return fx end
    local h = math.max(main.Size.Y, 1) * 0.5
    local a0 = mk("Attachment", { Name = "UJOrbA", Position = Vector3.new(0, h, 0) }, main)
    local a1 = mk("Attachment", { Name = "UJOrbB", Position = Vector3.new(0, -h, 0) }, main)
    local tr = mk("Trail", {
        Name = "UJOrbTrail",
        Attachment0 = a0,
        Attachment1 = a1,
        Lifetime = 0.6,
        MinLength = 0,
        FaceCamera = true,
        LightEmission = 1,
        LightInfluence = 0,
        WidthScale = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 1),
            NumberSequenceKeypoint.new(1, 0),
        }),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.1),
            NumberSequenceKeypoint.new(1, 1),
        }),
        Color = ColorSequence.new(ACCENT_A, ACCENT_B),
    }, main)
    fx[1], fx[2], fx[3] = a0, a1, tr
    return fx
end

local function orbStep(dt)
    if not Root or not Root.Parent then
        F.orbital = false
        orbRelease()
        return
    end
    orbClock += dt * (F.orbSpeed * 0.22)
    local center = Root.Position + Vector3.new(0, 3.5, 0)
    local live = 0
    for _, it in ipairs(orbItems) do
        if it.model.Parent then
            live += 1
            local spin = orbClock * it.rate + it.phase
            local axis = CFrame.Angles(0, orbClock * it.drift, 0) * CFrame.Angles(it.tilt, 0, it.roll)
            local ring = axis * Vector3.new(math.cos(spin) * F.orbRadius, 0, math.sin(spin) * F.orbRadius)
            pcall(orbPose, it.model, CFrame.new(center + ring) * CFrame.Angles(orbClock * 1.7, orbClock * 2.3, orbClock * 1.1))
        end
    end
    Stats.orbiting = live
end

local function orbCapture(cat, count)
    if not Root then return 0 end
    local want = math.max(tonumber(count) or 1, 1)
    local rings = math.clamp(math.floor(tonumber(F.orbRings) or 3), 1, 4)
    local held = {}
    for _, it in ipairs(orbItems) do
        held[it.model] = true
    end
    local picks = pickLoot(cat, want, nil, held)
    for i, e in ipairs(picks) do
        local r = ((i - 1) % rings) + 1
        local rec = {
            model = e.model,
            parts = {},
            fx = {},
            tilt = (r - 0.5) * math.pi / rings,
            roll = (r - 0.5) * math.pi / (rings * 2),
            drift = 0.18 + r * 0.14,
            rate = 1 + r * 0.25,
            phase = (i / math.max(#picks, 1)) * math.pi * 2,
        }
        for _, p in ipairs(orbPartsOf(e.model)) do
            rec.parts[#rec.parts + 1] = { part = p, anchored = p.Anchored, collide = p.CanCollide }
        end
        ownLoot(e.part)
        for _, s in ipairs(rec.parts) do
            pcall(function()
                s.part.CanCollide = false
                s.part.Anchored = true
            end)
        end
        rec.fx = orbTrail(e.part)
        orbItems[#orbItems + 1] = rec
    end
    return #picks
end

local function setOrbital(on)
    if on then
        if not Root then return false, "no character" end
        orbCapture(F.orbCat, F.orbCount)
        if #orbItems == 0 then return false, "no items in range" end
        F.orbital = true
        if not orbConn then
            orbClock = 0
            orbConn = track(RunService.RenderStepped:Connect(orbStep))
        end
        return true, #orbItems
    end
    F.orbital = false
    return true, orbRelease()
end

local auraRunning = false

local function auraBody()
    auraRunning = true
    while F.aura do
        pcall(killNear, F.auraRadius)
        task.wait(0.25)
    end
    auraRunning = false
end

local function setAura(on)
    local npcs = Flow and Flow.NPCs
    if type(npcs) ~= "table" or type(npcs.Damage) ~= "function" then
        F.aura = false
        return false
    end
    F.aura = on and true or false
    if F.aura and not auraRunning then
        task.spawn(auraBody)
    end
    return true
end

local stealRunning = false

local function stealOnce(cat, skip)
    grabFull = false
    if grabOnce(cat, nil, skip) then
        Stats.stolen += 1
        return true
    end
    return false
end

local function stealBody()
    stealRunning = true
    local skip, idle = {}, 0
    local home = Root and Root.CFrame
    while F.steal do
        if grabFull or backpackCount() >= F.stealCap then
            grabFull = false
            task.wait(1.5)
        elseif stealOnce(F.stealCat, skip) then
            idle = 0
            task.wait(0.15)
        else
            idle += 1
            if idle > 8 then
                skip = {}
                idle = 0
            end
            task.wait(0.35)
        end
    end
    if home and Root and Root.Parent then
        Root.CFrame = home
        Root.AssemblyLinearVelocity = Vector3.zero
    end
    stealRunning = false
end

local function setSteal(on)
    if not lootFn("LootEquip") then
        F.steal = false
        return false
    end
    F.steal = on and true or false
    if F.steal and not stealRunning then
        task.spawn(stealBody)
    end
    return true
end

local winRunning = false

local function endFrame()
    local pg = LP:FindFirstChild("PlayerGui")
    local g = pg and pg:FindFirstChild("EndFrame")
    if g and g:IsA("ScreenGui") and g.Enabled then return g end
    return nil
end

local function gameEnded()
    return endFrame() ~= nil
end

local function gameWon()
    local g = endFrame()
    if not g then return false end
    local f = g:FindFirstChild("Frame")
    local o = f and f:FindFirstChild("Outcome")
    local esc = o and o:FindFirstChild("Escaped")
    return esc ~= nil and esc.Visible
end

local roadCache, roadStamp = nil, 0

local function roadNodes(force)
    if roadCache and not force and tick() - roadStamp < ROAD_TTL then return roadCache end
    local map = workspace:FindFirstChild("Map")
    local g = map and map:FindFirstChild("Ground")
    local r = g and g:FindFirstChild("Road")
    if not r then return roadCache end
    local n = {}
    for _, d in ipairs(r:GetDescendants()) do
        if d:IsA("BasePart") and d.Size.X >= 40 and d.Size.X <= 160 and d.Size.Z >= 80 then
            n[#n + 1] = { x = d.Position.X, y = d.Position.Y + d.Size.Y / 2, z = d.Position.Z }
        end
    end
    if #n == 0 then return roadCache end
    table.sort(n, function(a, b) return a.z < b.z end)
    roadCache, roadStamp = n, tick()
    return n
end

local function roadAt(z)
    local n = roadNodes()
    if n and (z < n[1].z - ROAD_NEAR or z > n[#n].z + ROAD_NEAR) then n = roadNodes(true) end
    if not n then return nil end
    local lo, hi = 1, #n
    while lo < hi do
        local mid = (lo + hi) // 2
        if n[mid].z < z then lo = mid + 1 else hi = mid end
    end
    local a, b = n[math.max(1, lo - 1)], n[lo]
    if math.abs(a.z - z) <= math.abs(b.z - z) then return a end
    return b
end

local function finalDoorPart()
    local map = workspace:FindFirstChild("Map")
    local b = map and map:FindFirstChild("Buildings")
    if not b then return nil end
    local best, score
    for _, c in ipairs(b:GetChildren()) do
        if c.Name == "CustomsFinal" then
            local cb = c:FindFirstChild("CustomsBuilding")
            local fd = cb and cb:FindFirstChild("FinalDoor")
            local dr = fd and fd:FindFirstChild("DoorR")
            local door = dr and dr:FindFirstChild("Door")
            if door and door:IsA("BasePart") then
                local r = roadAt(door.Position.Z)
                local s = r and (math.abs(door.Position.Y - r.y) + math.abs(door.Position.X - r.x))
                    or math.abs(door.Position.Z - GATE_Z)
                if not score or s < score then best, score = door, s end
            end
        end
    end
    return best
end

local function gateInfo()
    local dr = finalDoorPart()
    if not dr then return nil end
    local fd = dr.Parent.Parent
    local dl = fd:FindFirstChild("DoorL")
    dl = dl and dl:FindFirstChild("Door")
    local gap = 0
    local x = dr.Position.X
    if dl then
        gap = (dl.Position.X - dl.Size.X / 2) - (dr.Position.X + dr.Size.X / 2)
        x = (dr.Position.X + dl.Position.X) / 2
    end
    local lbl = fd:FindFirstChild("Timer")
    lbl = lbl and lbl:FindFirstChild("SurfaceGui")
    lbl = lbl and lbl:FindFirstChild("Timer")
    lbl = lbl and lbl:FindFirstChild("Time")
    local r = roadAt(dr.Position.Z)
    return {
        door = fd,
        x = x,
        y = r and r.y or (dr.Position.Y - dr.Size.Y / 2),
        z = dr.Position.Z,
        gap = gap,
        open = gap > 8,
        time = lbl and lbl.Text or "",
    }
end

local function customsPrompt()
    local dr = finalDoorPart()
    local cmd = dr and dr.Parent.Parent:FindFirstChild("Command")
    return cmd and cmd:FindFirstChildWhichIsA("ProximityPrompt", true) or nil
end

local function pressPrompt(p)
    if fireproximityprompt then
        local ok = pcall(fireproximityprompt, p)
        if ok then return true end
    end
    return (pcall(function()
        p:InputHoldBegin()
        task.wait(math.max(p.HoldDuration, 0.05))
        p:InputHoldEnd()
    end))
end

local function pokeConsole(trip)
    local p = customsPrompt()
    local part = p and p.Parent
    if not (part and part:IsA("BasePart")) then return false end
    if not (Root and Root.Parent) then return false end
    local off = ARM_SPOTS[(trip - 1) % #ARM_SPOTS + 1]
    for _ = 1, ARM_TRIES do
        if not (F.autoWin and Root and Root.Parent) then return false end
        if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
        Root.CFrame = CFrame.new(part.Position + off)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        task.wait(ARM_WAIT)
        pressPrompt(p)
    end
    return true
end

local function runTo(targetZ)
    if not (Root and Root.Parent) then return false, "no character" end
    local t0, tg = tick(), 0
    local z = Root.Position.Z
    local x, y = Root.Position.X, Root.Position.Y
    while F.autoWin do
        if gameEnded() then return true end
        if tick() - t0 > RUN_MAX then return false, "route timed out" end
        if not (Root and Root.Parent) then return false, "character lost" end
        if tick() - tg > GATE_POLL then
            tg = tick()
            local g = gateInfo()
            if g then targetZ = g.z - GATE_STOP end
        end
        z = math.min(z + STEP_Z, targetZ)
        local r = roadAt(z)
        if r and math.abs(r.z - z) < ROAD_NEAR then x, y = r.x, r.y + STEP_LIFT end
        if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
        Root.CFrame = CFrame.new(x, y, z)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        if z >= targetZ then return true end
        task.wait(STEP_WAIT)
    end
    return false, "cancelled"
end

local function holdAtGate(x, y, z)
    local t0 = tick()
    local tg = 0
    local wasOpen = false
    local lastTime, lastStamp, trips = nil, tick(), 0
    while F.autoWin do
        if gameEnded() then return true end
        if tick() - t0 > HOLD_MAX then return false, "border did not open in time" end
        if tick() - tg > GATE_POLL then
            tg = tick()
            local g = gateInfo()
            if g then
                x, y, z = g.x, g.y + GATE_LIFT, g.z + GATE_PAST
                if g.open and not wasOpen then
                    wasOpen = true
                    notify("Auto Win", "border open", 3)
                end
                if g.time ~= lastTime then
                    lastTime, lastStamp = g.time, tick()
                end
                if not g.open and tick() - lastStamp > ARM_IDLE and trips < ARM_MAX then
                    trips = trips + 1
                    notify("Auto Win", "starting the border countdown", 3)
                    pokeConsole(trips)
                    lastStamp = tick()
                end
            end
        end
        if not (Root and Root.Parent) then return false, "character lost" end
        if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
        Root.CFrame = CFrame.new(x, y, z)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        task.wait(HOLD_WAIT)
    end
    return gameEnded(), "cancelled"
end

local function finishRun(gz)
    local t0 = tick()
    local z = gz - FINISH.back
    local flip = 1
    while F.autoWin do
        if gameEnded() then return true end
        if tick() - t0 > FINISH.max then return false, "no finish trigger" end
        if not (Root and Root.Parent) then return false, "character lost" end
        if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
        local x, y = Root.Position.X, Root.Position.Y
        local r = roadAt(z)
        if r then x, y = r.x, r.y + STEP_LIFT end
        Root.CFrame = CFrame.new(x + flip * FINISH.jog, y, z)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        flip = -flip
        if z < gz + FINISH.past then z = z + FINISH.step end
        task.wait(FINISH.wait)
    end
    return gameEnded(), "cancelled"
end

local function autoWinBody()
    winRunning = true
    if not F.antiYeetOff then setAntiYeet(true) end
    if not F.godmode then setGodmode(true) end
    syncToggle(UI.God, F.godmode)
    syncToggle(UI.Yeet, F.antiYeetOff)
    if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
    notify("Auto Win", "heading for the border", 4)
    local ok, err = runTo(GATE_Z)
    local g = gateInfo()
    if ok and not gameEnded() then
        if g then
            notify("Auto Win", g.time ~= "" and ("border opens in " .. g.time) or "waiting at the border", 5)
            ok, err = holdAtGate(g.x, g.y + GATE_LIFT, g.z + GATE_PAST)
        else
            ok, err = false, "border not found"
        end
    end
    if F.autoWin and not gameEnded() then
        notify("Auto Win", "crossing into Mexico", 4)
        ok, err = finishRun((g and g.z) or GATE_Z)
    end
    if gameWon() then
        notify("Auto Win", "escaped", 8)
    elseif gameEnded() then
        notify("Auto Win", "run ended without escaping", 8)
    elseif F.autoWin then
        notify("Auto Win", err or "no outcome at the border", 6)
    end
    F.autoWin = false
    pcall(function() UI.AutoWin:Set(false) end)
    winRunning = false
end

local function setAutoWin(on)
    F.autoWin = on and true or false
    if F.autoWin and not winRunning then
        task.spawn(autoWinBody)
    end
    return true
end

track(LP.CharacterAdded:Connect(function(c)
    task.spawn(function()
        c:WaitForChild("Humanoid", 10)
        c:WaitForChild("HumanoidRootPart", 10)
        c:WaitForChild("HeadCollision", 5)
        task.wait(0.6)
        bindChar(c)
        if F.godmode then setRagdollLock(Hum, true) end
        bindRagWatch()
        if F.antiYeetOff then setAntiYeet(true) end
        if F.fly then setFly(true) end
        syncPulse()
    end)
end))

local guiBefore = {}
for _, v in ipairs(gethui():GetChildren()) do
    guiBefore[v] = true
end

local Window = Lib:CreateWindow({
    Title = "UNKNOWN JOURNEY",
    Description = "RUNAWAYS",
    ["Tab Width"] = 132,
    SizeUi = UDim2.fromOffset(620, 400),
})

local MyGuis = {}
local MyGui
for _, v in ipairs(gethui():GetChildren()) do
    if not guiBefore[v] and v:IsA("ScreenGui") then
        MyGuis[#MyGuis + 1] = v
        if not MyGui and v:FindFirstChild("Main", true) then MyGui = v end
    end
end
MyGui = MyGui or MyGuis[1]

track(gethui().ChildAdded:Connect(function(v)
    if not v:IsA("ScreenGui") then return end
    task.defer(function()
        if v.Parent and v:FindFirstChild("NotificationLayout") then
            MyGuis[#MyGuis + 1] = v
        end
    end)
end))
local function styleWindow()
    if not MyGui then return end
    local main = MyGui:FindFirstChild("Main", true)
    if not main then return end
    pcall(function()
        main.BackgroundColor3 = Color3.fromRGB(11, 12, 16)
        main.BackgroundTransparency = 0.04
        local c = main:FindFirstChildOfClass("UICorner")
        if c then c.CornerRadius = UDim.new(0, 12) end
        local s = main:FindFirstChildOfClass("UIStroke")
        if s then
            s.Color = Color3.fromRGB(38, 42, 54)
            s.Thickness = 1.2
        end
        grad(main, 90, Color3.fromRGB(22, 24, 32), Color3.fromRGB(11, 12, 16))
    end)

    local top = main:FindFirstChild("Top")
    if not top then return end

    local hair = mk("Frame", {
        Name = "UJAccent",
        BorderSizePixel = 0,
        Size = UDim2.new(1, -24, 0, 2),
        Position = UDim2.new(0, 12, 1, -1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        ZIndex = 5,
    }, top)
    mk("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, ACCENT_A),
            ColorSequenceKeypoint.new(0.5, ACCENT_B),
            ColorSequenceKeypoint.new(1, ACCENT_A),
        }),
        Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.75),
            NumberSequenceKeypoint.new(0.5, 0),
            NumberSequenceKeypoint.new(1, 0.75),
        }),
    }, hair)

    local badge = mk("Frame", {
        Name = "UJLogo",
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 10, 0.5, 0),
        Size = UDim2.fromOffset(26, 26),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 6,
    }, top)
    mk("UICorner", { CornerRadius = UDim.new(0, 8) }, badge)
    grad(badge, 35, ACCENT_A, ACCENT_B)
    local mono = mk("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Font = Enum.Font.GothamBlack,
        Text = "UJ",
        TextSize = 13,
        TextColor3 = Color3.fromRGB(8, 10, 14),
        ZIndex = 7,
    }, badge)

    local labels = {}
    for _, c in ipairs(top:GetChildren()) do
        if c:IsA("TextLabel") and c ~= mono then
            labels[#labels + 1] = c
        end
    end
    table.sort(labels, function(a, b) return a.Position.X.Offset < b.Position.X.Offset end)

    local name, sub = labels[1], labels[2]
    if name then
        name.Font = Enum.Font.GothamBlack
        name.TextSize = 13
        name.TextColor3 = Color3.fromRGB(240, 244, 255)
        name.Position = UDim2.new(0, 44, 0, 0)
        name.Size = UDim2.new(0, 128, 1, 0)
    end
    if sub then
        sub.Font = Enum.Font.GothamMedium
        sub.TextSize = 12
        sub.TextColor3 = ACCENT_A
        sub.Position = UDim2.new(0, 176, 0, 0)
        sub.Size = UDim2.new(1, -286, 1, 0)
    end

    for _, n in ipairs({ "Close", "Min" }) do
        local b = top:FindFirstChild(n)
        if b and b:IsA("TextButton") then
            b.BackgroundTransparency = 0.86
            b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
            b.Size = UDim2.fromOffset(22, 22)
            b.Font = Enum.Font.GothamBold
            b.TextSize = 13
            mk("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
            local hot = n == "Close" and Color3.fromRGB(255, 92, 108) or ACCENT_A
            track(b.MouseEnter:Connect(function()
                b.BackgroundColor3 = hot
                b.BackgroundTransparency = 0.25
            end))
            track(b.MouseLeave:Connect(function()
                b.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
                b.BackgroundTransparency = 0.86
            end))
        end
    end
end
local ToggleBtn
local LibToggleGui
local libToggleConns = {}
local alive = true

local function stripToggle(btn)
    for _, n in ipairs({ "UJGlow", "UJRing", "UJCore", "UJMark", "UJDot" }) do
        local o = btn:FindFirstChild(n)
        if o then o:Destroy() end
    end
    local s = btn:FindFirstChildOfClass("UIScale")
    if s then s:Destroy() end
end

local function findToggle()
    local kids = gethui():GetChildren()
    for i = #kids, 1, -1 do
        local g = kids[i]
        if g:IsA("ScreenGui") and g ~= MyGui then
            local b = g:FindFirstChildOfClass("ImageButton")
            if b and (b.Image == TOGGLE_IMAGE or b:FindFirstChild("UJRing")) then
                if b:FindFirstChild("UJRing") then stripToggle(b) end
                LibToggleGui = g
                return b
            end
        end
    end
end

local function makeToggle()
    local g = mk("ScreenGui", {
        Name = "UJToggleGui",
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        ResetOnSpawn = false,
        DisplayOrder = 12,
    }, gethui())
    MyGuis[#MyGuis + 1] = g
    local b = mk("ImageButton", {
        Name = "UJToggle",
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Image = TOGGLE_IMAGE,
        Position = UDim2.fromOffset(28, 140),
        Size = UDim2.fromOffset(52, 52),
    }, g)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, b)
    return b
end

local function anyActive()
    return F.fly or F.godmode or F.noclip or F.infJump or F.antiYeetOff or F.fullBright
        or F.walkSpeed ~= WALK_DEFAULT or F.jumpPower ~= JUMP_DEFAULT
end

local function modernToggle()
    local btn = findToggle() or makeToggle()
    if not btn then return false end
    ToggleBtn = btn

    btn.Image = ""
    btn.ImageTransparency = 1
    btn.BackgroundTransparency = 1
    btn.AutoButtonColor = false
    btn.Size = UDim2.fromOffset(52, 52)
    local oc = btn:FindFirstChildOfClass("UICorner")
    if oc then oc.CornerRadius = UDim.new(1, 0) end

    local scale = mk("UIScale", { Scale = 1 }, btn)
    local glow = mk("Frame", {
        Name = "UJGlow",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(1.34, 1.34),
        BackgroundColor3 = ACCENT_A,
        BackgroundTransparency = 0.82,
        BorderSizePixel = 0,
        ZIndex = 1,
    }, btn)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, glow)
    grad(glow, 45, ACCENT_A, ACCENT_B)
    local ring = mk("Frame", {
        Name = "UJRing",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromScale(1, 1),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        ZIndex = 2,
    }, btn)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, ring)
    grad(ring, 35, ACCENT_A, ACCENT_B)

    local core = mk("Frame", {
        Name = "UJCore",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.new(1, -4, 1, -4),
        BackgroundColor3 = Color3.fromRGB(11, 12, 16),
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        ZIndex = 3,
    }, btn)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, core)
    grad(core, 90, Color3.fromRGB(26, 28, 38), Color3.fromRGB(10, 11, 15))

    local mark = mk("TextLabel", {
        Name = "UJMark",
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.fromScale(0, 0.02),
        Font = Enum.Font.GothamBlack,
        Text = "UJ",
        TextSize = 17,
        TextColor3 = Color3.fromRGB(238, 244, 255),
        ZIndex = 4,
    }, core)
    grad(mark, 25, ACCENT_A, ACCENT_B)

    local dot = mk("Frame", {
        Name = "UJDot",
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 1, -9),
        Size = UDim2.fromOffset(6, 6),
        BackgroundColor3 = Color3.fromRGB(120, 130, 150),
        BorderSizePixel = 0,
        ZIndex = 5,
    }, core)
    mk("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
    local quick = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    local function to(obj, props, info)
        pcall(function() TweenService:Create(obj, info or quick, props):Play() end)
    end

    local hovering = false

    track(btn.MouseEnter:Connect(function()
        hovering = true
        to(scale, { Scale = 1.08 })
        to(glow, { BackgroundTransparency = 0.62, Size = UDim2.fromScale(1.46, 1.46) })
    end))
    track(btn.MouseLeave:Connect(function()
        hovering = false
        to(scale, { Scale = 1 })
        to(glow, { BackgroundTransparency = 0.82, Size = UDim2.fromScale(1.34, 1.34) })
    end))
    track(btn.MouseButton1Down:Connect(function()
        to(scale, { Scale = 0.93 }, TweenInfo.new(0.08))
    end))
    track(btn.MouseButton1Up:Connect(function()
        to(scale, { Scale = 1.08 }, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
    end))

    task.spawn(function()
        while alive and btn.Parent do
            local live = anyActive()
            local breathe = 0.72 + 0.12 * math.sin(os.clock() * 1.9)
            pcall(function()
                if not hovering then
                    glow.BackgroundTransparency = live and breathe or 0.86
                end
                glow.BackgroundColor3 = live and ACCENT_A or Color3.fromRGB(90, 96, 112)
                dot.BackgroundColor3 = live
                    and Color3.fromRGB(96, 240, 150)
                    or Color3.fromRGB(120, 130, 150)
            end)
            task.wait(0.06)
        end
    end)
    return true
end

pcall(styleWindow)
pcall(modernToggle)
local function killConns(signal, bucket)
    if type(getconnections) ~= "function" then return end
    pcall(function()
        for _, c in ipairs(getconnections(signal)) do
            local mine = false
            pcall(function() mine = select(1, debug.info(c.Function, "s")) == SELF_SRC end)
            if not mine then
                if c.Disable then
                    pcall(function() c:Disable() end)
                    if bucket then bucket[#bucket + 1] = c end
                else
                    pcall(function() c:Disconnect() end)
                end
            end
        end
    end)
end

local function clampToScreen(target, x, y)
    local vw, vh = 1920, 1080
    pcall(function()
        local s = target.Parent.AbsoluteSize
        if s.X > 0 then vw, vh = s.X, s.Y end
    end)
    local w, h = target.AbsoluteSize.X, target.AbsoluteSize.Y
    local dx, dy = 0, 0
    local vis = target:FindFirstChild("DropShadow")
    if vis and vis:IsA("GuiObject") and vis.AbsoluteSize.X > 0 then
        dx = vis.AbsolutePosition.X - target.AbsolutePosition.X
        dy = vis.AbsolutePosition.Y - target.AbsolutePosition.Y
        w, h = vis.AbsoluteSize.X, vis.AbsoluteSize.Y
    end
    return math.clamp(x + dx, -w + 90, vw - 90) - dx,
        math.clamp(y + dy, 0, vh - math.min(40, h)) - dy
end

local function betterDrag(handle, target, state, bucket)
    if not handle or not target then return end
    killConns(handle.InputBegan, bucket)
    killConns(handle.InputChanged, bucket)

    local dragging, grabAt, startPos = false, nil, nil

    track(handle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        if state then state.movedAt = nil end
        grabAt = input.Position
        local ps = target.Parent and target.Parent.AbsoluteSize or Vector2.new(1920, 1080)
        local p = target.Position
        startPos = Vector2.new(
            p.X.Scale * ps.X + p.X.Offset,
            p.Y.Scale * ps.Y + p.Y.Offset)
    end))
    track(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))

    track(UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = input.Position - grabAt
        if state and (math.abs(d.X) > 5 or math.abs(d.Y) > 5) then state.movedAt = os.clock() end
        local x, y = clampToScreen(target, startPos.X + d.X, startPos.Y + d.Y)
        target.Position = UDim2.fromOffset(x, y)
    end))
end

local function addResizeGrip()
    if not MyGui then return end
    local main = MyGui:FindFirstChild("Main", true)
    if not main then return end
    local shadow = main.Parent
    local holder = shadow and shadow.Parent
    if not holder then return end

    local grip = mk("TextButton", {
        Name = "UJResize",
        AnchorPoint = Vector2.new(1, 1),
        Position = UDim2.new(1, -3, 1, -3),
        Size = UDim2.fromOffset(18, 18),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
        ZIndex = 20,
    }, main)

    for i = 1, 3 do
        local bar = mk("Frame", {
            AnchorPoint = Vector2.new(1, 1),
            Position = UDim2.new(1, 0, 1, -(i - 1) * 5),
            Size = UDim2.fromOffset(3 + (3 - i) * 5, 2),
            BackgroundColor3 = ACCENT_A,
            BackgroundTransparency = 0.45,
            BorderSizePixel = 0,
        }, grip)
        mk("UICorner", { CornerRadius = UDim.new(1, 0) }, bar)
    end

    local sizing, grabAt, startSize, startHold = false, nil, nil, nil
    track(grip.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        sizing = true
        grabAt = input.Position
        startSize = Vector2.new(main.AbsoluteSize.X, main.AbsoluteSize.Y)
        startHold = holder.Position
    end))

    track(UIS.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sizing = false
        end
    end))

    track(UIS.InputChanged:Connect(function(input)
        if not sizing then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local vp = MyGui.AbsoluteSize
        local maxW = math.max(470, (vp.X > 0 and vp.X or 1920) - 20)
        local maxH = math.max(300, (vp.Y > 0 and vp.Y or 1080) - 20)
        local d = input.Position - grabAt
        local w = math.clamp(startSize.X + d.X, 470, maxW)
        local h = math.clamp(startSize.Y + d.Y, 300, maxH)
        local size = UDim2.fromOffset(w, h)
        shadow.Size = size
        main.Size = size
        holder.Position = UDim2.new(
            startHold.X.Scale, startHold.X.Offset + (w - startSize.X) / 2,
            startHold.Y.Scale, startHold.Y.Offset + (h - startSize.Y) / 2)
    end))

    track(grip.MouseEnter:Connect(function()
        for _, b in ipairs(grip:GetChildren()) do
            if b:IsA("Frame") then b.BackgroundTransparency = 0.1 end
        end
    end))
    track(grip.MouseLeave:Connect(function()
        if sizing then return end
        for _, b in ipairs(grip:GetChildren()) do
            if b:IsA("Frame") then b.BackgroundTransparency = 0.45 end
        end
    end))
end
local function resetWindow()
    if not MyGui then return end
    local main = MyGui:FindFirstChild("Main", true)
    if not main then return end
    local shadow = main.Parent
    local holder = shadow and shadow.Parent
    if not holder then return end
    pcall(function()
        local size = UDim2.fromOffset(620, 400)
        main.Size = size
        shadow.Size = size
        local vp = MyGui.AbsoluteSize
        local hs = holder.AbsoluteSize
        holder.Position = UDim2.fromOffset(
            math.floor((vp.X > 0 and vp.X or 1920) / 2 - hs.X / 2),
            math.floor((vp.Y > 0 and vp.Y or 1080) / 2 - hs.Y / 2))
    end)
end

pcall(function()
    local main = MyGui and MyGui:FindFirstChild("Main", true)
    if main then betterDrag(main:FindFirstChild("Top"), main.Parent.Parent) end
end)

local function holderOf()
    local main = MyGui and MyGui:FindFirstChild("Main", true)
    local shadow = main and main.Parent
    return shadow and shadow.Parent
end

local function wireToggle()
    local btn = ToggleBtn
    if not btn then return end
    local dragState = {}
    betterDrag(btn, btn, dragState, libToggleConns)
    killConns(btn.Activated, libToggleConns)
    killConns(btn.MouseButton1Click, libToggleConns)

    local gui = btn.Parent
    if gui and gui:IsA("ScreenGui") then
        gui.Enabled = true
        gui.DisplayOrder = 12
    end
    btn.Visible = true

    track(btn.Activated:Connect(function()
        if dragState.movedAt and os.clock() - dragState.movedAt < 0.2 then return end
        local h = holderOf()
        if not h then return end
        local want = not h.Visible
        h.Visible = want
        task.defer(function()
            local h2 = holderOf()
            if h2 then h2.Visible = want end
            if btn.Parent then btn.Visible = true end
        end)
    end))
end

pcall(wireToggle)
pcall(addResizeGrip)

local syncing = false

function syncToggle(o, v)
    syncing = true
    pcall(function() o:Set(v) end)
    syncing = false
end

local TabLocal = Window:CreateTab({ Name = "Local", Icon = "rbxassetid://7733715400" })
local TabAuto = Window:CreateTab({ Name = "Escape", Icon = "rbxassetid://7733954611" })
local TabFun = Window:CreateTab({ Name = "Fun", Icon = "rbxassetid://7734053495" })
local TabWindow = Window:CreateTab({ Name = "Window", Icon = "rbxassetid://7733964370" })

local SecMove = TabLocal:AddSection("Movement", true)

UI.Walk = SecMove:AddSlider({
    Title = "Walk Speed",
    Increment = 1,
    Min = 5,
    Max = 350,
    Default = WALK_DEFAULT,
    Callback = setWalkSpeed,
})
UI.Jump = SecMove:AddSlider({
    Title = "Jump Power",
    Increment = 1,
    Min = 20,
    Max = 350,
    Default = JUMP_DEFAULT,
    Callback = setJumpPower,
})

UI.InfJump = SecMove:AddToggle({
    Title = "Infinite Jump",
    Default = false,
    Callback = function(v)
        F.infJump = v and true or false
    end,
})

UI.Noclip = SecMove:AddToggle({
    Title = "No Clip",
    Default = false,
    Callback = function(v)
        setNoclip(v)
    end,
})

local SecFly = TabLocal:AddSection("Fly   ( Space up  -  Ctrl down  -  Shift x2 )", true)

UI.Fly = SecFly:AddToggle({
    Title = "Fly",
    Default = false,
    Callback = function(v)
        if syncing then return end
        if not setFly(v and true or false) then syncToggle(UI.Fly, false) end
    end,
})

UI.FlySpeed = SecFly:AddSlider({
    Title = "Fly Speed",
    Increment = 5,
    Min = 10,
    Max = 400,
    Default = 90,
    Callback = function(v)
        F.flySpeed = tonumber(v) or 90
    end,
})
local SecSurv = TabLocal:AddSection("Survival", true)

UI.God = SecSurv:AddToggle({
    Title = "Godmode",
    Default = false,
    Callback = function(v)
        if syncing then return end
        if not setGodmode(v and true or false) then syncToggle(UI.God, false) end
    end,
})

UI.Yeet = SecSurv:AddToggle({
    Title = "Disable Anti-Yeet",
    Default = false,
    Callback = function(v)
        if syncing then return end
        if not setAntiYeet(v and true or false) then syncToggle(UI.Yeet, false) end
    end,
})

local SecUtil = TabLocal:AddSection("Utility", false)

UI.Bright = SecUtil:AddToggle({
    Title = "Full Bright",
    Default = false,
    Callback = setFullBright,
})

SecUtil:AddButton({ Title = "Save Position", Callback = savePos })
SecUtil:AddButton({ Title = "Return To Saved", Callback = returnPos })

local SecEscape = TabAuto:AddSection("Escape", true)

UI.AutoWin = SecEscape:AddToggle({
    Title = "Auto Win   ( drive main vehicle to Mexico )",
    Default = false,
    Callback = function(v)
        if syncing then return end
        setAutoWin(v and true or false)
    end,
})

SecEscape:AddButton({
    Title = "Open Customs Door",
    Callback = function()
        local p = customsPrompt()
        if not p then
            notify("Escape", "customs not loaded", 3)
            return
        end
        notify("Escape", firePrompt(p) and "command sent" or "command failed", 3)
    end,
})

local SecAura = TabAuto:AddSection("Kill Aura", true)

UI.Aura = SecAura:AddToggle({
    Title = "Kill Aura",
    Default = false,
    Callback = function(v)
        if syncing then return end
        if not setAura(v and true or false) then syncToggle(UI.Aura, false) end
    end,
})

UI.AuraRadius = SecAura:AddSlider({
    Title = "Aura Radius",
    Increment = 25,
    Min = 50,
    Max = 2000,
    Default = 250,
    Callback = function(v)
        F.auraRadius = math.clamp(tonumber(v) or 250, 50, 2000)
    end,
})

SecAura:AddButton({
    Title = "Kill NPCs In Radius",
    Callback = function()
        local n = killNear(F.auraRadius)
        notify("Kill Aura", n .. " hit", 3)
    end,
})

local SecLoot = TabAuto:AddSection("Loot", true)

UI.BringCat = SecLoot:AddDropdown({
    Title = "Item Type",
    Options = LOOT_TYPES,
    Default = { "All" },
    Callback = function(v)
        local pick = (type(v) == "table" and v[1]) or tostring(v)
        F.bringCat = pick
        F.stealCat = pick
    end,
})

UI.BringCount = SecLoot:AddSlider({
    Title = "Bring Amount",
    Increment = 1,
    Min = 1,
    Max = 30,
    Default = 8,
    Callback = function(v)
        F.bringCount = math.clamp(tonumber(v) or 8, 1, 30)
    end,
})

SecLoot:AddButton({
    Title = "Bring Items",
    Callback = function()
        local n = bringItems(F.bringCat, F.bringCount)
        notify("Bring Item", n .. " x " .. F.bringCat, 3)
    end,
})

UI.Steal = SecLoot:AddToggle({
    Title = "Auto Steal   ( fills backpack )",
    Default = false,
    Callback = function(v)
        if syncing then return end
        if not setSteal(v and true or false) then syncToggle(UI.Steal, false) end
    end,
})

UI.StealCap = SecLoot:AddSlider({
    Title = "Backpack Limit",
    Increment = 1,
    Min = 1,
    Max = 30,
    Default = 10,
    Callback = function(v)
        F.stealCap = math.clamp(tonumber(v) or 10, 1, 30)
    end,
})

local SecShop = TabAuto:AddSection("Pawn Shop", true)

UI.SellRadius = SecShop:AddSlider({
    Title = "Sell Radius",
    Increment = 50,
    Min = 50,
    Max = 5000,
    Default = 400,
    Callback = function(v)
        F.sellRadius = math.clamp(tonumber(v) or 400, 50, 5000)
    end,
})

SecShop:AddButton({
    Title = "Auto Sell   ( nearby loot )",
    Callback = function()
        task.spawn(function()
            local n, err, cash = sellLoot(F.bringCat, false)
            notify("Auto Sell", err or (n .. " sold   $" .. (cash or 0)), 4)
        end)
    end,
})

SecShop:AddButton({
    Title = "Auto Sell Backpack",
    Callback = function()
        task.spawn(function()
            local n, err, cash = sellLoot("All", true)
            notify("Auto Sell", err or (n .. " sold   $" .. (cash or 0)), 4)
        end)
    end,
})

UI.BuyName = SecShop:AddDropdown({
    Title = "Shop Item",
    Options = { "-" },
    Default = { "-" },
    Callback = function(v)
        F.buyName = (type(v) == "table" and v[1]) or tostring(v)
    end,
})

UI.BuyCount = SecShop:AddSlider({
    Title = "Buy Amount",
    Increment = 1,
    Min = 1,
    Max = 20,
    Default = 1,
    Callback = function(v)
        F.buyCount = math.clamp(tonumber(v) or 1, 1, 20)
    end,
})

local function refreshShop()
    local refs = buyRefs()
    if not refs or refs.count == 0 then
        notify("Auto Buy", "pawn shop not loaded", 3)
        return 0
    end
    pcall(function() UI.BuyName:Refresh(refs.order, { refs.order[1] }) end)
    F.buyName = refs.order[1]
    return refs.count
end

SecShop:AddButton({
    Title = "Refresh Shop Items",
    Callback = function()
        local n = refreshShop()
        if n > 0 then notify("Auto Buy", n .. " items", 3) end
    end,
})

SecShop:AddButton({
    Title = "Auto Buy",
    Callback = function()
        task.spawn(function()
            local n, err, spent = buyItem(F.buyName, F.buyCount)
            notify("Auto Buy", err or (n .. " x " .. tostring(F.buyName) .. "   -$" .. (spent or 0)), 4)
        end)
    end,
})

SecShop:AddButton({
    Title = "Drop Backpack",
    Callback = function()
        task.spawn(function()
            notify("Backpack", dropBackpack() .. " dropped", 3)
        end)
    end,
})

task.spawn(function()
    task.wait(1.5)
    local refs = buyRefs()
    if refs and refs.count > 0 then
        pcall(function() UI.BuyName:Refresh(refs.order, { refs.order[1] }) end)
        F.buyName = refs.order[1]
    end
end)

local SecOrb = TabFun:AddSection("Orbital Item", true)

UI.Orb = SecOrb:AddToggle({
    Title = "Orbital Item   ( gyroscope )",
    Default = false,
    Callback = function(v)
        if syncing then return end
        local ok, info = setOrbital(v and true or false)
        if not ok then
            syncToggle(UI.Orb, false)
            notify("Orbital", tostring(info), 3)
        elseif v then
            notify("Orbital", info .. " x " .. F.orbCat, 3)
        end
    end,
})

UI.OrbCat = SecOrb:AddDropdown({
    Title = "Orbit Item Type",
    Options = LOOT_TYPES,
    Default = { "All" },
    Callback = function(v)
        F.orbCat = (type(v) == "table" and v[1]) or tostring(v)
    end,
})

UI.OrbCount = SecOrb:AddSlider({
    Title = "Orbit Items",
    Increment = 1,
    Min = 1,
    Max = 24,
    Default = 8,
    Callback = function(v)
        F.orbCount = math.clamp(tonumber(v) or 8, 1, 24)
    end,
})

UI.OrbRings = SecOrb:AddSlider({
    Title = "Orbit Rings",
    Increment = 1,
    Min = 1,
    Max = 4,
    Default = 3,
    Callback = function(v)
        F.orbRings = math.clamp(tonumber(v) or 3, 1, 4)
    end,
})

UI.OrbRadius = SecOrb:AddSlider({
    Title = "Orbit Radius",
    Increment = 1,
    Min = 5,
    Max = 60,
    Default = 16,
    Callback = function(v)
        F.orbRadius = math.clamp(tonumber(v) or 16, 5, 60)
    end,
})

UI.OrbSpeed = SecOrb:AddSlider({
    Title = "Orbit Speed",
    Increment = 1,
    Min = 1,
    Max = 20,
    Default = 6,
    Callback = function(v)
        F.orbSpeed = math.clamp(tonumber(v) or 6, 1, 20)
    end,
})

UI.OrbTrails = SecOrb:AddToggle({
    Title = "Orbit Trails",
    Default = true,
    Callback = function(v)
        F.orbTrails = v and true or false
    end,
})

SecOrb:AddButton({
    Title = "Add More To Orbit",
    Callback = function()
        if not F.orbital then
            notify("Orbital", "enable the orbit first", 3)
            return
        end
        local n = orbCapture(F.orbCat, F.orbCount)
        notify("Orbital", n > 0 and ("+" .. n .. " orbiting " .. #orbItems) or "no items in range", 3)
    end,
})

SecOrb:AddButton({
    Title = "Release Orbit",
    Callback = function()
        local n = select(2, setOrbital(false))
        syncToggle(UI.Orb, false)
        notify("Orbital", n .. " released", 3)
    end,
})

local function resetAll()
    setFly(false)
    setNoclip(false)
    setGodmode(false)
    setAntiYeet(false)
    setFullBright(false)
    setAura(false)
    setSteal(false)
    setOrbital(false)
    F.autoWin = false
    F.infJump = false
    F.auraRadius = 250
    F.stealCap = 10
    F.sellRadius = 400
    F.bringCat = "All"
    F.stealCat = "All"
    F.bringCount = 8
    F.buyCount = 1
    F.orbCat = "All"
    F.orbCount = 8
    F.orbRings = 3
    F.orbRadius = 16
    F.orbSpeed = 6
    F.orbTrails = true
    setWalkSpeed(WALK_DEFAULT)
    setJumpPower(JUMP_DEFAULT)
    pcall(function() UI.Walk:Set(WALK_DEFAULT) end)
    pcall(function() UI.Jump:Set(JUMP_DEFAULT) end)
    pcall(function() UI.AuraRadius:Set(250) end)
    pcall(function() UI.StealCap:Set(10) end)
    pcall(function() UI.SellRadius:Set(400) end)
    pcall(function() UI.BringCount:Set(8) end)
    pcall(function() UI.BuyCount:Set(1) end)
    pcall(function() UI.BringCat:Set({ "All" }) end)
    pcall(function() UI.OrbCat:Set({ "All" }) end)
    pcall(function() UI.OrbCount:Set(8) end)
    pcall(function() UI.OrbRings:Set(3) end)
    pcall(function() UI.OrbRadius:Set(16) end)
    pcall(function() UI.OrbSpeed:Set(6) end)
    syncToggle(UI.Fly, false)
    syncToggle(UI.Noclip, false)
    syncToggle(UI.InfJump, false)
    syncToggle(UI.God, false)
    syncToggle(UI.Yeet, false)
    syncToggle(UI.Bright, false)
    syncToggle(UI.Aura, false)
    syncToggle(UI.Steal, false)
    syncToggle(UI.AutoWin, false)
    syncToggle(UI.Orb, false)
    syncToggle(UI.OrbTrails, true)
end
local Unload

local SecWin = TabWindow:AddSection("Interface", true)

SecWin:AddButton({ Title = "Center Window", Callback = resetWindow })
SecWin:AddButton({ Title = "Reset All Features", Callback = resetAll })
SecWin:AddButton({ Title = "Unload", Callback = function() Unload() end })

function Unload()
    resetAll()
    alive = false
    if pulse then
        pulse:Disconnect()
        pulse = nil
    end
    if ragConn then
        ragConn:Disconnect()
        ragConn = nil
    end
    if Hum then
        pcall(function()
            Hum.WalkSpeed = WALK_DEFAULT
            Hum.UseJumpPower = false
            Hum.JumpHeight = JUMP_HEIGHT
        end)
    end
    for _, c in ipairs(conns) do
        pcall(function() c:Disconnect() end)
    end
    conns = {}
    if LibToggleGui and ToggleBtn and ToggleBtn.Parent then
        pcall(function()
            stripToggle(ToggleBtn)
            ToggleBtn.Image = TOGGLE_IMAGE
            ToggleBtn.ImageTransparency = 0
            ToggleBtn.BackgroundTransparency = 1
            ToggleBtn.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            ToggleBtn.AutoButtonColor = true
            ToggleBtn.Size = UDim2.new(0, 59, 0, 49)
            ToggleBtn.Position = UDim2.new(0.1021, 0, 0.0743, 0)
            local c = ToggleBtn:FindFirstChildOfClass("UICorner")
            if c then c.CornerRadius = UDim.new(0, 9) end
            ToggleBtn.Visible = false
        end)
    end
    for _, c in ipairs(libToggleConns) do
        pcall(function() c:Enable() end)
    end
    libToggleConns = {}
    LibToggleGui, ToggleBtn = nil, nil
    for _, g in ipairs(MyGuis) do
        pcall(function() g:Destroy() end)
    end
    MyGuis = {}
    if _G.UJRunaways and _G.UJRunaways.Unload == Unload then
        _G.UJRunaways = nil
    end
end

_G.UJRunaways = {
    Unload = Unload,
    Flags = F,
    Stats = Stats,
    Set = {
        WalkSpeed = function(n)
            setWalkSpeed(n)
            pcall(function() UI.Walk:Set(F.walkSpeed) end)
        end,
        JumpPower = function(n)
            setJumpPower(n)
            pcall(function() UI.Jump:Set(F.jumpPower) end)
        end,
        FlySpeed = function(n)
            F.flySpeed = tonumber(n) or 90
            pcall(function() UI.FlySpeed:Set(F.flySpeed) end)
        end,
        InfJump = function(v)
            F.infJump = v and true or false
            syncToggle(UI.InfJump, F.infJump)
        end,
        Noclip = function(v)
            setNoclip(v)
            syncToggle(UI.Noclip, F.noclip)
        end,
        Fly = function(v)
            setFly(v and true or false)
            syncToggle(UI.Fly, F.fly)
        end,
        Godmode = function(v)
            setGodmode(v and true or false)
            syncToggle(UI.God, F.godmode)
        end,
        KillNPCs = function(r)
            return killNear(tonumber(r) or F.auraRadius)
        end,
        AntiYeet = function(v)
            setAntiYeet(v and true or false)
            syncToggle(UI.Yeet, F.antiYeetOff)
        end,
        FullBright = function(v)
            setFullBright(v)
            syncToggle(UI.Bright, F.fullBright)
        end,
        Aura = function(v)
            setAura(v and true or false)
            syncToggle(UI.Aura, F.aura)
        end,
        AuraRadius = function(n)
            F.auraRadius = math.clamp(tonumber(n) or 250, 50, 2000)
            pcall(function() UI.AuraRadius:Set(F.auraRadius) end)
        end,
        Steal = function(v)
            setSteal(v and true or false)
            syncToggle(UI.Steal, F.steal)
        end,
        AutoWin = function(v)
            setAutoWin(v and true or false)
            syncToggle(UI.AutoWin, F.autoWin)
        end,
        Orbital = function(v)
            local ok, info = setOrbital(v and true or false)
            syncToggle(UI.Orb, F.orbital)
            return ok, info
        end,
        OrbitalAdd = function(cat, n)
            if not F.orbital then return 0 end
            return orbCapture(cat or F.orbCat, tonumber(n) or F.orbCount)
        end,
        OrbitalRelease = function()
            local n = select(2, setOrbital(false))
            syncToggle(UI.Orb, false)
            return n
        end,
        OrbitalSet = function(t)
            if type(t) ~= "table" then return false end
            if t.cat then
                F.orbCat = tostring(t.cat)
                pcall(function() UI.OrbCat:Set({ F.orbCat }) end)
            end
            if t.count then
                F.orbCount = math.clamp(tonumber(t.count) or 8, 1, 24)
                pcall(function() UI.OrbCount:Set(F.orbCount) end)
            end
            if t.rings then
                F.orbRings = math.clamp(tonumber(t.rings) or 3, 1, 4)
                pcall(function() UI.OrbRings:Set(F.orbRings) end)
            end
            if t.radius then
                F.orbRadius = math.clamp(tonumber(t.radius) or 16, 5, 60)
                pcall(function() UI.OrbRadius:Set(F.orbRadius) end)
            end
            if t.speed then
                F.orbSpeed = math.clamp(tonumber(t.speed) or 6, 1, 20)
                pcall(function() UI.OrbSpeed:Set(F.orbSpeed) end)
            end
            if t.trails ~= nil then
                F.orbTrails = t.trails and true or false
                syncToggle(UI.OrbTrails, F.orbTrails)
            end
            return true
        end,
        Type = function(s)
            local pick = tostring(s or "All")
            F.bringCat = pick
            F.stealCat = pick
            pcall(function() UI.BringCat:Set({ pick }) end)
        end,
        Bring = function(cat, n)
            return bringItems(cat or F.bringCat, tonumber(n) or F.bringCount)
        end,
        Sell = function(cat, drop)
            return sellLoot(cat or F.bringCat, drop and true or false)
        end,
        Buy = function(name, n)
            return buyItem(name or F.buyName, tonumber(n) or F.buyCount)
        end,
        ShopItems = function()
            local refs = buyRefs()
            return refs and refs.order or {}
        end,
        DropBackpack = dropBackpack,
        OpenCustoms = function()
            local p = customsPrompt()
            return p and firePrompt(p) or false
        end,
        SavePos = savePos,
        ReturnPos = returnPos,
        CenterWindow = resetWindow,
        ResetAll = resetAll,
    },
}

notify("UJ RUNAWAYS", "Local, Escape and Fun tabs ready.", 4)
