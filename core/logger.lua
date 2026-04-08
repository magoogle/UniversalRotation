-- ============================================================
--  core/logger.lua  —  Debug file logger for UniversalRotation
--  Writes timestamped lines to universal_rotation_debug.log
--  in the script root folder.
--  Only logs when data changes — repeated identical messages
--  are suppressed and a count is written when the message changes.
-- ============================================================

local logger = {}

local _file = nil
local _enabled = false
local _path = nil
local _last_msg = nil
local _repeat_count = 0

local function _get_script_root()
    local root = string.gmatch(package.path, '.*?\\?')()
    return root and root:gsub('?', '') or ''
end

function logger.enable()
    if _file then return end
    _path = _get_script_root() .. 'universal_rotation_debug.log'
    local f = io.open(_path, 'w')
    if f then
        _file = f
        _enabled = true
        _last_msg = nil
        _repeat_count = 0
        f:write(string.format('[%s] Logger started\n', os.date('%Y-%m-%d %H:%M:%S')))
        f:flush()
    end
end

function logger.disable()
    if _file then
        pcall(function() _file:close() end)
        _file = nil
    end
    _enabled = false
end

local function _get_time()
    local t = 0
    pcall(function() t = get_time_since_inject() end)
    return t
end

local function _flush_repeat()
    if _repeat_count > 0 and _file then
        _file:write(string.format('[%.2f]   ... repeated %dx\n', _get_time(), _repeat_count))
    end
    _repeat_count = 0
end

function logger.log(msg)
    if not _enabled or not _file then return end
    msg = tostring(msg)

    if msg == _last_msg then
        _repeat_count = _repeat_count + 1
        return
    end

    -- New message — flush any pending repeat count, then write
    _flush_repeat()
    _last_msg = msg
    _file:write(string.format('[%.2f] %s\n', _get_time(), msg))
    _file:flush()
end

function logger.is_enabled()
    return _enabled
end

return logger
