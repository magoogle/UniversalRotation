local spell_config   = require 'core.spell_config'
local spell_tracker  = require 'core.spell_tracker'
local target_selector = require 'core.target_selector'
local buff_provider   = require 'core.buff_provider'

local rotation_engine = {}

local GLOBAL_GCD     = 0.05   -- minimal delay between any two casts
local _gcd_until     = 0.0
local _scan_range    = 16.0
local _move_until    = 0.0

local function _player_has_buff(required_hash, min_stacks)
    if not required_hash or required_hash == 0 then return true end
    min_stacks = min_stacks or 1

    local player = get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return false end

    local buffs = player:get_buffs()
    if type(buffs) ~= 'table' then return false end

    for _, b in ipairs(buffs) do
        if b then
            local h = nil

            if type(b.get_name_hash) == 'function' then
                h = b:get_name_hash()
            elseif type(b.name_hash) == 'function' then
                h = b:name_hash()
            elseif type(b.name_hash) == 'number' then
                h = b.name_hash
            end

            if h == required_hash then
                local stacks = 0
                if type(b.get_stacks) == 'function' then
                    stacks = b:get_stacks()
                elseif type(b.stacks) == 'number' then
                    stacks = b.stacks
                end
                return stacks >= min_stacks
            end
        end
    end

    return false
end

local function can_act()
    local lp = get_local_player()
    if not lp then return false end
    if lp:is_dead() then return false end

    local pos = lp:get_position()
    if evade and evade.is_dangerous_position and evade.is_dangerous_position(pos) then
        return false
    end

    local active = lp:get_active_spell_id()
    local blocked = { [186139]=true, [197833]=true, [211568]=true }
    if active and blocked[active] then return false end

    local ok, mount_val = pcall(function()
        return lp:get_attribute(attributes.CURRENT_MOUNT)
    end)
    if ok and mount_val and mount_val < 0 then return false end

    return true
end

local function try_cast(spell_id, target, player_pos, anim_delay)
    anim_delay = anim_delay or 0.05

    if not utility.is_spell_ready(spell_id) then return false end
    if not utility.is_spell_affordable(spell_id) then return false end

    local target_pos = target and target:get_position() or player_pos

    local ok = cast_spell.position(spell_id, target_pos, anim_delay)
    if ok then return true end

    if target then
        ok = cast_spell.target(target, spell_id, anim_delay)
        if ok then return true end
    end

    ok = cast_spell.self(spell_id, anim_delay)
    return ok or false
end


local function try_move_towards(target, player_pos, desired_range)
    if not (pathfinder and type(pathfinder.request_move) == 'function') then return false end
    if not target or not player_pos then return false end
    local now = get_time_since_inject()
    if now < _move_until then return false end

    local tpos = nil
    pcall(function() tpos = target:get_position() end)
    if not tpos then return false end

    local stop = tonumber(desired_range) or 2.0
    if stop < 1.5 then stop = 1.5 end

    local move_pos = tpos
    if tpos.get_extended then
        local ok, mp = pcall(function() return tpos:get_extended(player_pos, -stop) end)
        if ok and mp then move_pos = mp end
    end

    local ok = pathfinder.request_move(move_pos)
    if ok then _move_until = now + 0.35 end
    return ok and true or false
end

function rotation_engine.tick(equipped_ids, settings)
    if not can_act() then return false end
    if get_time_since_inject() < _gcd_until then return false end

    local lp         = get_local_player()
    local player_pos = lp:get_position()
    local range      = settings.scan_range or _scan_range

    local targets = target_selector.get_targets(player_pos, range)
    if not targets.is_valid or (targets.enemy_count or 0) <= 0 then return false end

    local spell_list = {}
    for _, spell_id in ipairs(equipped_ids) do
        if spell_id and spell_id > 1 then
            local cfg = spell_config.get(spell_id)
            if cfg.enabled then
                local name = get_name_for_spell(spell_id) or tostring(spell_id)
                table.insert(spell_list, {
                    spell_id = spell_id,
                    cfg      = cfg,
                    name     = name,
                })
            end
        end
    end

    table.sort(spell_list, function(a, b)
        return a.cfg.priority < b.cfg.priority
    end)

    for _, entry in ipairs(spell_list) do
        local spell_id = entry.spell_id
        local cfg      = entry.cfg

        if not spell_tracker.is_off_cooldown(spell_id, cfg.cooldown, cfg.charges) then
            goto next_spell
        end

        if not utility.is_spell_ready(spell_id) then goto next_spell end
        if not utility.is_spell_affordable(spell_id) then goto next_spell end

        if cfg.boss_only and not targets.has_boss then goto next_spell end
        if cfg.elite_only and not targets.has_elite
            and not targets.has_boss and not targets.has_champion
        then goto next_spell end

        if cfg.require_buff then
            if not _player_has_buff(cfg.buff_hash, cfg.buff_stacks) then
                goto next_spell
            end
        end

        local spell_range = cfg.range or range
        local aoe_check = cfg.aoe_range or 6.0

        if cfg.min_enemies > 0 then
            local nearby = target_selector.count_near(targets, player_pos, aoe_check)
            if nearby < cfg.min_enemies then goto next_spell end
        end

        local target = target_selector.pick_target(targets, cfg, player_pos, spell_range)
        if not target then
            local stype = cfg.spell_type or 0 -- 0=Auto,1=Melee,2=Ranged
            local is_melee = (stype == 1) or (stype == 0 and (spell_range or 0) <= 6.0)
            if is_melee and targets.closest then
                try_move_towards(targets.closest, player_pos, spell_range)
            end
            goto next_spell
        end

        if try_cast(spell_id, target, player_pos, settings.anim_delay or 0.05) then
            spell_tracker.record_cast(spell_id, cfg.charges)
            _gcd_until = get_time_since_inject() + GLOBAL_GCD
            if settings.debug then
                console.print(string.format('[UniversalRota] Cast: %s (id=%d pri=%d)',
                    entry.name, spell_id, cfg.priority))
            end
            return true
        end

        ::next_spell::
    end

    return false
end

function rotation_engine.set_scan_range(r)
    _scan_range = r or 16.0
end

return rotation_engine
