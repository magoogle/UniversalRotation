local spell_config   = require 'core.spell_config'
local spell_tracker  = require 'core.spell_tracker'
local target_selector = require 'core.target_selector'
local buff_provider   = require 'core.buff_provider'

local rotation_engine = {}

local GLOBAL_GCD     = 0.05   -- minimal delay between any two casts
local _gcd_until     = 0.0
local _scan_range    = 16.0
local _move_until    = 0.0

local _chain_boosts = {}   -- keyed by target spell_id (number)

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

-- Returns current resource as a percentage (0-100), or nil if unavailable / unreliable
local function _get_resource_pct()
    local lp = get_local_player()
    if not lp then return nil end

    local cur, max_r
    if type(lp.get_primary_resource_current) == 'function' then
        local ok, v = pcall(lp.get_primary_resource_current, lp)
        if ok and type(v) == 'number' then cur = v end
    end
    if type(lp.get_primary_resource_max) == 'function' then
        local ok, v = pcall(lp.get_primary_resource_max, lp)
        if ok and type(v) == 'number' then max_r = v end
    end

    -- If either is 0 / nil, we can't compute a reliable percentage — skip gracefully
    if not cur or not max_r or max_r <= 0 then return nil end
    if cur <= 0 then return nil end  -- Rogue energy / unreported resource

    return (cur / max_r) * 100.0
end

local function _check_resource_condition(cfg)
    if not cfg.use_resource then return true end

    local pct = _get_resource_pct()
    if pct == nil then return true end  -- API returned 0 / unreliable, skip check gracefully

    local threshold = tonumber(cfg.resource_pct) or 50
    local mode = tonumber(cfg.resource_mode) or 1  -- 0=Below, 1=Above

    if mode == 0 then
        -- Below %: cast when pct < threshold
        return pct < threshold
    else
        -- Above %: cast when pct >= threshold
        return pct >= threshold
    end
end

-- Apply a chain boost after casting spell_id
local function _apply_chain(cfg)
    if not cfg.use_chain then return end
    local target_id = tonumber(cfg.chain_target_id) or 0
    if target_id == 0 then return end

    local boost    = tonumber(cfg.chain_boost) or 3
    local duration = tonumber(cfg.chain_duration) or 3.0
    local expires  = get_time_since_inject() + duration

    local existing = _chain_boosts[target_id]
    if not existing or existing.expires < get_time_since_inject() or boost > (existing.boost or 0) then
        _chain_boosts[target_id] = { boost = boost, expires = expires }
    end
end

-- Get the effective priority of a spell (accounting for active chain boosts)
local function _effective_priority(spell_id, base_priority)
    local now = get_time_since_inject()
    local cb = _chain_boosts[spell_id]
    if cb and cb.expires > now then
        -- Boost = reduce the priority number so it fires earlier
        -- Clamp to at least 1 so it never goes negative
        local boosted = base_priority - cb.boost
        if boosted < 1 then boosted = 1 end
        return boosted
    end
    return base_priority
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

local function try_cast(spell_id, target, player_pos, anim_delay, self_cast)
    anim_delay = anim_delay or 0.05

    if not utility.is_spell_ready(spell_id) then return false end
    if not utility.is_spell_affordable(spell_id) then return false end

    -- Self-cast: cast on player's position, no target needed
    if self_cast then
        local ok = cast_spell.self(spell_id, anim_delay)
        if ok then return true end
        -- Fallback: cast at player's own position
        ok = cast_spell.position(spell_id, player_pos, anim_delay)
        return ok or false
    end

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

    local spell_list = {}
    for _, spell_id in ipairs(equipped_ids) do
        if spell_id and spell_id > 1 then
            local cfg = spell_config.get(spell_id)
            if cfg.enabled then
                local name = get_name_for_spell(spell_id) or tostring(spell_id)
                local eff_pri = _effective_priority(spell_id, cfg.priority)
                table.insert(spell_list, {
                    spell_id = spell_id,
                    cfg      = cfg,
                    name     = name,
                    eff_pri  = eff_pri,
                })
            end
        end
    end

    table.sort(spell_list, function(a, b)
        return a.eff_pri < b.eff_pri
    end)

    for _, entry in ipairs(spell_list) do
        local spell_id = entry.spell_id
        local cfg      = entry.cfg

        -- Self-cast spells don't need enemies present
        if not cfg.self_cast then
            if not targets.is_valid or (targets.enemy_count or 0) <= 0 then
                goto next_spell
            end
        end

        if not spell_tracker.is_off_cooldown(spell_id, cfg.cooldown, cfg.charges) then
            goto next_spell
        end

        if not utility.is_spell_ready(spell_id) then goto next_spell end
        if not utility.is_spell_affordable(spell_id) then goto next_spell end

        -- Resource condition check
        if not _check_resource_condition(cfg) then goto next_spell end

        if not cfg.self_cast then
            if cfg.boss_only and not targets.has_boss then goto next_spell end
            if cfg.elite_only and not targets.has_elite
                and not targets.has_boss and not targets.has_champion
            then goto next_spell end
        end

        if cfg.require_buff then
            if not _player_has_buff(cfg.buff_hash, cfg.buff_stacks) then
                goto next_spell
            end
        end

        -- Min enemies check (always uses player position radius, even for self-casts it's valid)
        local aoe_check = cfg.aoe_range or 6.0
        if cfg.min_enemies > 0 then
            local nearby = target_selector.count_near(targets, player_pos, aoe_check)
            if nearby < cfg.min_enemies then goto next_spell end
        end

        -- For self-cast, skip target selection entirely
        if cfg.self_cast then
            if try_cast(spell_id, nil, player_pos, settings.anim_delay or 0.05, true) then
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    console.print(string.format('[UniversalRota] Self-Cast: %s (id=%d pri=%d eff=%d)',
                        entry.name, spell_id, cfg.priority, entry.eff_pri))
                end
                return true
            end
            goto next_spell
        end

        -- Normal targeted cast
        do
            local spell_range = cfg.range or range
            local target = target_selector.pick_target(targets, cfg, player_pos, spell_range)

            if not target then
                local stype = cfg.spell_type or 0
                local is_melee = (stype == 1) or (stype == 0 and (spell_range or 0) <= 6.0)
                if is_melee and targets.closest then
                    try_move_towards(targets.closest, player_pos, spell_range)
                end
                goto next_spell
            end

            if try_cast(spell_id, target, player_pos, settings.anim_delay or 0.05, false) then
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    local mode_names = { [0]='Priority', [1]='Closest', [2]='LowestHP', [3]='HighestHP', [4]='Cleave' }
                    console.print(string.format('[UniversalRota] Cast: %s (id=%d pri=%d eff=%d mode=%s)',
                        entry.name, spell_id, cfg.priority, entry.eff_pri,
                        mode_names[cfg.target_mode or 0] or '?'))
                end
                return true
            end
        end

        ::next_spell::
    end

    return false
end

function rotation_engine.set_scan_range(r)
    _scan_range = r or 16.0
end

return rotation_engine
