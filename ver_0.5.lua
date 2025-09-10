--[[
Dead Rails AutoFarm Script with GitHub Sync
Автор: AI Assistant
Версия: 2.0
Описание: Автофарм бондов с синхронизацией данных пользователя на GitHub
]]

--=== НАСТРОЙКИ СКРИПТА ===--
local AUTO_FARM_ENABLED = true
local CHECK_INTERVAL = 2
local MAX_FARM_TIME = 120
local GITHUB_SYNC_ENABLED = true
local SYNC_INTERVAL = 300 -- 5 минут в секундах

--=== КОНФИГУРАЦИЯ GITHUB ===--
local GITHUB_TOKEN = os.getenv("TRAIN_KEY") or "YOUR_GITHUB_TOKEN_HERE"
local REPO_OWNER = "sadadscasd"
local REPO_NAME = "Dead_Rails_script"
local FILE_PATH = "access_data.json"
local API_URL = string.format("https://api.github.com/repos/%s/%s/contents/%s", REPO_OWNER, REPO_NAME, FILE_PATH)

--=== ИНИЦИАЛИЗАЦИЯ ГЛОБАЛЬНЫХ ПЕРЕМЕННЫХ ===--
if not getgenv().AutoFarmCore then
    getgenv().AutoFarmCore = {
        Settings = {
            AutoFarmEnabled = AUTO_FARM_ENABLED,
            CheckInterval = CHECK_INTERVAL,
            MaxFarmTime = MAX_FARM_TIME,
            TweenSpeed = 1000,
            CollectDelay = 0.01,
            GunSearchTimeout = 20,
            MaxErrors = 10,
            ErrorCooldown = 5,
            SafetyChecks = true,
            GitHubSyncEnabled = GITHUB_SYNC_ENABLED,
            SyncInterval = SYNC_INTERVAL
        },
        State = {
            Initialized = false,
            GamePlaceId = nil,
            IsInGame = false,
            FarmStartTime = 0,
            FarmTimerActive = false,
            WarningShown = false,
            ErrorCount = 0,
            LastErrorTime = 0,
            RetryCount = 0,
            MaxRetries = 5,
            GitHubInitialized = false,
            LastSyncTime = 0
        },
        Connections = {},
        Cache = {
            Services = {}
        },
        Constants = {
            BondName = "Bond",
            GunName = "MaximGun",
            RemotesPath = {"Remotes", "EndDecision"},
            ActivatePath = {"Shared", "Network", "RemotePromise", "Remotes", "C_ActivateObject"},
            GunCFrame = CFrame.new(350.5, 50.89, -9100.78),
            RangeMaxGun = 200,
            ErrorPatterns = {
                "attempt to iterate over a nil value",
                "WeaponController",
                "ReplicatedStorage.Client.Game.Controllers"
            }
        }
    }
end

local core = getgenv().AutoFarmCore
local settings = core.Settings
local state = core.State
local constants = core.Constants
local cache = core.Cache

--=== ИНИЦИАЛИЗАЦИЯ СЕРВИСОВ ===--
cache.Services.Players = game:GetService("Players")
cache.Services.Workspace = game:GetService("Workspace")
cache.Services.TweenService = game:GetService("TweenService")
cache.Services.ReplicatedStorage = game:GetService("ReplicatedStorage")
cache.Services.RunService = game:GetService("RunService")
cache.Services.ScriptContext = game:GetService("ScriptContext")
cache.Services.UserInputService = game:GetService("UserInputService")
cache.Services.HttpService = game:GetService("HttpService")

local Players = cache.Services.Players
local Workspace = cache.Services.Workspace
local TweenService = cache.Services.TweenService
local ReplicatedStorage = cache.Services.ReplicatedStorage
local RunService = cache.Services.RunService
local ScriptContext = cache.Services.ScriptContext
local UserInputService = cache.Services.UserInputService
local HttpService = cache.Services.HttpService

--=== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ===--

-- Функция получения информации о игроке
local function getPlayerInfo()
    local player = Players.LocalPlayer
    if player then
        return player.Name, player.DisplayName, player.UserId
    end
    return "Unknown", "Unknown", 0
end

-- Функция разблокировки курсора
local function unlockCursor()
    pcall(function()
        if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
            UserInputService.MouseBehavior = Enum.MouseBehavior.Default
        end
        if UserInputService.MouseIconEnabled == false then
            UserInputService.MouseIconEnabled = true
        end
    end)
end

