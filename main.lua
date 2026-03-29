local plugin_label = 'magoogles_universal_rotation'

local gui             = require 'gui'
local spell_config    = require 'core.spell_config'
local spell_tracker   = require 'core.spell_tracker'
local rotation_engine = require 'core.rotation_engine'
local profile_io      = require 'core.profile_io'
local buff_provider    = require 'core.buff_provider'

local equipped_ids  = {}   -- spell IDs currently on bar
local all_known_ids = {}   -- union of all ever-seen IDs (persists through bar swaps)
local all_known_set = {}

local scan_interval = 2.0  -- re-scan bar every 2 seconds
local last_scan     = -999

local last_class_key = nil

local settings = {
    scan_range       = 16.0,
    anim_delay       = 0.05,
    debug            = false,
    overlay_enabled  = true,
    overlay_x        = 20,
    overlay_y        = 12,
    overlay_show_buffs = false,
}

local function is_enabled()
    if not gui.elements.enabled:get() then return false end
    if gui.elements.use_keybind:get() then
        local key   = gui.elements.keybind:get_key()
        local state = gui.elements.keybind:get_state()
        if key == 0x0A then return false end      -- not bound yet
        if state ~= 1 and state ~= true then return false end
    end
    return true
end

local function refresh_equipped()
    local now = get_time_since_inject()
    if now - last_scan < scan_interval then return end
    last_scan = now

    local ids = get_equipped_spell_ids()
    if not ids then equipped_ids = {}; return end

    equipped_ids = {}
    for _, id in ipairs(ids) do
        if id and id > 1 then
            table.insert(equipped_ids, id)
            if not all_known_set[id] then
                all_known_set[id] = true
                table.insert(all_known_ids, id)
            end
        end
    end
end

local function update_settings()
    settings.scan_range = gui.elements.scan_range:get()
    settings.anim_delay = gui.elements.anim_delay:get()
    settings.debug           = gui.elements.debug_mode:get()
    settings.overlay_enabled = gui.elements.overlay_enabled:get()
    settings.overlay_x       = gui.elements.overlay_x:get()
    settings.overlay_y       = gui.elements.overlay_y:get()
    settings.overlay_show_buffs = gui.elements.overlay_show_buffs and gui.elements.overlay_show_buffs:get() or false
    rotation_engine.set_scan_range(settings.scan_range)
end

local function _pretty_spell_name(raw)
    if not raw or raw == '' then return nil end
    raw = tostring(raw)
    local bracket = raw:match('%[([^%]]+)%]')
    if bracket and bracket ~= '' then raw = bracket end
    raw = raw:gsub('%s*ID%s*=%s*%d+.*$', '')
    raw = raw:gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local parts = {}
    for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
    if #parts >= 2 then table.remove(parts, 1) end
    local phrase = table.concat(parts, ' ')
    phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
    return phrase
end


local function get_script_root()
    local root = string.gmatch(package.path, '.*?\\?')()
    return root and root:gsub('?', '') or ''
end

local function _set_element(el, val)
    if not el then return end
    if type(el.set) == 'function' then pcall(el.set, el, val); return end
    if type(el.set_value) == 'function' then pcall(el.set_value, el, val); return end
end

local function _class_key()
    local lp = get_local_player()
    if not lp or type(lp.get_character_class_id) ~= 'function' then return 'unknown' end
    local ok, cid = pcall(lp.get_character_class_id, lp)
    cid = ok and cid or nil
    local map = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [2] = 'druid',
        [3] = 'rogue',
        [6] = 'necromancer',
        [9] = 'paladin',
    }
    if cid ~= nil and map[cid] then return map[cid] end
    return 'class_' .. tostring(cid or 'unknown')
end

local function _profile_path_for(class_key)
    return get_script_root() .. 'universal_rotation_' .. tostring(class_key) .. '.json'
end

local function _profile_path()
    return _profile_path_for(_class_key())
end

