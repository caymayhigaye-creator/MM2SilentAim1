-- centuryism Gun silent-aim, Luau, exploit namecall hook, server-confirmed hitscan + latency comp
warn 'silent-aim loaded — F1: toggle | F2: target part'

local enabled = true
local targetPartName = 'HumanoidRootPart'
local firing = false

local Players = game:GetService 'Players'
local UIS = game:GetService 'UserInputService'
local Workspace = game:GetService 'Workspace'
local RunService = game:GetService 'RunService'
local LocalPlayer = Players.LocalPlayer

local oldnamecall

local leadFraction = 0.85 -- 1.0 = tam tahmin, düşürmek overshoot'u azaltır, F3 ile ayarlanabilir

local posHistory = {} -- [Player] = { {pos=Vector3, t=number}, ... }
local HISTORY_LEN = 3

-- ping moving average — tek örnek jitter'ını ezer
local pingHistory = {}
local PING_HISTORY_LEN = 5

local function getSmoothedPing(): number
    local raw = LocalPlayer:GetNetworkPing() / 2
    table.insert(pingHistory, raw)
    while #pingHistory > PING_HISTORY_LEN do
        table.remove(pingHistory, 1)
    end
    local sum = 0
    for _, v in ipairs(pingHistory) do sum += v end
    return sum / #pingHistory
end

local function trackPosition(player: Player, part: BasePart)
    local hist = posHistory[player]
    if not hist then
        hist = {}
        posHistory[player] = hist
    end
    table.insert(hist, { pos = part.Position, t = os.clock() })
    while #hist > HISTORY_LEN do
        table.remove(hist, 1)
    end
end