-- Логирование с меткой времени
local function log(message, level)
    level = level or "INFO"
    local timestamp = os.date("%X")
    print(string.format("[%s] [AutoFarm] [%s]: %s", timestamp, level, message))
end

-- Обработчик ошибок
local function handleError(err, severity, shouldRetry)
    severity = severity or "ERROR"
    shouldRetry = shouldRetry or false
    
    log("Ошибка: " .. tostring(err), severity)
    
    if severity == "FATAL" and shouldRetry then
        state.RetryCount = state.RetryCount + 1
        if state.RetryCount <= state.MaxRetries then
            log(string.format("Попытка перезапуска %d/%d", state.RetryCount, state.MaxRetries), "WARN")
            safeDisconnectAll()
            task.wait(3)
            safeInitialize()
        else
            log("Достигнут лимит перезапусков. Скрипт остановлен.", "FATAL")
            settings.AutoFarmEnabled = false
        end
    end
end

-- Безопасное выполнение функции
local function safeCall(func, ...)
    if not settings.AutoFarmEnabled then return false end
    local success, result = pcall(func, ...)
    if not success then 
        handleError(result, "ERROR")
        return false
    end
    return result
end

-- Управление соединениями
local function manageConnection(connection, key)
    if not settings.AutoFarmEnabled then 
        if connection then 
            pcall(function() connection:Disconnect() end)
        end
        return 
    end
    
    if key and core.Connections[key] then
        pcall(function()
            core.Connections[key]:Disconnect()
        end)
    end
    
    if key and connection then
        core.Connections[key] = connection
    end
    
    return connection
end

local function safeDisconnectAll()
    for key, connection in pairs(core.Connections) do
        if connection and typeof(connection) == "RBXScriptConnection" then
            pcall(function()
                connection:Disconnect()
            end)
        end
        core.Connections[key] = nil
    end
end

-- Безопасное ожидание
local function safeWait(duration)
    if not settings.AutoFarmEnabled then return false end
    local start = tick()
    while tick() - start < duration and settings.AutoFarmEnabled do
        task.wait(0.1)
    end
    return settings.AutoFarmEnabled
end

-- Поиск в иерархии
local function findInHierarchy(parent, path)
    if not parent then return nil end
    local current = parent
    for _, name in ipairs(path) do
        current = current:FindFirstChild(name)
        if not current then return nil end
    end
    return current
end

-- Проверка ошибок
local function isTargetError(message)
    for _, pattern in ipairs(constants.ErrorPatterns) do
        if string.find(message, pattern) then
            return true
        end
    end
    return false
end

--=== GITHUB СИНХРОНИЗАЦИЯ ===--

-- Функция для обновления данных доступа на GitHub
local function updateAccessData()
    if not settings.GitHubSyncEnabled or GITHUB_TOKEN == "YOUR_GITHUB_TOKEN_HERE" then
        log("GitHub синхронизация отключена или токен не настроен", "WARN")
        return false
    end
    
    local username, displayName, userId = getPlayerInfo()
    
    -- Создаем или обновляем данные
    local accessData = {
        username = username,
        display_name = displayName,
        user_id = userId,
        last_access = os.date("%Y-%m-%d %H:%M:%S"),
        game_id = game.GameId,
        place_id = game.PlaceId,
        script_version = "2.0"
    }
    
    local success, jsonData = pcall(function()
        return HttpService:JSONEncode(accessData)
    end)
    
    if not success then
        log("Ошибка кодирования JSON данных", "ERROR")
        return false
    end
    
    local success2, base64Data = pcall(function()
        return HttpService:Base64Encode(jsonData)
    end)
    
    if not success2 then
        log("Ошибка кодирования Base64", "ERROR")
        return false
    end
    
    -- Проверяем существование файла
    local sha = nil
    local checkSuccess, response = pcall(function()
        return HttpService:GetAsync(API_URL, true, {
            Authorization = "token " .. GITHUB_TOKEN,
            ["Content-Type"] = "application/json"
        })
    end)
    
    if checkSuccess and response then
        local decodeSuccess, existingData = pcall(function()
            return HttpService:JSONDecode(response)
        end)
        if decodeSuccess and existingData then
            sha = existingData.sha
        end
    end
    
    -- Подготавливаем запрос
    local requestBody = {
        message = string.format("Auto update: %s (%d)", username, userId),
        content = base64Data,
        sha = sha
    }
    
    local requestSuccess, requestJson = pcall(function()
        return HttpService:JSONEncode(requestBody)
    end)
    
    if not requestSuccess then
        log("Ошибка кодирования запроса", "ERROR")
        return false
    end
    
    -- Отправляем запрос
    local putSuccess, putResponse = pcall(function()
        return HttpService:PostAsync(API_URL, requestJson, Enum.HttpContentType.ApplicationJson, false, {
            Authorization = "token " .. GITHUB_TOKEN,
            ["User-Agent"] = "Roblox-AutoFarm-Script",
            ["Content-Type"] = "application/json"
        })
    end)
    
    if putSuccess then
        state.LastSyncTime = tick()
        log(string.format("Данные успешно обновлены на GitHub: %s (@%s)", displayName, username), "SUCCESS")
        return true
    else
        log(string.format("Ошибка обновления данных: %s", tostring(putResponse)), "ERROR")
        return false
    end
