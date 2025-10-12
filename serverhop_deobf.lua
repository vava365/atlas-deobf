-- Bee Swarm Simulator server hop (readable reimplementation)
-- Features:
-- - Enumerates public servers and teleports to the next one
-- - Between hops, detects Sprouts, Vicious Bee (with level/gifted checks), Windy Bee (with level checks), optional Fireflies
-- - Honors _G configuration flags described by the user
-- - Sends optional Discord webhook when a target is found
-- - Persists visited JobIds (to avoid re-joining) if isfile/readfile/writefile exist
--
-- Usage example (set your flags before loading):
-- _G.cannon = true
-- _G.walkspeed = 70
-- _G.movement = "Walk"
-- _G.tweenspeed = 6
-- _G.blacklistedfields = {"Mountain Top Field"}
-- _G.fireflies = false
-- _G.webhook = "https://discord.com/api/webhooks/..."
-- _G.vicious = true
-- _G.giftedonly = false
-- _G.viciousmin = 1
-- _G.viciousmax = 12
-- _G.sprouts = true
-- _G.rarity = { Basic = true, Rare = true, Moon = true, Gummy = true, ["Epic+"] = true }
-- _G.windy = false
-- _G.windymin = 1
-- _G.windymax = 25
-- loadstring(game:HttpGet("https://your/raw/serverhop_deobf.lua"))()

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local StarterGui = game:GetService("StarterGui")
local PathfindingService = game:GetService("PathfindingService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = game.PlaceId
local CURRENT_JOB_ID = game.JobId

-- Read _G configuration flags (with defaults)
local CFG = {
    cannon = (typeof(_G.cannon) == "boolean") and _G.cannon or false,
    walkspeed = tonumber(_G.walkspeed) or nil,
    movement = (typeof(_G.movement) == "string") and _G.movement or "Walk",
    tweenspeed = tonumber(_G.tweenspeed) or 6,
    blacklistedfields = (typeof(_G.blacklistedfields) == "table") and _G.blacklistedfields or {},
    fireflies = (typeof(_G.fireflies) == "boolean") and _G.fireflies or false,
    webhook = (typeof(_G.webhook) == "string") and _G.webhook or nil,
    notify = (typeof(_G.notify) == "boolean") and _G.notify or true,
    detecttimeout = tonumber(_G.detecttimeout) or 25,
    autovicious = (typeof(_G.autovicious) == "boolean") and _G.autovicious or false,
    autosprouts = (typeof(_G.autosprouts) == "boolean") and _G.autosprouts or false,
    collecttokens = true,
    tokenradius = tonumber(_G.tokenradius) or 75,
    vicioustime = tonumber(_G.vicioustime) or 180,
    sprouttime = tonumber(_G.sprouttime) or 120,

    vicious = (typeof(_G.vicious) == "boolean") and _G.vicious or false,
    giftedonly = (typeof(_G.giftedonly) == "boolean") and _G.giftedonly or false,
    viciousmin = tonumber(_G.viciousmin) or 1,
    viciousmax = tonumber(_G.viciousmax) or 20,

    sprouts = (typeof(_G.sprouts) == "boolean") and _G.sprouts or false,
    rarity = (typeof(_G.rarity) == "table") and _G.rarity or { Basic = true, Rare = true, Moon = true, Gummy = true, ["Epic+"] = true },

    windy = (typeof(_G.windy) == "boolean") and _G.windy or false,
    windymin = tonumber(_G.windymin) or 1,
    windymax = tonumber(_G.windymax) or 25,
    stopOnInput = (typeof(_G.stopOnInput) == "boolean") and _G.stopOnInput or true,
    -- movement tuning
    jumppower = tonumber(_G.jumppower) or nil,
    jumpheight = tonumber(_G.jumpheight) or nil,
    hipheight = tonumber(_G.hipheight) or nil,
    noclip = (typeof(_G.noclip) == "boolean") and _G.noclip or false,
    usepathfinding = (typeof(_G.usepathfinding) == "boolean") and _G.usepathfinding or true,
    agentRadius = tonumber(_G.agentRadius) or 4,
    agentHeight = tonumber(_G.agentHeight) or 6,
    dodgevicious = (typeof(_G.dodgevicious) == "boolean") and _G.dodgevicious or true,
    combatradius = tonumber(_G.combatradius) or 8,
}

-- Movement/dodge constants (not customizable)
local TWEEN_SPEED = 6
local COMBAT_RADIUS = 8
local DODGE_VICIOUS = true

-- Server hop behavior config
local HOP = {
    preferLeastPlayers = true, -- pick least-populated valid server if true, else first available
    maxHopAttempts = 50,       -- maximum number of servers to try
    perServerDetectTimeout = CFG.detecttimeout, -- seconds to wait in a server for targets to load
    retryTeleportDelay = 2,    -- seconds between teleport retries
    teleportConfirmTimeout = 8, -- seconds to wait for TeleportInitFailed before assuming success
    teleportCooldownBase = 15,  -- base cooldown after throttle/timeout
    teleportCooldownMax = 120,  -- max cooldown seconds
    -- Anti-stall settings
    maxNilPicks = 3,
    clearVisitedOnStall = true,
    forceRandomTeleportOnStall = true,
    maxVisited = 1500,
    persistenceFile = "serverhop_visited.json",
}

-- Detect request function from exploit environment
local function getRequester()
    if typeof(http_request) == "function" then
        return http_request
    end
    if typeof(syn) == "table" and typeof(syn.request) == "function" then
        return syn.request
    end
    if typeof(request) == "function" then
        return request
    end
    return nil
end

local requester = getRequester()

-- Teleport throttle/timeout handling
local teleportBlockedUntil = 0
local teleportFailCounter = 0

local function scheduleTeleportCooldown(reason)
    local now = tick()
    local prev = math.max(0, teleportBlockedUntil - now)
    local base = HOP.teleportCooldownBase or 15
    local maxc = HOP.teleportCooldownMax or 120
    local mult = 1
    local r = tostring(reason or ""):lower()
    if r:find("flood") or r:find("timeout") then mult = 2 end
    local nextDelay = math.min((prev > 0 and prev * 1.5 or base) * mult, maxc)
    teleportBlockedUntil = now + nextDelay
    teleportFailCounter = teleportFailCounter + 1
    warn(string.format("ServerHop: teleport cooldown %.0fs (%s)", nextDelay, tostring(reason)))
end

pcall(function()
    TeleportService.TeleportInitFailed:Connect(function(player, result)
        scheduleTeleportCooldown(result)
    end)
end)

-- File helpers (optional)
local function safeIsFile(path)
    local ok = pcall(function()
        return isfile and isfile(path)
    end)
    if ok and isfile then
        return isfile(path)
    end
    return false
end

local function safeReadFile(path)
    if safeIsFile(path) and readfile then
        local ok, data = pcall(readfile, path)
        if ok then return data end
    end
    return nil
end

local function safeWriteFile(path, data)
    if writefile then
        pcall(writefile, path, data)
    end
end

-- Load visited jobIds
local visited = {}
local persisted = safeReadFile(HOP.persistenceFile)
if persisted then
    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(persisted)
    end)
    if ok and typeof(decoded) == "table" then
        visited = decoded
    end
