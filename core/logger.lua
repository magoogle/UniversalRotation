-- ============================================================
--  core/logger.lua  —  Debug file logger for UniversalRotation
--  Writes timestamped lines to universal_rotation_debug.log
--  in the script root folder.
-- ============================================================

local logger = {}

local _file = nil
local _enabled = false
local _path = nil

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

function logger.log(msg)
    if not _enabled or not _file then return end
    local t = 0
    pcall(function() t = get_time_since_inject() end)
    _file:write(string.format('[%.2f] %s\n', t, tostring(msg)))
    _file:flush()
end

function logger.is_enabled()
    return _enabled
end

return logger