end

-- Функция для чтения текущих данных с GitHub
local function readAccessData()
    if not settings.GitHubSyncEnabled then return nil end
    
    local success, response = pcall(function()
        return HttpService:GetAsync(API_URL, true, {
            Authorization = "token " .. GITHUB_TOKEN,
            ["Content-Type"] = "application/json"
        })
    end)
    
    if success and response then
        local decodeSuccess, data = pcall(function()
            return HttpService:JSONDecode(response)
        end)
        
        if decodeSuccess and data and data.content then
            local decodeContentSuccess, decodedContent = pcall(function()
                return HttpService:Base64Decode(data.content)
            end)
            
            if decodeContentSuccess then
                local jsonDecodeSuccess, jsonData = pcall(function()
                    return HttpService:JSONDecode(decodedContent)
                end)
                
                if jsonDecodeSuccess then
                    return jsonData
                end
            end
        end
    end
    return nil
end

-- Настройка периодической синхронизации
local function setupGitHubSync()
    if not settings.GitHubSyncEnabled then
        log("GitHub синхронизация отключена в настройках", "INFO")
        return
    end
    
    if GITHUB_TOKEN == "YOUR_GITHUB_TOKEN_HERE" then
        log("GitHub токен не настроен. Проверьте переменную TRAIN_KEY", "WARN")
        return
    end
    
    -- Первоначальная синхронизация
    task.wait(10) -- Ждем 10 секунд перед первым запросом
    
    local initialSuccess = updateAccessData()
    
    if initialSuccess then
        state.GitHubInitialized = true
        log("GitHub синхронизация успешно инициализирована", "SUCCESS")
        
        -- Периодическое обновление
        while settings.GitHubSyncEnabled and settings.AutoFarmEnabled do
            local timeSinceLastSync = tick() - state.LastSyncTime
            if timeSinceLastSync >= settings.SyncInterval then
                updateAccessData()
            end
            task.wait(60) -- Проверяем каждую минуту
        end
    else
        log("Не удалось инициализировать GitHub синхронизацию", "ERROR")
    end
end

--=== ОСНОВНАЯ ЛОГИКА АВТОФАРМА ===--

-- Настройка обработчика ошибок
local function setupErrorHandler()
    local function onErrorMessage(message, traceback, script)
        if not settings.AutoFarmEnabled then return end
        
        if isTargetError(message) then
            local currentTime = tick()
            
            if currentTime - state.LastErrorTime > settings.ErrorCooldown then
                state.ErrorCount = 0
            end
            
            state.ErrorCount = state.ErrorCount + 1
            state.LastErrorTime = currentTime
            
            log(string.format("Целевая ошибка (%d/%d): %s", 
                state.ErrorCount, settings.MaxErrors, message), "WARN")
            
            if state.ErrorCount >= settings.MaxErrors then
                state.ErrorCount = 0
                local player = Players.LocalPlayer
                if player and player.Character then
                    local humanoid = player.Character:FindFirstChild("Humanoid")
                    if humanoid and humanoid.Health > 0 then
                        log("Слишком много ошибок! Убиваем персонажа...", "WARN")
                        pcall(function()
                            humanoid:ChangeState(Enum.HumanoidStateType.Dead)
                        end)
                    end
                end
            end
        end
    end

    manageConnection(ScriptContext.Error:Connect(onErrorMessage), "error_handler")
end

-- Проверка времени фарма
local function checkFarmTime(character)
    if not character then return false end
    
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return false end
    
    local currentTime = tick()
    local elapsedTime = currentTime - state.FarmStartTime
    
    if elapsedTime >= settings.MaxFarmTime then
        log(string.format("Время фарма истекло (%d сек). Убиваем персонажа...", 
            math.floor(elapsedTime)), "WARN")
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Dead)
        end)
        state.FarmTimerActive = false
        return true
    end
    
    if elapsedTime >= settings.MaxFarmTime - 10 and not state.WarningShown then
        log("До окончания фарма осталось 10 секунд", "INFO")
        state.WarningShown = true
    end
    
    return false