end

local function saveVisited()
    safeWriteFile(HOP.persistenceFile, HttpService:JSONEncode(visited))
end

local function countVisited()
    local n = 0
    for _ in pairs(visited) do n = n + 1 end
    return n
end

local function maybeTrimVisited()
    if countVisited() > (HOP.maxVisited or 1500) then
        visited = {}
        saveVisited()
    end
end

local function clearVisitedIfStalled(stallCount)
    if HOP.clearVisitedOnStall and stallCount >= (HOP.maxNilPicks or 3) then
        visited = {}
        saveVisited()
        return true
    end
    return false
end

-- Helpers
local function toSet(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

local blacklistSet = toSet(CFG.blacklistedfields)

local function inBlacklist(fieldName)
    if not fieldName then return false end
    return blacklistSet[fieldName] or false
end

local function toServerLinks(placeId, jobId)
    local pid = tonumber(placeId) or 0
    local jid = tostring(jobId)
    local http = string.format("https://www.roblox.com/games/start?placeId=%d&gameInstanceId=%s", pid, jid)
    local proto = string.format("roblox://placeId=%d&gameInstanceId=%s", pid, jid)
    return http, proto
end

-- Zones/fields lookup (best-effort)
local function getFlowerZones()
    local zones = {}
    local folder = Workspace:FindFirstChild("FlowerZones") or Workspace:FindFirstChild("Flower Zone") or Workspace:FindFirstChild("Zones")
    if folder and folder:IsA("Folder") then
        for _, inst in ipairs(folder:GetChildren()) do
            if inst:IsA("BasePart") or inst:IsA("Model") then
                table.insert(zones, inst)
            end
        end
    else
        -- Fallback: scan top-level for parts containing "Field" in the name
        for _, inst in ipairs(Workspace:GetChildren()) do
            if (inst:IsA("BasePart") or inst:IsA("Model")) and string.find(inst.Name, "Field") then
                table.insert(zones, inst)
            end
        end
    end
    return zones
end

local ZONES = getFlowerZones()

local function instancePosition(inst)
    local ok, cf = pcall(function()
        if inst.GetPivot then return inst:GetPivot() end
        if inst:IsA("Model") then return inst:GetModelCFrame() end
        if inst:IsA("BasePart") then return inst.CFrame end
    end)
    if ok and typeof(cf) == "CFrame" then
        return cf.Position
    end
    return nil
end

local function nearestFieldName(pos)
    if not pos then return nil end
    local bestName, bestDist = nil, math.huge
    for _, zone in ipairs(ZONES) do
        local zpos = instancePosition(zone)
        if zpos then
            local d = (zpos - pos).Magnitude
            if d < bestDist then
                bestDist, bestName = d, zone.Name
            end
        end
    end
    return bestName
end

-- Detection: Sprouts
local function mapSproutRarity(name)
    name = string.lower(name or "")
    if string.find(name, "gummy") then return "Gummy" end
    if string.find(name, "moon") then return "Moon" end
    if string.find(name, "rare") then return "Rare" end
    if string.find(name, "supreme") then return "Supreme" end
    if string.find(name, "legend") then return "Legendary" end
    if string.find(name, "epic") then return "Epic" end
    return "Basic"
end

-- Try to determine sprout rarity from GUI text inside the model, fallback to name
local function detectSproutRarity(model)
    if not model or not model.GetDescendants then
        return "Basic"
    end
    local best = mapSproutRarity(model.Name)
    -- Prefer explicit billboard text if present
    for _, d in ipairs(model:GetDescendants()) do
        local ok, text = pcall(function()
            if d:IsA("TextLabel") or d:IsA("TextButton") then return d.Text end
        end)
        if ok and typeof(text) == "string" then
            local t = string.lower(text)
            if string.find(t, "supreme") then return "Supreme" end
            if string.find(t, "legend") then return "Legendary" end
            if string.find(t, "epic") then return "Epic" end
            if string.find(t, "gummy") then return "Gummy" end
            if string.find(t, "moon") then return "Moon" end
            if string.find(t, "rare") then return "Rare" end
        end
    end
    return best
end

local function findSprouts()
    local folder = Workspace:FindFirstChild("Sprouts") or Workspace
    local results = {}
    local seen = {}
    for _, inst in ipairs(folder:GetDescendants()) do
        local nameLower = string.lower(inst.Name)
        if (inst:IsA("Model") or inst:IsA("BasePart")) and string.find(nameLower, "sprout") then
            local key = nil
            local okK, full = pcall(function() return inst:GetFullName() end)
            if okK and typeof(full) == "string" then key = full end
            if key and seen[key] then
                -- skip duplicates
            else
                if key then seen[key] = true end
                local pos = instancePosition(inst)
                local field = nearestFieldName(pos)
                local model = inst:IsA("Model") and inst or inst.Parent
                local rarity = detectSproutRarity(model or inst)
                local allow = CFG.rarity[rarity]
                if not allow and (rarity == "Epic" or rarity == "Legendary" or rarity == "Supreme") then
                    allow = CFG.rarity["Epic+"]
                end
                if allow and not inBlacklist(field) then
                    table.insert(results, { kind = "sprout", rarity = rarity, field = field, pos = pos })
                end
            end
        end
    end
    return results
end

-- Common: parse level from model (attributes/children/Billboard)
local function parseLevelFromModel(model)
    if not model or not model.IsA then return nil end
    -- Try Attribute
    local okA, lvl = pcall(function() return model:GetAttribute("Level") end)
    if okA and typeof(lvl) == "number" then return lvl end

    -- Try child IntValue named Level
    local iv = model:FindFirstChild("Level")
    if iv and iv:IsA("IntValue") then return iv.Value end

    -- Try billboard text
    for _, d in ipairs(model:GetDescendants()) do
        local ok, text = pcall(function()
            if d:IsA("TextLabel") or d:IsA("TextButton") then return d.Text end
        end)
        if ok and typeof(text) == "string" then
            local num = tonumber((text:match("%d+") or ""))
            if num then return num end
        end
    end

    return nil
end

-- Detection: Vicious Bee
local function findVicious()
    local results = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") then
            local name = string.lower(inst.Name)
            if string.find(name, "vicious") and string.find(name, "bee") then
                local gifted = string.find(name, "gifted") ~= nil
                if (not CFG.giftedonly) or gifted then
                    local lvl = parseLevelFromModel(inst) or 1
                    if lvl >= CFG.viciousmin and lvl <= CFG.viciousmax then
                        local pos = instancePosition(inst)
                        local field = nearestFieldName(pos)
                        if not inBlacklist(field) then
                            table.insert(results, { kind = "vicious", gifted = gifted, level = lvl, field = field, pos = pos })
                        end
                    end
                end
            end
        end
    end
    return results
end

-- Detection: Windy Bee
local function findWindy()
    local results = {}
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") then
            local name = string.lower(inst.Name)
            if string.find(name, "windy") and string.find(name, "bee") then
                local lvl = parseLevelFromModel(inst) or 1
                if lvl >= CFG.windymin and lvl <= CFG.windymax then
                    local pos = instancePosition(inst)
                    local field = nearestFieldName(pos)
                    if not inBlacklist(field) then
                        table.insert(results, { kind = "windy", level = lvl, field = field, pos = pos })
                    end
                end
            end
        end
    end
    return results
end

-- Detection: Fireflies (optional)
local function findFireflies()
    local results = {}
    if not CFG.fireflies then return results end
    local function add(inst)
        local pos = instancePosition(inst)
        local field = nearestFieldName(pos)
        if not inBlacklist(field) then
            table.insert(results, { kind = "fireflies", field = field, pos = pos })
        end
    end
    local folder = Workspace:FindFirstChild("Fireflies") or Workspace:FindFirstChild("Creatures") or Workspace
    for _, inst in ipairs(folder:GetDescendants()) do
        local name = string.lower(inst.Name)
        if inst:IsA("Model") and (string.find(name, "firefly") or string.find(name, "fireflies")) then
            add(inst)
        end
    end
    return results
end

-- Single pass: check server for any target based on CFG flags
local function detectTargets()
    local found = {}
    if CFG.sprouts then
        for _, s in ipairs(findSprouts()) do table.insert(found, s) end
    end
    if CFG.vicious then
        for _, v in ipairs(findVicious()) do table.insert(found, v) end
    end
    if CFG.windy then
        for _, w in ipairs(findWindy()) do table.insert(found, w) end
    end
    if CFG.fireflies then
        for _, f in ipairs(findFireflies()) do table.insert(found, f) end
    end
    return found
end

-- Webhook
local function sendWebhook(payload)
    if not CFG.webhook or not requester then return end
    local data = HttpService:JSONEncode(payload)
    requester({ Url = CFG.webhook, Method = "POST", Headers = { ["Content-Type"] = "application/json" }, Body = data })
end

-- Client notification helper
local function pushNotification(title, text, duration)
    if not CFG.notify then return end
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = duration or 15
        })
    end)
