if rawget(_G, "KaitunRunaway") then return end
_G.KaitunRunaway = true

local PAYLOAD = [==[
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LOBBY_ID = 118418618261207
local LOG = "UJ/_kaitun.log"
local STATE = "UJ/_kaitun_state.txt"
local SELF = "UJ/Kaitun.lua"
local GATE_Z = 83700
local GATE_BACK = 140
local STEP_Z = 200
local STEP_WAIT = 0.05
local STEP_LIFT = 4
local ROAD_NEAR = 800
local ROAD_TTL = 1
local AURA_R = 320
local AURA_WAIT = 0.2
local RUN_MAX = 75

local canlog = type(appendfile) == "function" and type(isfile) == "function"
    and type(readfile) == "function" and type(writefile) == "function"

local function log(s)
    if not canlog then return end
    pcall(function()
        if isfile(LOG) and #readfile(LOG) > 120000 then writefile(LOG, "") end
        appendfile(LOG, os.date("%H:%M:%S ") .. s .. "\n")
    end)
end

local function statRead()
    if not (canlog and isfile(STATE)) then return 0, 0 end
    local ok, s = pcall(readfile, STATE)
    if not ok then return 0, 0 end
    local c, t = tostring(s):match("(%d+)|(%d+)")
    return tonumber(c) or 0, tonumber(t) or 0
end

local function statAdd(gain)
    local c, t = statRead()
    c, t = c + 1, t + (gain or 0)
    if canlog then pcall(writefile, STATE, c .. "|" .. t) end
    return c, t
end

local q = queue_on_teleport or queueonteleport
if type(q) == "function" then
    pcall(q, 'if not rawget(_G,"KaitunRunaway") then _G.KaitunRunaway=true local ok,s=pcall(readfile,"'
        .. SELF .. '") if ok and s then local f=loadstring(s,"=Kaitun") if f then task.spawn(f) end end end')
end

if not game:IsLoaded() then
    pcall(function() game.Loaded:Wait() end)
end
local LP = Players.LocalPlayer
local boot = tick()
while not LP and tick() - boot < 60 do
    task.wait(0.2)
    LP = Players.LocalPlayer
end
if not LP then
    log("no LocalPlayer")
    return
end
local PG = LP:WaitForChild("PlayerGui", 60)
if not PG then
    log("no PlayerGui")
    return
end

pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)

local function waitFor(f, timeout, interval)
    local t = tick()
    while tick() - t < timeout do
        local ok, v = pcall(f)
        if ok and v then return v end
        task.wait(interval or 0.2)
    end
    return nil
end

local mod = RS:WaitForChild("FlowClient", 60)
if not mod then
    log("no FlowClient")
    return
end
local ok, Flow = pcall(require, mod)
if not ok or type(Flow) ~= "table" then
    log("flow require failed")
    return
end

local function fire(btn)
    if not (btn and type(getconnections) == "function") then return false end
    local good, cons = pcall(getconnections, btn.MouseButton1Click)
    if not (good and type(cons) == "table") then return false end
    local n = 0
    for _, c in ipairs(cons) do
        if pcall(function() c:Fire() end) then n = n + 1 end
    end
    return n > 0
end

local function findDeep(root, name, class)
    if not root then return nil end
    for _, d in ipairs(root:GetDescendants()) do
        if d.Name == name and (not class or d:IsA(class)) then return d end
    end
    return nil
end

local function endGui()
    local g = PG:FindFirstChild("EndFrame")
    if g and g.Enabled then return g end
    return nil
end

local function payout()
    local g = endGui()
    if not g then return "no end frame" end
    local out = {}
    for _, d in ipairs(g:GetDescendants()) do
        if d:IsA("TextLabel") then
            local t = d.Text
            if t:match("^Total") or t:match("^Borders") or t:match("^Distance")
                or t:match("^Wanted") or t:match("^Cash") or t:match("^BONUS") then
                out[#out + 1] = t
            end
        end
    end
    return table.concat(out, " | ")
end
local Char, Hum, Root

local function bind(c)
    Char = c
    Hum = c and c:FindFirstChildOfClass("Humanoid")
    Root = c and (c:FindFirstChild("HumanoidRootPart") or (Hum and Hum.RootPart))
end

local god, aura, origDamage = false, false, nil

local function godOn()
    if god then return end
    god = true
    local pd = Flow.PlayerDamage
    if type(pd) == "table" and type(pd.TakeDamage) == "function" and not origDamage then
        origDamage = pd.TakeDamage
        pcall(function() pd.TakeDamage = function() end end)
    end
    RunService.Heartbeat:Connect(function()
        if not god then return end
        local h = Hum
        if not (h and h.Parent) then return end
        if h.Health < h.MaxHealth then h.Health = h.MaxHealth end
        local st = h:GetState()
        if st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.FallingDown
            or st == Enum.HumanoidStateType.Ragdoll then
            h:ChangeState(Enum.HumanoidStateType.GettingUp)
        end
    end)
end

local function godOff()
    god = false
    if origDamage then
        pcall(function() Flow.PlayerDamage.TakeDamage = origDamage end)
        origDamage = nil
    end
end

local kills = 0

local function auraOn()
    if aura then return end
    local npcs = Flow.NPCs
    if type(npcs) ~= "table" or type(npcs.Damage) ~= "function" then return end
    aura = true
    task.spawn(function()
        while aura do
            pcall(function()
                local r = Root
                local folder = workspace:FindFirstChild("NPCs")
                if r and r.Parent and folder then
                    local o = r.Position
                    for _, m in ipairs(folder:GetChildren()) do
                        local h = m:FindFirstChildOfClass("Humanoid")
                        local pp = h and ((m:IsA("Model") and m.PrimaryPart)
                            or m:FindFirstChild("HumanoidRootPart"))
                        if pp and h.Health > 0 and (pp.Position - o).Magnitude <= AURA_R then
                            if pcall(npcs.Damage, h, h.Health + 25) then kills = kills + 1 end
                        end
                    end
                end
            end)
            task.wait(AURA_WAIT)
        end
    end)
end
local nodes, nodeStamp = nil, 0

local function roads(force)
    if nodes and not force and tick() - nodeStamp < ROAD_TTL then return nodes end
    local r = workspace:FindFirstChild("Map")
    r = r and r:FindFirstChild("Ground")
    r = r and r:FindFirstChild("Road")
    if not r then return nodes end
    local n = {}
    for _, d in ipairs(r:GetDescendants()) do
        if d:IsA("BasePart") and d.Size.X >= 40 and d.Size.X <= 160 and d.Size.Z >= 80 then
            n[#n + 1] = { x = d.Position.X, y = d.Position.Y + d.Size.Y / 2, z = d.Position.Z }
        end
    end
    if #n == 0 then return nodes end
    table.sort(n, function(a, b) return a.z < b.z end)
    nodes, nodeStamp = n, tick()
    return n
end

local function roadAt(z)
    local n = roads()
    if n and (z < n[1].z - ROAD_NEAR or z > n[#n].z + ROAD_NEAR) then n = roads(true) end
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

local function doorZ()
    local b = workspace:FindFirstChild("Map")
    b = b and b:FindFirstChild("Buildings")
    if not b then return nil end
    for _, c in ipairs(b:GetChildren()) do
        if c.Name == "CustomsFinal" then
            local d = c:FindFirstChild("CustomsBuilding")
            d = d and d:FindFirstChild("FinalDoor")
            d = d and d:FindFirstChild("DoorR")
            d = d and d:FindFirstChild("Door")
            if d and d:IsA("BasePart") then return d.Position.Z end
        end
    end
    return nil
end
local function route()
    if not (Root and Root.Parent) then return false, "no character" end
    local t0, poll = tick(), 0
    local z = Root.Position.Z
    local x, y = Root.Position.X, Root.Position.Y
    local target = GATE_Z - GATE_BACK
    while true do
        if endGui() then return true, "ended early" end
        if tick() - t0 > RUN_MAX then return false, "timeout" end
        if not (Root and Root.Parent) then return false, "character lost" end
        if tick() - poll > 1 then
            poll = tick()
            local d = doorZ()
            if d then target = d - GATE_BACK end
        end
        z = math.min(z + STEP_Z, target)
        local r = roadAt(z)
        if r and math.abs(r.z - z) < ROAD_NEAR then x, y = r.x, r.y + STEP_LIFT end
        if Hum and Hum.SeatPart then pcall(function() Hum.Sit = false end) end
        Root.CFrame = CFrame.new(x, y, z)
        Root.AssemblyLinearVelocity = Vector3.zero
        Root.AssemblyAngularVelocity = Vector3.zero
        if z >= target then return true, string.format("%.1fs", tick() - t0) end
        task.wait(STEP_WAIT)
    end
end

local function playRun()
    local c = LP.Character or LP.CharacterAdded:Wait()
    c:WaitForChild("HumanoidRootPart", 20)
    task.wait(0.4)
    bind(c)
    LP.CharacterAdded:Connect(function(nc)
        nc:WaitForChild("HumanoidRootPart", 20)
        task.wait(0.4)
        bind(nc)
    end)
    if not waitFor(function() return workspace:FindFirstChild("Map") end, 60) then
        log("no map")
        return
    end
    godOn()
    auraOn()
    local ok2, info = route()
    aura = false
    log(string.format("route ok=%s %s kills=%d", tostring(ok2), tostring(info), kills))
    godOff()
    if not endGui() then
        task.wait(0.3)
        pcall(Flow.Passout.Abandon)
    end
end

local function finish()
    aura = false
    godOff()
    local g = waitFor(endGui, 8, 0.2)
    if not g then
        pcall(Flow.Passout.Abandon)
        g = waitFor(endGui, 20, 0.2)
    end
    task.wait(1.2)
    local p = payout()
    local digits = (p:match("Total:%s*([%d,]+)") or "0"):gsub(",", "")
    local cycle, total = statAdd(tonumber(digits) or 0)
    log(string.format("cycle=%d payout %s | run=%d", cycle, p, total))
    if not pcall(Flow.GameManager.Replay) then
        pcall(Flow.GameManager.BackToLobby)
        return
    end
    if not waitFor(function() return endGui() == nil end, 25, 0.4) then
        log("replay stalled, back to lobby")
        pcall(Flow.GameManager.BackToLobby)
    end
end
local function launch()
    local hud, frame, box, minus, create

    local function resolve()
        hud = PG:FindFirstChild("Hud") or hud
        local cg = waitFor(function() return PG:FindFirstChild("CreateLobbyGui") end, 30)
        frame = cg and cg:WaitForChild("Frame", 10)
        box = frame and frame:WaitForChild("Container", 10)
        minus = box and findDeep(box:FindFirstChild("MaxPlayers") or box, "Minus", "GuiButton")
        create = box and (box:FindFirstChild("Create") or findDeep(box, "Create", "GuiButton"))
        return frame ~= nil and box ~= nil
    end

    waitFor(function() return PG:FindFirstChild("Hud") end, 60)
    if not resolve() then
        log("no create gui")
        return
    end
    task.wait(4)
    local attempt = 0
    while true do
        attempt = attempt + 1
        if not (frame and frame.Parent) then resolve() end
        if not (frame and box) then
            log("create gui lost attempt=" .. attempt)
            task.wait(2)
        else
            pcall(function() Flow.LobbyServer.exit() end)
            task.wait(0.7)
            pcall(function() frame.Visible = false end)
            local pn = hud and (hud:FindFirstChild("PlayNow") or findDeep(hud, "PlayNow", "GuiButton"))
            if not (pn and pn:IsA("GuiButton") and fire(pn)) then
                pcall(function() Flow.LobbyServer.play() end)
            end
            if waitFor(function() return frame.Visible end, 9, 0.1) then
                for _ = 1, 6 do
                    fire(minus)
                    task.wait(0.04)
                end
                task.wait(0.25)
                local sent = fire(create)
                if not sent then
                    pcall(function()
                        Flow.LobbyServer.create({ maxPlayers = 1, permissions = "All" })
                    end)
                end
                log("launch fired attempt=" .. attempt)
                task.wait(30)
            else
                log("no create window attempt=" .. attempt)
                task.wait(2)
            end
        end
    end
end

local inLobby = game.PlaceId == LOBBY_ID or workspace:FindFirstChild("Lobbies") ~= nil
log(string.format("start place=%d %s", game.PlaceId, inLobby and "lobby" or "game"))
if inLobby then
    launch()
else
    if not endGui() then
        local ran, err = pcall(playRun)
        if not ran then log("run error " .. tostring(err)) end
    end
    finish()
end

]==]

if type(writefile) == "function" then pcall(writefile, "UJ/Kaitun.lua", PAYLOAD) end

local fn, err = loadstring(PAYLOAD, "=KaitunRunaway")
if not fn then
    if type(warn) == "function" then warn("KaitunRunaway " .. tostring(err)) end
    return
end
task.spawn(fn)