local function _export_profile(class_key)
    local data = {
        version = 1,
        class   = class_key or _class_key(),
        global  = {
            scan_range      = gui.elements.scan_range:get(),
            anim_delay      = gui.elements.anim_delay:get(),
            debug_mode      = gui.elements.debug_mode:get(),
            overlay_enabled = gui.elements.overlay_enabled:get(),
            overlay_x       = gui.elements.overlay_x:get(),
            overlay_y       = gui.elements.overlay_y:get(),
        },
        spells = {},
    }

    for _, sid in ipairs(all_known_ids) do
        data.spells[tostring(sid)] = spell_config.get(sid)
    end

    local json = profile_io.to_json(data)
    local path = _profile_path_for(class_key or _class_key())
    local ok, err = pcall(function()
        local f = assert(io.open(path, 'w'))
        f:write(json)
        f:close()
    end)

    if ok then
        console.print('[UniversalRotation] Exported profile: ' .. path)
    else
        console.print('[UniversalRotation] Export failed: ' .. tostring(err))
        console.print('[UniversalRotation] JSON (copy/paste): ' .. json)
    end
end

local function _import_profile(class_key, silent)
    local path = _profile_path_for(class_key or _class_key())
    local f = io.open(path, 'r')
    if not f then
        console.print('[UniversalRotation] Import failed: file not found: ' .. path)
        return
    end
    local json = f:read('*a')
    f:close()

    local data = profile_io.from_json(json)
    if type(data) ~= 'table' then
        console.print('[UniversalRotation] Import failed: invalid JSON')
        return
    end

    if type(data.global) == 'table' then
        _set_element(gui.elements.scan_range,      data.global.scan_range)
        _set_element(gui.elements.anim_delay,      data.global.anim_delay)
        _set_element(gui.elements.debug_mode,      data.global.debug_mode)
        _set_element(gui.elements.overlay_enabled, data.global.overlay_enabled)
        _set_element(gui.elements.overlay_x,       data.global.overlay_x)
        _set_element(gui.elements.overlay_y,       data.global.overlay_y)
    end

    if type(data.spells) == 'table' then
        for sid_str, cfg in pairs(data.spells) do
            local sid = tonumber(sid_str)
            if sid and type(cfg) == 'table' then
                spell_config.apply(sid, cfg)
                if not all_known_set[sid] then
                    all_known_set[sid] = true
                    table.insert(all_known_ids, sid)
                end
            end
        end
    end

    if not silent then
        console.print('[UniversalRotation] Imported profile: ' .. path)
    end
end

local function handle_profile_io()
    if gui.elements.export_profile and gui.elements.export_profile:get() then
        _export_profile()
        gui.elements.export_profile:set(false)
    end
    if gui.elements.import_profile and gui.elements.import_profile:get() then
        _import_profile()
        gui.elements.import_profile:set(false)
    end
end

local function handle_class_profiles()
    local ck = _class_key()
    if not last_class_key then
        last_class_key = ck
        _import_profile(ck, true)
        return
    end
    if ck ~= last_class_key then
        _export_profile(last_class_key)

        equipped_ids  = {}
        all_known_ids = {}
        all_known_set = {}
        last_scan     = -999

        last_class_key = ck
        _import_profile(ck, true)
    end