end

local function announceFound(result)
    local title
    if result.kind == "sprout" then
        title = string.format("Sprout: %s", result.rarity)
    elseif result.kind == "vicious" then
        title = string.format("Vicious Bee%s (Lv.%d)", result.gifted and " [Gifted]" or "", result.level or -1)
    elseif result.kind == "windy" then
        title = string.format("Windy Bee (Lv.%d)", result.level or -1)
    elseif result.kind == "fireflies" then
        title = "Fireflies"
    else
        title = "Target Found"
    end

    local httpLink, protoLink = toServerLinks(PLACE_ID, CURRENT_JOB_ID)
    pushNotification(title, string.format("Field: %s\nJobId: %s", tostring(result.field), tostring(CURRENT_JOB_ID)), 20)
    local embed = {
        username = "BSS ServerHop",
        embeds = {
            {
                title = title,
                url = httpLink,
                description = string.format("Field: %s\nJobId: %s\nJoin: [Click to Join](%s)\nAlt: %s", tostring(result.field), tostring(CURRENT_JOB_ID), httpLink, protoLink),
                color = 5793266,
                footer = { text = os.date("!%Y-%m-%d %H:%M:%SZ") .. " UTC" },
            },
        },
    }
    sendWebhook(embed)
end

-- Fetch public server pages from Roblox games API
local function fetchServers(placeId, cursor)
    local base = string.format("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100", placeId)
    local url = cursor and (base .. "&cursor=" .. HttpService:UrlEncode(cursor)) or base

    local body
    if requester then
        local res = requester({ Url = url, Method = "GET" })
        if res and (res.Body or res.body) then
            body = res.Body or res.body
        end
    end

    if not body then
        local ok, result = pcall(HttpService.GetAsync, HttpService, url)
        if ok then body = result end
    end

    if not body then return nil, "HTTP request failed" end

    local ok, decoded = pcall(function()
        return HttpService:JSONDecode(body)
    end)
    if not ok or typeof(decoded) ~= "table" then return nil, "Failed to decode JSON" end

    return decoded, nil
