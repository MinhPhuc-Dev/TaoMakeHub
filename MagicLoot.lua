--[[=========================================================================
    Magic Loot  -  Fluent Hub v3
    UI: Fluent (dawid-scripts).  Every tunable is a free-text number box.

    Verified against the decompiled client:
      enemies      CollectionService:GetTagged("Enemy") -> HumanoidRootPart;
                   the model lives in Workspace.LocalMonster.<id>
      attack       PlayerSkillInput.simulateSlotPressRelease(slot, true)
                   slot 5 = normal attack, 1..3 = skills (SkillSlotConfig)
      stage entry  there is no client "enter stage" message - the server reads
                   your position, so teleporting into the stage's combat volume
                   IS the door.  Flags flip within ~3s: InStageSafeArea 1->0,
                   DungeonAggroStage ->N, InDungeonChallenge ->1
      pickup       FireServer(DROP_PICKUP, "<dropModelName>") - unlimited
                   range, but individual requests get rejected, so we retry
      sell         InvokeServer(SELL_MATERIAL, { onlyIDList = {...} }) over
                   PlayerData.GetPlrDataByKey(LP, "Bag") rows with tp==Material
      bag flush    loot picked up inside a stage sits in a server-side temp bag
                   (Player.LimitBagUsed) and is NOT sellable until
                   FireServer(DUNGEON_RETURN_TOWN) flushes it.  That message
                   also drops you in town, so auto-sell re-enters afterwards.
      train        InvokeServer(TRAIN_MANUAL_CLICK, {}) -> { ok = , gain = }
                   dispatched concurrently; blocking on it is why v2 was slow

    What cannot be multiplied from the client (measured, not assumed):
    damage per hit and gain per training tap are computed server-side.  42
    presses/second produced the same stage clear time as 1 press/second, so the
    number boxes buy request *rate* - never a damage or gain multiplier.  The
    real throughput lever for farming is stage rotation speed.

    Pacing: ToolSystem.RequestRateLimit allows 20 requests/second per message
    name.  The gate below defaults to 18 and is itself a number box.
=========================================================================]]

if _G.__MagicLootHub then
    pcall(function() _G.__MagicLootHub:Unload() end)
end