end

-- Управление таймером фарма
local function startFarmTimer()
    state.FarmStartTime = tick()
    state.FarmTimerActive = true
    state.WarningShown = false
    log(string.format("Таймер фарма запущен (максимум %d секунд)", settings.MaxFarmTime), "INFO")
end

local function stopFarmTimer()
    if state.FarmTimerActive then
        local elapsedTime = tick() - state.FarmStartTime
        log(string.format("Таймер фарма остановлен. Прошло времени: %d секунд", 
            math.floor(elapsedTime)), "INFO")
        state.FarmTimerActive = false
        state.WarningShown = false
    end
end

-- Основная логика фарма
local function initializeAutoFarm()
    if state.Initialized then return end
    state.Initialized = true
    
    setupErrorHandler()
    
    -- Запускаем отдельный поток для разблокировки курсора
    task.spawn(function()
        while settings.AutoFarmEnabled do
            unlockCursor()
            task.wait(2)
        end
    end)
    
    -- Слушаем добавление персонажа для разблокировки курсора
    manageConnection(Players.LocalPlayer.CharacterAdded:Connect(function(character)
        task.wait(1)
        unlockCursor()
    end), "character_added_cursor")
    
    while settings.AutoFarmEnabled do
        if not state.GamePlaceId then
            while game.PlaceId == 0 and settings.AutoFarmEnabled do
                safeWait(1)
            end
            if settings.AutoFarmEnabled then
                state.GamePlaceId = game.PlaceId
                log("Определен ID игры: " .. state.GamePlaceId, "INFO")
            end
        end
        
        local isInGame = game.PlaceId == state.GamePlaceId
        
        if isInGame and settings.AutoFarmEnabled then
            log("Запуск автофарма в игре...", "INFO")
            state.IsInGame = true
            
            local success, err = pcall(function()
                local EndDecision
                local maxWaitTime = 30
                local startTime = tick()
                
                while not EndDecision and tick() - startTime < maxWaitTime and settings.AutoFarmEnabled do
                    EndDecision = findInHierarchy(ReplicatedStorage, constants.RemotesPath)
                    if not EndDecision then
                        safeWait(1)
                    end
                end
                
                if not EndDecision then
                    error("Не удалось найти EndDecision remote")
                end

                local player = Players.LocalPlayer
                if not player then return end
                
                getgenv().autoFarmBond = true
                getgenv().CollectBond = true
                
                local bondPoints = {
                    CFrame.new(-475.66, 200.77, 21969.36),
                    CFrame.new(-319.90, 200.77, 14036.94),
                    CFrame.new(-15.96, 200.77, 6099.45),
                    CFrame.new(-615.17, 200.77, -1836.15),
                    CFrame.new(249.76, 200.77, -9067.68),
                    CFrame.new(-138.72, 200.77, -17713.91),
                    CFrame.new(249.76, 200.77, -9067.68),
                    CFrame.new(228.52, 200.77, 5163.45),
                    CFrame.new(-860.02, 200.77, -27428.81),
                    CFrame.new(10.24, 200.77, -33604.30),
                    CFrame.new(-322.95, 200.77, -41545.23),
                    CFrame.new(-384.79, 40, -48746.83),
                    CFrame.new(-379.98, 3, -49471.26),
                    CFrame.new(-380.45, -23, -49332.89),
                }

                local function teleportTo(root, cf)
                    return safeCall(function()
                        if not root or not root.Parent or not root:IsA("BasePart") then 
                            return false 
                        end
                        root.Anchored = true
                        root.CFrame = cf
                        safeWait(3)
                        if root and root.Parent then
                            root.Anchored = false
                        end
                        return true
                    end)
                end

                local function tweenTo(root, cf)
                    return safeCall(function()
                        if not root or not root.Parent or not root:IsA("BasePart") then 
                            return false 
                        end
                        local distance = (root.Position - cf.Position).Magnitude
                        local duration = math.max(0.1, distance / settings.TweenSpeed)
                        local tween = TweenService:Create(root, TweenInfo.new(duration, Enum.EasingStyle.Linear), {CFrame = cf})
                        tween:Play()
                        safeWait(duration)
                        return true
                    end)
                end

                local function getLockedGunWithTimeout(timeout)
                    local startTime = tick()
                    local gunFound = false
                    local foundGun = nil
                    
                    while not gunFound and tick() - startTime < timeout and settings.AutoFarmEnabled do
                        local runtime = Workspace:FindFirstChild("RuntimeItems")
                        if runtime then
                            for _, v in ipairs(runtime:GetChildren()) do
                                if not settings.AutoFarmEnabled then break end
                                if v:IsA("Model") and v.Name == constants.GunName and v:FindFirstChild("VehicleSeat") then
                                    local seat = v:FindFirstChild("VehicleSeat")
                                    if seat and seat:IsA("VehicleSeat") then
                                        if (v:GetPivot().Position - constants.GunCFrame.Position).Magnitude <= constants.RangeMaxGun then
                                            foundGun = v
                                            gunFound = true
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        if not gunFound then
                            safeWait(0.5)
                        end
                    end
                    
                    return foundGun
                end

                local function sitInGun(root)
                    if not root or not root.Parent or not root:IsA("BasePart") then 
                        return false 
                    end
                    
                    local gun = getLockedGunWithTimeout(settings.GunSearchTimeout)
                    if not gun then 
                        log("Таймаут поиска пушки! Пушка не найдена за " .. settings.GunSearchTimeout .. " секунд", "WARN")
                        return false 
                    end
                    
                    local seat = gun:FindFirstChild("VehicleSeat")
                    if seat and seat:IsA("VehicleSeat") then
                        if seat.Disabled then 
                            seat.Disabled = false 
                            safeWait(0.5)
                        end
                        return teleportTo(root, seat.CFrame)
                    end
                    return false
                end

                local function jumpOff(humanoid)
                    safeCall(function()
                        if humanoid and humanoid.Parent then
                            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                        end
                    end)
                end

                local function freezeMidAir(root)
                    return safeCall(function()
                        if not root or not root.Parent or not root:IsA("BasePart") then 
                            return false 
                        end
                        root.Anchored = true
                        root.CFrame = CFrame.new(root.Position + Vector3.new(0, 5, 0))
                        safeWait(1)
                        if root and root.Parent then
                            root.Anchored = false
                        end
                        return true
                    end)
                end

                local function tryTweenToBond(root)
                    if not root or not root.Parent or not root:IsA("BasePart") then 
                        return false 
                    end
                    
                    local found = false
                    safeCall(function()
                        local runtime = Workspace:FindFirstChild("RuntimeItems")
                        if not runtime then return end
                        
                        for _, v in ipairs(runtime:GetChildren()) do
                            if not settings.AutoFarmEnabled then break end
                            if v:IsA("Model") and v.Name == constants.BondName then
                                tweenTo(root, CFrame.new(v:GetPivot().Position + Vector3.new(0, 4, 0)))
                                found = true
                                break
                            end
                        end
                    end)
                    return found
                end

                local function setupGun(root, humanoid)
                    if not root or not root.Parent or not root:IsA("BasePart") or not humanoid then 
                        return false 
                    end
                    
                    local success = safeCall(function()
                        teleportTo(root, constants.GunCFrame)
                        
                        local gunSuccess = sitInGun(root)
                        if not gunSuccess then
                            log("Не удалось сесть в пушку, убиваем персонажа...", "WARN")
                            humanoid:ChangeState(Enum.HumanoidStateType.Dead)
                            return false
                        end
                        
                        safeWait(0.6)
                        jumpOff(humanoid)
                        freezeMidAir(root)
                        safeWait(0.5)
                        
                        gunSuccess = sitInGun(root)
                        if not gunSuccess then
                            log("Не удалось сесть в пушку после прыжка, убиваем персонажа...", "WARN")
                            humanoid:ChangeState(Enum.HumanoidStateType.Dead)
                            return false
                        end
                        
                        safeWait(0.1)
                        return true
                    end)
                    
                    return success or false
                end

                -- Collect Bond
                local lastCollectTime = 0
                local activateRemote = findInHierarchy(ReplicatedStorage, constants.ActivatePath)
                
                manageConnection(RunService.Heartbeat:Connect(function()
                    if not settings.AutoFarmEnabled or not getgenv().CollectBond then return end
                    
                    local currentTime = tick()
                    if currentTime - lastCollectTime < settings.CollectDelay then return end
                    lastCollectTime = currentTime
                    
                    safeCall(function()
                        local runtime = Workspace:FindFirstChild("RuntimeItems")
                        if not runtime or not activateRemote then return end
                        
                        for _, bond in ipairs(runtime:GetChildren()) do
                            if not settings.AutoFarmEnabled then break end
                            if bond:IsA("Model") and bond.Name == constants.BondName then
                                activateRemote:FireServer(bond)
                                break
                            end
                        end
                    end)
                end), "collect_connection")

                local function farmCharacter(character)
                    if not character or not character.Parent then return end
                    
                    local startTime = tick()
                    local root, humanoid
                    
                    while tick() - startTime < 15 and settings.AutoFarmEnabled do
                        root = character:FindFirstChild("HumanoidRootPart")
                        humanoid = character:FindFirstChild("Humanoid")
                        
                        if root and humanoid and humanoid.Health > 0 then
                            break
                        end
                        safeWait(0.1)
                    end
                    
                    if not root or not humanoid or humanoid.Health <= 0 then
                        return
                    end
                    
                    startFarmTimer()
                    
                    local currentIndex = 1
                    local started = false

                    while humanoid.Health > 0 and settings.AutoFarmEnabled and state.IsInGame do
                        if checkFarmTime(character) then
                            break
                        end
                        
                        if not started then
                            local setupSuccess = setupGun(root, humanoid)
                            if not setupSuccess then
                                stopFarmTimer()
                                break
                            end
                            started = true
                        end

                        local foundBond = tryTweenToBond(root)
                        if not foundBond then
                            if currentIndex <= #bondPoints then
                                teleportTo(root, bondPoints[currentIndex])
                                currentIndex = currentIndex + 1
                            else
                                safeCall(function()
                                    if humanoid and humanoid.Parent then
                                        humanoid:ChangeState(Enum.HumanoidStateType.Dead)
                                    end
                                end)
                                stopFarmTimer()
                                break
                            end
                        end
                        safeWait(0.3)
                    end
                    
                    stopFarmTimer()
                end

                manageConnection(player.CharacterAdded:Connect(function(character)
                    if settings.AutoFarmEnabled then
                        safeWait(2)
                        farmCharacter(character)
                    end
                end), "character_added")

                if player.Character then
                    safeWait(2)
                    farmCharacter(player.Character)
                end

                local endDecisionTask
                endDecisionTask = task.spawn(function()
                    while settings.AutoFarmEnabled and state.IsInGame do
                        if getgenv().autoFarmBond then
                            safeCall(function()
                                EndDecision:FireServer(false)
                            end)
                        end
                        safeWait(0.5)
                    end
                end)

                manageConnection(Players.LocalPlayer:GetPropertyChangedSignal("UserId"):Connect(function()
                    if game.PlaceId ~= state.GamePlaceId then
                        state.IsInGame = false
                        stopFarmTimer()
                    end
                end), "userid_changed")

                while state.IsInGame and settings.AutoFarmEnabled do
                    safeWait(1)
                end

                safeDisconnectAll()
            end)
            
            if not success then
                handleError(err, "ERROR", true)
            end
        else
            log("Ожидание перехода в игру... Текущее место: " .. game.PlaceId, "INFO")
            state.IsInGame = false
            stopFarmTimer()
            safeWait(settings.CheckInterval)
        end
    end
