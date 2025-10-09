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
}

-- Server hop behavior config
local HOP = {
    preferLeastPlayers = true, -- pick least-populated valid server if true, else first available
    maxHopAttempts = 50,       -- maximum number of servers to try
    perServerDetectTimeout = CFG.detecttimeout, -- seconds to wait in a server for targets to load
    retryTeleportDelay = 2,    -- seconds between teleport retries
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

local function toServerLink(placeId, jobId)
    return string.format("roblox://placeId=%d&gameInstanceId=%s", tonumber(placeId) or 0, tostring(jobId))
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

local function findSprouts()
    local folder = Workspace:FindFirstChild("Sprouts") or Workspace
    local results = {}
    for _, inst in ipairs(folder:GetDescendants()) do
        if inst:IsA("Model") and string.find(string.lower(inst.Name), "sprout") then
            local pos = instancePosition(inst)
            local field = nearestFieldName(pos)
            local rarity = mapSproutRarity(inst.Name)
            local allow = CFG.rarity[rarity]
            if not allow and (rarity == "Epic" or rarity == "Legendary" or rarity == "Supreme") then
                allow = CFG.rarity["Epic+"]
            end
            if allow and not inBlacklist(field) then
                table.insert(results, { kind = "sprout", rarity = rarity, field = field, pos = pos })
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

    local link = toServerLink(PLACE_ID, CURRENT_JOB_ID)
    pushNotification(title, string.format("Field: %s\nJobId: %s", tostring(result.field), tostring(CURRENT_JOB_ID)), 20)
    local embed = {
        username = "BSS ServerHop",
        embeds = {
            {
                title = title,
                description = string.format("Field: %s\nJobId: %s\nLink: %s", tostring(result.field), tostring(CURRENT_JOB_ID), link),
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

local function applyMovementSettings()
    local char = ensureCharacter()
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and CFG.walkspeed then
        pcall(function() hum.WalkSpeed = CFG.walkspeed end)
    end
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

local function moveToPosition(pos, timeout)
    local hum = getHumanoid()
    local hrp = getHRP()
    if not hum or not hrp or not pos then return false end
    local reached = false
    pcall(function()
        hum:MoveTo(pos)
    end)
    local conn
    conn = hum.MoveToFinished:Connect(function(r)
        reached = r
    end)
    local t0 = tick()
    while tick() - t0 < (timeout or 6) and not reached do
        if (hrp.Position - pos).Magnitude < 3 then
            reached = true
            break
        end
        task.wait(0.1)
    end
    if conn then conn:Disconnect() end
    return reached
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

local function collectTokens(duration, aroundPos, radius)
    local hrp = getHRP()
    local tEnd = tick() + (duration or 10)
    while tick() < tEnd do
        local origin = (aroundPos or (hrp and hrp.Position))
        if not origin then break end
        local tok = findNearestToken(origin, radius or CFG.tokenradius)
        if tok and tok:IsA("BasePart") then
            moveToPosition(tok.Position, 4)
        else
            task.wait(0.25)
        end
    end
end

local function locateViciousNear(pos)
    local nearest, best = nil, math.huge
    for _, inst in ipairs(Workspace:GetDescendants()) do
        if inst:IsA("Model") then
            local name = string.lower(inst.Name)
            if string.find(name, "vicious") and string.find(name, "bee") then
                local ip = instancePosition(inst)
                if ip then
                    local d = (ip - pos).Magnitude
                    if d < best then
                        nearest, best = inst, d
                    end
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
    while tick() < tEnd do
        if not target or not target.Parent then break end
        local bpos = instancePosition(target)
        if not bpos then break end
        moveToPosition(bpos, 2)
        collectTokens(1.5, bpos, math.min(50, CFG.tokenradius or 75))
        -- Reacquire in case the model reference changes
        target = locateViciousNear(bpos)
    end
    collectTokens(10, (getHRP() and getHRP().Position) or startPos, CFG.tokenradius)
end

local function farmSprout(result)
    local targetPos = result.pos
    if targetPos then
        moveToPosition(targetPos, 8)
    end
    local duration = CFG.sprouttime or 120
    local tEnd = tick() + duration
    while tick() < tEnd do
        collectTokens(2, targetPos or (getHRP() and getHRP().Position) or Vector3.new(), CFG.tokenradius)
        task.wait(0.2)
    end
end

-- Main hop logic
local function waitForTargets()
    -- Wait some time for assets to spawn, periodically scanning
    local deadline = tick() + HOP.perServerDetectTimeout
    while tick() < deadline do
        local found = detectTargets()
        if #found > 0 then
            announceFound(found[1])
            -- Optional autopilot
            pcall(function()
                local f = found[1]
                if f.kind == "vicious" and CFG.autovicious then
                    engageVicious(f)
                elseif f.kind == "sprout" and CFG.autosprouts then
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

    for attempt = 1, HOP.maxHopAttempts do
        -- Scan this server for targets first
        local ok, res = pcall(waitForTargets)
        if ok and res then
            warn("ServerHop: target found, staying on this server.")
            return true
        end

        -- Otherwise, hop to next server
        local srv = pickServer(placeId, visited, HOP.preferLeastPlayers)
        if not srv then
            warn("ServerHop: no suitable server found on attempt", attempt)
            task.wait(HOP.retryTeleportDelay)
        else
            local id = srv.id
            visited[id] = true
            saveVisited()

            warn(string.format("ServerHop: teleporting to %s (%d/%d)", id, srv.playing or -1, srv.maxPlayers or -1))

            local teleported = false
            for t = 1, 3 do
                local okTp, err = pcall(function()
                    TeleportService:TeleportToPlaceInstance(placeId, id, LocalPlayer)
                end)
                if okTp then
                    teleported = true
                    break
                else
                    warn("ServerHop: Teleport failed:", err)
                    task.wait(HOP.retryTeleportDelay)
                end
            end

            if not teleported then
                -- failed to teleport, try another server next loop
                task.wait(HOP.retryTeleportDelay)
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
