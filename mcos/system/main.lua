-- McOS 1.0 for CC:Tweaked
-- Main system core. Installed by McOS installer.

local OS_NAME = "McOS"
local OS_VERSION = "1.0.0"
local ROOT = "/mcos"
local SYSTEM_DIR = ROOT .. "/system"
local APPS_DIR = ROOT .. "/apps"
local DATA_DIR = ROOT .. "/data"
local USER_DIR = ROOT .. "/user"
local NOTES_DIR = USER_DIR .. "/notes"
local MUSIC_DIR = USER_DIR .. "/music"
local INBOX_DIR = USER_DIR .. "/inbox"
local TRASH_DIR = ROOT .. "/trash"
local BACKUP_DIR = ROOT .. "/backups"
local CONFIG_FILE = DATA_DIR .. "/config.db"
local NOTIFY_FILE = DATA_DIR .. "/notifications.db"
local LOG_FILE = DATA_DIR .. "/system.log"
local RS_FILE = DATA_DIR .. "/redstone.db"
local TRASH_FILE = DATA_DIR .. "/trash.db"
local TIMER_FILE = DATA_DIR .. "/timers.db"
local NET_FILE = DATA_DIR .. "/mcnet.db"
local BOOT_FLAG = DATA_DIR .. "/boot.flag"
local RESTORE_JOURNAL = ROOT .. "/restore_journal.db"
local NET_PROTOCOL = "mcos2"
local unpack = table.unpack or unpack

local function ensureDir(path)
    if not path or path == "" then return true end
    if fs.exists(path) then return fs.isDir(path) end
    local ok = pcall(fs.makeDir, path)
    return ok and fs.exists(path) and fs.isDir(path)
end

-- Recover interrupted verified writes before loading any state. McOS reserves these
-- sidecar suffixes inside /mcos and never exposes them as user-facing filenames.
local function recoverAtomicTree(path, depth)
    if path == BACKUP_DIR then return true end
    if depth > 16 or not fs.exists(path) or not fs.isDir(path) then return true end
    local listOk, names = pcall(fs.list, path)
    if not listOk then return false, tostring(names) end
    for _, name in ipairs(names) do
        local full = fs.combine(path, name)
        if fs.isDir(full) then
            local ok, err = recoverAtomicTree(full, depth + 1)
            if not ok then return false, err end
        elseif name:sub(-14) == ".mcos_previous" then
            local target = full:sub(1, -15)
            if fs.exists(target) then
                local ok, err = pcall(fs.delete, full)
                if not ok then return false, tostring(err) end
            else
                local ok, err = pcall(fs.move, full, target)
                if not ok then return false, tostring(err) end
            end
        elseif name:sub(-9) == ".mcos_tmp" then
            local ok, err = pcall(fs.delete, full)
            if not ok then return false, tostring(err) end
        end
    end
    return true
end

local function earlyReadTable(path)
    if not fs.exists(path) or fs.isDir(path) then return nil end
    local h = fs.open(path, "r")
    if not h then return nil end
    local ok, raw = pcall(h.readAll)
    pcall(h.close)
    if not ok then return nil end
    local decodedOk, value = pcall(textutils.unserialize, raw)
    return decodedOk and type(value) == "table" and value or nil
end

local atomicOk, atomicErr = recoverAtomicTree(ROOT, 0)
if not atomicOk then error("Unable to recover an interrupted McOS write: " .. tostring(atomicErr), 0) end

-- A restore journal is written before any live directory is replaced. If the
-- computer stopped mid-restore, roll every target back before creating folders.
if fs.exists(RESTORE_JOURNAL) then
    local journal = earlyReadTable(RESTORE_JOURNAL)
    if not journal or type(journal.operations) ~= "table" then
        error("The McOS restore journal is damaged. Restore it manually or reinstall McOS.", 0)
    end
    local recoveryOk, recoveryErr = true, nil
    for i = #journal.operations, 1, -1 do
        local op = journal.operations[i]
        if type(op) == "table" and type(op.target) == "string" then
            local target = op.target
            local temporary = type(op.temporary) == "string" and op.temporary or (target .. ".restore_new")
            local previous = type(op.previous) == "string" and op.previous or (target .. ".restore_previous")
            if op.hadOriginal == true then
                if fs.exists(previous) then
                    if fs.exists(target) then
                        local ok, err = pcall(fs.delete, target)
                        if not ok then recoveryOk, recoveryErr = false, err break end
                    end
                    local ok, err = pcall(fs.move, previous, target)
                    if not ok then recoveryOk, recoveryErr = false, err break end
                end
            elseif fs.exists(target) and not fs.exists(temporary) then
                local ok, err = pcall(fs.delete, target)
                if not ok then recoveryOk, recoveryErr = false, err break end
            end
            if fs.exists(temporary) then
                local ok, err = pcall(fs.delete, temporary)
                if not ok then recoveryOk, recoveryErr = false, err break end
            end
        end
    end
    if not recoveryOk then error("Unable to roll back an interrupted McOS restore: " .. tostring(recoveryErr), 0) end
    pcall(fs.delete, RESTORE_JOURNAL)
end

for _, path in ipairs({ ROOT, SYSTEM_DIR, APPS_DIR, DATA_DIR, USER_DIR, NOTES_DIR, MUSIC_DIR, INBOX_DIR, TRASH_DIR, BACKUP_DIR }) do
    if not ensureDir(path) then error("Unable to create directory: " .. path, 0) end
end

local function readAll(path, mode)
    local h = fs.open(path, mode or "r")
    if not h then return nil, "Unable to open " .. tostring(path) end
    local ok, data = pcall(h.readAll)
    pcall(h.close)
    if not ok then return nil, tostring(data) end
    return data
end

local function writeAll(path, data, mode)
    mode = mode or "w"
    local dir = fs.getDir(path)
    if dir ~= "" and not ensureDir(dir) then return false, "Unable to create " .. dir end
    if fs.isReadOnly(path) then return false, "Path is read-only: " .. path end

    -- Append operations (the system log) cannot use replacement semantics.
    if mode:sub(1, 1) == "a" then
        local h = fs.open(path, mode)
        if not h then return false, "Unable to open " .. path .. " for writing" end
        local ok, err = pcall(h.write, data or "")
        pcall(h.close)
        if not ok then return false, tostring(err) end
        return true
    end

    -- Write to a verified temporary file, then replace the old file with rollback.
    -- This prevents a full disk or interrupted move from silently truncating state.
    local temporary, previous = path .. ".mcos_tmp", path .. ".mcos_previous"
    if fs.exists(previous) then
        if not fs.exists(path) then
            local recovered = pcall(fs.move, previous, path)
            if not recovered then return false, "Unable to recover the previous copy of " .. path end
        else
            pcall(fs.delete, previous)
        end
    end
    if fs.exists(temporary) then pcall(fs.delete, temporary) end

    local h = fs.open(temporary, mode)
    if not h then return false, "Unable to open a temporary file for " .. path end
    local ok, err = pcall(h.write, data or "")
    pcall(h.close)
    if not ok then pcall(fs.delete, temporary) return false, tostring(err) end

    local verifyMode = mode:find("b", 1, true) and "rb" or "r"
    local verify, verifyErr = readAll(temporary, verifyMode)
    if verify == nil or verify ~= (data or "") then
        pcall(fs.delete, temporary)
        return false, verifyErr or ("Write verification failed for " .. path)
    end

    local hadOriginal = fs.exists(path)
    if hadOriginal then
        local movedOld, moveOldErr = pcall(fs.move, path, previous)
        if not movedOld then pcall(fs.delete, temporary) return false, tostring(moveOldErr) end
    end
    local movedNew, moveNewErr = pcall(fs.move, temporary, path)
    if not movedNew then
        pcall(fs.delete, temporary)
        if hadOriginal and fs.exists(previous) then pcall(fs.move, previous, path) end
        return false, tostring(moveNewErr)
    end
    if fs.exists(previous) then pcall(fs.delete, previous) end
    return true
end

local function readTable(path, fallback)
    if not fs.exists(path) or fs.isDir(path) then return fallback end
    local raw = readAll(path)
    if not raw then return fallback end
    local ok, value = pcall(textutils.unserialize, raw)
    if ok and type(value) == "table" then return value end
    return fallback
end

local function writeTable(path, value)
    local ok, encoded = pcall(textutils.serialize, value)
    if not ok then return false, tostring(encoded) end
    return writeAll(path, encoded)
end

local function nowMs()
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then return value end
    return math.floor(os.clock() * 1000)
end

local function timestamp()
    local d = os.date("!*t")
    return string.format("%04d%02d%02d-%02d%02d%02d", d.year, d.month, d.day, d.hour, d.min, d.sec)
end

local function deepCopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local copy = {}
    seen[value] = copy
    for k, v in pairs(value) do copy[deepCopy(k, seen)] = deepCopy(v, seen) end
    return copy
end

local function canonicalPath(path)
    path = tostring(path or "/")
    if path == "" then path = "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return fs.combine("/", path)
end

local function isInside(path, parent)
    path, parent = canonicalPath(path), canonicalPath(parent)
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

local function safeName(name, fallback)
    name = tostring(name or "")
    name = name:gsub("[%z\1-\31]", "_")
    name = name:gsub("[\\/:*?\"<>|]", "_")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("^%.+", ""):gsub("%.+$", "")
    if name == "" or name == "." or name == ".." then name = fallback or "file" end
    local lower = name:lower()
    if lower:sub(-9) == ".mcos_tmp" or lower:sub(-14) == ".mcos_previous"
        or lower:sub(-12) == ".restore_new" or lower:sub(-17) == ".restore_previous" then
        name = name .. "_file"
    end
    return name:sub(1, 96)
end

local validSides = { top = true, bottom = true, left = true, right = true, front = true, back = true }
local function normalSide(side)
    side = type(side) == "string" and side:lower() or nil
    return side and validSides[side] and side or nil
end

local function analogValue(value, fallback)
    value = tonumber(value)
    if not value then return fallback end
    return math.max(0, math.min(15, math.floor(value + 0.5)))
end

local function isProtectedWriteTarget(path)
    path = canonicalPath(path)
    return path == "/startup.lua" or path == RESTORE_JOURNAL or isInside(path, SYSTEM_DIR)
        or isInside(path, DATA_DIR) or isInside(path, TRASH_DIR) or isInside(path, BACKUP_DIR)
end

local function isProtectedContainer(path)
    path = canonicalPath(path)
    -- Users may create files in /, /mcos/user and /mcos/apps. The internal
    -- system, state, recycle-bin and backup trees remain write-protected.
    return path == ROOT or isInside(path, SYSTEM_DIR) or isInside(path, DATA_DIR)
        or isInside(path, TRASH_DIR) or isInside(path, BACKUP_DIR)
end

local function isProtectedPath(path)
    path = canonicalPath(path)
    -- Structural roots cannot be renamed, cut or deleted, while their ordinary
    -- contents remain manageable where appropriate.
    return path == "/" or path == "/startup.lua" or path == ROOT
        or path == APPS_DIR or path == USER_DIR or path == NOTES_DIR
        or path == MUSIC_DIR or path == INBOX_DIR or isProtectedWriteTarget(path)
end

local function formatBytes(value)
    if type(value) ~= "number" then return tostring(value or "unknown") end
    local units = { "B", "KB", "MB", "GB" }
    local index = 1
    while value >= 1024 and index < #units do
        value = value / 1024
        index = index + 1
    end
    if index == 1 then return tostring(math.floor(value)) .. " " .. units[index] end
    return string.format("%.1f %s", value, units[index])
end

local themes = {
    blue =   { desktop = colors.lightBlue, panel = colors.blue,   accent = colors.cyan,      text = colors.white, dark = colors.black, soft = colors.lightGray },
    red =    { desktop = colors.red,       panel = colors.brown,  accent = colors.orange,    text = colors.white, dark = colors.black, soft = colors.lightGray },
    green =  { desktop = colors.lime,      panel = colors.green,  accent = colors.yellow,    text = colors.white, dark = colors.black, soft = colors.lightGray },
    purple = { desktop = colors.magenta,   panel = colors.purple, accent = colors.pink,      text = colors.white, dark = colors.black, soft = colors.lightGray },
    gray =   { desktop = colors.lightGray, panel = colors.gray,   accent = colors.lightBlue, text = colors.white, dark = colors.black, soft = colors.white },
}
local themeOrder = { "blue", "red", "green", "purple", "gray" }

local defaults = {
    theme = "blue",
    showClock = true,
    confirmPower = true,
    guideCompleted = false,
    monitorScale = 0.5,
    autoTouchDisplay = false,
    username = "User",
    pinHash = nil,
    allowRemoteRedstone = false,
    allowRemoteRun = false,
    trustedPeers = {},
    peripheralAliases = {},
    favorites = { "/", NOTES_DIR, INBOX_DIR },
    desktopPins = { "files", "redstone", "peripherals", "mcnet", "notes", "calculator", "clock", "settings", "tasks", "notifications", "store", "about" },
}

-- Import compatible settings from legacy McOS preview builds on the first McOS 1.0 launch.
if not fs.exists(CONFIG_FILE) and fs.exists("/.mcos/config") then
    local legacy = readTable("/.mcos/config", {})
    if type(legacy) == "table" then
        local migrated = {}
        for _, key in ipairs({ "theme", "showClock", "confirmPower", "guideCompleted", "monitorScale", "autoTouchDisplay" }) do
            if legacy[key] ~= nil then migrated[key] = legacy[key] end
        end
        writeTable(CONFIG_FILE, migrated)
    end
end

local config = readTable(CONFIG_FILE, {})
if type(config) ~= "table" then config = {} end
-- Upgrade the old single remote-control switch without silently enabling anything new.
if config.allowRemote ~= nil then
    config.allowRemoteRedstone = false
    config.allowRemoteRun = false
    config.allowRemote = nil
end
for key, value in pairs(defaults) do
    if config[key] == nil then config[key] = deepCopy(value) end
end
if not themes[config.theme] then config.theme = "blue" end
for _, key in ipairs({ "showClock", "confirmPower", "guideCompleted", "autoTouchDisplay" }) do
    if type(config[key]) ~= "boolean" then config[key] = defaults[key] end
end
if type(config.username) ~= "string" then config.username = "User" end
config.username = config.username:gsub("[%z\1-\31]", ""):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 24)
if config.username == "" then config.username = "User" end
local validScales = { [0.5] = true, [1] = true, [1.5] = true, [2] = true, [2.5] = true, [3] = true, [4] = true, [5] = true }
if type(config.monitorScale) ~= "number" or config.monitorScale ~= config.monitorScale or not validScales[config.monitorScale] then config.monitorScale = 0.5 end
if type(config.pinHash) ~= "string" or config.pinHash == "" then config.pinHash = nil else config.pinHash = config.pinHash:sub(1, 64) end
if type(config.peripheralAliases) ~= "table" then config.peripheralAliases = {} end
local cleanAliases = {}
for name, alias in pairs(config.peripheralAliases) do
    if type(name) == "string" and type(alias) == "string" then
        alias = alias:gsub("[%z\1-\31]", ""):sub(1, 32)
        if alias ~= "" then cleanAliases[name:sub(1, 128)] = alias end
    end
