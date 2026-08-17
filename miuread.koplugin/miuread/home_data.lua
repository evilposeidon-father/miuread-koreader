local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ReadTimeLedger = require("miuread.read_time_ledger")
local TimeZone = require("miuread.timezone")

local HomeData = {}
local stats_cache

-- Days since 1970-01-01 for a civil date; timezone-independent pure math.
local function days_from_civil(year, month, day)
    year = tonumber(year) or 1970
    month = tonumber(month) or 1
    day = tonumber(day) or 1
    year = year - (month <= 2 and 1 or 0)
    local era = math.floor(year / 400)
    local yoe = year - era * 400
    local mp = month + (month > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
local device_cache

local function clamp_number(value, minimum, maximum)
    value = tonumber(value) or 0
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

-- Single duration formatter: the ledger and the local statistics card share
-- one implementation (backend wrap-up review).
function HomeData.format_duration(seconds)
    return ReadTimeLedger.format(seconds)
end

function HomeData.reading_stats(force)
    local now = os.time()
    if not force and stats_cache and now - stats_cache.at < 30 then
        return stats_cache.value
    end

    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if lfs.attributes(path, "mode") ~= "file" then
        stats_cache = {at = now, value = nil}
        return nil
    end

    local ok, value = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(path, "ro")
        local result
        local query_ok, query_error = pcall(function()
            conn:exec("PRAGMA busy_timeout=180;")
            -- Day/week boundaries follow the MiuRead display timezone, not the
            -- process TZ (Kindle systems are typically UTC; os.date would put
            -- early-morning Shanghai reading into "yesterday", making 今日 0).
            local time_display = {}
            local ok_td, td = pcall(function()
                local Store = require("miuread.store")
                return Store:new():preferences().time_display
            end)
            if ok_td and type(td) == "table" then time_display = td end
            local offset_min = tonumber(TimeZone.offset_minutes(time_display, now)) or 0
            if offset_min == 0 and (time_display.mode or "device") == "device" then
                -- device mode on a UTC host (Kindle systems are typically UTC):
                -- fall back to the configured zone offset so 今日 follows the
                -- user's clock instead of the UTC calendar day.
                offset_min = tonumber(time_display.offset_minutes) or 0
            end
            -- Display-zone local calendar via the UTC interpretation of
            -- (now + offset); the day/week boundary then uses pure civil
            -- arithmetic so the process TZ can never skew it.
            local ld = os.date("!*t", now + offset_min * 60)
            local day_start = days_from_civil(ld.year, ld.month, ld.day) * 86400
                - offset_min * 60
            -- wday: 1=Sunday..7=Saturday; Monday-anchored week.
            local days_back = (ld.wday + 5) % 7
            local week_start = day_start - days_back * 86400
            local statement = conn:prepare([[
                SELECT COALESCE(SUM(duration), 0),
                       COUNT(DISTINCT (id_book || ':' || page))
                  FROM page_stat_data
                 WHERE start_time >= ?
            ]])
            local today = statement:bind(day_start):step()
            statement:clearbind():reset()
            local week = statement:bind(week_start):step()
            statement:close()
            local week_pages_statement = conn:prepare([[
                SELECT COUNT(DISTINCT (id_book || ':' || page))
                  FROM page_stat_data
                 WHERE start_time >= ?
            ]])
            local week_pages_row = week_pages_statement:bind(week_start):step()
            week_pages_statement:close()
            result = {
                today_seconds = tonumber(today and today[1]) or 0,
                today_pages = tonumber(today and today[2]) or 0,
                week_seconds = tonumber(week and week[1]) or 0,
                week_pages = tonumber(week_pages_row and week_pages_row[1]) or 0,
            }
        end)
        conn:close()
        if not query_ok then error(query_error) end
        return result
    end)

    if not ok then
        logger.warn("[MiuRead][Home] reading statistics unavailable", tostring(value))
        value = nil
    end
    stats_cache = {at = now, value = value}
    return value
end

function HomeData.invalidate_device_state()
    device_cache = nil
end

function HomeData.cached_device_state()
    return device_cache and device_cache.value or nil
end

function HomeData.quick_device_state(force)
    local now = os.time()
    if not force and device_cache and now - device_cache.at < 60 then
        return device_cache.value
    end
    local state = {online = nil, wifi_on = nil, wifi_name = nil, battery = nil, charging = false}
    local ok_power, power = pcall(Device.getPowerDevice, Device)
    if ok_power and power then
        if type(power.getCapacity) == "function" then
            local ok, capacity = pcall(power.getCapacity, power)
            if ok and tonumber(capacity) then state.battery = clamp_number(capacity, 0, 100) end
        end
        if type(power.isCharging) == "function" then
            local ok, charging = pcall(power.isCharging, power)
            if ok then state.charging = charging == true end
        end
    end
    local ok_network, network = pcall(require, "ui/network/manager")
    if ok_network and network then
        if type(network.isWifiOn) == "function" then
            local ok, value = pcall(network.isWifiOn, network)
            if ok then state.wifi_on = value == true end
        end
        if type(network.isOnline) == "function" then
            local ok, online = pcall(network.isOnline, network)
            if ok then state.online = online == true end
        end
        if state.wifi_on == true and type(network.getCurrentNetwork) == "function" then
            local ok, current = pcall(network.getCurrentNetwork, network)
            if ok and type(current) == "table" then
                local ssid = tostring(current.ssid or current.name or ""):gsub("^%s+", ""):gsub("%s+$", "")
                if ssid ~= "" then state.wifi_name = ssid end
            end
        end
    end
    device_cache = {at = now, value = state}
    return state
end

function HomeData.device_state(force)
    local now = os.time()
    local base = HomeData.quick_device_state(force)
    if not force and device_cache and device_cache.value.storage_checked_at
        and now - device_cache.value.storage_checked_at < 60 then
        return device_cache.value
    end

    local state = {}
    for key, value in pairs(base or {}) do state[key] = value end
    state.storage_free = state.storage_free
    state.storage_total = state.storage_total
    local ok_util, util = pcall(require, "util")
    if ok_util and util and type(util.diskUsage) == "function" then
        local drive = Device.home_dir or DataStorage:getDataDir() or "/"
        local ok, usage = pcall(util.diskUsage, drive)
        if ok and type(usage) == "table" then
            state.storage_free = tonumber(usage.available)
            state.storage_total = tonumber(usage.total)
        end
    end
    state.storage_checked_at = now
    device_cache = {at = now, value = state}
    return state
end

function HomeData.format_bytes(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return "未知" end
    local gib = bytes / 1024 / 1024 / 1024
    if gib >= 1 then return string.format("%.1f GB", gib) end
    return string.format("%.0f MB", bytes / 1024 / 1024)
end

return HomeData