local function CreateMagicLootHub()

    ------------------------------------------------------------------
    -- 1. Services, escaped instance names
    ------------------------------------------------------------------
    local Players           = game:GetService("Players")
    local Workspace         = game:GetService("Workspace")
    local CollectionService = game:GetService("CollectionService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local ReplicatedFirst   = game:GetService("ReplicatedFirst")
    local Lighting          = game:GetService("Lighting")
    local RunService        = game:GetService("RunService")
    local LP                = Players.LocalPlayer

    -- Chinese instance names, byte-escaped so this file stays ASCII-clean.
    local N_SCENE  = "\229\156\186\230\153\175"                         -- 场景
    local N_COMBAT = "\230\136\152\230\150\151\229\140\186\229\159\159" -- 战斗区域
    local N_SAFE   = "\229\174\137\229\133\168\229\140\186\229\159\159" -- 安全区域
    local N_LOBBY  = "\229\164\167\229\142\133"                         -- 大厅
    local N_TEMP   = "\228\184\180\230\151\182\230\150\135\228\187\182\229\164\185" -- 临时文件夹

    ------------------------------------------------------------------
    -- 2. Game modules
    ------------------------------------------------------------------
    local Utils     = require(ReplicatedFirst.AllSideCode.UtilsSystem)
    local NetWork   = Utils.NetWork
    local NetMsg    = Utils.NetMsg
    local GetData   = Utils.GetData
    local CfgFind   = Utils.CfgFind
    local Conf      = Utils.ConfigInstance
    local Translate = Utils.TranslationHelper
    local PlrData   = Utils.PlayerData
    local HumanMod  = Utils.HumanModule
    local ItemType  = Utils.EnumMgr.ItemType
    local EquipShop = Utils.EquipShop

    local SkillFolder = LP.PlayerScripts.Manager.PlayerSkillClientManager
    local SkillInput  = require(SkillFolder.PlayerSkillInput)
    local SlotCfg     = require(SkillFolder.SkillSlotConfig)
    local SLOT_NORMAL = SlotCfg.NORMAL_ATTACK_SLOT_INDEX   -- 5
    local SLOT_MAX    = SlotCfg.MAX_SKILL_COUNT            -- 3

    -- Optional: used only to keep alchemy recipe materials out of the sell list.
    local Alchemy
    pcall(function()
        Alchemy = require(ReplicatedFirst.AllSideCode.ToolSystem.Alchemy)
    end)

    local ADDONS = "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/"
    local Fluent = loadstring(game:HttpGet(
        "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
    local SaveManager      = loadstring(game:HttpGet(ADDONS .. "SaveManager.lua"))()
    local InterfaceManager = loadstring(game:HttpGet(ADDONS .. "InterfaceManager.lua"))()

    ------------------------------------------------------------------
    -- 3. State  (UI callbacks only ever write here - see note below)
    ------------------------------------------------------------------
    -- Fluent invokes OnChanged/Callback during construction.  Returning from
    -- the game's NetWork inside such a callback permanently strips the
    -- thread's capabilities and every later CoreGui write fails with
    -- "lacking capability Plugin".  So: callbacks mutate S, workers act.
    local S = {
        running = true,

        -- combat
        killAura      = false,
        auraSlots     = { [SLOT_NORMAL] = true, [1] = true, [2] = true, [3] = true },
        attacksPerSec = 12,      -- number box, unbounded
        auraRange     = 400,     -- studs; the game's own target gate is 60
        snapToTarget  = true,
        snapDistance  = 12,

        -- movement
        hover         = true,    -- float above the wave instead of standing in it
        hoverHeight   = 14,      -- studs above the floor; the volume allows 22

        -- farm
        autoFarm      = false,
        stageStart    = 1,
        stageEnd      = 0,       -- 0 = CareerMaxStage + 1
        stageSeconds  = 70,      -- hard timeout before advancing
        spawnWait     = 36,      -- a wave lands every ~32s, so wait one out
        clearsPerStage = 1,      -- advance after this many cleared waves
        maxClearSecs  = 60,      -- give up on a wave that would take longer
        dps           = 0,       -- measured damage per second, for that estimate
        retreatHP     = 45,      -- percent
        returnHP      = 95,      -- percent
        retreating    = false,   -- set while healing, freezes the aura
        farmStage     = 0,
        farmClears    = 0,
        farmPhase     = "idle",
        farmWalking   = false,   -- true while the corridor is being walked

        -- drops
        autoPickup    = false,
        pickupPerSec  = 4,       -- scan passes per second
        needFlush     = false,   -- set when the temp bag fills up

        -- selling
        autoSell      = false,
        sellSeconds   = 6,
        sellFlush     = true,    -- fire DUNGEON_RETURN_TOWN to release temp bag
        keepAlchemy   = true,
        sellNow       = false,
        flushNow      = false,

        -- training
        autoTrain     = false,
        tapsPerSec    = 10,
        trainInFlight = 0,
        trainGain     = 0,

        -- shop
        autoBuyWand   = false,
        wandMode      = "Unlock all wands",
        wandChoice    = nil,
        equipAfterBuy = true,

        -- rebirth
        autoRebirth   = false,

        -- performance
        perfWanted    = false,
        perfApplied   = false,

        -- pacing
        reqPerSec     = 18,      -- per message name, server cap is 20

        -- counters
        picked = 0, trained = 0, sold = 0, goldFromSales = 0,
        casts = 0, kills = 0, bought = 0, rebirths = 0, flushes = 0,
        note = "idle",
    }

    ------------------------------------------------------------------
    -- 4. Request budget
    ------------------------------------------------------------------
    -- Two guards: <reqPerSec> per message name per second, and no more than 9
    -- distinct message names in any 5s window (the server's
    -- DetectRequestPatternAnomaly flags 10+).
    local buckets, nameSeen = {}, {}

    local function allow(msgName)
        local now = os.clock()

        local seenCount = 0
        for k, t in pairs(nameSeen) do
            if now - t > 5 then nameSeen[k] = nil else seenCount += 1 end
        end
        if not nameSeen[msgName] and seenCount >= 9 then return false end

        local q = buckets[msgName]
        if not q then q = {}; buckets[msgName] = q end
        for i = #q, 1, -1 do
            if now - q[i] > 1 then table.remove(q, i) end
        end
        local cap = math.max(1, math.floor(tonumber(S.reqPerSec) or 18))
        if #q >= cap then return false end

        q[#q + 1] = now
        nameSeen[msgName] = now
        return true
    end

    ------------------------------------------------------------------
    -- 5. Small read helpers
    ------------------------------------------------------------------
    local function num(v, fallback)
        return tonumber(v) or fallback
    end

    local function valueIn(folderName, id)
        local folder = LP:FindFirstChild(folderName)
        local v = folder and folder:FindFirstChild(tostring(id))
        return (v and tonumber(v.Value)) or 0
    end
    local function bag(id)  return valueIn("Bag", id) end
    local function attr(id) return valueIn("Attrs", id) end

    local function flag(name)
        local v = LP:FindFirstChild(name)
        if not v then return 0 end
        if typeof(v.Value) == "boolean" then return v.Value and 1 or 0 end
        return tonumber(v.Value) or 0
    end

    local function en(zh, fallback)
        if not zh then return fallback end
        local ok, t = pcall(Translate.TranslateByKey, zh)
        if ok and t and t ~= "" then return tostring(t) end
        return tostring(zh)
    end
    local function label(confName, id, fallback)
        local row = Conf[confName] and Conf[confName][id]
        return en(row and row.ZhName, fallback)
    end

    local function comma(n)
        n = math.floor(num(n, 0))
        local neg = n < 0
        local s = tostring(math.abs(n))
        s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
        return (neg and "-" or "") .. s
    end

    local function short(n)
        n = num(n, 0)
        for _, u in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
            if n >= u[1] then return ("%.2f%s"):format(n / u[1], u[2]) end
        end
        return comma(n)
    end

    local function charOf()   return LP.Character end
    local function root()
        local c = charOf()
        return c and c:FindFirstChild("HumanoidRootPart")
    end
    local function humanoid()
        local c = charOf()
        return c and c:FindFirstChildOfClass("Humanoid")
    end
    local function alive()
        local h = humanoid()
        return h ~= nil and h.Health > 0
    end
    local function hpFrac()
        local h = humanoid()
        if not h or h.MaxHealth <= 0 then return 1 end
        return h.Health / h.MaxHealth
    end

    -- Regeneration in this game is ~1% per second, so "retreat and wait for 95%"
    -- costs a minute and a half of farming for a hit that hover already prevents.
    -- What matters is not the number, it is whether anything is still hurting us:
    -- a worker stamps the clock whenever health actually drops, and the guard only
    -- pulls out when the damage is recent.
    local lastDamage, lastHP = 0, nil
    local function watchDamage()
        local h = humanoid()
        if not h then lastHP = nil return end
        local hp = h.Health
        if lastHP and hp < lastHP - 0.5 then lastDamage = os.clock() end
        lastHP = hp
    end
    local function underAttack(window)
        return os.clock() - lastDamage < (window or 6)
    end
    local function holdingWeapon()
        local ok, t = pcall(HumanMod.GetHeldItemType, LP)
        return ok and t == "Weapon"
    end

    ------------------------------------------------------------------
    -- 5b. Movement  (tween, not a CFrame snap)
    ------------------------------------------------------------------
    -- Every position change goes through here.  A raw `hrp.CFrame = ...` snap
    -- is a zero-frame jump: the server sees one replicated position and then
    -- another 500 studs away, which is the single most obvious thing a client
    -- Tweening the same CFrame produces a continuous path at a plausible
    -- running speed, and it also fixes a real bug - the server's pickup and stage
    -- region checks test the position it has *replicated* for us, and a snap
    -- outruns replication (that is why 3 of 5 pickup requests used to be
    -- refused).  A tween arrives with replication already caught up.
    local TweenService = game:GetService("TweenService")
    local MOVE_SPEED   = 120      -- studs/second along the path
    local MOVE_MIN     = 0.12     -- never shorter than this, so a hop still ticks
    local MOVE_MAX     = 1.60     -- never longer, so the farm loop stays responsive

    local moveTween                -- the one tween in flight, if any
    local hoverAt                  -- Vector3 the hover worker holds us at

    local function cancelMove()
        if moveTween then
            pcall(function() moveTween:Cancel() end)
            moveTween = nil
        end
    end

    -- Physics fights a CFrame tween: gravity pulls down between frames and the
    -- Humanoid tries to walk.  PlatformStand parks the state machine without
    -- unanchoring us from the world the way Anchored = true does (an anchored
    -- root stops replicating its CFrame, which would break the region checks).
    local function freezePhysics(on)
        local h = humanoid()
        if not h then return end
        pcall(function()
            h.PlatformStand = on
            if on then h:ChangeState(Enum.HumanoidStateType.Physics) end
        end)
        local hrp = root()
        if hrp then
            hrp.AssemblyLinearVelocity = Vector3.zero
            hrp.AssemblyAngularVelocity = Vector3.zero
        end
    end

    -- Blocks until the character is there (or the tween is cancelled by a newer
    -- move).  Callers already treat movement as taking time, so this keeps the
    -- old teleport() contract: it returns once we are in position.
    local function moveTo(pos, wait_)
        local hrp = root()
        if not hrp or not pos then return false end
        cancelMove()
        local dist = (hrp.Position - pos).Magnitude
        if dist < 0.6 then
            hrp.CFrame = CFrame.new(pos)
            return true
        end
        freezePhysics(true)
        local secs = math.clamp(dist / MOVE_SPEED, MOVE_MIN, MOVE_MAX)
        local info = TweenInfo.new(secs, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        local ok, tw = pcall(TweenService.Create, TweenService, hrp, info,
                             { CFrame = CFrame.new(pos) })
        if not ok or not tw then
            hrp.CFrame = CFrame.new(pos)      -- last resort, still better than stalling
            return true
        end
        moveTween = tw
        tw:Play()
        if wait_ == false then return true end
        local t0 = os.clock()
        while tw.PlaybackState == Enum.PlaybackState.Playing
              and os.clock() - t0 < secs + 0.4 do
            task.wait()
        end
        if moveTween == tw then moveTween = nil end
        -- Leaving PlatformStand on after a move leaves the character floating
        -- with no friction, and it slides off the spot we just aimed at (seen
        -- live: arrived at z=92, drifted to z=85 over 3s).  Only the hover wants
        -- physics off; a plain move hands control back.
        if not hoverAt then freezePhysics(false) end
        return true
    end

    -- Kept as the name the rest of the hub uses.
    local function teleport(pos)
        return moveTo(pos, true)
    end

    ------------------------------------------------------------------
    -- 5c. Hover  (stay out of melee reach)
    ------------------------------------------------------------------
    -- The waves are melee: they walk to the player and swing.  Parking a dozen
    -- studs off the floor means they gather underneath and never connect, while
    -- our own skill presses still resolve because the game's target gate is a
    -- 60-stud sphere, not a ground check.
    --
    -- Measured: 战斗区域 is 100.7 x 25.9 x 87.0 centred at Y 20.2, so it spans
    -- Y 7.2 -> 33.2 with the floor at ~8.2.  The server's stage-presence test is
    -- that volume, so the hover has to stay inside it - float above Y 33 and the
    -- stage stops counting us as present and the wave timer dies with it.  That
    -- caps the useful height at ~22 studs above the floor.
    local HOVER_MAX = 22

    local function hoverStop()
        hoverAt = nil
        freezePhysics(false)
    end

    local hoverConn
    local function startHoverWorker()
        if hoverConn then return end
        hoverConn = RunService.Heartbeat:Connect(function()
            local pos = hoverAt
            if not pos then return end
            if moveTween and moveTween.PlaybackState == Enum.PlaybackState.Playing then
                return                              -- a move is in flight, let it land
            end
            local hrp = root()
            if not hrp then return end
            local h = humanoid()
            if h and not h.PlatformStand then
                pcall(function() h.PlatformStand = true end)
            end
            hrp.CFrame = CFrame.new(pos)
            hrp.AssemblyLinearVelocity = Vector3.zero
        end)
    end

    ------------------------------------------------------------------
    -- 6. Stage geometry  (streaming-safe)
    ------------------------------------------------------------------
    -- Career stages are 108 studs apart on Z.  Measured live:
    --   combat volume centre : (-458.389, 20.200, 139.162 + 108*(N-1))
    --   safe area            : z = 193.15 + 108*(N-1)
    -- Standing point is centre.Y - 12 (the volume centre is well above floor).
    -- Far stages are not replicated (streaming is on), so we fall back to the
    -- formula and RequestStreamAroundAsync the target before teleporting.
    local STAGE_X, STAGE_Y, STAGE_Z0, STAGE_STEP = -458.389, 20.200, 139.162, 108
    local SAFE_Z0, STAND_DROP = 193.15, 12
    local MAX_STAGE = 32

    local function scene() return Workspace:FindFirstChild(N_SCENE) end
    local function stageModel(n)
        local sc = scene()
        return sc and sc:FindFirstChild(tostring(n))
    end

    local function stagePart(n, partName)
        local m = stageModel(n)
        local p = m and m:FindFirstChild(partName)
        return (p and p:IsA("BasePart")) and p or nil
    end

    -- Where to stand to trigger the server's stage-entry region check.
    local function combatStand(n)
        local p = stagePart(n, N_COMBAT)
        if p then
            return Vector3.new(p.Position.X, p.Position.Y - STAND_DROP, p.Position.Z)
        end
        return Vector3.new(STAGE_X, STAGE_Y - STAND_DROP, STAGE_Z0 + STAGE_STEP * (n - 1))
    end

    -- 安全区域 is a 12-stud-tall region volume whose centre sits at Y 12.1, so the
    -- combat stand's "centre minus 12" trick puts us at Y 0.1 - under the floor
    -- plate (Root tops out at ~4.5).  Measured live: the character ended up at
    -- y=-12 and regenerated at 1%/s while stuck there.  Take X/Z from the volume
    -- but stand just above its own floor instead.
    local function safeStand(n)
        local p = stagePart(n, N_SAFE)
        if p then
            return Vector3.new(p.Position.X,
                               p.Position.Y - p.Size.Y * 0.5 + 3.5,
                               p.Position.Z)
        end
        return Vector3.new(STAGE_X, STAGE_Y - STAND_DROP, SAFE_Z0 + STAGE_STEP * (n - 1))
    end

    -- Clamp any hover position into stage n's combat volume, keeping a 3-stud
    -- margin under the ceiling so a bit of physics jitter cannot pop us out of
    -- the region the server tests.
    local function clampToCombat(n, pos)
        local p = stagePart(n, N_COMBAT)
        if not p then return pos end
        local half = p.Size * 0.5
        local c    = p.Position
        return Vector3.new(
            math.clamp(pos.X, c.X - half.X + 3, c.X + half.X - 3),
            math.clamp(pos.Y, c.Y - half.Y + 2, c.Y + half.Y - 3),
            math.clamp(pos.Z, c.Z - half.Z + 3, c.Z + half.Z - 3))
    end

    -- The height the farm holds while a wave is up: straight above the combat
    -- volume's centre, S.hoverHeight studs off the floor.
    local function combatHover(n)
        local base = combatStand(n)
        local h    = math.clamp(num(S.hoverHeight, 14), 0, HOVER_MAX)
        return clampToCombat(n, base + Vector3.new(0, h, 0))
    end

    -- Hover directly over a target, at our configured height above *its* feet.
    local function hoverOver(n, pos)
        local h = math.clamp(num(S.hoverHeight, 14), 0, HOVER_MAX)
        local want = Vector3.new(pos.X, pos.Y + h, pos.Z)
        return (n and n > 0) and clampToCombat(n, want) or want
    end

    local function hoverHold(pos)
        hoverAt = pos
        moveTo(pos, true)
    end

    local function lobbyStand()
        local sc = scene()
        local lobby = sc and sc:FindFirstChild(N_LOBBY)
        local spawn = lobby and lobby:FindFirstChildOfClass("SpawnLocation")
        return spawn and (spawn.Position + Vector3.new(0, 4, 0)) or nil
    end

    -- RequestStreamAroundAsync yields until the streamer says the region is in,
    -- and in this client it measurably never comes back: a probe fired at the
    -- stage-1 combat volume was still running after 60s.  Every call was a
    -- permanent block, which is exactly what froze the farm at "entering
    -- stage 1" and, before that, at "discovering stages".  So it is strictly
    -- fire-and-forget now, and anything that actually needs a stage present
    -- waits for the part to replicate instead of waiting on this call.
    local function streamAround(pos)
        task.spawn(function()
            pcall(function() LP:RequestStreamAroundAsync(pos, 1) end)
        end)
    end

    -- Only stages that actually carry a combat volume can be entered.  Models
    -- 1..32 all exist, but with streaming on a far stage arrives as a stub
    -- (柱子 / EnemyPos / Root / 安全区域 only) and gains 战斗区域, 前门, 后门 and
    -- 材料掉落区域 once we are close enough.  Stage 1 does have a combat volume -
    -- an early reading that said otherwise was just a half-streamed model.
    local function stagePlayable(n)
        return stagePart(n, N_COMBAT) ~= nil
    end

    -- Streaming follows the character, so the way to bring a stage in is to
    -- stand in it and wait for 战斗区域 to replicate.  Bounded, and it never
    -- waits on the streamer's own promise.
    local function awaitStage(n, seconds)
        if stagePlayable(n) then return true end
        hoverStop()
        local guess = Vector3.new(STAGE_X, STAGE_Y - STAND_DROP,
                                  STAGE_Z0 + STAGE_STEP * (n - 1))
        streamAround(guess)
        local t0 = os.clock()
        while os.clock() - t0 < (seconds or 6) do
            teleport(guess)
            if stagePlayable(n) then return true end
            task.wait(0.25)
        end
        return stagePlayable(n)
    end

    -- Nudge the streamer towards every stage region once.  This is only a hint
    -- for the UI's stage list - the rotation's ceiling comes from
    -- CareerMaxStage, and enterStage streams the one stage it needs - so it is
    -- spaced out and entirely fire-and-forget.
    local function discoverStages()
        task.spawn(function()
            for n = 1, MAX_STAGE do
                if not stagePlayable(n) then
                    streamAround(Vector3.new(STAGE_X, STAGE_Y, STAGE_Z0 + STAGE_STEP * (n - 1)))
                    task.wait(0.05)
                end
            end
        end)
    end

    local function highestPlayable()
        local top = 1
        for n = 1, MAX_STAGE do
            if stagePlayable(n) then top = n end
        end
        return top
    end

    -- Geometry is necessary but not sufficient.  RequestStreamAroundAsync will
    -- happily stream in stages above your career progression: they gain a
    -- 战斗区域, pass stagePlayable, and the ceiling runs away (it reached 21 in
    -- testing) - but the server never spawns a wave there, so the rotation
    -- burns its whole cycle on empty rooms.  So the auto ceiling only follows
    -- stages we have actually seen an enemy in, plus one probe stage above.
    local frontier = 1        -- highest stage that has ever spawned a wave
    local barren = {}         -- stage -> consecutive visits with no spawn

    local function noteStageAlive(n)
        barren[n] = 0
        if n > frontier then frontier = n end
    end

    local function noteStageBarren(n)
        barren[n] = (barren[n] or 0) + 1
    end

    -- A stage is dropped from the rotation once it has come up empty three
    -- times in a row and it is above the frontier - i.e. it is not just on
    -- respawn cooldown, it is genuinely not ours yet.
    local function stageWorthVisiting(n)
        -- Do not judge a stage that has not replicated yet: with streaming on,
        -- every stage above the one we are standing in looks unplayable from
        -- here.  enterStage streams it and gives up quickly if it truly has no
        -- combat volume.
        if n <= frontier then return true end
        return (barren[n] or 0) < 3
    end

    -- The run has to be walked from stage 1 anyway, and the server only lets it
    -- reach CareerMaxStage + 1, so the ceiling comes from career progression -
    -- not from what the streamer happens to have loaded (that ran away to 21).
    local function stageCeiling()
        if num(S.stageEnd, 0) > 0 then
            return math.clamp(math.floor(S.stageEnd), 1, MAX_STAGE)
        end
        local cm = LP:FindFirstChild("CareerMaxStage")
        local career = cm and math.floor(tonumber(cm.Value) or 1) + 1 or 1
        return math.clamp(math.max(career, frontier), 1, MAX_STAGE)
    end

    ------------------------------------------------------------------
    -- 7. Enemies  (the game's own registry)
    ------------------------------------------------------------------
    -- NowTargetUpdater builds its target list from CollectionService's "Enemy"
    -- tag, which is applied to each enemy's HumanoidRootPart.  v2 scanned
    -- Workspace.Monster, which is always empty for logical enemies - that is
    -- why the old kill aura never fired.
    local function enemyList(stageFilter)
        local out = {}
        -- With 7 players on the server, Workspace.Monster carries their enemies
        -- too, stamped with the same Stage number as ours.  So a stage filter
        -- alone still counted foreign monsters ("1 up" forever, no wave ever
        -- looked cleared); pin them to our own room as well.
        local room = stageFilter and stageFilter > 0 and combatStand(stageFilter) or nil
        for _, tagged in ipairs(CollectionService:GetTagged("Enemy")) do
            if tagged.Parent then
                local model = tagged:IsA("Model") and tagged or tagged.Parent
                local part  = tagged:IsA("BasePart") and tagged
                    or (model and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")))
                local hum   = model and model:FindFirstChildOfClass("Humanoid")
                if model and part and hum and hum.Health > 0 then
                    local st = model:GetAttribute("Stage")
                        or model:GetAttribute("SpecialEnemyStageId")
                    local stageOk = (not stageFilter) or (not st) or tonumber(st) == stageFilter
                    local roomOk  = (not room) or (part.Position - room).Magnitude <= 60
                    if stageOk and roomOk then
                        out[#out + 1] = { model = model, part = part, hum = hum, stage = st }
                    end
                end
            end
        end
        return out
    end

    local function nearestEnemy(stageFilter)
        local hrp = root()
        if not hrp then return nil, math.huge end
        local best, bestD = nil, math.huge
        for _, e in ipairs(enemyList(stageFilter)) do
            local d = (e.part.Position - hrp.Position).Magnitude
            if d < bestD then best, bestD = e, d end
        end
        return best, bestD
    end

    -- The game only accepts a skill release against ReplicatedStorage
    -- .NowTargetCurrent.  NowTargetUpdater re-picks it every Heartbeat within
    -- 60 studs, so we set it immediately before pressing.
    local function forceTarget(model)
        local ov = ReplicatedStorage:FindFirstChild("NowTargetCurrent")
        if ov and ov:IsA("ObjectValue") and ov.Value ~= model then
            pcall(function() ov.Value = model end)
        end
    end

    ------------------------------------------------------------------
    -- 8. Kill aura
    ------------------------------------------------------------------
    -- simulateSlotPressRelease(slot, true) sets _hubSkipCooldownOnce, which
    -- bypasses the *local* cooldown check; the server still enforces the
    -- skill's cast rhythm.  Requirements it checks itself: alive, held item
    -- type "Weapon" (except the dash slot), and normal attack is blocked while
    -- Player.IsAutoTraining is true.
    local function press(slot)
        if not allow(NetMsg.RELEASE_GROUP_SKILL) then return false end
        local ok, fired = pcall(SkillInput.simulateSlotPressRelease, slot, true)
        if ok and fired then
            S.casts += 1
            return true
        end
        return false
    end

    local function auraTick()
        if not alive() then S.note = "aura: dead" return 0 end
        if S.retreating then S.note = "aura: paused while healing" return 0 end
        if not holdingWeapon() then S.note = "aura: no wand held" return 0 end
        if flag("IsAutoTraining") == 1 then S.note = "aura: game auto-train is on" return 0 end

        -- Lock onto our own stage while we are in one.  Workspace.Monster also
        -- carries other players' enemies, tagged and stamped with *their* stage,
        -- and chasing one of those (auraRange is 400 studs) teleports us out of
        -- our combat volume - which stops our own wave from ever spawning.
        local mine   = flag("DungeonAggroStage")
        local live   = flag("InDungeonChallenge") > 0

        -- While the farm is walking the corridor there is no room of ours to
        -- fight in, and letting the aura pick a target anyway is how the
        -- character ended up at y=124, z=-177: it locked onto some other
        -- player's event monster across the map and hovered over it, and the
        -- corridor walk never finished.  So the aura stands down until the farm
        -- has a live stage again.
        if S.autoFarm and not (live and mine > 0) then
            S.note = "aura: waiting for the farm to open the run"
            return 0
        end

        local anchor = mine > 0 and combatStand(mine) or nil
        local target, dist = nearestEnemy(mine > 0 and mine or nil)
        if target and anchor and (target.part.Position - anchor).Magnitude > 60 then
            target = nil    -- outside our room; the game's own gate is 60 studs
        end
        if not target then S.note = "aura: no enemy spawned" return 0 end
        if dist > num(S.auraRange, 400) then
            S.note = ("aura: nearest enemy %dst away"):format(math.floor(dist))
            return 0
        end

        -- The game's own target gate is a weighted 60-stud sphere, so pull
        -- ourselves to whatever spawned instead of waiting for it to walk.  With
        -- hover on we sit directly over its head: still well inside the 60-stud
        -- gate, but out of reach of a melee swing.  Only hover inside a stage -
        -- outside one there is no volume to clamp against and the height just
        -- accumulates.
        if S.snapToTarget then
            local p = target.part.Position
            if S.hover and mine > 0 then
                hoverHold(hoverOver(mine, p))
            elseif dist > num(S.snapDistance, 12) then
                local hrp = root()
                if hrp then
                    local dir = (hrp.Position - p)
                    dir = (dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1))
                    teleport(p + dir * num(S.snapDistance, 12) + Vector3.new(0, 1, 0))
                end
            end
        end
        forceTarget(target.model)

        local n = 0
        if S.auraSlots[SLOT_NORMAL] and press(SLOT_NORMAL) then n += 1 end
        for slot = 1, SLOT_MAX do
            if S.auraSlots[slot] and press(slot) then n += 1 end
        end
        S.note = ("aura: %d enemy(s) up, %d press(es)")
            :format(#enemyList(mine > 0 and mine or nil), n)

        return n
    end

    ------------------------------------------------------------------
    -- 9. Drops  (the rules come out of ClientScript.SystemDrop)
    ------------------------------------------------------------------
    -- Layout is Workspace.DropsClient.<xyd rarity>.<dropId>: the sub-models are
    -- rarity buckets, not stages, and each one owns a permanent
    -- "DropRareHighlight" child, so only numerically-named children are drops.
    --
    -- The game picks a drop up through a ProximityPrompt on its PrimaryPart:
    -- MaxActivationDistance = 10, RequiresLineOfSight = false, and Enabled only
    -- while  drop.DropLanded == true  and  drop.Stage == the stage you are
    -- aggroed into.  Triggered then fires FireServer(DROP_PICKUP, dropId).
    -- The server enforces those same conditions plus temp-bag space, which is
    -- why v3 could spray 178 blind requests and land 4 items.  So: match the
    -- stage, wait for the landing, teleport inside 10 studs, fire once.
    local DROP_REACH = 9        -- prompt allows 10; keep a stud of slack

    local function limitBagUsed()
        local v = LP:FindFirstChild("LimitBagUsed")
        return v and math.floor(tonumber(v.Value) or 0) or 0
    end

    -- Temp-bag capacity is Bag.5 ("+1 Slot Space"); it reads 5 on this account.
    local function tempCap()
        local bag = LP:FindFirstChild("Bag")
        local v = bag and bag:FindFirstChild("5")
        return v and math.max(1, math.floor(tonumber(v.Value) or 4)) or 4
    end

    local lastTry = {}

    local function dropList()
        local holder = Workspace:FindFirstChild("DropsClient")
        if not holder then return {} end
        local stage = flag("DungeonAggroStage")
        if stage <= 0 then return {} end
        local out = {}
        for _, bucket in ipairs(holder:GetChildren()) do
            for _, d in ipairs(bucket:GetChildren()) do
                if tonumber(d.Name) and d:IsA("Model")
                    and d:GetAttribute("DropLanded") == true
                    and math.floor(tonumber(d:GetAttribute("Stage")) or 0) == stage then
                    local part = d.PrimaryPart or d:FindFirstChildWhichIsA("BasePart")
                    if part then
                        out[#out + 1] = { id = d.Name, pos = part.Position }
                    end
                end
            end
        end
        return out
    end

    -- Measured: firing five requests back to back while teleporting between the
    -- drops landed two of five.  The server re-checks the 10-stud radius against
    -- the position it has *replicated* for us, and that lags a teleport by a
    -- couple of frames - so land on the drop, let replication catch up, fire one
    -- request, and confirm LimitBagUsed moved before walking to the next one.
    local function pickupPass()
        -- Walking the corridor and chasing loot are two workers pulling the same
        -- character in different directions; the walk wins by standing down the
        -- pickup for the couple of seconds it takes.
        if S.farmWalking then return 0 end
        local free = tempCap() - limitBagUsed()
        if free <= 0 then
            S.needFlush = true
            S.note = "pickup: temp bag full, selling"
            return 0
        end

        local drops = dropList()
        if #drops == 0 then return 0 end
        local hrp = root()
        if not hrp then return 0 end

        -- nearest first: fewer teleports, less replication lag to wait out
        local here = hrp.Position
        table.sort(drops, function(a, b)
            return (a.pos - here).Magnitude < (b.pos - here).Magnitude
        end)

        local got = 0
        -- The prompt radius is 10 studs and the drops lie on the floor, so a
        -- 14-stud hover is out of range.  Release the hover for the duration of
        -- the pass and put it back afterwards.
        local resumeHover = hoverAt
        hoverAt = nil
        for _, d in ipairs(drops) do
            -- Bag.5 has been observed climbing (4 -> 5 -> 6) as bag upgrades drop,
            -- so treat it as a hint and let the server be the real authority: a
            -- request that does not move LimitBagUsed was refused.
            if limitBagUsed() >= tempCap() then S.needFlush = true break end
            if not S.autoPickup or not S.running then break end
            if not allow(NetMsg.DROP_PICKUP) then break end
            local last = lastTry[d.id]
            if (not last) or (os.clock() - last > 3) then
                lastTry[d.id] = os.clock()
                hrp = root() or hrp
                if (d.pos - hrp.Position).Magnitude > DROP_REACH then
                    teleport(d.pos + Vector3.new(0, 3, 0))
                    task.wait(0.25)
                end
                local before = limitBagUsed()
                if pcall(NetWork.FireServer, NetMsg.DROP_PICKUP, d.id) then
                    local landed = false
                    for _ = 1, 8 do
                        task.wait(0.05)
                        if limitBagUsed() > before then landed = true break end
                    end
                    if landed then
                        got += 1
                        S.picked += 1
                    else
                        -- let it come round again shortly instead of after 3s
                        lastTry[d.id] = os.clock() - 2
                    end
                end
            end
        end

        for id, t in pairs(lastTry) do
            if os.clock() - t > 30 then lastTry[id] = nil end
        end

        if resumeHover and S.hover then hoverHold(resumeHover) end

        if got > 0 then
            S.note = ("pickup: %d drop(s) in, %d temp slot(s) left")
                :format(got, math.max(0, tempCap() - limitBagUsed()))
        end
        return got
    end

    ------------------------------------------------------------------
    -- 10. Selling  (this is the "must return to town" bug, automated)
    ------------------------------------------------------------------
    -- Verified live, end to end:
    --   DROP_PICKUP        -> item goes into a server-side temp bag, and
    --                         Player.LimitBagUsed counts it (cap 4)
    --   DUNGEON_RETURN_TOWN-> flushes the temp bag into Player.Bag as material
    --                         rows, within ~0.25s.  It does not need you to
    --                         walk anywhere, but it does end the dungeon run
    --                         and teleport you to the lobby.
    --   SELL_MATERIAL      -> { onlyIDList = {onlyID, ...} }, returns true and
    --                         credits gold immediately (+2,332,883 for 18 rows,
    --                         exactly matching GetData.Sell.GetSellPrice).
    -- So "sell immediately" is flush -> sell, and the farm just re-enters the
    -- stage afterwards.  InitTop debounces the flush by 1.5s, so do we.
    local lastFlush = 0

    local function flushTempBag()
        if limitBagUsed() <= 0 then return false, "nothing pending" end
        if os.clock() - lastFlush < 1.6 then return false, "debounced" end
        if not allow(NetMsg.DUNGEON_RETURN_TOWN) then return false, "capped" end
        lastFlush = os.clock()
        local ok, err = pcall(NetWork.FireServer, NetMsg.DUNGEON_RETURN_TOWN)
        if not ok then return false, tostring(err) end
        S.flushes += 1
        -- wait for the server to actually credit it
        local t0 = os.clock()
        while limitBagUsed() > 0 and os.clock() - t0 < 3 do task.wait(0.1) end
        S.note = "sell: temp bag flushed"
        return true, "ok"
    end

    -- Sellable rows, mirroring GuiScripts.ModuleScript.Sell exactly:
    -- PlayerData.GetPlrDataByKey(LP,"Bag") is a TABLE keyed by stringified
    -- onlyID (rows {tp, id, onlyID, count, lock}) - not the Bag Instance folder.
    local function sellableRows()
        local ok, Bag = pcall(PlrData.GetPlrDataByKey, LP, "Bag")
        if not ok or type(Bag) ~= "table" then return {} end
        local rows = {}
        for _, row in pairs(Bag) do
            if type(row) == "table" and tonumber(row.tp) == ItemType.Material then
                local locked = (row.lock == 1 or row.lock == true)
                local id = tonumber(row.id)
                local marked = false
                if S.keepAlchemy and Alchemy and id then
                    local okA, res = pcall(Alchemy.IsMarkedRecipeMaterial, LP, id)
                    marked = okA and res == true
                end
                if not locked and not marked then rows[#rows + 1] = row end
            end
        end
        return rows
    end

    local function estimateValue(rows)
        local total = 0
        for _, row in ipairs(rows) do
            local id = tonumber(row.id)
            local cfg = id and CfgFind.FindCfgByID(id, ItemType.Material)
            if cfg then
                local ok, price = pcall(GetData.Sell.GetSellPrice, LP, cfg)
                if ok then total += (tonumber(price) or 0) * (tonumber(row.count) or 1) end
            end
        end
        return total
    end

    local function sellEverything()
        if S.sellFlush then flushTempBag() end
        -- Only clear the "bag is full" flag once the bag is genuinely empty.
        -- Clearing it up front is what pinned LimitBagUsed at its cap with five
        -- drops lying on the floor and gold frozen for 30s: the flush can be
        -- debounced, rate-capped or switched off, and the one signal that says
        -- "stop, we cannot carry any more" was being thrown away regardless.
        S.needFlush = limitBagUsed() > 0

        local rows = sellableRows()
        if #rows == 0 then
            S.note = "sell: nothing sellable in the bag"
            return 0
        end
        local worth = estimateValue(rows)

        local ids, done = {}, 0
        for _, row in ipairs(rows) do
            ids[#ids + 1] = row.onlyID
            if #ids >= 100 then
                if not allow(NetMsg.SELL_MATERIAL) then break end
                local ok, res = pcall(NetWork.InvokeServer, NetMsg.SELL_MATERIAL,
                    { onlyIDList = ids })
                if ok and res == true then done += #ids end
                ids = {}
            end
        end
        if #ids > 0 and allow(NetMsg.SELL_MATERIAL) then
            local ok, res = pcall(NetWork.InvokeServer, NetMsg.SELL_MATERIAL,
                { onlyIDList = ids })
            if ok and res == true then done += #ids end
        end

        if done > 0 then
            S.sold += done
            S.goldFromSales += worth
            S.note = ("sell: %d item(s), ~%s gold"):format(done, short(worth))
        else
            S.note = ("sell: server rejected %d item(s)"):format(#rows)
        end
        return done
    end

    ------------------------------------------------------------------
    -- 11. Training
    ------------------------------------------------------------------
    -- v2 was slow for one reason: it awaited InvokeServer, and Roblox
    -- serialises RemoteFunction calls per client, so the rate collapsed to
    -- 1/ping (~8/s at best, far less under load).  Here every tap is
    -- dispatched on its own thread and only the in-flight count is bounded,
    -- so the real limit is the request budget instead of round-trip latency.
    --
    -- There is no zone auto-move any more: the user asked for it gone, and the
    -- gain per tap comes from your weapon's trainBase server-side, not from
    -- where you stand.  Standing in a training zone actually *hurts* - the
    -- client's tap handler ignores manual taps while Player.InTrainGround is
    -- true - so we warn instead of moving you there.
    local MAX_TRAIN_INFLIGHT = 24

    -- One tap per call; the worker loop paces itself off S.tapsPerSec.
    local function trainTick()
        if flag("InTrainGround") == 1 then
            S.note = "train: leave the training ground - manual taps are ignored there"
            return 0
        end
        if S.trainInFlight >= MAX_TRAIN_INFLIGHT then return 0 end
        if not allow(NetMsg.TRAIN_MANUAL_CLICK) then return 0 end
        S.trainInFlight += 1
        task.spawn(function()
            local ok, res = pcall(NetWork.InvokeServer, NetMsg.TRAIN_MANUAL_CLICK, {})
            S.trainInFlight -= 1
            if ok and type(res) == "table" and res.ok == true then
                S.trained += 1
                S.trainGain = tonumber(res.gain) or S.trainGain
            end
        end)
        S.note = ("train: %s taps, +%s each, %d in flight")
            :format(comma(S.trained), short(S.trainGain), S.trainInFlight)
        return 1
    end

    ------------------------------------------------------------------
    -- 12. Stage entry  ("the dungeon door")
    ------------------------------------------------------------------
    -- There is no client-side enter message: DUNGEON_ENTER_STAGE_SAFE_AREA and
    -- DUNGEON_SPAWN_STAGE have no client sender at all.  The server does the
    -- region test on your replicated position, so putting the HumanoidRootPart
    -- inside 场景.<N>.战斗区域 *is* walking through the door.
    --
    -- But there are two server flags, and both matter:
    --   DungeonAggroStage   - which room you are standing in.  Follows a
    --                         teleport anywhere, including stage 20.
    --   InDungeonChallenge  - how far the *current run* has progressed, and it
    --                         only ever advances from the lobby end of the
    --                         corridor, one 前门 at a time.
    -- The server spawns waves for a room only while a run is live, so dropping
    -- straight into stage 5 gives aggro=5, InDungeonChallenge=0 and an empty
    -- room forever.  Measured: from the lobby, z=100 sets aggro=1/run=1 and
    -- z=210 sets aggro=2/run=2; with run=2 a wave landed in 22s, and with run=0
    -- nothing spawned in 78s of standing in the combat volume.  DUNGEON_RETURN
    -- _TOWN (the sell flush) resets the run to 0, so every flush has to be
    -- followed by walking the corridor again - that is what silently killed the
    -- rotation after the first sale.
    -- The 前门 parts sit at z = 200.1 + 108*(n-2) and the trigger volume starts
    -- just past them: measured live, z=92.6 did NOT open stage 1 but z=98.8 did,
    -- and z=210 opened stage 2.  So stand ~8 studs beyond the door plane, on the
    -- floor (y=10) rather than at the door part's centre height - a mid-air
    -- standing point just sinks and drifts.
    local DOOR_Z0 = 100         -- stage 1's entrance; each 前门 is 108 further
    local DOOR_Y  = 10

    local function doorStand(n)
        return Vector3.new(STAGE_X, DOOR_Y, DOOR_Z0 + STAGE_STEP * (n - 1))
    end

    local function runStage()
        return flag("InDungeonChallenge")
    end

    local function inStage(n)
        return flag("DungeonAggroStage") == n and runStage() > 0
    end

    -- DUNGEON_RETURN_TOWN does two things: it banks the temp bag *and* it ends the
    -- run (InDungeonChallenge -> 0).  flushTempBag refuses when the bag is empty,
    -- which is right for selling and wrong for the rotation: to farm a room the run
    -- has already passed, the run has to be reset whether or not we are carrying
    -- anything.  Measured: skipping this left run=11 while the farm tried to enter
    -- stage 10, and every entry attempt burned a full 5s window for nothing.
    local function endRun()
        if runStage() <= 0 then return true end
        if not allow(NetMsg.DUNGEON_RETURN_TOWN) then return false end
        lastFlush = os.clock()
        local ok = pcall(NetWork.FireServer, NetMsg.DUNGEON_RETURN_TOWN)
        if not ok then return false end
        S.flushes += 1
        local t0 = os.clock()
        while runStage() > 0 and os.clock() - t0 < 3 do task.wait(0.1) end
        return runStage() <= 0
    end

    -- Push the run forward to stage n, one front door at a time.  Stages the
    -- run has already opened are free to jump straight back to.
    local function openRunTo(n)
        hoverStop()          -- the door region checks are on the floor
        S.farmWalking = true
        if runStage() <= 0 then
            teleport(lobbyStand() or Vector3.new(-451.29, 10.09, 38.10))
            task.wait(0.35)
        end
        for k = math.max(1, runStage() + 1), n do
            if not S.running then return false end
            streamAround(doorStand(k))
            S.farmPhase = ("opening the run: stage %d"):format(k)
            local t0 = os.clock()
            repeat
                -- Re-assert the position every quarter second.  Arriving once and
                -- then only watching the flag looked cheaper and was much worse:
                -- doors that used to open in ~3.5s started timing out at 7s, and
                -- the run sat at 0 for 35s.  The server's region test wants the
                -- position replicated repeatedly, and the character drifts.
                teleport(doorStand(k))
                task.wait(0.25)
            until runStage() >= k or os.clock() - t0 > 7
            if runStage() < k then
                S.note = ("farm: the run stalled at stage %d"):format(runStage())
                S.farmWalking = false
                return false
            end
        end
        S.farmWalking = false
        return runStage() >= n
    end

    -- Keep this cheap: a long blocking retry loop here stalled the whole
    -- rotation for ~30s in testing, so it re-asserts the position every 0.2s
    -- for a short window and then lets holdStage carry on regardless.
    local function enterStage(n)
        S.farmWalking = true
        if not awaitStage(n, 5) then
            S.note = ("farm: stage %d never streamed in"):format(n)
            S.farmWalking = false
            return false
        end
        if runStage() < n and not openRunTo(n) then
            S.farmWalking = false
            return false
        end
        S.farmWalking = true
        local pos = combatStand(n)
        local t0 = os.clock()
        while os.clock() - t0 < 5 do
            teleport(pos)
            if inStage(n) then
                -- presence is registered on the floor; now lift off out of reach
                if S.hover then hoverHold(combatHover(n)) end
                S.farmWalking = false
                return true
            end
            task.wait(0.2)
        end
        S.farmWalking = false
        return inStage(n)
    end

    local function retreat(stage)
        hoverStop()
        local pos = safeStand(stage) or lobbyStand()
        if pos then teleport(pos) end
    end

    -- Returns true when it had to interrupt combat for health or a respawn.
    -- S.retreating suppresses the kill aura so it cannot drag us back in.
    local function guardHealth(stage)
        if not alive() then
            S.retreating = true
            S.farmPhase = "waiting for respawn"
            local t0 = os.clock()
            while not alive() and os.clock() - t0 < 30 and S.autoFarm do task.wait(0.5) end
            S.retreating = false
            return true
        end
        local pct = hpFrac() * 100
        -- Low health on its own is not a reason to leave: hover keeps the melee
        -- waves off us, and health climbs back at ~1%/s while we keep farming.
        -- Retreat only when something is landing hits right now.
        if pct <= num(S.retreatHP, 45) and underAttack(6) then
            S.retreating = true
            retreat(stage)
            -- Come back as soon as the hitting stops and we are off the floor of
            -- the HP bar, rather than idling all the way to 95%.
            local backAt = math.min(num(S.returnHP, 95),
                                    num(S.retreatHP, 45) + 20)
            while S.autoFarm and alive()
                  and (underAttack(4) or hpFrac() * 100 < backAt) do
                S.farmPhase = ("healing in safe area: %d%%"):format(math.floor(hpFrac() * 100))
                retreat(stage)
                task.wait(0.4)
            end
            S.retreating = false
            return true
        end
        return false
    end

    ------------------------------------------------------------------
    -- 13. Auto farm  (sequential: stage 1 -> 2 -> 3 -> ... then repeat)
    ------------------------------------------------------------------
    -- No "recommended stage" any more.  Start at S.stageStart, walk upward to
    -- S.stageEnd (0 = the highest stage that has a combat volume, and at least
    -- CareerMaxStage + 1 so the run also pushes your career), then loop back.
    --
    -- Measured wave cadence in a career stage: 4 local monsters appear in
    -- Workspace.LocalMonster (one ~6000hp elite plus three ~2000hp), they are
    -- down inside ~1.3s, ~2s later the stage drops 11 items, and the next wave
    -- lands ~32s after the previous one.  Two consequences:
    --   * a 5s look-in genuinely misses a live stage, so spawnWait has to cover
    --     a whole wave period before we call a stage barren;
    --   * leaving as soon as the wave dies abandons 11 drops, so the hold also
    --     stays while there is loot on the ground and pickup is on.
    local function holdStage(stage)
        local deadline  = os.clock() + math.max(5, num(S.stageSeconds, 70))
        local spawnGive = os.clock() + math.max(1, num(S.spawnWait, 36))
        local wanted    = math.max(1, math.floor(num(S.clearsPerStage, 1)))
        local sawEnemy  = false
        local sawAny    = false     -- did anything at all spawn in this window
        local lastCash  = 0
        S.farmClears = 0

        -- Damage meter.  Measured: a stage-6 wave is 4 x 2.5M HP and dies in under
        -- 6s, so ~1.7M dps; stage 11's five monsters lost nothing in 45s.  Summing
        -- our room's enemy health each tick gives the rate, and the rate turns the
        -- next room's health bar into an ETA - which is the only honest way to know
        -- a stage is out of reach *before* burning a whole window on it.
        local lastSum, fightSecs, damage = nil, 0, 0
        local lastTick = os.clock()

        while S.autoFarm and S.running and os.clock() < deadline do
            if guardHealth(stage) then
                if S.autoFarm then enterStage(stage) end
                deadline  = os.clock() + math.max(5, num(S.stageSeconds, 45))
                spawnGive = os.clock() + math.max(1, num(S.spawnWait, 36))
            end

            -- selling / flushing / retreating moves us, so re-assert cheaply.
            -- A flush also ends the run, so that case needs the full corridor
            -- walk again rather than a teleport into a dead room.
            if not inStage(stage) then
                if runStage() <= 0 then
                    S.farmPhase = ("re-opening the run to stage %d"):format(stage)
                    enterStage(stage)
                else
                    S.farmPhase = ("re-asserting stage %d"):format(stage)
                    hoverStop()
                    teleport(combatStand(stage))
                    if inStage(stage) and S.hover then hoverHold(combatHover(stage)) end
                end
            elseif S.hover and not hoverAt then
                hoverHold(combatHover(stage))
            end

            local mobs = enemyList(stage)
            local up   = #mobs
            local loot = #dropList()

            -- The temp bag is 5-7 slots and one wave drops 11 items, so it fills
            -- mid-hold.  Deferring the flush until the window ends loses every
            -- drop after that point: measured, five items sat on the floor for
            -- 30s with LimitBagUsed pinned at 7 and gold unchanged.  Cash out the
            -- moment it is full.  The flush also ends the run, so hand straight
            -- back to the rotation and let it re-walk the corridor.
            if S.autoSell and limitBagUsed() >= tempCap()
               and os.clock() - lastCash > 3 then
                lastCash = os.clock()
                S.farmPhase = ("stage %d - temp bag full (%d/%d), cashing out")
                    :format(stage, limitBagUsed(), tempCap())
                sellEverything()
                if limitBagUsed() <= 0 then return "flushed" end
                -- Flushing is switched off or was refused; there is no point
                -- chasing loot we cannot carry, so keep fighting instead.
                S.needFlush = true
            end

            -- Health pool of this room's wave, and how fast it is dropping.
            local sum = 0
            for _, e in ipairs(mobs) do sum += e.hum.Health end
            local dt = os.clock() - lastTick
            lastTick = os.clock()
            if up > 0 then
                if lastSum and up > 0 and sum < lastSum then damage += (lastSum - sum) end
                fightSecs += dt
                if fightSecs > 1.5 and damage > 0 then
                    local rate = damage / fightSecs
                    -- Exponential average so one lucky wave does not set the bar.
                    S.dps = (S.dps > 0) and (S.dps * 0.7 + rate * 0.3) or rate
                end
                lastSum = sum
            else
                lastSum = nil
            end

            -- The give-up rule.  If this wave's remaining health divided by the
            -- damage we are actually doing needs longer than maxClearSecs, stop:
            -- there is nothing to be gained by standing there, and the caller
            -- collects, sells and reloops on a stage it can finish.
            if up > 0 and S.dps > 0 and fightSecs > 3 then
                local eta = sum / S.dps
                if eta > math.max(5, num(S.maxClearSecs, 60)) then
                    S.note = ("farm: stage %d wave is %s HP at %s dps - %ds to clear, too slow")
                        :format(stage, short(sum), short(S.dps), math.floor(eta))
                    S.farmPhase = ("stage %d too tanky (%ds to clear) - cashing out")
                        :format(stage, math.floor(eta))
                    return "tanky"
                end
            end

            if up > 0 then
                sawEnemy = true
                sawAny   = true
                noteStageAlive(stage)
            else
                if loot > 0 then noteStageAlive(stage) end   -- a wave died here
                if sawEnemy then
                    sawEnemy = false
                    S.farmClears += 1
                    S.kills += 1
                elseif loot == 0 and os.clock() > spawnGive then
                    -- The frontier room is the only one the server spawns in, and
                    -- it spawns on a respawn timer: measured 25s+ of an empty
                    -- stage 10 between waves.  Calling that "barren" and bouncing
                    -- out only churns the corridor, so wait the timer out there
                    -- and reserve the skip for rooms that are not the frontier.
                    if stage == runStage() then
                        S.farmPhase = ("stage %d clear - waiting out the respawn timer")
                            :format(stage)
                        spawnGive = os.clock() + math.max(1, num(S.spawnWait, 36))
                    else
                        noteStageBarren(stage)
                        S.farmPhase = ("stage %d spawned nothing in %ds, skipping")
                            :format(stage, math.floor(num(S.spawnWait, 36)))
                        return "barren"
                    end
                end
            end

            local lootLeft = S.autoPickup and loot > 0 and (tempCap() - limitBagUsed()) > 0
            if S.farmClears >= wanted and not lootLeft then return "cleared" end

            S.farmPhase = ("stage %d - %d up, %s HP, %d loot, %d/%d cleared, %ds left")
                :format(stage, up, short(sum), loot, S.farmClears, wanted,
                        math.max(0, math.floor(deadline - os.clock())))
            task.wait(0.2)
        end
        -- Ran out of clock, and the three endings are not the same thing:
        --   * we killed a wave                      -> cleared;
        --   * we watched monsters we could not kill  -> tanky, drop the cap;
        --   * nothing ever spawned                   -> the respawn timer simply
        --     outlasted the window.  That is not a damage problem, so it must not
        --     cost us a stage of ceiling.
        if S.farmClears > 0 then return "cleared" end
        return sawAny and "tanky" or "barren"
    end

    -- The rotation IS the run.  The server only spawns a wave in the room that
    -- matches the run's current frontier: measured live, sitting in stage 1 for
    -- 70s with InDungeonChallenge=9 produced nothing at all, while stage 9 had a
    -- wave up within seconds.  So this is not a free sweep over 1..ceiling - it
    -- walks the run forward one door per lap and then holds the top.
    --
    -- Two things stop the climb, and they are different:
    --   * a door that will not open  -> the career gate, hardCap = stage - 1;
    --   * a room full of monsters that never die -> above our damage, and the
    --     measured symptom is "5 up, 0/1 cleared" for the whole 45s window.
    -- The second one has to walk back *down*, and going down means ending the run
    -- first: a room the run has already passed spawns nothing, so the way to farm
    -- stage 6 again is flush (run -> 0) and re-walk the corridor to 6 only.
    local function farmWorker()
        local discovered = false
        local target  = 0
        local hardCap = MAX_STAGE     -- highest stage we are allowed to try
        local best    = 0             -- highest stage we have actually cleared in
        local wins    = 0             -- clean clears at the cap, earns a re-probe
        local failAt  = {}
        while S.running and not Fluent.Unloaded do
            if not S.autoFarm then
                S.farmPhase = "off"
                discovered, target, best = false, 0, 0
                hardCap, failAt, wins = MAX_STAGE, {}, 0
                task.wait(0.3)
                continue
            end
            if not discovered then
                discovered = true
                S.farmPhase = "discovering stages"
                discoverStages()
            end

            local first = math.clamp(math.floor(num(S.stageStart, 1)), 1, MAX_STAGE)
            local last  = math.clamp(math.max(first, stageCeiling()), first, hardCap)

            -- Never aim below where the run already is: those rooms are dead
            -- until something ends the run.
            target = math.clamp(math.max(target, runStage(), first), first, last)

            S.farmStage = target
            S.farmPhase = ("entering stage %d"):format(target)
            if enterStage(target) then
                failAt[target] = nil
                local how = holdStage(target)
                if how == "cleared" then
                    best = math.max(best, target)
                    -- Damage grows over a session (rebirths, a new wand, levels),
                    -- so a cap set an hour ago should not be permanent.  Three
                    -- clean clears at the cap earns one probe at the next room.
                    if target >= hardCap and hardCap < MAX_STAGE then
                        wins += 1
                        if wins >= 3 then
                            wins = 0
                            hardCap += 1
                            S.note = ("farm: cleared stage %d three times, trying %d again")
                                :format(target, hardCap)
                        end
                    end
                end

                -- Cash out only when the temp bag is actually full.  The flush
                -- ends the run, so doing it on every stage transition starved
                -- the rotation of waves entirely (8 flushes / 72s, 0 enemies).
                if S.autoSell and S.needFlush then
                    S.farmPhase = "temp bag full - flushing and selling"
                    sellEverything()
                end

                if how == "tanky" then
                    -- This room is above our damage: either nothing died in a
                    -- whole window, or the wave's health divided by our measured
                    -- dps needed longer than maxClearSecs.  The sequence the user
                    -- asked for is stop -> collect -> sell -> reloop, and it is
                    -- also the right one: the loot already on the floor is worth
                    -- more than another minute of chipping at a 250M health bar.
                    hardCap = math.max(first, target - 1)
                    wins = 0
                    local back = math.max(first, math.min(hardCap, best > 0 and best or hardCap))

                    S.farmPhase = ("stage %d too tanky - collecting the loot"):format(target)
                    local sweep = os.clock()
                    while S.autoPickup and os.clock() - sweep < 4 do
                        if pickupPass() == 0 and #dropList() == 0 then break end
                        task.wait(0.2)
                    end
                    if S.autoSell then
                        S.farmPhase = "cashing out before dropping back"
                        sellEverything()
                    end
                    -- Unconditional: the sell may have had nothing to flush, and a
                    -- live run keeps every room below the frontier empty.
                    S.farmPhase = ("reloop: ending the run, back to stage %d"):format(back)
                    endRun()
                    task.wait(0.3)
                    S.note = ("farm: stage %d is out of reach, farming stage %d instead")
                        :format(target, back)
                    target = back
                elseif how == "flushed" then
                    -- The bag filled and was banked mid-fight, which ended the
                    -- run.  Stay on this room - it is the best one we can clear -
                    -- and let the top of the loop re-walk the corridor to it.
                    best = math.max(best, target)
                    S.farmPhase = ("sold mid-run - walking back to stage %d"):format(target)
                elseif how == "barren" and target < last then
                    target += 1                      -- no wave here, push on
                elseif how == "cleared" and target < last then
                    target += 1                      -- one room per lap, upward
                end
            else
                -- A door that will not open twice in a row is the career limit,
                -- so stop trying to climb past it and settle on the room below.
                failAt[target] = (failAt[target] or 0) + 1
                if failAt[target] >= 2 and target > first then
                    hardCap = math.max(first, target - 1)
                    S.note = ("farm: stage %d will not open, holding at %d")
                        :format(target, hardCap)
                end
                -- Do not fall back to wherever the run happens to be after every
                -- hiccup.  A flush leaves run=0, and collapsing the target onto it
                -- sent the rotation back to stage 1 to fight rooms whose drops are
                -- worth a thousandth of the top room's (measured: 20s held in
                -- stage 2 for 495 HP of monsters, straight after clearing 10).
                -- Three failures in a row is not a hiccup though, and farming the
                -- room the run did reach beats retrying one climb forever.
                if (failAt[target] or 0) >= 3 then
                    local dropped = target
                    target = math.clamp(math.max(runStage(), first), first, hardCap)
                    failAt[dropped] = 0
                    S.note = ("farm: could not walk to stage %d, farming %d for now")
                        :format(dropped, target)
                else
                    target = math.clamp(math.max(target, best), first, hardCap)
                end
                task.wait(0.5)
            end
            task.wait(0.2)
        end
    end

    ------------------------------------------------------------------
    -- 14. Wand shop
    ------------------------------------------------------------------
    -- weaponConf rows with Price >= 0 are gold purchases; Price -1 means
    -- Robux/event only and is skipped.
    local wandList, wandByName = {}, {}
    do
        for id, row in pairs(Conf.weaponConf) do
            local price = num(row.Price, -1)
            if price >= 0 then
                local entry = {
                    id    = id,
                    price = price,
                    sort  = num(row.Sort, 0),
                    name  = ("%s  (%s)"):format(en(row.ZhName, "Wand " .. id), short(price)),
                }
                wandList[#wandList + 1] = entry
                wandByName[entry.name] = entry
            end
        end
        table.sort(wandList, function(a, b) return a.sort < b.sort end)
    end

    local function ownsWand(id)
        local ok, owned = pcall(function()
            return EquipShop and EquipShop.OwnsInBag(LP, id, ItemType.Weapon)
        end)
        return ok and owned == true
    end

    local function equipWand(id)
        -- Payload mirrors EQUIP_SHOP_BUY in ToolSystem.EquipShopUi.
        if not allow(NetMsg.EQUIP_SHOP_EQUIP) then return false end
        local ok, res = pcall(NetWork.InvokeServer, NetMsg.EQUIP_SHOP_EQUIP,
            { equipID = id, itemType = ItemType.Weapon })
        return ok and res == true
    end

    local function buyWand(id)
        if not allow(NetMsg.EQUIP_SHOP_BUY) then return false, "capped" end
        local ok, res = pcall(NetWork.InvokeServer, NetMsg.EQUIP_SHOP_BUY,
            { equipID = id, itemType = ItemType.Weapon })
        if not ok then return false, tostring(res) end
        if res ~= true then return false, "server rejected" end
        S.bought += 1
        if S.equipAfterBuy then task.spawn(equipWand, id) end
        return true, "ok"
    end

    local function wandTick()
        local gold = bag(1)
        if S.wandMode == "Choose wand to buy" then
            local pick = S.wandChoice and wandByName[S.wandChoice]
            if not pick then S.note = "shop: no wand chosen" return end
            if ownsWand(pick.id) then S.note = "shop: already owned" return end
            if gold < pick.price then
                S.note = ("shop: need %s more gold"):format(short(pick.price - gold))
                return
            end
            local ok, why = buyWand(pick.id)
            S.note = ok and ("shop: bought " .. pick.name) or ("shop: " .. why)
            return
        end
        -- Unlock all: cheapest affordable unowned wand first, one per tick.
        for _, w in ipairs(wandList) do
            if not ownsWand(w.id) and gold >= w.price then
                local ok, why = buyWand(w.id)
                S.note = ok and ("shop: bought " .. w.name) or ("shop: " .. why)
                return
            end
        end
        S.note = "shop: nothing affordable yet"
    end

    ------------------------------------------------------------------
    -- 15. Rebirth
    ------------------------------------------------------------------
    local function rebirthStatus()
        local count, level = math.floor(bag(2)), math.floor(bag(4))
        local cfg = CfgFind.GetCfgByNameAndID("rebirthConf", count + 1)
        if not cfg then return count, level, nil, false end
        local need = math.floor(num(cfg.LvNeed, 0))
        return count, level, need, level >= need
    end

    local function rebirthOnce()
        local _, _, need, eligible = rebirthStatus()
        if not need then return false, "already max rebirth" end
        if not eligible then return false, "level below " .. need end
        if not allow(NetMsg.PLAYER_REBIRTH) then return false, "capped" end
        local ok, res = pcall(NetWork.InvokeServer, NetMsg.PLAYER_REBIRTH)
        if not ok then return false, tostring(res) end
        if res ~= true then return false, "server rejected" end
        S.rebirths += 1
        return true, "ok"
    end

    ------------------------------------------------------------------
    -- 16. Performance
    ------------------------------------------------------------------
    local perfSaved = {}

    local function applyPerformance(on)
        if on and not S.perfApplied then
            pcall(function()
                perfSaved.quality = settings().Rendering.QualityLevel
                settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
            end)
            perfSaved.globalShadows = Lighting.GlobalShadows
            perfSaved.fog = Lighting.FogEnd
            Lighting.GlobalShadows = false
            Lighting.FogEnd = 1e6
            for _, d in ipairs(Workspace:GetDescendants()) do
                if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
                    or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("Beam") then
                    d.Enabled = false
                elseif d:IsA("BasePart") then
                    d.CastShadow = false
                    d.Material = Enum.Material.SmoothPlastic
                end
            end
            local terrain = Workspace:FindFirstChildOfClass("Terrain")
            if terrain then
                terrain.WaterWaveSize = 0
                terrain.WaterWaveSpeed = 0
                terrain.WaterReflectance = 0
            end
            S.perfApplied = true
            S.note = "performance mode on"
        elseif not on and S.perfApplied then
            pcall(function()
                settings().Rendering.QualityLevel =
                    perfSaved.quality or Enum.QualityLevel.Automatic
            end)
            Lighting.GlobalShadows = perfSaved.globalShadows
            Lighting.FogEnd = perfSaved.fog or 100000
            S.perfApplied = false
            S.note = "performance mode off (rejoin for a full restore)"
        end
    end

    ------------------------------------------------------------------
    -- 17. Window
    ------------------------------------------------------------------
    local Window = Fluent:CreateWindow({
        Title       = "Magic Loot",
        SubTitle    = "Fluent hub v3",
        TabWidth    = 140,
        Size        = UDim2.fromOffset(600, 520),
        Acrylic     = false,
        Theme       = "Dark",
        MinimizeKey = Enum.KeyCode.LeftControl,
    })

    local Tabs = {
        Combat   = Window:AddTab({ Title = "Combat",   Icon = "crosshair" }),
        Farm     = Window:AddTab({ Title = "Farm",     Icon = "swords" }),
        Bag      = Window:AddTab({ Title = "Bag",      Icon = "package" }),
        Train    = Window:AddTab({ Title = "Train",    Icon = "dumbbell" }),
        Shop     = Window:AddTab({ Title = "Shop",     Icon = "shopping-cart" }),
        Stats    = Window:AddTab({ Title = "Stats",    Icon = "bar-chart-2" }),
        Misc     = Window:AddTab({ Title = "Misc",     Icon = "wrench" }),
        Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
    }

    -- Every numeric control is a free-text box with no upper bound, per request.
    -- Callbacks only assign into S, never touch the network (capability bug).
    local function numberBox(parent, id, title, desc, key)
        local default = tostring(S[key])
        parent:AddInput(id, {
            Title       = title,
            Description = desc,
            Default     = default,
            Placeholder = default,
            Numeric     = true,
            Finished    = false,
            Callback    = function(v)
                local n = tonumber(v)
                if n then S[key] = n end
            end,
        })
    end

    ------------------------------------------------------------------
    -- 18. Combat tab
    ------------------------------------------------------------------
    local auraSec = Tabs.Combat:AddSection("Kill aura")

    auraSec:AddParagraph({
        Title   = "Read me once",
        Content = "This drives the game's own input simulator, so the server\n"
               .. "builds the release payload exactly like a real press. Damage\n"
               .. "is decided server-side: 42 presses/sec cleared a stage in the\n"
               .. "same time as 1 press/sec, so there is no damage multiplier to\n"
               .. "give you. What this does buy you is that nothing is ever left\n"
               .. "alive or waiting - it targets every tagged enemy the moment it\n"
               .. "spawns instead of waiting for it to walk into 60 studs.",
    })

    local auraInfo = auraSec:AddParagraph({ Title = "Live", Content = "reading..." })

    auraSec:AddToggle("KillAura", {
        Title       = "Kill aura",
        Description = "Attacks the nearest live enemy from CollectionService \"Enemy\"",
        Default     = false,
    }):OnChanged(function(v) S.killAura = v end)

    numberBox(auraSec, "AttacksPerSec", "Attacks per second",
        "Unbounded. Effective rate is still capped by the request budget in Misc.",
        "attacksPerSec")

    numberBox(auraSec, "AuraRange", "Target range (studs)",
        "How far away an enemy may be before we bother with it",
        "auraRange")

    auraSec:AddToggle("SnapToTarget", {
        Title       = "Snap next to the target",
        Description = "The game only accepts targets inside ~60 studs, so we close the gap",
        Default     = true,
    }):OnChanged(function(v) S.snapToTarget = v end)

    numberBox(auraSec, "SnapDistance", "Snap standoff (studs)",
        "How close to stand when snapping. Ignored while Hover is on.",
        "snapDistance")

    auraSec:AddToggle("Hover", {
        Title       = "Hover above the enemies",
        Description = "Floats over the wave so melee swings cannot reach you",
        Default     = true,
    }):OnChanged(function(v) S.hover = v end)

    numberBox(auraSec, "HoverHeight", "Hover height (studs above the floor)",
        "The combat volume is 25.9 studs tall, so anything over 22 puts you\n"
     .. "outside the region the server tests and the stage stops spawning.\n"
     .. "Clamped to that ceiling automatically.",
        "hoverHeight")

    auraSec:AddDropdown("AuraSlots", {
        Title   = "Slots to press",
        Values  = { "Normal attack", "Skill 1", "Skill 2", "Skill 3" },
        Multi   = true,
        Default = { "Normal attack", "Skill 1", "Skill 2", "Skill 3" },
    }):OnChanged(function(sel)
        S.auraSlots = {
            [SLOT_NORMAL] = sel["Normal attack"] == true,
            [1] = sel["Skill 1"] == true,
            [2] = sel["Skill 2"] == true,
            [3] = sel["Skill 3"] == true,
        }
    end)

    ------------------------------------------------------------------
    -- 19. Farm tab
    ------------------------------------------------------------------
    local farmSec  = Tabs.Farm:AddSection("Sequential career farm")
    local farmInfo = farmSec:AddParagraph({ Title = "Status", Content = "idle" })

    farmSec:AddParagraph({
        Title   = "How entry works",
        Content = "The game has no client \"enter stage\" message - the server\n"
               .. "region-tests your position, so we place you inside the stage's\n"
               .. "combat volume and wait for DungeonAggroStage to flip. Waves only\n"
               .. "spawn in the room the *run* has reached (InDungeonChallenge), so\n"
               .. "the rotation walks the corridor forward one front door at a time,\n"
               .. "1 -> 2 -> 3 ..., and holds the top room. If a wave would take\n"
               .. "longer than the limit below to kill, the farm stops there, picks\n"
               .. "the loot up, sells it, ends the run and loops back down to the\n"
               .. "highest stage it can actually finish.",
    })

    farmSec:AddToggle("AutoFarm", {
        Title       = "Auto farm",
        Description = "Walks the stage list in order and re-enters after selling or dying",
        Default     = false,
    }):OnChanged(function(v) S.autoFarm = v end)

    numberBox(farmSec, "StageStart", "First stage", "Where the rotation starts", "stageStart")
    numberBox(farmSec, "StageEnd", "Last stage",
        "0 = CareerMaxStage + 1, so the run also pushes your career forward", "stageEnd")
    numberBox(farmSec, "ClearsPerStage", "Waves to clear per stage",
        "Advance once this many waves have been wiped", "clearsPerStage")
    numberBox(farmSec, "MaxClearSecs", "Give up on a wave over (s)",
        "Health of the wave divided by the damage we are actually doing. Over\n"
     .. "this many seconds the farm stops, collects the loot, sells it, ends\n"
     .. "the run and drops back to a stage it can clear. 60 by default.",
        "maxClearSecs")
    numberBox(farmSec, "SpawnWait", "Give up waiting after (s)",
        "Waves land every ~32s, so anything under ~36 skips live stages by mistake",
        "spawnWait")
    numberBox(farmSec, "StageSeconds", "Seconds per stage (timeout)",
        "Hard cap before moving on, even with a wave alive or loot still down", "stageSeconds")
    numberBox(farmSec, "RetreatHP", "Retreat at HP %",
        "Teleports to the stage safe area below this", "retreatHP")
    numberBox(farmSec, "ReturnHP", "Re-enter at HP %",
        "Goes back in once health recovers to this", "returnHP")

    local rebirthSec  = Tabs.Farm:AddSection("Rebirth")
    local rebirthInfo = rebirthSec:AddParagraph({ Title = "Rebirth", Content = "reading..." })

    rebirthSec:AddToggle("AutoRebirth", {
        Title       = "Auto rebirth",
        Description = "Rebirths as soon as your level reaches the next LvNeed",
        Default     = false,
    }):OnChanged(function(v) S.autoRebirth = v end)

    ------------------------------------------------------------------
    -- 20. Bag tab  (pickup + selling)
    ------------------------------------------------------------------
    local dropSec = Tabs.Bag:AddSection("Pickup")

    dropSec:AddToggle("AutoPickup", {
        Title       = "Auto pickup (walks itself into range)",
        Description = "Teleports inside the 10-stud prompt radius, then fires DROP_PICKUP once",
        Default     = false,
    }):OnChanged(function(v) S.autoPickup = v end)

    numberBox(dropSec, "PickupPerSec", "Scan passes per second",
        "How often to sweep Workspace.DropsClient", "pickupPerSec")

    dropSec:AddParagraph({
        Title   = "Why v3's pickup landed 4 items out of 178 requests",
        Content = "The game picks drops up with a ProximityPrompt, and the server\n"
               .. "enforces the same rules: the drop must have landed, its Stage\n"
               .. "attribute must equal your DungeonAggroStage, you must be within\n"
               .. "10 studs, and the temp bag must have room (capacity is Bag.5,\n"
               .. "which is 4). Blind spam fails all four. This version checks\n"
               .. "each one, teleports into range, and fires a single request.",
    })

    local sellSec  = Tabs.Bag:AddSection("Selling")
    local sellInfo = sellSec:AddParagraph({ Title = "Bag", Content = "reading..." })

    sellSec:AddParagraph({
        Title   = "The full loot chain, verified live",
        Content = "1. DROP_PICKUP puts the item in a server-side temp bag, and\n"
               .. "   Player.LimitBagUsed counts it. It holds 4.\n"
               .. "2. DUNGEON_RETURN_TOWN flushes it into your real bag in about\n"
               .. "   a quarter of a second - that is the \"go back to load your\n"
               .. "   items\" step, and it needs no walking, only the message. It\n"
               .. "   does end the run, so the farm re-enters afterwards.\n"
               .. "3. SELL_MATERIAL {onlyIDList=...} pays out at once (a test of\n"
               .. "   18 rows returned 2,332,883 gold).\n"
               .. "With auto farm on, this runs between stages the moment the\n"
               .. "temp bag fills, so nothing is ever left behind.",
    })

    sellSec:AddToggle("AutoSell", {
        Title       = "Auto sell materials",
        Description = "Flushes the temp bag, then sells every unlocked material",
        Default     = false,
    }):OnChanged(function(v) S.autoSell = v end)

    numberBox(sellSec, "SellSeconds", "Seconds between sell passes",
        "Lower = sells sooner after each pickup", "sellSeconds")

    sellSec:AddToggle("SellFlush", {
        Title       = "Flush temp bag first (returns you to town)",
        Description = "Required for anything picked up inside a stage; farm re-enters after",
        Default     = true,
    }):OnChanged(function(v) S.sellFlush = v end)

    sellSec:AddToggle("KeepAlchemy", {
        Title       = "Keep alchemy recipe materials",
        Description = "Skips anything marked by the alchemy system",
        Default     = true,
    }):OnChanged(function(v) S.keepAlchemy = v end)

    sellSec:AddButton({
        Title       = "Sell now",
        Description = "Flush + sell immediately, once",
        Callback    = function() S.sellNow = true end,
    })

    sellSec:AddButton({
        Title       = "Flush temp bag now",
        Description = "Fires DUNGEON_RETURN_TOWN so pending loot lands in your bag",
        Callback    = function() S.flushNow = true end,
    })

    ------------------------------------------------------------------
    -- 21. Train tab
    ------------------------------------------------------------------
    local trainSec  = Tabs.Train:AddSection("Training")
    local trainInfo = trainSec:AddParagraph({ Title = "Live", Content = "reading..." })

    trainSec:AddParagraph({
        Title   = "What changed",
        Content = "v2 awaited every tap, and Roblox serialises RemoteFunction\n"
               .. "calls per client, so it ran at 1/ping. Taps are now fired on\n"
               .. "their own threads, so the rate is limited by the request budget\n"
               .. "instead of latency. The zone auto-move is gone: gain per tap\n"
               .. "comes from your wand's trainBase server-side, and standing in a\n"
               .. "training ground actively blocks manual taps.",
    })

    trainSec:AddToggle("AutoTrain", {
        Title       = "Auto train",
        Description = "No animation, no interval to tune, works anywhere outside a train zone",
        Default     = false,
    }):OnChanged(function(v) S.autoTrain = v end)

    numberBox(trainSec, "TapsPerSec", "Taps per second",
        "Unbounded here; the request budget in Misc is the real ceiling",
        "tapsPerSec")

    ------------------------------------------------------------------
    -- 22. Shop tab
    ------------------------------------------------------------------
    local wandSec  = Tabs.Shop:AddSection("Wands")
    local wandInfo = wandSec:AddParagraph({ Title = "Gold", Content = "reading..." })

    local wandNames = {}
    for _, w in ipairs(wandList) do wandNames[#wandNames + 1] = w.name end
    S.wandChoice = wandNames[1]

    wandSec:AddDropdown("WandMode", {
        Title   = "Mode",
        Values  = { "Unlock all wands", "Choose wand to buy" },
        Multi   = false,
        Default = 1,
    }):OnChanged(function(v) S.wandMode = v end)

    wandSec:AddDropdown("WandChoice", {
        Title       = "Wand",
        Description = "Only used in \"Choose wand to buy\" mode",
        Values      = wandNames,
        Multi       = false,
        Default     = 1,
    }):OnChanged(function(v) S.wandChoice = v end)

    wandSec:AddToggle("AutoBuyWand", {
        Title       = "Auto buy when affordable",
        Description = "Gold purchases only - Robux and event wands are skipped",
        Default     = false,
    }):OnChanged(function(v) S.autoBuyWand = v end)

    wandSec:AddToggle("EquipAfterBuy", {
        Title       = "Equip after buying",
        Description = "Sends EQUIP_SHOP_EQUIP with the same payload shape as the buy call",
        Default     = true,
    }):OnChanged(function(v) S.equipAfterBuy = v end)

    ------------------------------------------------------------------
    -- 23. Stats tab
    ------------------------------------------------------------------
    local statsPara   = Tabs.Stats:AddParagraph({ Title = "Player",  Content = "reading..." })
    local walletPara  = Tabs.Stats:AddParagraph({ Title = "Wallet",  Content = "reading..." })
    local sessionPara = Tabs.Stats:AddParagraph({ Title = "Session", Content = "reading..." })

    local SHOWN_ATTRS = { 1, 5, 4, 9, 11, 12, 13, 19, 21 }
    local SHOWN_ITEMS = { 1, 8, 10, 14, 16, 17 }

    ------------------------------------------------------------------
    -- 24. Misc tab
    ------------------------------------------------------------------
    local perfSec = Tabs.Misc:AddSection("Performance")

    perfSec:AddToggle("PerfMode", {
        Title       = "Improve performance",
        Description = "Lowest quality, no shadows/particles/trails, flat water",
        Default     = false,
    }):OnChanged(function(v) S.perfWanted = v end)

    perfSec:AddButton({
        Title       = "Clear debris & temp folders",
        Description = "One-off sweep of accumulated effect junk",
        Callback    = function()
            local n = 0
            for _, name in ipairs({ "Debris", N_TEMP, "Sound3D" }) do
                local f = Workspace:FindFirstChild(name)
                if f then
                    for _, c in ipairs(f:GetChildren()) do c:Destroy(); n += 1 end
                end
            end
            Fluent:Notify({
                Title = "Cleanup",
                Content = ("Removed %d object(s)"):format(n),
                Duration = 3,
            })
        end,
    })

    local paceSec = Tabs.Misc:AddSection("Request budget")

    paceSec:AddParagraph({
        Title   = "Why this exists",
        Content = "ToolSystem.RequestRateLimit drops anything past 20 requests per\n"
               .. "second per message name, and the server also flags 10+ distinct\n"
               .. "message names inside 5 seconds. 18 leaves headroom for the\n"
               .. "game's own traffic. Raising it does not make anything faster -\n"
               .. "it just gets requests thrown away.",
    })

    numberBox(paceSec, "ReqPerSec", "Max requests/sec per message", "Server hard limit is 20",
        "reqPerSec")

    local infoSec    = Tabs.Misc:AddSection("Server")
    local serverInfo = infoSec:AddParagraph({ Title = "Info", Content = "reading..." })

    infoSec:AddButton({
        Title       = "Unload hub",
        Description = "Stops every loop and destroys the UI",
        Callback    = function()
            if _G.__MagicLootHub then
                task.spawn(function() _G.__MagicLootHub:Unload() end)
            end
        end,
    })

    ------------------------------------------------------------------
    -- 25. Status refresh  (UI only - no network calls in here)
    ------------------------------------------------------------------
    local function refresh()
        local count, level, need = rebirthStatus()

        local lines = { ("Level %d   Rebirths %d"):format(level, count) }
        for _, id in ipairs(SHOWN_ATTRS) do
            local row = Conf.plrdataConf[id]
            local v = attr(id)
            lines[#lines + 1] = ("%s: %s"):format(
                label("plrdataConf", id, "Attr " .. id),
                (row and tostring(row.isPercent) == "1")
                    and ("%.2f%%"):format(v * 100) or short(v))
        end
        statsPara:SetDesc(table.concat(lines, "\n"))

        local wallet = {}
        for _, id in ipairs(SHOWN_ITEMS) do
            wallet[#wallet + 1] = ("%s: %s")
                :format(label("itemdataConf", id, "Item " .. id), short(bag(id)))
        end
        wallet[#wallet + 1] = ("Temp bag pending: %d / %d"):format(limitBagUsed(), bag(5))
        walletPara:SetDesc(table.concat(wallet, "\n"))

        sessionPara:SetDesc(table.concat({
            ("Pickup requests: %s"):format(comma(S.picked)),
            ("Training taps: %s"):format(comma(S.trained)),
            ("Attack presses: %s"):format(comma(S.casts)),
            ("Items sold: %s (~%s gold)"):format(comma(S.sold), short(S.goldFromSales)),
            ("Waves cleared: %s"):format(comma(S.kills)),
            ("Temp bag flushes: %d"):format(S.flushes),
            ("Wands bought: %d    Rebirths: %d"):format(S.bought, S.rebirths),
            ("Last: %s"):format(S.note),
        }, "\n"))

        rebirthInfo:SetDesc(need
            and ("Rebirth %d -> %d needs level %d. You are level %d.")
                :format(count, count + 1, need, level)
            or ("Rebirth %d is the maximum."):format(count))

        local up = #enemyList(nil)
        local _, dist = nearestEnemy(nil)
        auraInfo:SetDesc(table.concat({
            ("Enemies tagged alive: %d"):format(up),
            ("Nearest: %s"):format(dist < math.huge
                and ("%d studs"):format(math.floor(dist)) or "none"),
            ("Holding a wand: %s"):format(holdingWeapon() and "yes" or "NO - aura cannot fire"),
            ("Presses sent: %s"):format(comma(S.casts)),
        }, "\n"))

        farmInfo:SetDesc(table.concat({
            ("Rotation: %d -> %d"):format(
                math.clamp(math.floor(num(S.stageStart, 1)), 1, MAX_STAGE), stageCeiling()),
            ("Now: %s"):format(S.farmPhase),
            ("Measured damage: %s/s   give up over %ds"):format(
                short(S.dps), math.floor(num(S.maxClearSecs, 60))),
            ("DungeonAggroStage %d   InDungeonChallenge %d   SafeArea %d"):format(
                flag("DungeonAggroStage"), flag("InDungeonChallenge"), flag("InStageSafeArea")),
            ("HP %d%%   CareerMaxStage %d"):format(
                math.floor(hpFrac() * 100), flag("CareerMaxStage")),
        }, "\n"))

        sellInfo:SetDesc(table.concat({
            ("Pending in temp bag: %d"):format(limitBagUsed()),
            ("Sold this session: %s"):format(comma(S.sold)),
            ("Flushes: %d"):format(S.flushes),
        }, "\n"))

        trainInfo:SetDesc(table.concat({
            ("Taps: %s   in flight: %d"):format(comma(S.trained), S.trainInFlight),
            ("Gain per tap (server): %s"):format(short(S.trainGain)),
            ("In a training ground: %s"):format(flag("InTrainGround") == 1
                and "yes - taps are being ignored" or "no"),
        }, "\n"))

        wandInfo:SetDesc(("Gold: %s\nGold-purchasable wands: %d")
            :format(short(bag(1)), #wandList))

        serverInfo:SetDesc(table.concat({
            ("Players: %d"):format(#Players:GetPlayers()),
            ("Event: %s"):format(label("eventConf", flag("curEventId"), "none")),
            ("Hub: v3"),
        }, "\n"))
    end

    ------------------------------------------------------------------
    -- 26. Workers
    ------------------------------------------------------------------
    local function every(period, fn)
        task.spawn(function()
            while S.running and not Fluent.Unloaded do
                pcall(fn)
                task.wait(period)
            end
        end)
    end

    -- Rate comes from a number box, so re-read it on every iteration.
    local function paced(rateKey, fn)
        task.spawn(function()
            while S.running and not Fluent.Unloaded do
                pcall(fn)
                local rate = math.max(0.05, num(S[rateKey], 1))
                task.wait(1 / rate)
            end
        end)
    end

    every(0.4, refresh)
    every(0.2, watchDamage)

    startHoverWorker()

    -- Drop the hover the moment the features that use it are switched off, so
    -- toggling farm/aura off puts the character back on the floor.
    every(0.3, function()
        if hoverAt and not (S.hover and (S.autoFarm or S.killAura)) then hoverStop() end
    end)

    -- The farm is useless without attacks, and leaving that to a separate toggle
    -- is how a 150s run ended with 5 monsters alive and zero presses sent: the
    -- Kill aura switch was off, so nothing ever fired.  Auto farm therefore drives
    -- the attack loop itself; the toggle only matters when farming is off.
    paced("attacksPerSec", function()
        if S.killAura or S.autoFarm then auraTick() end
    end)
    paced("pickupPerSec",  function() if S.autoPickup then pickupPass() end end)
    paced("tapsPerSec",    function() if S.autoTrain then trainTick() end end)

    task.spawn(farmWorker)

    every(0.25, function()
        if S.flushNow then
            S.flushNow = false
            local ok, why = flushTempBag()
            if not ok then S.note = "flush: " .. why end
        end
        if S.sellNow then
            S.sellNow = false
            sellEverything()
        end
    end)

    task.spawn(function()
        while S.running and not Fluent.Unloaded do
            -- With auto farm on, the farm cashes out between stages instead, so
            -- the flush never lands in the middle of a fight.
            if S.autoSell and not S.autoFarm then pcall(sellEverything) end
            task.wait(math.max(1, num(S.sellSeconds, 6)))
        end
    end)

    every(2.0, function() if S.autoBuyWand then wandTick() end end)

    every(3.0, function()
        if S.autoRebirth then
            local _, _, _, eligible = rebirthStatus()
            if eligible then rebirthOnce() end
        end
    end)

    every(0.5, function()
        if S.perfWanted ~= S.perfApplied then applyPerformance(S.perfWanted) end
    end)

    ------------------------------------------------------------------
    -- 27. Config persistence
    ------------------------------------------------------------------
    SaveManager:SetLibrary(Fluent)
    InterfaceManager:SetLibrary(Fluent)
    SaveManager:IgnoreThemeSettings()
    SaveManager:SetIgnoreIndexes({})
    InterfaceManager:SetFolder("MagicLootHub")
    SaveManager:SetFolder("MagicLootHub/configs")
    InterfaceManager:BuildInterfaceSection(Tabs.Settings)
    SaveManager:BuildConfigSection(Tabs.Settings)

    Window:SelectTab(1)
    Fluent:Notify({
        Title    = "Magic Loot hub v3",
        Content  = "Everything starts off. Left Ctrl minimises.",
        Duration = 6,
    })
    pcall(function() SaveManager:LoadAutoloadConfig() end)

    ------------------------------------------------------------------
    -- 28. Public API
    ------------------------------------------------------------------
    local API = {
        Fluent = Fluent, Window = Window, Tabs = Tabs, State = S, Wands = wandList,

        -- combat
        Enemies = enemyList, NearestEnemy = nearestEnemy, Press = press, AuraTick = auraTick,
        -- farm
        EnterStage = enterStage, HoldStage = holdStage, InStage = inStage,
        CombatStand = combatStand, SafeStand = safeStand, StageCeiling = stageCeiling,
        StagePlayable = stagePlayable, DiscoverStages = discoverStages,
        AwaitStage = awaitStage, EndRun = endRun, RunStage = runStage,
        HighestPlayable = highestPlayable,
        -- bag
        PickupPass = pickupPass, SellableRows = sellableRows, Sell = sellEverything,
        FlushTempBag = flushTempBag, LimitBagUsed = limitBagUsed, TempCap = tempCap,
        -- misc
        TrainTick = trainTick, BuyWand = buyWand, EquipWand = equipWand, WandTick = wandTick,
        RebirthOnce = rebirthOnce, RebirthStatus = rebirthStatus,
        Performance = applyPerformance, Refresh = refresh,
    }

    function API:Unload()
        S.running = false
        for _, k in ipairs({ "killAura", "autoFarm", "autoPickup", "autoSell",
                             "autoTrain", "autoBuyWand", "autoRebirth" }) do
            S[k] = false
        end
        -- Drop the handle first.  Fluent:Destroy() yields, so clearing the global
        -- afterwards let a reload that unloaded the old hub from another thread
        -- register the new one and *then* have this line wipe it - the hub looked
        -- like it had vanished a dozen seconds after a clean load.
        if _G.__MagicLootHub == API then _G.__MagicLootHub = nil end
        cancelMove()
        hoverStop()
        if hoverConn then pcall(function() hoverConn:Disconnect() end) hoverConn = nil end
        applyPerformance(false)
        pcall(function() Fluent:Destroy() end)
    end

    _G.__MagicLootHub = API
    return API
end

return CreateMagicLootHub()