end
config.peripheralAliases = cleanAliases
if type(config.favorites) ~= "table" then config.favorites = deepCopy(defaults.favorites) end
local cleanFavorites, seenFavorites = {}, {}
for i = 1, math.min(#config.favorites, 32) do
    if type(config.favorites[i]) == "string" then
        local value = canonicalPath(config.favorites[i])
        if not seenFavorites[value] then seenFavorites[value] = true cleanFavorites[#cleanFavorites + 1] = value end
    end
end
if #cleanFavorites == 0 then cleanFavorites = deepCopy(defaults.favorites) end
config.favorites = cleanFavorites
if type(config.desktopPins) ~= "table" then config.desktopPins = deepCopy(defaults.desktopPins) end
local cleanPins, seenPins = {}, {}
for i = 1, math.min(#config.desktopPins, 48) do
    local id = type(config.desktopPins[i]) == "string" and config.desktopPins[i]:match("^[%w_%-]+$") or nil
    if id and not seenPins[id] then seenPins[id] = true cleanPins[#cleanPins + 1] = id end
end
if #cleanPins == 0 then cleanPins = deepCopy(defaults.desktopPins) end
config.desktopPins = cleanPins
if type(config.trustedPeers) ~= "table" then config.trustedPeers = {} end
local cleanTrusted = {}
for id, trusted in pairs(config.trustedPeers) do
    local number = tonumber(id)
    if trusted == true and number and number >= 0 and number == math.floor(number) then cleanTrusted[tostring(number)] = true end
end
config.trustedPeers = cleanTrusted
config.allowRemoteRedstone = config.allowRemoteRedstone == true
config.allowRemoteRun = config.allowRemoteRun == true

local function saveConfig()
    local ok, err = writeTable(CONFIG_FILE, config)
    if not ok then error("Unable to save McOS settings: " .. tostring(err), 0) end
end
saveConfig()

local notifications = readTable(NOTIFY_FILE, {})
local rsData = readTable(RS_FILE, { scenes = {}, rules = {}, timers = {} })
local trashData = readTable(TRASH_FILE, {})
local userTimers = readTable(TIMER_FILE, {})
local netInbox = readTable(NET_FILE, {})
if type(notifications) ~= "table" then notifications = {} end
if type(rsData) ~= "table" then rsData = { scenes = {}, rules = {}, timers = {} } end
if type(trashData) ~= "table" then trashData = {} end
if type(userTimers) ~= "table" then userTimers = {} end
if type(netInbox) ~= "table" then netInbox = {} end
if type(rsData.scenes) ~= "table" then rsData.scenes = {} end
if type(rsData.rules) ~= "table" then rsData.rules = {} end
if type(rsData.timers) ~= "table" then rsData.timers = {} end
for i = #notifications, 1, -1 do
    local item = notifications[i]
    if type(item) ~= "table" then table.remove(notifications, i)
    else
        item.title = tostring(item.title or "Notification"):gsub("[\r\n]", " "):sub(1, 80)
        item.body = tostring(item.body or ""):gsub("[\r\n]", " "):sub(1, 2048)
        item.time = tostring(item.time or ""):sub(1, 32)
        item.level = (item.level == "error" or item.level == "warn") and item.level or "info"
        item.read = item.read == true
    end
end
while #notifications > 60 do table.remove(notifications, 1) end
for i = #userTimers, 1, -1 do
    local item = userTimers[i]
    if type(item) ~= "table" or not tonumber(item.due) then table.remove(userTimers, i)
    else item.name = tostring(item.name or "Timer"):sub(1, 40) item.due = tonumber(item.due) end
end
while #userTimers > 100 do table.remove(userTimers, 1) end
for i = #netInbox, 1, -1 do
    local item = netInbox[i]
    if type(item) ~= "table" then table.remove(netInbox, i)
    else
        item.from = tonumber(item.from) or "?"
        item.body = tostring(item.body or ""):sub(1, 1024)
        item.time = tostring(item.time or ""):sub(1, 32)
    end
end
while #netInbox > 100 do table.remove(netInbox, 1) end
for i = #rsData.timers, 1, -1 do if type(rsData.timers[i]) ~= "table" then table.remove(rsData.timers, i) end end
for i = #rsData.rules, 1, -1 do if type(rsData.rules[i]) ~= "table" then table.remove(rsData.rules, i) end end
while #rsData.timers > 128 do table.remove(rsData.timers, 1) end
while #rsData.rules > 128 do table.remove(rsData.rules, 1) end
local cleanScenes, sceneCount = {}, 0
for name, scene in pairs(rsData.scenes) do
    if sceneCount < 64 and type(name) == "string" and type(scene) == "table" then
        local clean = {}
        for side, value in pairs(scene) do
            local validSide, validValue = normalSide(side), analogValue(value)
            if validSide and validValue ~= nil then clean[validSide] = validValue end
        end
        cleanScenes[safeName(name, "Scene")] = clean
        sceneCount = sceneCount + 1
    end
end
rsData.scenes = cleanScenes
for name, original in pairs(trashData) do
    local item = fs.combine(TRASH_DIR, tostring(name))
    if type(name) ~= "string" or type(original) ~= "string" or not fs.exists(item) then trashData[name] = nil end
end
writeTable(TRASH_FILE, trashData)

local function logEvent(kind, message)
    kind = tostring(kind or "INFO"):gsub("[\r\n]", " "):sub(1, 32)
    message = tostring(message or ""):gsub("[\r\n]", " "):sub(1, 2048)
    local line = string.format("[%s] [%s] %s\n", os.date("!%Y-%m-%d %H:%M:%S"), kind, message)
    local mode = fs.exists(LOG_FILE) and "a" or "w"
    local h = fs.open(LOG_FILE, mode)
    if h then pcall(h.write, line) pcall(h.close) end
    local ok, size = pcall(fs.getSize, LOG_FILE)
    if ok and type(size) == "number" and size > 131072 then
        local raw = readAll(LOG_FILE) or ""
        local cut = math.floor(#raw / 2)
        local nextLine = raw:find("\n", cut, true)
        writeAll(LOG_FILE, raw:sub(nextLine and nextLine + 1 or cut))
    end
end

local function peripheralTypes(name)
    local ok, result = pcall(function() return { peripheral.getType(name) } end)
    return ok and result or {}
end

local function peripheralMethods(name)
    local ok, result = pcall(peripheral.getMethods, name)
    return ok and type(result) == "table" and result or {}
end

local speakers = {}
local function refreshSpeakers()
    speakers = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return end
    for _, name in ipairs(names) do
        local typeOk, hasSpeaker = pcall(peripheral.hasType, name, "speaker")
        if typeOk and hasSpeaker then
            local wrapOk, object = pcall(peripheral.wrap, name)
            if wrapOk and object then speakers[#speakers + 1] = object end
        end
    end
end
refreshSpeakers()

local function sound(kind)
    if #speakers == 0 then return end
    local note = kind == "error" and 3 or kind == "warn" and 7 or 12
    pcall(speakers[1].playNote, "pling", 1, note)
end

local function notify(title, body, level)
    title = tostring(title or "Notification"):gsub("[\r\n]", " "):sub(1, 80)
    body = tostring(body or ""):gsub("[\r\n]", " "):sub(1, 2048)
    level = (level == "error" or level == "warn") and level or "info"
    notifications[#notifications + 1] = {
        title = title, body = body, level = level,
        time = os.date("!%Y-%m-%d %H:%M:%S"), read = false,
    }
    while #notifications > 60 do table.remove(notifications, 1) end
    writeTable(NOTIFY_FILE, notifications)
    sound(level)
end

local nativeTerminal = term.current()
local displayMode = "computer"
local activeMonitor = nil
local activeMonitorName = nil
local serviceTimer = nil
local netPeers = {}
local remoteQueue = {}
local pendingNet = {}
local currentApp = "desktop"
local lockRequested = false
local pullUiEvent
local uniquePath

local function T() return themes[config.theme] end
local function size() return term.getSize() end
local function setColours(fg, bg)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg) end
end
local function fill(x1, y1, x2, y2, bg)
    local w, h = size()
    x1, y1, x2, y2 = math.max(1, x1), math.max(1, y1), math.min(w, x2), math.min(h, y2)
    if x2 < x1 or y2 < y1 then return end
    term.setBackgroundColor(bg)
    local line = string.rep(" ", x2 - x1 + 1)
    for y = y1, y2 do term.setCursorPos(x1, y) term.write(line) end
end
local function clip(text, width)
    text = tostring(text or "")
    if width <= 0 then return "" end
    if #text <= width then return text end
    if width <= 3 then return text:sub(1, width) end
    return text:sub(1, width - 3) .. "..."
end
local function writeAt(x, y, text, fg, bg)
    local w, h = size()
    if y < 1 or y > h or x > w then return end
    text = tostring(text or "")
    if x < 1 then text = text:sub(2 - x) x = 1 end
    text = text:sub(1, math.max(0, w - x + 1))
    setColours(fg, bg)
    term.setCursorPos(x, y)
    term.write(text)
end
local function centerText(y, text, fg, bg)
    local w = select(1, size())
    text = clip(text, w)
    writeAt(math.max(1, math.floor((w - #text) / 2) + 1), y, text, fg, bg)
end
local function clearScreen(bg)
    term.setCursorBlink(false)
    term.setBackgroundColor(bg)
    term.clear()
    term.setCursorPos(1, 1)
end
local function wrapText(text, width)
    local out = {}
    for paragraph in (tostring(text or "") .. "\n"):gmatch("(.-)\n") do
        local line = ""
        if paragraph == "" then out[#out + 1] = "" end
        for word in paragraph:gmatch("%S+") do
            if line == "" then line = word
            elseif #line + #word + 1 <= width then line = line .. " " .. word
            else out[#out + 1] = line line = word end
        end
        if line ~= "" then out[#out + 1] = line end
    end
    return out
end
local function inBox(x, y, box)
    return box and x >= box.x1 and x <= box.x2 and y >= box.y1 and y <= box.y2
end
local function drawButton(x1, y1, x2, y2, label, active)
    local bg = active and T().accent or T().panel
    fill(x1, y1, x2, y2, bg)
    local y = math.floor((y1 + y2) / 2)
    local width = x2 - x1 + 1
    local text = clip(label, width - 2)
    writeAt(x1 + math.max(0, math.floor((width - #text) / 2)), y, text, T().text, bg)
    return { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
end

local function unreadCount()
    local count = 0
    for _, item in ipairs(notifications) do if not item.read then count = count + 1 end end
    return count
end

local function drawChrome(title, hint)
    local w, h = size()
    fill(1, 1, w, 2, T().panel)
    writeAt(2, 1, OS_NAME .. " 1.0", T().text, T().panel)
    centerText(1, title or "Desktop", T().text, T().panel)
    local mode = displayMode == "monitor" and "TOUCH" or "PC"
    writeAt(math.max(1, w - #mode - 1), 1, mode, colors.lightGray, T().panel)
    writeAt(2, 2, clip(config.username .. " @ " .. (os.getComputerLabel() or ("Computer " .. os.getComputerID())), w - 3), colors.lightGray, T().panel)
    fill(1, h, w, h, T().panel)
    writeAt(2, h, "[Start]", T().text, T().panel)
    local nc = "Alerts:" .. unreadCount()
    writeAt(math.max(10, w - #nc - 10), h, nc, T().text, T().panel)
    if config.showClock then
        local clock = textutils.formatTime(os.time(), true)
        writeAt(math.max(1, w - #clock - 1), h, clock, T().text, T().panel)
    end
    if hint and h > 4 then centerText(h - 1, clip(hint, w - 2), T().dark, T().desktop) end
end

local function showMessage(title, message)
    clearScreen(T().desktop)
    drawChrome(title)
    local w, h = size()
    local lines = type(message) == "table" and message or wrapText(message, w - 6)
    local y = 4
    for _, line in ipairs(lines) do
        if y >= h - 1 then break end
        centerText(y, clip(line, w - 4), T().dark, T().desktop)
        y = y + 1
    end
    centerText(h - 2, "Press any key or click", T().dark, T().desktop)
    while true do
        local e = { pullUiEvent() }
        if e[1] == "key" or e[1] == "mouse_click" then return
        elseif e[1] == "term_resize" then return showMessage(title, message) end
    end
end

local function findTouchMonitor()
    local namesOk, names = pcall(peripheral.getNames)
    if not namesOk or type(names) ~= "table" then return nil, nil end
    for _, name in ipairs(names) do
        local typeOk, isMonitor = pcall(peripheral.hasType, name, "monitor")
        if typeOk and isMonitor then
            local wrapOk, monitor = pcall(peripheral.wrap, name)
            if wrapOk and monitor then
                local ok, color = pcall(monitor.isColor)
                if ok and color then return monitor, name end
            end
        end
    end
    return nil, nil
end

local function activateMonitor(silent)
    local monitor, name = findTouchMonitor()
    if not monitor then
        if not silent then showMessage("Touch display", "No Advanced Monitor was found.") end
        return false
    end
    local okScale = pcall(monitor.setTextScale, config.monitorScale)
    if not okScale then
        config.monitorScale = 0.5
        saveConfig()
        pcall(monitor.setTextScale, config.monitorScale)
    end
    local okRedirect, previous = pcall(term.redirect, monitor)
    if not okRedirect then
        if not silent then showMessage("Touch display", "The monitor could not be activated: " .. tostring(previous)) end
        return false
    end
    activeMonitor, activeMonitorName = monitor, name
    displayMode = "monitor"
    local w, h = term.getSize()
    if w < 32 or h < 16 then
        term.redirect(nativeTerminal)
        displayMode = "computer"
        activeMonitor, activeMonitorName = nil, nil
        if not silent then showMessage("Touch display", "The monitor must provide at least 32 columns and 16 rows. Use a larger monitor or a smaller text scale.") end
        return false
    end
    clearScreen(T().desktop)
    return true
end

local function returnToComputer()
    pcall(term.redirect, nativeTerminal)
    displayMode = "computer"
    activeMonitor, activeMonitorName = nil, nil
    clearScreen(T().desktop)
end

local function onTouchDisplay() return displayMode == "monitor" end

local function hashPin(text)
    local hash = 5381
    for i = 1, #text do hash = (hash * 33 + text:byte(i)) % 2147483647 end
    return tostring(hash)
end

local function inputBox(title, prompt, secret)
    local restoreMonitor = onTouchDisplay()
    if restoreMonitor then returnToComputer() end
    local value = ""
    local maxLength = 1024
    while true do
        clearScreen(T().desktop)
        drawChrome(title)
        local w = select(1, size())
        writeAt(2, 4, clip(prompt, w - 3), T().dark, T().desktop)
        fill(2, 6, math.max(2, w - 1), 6, colors.white)
        local rendered = secret and string.rep("*", #value) or value
        rendered = rendered:sub(math.max(1, #rendered - math.max(1, w - 4) + 1))
        writeAt(2, 6, rendered, T().dark, colors.white)
        term.setCursorPos(math.min(w - 1, 2 + #rendered), 6)
        term.setCursorBlink(true)
        local e, a = pullUiEvent(nil, true)
        term.setCursorBlink(false)
        if e == "char" then
            if #value < maxLength then value = (value .. tostring(a)):sub(1, maxLength) end
        elseif e == "paste" then
            if #value < maxLength then value = (value .. tostring(a or "")):sub(1, maxLength) end
        elseif e == "key" then
            if a == keys.enter then if restoreMonitor then activateMonitor(true) end return value
            elseif a == keys.backspace then value = value:sub(1, math.max(0, #value - 1))
            elseif a == keys.escape then if restoreMonitor then activateMonitor(true) end return nil end
        elseif e == "terminate" then
            if restoreMonitor then activateMonitor(true) end
            return nil
        end
    end
end

local function confirm(title, question)
    clearScreen(T().desktop)
    drawChrome(title)
    local w, h = size()
    local lines = wrapText(question, w - 6)
    local y = 4
    for _, line in ipairs(lines) do centerText(y, line, T().dark, T().desktop) y = y + 1 end
    local yes = drawButton(math.max(2, math.floor(w / 2) - 12), h - 4, math.max(8, math.floor(w / 2) - 2), h - 2, "Yes", true)
    local no = drawButton(math.floor(w / 2) + 2, h - 4, math.min(w - 1, math.floor(w / 2) + 12), h - 2, "No", false)
    while true do
        local e = { pullUiEvent() }
        if e[1] == "key" then
            if e[2] == keys.y or e[2] == keys.enter then return true end
            if e[2] == keys.n or e[2] == keys.escape or e[2] == keys.backspace then return false end
        elseif e[1] == "mouse_click" then
            if inBox(e[3], e[4], yes) then return true end
            if inBox(e[3], e[4], no) then return false end
        elseif e[1] == "term_resize" then return confirm(title, question) end
    end
end

local function menuSelect(title, items, hint)
    if #items == 0 then showMessage(title, "Nothing to show.") return nil end
    local selected, offset = 1, 0
    while true do
        clearScreen(T().desktop)
        drawChrome(title, hint or "Arrows/scroll: select   Enter: choose   Esc: back")
        local w, h = size()
        local maxRows = math.max(1, h - 5)
        if selected <= offset then offset = selected - 1 end
        if selected > offset + maxRows then offset = selected - maxRows end
        local boxes = {}
        for row = 1, maxRows do
            local index = offset + row
            if index > #items then break end
            local item = items[index]
            local label = type(item) == "table" and (item.label or item.name or tostring(index)) or tostring(item)
            local bg = index == selected and T().accent or T().desktop
            fill(2, row + 2, w - 1, row + 2, bg)
            writeAt(3, row + 2, clip(label, w - 5), index == selected and T().text or T().dark, bg)
            boxes[#boxes + 1] = { index = index, x1 = 2, y1 = row + 2, x2 = w - 1, y2 = row + 2 }
        end
        local e = { pullUiEvent() }
        if e[1] == "key" then
            if e[2] == keys.up then selected = math.max(1, selected - 1)
            elseif e[2] == keys.down then selected = math.min(#items, selected + 1)
            elseif e[2] == keys.pageUp then selected = math.max(1, selected - maxRows)
            elseif e[2] == keys.pageDown then selected = math.min(#items, selected + maxRows)
            elseif e[2] == keys.enter or e[2] == keys.space then return selected
            elseif e[2] == keys.escape or e[2] == keys.backspace then return nil end
        elseif e[1] == "mouse_scroll" then
            selected = math.max(1, math.min(#items, selected + e[2]))
        elseif e[1] == "mouse_click" or (e[1] == "monitor_touch" and e[2] == activeMonitorName) then
            local x, y = e[1] == "mouse_click" and e[3] or e[3], e[1] == "mouse_click" and e[4] or e[4]
            for _, box in ipairs(boxes) do
                if inBox(x, y, box) then
                    if selected == box.index then return selected end
                    selected = box.index
                end
            end
        end
    end
end

local function openRednet()
    local opened = false
    local namesOk, names = pcall(peripheral.getNames)
    if namesOk and type(names) == "table" then
        for _, name in ipairs(names) do
            local typeOk, isModem = pcall(peripheral.hasType, name, "modem")
            if typeOk and isModem then
                local ok = pcall(rednet.open, name)
                opened = opened or ok
            end
        end
    end
    local stateOk, state = pcall(rednet.isOpen)
    return (stateOk and state) or opened
end
openRednet()

local function sendNet(id, payload)
    local stateOk, isOpen = pcall(rednet.isOpen)
    if not (stateOk and isOpen) and not openRednet() then return false, "No modem is available" end
    local ok, result = pcall(rednet.send, id, payload, NET_PROTOCOL)
    if not ok then return false, tostring(result) end
    if result == false then return false, "Message could not be sent" end
    return true
end

local function broadcastNet(payload)
    local stateOk, isOpen = pcall(rednet.isOpen)
    if not (stateOk and isOpen) and not openRednet() then return false, "No modem is available" end
    local ok, result = pcall(rednet.broadcast, payload, NET_PROTOCOL)
    if not ok then return false, tostring(result) end
    if result == false then return false, "Broadcast could not be sent" end
    return true
end

local requestCounter = 0
local function requestId(prefix)
    requestCounter = (requestCounter + 1) % 100000
    return string.format("%s-%d-%d-%d", prefix or "req", os.getComputerID(), nowMs(), requestCounter)
end

local function isTrustedPeer(id)
    return config.trustedPeers[tostring(id)] == true
end

local function saveNetInbox()
    while #netInbox > 100 do table.remove(netInbox, 1) end
    return writeTable(NET_FILE, netInbox)
end

local function networkAck(sender, message, ok, detail)
    sendNet(sender, {
        type = "ACK", request = message.request, action = message.type,
        ok = ok == true, detail = tostring(detail or ""),
    })
end

local function handleNetwork(sender, message, protocol)
    if protocol ~= NET_PROTOCOL or type(sender) ~= "number" or type(message) ~= "table" then return false end
    local kind = type(message.type) == "string" and message.type or ""
    if kind == "DISCOVER" then
        sendNet(sender, { type = "HERE", version = OS_VERSION, label = os.getComputerLabel() or ("Computer " .. os.getComputerID()), user = config.username })
    elseif kind == "HERE" then
        netPeers[sender] = {
            id = sender,
            label = clip(tostring(message.label or ("Computer " .. sender)), 40),
            version = clip(tostring(message.version or "?"), 16),
            user = clip(tostring(message.user or "User"), 24),
            seen = nowMs(),
            trusted = isTrustedPeer(sender),
        }
    elseif kind == "PING" then
        sendNet(sender, { type = "PONG", sent = tonumber(message.sent), request = message.request })
    elseif kind == "PONG" then
        netPeers[sender] = netPeers[sender] or { id = sender, label = "Computer " .. sender }
        netPeers[sender].latency = math.max(0, nowMs() - (tonumber(message.sent) or nowMs()))
        netPeers[sender].seen = nowMs()
        if message.request then pendingNet[tostring(message.request)] = { done = true, ok = true, detail = netPeers[sender].latency } end
    elseif kind == "ACK" then
        if message.request then
            local id = tostring(message.request)
            if pendingNet[id] then
                pendingNet[id] = { done = true, ok = message.ok == true, detail = tostring(message.detail or ""), action = message.action }
            elseif message.action == "REMOTE_RUN_RESULT" then
                notify(message.ok and "Remote program completed" or "Remote program failed", tostring(message.detail or ""), message.ok and "info" or "error")
            end
        end
    elseif kind == "MESSAGE" then
        local body = tostring(message.body or ""):sub(1, 1024)
        if body == "" then
            networkAck(sender, message, false, "Message was empty")
        else
            netInbox[#netInbox + 1] = { from = sender, body = body, time = os.date("!%Y-%m-%d %H:%M:%S") }
            local saved, saveErr = saveNetInbox()
            if not saved then table.remove(netInbox, #netInbox) end
            networkAck(sender, message, saved, saved and "Delivered" or saveErr)
            if saved then notify("McNet message", "From #" .. sender .. ": " .. body, "info") end
        end
    elseif kind == "FILE" then
        if type(message.data) ~= "string" then networkAck(sender, message, false, "Invalid file payload")
        elseif #message.data > 131072 then networkAck(sender, message, false, "File exceeds 128 KB")
        else
            local freeOk, free = pcall(fs.getFreeSpace, INBOX_DIR)
            if freeOk and type(free) == "number" and free < #message.data then
                networkAck(sender, message, false, "Not enough free space")
            else
            local filename = safeName(message.name, "file_from_" .. sender)
            local target = uniquePath and uniquePath(fs.combine(INBOX_DIR, filename)) or fs.combine(INBOX_DIR, filename)
            local ok, err = writeAll(target, message.data, "wb")
            networkAck(sender, message, ok, ok and fs.getName(target) or err)
            if ok then
                notify("McNet file received", fs.getName(target) .. " from #" .. sender, "info")
                logEvent("NET", "Received " .. fs.getName(target) .. " from #" .. sender)
            end
            end
        end
    elseif kind == "REMOTE_RS" then
        local side, value = normalSide(message.side), analogValue(message.value)
        if not config.allowRemoteRedstone then networkAck(sender, message, false, "Remote redstone is disabled")
        elseif not isTrustedPeer(sender) then networkAck(sender, message, false, "Sender is not trusted")
        elseif not side or value == nil then networkAck(sender, message, false, "Invalid side or value")
        else
            local ok, err = pcall(redstone.setAnalogOutput, side, value)
            networkAck(sender, message, ok, ok and (side .. "=" .. value) or err)
            if ok then
                notify("Remote redstone", "#" .. sender .. " set " .. side .. " to " .. value, "warn")
                logEvent("REMOTE", "#" .. sender .. " set " .. side .. " to " .. value)
            end
        end
    elseif kind == "REMOTE_RUN" then
        local path = type(message.path) == "string" and canonicalPath(message.path) or nil
        if not config.allowRemoteRun then networkAck(sender, message, false, "Remote launch is disabled")
        elseif not isTrustedPeer(sender) then networkAck(sender, message, false, "Sender is not trusted")
        elseif not path or not fs.exists(path) or fs.isDir(path) then networkAck(sender, message, false, "Program does not exist")
        elseif #remoteQueue >= 8 then networkAck(sender, message, false, "Remote queue is full")
        else
            local args = {}
            if type(message.args) == "table" then
                for i = 1, math.min(8, #message.args) do args[i] = tostring(message.args[i]):sub(1, 128) end
            end
            remoteQueue[#remoteQueue + 1] = { sender = sender, path = path, args = args, request = message.request }
            networkAck(sender, message, true, "Queued")
        end
    end
    return true
end

local function processServices()
    local now = nowMs()
    local changed = false
    for i = #rsData.timers, 1, -1 do
        local timer = rsData.timers[i]
        local side, value, due = normalSide(timer.side), analogValue(timer.value), tonumber(timer.due)
        if not side or value == nil or not due then
            table.remove(rsData.timers, i)
            changed = true
        elseif due <= now then
            local ok = pcall(redstone.setAnalogOutput, side, value)
            if ok then notify("Redstone timer", side .. " set to " .. value, "info") end
            table.remove(rsData.timers, i)
            changed = true
        end
    end
    for i = #rsData.rules, 1, -1 do
        local rule = rsData.rules[i]
        local inputSide, outputSide = normalSide(rule.inputSide), normalSide(rule.outputSide)
        local threshold, yesValue, noValue = analogValue(rule.threshold), analogValue(rule.value), analogValue(rule.elseValue, 0)
        if not inputSide or not outputSide or threshold == nil or yesValue == nil then
            table.remove(rsData.rules, i)
            changed = true
        else
            local ok, input = pcall(redstone.getAnalogInput, inputSide)
            if ok then pcall(redstone.setAnalogOutput, outputSide, input >= threshold and yesValue or noValue) end
        end
    end
    if changed then writeTable(RS_FILE, rsData) end

    local timersChanged = false
    for i = #userTimers, 1, -1 do
        local due = tonumber(userTimers[i].due)
        if not due then
            table.remove(userTimers, i)
            timersChanged = true
        elseif due <= now then
            notify("Timer finished", tostring(userTimers[i].name or "Timer"), "info")
            table.remove(userTimers, i)
            timersChanged = true
        end
    end
    if timersChanged then writeTable(TIMER_FILE, userTimers) end
    for id, peer in pairs(netPeers) do if now - (peer.seen or 0) > 120000 then netPeers[id] = nil end end
end

pullUiEvent = function(filter, raw)
    while true do
        local e = { os.pullEventRaw() }
        if e[1] == "timer" and e[2] == serviceTimer then
            processServices()
            serviceTimer = os.startTimer(0.5)
            if filter == "mcos_service" or (filter == nil and currentApp == "desktop") then return "mcos_service" end
        elseif e[1] == "rednet_message" and handleNetwork(e[2], e[3], e[4]) then
            if filter == "mcos_network" or (filter == nil and currentApp == "desktop") then
                return "mcos_network", e[2], e[3], e[4]
            end
        elseif e[1] == "peripheral" or e[1] == "peripheral_detach" then
            refreshSpeakers()
            openRednet()
            if e[1] == "peripheral_detach" and displayMode == "monitor" and e[2] == activeMonitorName then
                returnToComputer()
                e = { "term_resize" }
            end
            if filter == nil or e[1] == filter then return unpack(e) end
        else
            if e[1] == "terminate" and not raw then e = { "key", keys.escape } end
            if displayMode == "monitor" and e[1] == "monitor_touch" and e[2] == activeMonitorName then
                e = { "mouse_click", 1, e[3], e[4] }
            elseif displayMode == "monitor" and e[1] == "monitor_resize" and e[2] == activeMonitorName then
                e = { "term_resize" }
            end
            if filter == nil or e[1] == filter then return unpack(e) end
        end
    end
end

serviceTimer = os.startTimer(0.5)

local function cooperativeDelay(seconds)
    local timer = os.startTimer(math.max(0, tonumber(seconds) or 0))
    while true do
        local e, id = pullUiEvent(nil, true)
        if e == "timer" and id == timer then return true end
        if e == "terminate" then return false end
    end
end

local function runOnComputer(program, ...)
    local args = { ... }
    local restore = onTouchDisplay()
    if restore then returnToComputer() end

    -- Advanced Computers normally run inside multishell. Launching CraftOS tools
    -- in their own tab keeps McNet and automation services alive while the user
    -- edits a file, uses the shell, Paint, or another long-running program.
    if multishell and type(shell.openTab) == "function" then
        local tabOk, tabId = pcall(shell.openTab, program, unpack(args))
        if tabOk and type(tabId) == "number" then
            pcall(multishell.setFocus, tabId)
            if restore then activateMonitor(true) end
            logEvent("APP", "Opened CraftOS tab: " .. tostring(program))
            return true, tabId
        end
        logEvent("APP_ERROR", "Unable to open tab for " .. tostring(program) .. ": " .. tostring(tabId))
    end

    clearScreen(colors.black)
    term.setTextColor(colors.white)
    local callOk, result = pcall(function() return shell.run(program, unpack(args)) end)
    local success = callOk and result ~= false
    if not success then
        local message = callOk and ("Program returned failure: " .. tostring(program)) or tostring(result)
        printError(message)
        logEvent("APP_ERROR", message)
    end
    print("\nPress any key to return to McOS...")
    while true do
        local e = { pullUiEvent(nil, true) }
        if e[1] == "key" or e[1] == "mouse_click" or e[1] == "terminate" then break end
    end
    if restore then activateMonitor(true) end
    processServices()
    return success, result
end

local function executeRemoteJob()
    if #remoteQueue == 0 or currentApp ~= "desktop" then return end
    local job = table.remove(remoteQueue, 1)
    logEvent("REMOTE", "Run request from #" .. job.sender .. ": " .. job.path)
    local ok, result
    if shell.openTab and multishell then
        ok, result = pcall(shell.openTab, job.path, unpack(job.args))
    else
        ok, result = pcall(function() return shell.run(job.path, unpack(job.args)) end)
    end
    local success = ok and result ~= false
    sendNet(job.sender, {
        type = "ACK", request = job.request, action = "REMOTE_RUN_RESULT",
        ok = success, detail = success and tostring(result or "Started") or tostring(result),
    })
    if success then notify("Remote program", job.path .. " started for #" .. job.sender, "info")
    else notify("Remote program failed", tostring(result), "error") end
end

local function viewFile(path)
    path = canonicalPath(path)
    if not fs.exists(path) or fs.isDir(path) then showMessage("File", "The file does not exist.") return end
    local raw, err = readAll(path)
    if raw == nil then showMessage("File", err or "Unable to read this file.") return end
    if #raw > 524288 then showMessage("File", "This viewer is limited to 512 KB. Use the editor or shell tools instead.") return end
    local lines = {}
    for line in (raw .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line:gsub("[%z\1-\8\11\12\14-\31]", ".") end
    local offset = 0
    while true do
        clearScreen(T().desktop)
        drawChrome(fs.getName(path), "Arrows/scroll: move   E: edit   Esc: back")
        local w, h = size()
        local rows = math.max(1, h - 6)
        for row = 1, rows do
            local line = lines[offset + row]
            if not line then break end
            writeAt(2, row + 2, clip(line, w - 3), T().dark, T().desktop)
        end
        local editButton = drawButton(2, h - 2, math.max(8, math.floor(w / 2) - 1), h - 2, "Edit", false)
        local backButton = drawButton(math.floor(w / 2) + 1, h - 2, w - 1, h - 2, "Back", true)
        local e, a, b, c = pullUiEvent()
        if e == "key" then
            if a == keys.up then offset = math.max(0, offset - 1)
            elseif a == keys.down then offset = math.min(math.max(0, #lines - rows), offset + 1)
            elseif a == keys.pageUp then offset = math.max(0, offset - rows)
            elseif a == keys.pageDown then offset = math.min(math.max(0, #lines - rows), offset + rows)
            elseif a == keys.e then
                if isProtectedWriteTarget(path) then showMessage("Protected file", "McOS protects this file from editing.")
                else runOnComputer("edit", path) end
                raw = readAll(path) or raw
                lines = {}
                for line in (raw .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line:gsub("[%z\1-\8\11\12\14-\31]", ".") end
                offset = 0
            elseif a == keys.escape or a == keys.backspace then return end
        elseif e == "mouse_scroll" then
            offset = math.max(0, math.min(math.max(0, #lines - rows), offset + a))
        elseif e == "mouse_click" then
            if inBox(b, c, editButton) then os.queueEvent("key", keys.e)
            elseif inBox(b, c, backButton) then return
            elseif c < h - 2 then offset = math.min(math.max(0, #lines - rows), offset + rows) end
        end
    end
end

uniquePath = function(base)
    base = canonicalPath(base)
    if not fs.exists(base) then return base end
    local dir, name = fs.getDir(base), fs.getName(base)
    local stem, ext = name:match("^(.*)(%.[^%.]+)$")
    stem, ext = stem or name, ext or ""
    local n = 1
    local candidate
    repeat
        candidate = fs.combine(dir, stem .. "_" .. n .. ext)
        n = n + 1
    until not fs.exists(candidate)
    return canonicalPath(candidate)
end

local function moveToTrash(path)
    path = canonicalPath(path)
    if not fs.exists(path) then return false, "Path no longer exists" end
    if isProtectedPath(path) then return false, "McOS protects this path" end
    if fs.isReadOnly(path) then return false, "Path is read-only" end
    if isInside(path, TRASH_DIR) then return false, "Item is already in the Recycle Bin" end
    local targetName = timestamp() .. "_" .. safeName(fs.getName(path), "item")
    local target = uniquePath(fs.combine(TRASH_DIR, targetName))
    local targetKey = fs.getName(target)
    trashData[targetKey] = path
    local saved, saveErr = writeTable(TRASH_FILE, trashData)
    if not saved then trashData[targetKey] = nil return false, "Unable to update the Recycle Bin index: " .. tostring(saveErr) end
    local ok, err = pcall(fs.move, path, target)
    if not ok then
        trashData[targetKey] = nil
        writeTable(TRASH_FILE, trashData)
        return false, tostring(err)
    end
    logEvent("FILES", "Moved to trash: " .. path)
    return true, target
end

local function restoreTrash(path)
    path = canonicalPath(path)
    if canonicalPath(fs.getDir(path)) ~= TRASH_DIR or not fs.exists(path) then return false, "Select a top-level Recycle Bin item" end
    local name = fs.getName(path)
    local original = trashData[name]
    if type(original) ~= "string" then return false, "Original path is unknown" end
    local target = uniquePath(canonicalPath(original))
    local parent = fs.getDir(target)
    if parent ~= "" and not ensureDir(parent) then return false, "Unable to create destination folder" end
    local ok, err = pcall(fs.move, path, target)
    if not ok then return false, tostring(err) end
    trashData[name] = nil
    local saved, saveErr = writeTable(TRASH_FILE, trashData)
    if not saved then
        trashData[name] = original
        local rolledBack, rollbackErr = pcall(fs.move, target, path)
        if rolledBack then return false, "Unable to update the Recycle Bin index: " .. tostring(saveErr) end
        return false, "The file was restored to " .. target .. ", but the index update and rollback failed: " .. tostring(rollbackErr)
    end
    logEvent("FILES", "Restored " .. path .. " to " .. target)
    return true, target
end

local function permanentlyDelete(path)
    path = canonicalPath(path)
    if not isInside(path, TRASH_DIR) or path == TRASH_DIR then return false, "Only Recycle Bin items can be permanently deleted here" end
    if not fs.exists(path) then return false, "Item no longer exists" end
    local name = fs.getName(path)
    local ok, err = pcall(fs.delete, path)
    if not ok then return false, tostring(err) end
    if canonicalPath(fs.getDir(path)) == TRASH_DIR then trashData[name] = nil end
    writeTable(TRASH_FILE, trashData)
    logEvent("FILES", "Permanently deleted " .. path)
    return true
end

local function collectEntries(path, query, sortMode)
    path = canonicalPath(path)
    local entries = {}
    local function add(full)
        local okDir, isDir = pcall(fs.isDir, full)
        if not okDir then return end
        local sizeValue = 0
        if not isDir then
            local okSize, value = pcall(fs.getSize, full)
            sizeValue = okSize and value or 0
        end
        entries[#entries + 1] = { name = fs.getName(full), path = canonicalPath(full), dir = isDir, size = sizeValue }
    end
    if query and query ~= "" then
        local needle = query:lower()
        local function walk(dir, depth)
            if #entries >= 200 or depth > 32 then return end
            local ok, list = pcall(fs.list, dir)
            if not ok then return end
            table.sort(list)
            for _, name in ipairs(list) do
                if #entries >= 200 then break end
                local full = fs.combine(dir, name)
                if name:lower():find(needle, 1, true) then add(full) end
                local dirOk, isDir = pcall(fs.isDir, full)
                if dirOk and isDir and not isInside(full, TRASH_DIR) then walk(full, depth + 1) end
            end
        end
        walk(path, 0)
    else
        local ok, list = pcall(fs.list, path)
        if ok then for _, name in ipairs(list) do add(fs.combine(path, name)) end end
    end
    table.sort(entries, function(a, b)
        if a.dir ~= b.dir then return a.dir end
        if sortMode == "size" and a.size ~= b.size then return a.size < b.size end
        if sortMode == "type" then
            local ea, eb = a.name:match("%.([^%.]+)$") or "", b.name:match("%.([^%.]+)$") or ""
            if ea ~= eb then return ea:lower() < eb:lower() end
        end
        return a.name:lower() < b.name:lower()
    end)
    return entries
end

local function copyOrMove(source, destinationDir, cut)
    source, destinationDir = canonicalPath(source), canonicalPath(destinationDir)
    if not fs.exists(source) then return false, "Clipboard source no longer exists" end
    if not fs.isDir(destinationDir) then return false, "Destination is not a folder" end
    if isProtectedContainer(destinationDir) then return false, "McOS protects this destination" end
    if isProtectedPath(source) and cut then return false, "McOS protects this path from moving" end
    if fs.isReadOnly(destinationDir) then return false, "Destination is read-only" end
    if fs.isDir(source) and isInside(destinationDir, source) then return false, "A folder cannot be copied into itself" end
    local target = uniquePath(fs.combine(destinationDir, fs.getName(source)))
    local ok, err = pcall(cut and fs.move or fs.copy, source, target)
    if not ok then return false, tostring(err) end
    logEvent("FILES", (cut and "Moved " or "Copied ") .. source .. " to " .. target)
    return true, target
end

local function fileManager(startPath)
    local path = startPath and fs.exists(startPath) and canonicalPath(startPath) or "/"
    if not fs.isDir(path) then path = canonicalPath(fs.getDir(path)) end
    local selected, offset, sortMode, query = 1, 0, "name", ""
    local clipboard = nil
    local history, historyIndex = { path }, 1
    local function navigate(newPath, noHistory)
        newPath = canonicalPath(newPath)
        if not fs.exists(newPath) or not fs.isDir(newPath) then showMessage("Files", "Folder not found: " .. newPath) return end
        path, selected, offset, query = newPath, 1, 0, ""
        if not noHistory then
            while #history > historyIndex do table.remove(history) end
            if history[#history] ~= newPath then history[#history + 1] = newPath end
            historyIndex = #history
        end
    end
    while true do
        if not fs.exists(path) or not fs.isDir(path) then
            path, selected, offset, query = "/", 1, 0, ""
            history, historyIndex = { "/" }, 1
            notify("Files", "The previous folder was disconnected or removed. Returned to /.", "warn")
        end
        local entries = collectEntries(path, query, sortMode)
        if #entries == 0 then selected = 1 else selected = math.max(1, math.min(selected, #entries)) end
        clearScreen(T().desktop)
        drawChrome("Files", "Enter open | B back | C copy | X cut | P paste | R rename | Del trash/delete | / search | S sort")
        local w, h = size()
        writeAt(2, 3, clip((query ~= "" and ("Search in " .. path .. ": " .. query) or path), w - 3), T().dark, T().desktop)
        local freeOk, free = pcall(fs.getFreeSpace, path)
        writeAt(2, 4, "Free: " .. formatBytes(freeOk and free or "unknown") .. "   Sort: " .. sortMode .. (clipboard and ("   Clipboard: " .. fs.getName(clipboard.path)) or ""), T().dark, T().desktop)
        local maxRows = math.max(1, h - 7)
        if selected <= offset then offset = selected - 1 end
        if selected > offset + maxRows then offset = selected - maxRows end
        local boxes = {}
        for row = 1, maxRows do
            local index = offset + row
            local item = entries[index]
            if not item then break end
            local bg = index == selected and T().accent or T().desktop
            fill(2, row + 4, w - 1, row + 4, bg)
            local icon = item.dir and "[DIR] " or "      "
            local suffix = item.dir and "" or ("  " .. formatBytes(item.size))
            writeAt(3, row + 4, clip(icon .. item.name .. suffix, w - 5), index == selected and T().text or T().dark, bg)
            boxes[#boxes + 1] = { index = index, x1 = 2, y1 = row + 4, x2 = w - 1, y2 = row + 4 }
        end
        if #entries == 0 then centerText(7, query ~= "" and "No matching files" or "This folder is empty", T().dark, T().desktop) end
        local buttonWidth = math.max(6, math.floor((w - 2) / 5))
        local toolbar = {
            drawButton(2, h - 2, math.min(w - 1, 1 + buttonWidth), h - 2, "Open", true),
            drawButton(2 + buttonWidth, h - 2, math.min(w - 1, 1 + buttonWidth * 2), h - 2, "Back", false),
            drawButton(2 + buttonWidth * 2, h - 2, math.min(w - 1, 1 + buttonWidth * 3), h - 2, "Copy", false),
            drawButton(2 + buttonWidth * 3, h - 2, math.min(w - 1, 1 + buttonWidth * 4), h - 2, "Paste", false),
            drawButton(2 + buttonWidth * 4, h - 2, w - 1, h - 2, "More", false),
        }
        local e, a, b, c = pullUiEvent()
        local function current() return entries[selected] end
        local function openCurrent()
            local item = current() if not item then return end
            if item.dir then navigate(item.path)
            elseif item.name:lower():match("%.lua$") then
                if isProtectedWriteTarget(item.path) then viewFile(item.path)
                else
                    local choice = menuSelect("Lua file", { "Run", "View", "Edit", "Cancel" })
                    if choice == 1 then runOnComputer(item.path)
                    elseif choice == 2 then viewFile(item.path)
                    elseif choice == 3 then runOnComputer("edit", item.path) end
                end
            else viewFile(item.path) end
        end
        local function newFile()
            if isProtectedContainer(path) then showMessage("New file", "McOS protects this folder.") return end
            local name = inputBox("New file", "File name:")
            if name and name ~= "" then
                local target = canonicalPath(fs.combine(path, safeName(name, "new_file")))
                if fs.exists(target) then showMessage("New file", "A file with that name already exists.")
                else local ok, err = writeAll(target, "") if not ok then showMessage("New file failed", err) end end
            end
        end
        local function newFolder()
            if isProtectedContainer(path) then showMessage("New folder", "McOS protects this folder.") return end
            local name = inputBox("New folder", "Folder name:")
            if name and name ~= "" then
                local target = canonicalPath(fs.combine(path, safeName(name, "New folder")))
                if fs.exists(target) then showMessage("New folder", "An item with that name already exists.")
                elseif not ensureDir(target) then showMessage("New folder failed", "Unable to create the folder.") end
            end
        end
        local function pasteClipboard()
            if not clipboard then showMessage("Clipboard", "Nothing has been copied or cut.") return end
            local ok, result = copyOrMove(clipboard.path, path, clipboard.cut)
            if not ok then showMessage("Paste failed", result)
            else if clipboard.cut then clipboard = nil end notify("Files", "Pasted to " .. result, "info") end
        end
        local function renameCurrent()
            local item = current() if not item then return end
            if isProtectedPath(item.path) then showMessage("Rename", "McOS protects this path.") return end
            local name = inputBox("Rename", "New name for " .. item.name .. ":")
            if name and name ~= "" then
                local target = canonicalPath(fs.combine(fs.getDir(item.path), safeName(name, item.name)))
                if target == item.path then return end
                if fs.exists(target) then showMessage("Rename failed", "An item with that name already exists.")
                else local ok, err = pcall(fs.move, item.path, target) if not ok then showMessage("Rename failed", tostring(err)) end end
            end
        end
        local function deleteCurrent()
            local item = current() if not item then return end
            if isInside(path, TRASH_DIR) then
                if confirm("Permanent delete", "Permanently delete " .. item.name .. "? This cannot be undone.") then
                    local ok, err = permanentlyDelete(item.path) if not ok then showMessage("Delete failed", err) end
                end
            elseif confirm("Recycle Bin", "Move " .. item.name .. " to the Recycle Bin?") then
                local ok, err = moveToTrash(item.path) if not ok then showMessage("Delete failed", err) end
            end
        end
        if e == "key" then
            if a == keys.up then selected = math.max(1, selected - 1)
            elseif a == keys.down then selected = #entries > 0 and math.min(#entries, selected + 1) or 1
            elseif a == keys.pageUp then selected = math.max(1, selected - maxRows)
            elseif a == keys.pageDown then selected = #entries > 0 and math.min(#entries, selected + maxRows) or 1
            elseif a == keys.enter then openCurrent()
            elseif a == keys.b or a == keys.backspace then if path ~= "/" then navigate(fs.getDir(path)) else return end
            elseif a == keys.left then if historyIndex > 1 then historyIndex = historyIndex - 1 navigate(history[historyIndex], true) end
            elseif a == keys.right then if historyIndex < #history then historyIndex = historyIndex + 1 navigate(history[historyIndex], true) end
            elseif a == keys.h then navigate("/")
            elseif a == keys.n then newFile()
            elseif a == keys.d then newFolder()
            elseif a == keys.c or a == keys.x then
                local item = current()
                if item then
                    if a == keys.x and isProtectedPath(item.path) then showMessage("Cut", "McOS protects this path from moving.")
                    else clipboard = { path = item.path, cut = a == keys.x } notify("Clipboard", (clipboard.cut and "Cut " or "Copied ") .. item.name, "info") end
                end
            elseif a == keys.p then pasteClipboard()
            elseif a == keys.r then renameCurrent()
            elseif a == keys.delete then deleteCurrent()
            elseif a == keys.slash then query = inputBox("Search", "Name contains (searches this folder):") or "" selected, offset = 1, 0
            elseif a == keys.s then sortMode = sortMode == "name" and "size" or sortMode == "size" and "type" or "name"
            elseif a == keys.f then
                local item = current()
                local favorite = item and item.dir and item.path or path
                local found = nil for i, v in ipairs(config.favorites) do if canonicalPath(v) == favorite then found = i break end end
                if found then table.remove(config.favorites, found) else config.favorites[#config.favorites + 1] = favorite end
                saveConfig()
            elseif a == keys.j then
                local valid, labels = {}, {}
                for _, v in ipairs(config.favorites) do if fs.exists(v) and fs.isDir(v) then valid[#valid + 1] = canonicalPath(v) labels[#labels + 1] = canonicalPath(v) end end
                labels[#labels + 1] = "Recycle Bin"
                local choice = menuSelect("Favorites", labels)
                if choice then if choice == #labels then navigate(TRASH_DIR) else navigate(valid[choice]) end end
            elseif a == keys.o and path == TRASH_DIR then
                local item = current() if item then local ok, result = restoreTrash(item.path) showMessage(ok and "Restored" or "Restore failed", tostring(result)) end
            elseif a == keys.escape then return end
        elseif e == "mouse_scroll" then
            if #entries > 0 then selected = math.max(1, math.min(#entries, selected + a)) end
        elseif e == "mouse_click" then
            local x, y = b, c
            if inBox(x, y, toolbar[1]) then openCurrent()
            elseif inBox(x, y, toolbar[2]) then if path ~= "/" then navigate(fs.getDir(path)) else return end
            elseif inBox(x, y, toolbar[3]) then local item = current() if item then clipboard = { path = item.path, cut = false } notify("Clipboard", "Copied " .. item.name, "info") end
            elseif inBox(x, y, toolbar[4]) then pasteClipboard()
            elseif inBox(x, y, toolbar[5]) then
                local labels = { "New file", "New folder", "Cut", "Rename", isInside(path, TRASH_DIR) and "Permanently delete" or "Move to Recycle Bin", "Search", "Change sort", "Favorites" }
                if path == TRASH_DIR then labels[#labels + 1] = "Restore selected" end
                local action = menuSelect("File actions", labels)
                local keyMap = { keys.n, keys.d, keys.x, keys.r, keys.delete, keys.slash, keys.s, keys.j, keys.o }
                if action then os.queueEvent("key", keyMap[action]) end
            else
                for _, box in ipairs(boxes) do
                    if inBox(x, y, box) then if selected == box.index then openCurrent() else selected = box.index end break end
                end
                if y == h and x <= 8 then return end
            end
        elseif e == "term_resize" then offset = 0 end
    end
end

local function terminalApp() runOnComputer("shell") end

local function programLauncher()
    local programs = shell.programs(true)
    table.sort(programs)
    local index = menuSelect("Programs", programs, "Enter: run   Esc: back")
    if index then runOnComputer(programs[index]) end
end

local sides = { "top", "bottom", "left", "right", "front", "back" }

local function chooseSide(title, prompt)
    local choice = menuSelect(title, sides, prompt or "Choose a computer side")
    return choice and sides[choice] or nil
end

local function redstoneScenes()
    while true do
        local names = {}
        for name, scene in pairs(rsData.scenes) do if type(scene) == "table" then names[#names + 1] = name end end
        table.sort(names)
        local items = {}
        for _, name in ipairs(names) do items[#items + 1] = name end
        items[#items + 1] = "<Save current outputs>"
        local choice = menuSelect("Redstone scenes", items)
        if not choice then return end
        if choice == #items then
            local name = inputBox("Save scene", "Scene name:")
            if name and name ~= "" then
                name = safeName(name, "Scene")
                if rsData.scenes[name] and not confirm("Replace scene", name .. " already exists. Replace it?") then
                    -- cancelled
                else
                    local scene = {}
                    for _, side in ipairs(sides) do
                        local ok, value = pcall(redstone.getAnalogOutput, side)
                        scene[side] = ok and analogValue(value, 0) or 0
                    end
                    rsData.scenes[name] = scene
                    writeTable(RS_FILE, rsData)
                end
            end
        else
            local name = names[choice]
            local action = menuSelect(name, { "Apply scene", "Delete scene", "Cancel" })
            if action == 1 then
                local scene = rsData.scenes[name]
                for rawSide, rawValue in pairs(scene) do
                    local side, value = normalSide(rawSide), analogValue(rawValue)
                    if side and value ~= nil then pcall(redstone.setAnalogOutput, side, value) end
                end
                notify("Redstone scene", name .. " applied", "info")
            elseif action == 2 and confirm("Delete scene", "Delete " .. name .. "?") then
                rsData.scenes[name] = nil
                writeTable(RS_FILE, rsData)
            end
        end
    end
end

local function redstoneRules()
    while true do
        local items = {}
        for i, rule in ipairs(rsData.rules) do
            items[#items + 1] = string.format("%d. %s >= %d -> %s=%d else %d", i,
                tostring(rule.inputSide), analogValue(rule.threshold, 0), tostring(rule.outputSide),
                analogValue(rule.value, 0), analogValue(rule.elseValue, 0))
        end
        items[#items + 1] = "<Add rule>"
        local choice = menuSelect("Automation rules", items, "Select a rule to delete, or add a new one")
        if not choice then return end
        if choice == #items then
            local inSide = chooseSide("New rule", "Input side")
            if not inSide then return end
            local threshold = analogValue(inputBox("Rule", "Trigger level 0-15:"))
            local outSide = chooseSide("New rule", "Output side")
            if not outSide then return end
            local value = analogValue(inputBox("Rule", "Output level when true 0-15:"))
            local elseValue = analogValue(inputBox("Rule", "Output level when false 0-15:"), 0)
            if threshold ~= nil and value ~= nil then
                rsData.rules[#rsData.rules + 1] = {
                    inputSide = inSide, threshold = threshold, outputSide = outSide,
                    value = value, elseValue = elseValue,
                }
                writeTable(RS_FILE, rsData)
            else showMessage("Rule", "The rule was not saved because one of the values was invalid.") end
        elseif confirm("Delete rule", items[choice] .. "?") then
            table.remove(rsData.rules, choice)
            writeTable(RS_FILE, rsData)
        end
    end
end

local bundledColors = {
    { "White", colors.white }, { "Orange", colors.orange }, { "Magenta", colors.magenta }, { "Light blue", colors.lightBlue },
    { "Yellow", colors.yellow }, { "Lime", colors.lime }, { "Pink", colors.pink }, { "Gray", colors.gray },
    { "Light gray", colors.lightGray }, { "Cyan", colors.cyan }, { "Purple", colors.purple }, { "Blue", colors.blue },
    { "Brown", colors.brown }, { "Green", colors.green }, { "Red", colors.red }, { "Black", colors.black },
}

local function bundledPanel(side)
    local selected, offset = 1, 0
    while true do
        clearScreen(T().desktop)
        drawChrome("Bundled redstone: " .. side, "Select a colour, then toggle its output")
        local w, h = size()
        local maxRows = math.max(1, h - 6)
        if selected <= offset then offset = selected - 1 end
        if selected > offset + maxRows then offset = selected - maxRows end
        local okOut, output = pcall(redstone.getBundledOutput, side)
        local okIn, input = pcall(redstone.getBundledInput, side)
        output, input = okOut and output or 0, okIn and input or 0
        local boxes = {}
        for row = 1, maxRows do
            local i = offset + row
            local item = bundledColors[i]
            if not item then break end
            local onOut, onIn = colors.test(output, item[2]), colors.test(input, item[2])
            local bg = i == selected and T().accent or T().desktop
            fill(2, row + 2, w - 1, row + 2, bg)
            writeAt(3, row + 2, string.format("%-12s OUT:%s  IN:%s", item[1], onOut and "ON " or "OFF", onIn and "ON" or "OFF"), i == selected and T().text or T().dark, bg)
            boxes[#boxes + 1] = { index = i, x1 = 2, y1 = row + 2, x2 = w - 1, y2 = row + 2 }
        end
        local toggle = drawButton(2, h - 2, math.max(8, math.floor(w / 2) - 1), h - 2, "Toggle", true)
        local back = drawButton(math.floor(w / 2) + 1, h - 2, w - 1, h - 2, "Back", false)
        local function doToggle()
            local bit = bundledColors[selected][2]
            output = colors.test(output, bit) and colors.subtract(output, bit) or colors.combine(output, bit)
            local ok, err = pcall(redstone.setBundledOutput, side, output)
            if not ok then showMessage("Bundled redstone", tostring(err)) end
        end
        local e, a, b, c = pullUiEvent()
        if e == "key" then
            if a == keys.up then selected = math.max(1, selected - 1)
            elseif a == keys.down then selected = math.min(#bundledColors, selected + 1)
            elseif a == keys.space or a == keys.enter then doToggle()
            elseif a == keys.escape or a == keys.backspace then return end
        elseif e == "mouse_scroll" then selected = math.max(1, math.min(#bundledColors, selected + a))
        elseif e == "mouse_click" then
            if inBox(b, c, toggle) then doToggle()
            elseif inBox(b, c, back) then return
            else for _, box in ipairs(boxes) do if inBox(b, c, box) then if selected == box.index then doToggle() else selected = box.index end break end end end
        end
    end
end

local function redstoneApp()
    local selected = 1
    while true do
        clearScreen(T().desktop)
        drawChrome("Redstone Center", "Select side | Set, pulse, timer, scenes or automation")
        local w, h = size()
        local boxes = {}
        for i, side in ipairs(sides) do
            local y = i + 3
            if y >= h - 2 then break end
            local okIn, input = pcall(redstone.getAnalogInput, side)
            local okOut, output = pcall(redstone.getAnalogOutput, side)
            input, output = okIn and analogValue(input, 0) or 0, okOut and analogValue(output, 0) or 0
            local bg = i == selected and T().accent or T().desktop
            fill(2, y, w - 1, y, bg)
            writeAt(3, y, string.format("%-7s INPUT %2d   OUTPUT %2d", side, input, output), i == selected and T().text or T().dark, bg)
            boxes[#boxes + 1] = { index = i, x1 = 2, y1 = y, x2 = w - 1, y2 = y }
        end
        local buttonWidth = math.max(6, math.floor((w - 2) / 5))
        local toolbar = {
            drawButton(2, h - 2, math.min(w - 1, 1 + buttonWidth), h - 2, "Set", true),
            drawButton(2 + buttonWidth, h - 2, math.min(w - 1, 1 + buttonWidth * 2), h - 2, "Pulse", false),
            drawButton(2 + buttonWidth * 2, h - 2, math.min(w - 1, 1 + buttonWidth * 3), h - 2, "Timer", false),
            drawButton(2 + buttonWidth * 3, h - 2, math.min(w - 1, 1 + buttonWidth * 4), h - 2, "Scenes", false),
            drawButton(2 + buttonWidth * 4, h - 2, w - 1, h - 2, "More", false),
        }
        local side = sides[selected]
        local function setLevel()
            local value = analogValue(inputBox("Set output", side .. " level 0-15:"))
            if value ~= nil then local ok, err = pcall(redstone.setAnalogOutput, side, value) if not ok then showMessage("Redstone", tostring(err)) end end
        end
        local function pulse()
            local seconds = tonumber(inputBox("Pulse", "Pulse duration in seconds:"))
            if not seconds or seconds <= 0 or seconds > 86400 then showMessage("Pulse", "Enter a duration between 0 and 86400 seconds.") return end
            local ok, old = pcall(redstone.getAnalogOutput, side)
            old = ok and analogValue(old, 0) or 0
            local setOk, err = pcall(redstone.setAnalogOutput, side, 15)
            if not setOk then showMessage("Pulse", tostring(err)) return end
            rsData.timers[#rsData.timers + 1] = { due = nowMs() + math.floor(seconds * 1000), side = side, value = old }
            writeTable(RS_FILE, rsData)
        end
        local function schedule()
            local seconds = tonumber(inputBox("Schedule output", "Delay in seconds:"))
            local value = analogValue(inputBox("Schedule output", "Output level 0-15:"))
            if seconds and seconds >= 0 and seconds <= 31536000 and value ~= nil then
                rsData.timers[#rsData.timers + 1] = { due = nowMs() + math.floor(seconds * 1000), side = side, value = value }
                writeTable(RS_FILE, rsData)
            else showMessage("Schedule output", "Invalid delay or output value.") end
        end
        local e, a, b, c = pullUiEvent()
        if e == "key" then
            if a == keys.up then selected = math.max(1, selected - 1)
            elseif a == keys.down then selected = math.min(#sides, selected + 1)
            elseif a == keys.left or a == keys.right then
                local ok, current = pcall(redstone.getAnalogOutput, side)
                current = ok and analogValue(current, 0) or 0
                pcall(redstone.setAnalogOutput, side, math.max(0, math.min(15, current + (a == keys.left and -1 or 1))))
            elseif a == keys.enter then setLevel()
            elseif a == keys.p then pulse()
            elseif a == keys.t then schedule()
            elseif a == keys.s then redstoneScenes()
            elseif a == keys.r then redstoneRules()
            elseif a == keys.b then bundledPanel(side)
            elseif a == keys.escape or a == keys.backspace then return end
        elseif e == "mouse_click" then
            if inBox(b, c, toolbar[1]) then setLevel()
            elseif inBox(b, c, toolbar[2]) then pulse()
            elseif inBox(b, c, toolbar[3]) then schedule()
            elseif inBox(b, c, toolbar[4]) then redstoneScenes()
            elseif inBox(b, c, toolbar[5]) then
                local action = menuSelect("Redstone tools", { "Automation rules", "Bundled redstone", "Toggle output", "Back" })
                if action == 1 then redstoneRules()
                elseif action == 2 then bundledPanel(side)
                elseif action == 3 then
                    local ok, current = pcall(redstone.getAnalogOutput, side)
                    pcall(redstone.setAnalogOutput, side, ok and current > 0 and 0 or 15)
                elseif action == 4 then return end
            else
                for _, box in ipairs(boxes) do
                    if inBox(b, c, box) then
                        if selected == box.index then
                            local selectedSide = sides[box.index]
                            local ok, current = pcall(redstone.getAnalogOutput, selectedSide)
                            pcall(redstone.setAnalogOutput, selectedSide, ok and current > 0 and 0 or 15)
                        else selected = box.index end
                        break
                    end
                end
            end
        end
    end
end

local function peripheralDetails(name)
    local presentOk, present = pcall(peripheral.isPresent, name)
    if not presentOk or not present then showMessage("Peripheral", "The device was disconnected.") return end
    local types = peripheralTypes(name)
    local methods = peripheralMethods(name)
    table.sort(methods)
    local alias = config.peripheralAliases[name]
    local items = {
        "Name: " .. name,
        "Alias: " .. (alias or "(none)"),
        "Types: " .. table.concat(types, ", "),
        "Methods: " .. #methods,
        "<Set alias>",
        "<Run device test>",
        "<Show methods>",
    }
    local choice = menuSelect("Peripheral details", items)
    if choice == 5 then
        local value = inputBox("Peripheral alias", "Alias for " .. name .. " (blank clears):")
        if value ~= nil then
            value = value:gsub("^%s+", ""):gsub("%s+$", "")
            config.peripheralAliases[name] = value ~= "" and value:sub(1, 32) or nil
            saveConfig()
        end
    elseif choice == 6 then
        local obj = peripheral.wrap(name)
        if not obj then showMessage("Peripheral", "The device was disconnected.") return end
        if peripheral.hasType(name, "monitor") then
            local previous = term.current()
            local oldScale = nil
            if obj.getTextScale then local ok, value = pcall(obj.getTextScale) if ok then oldScale = value end end
            local ok, err = pcall(function()
                if obj.setTextScale then obj.setTextScale(1) end
                term.redirect(obj)
                clearScreen(colors.black)
                centerText(2, "McOS monitor test", colors.white, colors.black)
                centerText(4, name, colors.lightGray, colors.black)
                cooperativeDelay(1)
            end)
            term.redirect(previous)
            if oldScale and obj.setTextScale then pcall(obj.setTextScale, oldScale) end
            if not ok then showMessage("Monitor test failed", tostring(err)) end
        elseif peripheral.hasType(name, "speaker") then
            local ok, err = pcall(obj.playNote, "pling", 2, 12)
            if not ok then showMessage("Speaker test failed", tostring(err)) end
        elseif peripheral.hasType(name, "printer") then
            local ok, paper, ink = pcall(function() return obj.getPaperLevel(), obj.getInkLevel() end)
            showMessage("Printer", ok and ("Paper: " .. tostring(paper) .. "  Ink: " .. tostring(ink)) or tostring(paper))
        elseif peripheral.hasType(name, "computer") or peripheral.hasType(name, "turtle") then
            local ok, info = pcall(function() return "ID: " .. tostring(obj.getID()) .. "  On: " .. tostring(obj.isOn()) .. "  Label: " .. tostring(obj.getLabel()) end)
            showMessage("Computer", ok and info or tostring(info))
        elseif type(obj.list) == "function" then
            local ok, list = pcall(obj.list)
            if ok and type(list) == "table" then
                local count = 0 for _ in pairs(list) do count = count + 1 end
                showMessage("Inventory test", "Occupied slots: " .. count)
            else showMessage("Inventory test failed", tostring(list)) end
        else showMessage("Test", "No built-in test is available for this peripheral.") end
    elseif choice == 7 then
        if #methods == 0 then showMessage("Methods", "This peripheral reports no methods.") else menuSelect("Methods", methods) end
    end
end

local function peripheralManager()
    while true do
        local namesOk, names = pcall(peripheral.getNames)
        names = namesOk and type(names) == "table" and names or {}
        table.sort(names)
        local items = {}
        for _, name in ipairs(names) do
            local alias = config.peripheralAliases[name]
            local types = peripheralTypes(name)
            items[#items + 1] = string.format("%s%s  [%s]", alias and (alias .. " / ") or "", name, table.concat(types, ","))
        end
        items[#items + 1] = "<Refresh devices>"
        local choice = menuSelect("Peripheral Manager", items, "Enter: details/test   Esc: back")
        if not choice then return end
        if choice == #items then
            refreshSpeakers()
            openRednet()
        else peripheralDetails(names[choice]) end
    end
end

local function discoverPeers()
    netPeers = {}
    local ok, err = broadcastNet({ type = "DISCOVER" })
    if not ok then showMessage("McNet", err or "No modem is available.") return false end
    local timer = os.startTimer(1.5)
    while true do
        local e, value = pullUiEvent()
        if e == "timer" and value == timer then break end
        if e == "key" and value == keys.escape then return false end
    end
    return true
end

local function peerList()
    local peers = {}
    for id, peer in pairs(netPeers) do
        peer.id = id
        peer.trusted = isTrustedPeer(id)
        peers[#peers + 1] = peer
    end
    table.sort(peers, function(a, b) return a.id < b.id end)
    return peers
end

local function waitForRequest(id, seconds)
    local timer = os.startTimer(seconds or 2)
    while true do
        local result = pendingNet[id]
        if result and result.done then pendingNet[id] = nil return result.ok, result.detail end
        local e, a = pullUiEvent()
        if e == "timer" and a == timer then pendingNet[id] = nil return false, "Timed out" end
        if e == "key" and a == keys.escape then pendingNet[id] = nil return false, "Cancelled" end
    end
end

local function sendRequest(peerId, payload, timeout)
    payload.request = payload.request or requestId(payload.type or "req")
    pendingNet[payload.request] = { done = false }
    local ok, err = sendNet(peerId, payload)
    if not ok then pendingNet[payload.request] = nil return false, err end
    return waitForRequest(payload.request, timeout or 2.5)
end

local function mcnetApp()
    local stateOk, isOpen = pcall(rednet.isOpen)
    if not (stateOk and isOpen) and not openRednet() then showMessage("McNet", "Connect a wired or wireless modem first.") return end
    discoverPeers()
    while true do
        local peers = peerList()
        local items = {}
        for _, peer in ipairs(peers) do
            items[#items + 1] = string.format("#%d  %s  v%s  %sms%s", peer.id, peer.label or "Computer", peer.version or "?", tostring(peer.latency or "-"), peer.trusted and "  [TRUSTED]" or "")
        end
        items[#items + 1] = "<Discover devices>"
        items[#items + 1] = "<Inbox (" .. #netInbox .. ")>"
        local choice = menuSelect("McNet", items, "Messages, files, ping and trusted remote control")
        if not choice then return end
        if choice == #items - 1 then discoverPeers()
        elseif choice == #items then
            local inbox = {}
            for i = #netInbox, 1, -1 do
                local msg = netInbox[i]
                inbox[#inbox + 1] = tostring(msg.time or "") .. "  #" .. tostring(msg.from or "?") .. ": " .. clip(msg.body, 60)
            end
            if #inbox == 0 then showMessage("McNet Inbox", "No messages have been received.")
            else
                inbox[#inbox + 1] = "<Clear inbox>"
                local selected = menuSelect("McNet Inbox", inbox)
                if selected == #inbox and confirm("McNet Inbox", "Clear all saved messages?") then netInbox = {} saveNetInbox() end
            end
        else
            local peer = peers[choice]
            if peer then
                local trusted = isTrustedPeer(peer.id)
                local action = menuSelect(peer.label or ("Computer " .. peer.id), {
                    "Send message", "Send file", "Ping",
                    trusted and "Remove from trusted devices" or "Trust this device",
                    "Remote redstone", "Remote program launch",
                })
                if action == 1 then
                    local body = inputBox("McNet message", "Message to #" .. peer.id .. " (max 1024 characters):")
                    if body and body ~= "" then
                        body = body:sub(1, 1024)
                        local ok, detail = sendRequest(peer.id, { type = "MESSAGE", body = body }, 3)
                        showMessage(ok and "McNet" or "Send failed", ok and "Message delivered." or tostring(detail))
                    end
                elseif action == 2 then
                    local path = inputBox("Send file", "Local file path:")
                    if path and path ~= "" then
                        path = canonicalPath(path)
                        if not fs.exists(path) or fs.isDir(path) then showMessage("Send file", "File not found.")
                        else
                            local data, readErr = readAll(path, "rb")
                            if not data then showMessage("Send file", readErr)
                            elseif #data > 131072 then showMessage("File too large", "McNet file limit is 128 KB.")
                            else
                                local ok, detail = sendRequest(peer.id, { type = "FILE", name = fs.getName(path), data = data }, 5)
                                showMessage(ok and "File sent" or "File transfer failed", tostring(detail or "Done"))
                            end
                        end
                    end
                elseif action == 3 then
                    local req = requestId("ping")
                    pendingNet[req] = { done = false }
                    local sent, err = sendNet(peer.id, { type = "PING", sent = nowMs(), request = req })
                    if not sent then pendingNet[req] = nil showMessage("Ping failed", tostring(err))
                    else
                        local ok, latency = waitForRequest(req, 2)
                        showMessage(ok and "Ping" or "Ping failed", ok and ("Reply from #" .. peer.id .. ": " .. tostring(latency) .. " ms") or tostring(latency))
                    end
                elseif action == 4 then
                    if trusted then config.trustedPeers[tostring(peer.id)] = nil
                    else config.trustedPeers[tostring(peer.id)] = true end
                    saveConfig()
                    netPeers[peer.id].trusted = not trusted
                    logEvent("NET", (trusted and "Untrusted #" or "Trusted #") .. peer.id)
                elseif action == 5 then
                    if not trusted then showMessage("Remote redstone", "Trust this device first.")
                    else
                        local side = chooseSide("Remote redstone", "Side on remote computer")
                        local value = analogValue(inputBox("Remote redstone", "Level 0-15:"))
                        if side and value ~= nil then
                            local ok, detail = sendRequest(peer.id, { type = "REMOTE_RS", side = side, value = value }, 3)
                            showMessage(ok and "Remote redstone" or "Remote redstone failed", tostring(detail))
                        end
                    end
                elseif action == 6 then
                    if not trusted then showMessage("Remote launch", "Trust this device first.")
                    else
                        local path = inputBox("Remote launch", "Program path on remote computer:")
                        if path and path ~= "" and confirm("Remote launch", "Request this trusted computer to launch " .. path .. "?") then
                            local ok, detail = sendRequest(peer.id, { type = "REMOTE_RUN", path = path, args = {} }, 3)
                            showMessage(ok and "Remote launch" or "Remote launch failed", tostring(detail))
                        end
                    end
                end
            end
        end
    end
end

local function notificationsApp()
    while true do
        local items = {}
        for i = #notifications, 1, -1 do
            local n = notifications[i]
            items[#items + 1] = string.format("%s%s  %s - %s", n.read and "" or "* ", tostring(n.time or ""), tostring(n.title or "Notification"), clip(tostring(n.body or ""), 40))
        end
        items[#items + 1] = "<Mark all read>"
        items[#items + 1] = "<Clear all>"
        local choice = menuSelect("Notification Center", items)
        if not choice then writeTable(NOTIFY_FILE, notifications) return end
        if choice == #items - 1 then
            for _, n in ipairs(notifications) do n.read = true end
            writeTable(NOTIFY_FILE, notifications)
        elseif choice == #items then
            if confirm("Clear notifications", "Delete all notifications?") then notifications = {} writeTable(NOTIFY_FILE, notifications) end
        else
            local real = #notifications - choice + 1
            local item = notifications[real]
            if item then item.read = true writeTable(NOTIFY_FILE, notifications) showMessage(tostring(item.title or "Notification"), tostring(item.body or "")) end
        end
    end
end

local function calculatorApp()
    local history = {}
    while true do
        local expression = inputBox("Calculator", "Expression, or leave blank to exit:")
        if not expression or expression == "" then return end
        if not expression:match("^[%d%s%.%+%-%*%/%^%%%(%)]+$") then showMessage("Calculator", "Only numbers and arithmetic operators are allowed.")
        else
            local fn, err = load("return " .. expression, "calculator", "t", {})
            if not fn then showMessage("Calculator error", err)
            else
                local ok, result = pcall(fn)
                if ok then history[#history + 1] = expression .. " = " .. tostring(result) showMessage("Calculator", history[#history]) else showMessage("Calculator error", result) end
            end
        end
    end
end

local function notesApp()
    while true do
        local names = {}
        local listOk, noteNames = pcall(fs.list, NOTES_DIR)
        for _, name in ipairs(listOk and noteNames or {}) do
            local full = fs.combine(NOTES_DIR, name)
            if not fs.isDir(full) then names[#names + 1] = name end
        end
        table.sort(names)
        local items = {} for _, name in ipairs(names) do items[#items + 1] = name end
        items[#items + 1] = "<New note>"
        local choice = menuSelect("Notes", items, "Select note to view, edit or delete")
        if not choice then return end
        if choice == #items then
            local name = inputBox("New note", "Note name:")
            if name and name ~= "" then
                name = safeName(name, "Note")
                if not name:lower():match("%.txt$") then name = name .. ".txt" end
                local path = canonicalPath(fs.combine(NOTES_DIR, name))
                if fs.exists(path) and not confirm("Note exists", name .. " already exists. Open it without clearing its contents?") then
                    -- cancelled
                else
                    if not fs.exists(path) then
                        local ok, err = writeAll(path, "")
                        if not ok then showMessage("New note failed", err) path = nil end
                    end
                    if path then runOnComputer("edit", path) end
                end
            end
        else
            local path = fs.combine(NOTES_DIR, names[choice])
            local action = menuSelect(names[choice], { "View", "Edit", "Delete" })
            if action == 1 then viewFile(path)
            elseif action == 2 then runOnComputer("edit", path)
            elseif action == 3 and confirm("Delete note", names[choice] .. "?") then
                local ok, err = moveToTrash(path)
                if not ok then showMessage("Delete note failed", err) end
            end
        end
    end
end

local function clockApp()
    while true do
        clearScreen(T().desktop)
        drawChrome("Clock & Timers", "Add and remove countdown timers")
        local w, h = size()
        centerText(4, textutils.formatTime(os.time(), true), T().dark, T().desktop)
        centerText(6, os.date("!%A, %Y-%m-%d UTC"), T().dark, T().desktop)
        local rows = math.max(1, h - 12)
        local boxes = {}
        for i = 1, math.min(#userTimers, rows) do
            local timer = userTimers[i]
            local left = math.max(0, math.ceil(((tonumber(timer.due) or nowMs()) - nowMs()) / 1000))
            local y = 7 + i
            fill(2, y, w - 1, y, T().desktop)
            writeAt(3, y, clip((timer.name or "Timer") .. ": " .. left .. "s", w - 5), T().dark, T().desktop)
            boxes[#boxes + 1] = { index = i, x1 = 2, y1 = y, x2 = w - 1, y2 = y }
        end
        if #userTimers == 0 then centerText(9, "No active timers", T().dark, T().desktop) end
        local add = drawButton(2, h - 2, math.max(8, math.floor(w / 2) - 1), h - 2, "Add timer", true)
        local back = drawButton(math.floor(w / 2) + 1, h - 2, w - 1, h - 2, "Back", false)
        local refresh = os.startTimer(1)
        local function addTimer()
            local name = inputBox("New timer", "Timer name:")
            local seconds = tonumber(inputBox("New timer", "Seconds:"))
            if seconds and seconds > 0 and seconds <= 31536000 then
                userTimers[#userTimers + 1] = { name = name and name ~= "" and name:sub(1, 40) or "Timer", due = nowMs() + math.floor(seconds * 1000) }
                writeTable(TIMER_FILE, userTimers)
            elseif seconds then showMessage("New timer", "Enter a duration between 1 second and 1 year.") end
        end
        local e, a, b, c = pullUiEvent()
        if e == "timer" and a == refresh then
            -- redraw
        elseif e == "key" then
            if a == keys.t then addTimer()
            elseif a == keys.escape or a == keys.backspace then return end
        elseif e == "mouse_click" then
            if inBox(b, c, add) then addTimer()
            elseif inBox(b, c, back) then return
            else
                for _, box in ipairs(boxes) do
                    if inBox(b, c, box) and confirm("Delete timer", "Delete " .. tostring(userTimers[box.index].name or "Timer") .. "?") then
                        table.remove(userTimers, box.index) writeTable(TIMER_FILE, userTimers) break
                    end
                end
            end
        end
    end
end

local function paintApp()
    local path = inputBox("Paint", "Image path (example /mcos/user/picture.nfp):")
    if path and path ~= "" then
        path = canonicalPath(path)
        if isProtectedWriteTarget(path) then showMessage("Paint", "McOS protects this path from editing.")
        elseif fs.exists(path) and fs.isDir(path) then showMessage("Paint", "The selected path is a folder.")
        else runOnComputer("paint", path) end
    end
end

local function musicApp()
    local listOk, names = pcall(fs.list, MUSIC_DIR)
    names = listOk and names or {}
    table.sort(names)
    local items = {}
    for _, name in ipairs(names) do if name:lower():match("%.dfpwm$") then items[#items + 1] = name end end
    items[#items + 1] = "<Play test melody>"
    local choice = menuSelect("Music Player", items, "Place .dfpwm files in " .. MUSIC_DIR)
    if not choice then return end
    local speaker = peripheral.find("speaker")
    if not speaker then showMessage("Music Player", "No speaker is connected.") return end
    if choice == #items then
        for _, note in ipairs({ 8, 10, 12, 15, 12, 10, 8 }) do
            local ok = pcall(speaker.playNote, "harp", 1, note)
            if not ok then break end
            if not cooperativeDelay(0.15) then break end
        end
        return
    end
    local path = fs.combine(MUSIC_DIR, items[choice])
    local okDecoder, decoderModule = pcall(require, "cc.audio.dfpwm")
    if not okDecoder or type(decoderModule) ~= "table" then showMessage("Music Player", "DFPWM decoder is not available in this CC:Tweaked version.") return end
    local decoder = decoderModule.make_decoder()
    local h = fs.open(path, "rb")
    if not h then showMessage("Music Player", "Unable to open file.") return end
    clearScreen(colors.black)
    local w, height = size()
    centerText(2, "Playing " .. fs.getName(path), colors.white, colors.black)
    centerText(4, "Esc or Back button: stop", colors.lightGray, colors.black)
    local back = drawButton(2, height - 2, w - 1, height - 2, "Stop", true)
    local stopped, failed = false, nil
    while not stopped do
        local chunk = h.read(16 * 1024)
        if not chunk then break end
        local buffer = decoder(chunk)
        while not stopped do
            local okPlay, accepted = pcall(speaker.playAudio, buffer)
            if not okPlay then failed = tostring(accepted) stopped = true break end
            if accepted then break end
            local e, a, b, c = pullUiEvent()
            if e == "key" and (a == keys.escape or a == keys.backspace) then stopped = true
            elseif e == "mouse_click" and inBox(b, c, back) then stopped = true
            elseif e == "speaker_audio_empty" then -- retry
            end
        end
    end
    pcall(h.close)
    pcall(speaker.stop)
    if failed then showMessage("Music Player", failed) end
end

local function printerApp()
    local printers = { peripheral.find("printer") }
    if #printers == 0 then showMessage("Printer Center", "No printer is connected.") return end
    local printer = printers[1]
    local action = menuSelect("Printer Center", { "Printer status", "Print text file" })
    if action == 1 then
        local ok, paper, ink = pcall(function() return printer.getPaperLevel(), printer.getInkLevel() end)
        showMessage("Printer status", ok and ("Paper: " .. tostring(paper) .. "\nInk: " .. tostring(ink)) or tostring(paper))
    elseif action == 2 then
        local path = inputBox("Print file", "Text file path:")
        if not path or path == "" then return end
        path = canonicalPath(path)
        if not fs.exists(path) or fs.isDir(path) then showMessage("Printer", "Text file not found.") return end
        local raw, err = readAll(path)
        if not raw then showMessage("Printer", err) return end
        local printable = {}
        for rawLine in (raw .. "\n"):gmatch("(.-)\n") do
            local line = rawLine:gsub("[%z\1-\31]", " ")
            if line == "" then printable[#printable + 1] = "" else
                while #line > 25 do printable[#printable + 1] = line:sub(1, 25) line = line:sub(26) end
                printable[#printable + 1] = line
            end
        end
        local pageNumber = 1
        for first = 1, #printable, 21 do
            local ok, pageOk = pcall(printer.newPage)
            if not ok or not pageOk then showMessage("Printer", "Unable to start a page. Check paper and ink.") return end
            local success, printErr = pcall(function()
                printer.setPageTitle(clip(fs.getName(path) .. " " .. pageNumber, 25))
                for row = 0, 20 do
                    local line = printable[first + row]
                    if line == nil then break end
                    printer.setCursorPos(1, row + 1)
                    printer.write(line)
                end
                if not printer.endPage() then error("Unable to finish the printed page") end
            end)
            if not success then showMessage("Printer", tostring(printErr)) return end
            pageNumber = pageNumber + 1
        end
        notify("Printer Center", "Printed " .. fs.getName(path), "info")
    end
end

local function inventoryApp()
    local inventories = {}
    local namesOk, peripheralNames = pcall(peripheral.getNames)
    for _, name in ipairs(namesOk and peripheralNames or {}) do
        local methods = peripheralMethods(name)
        for _, method in ipairs(methods) do if method == "list" then inventories[#inventories + 1] = name break end end
    end
    table.sort(inventories)
    if #inventories == 0 then showMessage("Inventory Viewer", "No inventory peripheral is connected.") return end
    local choice = menuSelect("Inventory Viewer", inventories)
    if not choice then return end
    local inv = peripheral.wrap(inventories[choice])
    if not inv then showMessage("Inventory Viewer", "The inventory was disconnected.") return end
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then showMessage("Inventory Viewer", tostring(list)) return end
    local slots = {}
    for slot in pairs(list) do slots[#slots + 1] = slot end
    table.sort(slots)
    local items = {}
    for _, slot in ipairs(slots) do
        local item = list[slot]
        items[#items + 1] = string.format("Slot %d: %s x%d", slot, tostring(item.name or "item"), tonumber(item.count) or 0)
    end
    if #items == 0 then showMessage("Inventory Viewer", "The inventory is empty.")
    else menuSelect(config.peripheralAliases[inventories[choice]] or inventories[choice], items) end
end

local function turtleApp()
    if turtle then
        while true do
            clearScreen(T().desktop)
            drawChrome("Turtle Control", "Keyboard or touch controls")
            local w, h = size()
            centerText(4, "Fuel: " .. tostring(turtle.getFuelLevel()) .. "   Slot: " .. turtle.getSelectedSlot(), T().dark, T().desktop)
            local cx = math.max(2, math.floor(w / 2) - 4)
            local third = math.max(7, math.floor((w - 2) / 3))
            local controls = {
                up = drawButton(cx, 5, math.min(w - 1, cx + 8), 6, "Forward", true),
                left = drawButton(2, 8, math.min(w - 1, 1 + third), 9, "Left", false),
                back = drawButton(2 + third, 8, math.min(w - 1, 1 + third * 2), 9, "Back", false),
                right = drawButton(2 + third * 2, 8, w - 1, 9, "Right", false),
                rise = drawButton(2, 11, math.min(w - 1, 1 + third), 12, "Up", false),
                fall = drawButton(2 + third, 11, math.min(w - 1, 1 + third * 2), 12, "Down", false),
                dig = drawButton(2 + third * 2, 11, w - 1, 12, "Dig", false),
                place = drawButton(2, h - 2, math.max(8, math.floor(w / 2) - 1), h - 2, "Place", false),
                exit = drawButton(math.floor(w / 2) + 1, h - 2, w - 1, h - 2, "Exit", false),
            }
            local function act(name)
                local fn = turtle[name]
                if type(fn) == "function" then
                    local ok, result, reason = pcall(fn)
                    if not ok then showMessage("Turtle", tostring(result))
                    elseif result == false and reason then notify("Turtle", tostring(reason), "warn") end
                end
            end
            local e, a, b, c = pullUiEvent()
            if e == "key" then
                if a == keys.w then act("forward")
                elseif a == keys.s then act("back")
                elseif a == keys.a then act("turnLeft")
                elseif a == keys.d then act("turnRight")
                elseif a == keys.u then act("up")
                elseif a == keys.j then act("down")
                elseif a == keys.g then act("dig")
                elseif a == keys.p then act("place")
                elseif a == keys.escape or a == keys.backspace then return end
            elseif e == "mouse_click" then
                if inBox(b, c, controls.up) then act("forward")
                elseif inBox(b, c, controls.back) then act("back")
                elseif inBox(b, c, controls.left) then act("turnLeft")
                elseif inBox(b, c, controls.right) then act("turnRight")
                elseif inBox(b, c, controls.rise) then act("up")
                elseif inBox(b, c, controls.fall) then act("down")
                elseif inBox(b, c, controls.dig) then act("dig")
                elseif inBox(b, c, controls.place) then act("place")
                elseif inBox(b, c, controls.exit) then return end
            end
        end
    end
    local devices = {}
    local namesOk, peripheralNames = pcall(peripheral.getNames)
    for _, name in ipairs(namesOk and peripheralNames or {}) do
        local computerOk, isComputer = pcall(peripheral.hasType, name, "computer")
        local turtleOk, isTurtle = pcall(peripheral.hasType, name, "turtle")
        if (computerOk and isComputer) or (turtleOk and isTurtle) then devices[#devices + 1] = name end
    end
    if #devices == 0 then showMessage("Computer & Turtle Power", "No wired computer or turtle peripheral is connected.") return end
    local choice = menuSelect("Computer & Turtle Power", devices)
    if not choice then return end
    local device = peripheral.wrap(devices[choice])
    if not device then showMessage("Device", "The device was disconnected.") return end
    local action = menuSelect(devices[choice], { "Turn on", "Reboot", "Shutdown", "Status" })
    local ok, result = true, nil
    if action == 1 then ok, result = pcall(device.turnOn)
    elseif action == 2 then ok, result = pcall(device.reboot)
    elseif action == 3 then ok, result = pcall(device.shutdown)
    elseif action == 4 then
        ok, result = pcall(function() return "ID: " .. tostring(device.getID()) .. "\nOn: " .. tostring(device.isOn()) .. "\nLabel: " .. tostring(device.getLabel()) end)
        showMessage("Status", ok and result or tostring(result))
    end
    if action and action < 4 and not ok then showMessage("Device command failed", tostring(result)) end
end

local function taskManagerApp()
    while true do
        clearScreen(T().desktop)
        drawChrome("System Monitor", "Live system state and multishell tabs")
        local w, h = size()
        local freeOk, free = pcall(fs.getFreeSpace, "/")
        local peripheralsOk, peripheralNames = pcall(peripheral.getNames)
        peripheralNames = peripheralsOk and type(peripheralNames) == "table" and peripheralNames or {}
        local stats = {
            "Current app: " .. currentApp,
            "Uptime: " .. math.floor(os.clock()) .. " seconds",
            "Free storage: " .. formatBytes(freeOk and free or "unknown"),
            "Peripherals: " .. #peripheralNames,
            "McNet peers: " .. #peerList(),
            "Saved McNet messages: " .. #netInbox,
            "Notifications: " .. #notifications,
            "Redstone rules: " .. #rsData.rules,
            "Scheduled jobs: " .. (#rsData.timers + #userTimers),
            "Remote queue: " .. #remoteQueue,
        }
        local y = 4
        for _, line in ipairs(stats) do if y >= h - 3 then break end writeAt(3, y, clip(line, w - 5), T().dark, T().desktop) y = y + 1 end
        if multishell and y < h - 4 then
            writeAt(3, y + 1, "Multishell tabs:", T().dark, T().desktop)
            for i = 1, multishell.getCount() do
                y = y + 1
                if y + 1 >= h - 2 then break end
                writeAt(5, y + 1, i .. ". " .. tostring(multishell.getTitle(i)), T().dark, T().desktop)
            end
        end
        local back = drawButton(2, h - 2, w - 1, h - 2, "Back", true)
        local refresh = os.startTimer(1)
        local e, a, b, c = pullUiEvent()
        if e == "timer" and a == refresh then
            -- redraw
        elseif e == "key" then
            if a == keys.t and multishell then
                local id = tonumber(inputBox("Focus tab", "Tab number:"))
                if id then pcall(multishell.setFocus, id) end
            elseif a == keys.escape or a == keys.backspace then return end
        elseif e == "mouse_click" and inBox(b, c, back) then return end
    end
end

local function logsApp()
    if not fs.exists(LOG_FILE) then showMessage("System Log", "The log is empty.") return end
    viewFile(LOG_FILE)
end

local function createBackup(label)
    local base = timestamp() .. (label and ("_" .. safeName(label, "backup")) or "")
    local dir = uniquePath(fs.combine(BACKUP_DIR, base))
    if not ensureDir(dir) then return false, "Unable to create backup folder" end
    local copied = {}
    local function copyItem(source, name)
        if not fs.exists(source) then return true end
        local target = fs.combine(dir, name or fs.getName(source))
        local ok, err = pcall(fs.copy, source, target)
        if ok then copied[#copied + 1] = source return true end
        return false, tostring(err)
    end
    local stateFiles = { CONFIG_FILE, NOTIFY_FILE, RS_FILE, TRASH_FILE, TIMER_FILE, NET_FILE }
    for _, source in ipairs(stateFiles) do
        local ok, err = copyItem(source)
        if not ok then pcall(fs.delete, dir) return false, err end
    end
    local ok, err = copyItem(USER_DIR, "user")
    if not ok then pcall(fs.delete, dir) return false, err end
    ok, err = copyItem(APPS_DIR, "apps")
    if not ok then pcall(fs.delete, dir) return false, err end
    ok, err = copyItem(TRASH_DIR, "trash")
    if not ok then pcall(fs.delete, dir) return false, err end
    local manifest = {
        version = OS_VERSION, created = os.date("!%Y-%m-%d %H:%M:%S"),
        label = label or "", files = copied,
    }
    local saved, saveErr = writeTable(fs.combine(dir, "manifest.db"), manifest)
    if not saved then pcall(fs.delete, dir) return false, saveErr end
    logEvent("BACKUP", "Created " .. dir)
    return true, dir
end

local function restoreBackup(dir)
    dir = canonicalPath(dir)
    if not isInside(dir, BACKUP_DIR) or not fs.exists(dir) or not fs.isDir(dir) then return false, "Invalid backup folder" end
    local manifest = readTable(fs.combine(dir, "manifest.db"), nil)
    if type(manifest) ~= "table" or type(manifest.version) ~= "string" then
        return false, "This folder is not a McOS recovery backup"
    end

    local operations = {}
    local function addOperation(source, target)
        if fs.exists(source) then operations[#operations + 1] = { source = source, target = target } end
    end
    for _, pair in ipairs({
        { "config.db", CONFIG_FILE }, { "notifications.db", NOTIFY_FILE },
        { "redstone.db", RS_FILE }, { "trash.db", TRASH_FILE },
        { "timers.db", TIMER_FILE }, { "mcnet.db", NET_FILE },
    }) do addOperation(fs.combine(dir, pair[1]), pair[2]) end
    if fs.exists(fs.combine(dir, "user")) then
        addOperation(fs.combine(dir, "user"), USER_DIR)
    elseif fs.exists(fs.combine(dir, "notes")) then
        -- Compatibility with an early pre-release backup layout.
        addOperation(fs.combine(dir, "notes"), NOTES_DIR)
    end
    addOperation(fs.combine(dir, "apps"), APPS_DIR)
    addOperation(fs.combine(dir, "trash"), TRASH_DIR)
    if #operations == 0 then return false, "The backup contains no restorable data" end

    -- Stage every item before replacing anything. This makes a bad/corrupt backup
    -- fail without leaving the live installation half-restored.
    for _, op in ipairs(operations) do
        op.temporary = op.target .. ".restore_new"
        op.previous = op.target .. ".restore_previous"
        op.hadOriginal = fs.exists(op.target)
        if fs.exists(op.previous) then
            if not fs.exists(op.target) then
                local recovered, recoverErr = pcall(fs.move, op.previous, op.target)
                if not recovered then return false, "Unable to recover " .. op.target .. ": " .. tostring(recoverErr) end
            else pcall(fs.delete, op.previous) end
        end
        if fs.exists(op.temporary) then pcall(fs.delete, op.temporary) end
        local copied, copyErr = pcall(fs.copy, op.source, op.temporary)
        if not copied then
            for _, staged in ipairs(operations) do if staged.temporary and fs.exists(staged.temporary) then pcall(fs.delete, staged.temporary) end end
            return false, "Unable to stage " .. op.source .. ": " .. tostring(copyErr)
        end
    end

    local journalOk, journalErr = writeTable(RESTORE_JOURNAL, { version = OS_VERSION, operations = operations })
    if not journalOk then
        for _, staged in ipairs(operations) do if fs.exists(staged.temporary) then pcall(fs.delete, staged.temporary) end end
        return false, "Unable to create the restore journal: " .. tostring(journalErr)
    end

    local applied = {}
    local function rollbackOperation(op)
        if fs.exists(op.target) then pcall(fs.delete, op.target) end
        if op.hadOriginal and fs.exists(op.previous) then pcall(fs.move, op.previous, op.target) end
        if fs.exists(op.temporary) then pcall(fs.delete, op.temporary) end
    end

    for _, op in ipairs(operations) do
        if op.hadOriginal then
            local movedOld, oldErr = pcall(fs.move, op.target, op.previous)
            if not movedOld then
                for i = #applied, 1, -1 do rollbackOperation(applied[i]) end
                for _, staged in ipairs(operations) do if fs.exists(staged.temporary) then pcall(fs.delete, staged.temporary) end end
                pcall(fs.delete, RESTORE_JOURNAL)
                return false, "Unable to preserve " .. op.target .. ": " .. tostring(oldErr)
            end
        end
        local movedNew, newErr = pcall(fs.move, op.temporary, op.target)
        if not movedNew then
            rollbackOperation(op)
            for i = #applied, 1, -1 do rollbackOperation(applied[i]) end
            for _, staged in ipairs(operations) do if fs.exists(staged.temporary) then pcall(fs.delete, staged.temporary) end end
            pcall(fs.delete, RESTORE_JOURNAL)
            return false, "Unable to restore " .. op.target .. ": " .. tostring(newErr)
        end
        applied[#applied + 1] = op
    end

    -- Deleting the journal commits the transaction. Any crash before this point
    -- rolls back on the next boot; a crash after it leaves a complete restore.
    local committed, commitErr = pcall(fs.delete, RESTORE_JOURNAL)
    if not committed then
        for i = #applied, 1, -1 do rollbackOperation(applied[i]) end
        return false, "Unable to commit the restore: " .. tostring(commitErr)
    end
    for _, op in ipairs(applied) do if fs.exists(op.previous) then pcall(fs.delete, op.previous) end end
    logEvent("BACKUP", "Restored " .. dir)
    return true
end

local function backupList()
    local names = {}
    local listOk, backupNames = pcall(fs.list, BACKUP_DIR)
    for _, name in ipairs(listOk and backupNames or {}) do
        local path = fs.combine(BACKUP_DIR, name)
        if fs.isDir(path) and fs.exists(fs.combine(path, "manifest.db")) then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return a > b end)
    return names
end

local function recoveryApp()
    while true do
        local action = menuSelect("Recovery Tools", {
            "Create backup", "Restore backup", "Reset settings", "Clear boot failure flag",
            "Clear system log", "Open CraftOS shell", "Return",
        })
        if action == 1 then
            local ok, result = createBackup("manual")
            showMessage(ok and "Backup created" or "Backup failed", tostring(result))
        elseif action == 2 then
            local names = backupList()
            if #names == 0 then showMessage("Restore backup", "No backup folders were found.")
            else
                local choice = menuSelect("Restore backup", names)
                if choice and confirm("Restore backup", "Restore " .. names[choice] .. " and reboot? Current settings and user files will be replaced.") then
                    local safeOk, safeResult = createBackup("before_restore")
                    if not safeOk then showMessage("Restore cancelled", "Safety backup failed: " .. tostring(safeResult))
                    else
                        local ok, err = restoreBackup(fs.combine(BACKUP_DIR, names[choice]))
                        if ok then if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end os.reboot()
                        else showMessage("Restore failed", tostring(err)) end
                    end
                end
            end
        elseif action == 3 then
            if confirm("Reset settings", "Reset McOS settings but keep user files?") then
                config = deepCopy(defaults)
                saveConfig()
                if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end
                os.reboot()
            end
        elseif action == 4 then
            if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end
            showMessage("Recovery", "Boot failure flag cleared.")
        elseif action == 5 then
            if confirm("Clear system log", "Delete the current system log?") then if fs.exists(LOG_FILE) then fs.delete(LOG_FILE) end end
        elseif action == 6 then runOnComputer("shell")
        else return end
    end
end

local externalApps = {}
local externalAppsDirty = true
local api = {
    version = OS_VERSION,
    notify = notify,
    message = showMessage,
    input = inputBox,
    confirm = confirm,
    run = runOnComputer,
    getTheme = T,
    getUserDir = function() return USER_DIR end,
    getDisplayMode = function() return displayMode end,
}

local function loadExternalApps(force)
    if not force and not externalAppsDirty then return end
    externalApps = {}
    externalAppsDirty = false
    local listOk, names = pcall(fs.list, APPS_DIR)
    names = listOk and names or {}
    table.sort(names)
    local usedIds = {}
    for _, name in ipairs(names) do
        if name:lower():match("%.lua$") then
            local path = fs.combine(APPS_DIR, name)
            local fn, err = loadfile(path, "t", _ENV)
            if fn then
                local ok, app = pcall(fn, api)
                if ok and type(app) == "table" and type(app.run) == "function" then
                    local id = tostring(app.id or ("ext_" .. name:gsub("%.lua$", ""))):gsub("[^%w_%-]", "_"):sub(1, 48)
                    if id == "" then id = "ext_app" end
                    if usedIds[id] then id = id .. "_" .. #externalApps + 1 end
                    usedIds[id] = true
                    app.id = id
                    app.name = tostring(app.name or fs.getName(path)):sub(1, 40)
                    app.icon = tostring(app.icon or "APP"):sub(1, 5)
                    app.category = tostring(app.category or "Custom"):sub(1, 24)
                    app.externalPath = path
                    externalApps[#externalApps + 1] = app
                else logEvent("APP_LOAD", name .. ": " .. tostring(app)) end
            else logEvent("APP_LOAD", name .. ": " .. tostring(err)) end
        end
    end
end

local function runExternalApp(app)
    local ok, err = pcall(app.run, api)
    if not ok then
        logEvent("APP_ERROR", app.name .. ": " .. tostring(err))
        notify(app.name .. " crashed", tostring(err), "error")
        showMessage("Application error", app.name .. " crashed:\n" .. tostring(err))
    end
end

local function appStore()
    while true do
        loadExternalApps()
        local items = {}
        for _, app in ipairs(externalApps) do items[#items + 1] = app.name .. "  (installed)" end
        items[#items + 1] = "<Install app from HTTPS URL>"
        items[#items + 1] = "<Refresh app list>"
        items[#items + 1] = "<Open apps folder>"
        local choice = menuSelect("McStore", items, "Apps are local Lua packages. Only install code you trust.")
        if not choice then return end
        if choice <= #externalApps then
            local app = externalApps[choice]
            local action = menuSelect(app.name, { "Run", "Uninstall", "View source" })
            if action == 1 then runExternalApp(app)
            elseif action == 2 and confirm("Uninstall app", app.name .. "?") then
                local ok, err = pcall(fs.delete, app.externalPath)
                if not ok then showMessage("Uninstall failed", tostring(err)) else externalAppsDirty = true end
            elseif action == 3 then viewFile(app.externalPath) end
        elseif choice == #externalApps + 1 then
            if not http or type(http.get) ~= "function" then showMessage("McStore", "HTTP is disabled in the server configuration.")
            else
                local name = inputBox("Install app", "Local app name:")
                local url = inputBox("Install app", "Direct HTTPS URL:")
                if name and url and name ~= "" and url ~= "" then
                    if not url:lower():match("^https://") then showMessage("Install failed", "McStore accepts HTTPS URLs only.")
                    else
                        name = safeName(name, "app")
                        if not name:lower():match("%.lua$") then name = name .. ".lua" end
                        local path = canonicalPath(fs.combine(APPS_DIR, name))
                        if fs.exists(path) and not confirm("Replace app", fs.getName(path) .. " already exists. Replace it?") then
                            -- cancelled
                        else
                            local okGet, response = pcall(http.get, url, nil, true)
                            if not okGet or not response then showMessage("Install failed", tostring(response or "HTTP request failed"))
                            else
                                local okRead, data = pcall(function()
                                    local chunks, total = {}, 0
                                    while true do
                                        local chunk = response.read(8192)
                                        if not chunk then break end
                                        total = total + #chunk
                                        if total > 262144 then error("App source exceeds the 256 KB limit.", 0) end
                                        chunks[#chunks + 1] = chunk
                                    end
                                    return table.concat(chunks)
                                end)
                                pcall(response.close)
                                if not okRead then showMessage("Install failed", tostring(data))
                                else
                                    local fn, syntaxError = load(data, "@" .. path, "t", _ENV)
                                    if not fn then showMessage("Install failed", "Lua syntax error:\n" .. tostring(syntaxError))
                                    else
                                        local writeOk, writeErr = writeAll(path, data)
                                        if writeOk then
                                            externalAppsDirty = true
                                            notify("McStore", "Installed " .. fs.getName(path), "info")
                                            local publicUrl = url:gsub("[?#].*$", "")
                                            logEvent("STORE", "Installed " .. path .. " from " .. publicUrl:sub(1, 160))
                                        else showMessage("Install failed", tostring(writeErr)) end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        elseif choice == #externalApps + 2 then
            externalAppsDirty = true
            loadExternalApps(true)
        else fileManager(APPS_DIR) externalAppsDirty = true end
    end
end

local function aboutApp()
    local host = _HOST or "CC:Tweaked"
    showMessage("About McOS", {
        OS_NAME .. " " .. OS_VERSION,
        "A modular desktop environment for CC:Tweaked.",
        "Computer ID: " .. os.getComputerID(),
        "Computer label: " .. tostring(os.getComputerLabel() or "Unnamed"),
        "User: " .. config.username,
        "Host: " .. host,
        "Display: " .. displayMode,
        "Core: " .. SYSTEM_DIR .. "/main.lua",
        "Apps: " .. APPS_DIR,
        "User data: " .. USER_DIR,
    })
end

local function startupGuide(force)
    if config.guideCompleted and not force then return end
    local pages = {
        { "Welcome to McOS 1.0", "McOS is a modular desktop for CC:Tweaked. Use arrow keys, Enter and the mouse. On an Advanced Monitor, right-click buttons to use the touch interface." },
        { "Desktop and taskbar", "Open pinned apps from the desktop. The Start menu contains every built-in and installed app. The taskbar shows notifications and time. Apps return to the desktop with Esc or Backspace." },
        { "Files", "The file manager supports copy, cut, paste, rename, scoped recursive search, sorting, favorites, navigation history and a protected Recycle Bin. Text editing still uses the computer keyboard." },
        { "Automation", "Redstone Center supports analog outputs, pulses, delayed actions, reusable scenes, bundled redstone and validated input-to-output automation rules." },
        { "McNet", "Connect a modem to discover other McOS computers. Messages and inbox history are saved. Remote redstone and program launch require both a trusted device and the matching permission in Settings." },
        { "Safety and recovery", "McOS stores logs, notifications and backups under /mcos. Recovery Tools can restore full user/app backups. A PIN is a convenience lock, not protection against direct disk access." },
    }
    local page = 1
    while true do
        clearScreen(T().desktop)
        drawChrome("Getting Started")
        local w, h = size()
        centerText(4, pages[page][1], T().dark, T().desktop)
        local lines = wrapText(pages[page][2], math.max(12, w - 8))
        local y = 7
        for _, line in ipairs(lines) do if y >= h - 5 then break end centerText(y, line, T().dark, T().desktop) y = y + 1 end
        centerText(h - 4, string.format("Page %d/%d", page, #pages), T().dark, T().desktop)
        local third = math.max(6, math.floor((w - 2) / 3))
        local back = drawButton(2, h - 2, math.min(w - 1, 1 + third), h - 2, page == 1 and "Skip" or "Back", false)
        local skip = drawButton(2 + third, h - 2, math.min(w - 1, 1 + third * 2), h - 2, "Skip", false)
        local nextButton = drawButton(2 + third * 2, h - 2, w - 1, h - 2, page == #pages and "Finish" or "Next", true)
        local function finish()
            config.guideCompleted = true
            saveConfig()
            return true
        end
        local e, a, b, c = pullUiEvent()
        if e == "key" then
            if a == keys.left then page = math.max(1, page - 1)
            elseif a == keys.right then page = math.min(#pages, page + 1)
            elseif a == keys.enter or a == keys.space then if page == #pages then finish() return else page = page + 1 end
            elseif a == keys.s or a == keys.q or a == keys.escape then finish() return end
        elseif e == "mouse_click" then
            if inBox(b, c, skip) then finish() return
            elseif inBox(b, c, back) then if page == 1 then finish() return else page = page - 1 end
            elseif inBox(b, c, nextButton) then if page == #pages then finish() return else page = page + 1 end end
        end
    end
end

local function settingsApp()
    while true do
        local items = {
            "Theme: " .. config.theme,
            "Clock: " .. (config.showClock and "On" or "Off"),
            "Power confirmations: " .. (config.confirmPower and "On" or "Off"),
            "Username: " .. config.username,
            "PIN lock: " .. (config.pinHash and "Enabled" or "Disabled"),
            "Remote redstone: " .. (config.allowRemoteRedstone and "Enabled" or "Disabled"),
            "Remote program launch: " .. (config.allowRemoteRun and "Enabled" or "Disabled"),
            "Trusted McNet devices: " .. tostring((function() local n = 0 for _ in pairs(config.trustedPeers) do n = n + 1 end return n end)()),
            "Touch scale: " .. tostring(config.monitorScale),
            "Open touch display on boot: " .. (config.autoTouchDisplay and "Yes" or "No"),
            "Open startup guide",
            "Show guide on next boot",
            "Create backup",
            "Recovery tools",
            "Switch display",
        }
        local choice = menuSelect("Settings", items)
        if not choice then return end
        if choice == 1 then
            local index = 1 for i, name in ipairs(themeOrder) do if name == config.theme then index = i break end end
            config.theme = themeOrder[index % #themeOrder + 1]
            saveConfig()
        elseif choice == 2 then config.showClock = not config.showClock saveConfig()
        elseif choice == 3 then config.confirmPower = not config.confirmPower saveConfig()
        elseif choice == 4 then
            local name = inputBox("Username", "New username:")
            if name and name ~= "" then config.username = name:gsub("[%z\1-\31]", ""):sub(1, 24) saveConfig() end
        elseif choice == 5 then
            if config.pinHash then
                if confirm("PIN lock", "Disable the PIN lock?") then config.pinHash = nil saveConfig() end
            else
                local pin = inputBox("Set PIN", "New PIN:", true)
                local again = pin and inputBox("Set PIN", "Repeat PIN:", true) or nil
                if pin and #pin >= 4 and #pin <= 32 and pin == again then config.pinHash = hashPin(pin) saveConfig()
                else showMessage("PIN", "PINs must match and contain 4-32 characters.") end
            end
        elseif choice == 6 then
            if not config.allowRemoteRedstone then
                if confirm("Remote redstone", "Enable remote redstone for trusted McNet devices only?") then config.allowRemoteRedstone = true saveConfig() end
            else config.allowRemoteRedstone = false saveConfig() end
        elseif choice == 7 then
            if not config.allowRemoteRun then
                if confirm("Remote program launch", "Trusted devices will be able to request local programs to run. Enable it?") then config.allowRemoteRun = true saveConfig() end
            else config.allowRemoteRun = false saveConfig() end
        elseif choice == 8 then
            local ids = {}
            for id in pairs(config.trustedPeers) do ids[#ids + 1] = tostring(id) end
            table.sort(ids)
            if #ids == 0 then showMessage("Trusted devices", "No McNet devices are trusted.")
            else
                local list = {} for _, id in ipairs(ids) do list[#list + 1] = "#" .. id end
                list[#list + 1] = "<Remove all trusted devices>"
                local selected = menuSelect("Trusted devices", list, "Select a device to remove trust")
                if selected then
                    if selected == #list then
                        if confirm("Trusted devices", "Remove trust from every device?") then config.trustedPeers = {} saveConfig() end
                    else config.trustedPeers[ids[selected]] = nil saveConfig() end
                end
            end
        elseif choice == 9 then
            local values = { 0.5, 1, 1.5, 2, 2.5, 3, 4, 5 }
            local index = 1 for i, v in ipairs(values) do if v == config.monitorScale then index = i break end end
            local oldScale = config.monitorScale
            config.monitorScale = values[index % #values + 1]
            saveConfig()
            if onTouchDisplay() and not activateMonitor(true) then
                config.monitorScale = oldScale
                saveConfig()
                activateMonitor(true)
                showMessage("Touch scale", "That scale makes the monitor too small for McOS, so the previous scale was restored.")
            end
        elseif choice == 10 then config.autoTouchDisplay = not config.autoTouchDisplay saveConfig()
        elseif choice == 11 then startupGuide(true)
        elseif choice == 12 then config.guideCompleted = false saveConfig()
        elseif choice == 13 then
            local ok, result = createBackup("settings")
            showMessage(ok and "Backup created" or "Backup failed", tostring(result))
        elseif choice == 14 then recoveryApp()
        elseif choice == 15 then if onTouchDisplay() then returnToComputer() else activateMonitor(false) end end
    end
end

local apps = {}
local appById = {}
local function registerApp(id, name, icon, run, category)
    local app = { id = id, name = name, icon = icon, run = run, category = category or "System" }
    apps[#apps + 1] = app appById[id] = app
end

registerApp("files", "Files", "DIR", fileManager, "System")
registerApp("terminal", "Terminal", ">_", terminalApp, "System")
registerApp("programs", "Programs", "RUN", programLauncher, "System")
registerApp("redstone", "Redstone Center", "RS", redstoneApp, "Automation")
registerApp("peripherals", "Peripheral Manager", "IO", peripheralManager, "Automation")
registerApp("mcnet", "McNet", "NET", mcnetApp, "Network")
registerApp("notifications", "Notifications", "!", notificationsApp, "System")
registerApp("calculator", "Calculator", "123", calculatorApp, "Accessories")
registerApp("notes", "Notes", "TXT", notesApp, "Accessories")
registerApp("clock", "Clock & Timers", "CLK", clockApp, "Accessories")
registerApp("paint", "Paint", "ART", paintApp, "Accessories")
registerApp("music", "Music Player", "MUS", musicApp, "Accessories")
registerApp("printer", "Printer Center", "PRN", printerApp, "Devices")
registerApp("inventory", "Inventory Viewer", "INV", inventoryApp, "Devices")
registerApp("turtle", "Turtle Control", "TUR", turtleApp, "Devices")
registerApp("tasks", "System Monitor", "CPU", taskManagerApp, "System")
registerApp("logs", "System Log", "LOG", logsApp, "System")
registerApp("store", "McStore", "GET", appStore, "System")
registerApp("recovery", "Recovery Tools", "FIX", recoveryApp, "System")
registerApp("settings", "Settings", "CFG", settingsApp, "System")
registerApp("about", "About McOS", "?", aboutApp, "System")

local function refreshApps()
    loadExternalApps()
    local combined = {}
    for _, app in ipairs(apps) do combined[#combined + 1] = app end
    for _, app in ipairs(externalApps) do combined[#combined + 1] = app end
    return combined
end

local function runApp(app)
    if not app then return end
    currentApp = tostring(app.id or "app")
    logEvent("APP", "Opened " .. tostring(app.name or currentApp))
    local ok, err = pcall(app.run, api)
    if displayMode == "monitor" and activeMonitor then pcall(term.redirect, activeMonitor)
    elseif displayMode == "computer" then pcall(term.redirect, nativeTerminal) end
    if not ok then
        logEvent("APP_ERROR", tostring(app.name) .. ": " .. tostring(err))
        notify(tostring(app.name) .. " crashed", tostring(err), "error")
        showMessage("Application error", tostring(app.name) .. " crashed:\n" .. tostring(err))
    end
    currentApp = "desktop"
    processServices()
end

local function startMenu()
    local combined = refreshApps()
    table.sort(combined, function(a, b) return a.name:lower() < b.name:lower() end)
    local items = {} for _, app in ipairs(combined) do items[#items + 1] = app.name .. "  [" .. (app.category or "App") .. "]" end
    items[#items + 1] = "Lock"
    items[#items + 1] = "Switch display"
    items[#items + 1] = "Reboot"
    items[#items + 1] = "Shut down"
    local choice = menuSelect("Start", items, "All apps and power controls")
    if not choice then return end
    if choice <= #combined then runApp(combined[choice])
    elseif choice == #combined + 1 then lockRequested = true
    elseif choice == #combined + 2 then if onTouchDisplay() then returnToComputer() else activateMonitor(false) end
    elseif choice == #combined + 3 then if not config.confirmPower or confirm("Reboot", "Reboot McOS?") then fs.delete(BOOT_FLAG) os.reboot() end
    elseif choice == #combined + 4 then if not config.confirmPower or confirm("Shut down", "Shut down the computer?") then fs.delete(BOOT_FLAG) os.shutdown() end end
end

local function searchApps()
    local query = inputBox("Search apps", "App name contains:")
    if not query or query == "" then return end
    query = query:lower()
    local matches = {}
    for _, app in ipairs(refreshApps()) do if app.name:lower():find(query, 1, true) then matches[#matches + 1] = app end end
    local labels = {} for _, app in ipairs(matches) do labels[#labels + 1] = app.name end
    local choice = menuSelect("Search results", labels)
    if choice then runApp(matches[choice]) end
end

local function drawDesktop()
    clearScreen(T().desktop)
    drawChrome("Desktop", "Click an icon | Start: all apps | F: files | N: McNet | R: redstone | /: search")
    local w, h = size()
    centerText(3, "Welcome, " .. config.username, T().dark, T().desktop)
    local columns = math.max(2, math.floor(w / 16))
    local cellW = math.floor((w - 2) / columns)
    local boxes = {}
    local index = 0
    for _, id in ipairs(config.desktopPins) do
        local app = appById[id]
        if app then
            index = index + 1
            local col = (index - 1) % columns
            local row = math.floor((index - 1) / columns)
            local x1 = 2 + col * cellW
            local y1 = 5 + row * 4
            if y1 + 2 < h - 1 then
                local x2 = math.min(w - 1, x1 + cellW - 2)
                fill(x1, y1, x2, y1 + 2, T().panel)
                centerText(y1, "")
                local icon = "[" .. app.icon .. "]"
                writeAt(x1 + math.max(0, math.floor((x2 - x1 + 1 - #icon) / 2)), y1, icon, T().text, T().panel)
                local label = clip(app.name, x2 - x1 - 1)
                writeAt(x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2)), y1 + 1, label, T().text, T().panel)
                boxes[#boxes + 1] = { app = app, x1 = x1, y1 = y1, x2 = x2, y2 = y1 + 2 }
            end
        end
    end
    return boxes
end

local function lockScreen()
    if not config.pinHash and not lockRequested then return true end
    lockRequested = false
    local attempts = 0
    while true do
        clearScreen(T().panel)
        local w, h = size()
        centerText(math.max(2, math.floor(h / 2) - 3), OS_NAME .. " 1.0", T().text, T().panel)
        centerText(math.max(3, math.floor(h / 2) - 1), config.username, T().text, T().panel)
        centerText(math.floor(h / 2) + 1, config.pinHash and "Press Enter to unlock" or "Press any key", colors.lightGray, T().panel)
        local e, a = pullUiEvent(nil, true)
        if e == "terminate" then return false end
        if e == "key" or e == "mouse_click" then
            if not config.pinHash then return true end
            local pin = inputBox("Unlock McOS", "PIN:", true)
            if hashPin(pin or "") == config.pinHash then logEvent("AUTH", "Unlocked") return true end
            attempts = attempts + 1 sound("error")
            if attempts >= 3 then
                local delay = os.startTimer(2)
                while true do local de, da = pullUiEvent(nil, true) if de == "timer" and da == delay then break end end
                attempts = 0
            end
        end
    end
end

local function bootAnimation()
    clearScreen(colors.black)
    local _, h = size()
    centerText(math.max(2, math.floor(h / 2) - 1), "McOS", colors.white, colors.black)
    centerText(math.floor(h / 2) + 1, "Starting services...", colors.lightGray, colors.black)
    for i = 1, 3 do
        centerText(math.floor(h / 2) + 3, string.rep("#", i * 5), colors.cyan, colors.black)
        if not cooperativeDelay(0.15) then break end
    end
end

local function desktopLoop()
    if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end
    while true do
        if lockRequested then if not lockScreen() then return end end
        if #remoteQueue > 0 then executeRemoteJob() end
        local boxes = drawDesktop()
        local e, a, b, c = pullUiEvent(nil, true)
        if e == "terminate" then
            if confirm("Exit McOS", "Exit to CraftOS?") then return end
        elseif e == "key" then
            if a == keys.f then runApp(appById.files)
            elseif a == keys.n then runApp(appById.mcnet)
            elseif a == keys.r then runApp(appById.redstone)
            elseif a == keys.slash then searchApps()
            elseif a == keys.enter or a == keys.s then startMenu()
            elseif a == keys.l then lockRequested = true end
        elseif e == "mouse_click" then
            local x, y = b, c
            local w, h = size()
            if y == h and x <= 8 then startMenu()
            elseif y == h and x >= math.max(1, w - 24) and x < math.max(1, w - 8) then runApp(appById.notifications)
            else for _, box in ipairs(boxes) do if inBox(x, y, box) then runApp(box.app) break end end end
        elseif e == "term_resize" then
            -- redraw
        end
    end
end

local function bootRecoveryCheck()
    if fs.exists(BOOT_FLAG) then
        returnToComputer()
        local choice = menuSelect("McOS Recovery", { "Start McOS normally", "Open Recovery Tools", "Open CraftOS shell", "Exit McOS" }, "The previous boot did not finish cleanly")
        if choice == 2 then recoveryApp()
        elseif choice == 3 then runOnComputer("shell")
        elseif choice == 4 or not choice then return false end
    end
    local ok, err = writeAll(BOOT_FLAG, tostring(nowMs()))
    if not ok then error("Unable to create boot status file: " .. tostring(err), 0) end
    return true
end

local function main()
    if not term.isColor() then error("McOS requires an Advanced Computer.", 0) end
    if not bootRecoveryCheck() then return end
    if config.autoTouchDisplay then activateMonitor(true) end
    bootAnimation()
    startupGuide(false)
    if not lockScreen() then
        if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end
        returnToComputer()
        return
    end
    notify("McOS 1.0", "System started successfully.", "info")
    logEvent("BOOT", "McOS " .. OS_VERSION .. " started")
    desktopLoop()
    if fs.exists(BOOT_FLAG) then fs.delete(BOOT_FLAG) end
    returnToComputer()
    clearScreen(colors.black)
    term.setTextColor(colors.white)
    print("McOS closed. Type 'reboot' to start it again.")
end

local ok, err = pcall(main)
if not ok then
    pcall(returnToComputer)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.red)
    term.clear()
    term.setCursorPos(1, 1)
    print("McOS 1.0 fatal error:")
    print(tostring(err))
    logEvent("FATAL", tostring(err))
    pcall(writeAll, BOOT_FLAG, "fatal: " .. tostring(err))
    print("\nThe recovery screen will appear on the next boot.")
end