end
local function render_overlay()
    if not is_enabled() then return end

    local sw = get_screen_width()
    local sh = get_screen_height()
    if not sw or not sh then return end

    local lp = get_local_player()
    if not lp then return end

    if not settings.overlay_enabled then return end

    local x  = settings.overlay_x or (sw - 220)
    local y  = settings.overlay_y or 12
    local lh = 18
    local sz = 14

    local function line(text, col)
        graphics.text_2d(text, vec2:new(x, y), sz, col or color_white(220))
        y = y + lh
    end

    line('[ Universal Rotation ]', color_yellow(255))
    line(string.format('%d spells equipped', #equipped_ids), color_white(180))

    local shown = 0
    local now_t = get_time_since_inject()

    -- Chain boost tracking (mirror rotation_engine's internal table isn't exposed,
    -- so we read from spell_config chain fields to show a UI hint only)
    local TARGET_MODE_SHORT = { [0]='PRI', [1]='NEAR', [2]='LHP', [3]='HHP', [4]='CLV' }

    local spell_list = {}
    for _, spell_id in ipairs(equipped_ids) do
        if spell_id > 1 then
            local cfg = spell_config.get(spell_id)
            if cfg.enabled then
                table.insert(spell_list, { id = spell_id, cfg = cfg })
            end
        end
    end
    table.sort(spell_list, function(a, b) return a.cfg.priority < b.cfg.priority end)

    for _, entry in ipairs(spell_list) do
        if shown >= 8 then break end
        shown = shown + 1
        local id   = entry.id
        local cfg  = entry.cfg
        local name = _pretty_spell_name(get_name_for_spell(id)) or tostring(id)
        local ready = utility.is_spell_ready(id) and utility.is_spell_affordable(id)
        local on_cd = not spell_tracker.is_off_cooldown(id, cfg.cooldown, cfg.charges)

        local charges_left, charges_max = spell_tracker.get_charges(id, cfg.charges)
        local charge_txt = ''
        if charges_max and charges_max > 1 then
            charge_txt = string.format(' %d/%d', charges_left, charges_max)
        end

        -- Annotate target mode if non-default
        local mode_txt = ''
        if not cfg.self_cast then
            local m = cfg.target_mode or 0
            if m ~= 0 then
                mode_txt = ' [' .. (TARGET_MODE_SHORT[m] or '?') .. ']'
            end
        else
            mode_txt = ' [SELF]'
        end

        -- Resource condition hint
        local res_txt = ''
        if cfg.use_resource then
            local sym = (cfg.resource_mode == 0) and '<' or '>='
            res_txt = string.format(' res%s%d%%', sym, cfg.resource_pct or 50)
        end

        local label = string.format('[%d] %s%s%s%s',
            cfg.priority, name:sub(1, 14), charge_txt, mode_txt, res_txt)

        local col
        if not ready then
            col = color_red(200)
            label = label .. ' (N/A)'
        elseif on_cd then
            col = color_yellow(200)
            label = label .. ' (CD)'
        else
            col = color_green(255)
            label = label .. ' (RDY)'
        end
        line(label, col)
    end

    if settings.overlay_show_buffs then
        y = y + 6
        line('[ Active Buffs ]', color_white(200))

        local buffs = {}
        if buff_provider and type(buff_provider.get_active_buffs) == 'function' then
            buffs = buff_provider.get_active_buffs()
        else
            local p = get_local_player and get_local_player()
            if p and type(p.get_buffs) == 'function' then
                buffs = p:get_buffs() or {}
            end
        end

        local shown_b = 0
        for _, b in ipairs(buffs) do
            if shown_b >= 10 then break end

            local name = nil
            local stacks = 0
            local rem = nil

            if type(b) == 'table' and b.name then
                name = b.name
                stacks = b.stacks or 0
                rem = b.remaining
            else
                if type(b.name) == 'function' then name = b:name() end
                if not name and type(b.get_name) == 'function' then name = b:get_name() end
                if type(b.get_stacks) == 'function' then stacks = b:get_stacks() end
                if type(b.stacks) == 'number' then stacks = b.stacks end
                if type(b.get_remaining_time) == 'function' then rem = b:get_remaining_time() end
            end

            name = tostring(name or 'Buff')
            stacks = tonumber(stacks) or 0

            local txt = name
            if stacks > 0 then txt = txt .. string.format(' (%d)', stacks) end
            if type(rem) == 'number' and rem >= 0 then
                txt = txt .. string.format(' %.1fs', rem)
            end

            line(txt:sub(1, 34), color_white(170))
            shown_b = shown_b + 1
        end
    end

end

on_update(function()
    handle_class_profiles()
    refresh_equipped()
    update_settings()
    handle_profile_io()

    if not is_enabled() then return end

    local lp = get_local_player()
    if not lp then return end
    if lp:is_dead() then return end

    rotation_engine.tick(equipped_ids, settings)
end)

on_render_menu(function()
    gui.render(spell_config, equipped_ids, all_known_ids)
end)

on_render(function()
    render_overlay()
end)