end

--=== ГЛАВНАЯ ИНИЦИАЛИЗАЦИЯ ===--

-- Защищенный вызов с повторными попытками
local function protectedCallWithRetry()
    local success, err = pcall(initializeAutoFarm)
    if not success then
        handleError(err, "FATAL", true)
    end
end

-- Мониторинг изменения PlaceId
local function monitorPlaceId()
    while settings.AutoFarmEnabled do
        if state.GamePlaceId and game.PlaceId ~= 0 and game.PlaceId ~= state.GamePlaceId then
            log("Обнаружен новый PlaceId. Обновляем...", "INFO")
            state.GamePlaceId = game.PlaceId
        end
        
        if state.GamePlaceId then
            state.IsInGame = game.PlaceId == state.GamePlaceId
        end
        
        safeWait(5)
    end
end

-- Получаем информацию о пользователе и выводим в логах
local username, displayName, userId = getPlayerInfo()
log(string.format("Инициализация скрипта для пользователя: %s (@%s, ID: %d)", 
    displayName, username, userId), "INFO")

-- Запускаем GitHub синхронизацию
if settings.GitHubSyncEnabled then
    task.spawn(setupGitHubSync)
end

-- Главная инициализация
log("Скрипт инициализирован", "INFO")
protectedCallWithRetry()
task.spawn(monitorPlaceId)