end

local function pickServer(placeId, avoid, preferLeast)
    local cursor = nil
    local best = nil
    while true do
        local data, err = fetchServers(placeId, cursor)
        if not data then warn("ServerHop: fetchServers failed:", err) return nil end
        if typeof(data.data) == "table" then
            for _, srv in ipairs(data.data) do
                local id = srv.id
                local playing = tonumber(srv.playing) or 0
                local maxPlayers = tonumber(srv.maxPlayers) or math.huge
                local notFull = playing < maxPlayers
                local notCurrent = id ~= CURRENT_JOB_ID
                local notVisited = not avoid[id]
                if id and notFull and notCurrent and notVisited then
                    if not preferLeast then
                        return srv
                    end
                    if not best or playing < (tonumber(best.playing) or math.huge) then
                        best = srv
                    end
                end
            end
        end
        if best then return best end
        cursor = data.nextPageCursor
        if not cursor then return nil end
    end
end

-- Character utils (optional movement tuning)
local function ensureCharacter()
    if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
        return LocalPlayer.Character
    end
    LocalPlayer.CharacterAdded:Wait()
    return LocalPlayer.Character
end

local settingsEnforcerConn

local function enforceHumanoid(hum)
    if not hum then return end
    pcall(function()
        if CFG.walkspeed then hum.WalkSpeed = CFG.walkspeed end
        if CFG.jumpheight then
            hum.UseJumpPower = false
            hum.JumpHeight = CFG.jumpheight
        elseif CFG.jumppower then
            hum.UseJumpPower = true
            hum.JumpPower = CFG.jumppower
        end
        if CFG.hipheight then hum.HipHeight = CFG.hipheight end
    end)
end

local function applyMovementSettings()
    local char = ensureCharacter()
    local hum = char:FindFirstChildOfClass("Humanoid")
    enforceHumanoid(hum)
    if settingsEnforcerConn then pcall(function() settingsEnforcerConn:Disconnect() end) end
    local last = 0
    settingsEnforcerConn = RunService.Heartbeat:Connect(function()
        local h = getHumanoid()
        if h and (tick() - last) > 0.75 then
            enforceHumanoid(h)
            last = tick()
        end
    end)
end

-- Movement and farming helpers
local function getHumanoid()
    local char = ensureCharacter()
    if not char then return nil end
    return char:FindFirstChildOfClass("Humanoid")
end

local function getHRP()
    local char = ensureCharacter()
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

-- Movement control (stop and cancel support)
local Movement = { cancel = false }
function stopMovement()
    Movement.cancel = true
end
_G.stopMovement = stopMovement
local function beginMovement()
    Movement.cancel = false
end

-- Optional: cancel movement when player presses movement keys
pcall(function()
    local UIS = game:GetService("UserInputService")
    UIS.InputBegan:Connect(function(input, gp)
        if not CFG.stopOnInput or gp then return end
        if input.UserInputType == Enum.UserInputType.Keyboard then
            local k = input.KeyCode
            if k == Enum.KeyCode.W or k == Enum.KeyCode.A or k == Enum.KeyCode.S or k == Enum.KeyCode.D or k == Enum.KeyCode.Space then
                stopMovement()
            end
        end
    end)
end)

local function setCharacterCollide(enabled)
    local char = LocalPlayer.Character
    if not char then return end
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            d.CanCollide = enabled
        end
    end
end

local function tweenToPosition(pos, studsPerSecond)
    local hrp = getHRP()
    if not hrp then return false end
    pcall(function() if hrp.Anchored then hrp.Anchored = false end end)
    -- Slightly faster than configured speed for responsiveness
    local sps = 6
    local dist = (hrp.Position - pos).Magnitude
    local dur = math.clamp(dist / math.max(1, sps), 0.05, 8)
    -- Force noclip during tween to avoid getting stuck
    setCharacterCollide(false)
    local tw = TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), { CFrame = CFrame.new(pos) })
    local done = false
    local conn
    conn = tw.Completed:Connect(function()
        done = true
    end)
    tw:Play()
    local t0 = tick()
    while not done and (tick() - t0) < (dur + 1) do
        if Movement.cancel then
            pcall(function() tw:Cancel() end)
            break
        end
        task.wait(0.03)
    end
    if conn then conn:Disconnect() end
    -- restore collisions
    setCharacterCollide(true)
    local hrp2 = getHRP()
    return (not Movement.cancel) and hrp2 and ((hrp2.Position - pos).Magnitude < 5)