local function smoothedVelocity(player: Player, fallback: Vector3): Vector3
    local hist = posHistory[player]
    if not hist or #hist < 2 then return fallback end
    local first, last = hist[1], hist[#hist]
    local dt = last.t - first.t
    if dt < 1e-3 then return fallback end
    return (last.pos - first.pos) / dt
end

RunService.Heartbeat:Connect(function()
    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer then continue end
        local pc = p.Character
        if not pc then continue end
        local part = pc:FindFirstChild 'HumanoidRootPart'
        if part then trackPosition(p, part) end
    end
end)

local function getOriginCFrame(): CFrame?
    local char = LocalPlayer.Character
    if not char then return nil end
    local hrp = char:FindFirstChild 'HumanoidRootPart'
    if not hrp then return nil end
    local attach = hrp:FindFirstChild 'GunRaycastAttachment'
    if not attach then return nil end
    return attach.WorldCFrame
end

local function hasLineOfSight(origin: Vector3, targetPos: Vector3, ignoreList: { Instance }): boolean
    local dir = (targetPos - origin)
    if dir.Magnitude < 1e-3 then return true end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = ignoreList
    local result = Workspace:Raycast(origin, dir.Unit * dir.Magnitude, params)
    if not result then return true end
    local hitModel = result.Instance:FindFirstAncestorOfClass 'Model'
    return hitModel ~= nil and hitModel:FindFirstChildOfClass 'Humanoid' ~= nil
end

-- part + sahibi player birlikte döner, SADECE knife taşıyan (murderer) hedeflenir
local function getBestEnemy(originPos: Vector3): (BasePart?, Player?)
    local char = LocalPlayer.Character
    if not char then return nil end

    local function hasKnife(p: Player): boolean
        local bp = p:FindFirstChild 'Backpack'
        if bp and bp:FindFirstChild 'Knife' then return true end
        local pc = p.Character
        if pc and pc:FindFirstChild 'Knife' then return true end
        return false
    end

    local candidates = {}

    for _, p in ipairs(Players:GetPlayers()) do
        if p == LocalPlayer then continue end
        if not hasKnife(p) then continue end

        local pc = p.Character
        if not pc then continue end
        local hum = pc:FindFirstChildOfClass 'Humanoid'
        if not hum or hum.Health <= 0 then continue end

        local part = pc:FindFirstChild(targetPartName) or pc:FindFirstChild 'HumanoidRootPart'
        if not part then continue end

        table.insert(candidates, { part = part, player = p })
    end

    table.sort(candidates, function(a, b)
        return (a.part.Position - originPos).Magnitude < (b.part.Position - originPos).Magnitude
    end)

    local ignoreList = { char }
    for _, c in ipairs(candidates) do
        if hasLineOfSight(originPos, c.part.Position, ignoreList) then
            return c.part, c.player
        end
    end

    return nil, nil
end

local function predictLatencyCompensatedPos(player: Player, part: BasePart, pingSeconds: number): Vector3
    local rawVel = part.AssemblyLinearVelocity
    local smoothVel = smoothedVelocity(player, rawVel)

    local hum = part.Parent and part.Parent:FindFirstChildOfClass 'Humanoid'
    local state = hum and hum:GetState()
    local airborne = (state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping)

    local effectivePing = pingSeconds * leadFraction

    if not airborne then
        return part.Position + smoothVel * effectivePing
    end

    local gravity = Workspace.Gravity
    local horizVel = Vector3.new(smoothVel.X, 0, smoothVel.Z)
    local vertVel = rawVel.Y

    local horizDelta = horizVel * effectivePing
    local vertDelta = vertVel * effectivePing - 0.5 * gravity * effectivePing * effectivePing

    return part.Position + horizDelta + Vector3.new(0, vertDelta, 0)
end

oldnamecall = hookmetamethod(game, '__namecall', function(Self, ...)
    local method = getnamecallmethod()
    local args = { ... }

    if firing then
        return oldnamecall(Self, table.unpack(args))
    end

    if enabled and method == 'FireServer'
        and typeof(Self) == 'Instance'
        and Self.ClassName == 'RemoteEvent'
        and Self.Name == 'Shoot'
        and Self.Parent
        and Self.Parent:IsA 'Tool'
    then
        local originCF = getOriginCFrame()
        if originCF then
            local enemyPart, enemyPlayer = getBestEnemy(originCF.Position)
            if enemyPart and enemyPlayer then
                local ping = getSmoothedPing() -- eskisi: LocalPlayer:GetNetworkPing() / 2
                local predictedPos = predictLatencyCompensatedPos(enemyPlayer, enemyPart, ping)
                local targetCF = CFrame.new(predictedPos)

                firing = true
                local ok, err = pcall(function()
                    Self:FireServer(originCF, targetCF)
                end)
                firing = false

                if ok then
                    warn('silent-aim -> ' .. enemyPlayer.Name .. ' (ping=' .. math.floor(ping * 1000) .. 'ms)')
                    return
                else
                    warn('silent-aim call failed: ' .. tostring(err))
                end
            else
                warn('silent-aim: temiz hatta hedef yok, normal atış geçiyor')
            end
        else
            warn('silent-aim: originCF bulunamadı')
        end
    end

    return oldnamecall(Self, table.unpack(args))
end)

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end

    if input.KeyCode == Enum.KeyCode.F1 then
        enabled = not enabled
        warn('silent-aim ' .. (enabled and 'ON' or 'OFF'))

    elseif input.KeyCode == Enum.KeyCode.F2 then
        targetPartName = (targetPartName == 'HumanoidRootPart') and 'Head' or 'HumanoidRootPart'
        warn('target part: ' .. targetPartName)

    elseif input.KeyCode == Enum.KeyCode.F3 then
        leadFraction = math.clamp(leadFraction - 0.05, 0.3, 1.0)
        warn('lead fraction: ' .. leadFraction)

    elseif input.KeyCode == Enum.KeyCode.F4 then
        leadFraction = math.clamp(leadFraction + 0.05, 0.3, 1.0)
        warn('lead fraction: ' .. leadFraction)
    end
end)
