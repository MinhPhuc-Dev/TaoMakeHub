--[[=========================================================================
    Magic Loot  -  Fluent Hub v4
    UI: Fluent (dawid-scripts).  Toggles only - every rate and threshold is a
    constant below, set to the value that measured best over ~20 farm runs.
    One switch (OneClick) runs the whole economy loop.

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
    old number boxes bought request *rate* - never a damage or gain multiplier.
    The real throughput lever for farming is stage rotation speed, so the rates
    below are pinned at the point where nothing waits and nothing is dropped.

    Pacing: ToolSystem.RequestRateLimit allows 20 requests/second per message
    name.  The gate below is fixed at 18, which leaves the game's own traffic
    room; raising it only gets requests thrown away.
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
    local HttpService       = game:GetService("HttpService")
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
    --
    -- The numbers here used to be number boxes.  They are constants now: the
    -- values are the ones that measured best (+22.1M gold / 200s on the run
    -- that set them), and every one of them is a rate or a safety margin that
    -- has a right answer rather than a preference.
    local S = {
        running = true,

        -- combat
        killAura      = false,
        auraSlots     = { [SLOT_NORMAL] = true, [1] = true, [2] = true, [3] = true },
        attacksPerSec = 14,      -- presses/s; the wand's own rhythm gates the rest
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
        stageSeconds  = 120,     -- safety wall-clock only; the ETA rule decides
        spawnWait     = 40,      -- a wave lands every ~32s, so wait one out
        clearsPerStage = 1,      -- advance after this many cleared waves
        etaLimit      = 35,      -- health / dps over this many seconds = walk away
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
        pickupPerSec  = 5,       -- scan passes per second
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
        tapsPerSec    = 14,
        trainInFlight = 0,
        trainGain     = 0,

        -- shop
        autoBuyWand   = false,
        wandMode      = "Unlock all wands",
        wandChoice    = nil,
        equipAfterBuy = true,

        -- rebirth
        autoRebirth   = false,

        -- one click
        oneClick      = false,
        ocFarm        = true,
        ocCollect     = true,
        ocSell        = true,
        ocTrain       = true,
        ocWand        = true,
        ocRebirth     = true,

        -- webhook
        hookUrl       = "",
        hookRarity    = 6,       -- notify on drops at this xyd rarity or above
        hookItems     = true,
        hookRebirth   = true,
        hookSales     = true,
        hookTest      = false,
        hookSent      = 0,
        hookFail      = "",

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

    ------------------------------------------------------------------
    -- 5a. Webhook  (the user's own URL - nothing is hard-coded)
    ------------------------------------------------------------------
    -- One HTTP POST per event would rate-limit a Discord webhook inside a
    -- second (a single wave drops 11 items), so events are queued as lines and
    -- a worker posts one batched message every few seconds.  Everything here is
    -- pcall'd and off the farm's thread: a dead URL must never stall a run.
    local RARITY = {
        "Common", "Uncommon", "Fine", "Rare", "Epic", "Legendary",
        "Mythic", "Ancient", "Divine", "Celestial", "Transcendent",
    }
    local function rarityName(x)
        x = math.floor(num(x, 0))
        return RARITY[x] or ("Rarity " .. x)
    end

    local hookQueue, hookLast = {}, 0

    local function httpPost(url, payload)
        local rq = rawget(_G, "request") or rawget(_G, "http_request")
            or (type(syn) == "table" and syn.request)
            or (type(http) == "table" and http.request)
        if type(rq) ~= "function" then return false, "executor has no request()" end
        local ok, res = pcall(rq, {
            Url     = url,
            Method  = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body    = HttpService:JSONEncode(payload),
        })
        if not ok then return false, tostring(res) end
        local code = tonumber(type(res) == "table" and res.StatusCode) or 0
        if code >= 200 and code < 300 then return true, "ok" end
        return false, ("HTTP %d"):format(code)
    end

    local function hookPush(line)
        if S.hookUrl == "" or not line then return end
        if #hookQueue >= 60 then return end          -- never grow without bound
        hookQueue[#hookQueue + 1] = tostring(line)
    end

    local function hookFlush()
        if S.hookUrl == "" or #hookQueue == 0 then return end
        if os.clock() - hookLast < 3 then return end -- Discord allows ~30/min
        hookLast = os.clock()
        local lines = {}
        while #hookQueue > 0 and #lines < 14 do
            lines[#lines + 1] = table.remove(hookQueue, 1)
        end
        local body = table.concat(lines, "\n"):sub(1, 1900)
        local ok, why = httpPost(S.hookUrl, {
            username = "Magic Loot Hub",
            content  = body,
        })
        if ok then
            S.hookSent += #lines
            S.hookFail = ""
        else
            S.hookFail = why
        end
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

    -- The run has to be walked from stage 1 anyway, and the ceiling is the career
    -- gate itself - CareerMaxStage.  It used to aim one room higher on the theory
    -- that the server lets you knock on the next door; measured, it does not: with
    -- CareerMaxStage 11 the door to 12 refused every attempt, and each lap spent
    -- 40-80s on it (including clearing stage 11's 425B wave for nothing) and then
    -- churned the corridor instead of farming.  A whole 300s window earned zero
    -- gold that way.  When the career gate moves, this follows it on its own.
    local function stageCeiling()
        if num(S.stageEnd, 0) > 0 then
            return math.clamp(math.floor(S.stageEnd), 1, MAX_STAGE)
        end
        local cm = LP:FindFirstChild("CareerMaxStage")
        local career = cm and math.floor(tonumber(cm.Value) or 1) or 1
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

    -- Temp-bag capacity is not knowable from the client.  Nothing in
    -- AllSideCode mentions LimitBagUsed, SystemDrop-Type and SystemBag-Type
    -- carry no bag/limit strings, and Bag.5 ("+1 Slot Space") is only a mirror
    -- that grows as upgrades drop - it has read 4, 5, 6, 7 and 8 on this
    -- account inside one session.  Selling on a stale number is the bug: at a
    -- remembered cap of 4 we banked (and ended the run) with half a bag, and at
    -- a cap of 8 that the server did not honour we stood next to loot we would
    -- not pick up.  So the cap is learned from what the server actually allows:
    --   * every count we successfully reach raises it;
    --   * three refusals in a row while standing on a landed drop pins it;
    --   * a later success, or a higher Bag.5, forgets the pin again.
    local capKnown, capFull, capFullAt = 0, 0, 0
    local capMiss = {}

    local function tempHint()
        local bagF = LP:FindFirstChild("Bag")
        local v = bagF and bagF:FindFirstChild("5")
        return math.max(1, math.floor(tonumber(v and v.Value) or 4))
    end

    local function tempCap()
        if capFull > 0 and tempHint() <= capFullAt then return capFull end
        return math.max(1, tempHint(), capKnown)
    end

    -- The only question the rest of the hub asks: may we still carry anything?
    local function bagFull()
        local used = limitBagUsed()
        return used > 0 and used >= tempCap()
    end

    -- Called after every DROP_PICKUP whose radius condition we know we met.
    local function notePickup(before, after)
        if after > before then
            capKnown = math.max(capKnown, after)
            capMiss  = {}
            if capFull > 0 and after >= capFull then capFull = 0 end
            return true
        end
        -- A refusal at count 0 is a range or replication miss, never a full bag.
        if before <= 0 then return false end
        capMiss[before] = (capMiss[before] or 0) + 1
        if capMiss[before] >= 3 then
            capFull, capFullAt = before, tempHint()
        end
        return false
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
                        -- Every drop carries its own price tag: GoldValue, ItemId
                        -- and Xyd (rarity, also the bucket's name).  That is what
                        -- makes "grab the expensive one first" possible without a
                        -- config join - and it matters, because one bag holds 5-8
                        -- items while a wave drops 11, so whatever we skip is lost.
                        local id = tonumber(d:GetAttribute("ItemId"))
                        out[#out + 1] = {
                            id     = d.Name,
                            pos    = part.Position,
                            gold   = tonumber(d:GetAttribute("GoldValue")) or 0,
                            rarity = math.floor(tonumber(d:GetAttribute("Xyd")) or 0),
                            item   = id,
                            name   = id and label("materialConf", id, "Item " .. id)
                                     or ("Drop " .. d.Name),
                        }
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
        if bagFull() then
            S.needFlush = true
            S.note = ("pickup: temp bag full at %d, selling"):format(limitBagUsed())
            return 0
        end

        local drops = dropList()
        if #drops == 0 then return 0 end
        local hrp = root()
        if not hrp then return 0 end

        -- Highest value first.  Nearest-first was the wrong sort: a stage-10 wave
        -- mixes 5.5K commons with 250K+ rarities, the bag holds a fraction of the
        -- wave, and the flush that empties it ends the run - so whatever is left
        -- behind is left behind for good.  Distance only breaks ties (the walk
        -- costs a fraction of a second either way).
        local here = hrp.Position
        table.sort(drops, function(a, b)
            if a.gold ~= b.gold then return a.gold > b.gold end
            return (a.pos - here).Magnitude < (b.pos - here).Magnitude
        end)

        local got = 0
        -- The prompt radius is 10 studs and the drops lie on the floor, so a
        -- 14-stud hover is out of range.  Release the hover for the duration of
        -- the pass and put it back afterwards.
        local resumeHover = hoverAt
        hoverAt = nil
        for _, d in ipairs(drops) do
            if bagFull() then S.needFlush = true break end
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
                hrp = root() or hrp
                local inRange = (d.pos - hrp.Position).Magnitude <= DROP_REACH
                local before = limitBagUsed()
                if pcall(NetWork.FireServer, NetMsg.DROP_PICKUP, d.id) then
                    local landed = false
                    for _ = 1, 8 do
                        task.wait(0.05)
                        if limitBagUsed() > before then landed = true break end
                    end
                    -- Only a refusal we know was in range teaches us the cap.
                    if inRange then notePickup(before, limitBagUsed()) end
                    if landed then
                        got += 1
                        S.picked += 1
                        if S.hookItems and d.rarity >= math.floor(num(S.hookRarity, 6)) then
                            hookPush(("**%s** [%s] - %s gold (stage %d)")
                                :format(d.name, rarityName(d.rarity), comma(d.gold),
                                        flag("DungeonAggroStage")))
                        end
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
            S.note = ("pickup: %d drop(s) in, %d/%d temp slot(s) used")
                :format(got, limitBagUsed(), tempCap())
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

    -- DUNGEON_RETURN_TOWN clears InDungeonChallenge first and *then* teleports
    -- you to the lobby spawn: measured, the flag was already 0 when the message
    -- returned after 0.10s, and the server's move landed 0.62s later, dropping
    -- the character at (-451.3, 10.1, 38.1) which then slid to (-448.1, 7.8,
    -- 35.1).  That late pull is the stage-1 reloop bug - the farm read run=0,
    -- started tweening onto stage 1's front door, and got yanked back to the
    -- spawn mid-tween, so the door region test never saw us and the run sat at 0
    -- for 35s.  Waiting the pull out first made door 1 open in 0.27s.
    --
    -- There is no event for it, so this watches the position instead and returns
    -- once it has stopped moving on its own.
    local function settleAfterTown(maxSecs)
        cancelMove()
        hoverStop()
        local hrp = root()
        if not hrp then task.wait(0.6) return end
        local t0, last, still = os.clock(), hrp.Position, 0
        while os.clock() - t0 < (maxSecs or 2.5) do
            task.wait(0.12)
            hrp = root() or hrp
            local p = hrp.Position
            local moved = (p - last).Magnitude
            last = p
            if moved < 1.2 then
                still += 0.12
                -- The pull arrives ~0.6s in, so "already still" is not enough
                -- on its own; give it long enough to have happened.
                if still >= 0.36 and os.clock() - t0 > 0.75 then return end
            else
                still = 0
            end
        end
    end

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
        settleAfterTown(2.5)
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
            if S.hookSales then
                hookPush((":coin: Sold %d item(s) for ~%s gold  (total this session %s)")
                    :format(done, comma(worth), short(S.goldFromSales)))
            end
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
        -- The flag clears ~0.6s before the town teleport actually lands, so
        -- returning here as soon as it flips hands the caller a character that
        -- is about to be moved out from under it.  See settleAfterTown.
        settleAfterTown(2.5)
        return runStage() <= 0
    end

    -- Confirmed live, and it is the rule the whole corridor turns on: the run
    -- advances one door at a time, and the server only lets it advance when the
    -- room the run is *currently* sitting in has no live monsters left.  Probe:
    -- standing on door 3 with two of stage 2's wave still up, the door refused for
    -- the full 12s; the same door opened in 0.9s the moment the room behind was
    -- clear.  A room spawns its wave ~1-2s after it opens, so a brisk climb
    -- usually beats the spawn and every door looks free - which is exactly why the
    -- stalls looked random.  When the climb loses that race the answer is to go
    -- back one room and kill, not to write the stage above off as a career gate.
    --
    -- Standing on door k puts us inside stage k's own volume, so the aura - which
    -- deliberately locks onto our own room - cannot see the wave behind us.
    -- Dropping into stage k-1's combat volume is what makes it a target.
    local function clearFrontier(secs)
        local st = runStage()
        if st <= 0 then return true end
        if #enemyList(st) == 0 then return true end
        hoverStop()
        teleport(combatStand(st))
        local t0 = os.clock()
        while os.clock() - t0 < (secs or 12) do
            local up = #enemyList(st)
            if up == 0 then return true end
            S.farmPhase = ("clearing stage %d to open the next door (%d up)")
                :format(st, up)
            auraTick()
            task.wait(0.2)
            if not S.running then return false end
        end
        return #enemyList(st) == 0
    end

    -- The run only ever starts from town, and "in town" is the server's opinion,
    -- not ours.  Measured after a flush taken at stage 10: the character was
    -- standing on door 1 with DungeonAggroStage still reading 1, then 8, then 9 -
    -- the server had not let go of the room we came from - and every door touch
    -- was ignored for 60s.  The tick the aggro flag finally read 0, the door
    -- opened immediately.  So wait for that flag rather than for the character to
    -- merely stop moving.
    local function returnToLobby(secs)
        settleAfterTown(2.0)
        local home = lobbyStand() or Vector3.new(-451.29, 10.09, 38.10)
        local t0 = os.clock()
        repeat
            teleport(home)
            if flag("DungeonAggroStage") <= 0 then return true end
            S.farmPhase = ("in town, waiting for stage %d to let go")
                :format(flag("DungeonAggroStage"))
            task.wait(0.3)
        until os.clock() - t0 > (secs or 5) or not S.running
        return flag("DungeonAggroStage") <= 0
    end

    -- Push the run forward to stage n, one front door at a time.  Stages the
    -- run has already opened are free to jump straight back to.
    local function openRunTo(n)
        hoverStop()          -- the door region checks are on the floor
        S.farmWalking = true
        if runStage() <= 0 then
            -- Belt and braces with settleAfterTown: this is also reached when the
            -- run was never open (a fresh start, a death, a manual flush from the
            -- Bag tab), and in every one of those cases something else may still
            -- be moving the character.  Walking to a door while the server is
            -- teleporting us is the whole stage-1 stall.
            S.farmPhase = "waiting for the town teleport to land"
            returnToLobby(5)
            task.wait(0.2)
        end
        for k = math.max(1, runStage() + 1), n do
            if not S.running then
                S.farmWalking = false
                return false
            end
            -- The run can lose ground under us: standing in a room it has not
            -- opened - which is what streaming a far stage used to do - makes the
            -- server rewind the challenge and pull us to town.  Pushing door k
            -- when the run is two or more rooms behind can never work, so hand
            -- back and let the rotation restart the walk from where it really is.
            if runStage() < k - 1 then
                S.note = ("farm: the run fell back to %d during the walk to %d")
                    :format(runStage(), n)
                S.farmWalking = false
                return false
            end
            streamAround(doorStand(k))
            local opened = false
            for attempt = 1, 3 do
                S.farmPhase = (attempt == 1)
                    and ("opening the run: stage %d"):format(k)
                    or  ("opening the run: stage %d (try %d)"):format(k, attempt)
                local t0 = os.clock()
                repeat
                    -- Re-assert the position every quarter second.  Arriving once
                    -- and then only watching the flag looked cheaper and was much
                    -- worse: doors that used to open in ~3.5s started timing out
                    -- at 7s, and the run sat at 0 for 35s.  The server's region
                    -- test wants the position replicated repeatedly, and the
                    -- character drifts.
                    teleport(doorStand(k))
                    task.wait(0.25)
                until runStage() >= k or os.clock() - t0 > 5 or not S.running
                if runStage() >= k then
                    opened = true
                    break
                end
                if not S.running then
                    S.farmWalking = false
                    return false
                end
                -- A refused door is nearly always one of two curable things, and
                -- they have different answers.  Something still alive in the room
                -- behind us holds the door shut by design, so go back and kill it.
                -- If the run is not open at all, the town pull is still in flight
                -- or the server has not let go of the room we left, and both of
                -- those clear from the lobby.  Neither is the career limit, which
                -- is what the rotation used to conclude - and it cost the top stage
                -- every time.
                --
                -- What must NOT happen is a trip to town while the run is live:
                -- standing in the lobby abandons the challenge outright.  Measured
                -- with that mistake in place, every lap climbed to stage 10, the
                -- retry walked to the lobby, the server reset the run to 0, and a
                -- 300s window earned nothing at all.
                if runStage() > 0 and #enemyList(runStage()) > 0 then
                    clearFrontier(14)
                elseif runStage() <= 0 then
                    returnToLobby(4)
                else
                    task.wait(0.4)
                end
            end
            if not opened then
                S.note = ("farm: the run stalled at stage %d (door %d refused)")
                    :format(runStage(), k)
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
        -- Walk first, stream second.  awaitStage brings a far room in by standing
        -- in it, and doing that *before* the run has opened it is a trap: the
        -- server registered us in stage 12 (DungeonAggroStage jumped straight to
        -- 12 with the run still at 0), rewound the challenge and pulled us back to
        -- town - which is exactly the reported "walks to the stage 1 gate and gets
        -- yanked to some other position" bug, and it cost a 300s window every
        -- gold piece it should have earned.  The corridor walk streams every room
        -- it passes through anyway, so by the time the run reaches n the model is
        -- normally already here.
        if runStage() < n and not openRunTo(n) then
            S.farmWalking = false
            return false
        end
        if not awaitStage(n, 5) then
            S.note = ("farm: stage %d never streamed in"):format(n)
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
    local dpsAttack = 0            -- Attack value the dps estimate was taken at
    local function holdStage(stage)
        local deadline  = os.clock() + math.max(5, num(S.stageSeconds, 70))
        local spawnGive = os.clock() + math.max(1, num(S.spawnWait, 36))
        local wanted    = math.max(1, math.floor(num(S.clearsPerStage, 1)))
        local sawEnemy  = false
        local sawAny    = false     -- did anything at all spawn in this window
        local lastCash  = 0
        local emptySince = nil      -- clock since the room went completely quiet
        S.farmClears = 0

        -- Damage meter.  The v3 version only counted health that dropped while an
        -- enemy was still listed, so the killing blow - which is most of the wave's
        -- health when a wave dies inside one 0.2s tick - was thrown away.  It read
        -- 3.5M/s against a real 4e9/s, the ETA rule believed it, and the farm
        -- capped itself at stage 6 (stage 7's 200M "needed" 56s).  Track health per
        -- enemy instead and treat a vanished enemy as having gone to zero, so the
        -- kill lands in the total.
        local prevHP, prevSum = {}, 0
        local fightSecs, damage = 0, 0
        local lastTick = os.clock()

        -- A rebirth or a wand swap changes damage by orders of magnitude, and a
        -- peak-hold meter would keep quoting the old number forever.  Re-base it
        -- whenever Attack moves more than a fifth either way.
        local atkNow = attr(1)
        if dpsAttack <= 0 or atkNow <= 0
           or atkNow > dpsAttack * 1.2 or atkNow < dpsAttack * 0.8 then
            dpsAttack = atkNow
            S.dps = 0
        end

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

            -- The temp bag is 5-8 slots and one wave drops 11 items, so it fills
            -- mid-hold.  Deferring the flush until the window ends loses every
            -- drop after that point: measured, five items sat on the floor for
            -- 30s with LimitBagUsed pinned and gold unchanged.  Cash out the
            -- moment the server says we are actually full.  The flush also ends
            -- the run, so hand straight back to the rotation and let it re-walk
            -- the corridor.
            if S.autoSell and bagFull() and os.clock() - lastCash > 3 then
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
            local sum, strongest = 0, 0
            local nowHP = {}
            for _, e in ipairs(mobs) do
                sum += e.hum.Health
                nowHP[e.model] = e.hum.Health
                if e.hum.Health > strongest then strongest = e.hum.Health end
            end
            local dt = os.clock() - lastTick
            lastTick = os.clock()

            -- Anything we saw last tick that is missing or lower now cost it that
            -- much health; a model that is simply gone died, so its whole last
            -- reading counts.  That is the tick where nearly all of the damage in
            -- a one-shot wave actually happens.
            local dealt = 0
            for model, was in pairs(prevHP) do
                local isNow = nowHP[model] or 0
                if was > isNow then dealt += (was - isNow) end
            end
            if prevSum > 0 then
                damage += dealt
                fightSecs += dt
                -- Peak, not average.  The meter can only ever *under*-read: a wave
                -- smaller than one tick of our damage caps `dealt` at its own
                -- health, so stage 2's 247 HP wave measured 617/s and the running
                -- average carried that lie into the ETA rule, which then called
                -- every room above 6 too tanky.  Damage capability does not drop
                -- between waves, so keep the best rate seen and let the attack
                -- floor in the ETA rule cover the cold start.
                if fightSecs > 1.0 and damage > 0 then
                    local rate = damage / fightSecs
                    if rate > S.dps then S.dps = rate end
                end
            end
            prevHP, prevSum = nowHP, sum

            -- The give-up rule is arithmetic, not a stopwatch.  Waiting out a
            -- 35s window to discover a room is unfarmable costs 35s every lap;
            -- the wave's health divided by our damage answers it on the first
            -- tick.  Attack (Attrs.1) x ~3 is the fallback until a wave has
            -- actually been measured - live readings were 3.3-5e9/s against an
            -- Attack of 1.12e9 - so even a room entered cold is judged at once.
            -- Stage 11 is the case that matters: 442B of health is ~130s at our
            -- damage, and it is now abandoned in the first fraction of a second
            -- instead of after a full window of chipping at it.
            if up > 0 then
                -- Attack x2 is the floor: measured 2e10/s against an Attack of
                -- 8.3e9, and 3.3-5e9/s against 1.12e9 earlier in the session, so
                -- the ratio holds across wands.  Using it as a floor means a
                -- rebirth or a new wand is priced in immediately, with no window
                -- spent re-measuring, and a stale peak can never be the only
                -- number the decision rests on.
                local rate = math.max(S.dps, attr(1) * 2)
                local cap  = math.max(5, num(S.etaLimit, 35))
                if rate > 0 then
                    local eta = sum / rate
                    if eta > cap then
                        S.note = ("farm: stage %d wave is %s HP (biggest %s) at %s dps"
                               .. " - %ds to clear, over the %ds limit")
                            :format(stage, short(sum), short(strongest), short(rate),
                                    math.floor(eta), math.floor(cap))
                        S.farmPhase = ("stage %d too tanky (%ds to clear) - cashing out")
                            :format(stage, math.floor(eta))
                        return "tanky"
                    end
                end
            end

            if up > 0 then
                sawEnemy = true
                sawAny   = true
                emptySince = nil
                noteStageAlive(stage)
            else
                if loot > 0 then noteStageAlive(stage) end   -- a wave died here
                emptySince = (loot == 0) and (emptySince or os.clock()) or nil
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

            -- Dead time is the only free flush in the game.  A stage-11 wave drops
            -- 11 items into an 8-slot bag and the room then sits empty for ~30s
            -- while the respawn timer runs; the corridor re-walk costs ~20s of
            -- that.  So once the frontier room is genuinely quiet - no enemies, no
            -- loot left - and the bag could not take another wave anyway, bank it
            -- and hand back to the rotation.  Two guards matter: only in the
            -- frontier room (banking while walking the corridor churns the run for
            -- one item), and only when nearly full (a bag with room to spare is
            -- worth more than the flush, since the flush costs the whole walk).
            if S.autoSell and emptySince and os.clock() - emptySince > 3
               and stage == runStage()
               and limitBagUsed() >= math.max(2, tempCap() - 2)
               and os.clock() - lastCash > 5 then
                lastCash = os.clock()
                S.farmPhase = ("stage %d empty - banking %d item(s) now")
                    :format(stage, limitBagUsed())
                sellEverything()
                if limitBagUsed() <= 0 then
                    return S.farmClears > 0 and "cleared" or "flushed"
                end
            end

            local lootLeft = S.autoPickup and loot > 0 and not bagFull()
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
        local walkFails = 0           -- corridor stalls below the target
        while S.running and not Fluent.Unloaded do
            if not S.autoFarm then
                S.farmPhase = "off"
                discovered, target, best = false, 0, 0
                hardCap, failAt, wins = MAX_STAGE, {}, 0
                walkFails = 0
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
                walkFails = 0
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
                    -- This room is above our damage: the wave's health divided by
                    -- our measured dps needs longer than the ETA limit.  The
                    -- sequence the user asked for is stop -> collect -> sell ->
                    -- reloop, and it is also the right one: the loot already on
                    -- the floor is worth more than another minute of chipping at
                    -- a 442B health bar.  pickupPass takes the dearest drops
                    -- first, so a short sweep still banks the valuable half.
                    hardCap = math.max(first, target - 1)
                    wins = 0
                    local back = math.max(first, math.min(hardCap, best > 0 and best or hardCap))

                    S.farmPhase = ("stage %d too tanky - collecting the loot"):format(target)
                    local sweep = os.clock()
                    while S.autoPickup and os.clock() - sweep < 6 do
                        if bagFull() then break end
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
                    -- The bag filled and was banked, which ended the run.  Aim at
                    -- the ceiling again rather than at this room: a flush says
                    -- nothing about how hard the room was, and treating it as the
                    -- new home pinned a whole 300s test to stage 6 (a 10M wave,
                    -- ~600K/lap) when stage 11's 425B wave was clearing in 25s for
                    -- ~50M.  The ETA rule re-judges the top room in one tick, so
                    -- aiming high costs nothing when it is out of reach.
                    best = math.max(best, target)
                    target = last
                    S.farmPhase = ("sold mid-run - walking back to stage %d"):format(target)
                elseif how == "barren" and target < last then
                    target += 1                      -- no wave here, push on
                elseif how == "cleared" then
                    -- Straight back to the ceiling.  Climbing one room per lap was
                    -- how the ceiling used to be discovered, but the doors and the
                    -- ETA rule both answer that in a fraction of a second now, and
                    -- the corridor has to be walked through every room in between
                    -- either way - so a lap that stops at stage 7 just throws away
                    -- the four rooms above it.
                    target = last
                end
            else
                -- A door refuses for two completely different reasons and they
                -- must not be conflated.  If the run had already reached the room
                -- *below* the target, then the door in front of the target is the
                -- career gate and the ceiling really is one lower.  If the walk
                -- died further down the corridor - which is exactly what a flush
                -- taken mid-lap looks like, the town pull landing while we stand
                -- on door 1 - then nothing whatsoever has been learned about the
                -- top room, and lowering the ceiling for it threw stage 11 away:
                -- measured 11 -> 10 -> 9 over 60s while the run flag sat at 0 and
                -- stage 11 was still clearing a 425B wave in 25s.
                local reached = runStage()
                if reached >= target - 1 then
                    failAt[target] = (failAt[target] or 0) + 1
                    if failAt[target] >= 2 and target > first then
                        hardCap = math.max(first, target - 1)
                        S.note = ("farm: stage %d will not open, holding at %d")
                            :format(target, hardCap)
                    end
                    -- Do not fall back to wherever the run happens to be after
                    -- every hiccup.  A flush leaves run=0, and collapsing the
                    -- target onto it sent the rotation back to stage 1 to fight
                    -- rooms worth a thousandth of the top room's drops (measured:
                    -- 20s held in stage 2 for 495 HP of monsters, straight after
                    -- clearing 10).  Three failures in a row is not a hiccup
                    -- though, and farming the room the run did reach beats
                    -- retrying one climb forever.
                    if (failAt[target] or 0) >= 3 then
                        local dropped = target
                        target = math.clamp(math.max(reached, first), first, hardCap)
                        failAt[dropped] = 0
                        S.note = ("farm: could not walk to stage %d, farming %d for now")
                            :format(dropped, target)
                    else
                        target = math.clamp(math.max(target, best), first, hardCap)
                    end
                else
                    -- Corridor hiccup below the target: keep the ceiling, and every
                    -- third try reset the run properly so the next walk starts from
                    -- a town the server agrees we are in.
                    walkFails += 1
                    S.note = ("farm: the walk stalled at stage %d on the way to %d,"
                           .. " retrying (%d)"):format(reached, target, walkFails)
                    if walkFails % 3 == 0 then
                        S.farmPhase = "corridor walk stalled - resetting the run"
                        endRun()
                    end
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
        local row = Conf.weaponConf[id]
        hookPush((":crossed_swords: Bought **%s**")
            :format(en(row and row.ZhName, "wand " .. tostring(id))))
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
        local count, level, need, eligible = rebirthStatus()
        if not need then return false, "already max rebirth" end
        if not eligible then return false, "level below " .. need end
        if not allow(NetMsg.PLAYER_REBIRTH) then return false, "capped" end
        local ok, res = pcall(NetWork.InvokeServer, NetMsg.PLAYER_REBIRTH)
        if not ok then return false, tostring(res) end
        if res ~= true then return false, "server rejected" end
        S.rebirths += 1
        if S.hookRebirth then
            hookPush((":sparkles: **Rebirth %d** at level %d  (%d this session)")
                :format(count + 1, level, S.rebirths))
        end
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
    -- 16b. OneClick  (the whole economy loop behind one switch)
    ------------------------------------------------------------------
    -- The loop the game actually rewards is: walk the corridor up to the best
    -- room we can clear -> kill -> take the dearest drops -> flush (which ends
    -- the run) -> sell -> walk it again, with training taps riding along the
    -- whole time because they cost nothing but request budget and gain is
    -- server-side.  None of those pieces is useful alone, and every one of them
    -- was a separate switch on a separate tab.  So this drives them together and
    -- keeps re-asserting: the sub-toggles can be flipped while it runs, and
    -- nothing can drift off because some other worker turned it off.
    local function oneClickApply()
        local on = S.oneClick
        S.autoFarm    = on and S.ocFarm
        S.autoPickup  = on and S.ocCollect
        S.autoSell    = on and S.ocSell
        S.autoTrain   = on and S.ocTrain
        S.autoBuyWand = on and S.ocWand
        S.autoRebirth = on and S.ocRebirth
        if on then
            -- The farm drives its own attacks, but hover is what keeps the melee
            -- waves off us (measured minHP 100 across full runs), and the flush
            -- is the only way loot picked up inside a stage ever becomes gold.
            S.hover     = true
            S.sellFlush = true
        end
    end


    ------------------------------------------------------------------
    -- 17. Window
    ------------------------------------------------------------------
    local Window = Fluent:CreateWindow({
        Title       = "Magic Loot",
        SubTitle    = "Fluent hub v4",
        TabWidth    = 140,
        Size        = UDim2.fromOffset(600, 520),
        Acrylic     = false,
        Theme       = "Dark",
        MinimizeKey = Enum.KeyCode.LeftControl,
    })

    local Tabs = {
        OneClick = Window:AddTab({ Title = "OneClick", Icon = "zap" }),
        Combat   = Window:AddTab({ Title = "Combat",   Icon = "crosshair" }),
        Farm     = Window:AddTab({ Title = "Farm",     Icon = "swords" }),
        Bag      = Window:AddTab({ Title = "Bag",      Icon = "package" }),
        Train    = Window:AddTab({ Title = "Train",    Icon = "dumbbell" }),
        Shop     = Window:AddTab({ Title = "Shop",     Icon = "shopping-cart" }),
        Webhook  = Window:AddTab({ Title = "Webhook",  Icon = "bell" }),
        Stats    = Window:AddTab({ Title = "Stats",    Icon = "bar-chart-2" }),
        Misc     = Window:AddTab({ Title = "Misc",     Icon = "wrench" }),
        Settings = Window:AddTab({ Title = "Settings", Icon = "settings" }),
    }

    ------------------------------------------------------------------
    -- 17b. OneClick tab
    ------------------------------------------------------------------
    local oneSec  = Tabs.OneClick:AddSection("OneClick")
    local oneInfo = oneSec:AddParagraph({ Title = "Status", Content = "off" })

    oneSec:AddToggle("OneClick", {
        Title   = "OneClick",
        Default = false,
    }):OnChanged(function(v) S.oneClick = v end)

    local incSec = Tabs.OneClick:AddSection("Include")

    for _, item in ipairs({
        { "OcFarm",    "Auto farm",     "ocFarm" },
        { "OcCollect", "Auto collect",  "ocCollect" },
        { "OcSell",    "Auto sell",     "ocSell" },
        { "OcTrain",   "Auto train",    "ocTrain" },
        { "OcWand",    "Auto buy wand", "ocWand" },
        { "OcRebirth", "Auto rebirth",  "ocRebirth" },
    }) do
        local key = item[3]
        incSec:AddToggle(item[1], { Title = item[2], Default = true })
            :OnChanged(function(v) S[key] = v end)
    end


    ------------------------------------------------------------------
    -- 18. Combat tab
    ------------------------------------------------------------------
    local auraSec  = Tabs.Combat:AddSection("Kill aura")
    local auraInfo = auraSec:AddParagraph({ Title = "Live", Content = "reading..." })

    auraSec:AddToggle("KillAura", {
        Title   = "Kill aura",
        Default = false,
    }):OnChanged(function(v) S.killAura = v end)

    auraSec:AddToggle("SnapToTarget", {
        Title   = "Snap to target",
        Default = true,
    }):OnChanged(function(v) S.snapToTarget = v end)

    auraSec:AddToggle("Hover", {
        Title   = "Hover above the enemies",
        Default = true,
    }):OnChanged(function(v) S.hover = v end)

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
    local farmSec  = Tabs.Farm:AddSection("Career farm")
    local farmInfo = farmSec:AddParagraph({ Title = "Status", Content = "idle" })

    farmSec:AddToggle("AutoFarm", {
        Title   = "Auto farm",
        Default = false,
    }):OnChanged(function(v) S.autoFarm = v end)

    local rebirthSec  = Tabs.Farm:AddSection("Rebirth")
    local rebirthInfo = rebirthSec:AddParagraph({ Title = "Rebirth", Content = "reading..." })

    rebirthSec:AddToggle("AutoRebirth", {
        Title   = "Auto rebirth",
        Default = false,
    }):OnChanged(function(v) S.autoRebirth = v end)

    ------------------------------------------------------------------
    -- 20. Bag tab  (pickup + selling)
    ------------------------------------------------------------------
    local dropSec = Tabs.Bag:AddSection("Pickup")

    dropSec:AddToggle("AutoPickup", {
        Title   = "Auto collect (dearest drop first)",
        Default = false,
    }):OnChanged(function(v) S.autoPickup = v end)

    local sellSec  = Tabs.Bag:AddSection("Selling")
    local sellInfo = sellSec:AddParagraph({ Title = "Bag", Content = "reading..." })

    sellSec:AddToggle("AutoSell", {
        Title   = "Auto sell materials",
        Default = false,
    }):OnChanged(function(v) S.autoSell = v end)

    sellSec:AddToggle("SellFlush", {
        Title   = "Flush temp bag first",
        Default = true,
    }):OnChanged(function(v) S.sellFlush = v end)

    sellSec:AddToggle("KeepAlchemy", {
        Title   = "Keep alchemy materials",
        Default = true,
    }):OnChanged(function(v) S.keepAlchemy = v end)

    sellSec:AddButton({ Title = "Sell now", Callback = function() S.sellNow = true end })
    sellSec:AddButton({ Title = "Flush temp bag now", Callback = function() S.flushNow = true end })

    ------------------------------------------------------------------
    -- 21. Train tab
    ------------------------------------------------------------------
    local trainSec  = Tabs.Train:AddSection("Training")
    local trainInfo = trainSec:AddParagraph({ Title = "Live", Content = "reading..." })

    trainSec:AddToggle("AutoTrain", {
        Title   = "Auto train",
        Default = false,
    }):OnChanged(function(v) S.autoTrain = v end)

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
        Title   = "Wand",
        Values  = wandNames,
        Multi   = false,
        Default = 1,
    }):OnChanged(function(v) S.wandChoice = v end)

    wandSec:AddToggle("AutoBuyWand", {
        Title   = "Auto buy when affordable",
        Default = false,
    }):OnChanged(function(v) S.autoBuyWand = v end)

    wandSec:AddToggle("EquipAfterBuy", {
        Title   = "Equip after buying",
        Default = true,
    }):OnChanged(function(v) S.equipAfterBuy = v end)

    ------------------------------------------------------------------
    -- 22b. Webhook tab
    ------------------------------------------------------------------
    local hookSec  = Tabs.Webhook:AddSection("Discord webhook")
    local hookInfo = hookSec:AddParagraph({ Title = "Status", Content = "no URL set" })

    -- The one text field left in the hub: it cannot be a toggle, and it is the
    -- user's own endpoint.  Nothing is sent anywhere until it is filled in.
    hookSec:AddInput("HookUrl", {
        Title       = "Webhook URL",
        Default     = "",
        Placeholder = "https://discord.com/api/webhooks/...",
        Numeric     = false,
        Finished    = true,
        Callback    = function(v) S.hookUrl = tostring(v or ""):gsub("%s+", "") end,
    })

    local rarityValues = {}
    for i = 1, #RARITY do
        rarityValues[i] = ("%d - %s and above"):format(i, RARITY[i])
    end

    hookSec:AddDropdown("HookRarity", {
        Title   = "Notify from rarity",
        Values  = rarityValues,
        Multi   = false,
        Default = 6,
    }):OnChanged(function(v)
        S.hookRarity = tonumber(tostring(v):match("^(%d+)")) or 6
    end)

    hookSec:AddToggle("HookItems",   { Title = "Notify on item",    Default = true })
        :OnChanged(function(v) S.hookItems = v end)
    hookSec:AddToggle("HookRebirth", { Title = "Notify on rebirth", Default = true })
        :OnChanged(function(v) S.hookRebirth = v end)
    hookSec:AddToggle("HookSales",   { Title = "Notify on sale",    Default = true })
        :OnChanged(function(v) S.hookSales = v end)

    hookSec:AddButton({ Title = "Send test message", Callback = function() S.hookTest = true end })

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
        Title   = "Improve performance",
        Default = false,
    }):OnChanged(function(v) S.perfWanted = v end)

    perfSec:AddButton({
        Title    = "Clear debris & temp folders",
        Callback = function()
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

    local infoSec    = Tabs.Misc:AddSection("Server")
    local serverInfo = infoSec:AddParagraph({ Title = "Info", Content = "reading..." })

    infoSec:AddButton({
        Title    = "Unload hub",
        Callback = function()
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
        wallet[#wallet + 1] = ("Temp bag pending: %d / %d")
            :format(limitBagUsed(), tempCap())
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
            ("Measured damage: %s/s   walk away over %ds"):format(
                short(math.max(S.dps, attr(1) * 2)), math.floor(num(S.etaLimit, 35))),
            ("DungeonAggroStage %d   InDungeonChallenge %d   SafeArea %d"):format(
                flag("DungeonAggroStage"), flag("InDungeonChallenge"), flag("InStageSafeArea")),
            ("HP %d%%   CareerMaxStage %d"):format(
                math.floor(hpFrac() * 100), flag("CareerMaxStage")),
        }, "\n"))

        sellInfo:SetDesc(table.concat({
            ("Pending in temp bag: %d / %d"):format(limitBagUsed(), tempCap()),
            ("Learned cap: %s"):format(capFull > 0
                and ("%d (server refused past it)"):format(capFull)
                or ("%d (still growing)"):format(math.max(tempHint(), capKnown))),
            ("Sold this session: %s"):format(comma(S.sold)),
            ("Flushes: %d"):format(S.flushes),
        }, "\n"))

        local ocOn = {}
        for _, p in ipairs({
            { "farm", S.ocFarm }, { "collect", S.ocCollect }, { "sell", S.ocSell },
            { "train", S.ocTrain }, { "wand", S.ocWand }, { "rebirth", S.ocRebirth },
        }) do
            if p[2] then ocOn[#ocOn + 1] = p[1] end
        end
        oneInfo:SetDesc(table.concat({
            ("OneClick: %s"):format(S.oneClick and "RUNNING" or "off"),
            ("Doing: %s"):format(#ocOn > 0 and table.concat(ocOn, ", ") or "nothing selected"),
            ("Now: %s"):format(S.oneClick and S.farmPhase or "-"),
            ("Gold: %s   sold %s   rebirths %d"):format(
                short(bag(1)), comma(S.sold), S.rebirths),
        }, "\n"))

        hookInfo:SetDesc(table.concat({
            ("URL: %s"):format(S.hookUrl ~= "" and "set" or "not set - nothing is sent"),
            ("Lines sent: %d   queued: %d"):format(S.hookSent, #hookQueue),
            ("Last error: %s"):format(S.hookFail ~= "" and S.hookFail or "none"),
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
            ("Hub: v4"),
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

    -- Every rate is a constant now, but the helper stays: it re-reads S so a
    -- config load or an API poke takes effect on the next iteration.
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

    -- OneClick owns the feature switches while it is on, so ticking a sub-toggle
    -- takes effect inside half a second.  It keeps applying for one tick after
    -- being switched off - that is what turns everything back off - and then
    -- stands aside so the individual tabs work on their own again.
    local ocWas = false
    every(0.4, function()
        if S.oneClick or ocWas then oneClickApply() end
        ocWas = S.oneClick
    end)

    -- Webhook: one POST every 3s at most, batched, so a wave of 11 drops is one
    -- message instead of eleven.  Runs on its own thread; a hung request cannot
    -- stall the farm.
    every(1.0, function()
        if S.hookTest then
            S.hookTest = false
            if S.hookUrl == "" then
                S.hookFail = "no URL set"
            else
                local ok, why = httpPost(S.hookUrl, {
                    username = "Magic Loot Hub",
                    content  = (":white_check_mark: Magic Loot hub v4 connected."
                        .. "\nLevel %d, %s gold, notifying from %s upward.")
                        :format(bag(4), comma(bag(1)),
                                rarityName(math.floor(num(S.hookRarity, 6)))),
                })
                S.hookFail = ok and "" or why
                Fluent:Notify({
                    Title    = "Webhook",
                    Content  = ok and "Test message sent." or ("Failed: " .. tostring(why)),
                    Duration = 5,
                })
            end
        end
        hookFlush()
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
        Title    = "Magic Loot hub v4",
        Content  = "Flip OneClick and leave it. Left Ctrl minimises.",
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
        OpenRunTo = openRunTo, ReturnToLobby = returnToLobby, DoorStand = doorStand,
        Teleport = teleport, HoverStop = hoverStop, Flag = flag, LobbyStand = lobbyStand,
        ClearFrontier = clearFrontier,
        -- bag
        PickupPass = pickupPass, SellableRows = sellableRows, Sell = sellEverything,
        FlushTempBag = flushTempBag, LimitBagUsed = limitBagUsed, TempCap = tempCap,
        TempHint = tempHint, BagFull = bagFull, SettleAfterTown = settleAfterTown,
        -- one click + webhook
        OneClickApply = oneClickApply, HookPush = hookPush, HookFlush = hookFlush,
        HttpPost = httpPost, RarityName = rarityName,
        -- misc
        TrainTick = trainTick, BuyWand = buyWand, EquipWand = equipWand, WandTick = wandTick,
        RebirthOnce = rebirthOnce, RebirthStatus = rebirthStatus,
        Performance = applyPerformance, Refresh = refresh,
    }

    function API:Unload()
        S.running = false
        S.oneClick = false
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