end

local function moveByPath(pos, timeout)
    local hum = getHumanoid()
    local hrp = getHRP()
    if not hum or not hrp or not pos then return false end
    local params = {
        AgentRadius = CFG.agentRadius or 4,
        AgentHeight = CFG.agentHeight or 6,
        AgentCanJump = true,
    }
    local path = PathfindingService:CreatePath(params)
    local ok = pcall(function() path:ComputeAsync(hrp.Position, pos) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        return false
    end
    local waypoints = path:GetWaypoints()
    local t0 = tick()
    for i, wp in ipairs(waypoints) do
        if Movement.cancel then return false end
        if wp.Action == Enum.PathWaypointAction.Jump then hum.Jump = true end
        hum:MoveTo(wp.Position)
        local reached = false
        local conn = hum.MoveToFinished:Connect(function(r) reached = r end)
        local st = tick()
        while (tick() - st) < 3 do
            if Movement.cancel then break end
            if (hrp.Position - wp.Position).Magnitude < 3 then reached = true break end
            task.wait(0.05)
        end
        if conn then conn:Disconnect() end
        if not reached and Movement.cancel then return false end
        if timeout and (tick() - t0) > timeout then break end
    end
    return (hrp.Position - pos).Magnitude < 6
end

local function moveToPosition(pos, timeout)
    local hum = getHumanoid()
    local hrp = getHRP()
    if not hum or not hrp or not pos then return false end
    beginMovement()
    setCharacterCollide(false)

    -- Prefer pathfinding to avoid obstacles
    if CFG.usepathfinding then
        local ok = moveByPath(pos, timeout or 8)
        if ok or Movement.cancel then
            setCharacterCollide(true)
            return ok
        end
    end

    -- Fallback simple MoveTo
    local reached = false
    pcall(function()
        if hrp.Anchored then hrp.Anchored = false end
        hum:MoveTo(pos)
    end)
    local conn
    conn = hum.MoveToFinished:Connect(function(r)
        reached = r
    end)
    local t0 = tick()
    local maxT = timeout or 6
    while (tick() - t0) < maxT and not reached do
        if Movement.cancel then break end
        if (hrp.Position - pos).Magnitude < 3 then
            reached = true
            break
        end
        task.wait(0.1)
    end
    if conn then conn:Disconnect() end
    if Movement.cancel then if CFG.noclip then setCharacterCollide(true) end return false end
    if not reached then
        -- Fallback: tween near the destination to avoid stalls (instead of teleport)
        local okTw = tweenToPosition(pos + Vector3.new(0, 3, 0), TWEEN_SPEED)
        setCharacterCollide(true)
        return okTw
    end
    setCharacterCollide(true)
    return true
end

local function findNearestToken(center, radius)
    local folder = Workspace:FindFirstChild("Tokens") or Workspace
    local nearest, bestDist
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("BasePart") and string.lower(inst.Name) == "token" then
            local pos = inst.Position
            local d = (pos - center).Magnitude
            if d <= (radius or 75) then
                if not nearest or d < bestDist then
                    nearest, bestDist = inst, d
                end
            end
        end
    end
    return nearest
end

local function countTokensInRadius(center, radius)
    local folder = Workspace:FindFirstChild("Tokens") or Workspace
    local count = 0
    if not center then return 0 end
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("BasePart") and string.lower(inst.Name) == "token" then
            local d = (inst.Position - center).Magnitude
            if d <= (radius or 75) then
                count = count + 1
            end
        end
    end
    return count
end

local function collectTokens(duration, aroundPos, radius)
    local hrp = getHRP()
    local tEnd = tick() + (duration or 10)
    while tick() < tEnd do
        if Movement.cancel then break end
        local origin = (aroundPos or (hrp and hrp.Position))
        if not origin then break end
        local tok = findNearestToken(origin, radius or CFG.tokenradius)
        if tok and tok:IsA("BasePart") then
            if not moveToPosition(tok.Position, 4) and Movement.cancel then break end
        else
            task.wait(0.25)
        end
    end
end

local function modelHasUnanchoredPart(model)
    local ok, res = pcall(function()
        for _, d in ipairs(model:GetDescendants()) do
            if d:IsA("BasePart") and d.Anchored == false then
                return true
            end
        end
        return false
    end)
    return ok and res or false
end

local function getModelRootPosition(model)
    local pos
    local ok = pcall(function()
        if model.PrimaryPart then pos = model.PrimaryPart.Position end
    end)
    if pos then return pos end
    local hrp = model:FindFirstChild("HumanoidRootPart")
    if hrp and hrp:IsA("BasePart") then return hrp.Position end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then return d.Position end
    end
    return nil
end

local function isActiveVicious(model)
    if not model or not model.IsA or not model:IsA("Model") then return false end
    local n = string.lower(model.Name)
    if not (n:find("vicious") and n:find("bee")) then return false end
    -- Heuristics: active mob has unanchored parts or a humanoid root
    if model:FindFirstChild("Humanoid") or model:FindFirstChild("HumanoidRootPart") then return true end
    if modelHasUnanchoredPart(model) then return true end
    return false
end

local function locateViciousNear(pos)
    local nearestActive, bestA = nil, math.huge
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") and isActiveVicious(inst) then
            local ip = getModelRootPosition(inst) or instancePosition(inst)
            if ip then
                local d = (ip - pos).Magnitude
                if d < bestA then
                    nearestActive, bestA = inst, d
                end
            end
        end
    end
    return nearestActive
end

local function findNearestHazard(center, radius)
    local nearest, best
    local r = radius or 25
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") then
            local n = string.lower(inst.Name)
            if n:find("stinger") or n:find("spike") or n:find("thorn") then
                local d = (inst.Position - center).Magnitude
                if d <= r and (not best or d < best) then
                    nearest, best = inst, d
                end
            end
        end
    end
    return nearest
end

local function findThreatNear(center, radius)
    local r = radius or 12
    local names = {"stinger", "spike", "thorn", "triangle", "shock", "shockwave"}
    local nearest, best
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("BasePart") then
            local n = string.lower(inst.Name)
            for _, k in ipairs(names) do
                if n:find(k) then
                    local d = (inst.Position - center).Magnitude
                    if d <= r and (not best or d < best) then
                        nearest, best = inst, d
                    end
                    break
                end
            end
        end
    end
    return nearest
end

local function engageVicious(result)
    local startPos = result.pos or (getHRP() and getHRP().Position) or Vector3.new()
    local target = locateViciousNear(startPos)
    local tEnd = tick() + (CFG.vicioustime or 180)
    local orbitAngle = 0
    while tick() < tEnd do
        if Movement.cancel then break end
        if not target or not target.Parent then break end
        if not isActiveVicious(target) then break end
        local bpos = getModelRootPosition(target) or instancePosition(target)
        if not bpos then break end

        local hrp = getHRP()
        if not hrp then break end
        local me = hrp.Position
        local dir = (me - bpos)
        local dist = math.max(1, dir.Magnitude)
        local desired = COMBAT_RADIUS

        -- Dodge hazards if close
        if DODGE_VICIOUS then
            local threat = findThreatNear(me, 12)
            if threat then
                local away = (me - threat.Position)
                local step = away.Magnitude > 0 and away.Unit * 12 or Vector3.new(6, 0, 0)
                local evadePos = me + step
                moveToPosition(evadePos, 0.8)
            end
        end

        -- Maintain an orbit around the bee to reduce hits
        orbitAngle = (orbitAngle + 0.35) % (math.pi * 2)
        local flatDir = Vector3.new(dir.X, 0, dir.Z)
        local baseDir = flatDir.Magnitude > 0 and flatDir.Unit or Vector3.new(1, 0, 0)
        local ox = math.cos(orbitAngle)
        local oz = math.sin(orbitAngle)
        local orbitDir = (Vector3.new(baseDir.X, 0, baseDir.Z) * ox + Vector3.new(-baseDir.Z, 0, baseDir.X) * oz).Unit
        local targetPos
        if dist > desired + 2 then
            targetPos = bpos + orbitDir * desired
        elseif dist < desired - 2 then
            targetPos = bpos + orbitDir * desired
        else
            targetPos = bpos + orbitDir * desired
        end
        moveToPosition(targetPos, 1.1)

        collectTokens(1.2, bpos, math.min(50, CFG.tokenradius or 75))
        -- Reacquire in case the model reference changes, and avoid static map objects
        target = locateViciousNear(bpos)
    end
    collectTokens(6, (getHRP() and getHRP().Position) or startPos, CFG.tokenradius)
end

local function farmSprout(result)
    local targetPos = result.pos
    if targetPos then
        moveToPosition(targetPos, 8)
    end
    local duration = CFG.sprouttime or 120
    local tEnd = tick() + duration
    local emptyStreak = 0
    while tick() < tEnd do
        if Movement.cancel then break end
        local center = targetPos or (getHRP() and getHRP().Position) or Vector3.new()
        local count = countTokensInRadius(center, CFG.tokenradius)
        if count == 0 then
            emptyStreak = emptyStreak + 1
        else
            emptyStreak = 0
        end
        collectTokens(2, center, CFG.tokenradius)
        if emptyStreak >= 8 then -- ~a few cycles with no tokens nearby
            break
        end
        task.wait(0.2)
    end
end

-- Hive claiming and field navigation
local function tryFirePrompt(prompt)
    local ok = pcall(function()
        if typeof(fireproximityprompt) == "function" then
            fireproximityprompt(prompt, 1)
        end
    end)
    if not ok then
        pcall(function()
            if typeof(fireproximityprompt) == "function" then
                fireproximityprompt(prompt)
            end
        end)
    end
end

local function tryClickDetector(cd)
    pcall(function()
        if typeof(fireclickdetector) == "function" then
            fireclickdetector(cd)
        end
    end)
end

-- Identify and move to the player's hive slot
local function isHiveOwnedByLocal(model)
    if not model or not model.IsA then return false end
    -- Attribute based
    local okA, ownerAttr = pcall(function() return model:GetAttribute("Owner") end)
    if okA and ownerAttr ~= nil then
        if ownerAttr == LocalPlayer or ownerAttr == LocalPlayer.Name or ownerAttr == LocalPlayer.DisplayName or ownerAttr == LocalPlayer.UserId then
            return true
        end
    end
    -- Child Value objects
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("ObjectValue") and string.lower(d.Name):find("owner") then
            if d.Value == LocalPlayer then return true end
        elseif d:IsA("StringValue") and string.lower(d.Name):find("owner") then
            if d.Value == LocalPlayer.Name or d.Value == LocalPlayer.DisplayName then return true end
        elseif d:IsA("IntValue") and string.lower(d.Name):find("owner") then
            if tonumber(d.Value) == LocalPlayer.UserId then return true end
        elseif d:IsA("TextLabel") or d:IsA("TextButton") then
            local txt = string.lower(d.Text or "")
            if txt:find(string.lower(LocalPlayer.DisplayName)) or txt:find(string.lower(LocalPlayer.Name)) then
                return true
            end
        end
    end
    return false
end

local function modelPlatformPosition(model)
    if not model or not model.IsA then return nil end
    local pp = nil
    local ok = pcall(function() pp = model.PrimaryPart end)
    if ok and pp and pp:IsA("BasePart") then return pp.Position end
    -- Prefer parts named platform/pad
    local best
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("BasePart") then
            local n = string.lower(c.Name)
            if n:find("platform") or n:find("pad") or n:find("hive") then
                best = best or c
            end
        end
    end
    if best then return best.Position end
    -- Fallback to any BasePart
    for _, c in ipairs(model:GetDescendants()) do
        if c:IsA("BasePart") then return c.Position end
    end
    return nil
end

local function findMyHiveSlotPos()
    local bestModel, bestDist, bestPos
    local hrp = getHRP()
    local origin = hrp and hrp.Position or Vector3.new()
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") then
            local n = string.lower(inst.Name)
            if n:find("hive") or n:find("honeycomb") then
                if isHiveOwnedByLocal(inst) then
                    local pos = modelPlatformPosition(inst)
                    if pos then
                        local d = (pos - origin).Magnitude
                        if not bestDist or d < bestDist then
                            bestModel, bestDist, bestPos = inst, d, pos
                        end
                    end
                end
            end
        end
    end
    return bestPos, bestModel
end

local function goToMyHiveSlot(timeout)
    local deadline = tick() + (timeout or 8)
    while tick() < deadline do
        if Movement.cancel then return false end
        local pos = findMyHiveSlotPos()
        if pos then
            if moveToPosition(pos, 10) then
                return true
            end
        end
        task.wait(0.5)
    end
    return false
end

local function findNearestClaimInteract()
    local hrp = getHRP()
    local origin = hrp and hrp.Position or Vector3.new()
    local best, bestDist, bestPart
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local text = string.lower((d.ObjectText or "") .. " " .. (d.ActionText or "") .. " " .. d.Name)
            if (text:find("claim") and text:find("hive")) and d.Enabled ~= false then
                local part = d.Parent
                if part and part:IsA("BasePart") then
                    local pos = part.Position
                    local dist = (pos - origin).Magnitude
                    if not best or dist < bestDist then
                        best, bestDist, bestPart = d, dist, part
                    end
                end
            end
        elseif d:IsA("ClickDetector") then
            local name = string.lower(d.Parent and d.Parent.Name or d.Name)
            if name:find("hive") or name:find("claim") then
                local part = d.Parent
                if part and part:IsA("BasePart") then
                    local pos = part.Position
                    local dist = (pos - origin).Magnitude
                    if not best or dist < bestDist then
                        best, bestDist, bestPart = d, dist, part
                    end
                end
            end
        end
    end
    return best, bestPart
end

local function listClaimInteracts()
    local hrp = getHRP()
    local origin = hrp and hrp.Position or Vector3.new()
    local items = {}
    for _, d in ipairs(Workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") then
            local text = string.lower((d.ObjectText or "") .. " " .. (d.ActionText or "") .. " " .. d.Name)
            if (text:find("claim") and text:find("hive")) and d.Enabled ~= false then
                local part = d.Parent
                if part and part:IsA("BasePart") then
                    local pos = part.Position
                    local dist = (pos - origin).Magnitude
                    table.insert(items, { interact = d, part = part, dist = dist })
                end
            end
        elseif d:IsA("ClickDetector") then
            local name = string.lower(d.Parent and d.Parent.Name or d.Name)
            if name:find("hive") or name:find("claim") then
                local part = d.Parent
                if part and part:IsA("BasePart") then
                    local pos = part.Position
                    local dist = (pos - origin).Magnitude
                    table.insert(items, { interact = d, part = part, dist = dist })
                end
            end
        end
    end
    table.sort(items, function(a,b) return a.dist < b.dist end)
    return items
end

local function claimHive(timeout)
    -- If already have a hive, just go to it
    if goToMyHiveSlot(2) then return true end
    local deadline = tick() + (timeout or 15)

    local function attemptClaim(interact, part)
        if not interact or not part then return false end
        -- Ensure close proximity
        moveToPosition(part.Position + Vector3.new(0, 0, 0), 6)
        -- Micro-reposition to trigger prompt if needed
        local offsets = {
            Vector3.new(2, 0, 0), Vector3.new(-2, 0, 0), Vector3.new(0, 0, 2), Vector3.new(0, 0, -2),
            Vector3.new(1.5, 0, 1.5), Vector3.new(-1.5, 0, -1.5)
        }
        for i = 1, 5 do
            if Movement.cancel then return false end
            if interact:IsA("ProximityPrompt") then
                tryFirePrompt(interact)
            elseif interact:IsA("ClickDetector") then
                tryClickDetector(interact)
            end
            task.wait(0.35)
            if goToMyHiveSlot(1) then return true end
            if offsets[i] then
                moveToPosition(part.Position + offsets[i], 2)
            end
        end
        -- Final short wait then re-check
        task.wait(0.5)
        return goToMyHiveSlot(2)
    end

    while tick() < deadline do
        if Movement.cancel then return false end
        -- If hive got assigned mid-loop
        if goToMyHiveSlot(1) then return true end
        local items = listClaimInteracts()
        if #items > 0 then
            for _, it in ipairs(items) do
                if Movement.cancel then return false end
                if attemptClaim(it.interact, it.part) then
                    return true
                end
            end
        else
            -- No prompt found; try to approach nearest hive platform and re-scan
            local nearestPlatform, nearestDist
            for _, inst in ipairs(Workspace:GetDescendants()) do
                if inst:IsA("Model") then
                    local n = string.lower(inst.Name)
                    if n:find("hive") or n:find("honeycomb") then
                        local p = modelPlatformPosition(inst)
                        if p then
                            local d = (p - (getHRP() and getHRP().Position or p)).Magnitude
                            if not nearestDist or d < nearestDist then
                                nearestPlatform, nearestDist = p, d
                            end
                        end
                    end
                end
            end
            if nearestPlatform then
                moveToPosition(nearestPlatform, 8)
                task.wait(0.5)
            end
        end
        task.wait(0.4)
    end
    return false
end

local function findZoneByName(name)
    if not name then return nil end
    for _, z in ipairs(ZONES) do
        if z.Name == name then return z end
    end
    return nil
end

local function goToField(result)
    local targetPos = result and result.pos or nil
    local zone = result and result.field and findZoneByName(result.field) or nil
    local zonePos = zone and instancePosition(zone) or nil
    local dest = zonePos or targetPos
    if dest then
        moveToPosition(dest, 12)
    end
end

-- Main hop logic
local function waitForTargets()
    -- Wait some time for assets to spawn, periodically scanning
    local deadline = tick() + HOP.perServerDetectTimeout
    while tick() < deadline do
        local found = detectTargets()
        if #found > 0 then
            -- Autopilot flow: first claim hive, then announce and proceed
            pcall(function()
                local f = found[1]
                claimHive(15)
                announceFound(f)
                goToField(f)
                if f.kind == "vicious" then
                    engageVicious(f)
                elseif f.kind == "sprout" then
                    farmSprout(f)
                end
            end)
            return true, found
        end
        task.wait(1)
    end
    return false, nil
end

local function hop(placeId)
    applyMovementSettings()
    local stallCount = 0
    local preferLeast = HOP.preferLeastPlayers

    for attempt = 1, HOP.maxHopAttempts do
        -- Scan this server for targets first
        local ok, res = pcall(waitForTargets)
        if ok and res then
            warn("ServerHop: target handled, hopping to next server.")
        end

        -- Otherwise, hop to next server
        local srv = pickServer(placeId, visited, preferLeast)
        if not srv then
            stallCount = stallCount + 1
            warn("ServerHop: no suitable server found on attempt", attempt, "stall", stallCount)
            if clearVisitedIfStalled(stallCount) then
                warn("ServerHop: cleared visited cache due to stall; switching to first-available mode")
                preferLeast = false
            end
            if HOP.forceRandomTeleportOnStall and stallCount >= (HOP.maxNilPicks or 3) then
                while tick() < teleportBlockedUntil do
                    task.wait(1)
                end
                local before = teleportFailCounter
                local okTp, err = pcall(function()
                    TeleportService:Teleport(placeId)
                end)
                if not okTp then
                    warn("ServerHop: Random teleport error:", err)
                    scheduleTeleportCooldown(err)
                else
                    task.wait(HOP.teleportConfirmTimeout)
                    if teleportFailCounter == before then
                        return true
                    else
                        warn("ServerHop: Random teleport init failed (event)")
                    end
                end
            end
            task.wait(HOP.retryTeleportDelay)
        else
            local id = srv.id
            stallCount = 0
            visited[id] = true
            saveVisited()
            maybeTrimVisited()

            warn(string.format("ServerHop: teleporting to %s (%d/%d)", id, srv.playing or -1, srv.maxPlayers or -1))

            local teleported = false
            for t = 1, 3 do
                while tick() < teleportBlockedUntil do
                    task.wait(1)
                end
                local before = teleportFailCounter
                local okTp, err = pcall(function()
                    TeleportService:TeleportToPlaceInstance(placeId, id, LocalPlayer)
                end)
                if not okTp then
                    warn("ServerHop: TeleportToPlaceInstance error:", err)
                    scheduleTeleportCooldown(err)
                    task.wait(HOP.retryTeleportDelay)
                else
                    task.wait(HOP.teleportConfirmTimeout)
                    if teleportFailCounter == before then
                        teleported = true
                        break
                    else
                        warn("ServerHop: Teleport init failed (event), retrying...")
                        task.wait(HOP.retryTeleportDelay)
                    end
                end
            end

            if not teleported then
                -- failed to teleport to a specific instance, try generic teleport as fallback
                while tick() < teleportBlockedUntil do
                    task.wait(1)
                end
                local before2 = teleportFailCounter
                local okTp2, err2 = pcall(function()
                    TeleportService:Teleport(placeId)
                end)
                if not okTp2 then
                    warn("ServerHop: Fallback Teleport error:", err2)
                    scheduleTeleportCooldown(err2)
                    task.wait(HOP.retryTeleportDelay)
                else
                    task.wait(HOP.teleportConfirmTimeout)
                    if teleportFailCounter == before2 then
                        return true
                    else
                        warn("ServerHop: Fallback Teleport init failed (event)")
                        task.wait(HOP.retryTeleportDelay)
                    end
                end
            else
                return true
            end
        end
    end

    return false
end

-- Public API and autorun
local M = {}
function M.ServerHop()
    return hop(PLACE_ID)
end

local ok, res = pcall(M.ServerHop)
if not ok then
    warn("ServerHop: error:", res)
end

return M
