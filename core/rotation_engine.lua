local spell_config   = require 'core.spell_config'
local spell_tracker  = require 'core.spell_tracker'
local target_selector = require 'core.target_selector'
local buff_provider   = require 'core.buff_provider'
local logger          = require 'core.logger'

local rotation_engine = {}

local GLOBAL_GCD     = 0.05   -- minimal delay between any two casts
local _gcd_until     = 0.0
local _scan_range    = 16.0
local _move_until    = 0.0

-- Chain boosts: [spell_id] = { priority_boost, expires_at }
-- After a spell with use_chain fires, the target spell's effective priority is temporarily lowered
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

local function _check_health_condition(cfg)
    if not cfg.use_health then return true end

    local lp = get_local_player()
    if not lp then return true end

    local cur, max_h
    if type(lp.get_current_health) == 'function' then
        local ok, v = pcall(lp.get_current_health, lp)
        if ok and type(v) == 'number' and v > 0 then cur = v end
    end
    if type(lp.get_max_health) == 'function' then
        local ok, v = pcall(lp.get_max_health, lp)
        if ok and type(v) == 'number' and v > 0 then max_h = v end
    end

    if not cur or not max_h then return true end

    local pct       = (cur / max_h) * 100.0
    local threshold = tonumber(cfg.health_pct) or 50
    local mode      = tonumber(cfg.health_mode) or 0  -- 0=Below, 1=Above

    if mode == 0 then return pct < threshold
    else              return pct >= threshold
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

-- Cast counters for Stack Priority Mode: [spell_id] = { count, last_cast }
local _stack_pri_counts = {}

-- Get the effective priority of a spell (chain boosts + stack-based priority override)
-- cfg is optional; if present, stack priority mode is evaluated
local function _effective_priority(spell_id, base_priority, cfg)
    local now = get_time_since_inject()
    local result = base_priority

    -- Stack Priority Mode: cast at override priority for the first N casts,
    -- then revert to normal. Counter resets after the configured idle window.
    if cfg and cfg.use_stack_pri then
        local sc = _stack_pri_counts[spell_id]
        if sc and sc.last_cast > 0 and (now - sc.last_cast) > (cfg.stack_pri_reset or 4.0) then
            sc.count = 0  -- reset: spell hasn't fired recently, start build phase again
        end
        local count = sc and sc.count or 0
        if count < (cfg.stack_pri_count or 4) then
            result = cfg.stack_pri_below_pri or base_priority
        end
    end

    -- Chain boost: reduce priority number so the spell fires sooner
    local cb = _chain_boosts[spell_id]
    if cb and cb.expires > now then
        result = math.max(1, result - cb.boost)
    end

    return result
end

local function _record_stack_pri_cast(spell_id, cfg)
    if not cfg or not cfg.use_stack_pri then return end
    local sc = _stack_pri_counts[spell_id]
    if not sc then
        sc = { count = 0, last_cast = 0 }
        _stack_pri_counts[spell_id] = sc
    end
    sc.count     = sc.count + 1
    sc.last_cast = get_time_since_inject()
end

local function can_act()
    local lp = get_local_player()
    if not lp then logger.log('can_act: NO local player'); return false end
    if lp:is_dead() then logger.log('can_act: player is DEAD'); return false end

    -- Don't cast anything in town / safe zones
    local town_ok, in_town = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA)
    end)
    if town_ok and in_town and in_town > 0 then logger.log('can_act: IN TOWN'); return false end

    local pos = lp:get_position()
    if evade and evade.is_dangerous_position and evade.is_dangerous_position(pos) then
        logger.log('can_act: dangerous position (evade)')
        return false
    end

    local active = lp:get_active_spell_id()
    local blocked = { [186139]=true, [197833]=true, [211568]=true }
    if active and blocked[active] then logger.log('can_act: blocked spell active ' .. tostring(active)); return false end

    local ok, mount_val = pcall(function()
        return lp:get_attribute(attributes.CURRENT_MOUNT)
    end)
    if ok and mount_val and mount_val < 0 then logger.log('can_act: mounted'); return false end

    return true
end

-- Convert a world vec3 position to screen vec2 coordinates.
-- D4 world uses x/y as horizontal plane; vec2:coordinate_to_screen() does the projection.
local function _world_to_screen(world_pos)
    if not world_pos then return nil end
    local result = nil
    pcall(function()
        local wx = type(world_pos.x) == 'function' and world_pos:x() or world_pos.x
        local wy = type(world_pos.y) == 'function' and world_pos:y() or world_pos.y
        local s = vec2:new(wx, wy):coordinate_to_screen()
        local sx = type(s.x) == 'function' and s:x() or s.x
        local sy = type(s.y) == 'function' and s:y() or s.y
        if sx and sy then result = { sx, sy } end
    end)
    if result then return result[1], result[2] end
    return nil
end

-- Get aim target world position based on aim_mode:
--   0 = towards closest enemy
--   1 = orbwalker direction (clear/pvp -> toward enemy, flee -> away from enemy)
local function _get_aim_target(aim_mode, player_pos, scan_range)
    logger.log(string.format('_get_aim_target: aim_mode=%d scan_range=%s', aim_mode, tostring(scan_range)))
    local nearby = target_selector.get_targets(player_pos, scan_range or 30)
    local enemy = nearby and nearby.closest
    if not enemy then logger.log('_get_aim_target: no enemy found'); return nil end

    local enemy_pos = nil
    pcall(function() enemy_pos = enemy:get_position() end)
    if not enemy_pos then logger.log('_get_aim_target: enemy has no position'); return nil end

    logger.log(string.format('_get_aim_target: enemy found'))

    if aim_mode == 1 then
        -- Orbwalker direction: read the mode enum to decide direction
        local orb_mode_val = 0
        pcall(function() orb_mode_val = orbwalker.get_orb_mode() end)
        logger.log(string.format('_get_aim_target: orbwalker mode=%d', orb_mode_val))
        if orb_mode_val == 4 then
            -- Flee: aim away from the nearest enemy
            local flee_pos = nil
            pcall(function()
                flee_pos = player_pos:get_extended(enemy_pos, -15.0)
            end)
            logger.log('_get_aim_target: flee mode, aiming away from enemy')
            return flee_pos or enemy_pos
        end
        -- Clear / PvP / None: aim toward enemy
        logger.log('_get_aim_target: orbwalker non-flee, aiming toward enemy')
        return enemy_pos
    end

    -- Mode 0: towards closest enemy
    logger.log('_get_aim_target: mode 0, aiming at closest enemy')
    return enemy_pos
end

-- Key-press cast: press a single key (evade / spacebar style)
-- aim_mode: 0=towards enemy, 1=orbwalker direction
local function try_key_cast(spell_id, vk_code, is_virtual, aim_mode, player_pos, scan_range)
    logger.log(string.format('try_key_cast: spell=%s vk=0x%02X virtual=%s aim=%d',
        tostring(spell_id), vk_code or 0x20, tostring(is_virtual), aim_mode or 0))

    if not is_virtual then
        if not utility.is_spell_ready(spell_id) then logger.log('try_key_cast: spell not ready'); return false end
        if not utility.is_spell_affordable(spell_id) then logger.log('try_key_cast: spell not affordable'); return false end
    end

    vk_code  = vk_code or 0x20  -- default: spacebar
    aim_mode = aim_mode or 0

    if player_pos then
        local aim_pos = _get_aim_target(aim_mode, player_pos, scan_range)
        if aim_pos then
            local sx, sy = _world_to_screen(aim_pos)
            if sx and sy then
                logger.log(string.format('try_key_cast: moving cursor to screen (%d, %d)', sx, sy))
                local cur = get_cursor_position()
                local cur_sx, cur_sy = _world_to_screen(cur)
                utility.send_mouse_move(sx, sy)
                utility.send_key_press(vk_code)
                if cur_sx and cur_sy then
                    utility.send_mouse_move(cur_sx, cur_sy)
                    logger.log('try_key_cast: cursor restored')
                end
                logger.log('try_key_cast: SUCCESS (aimed)')
                return true
            else
                logger.log('try_key_cast: world_to_screen FAILED for aim_pos')
            end
        else
            logger.log('try_key_cast: no aim target found')
        end
    else
        logger.log('try_key_cast: no player_pos')
    end

    -- Fallback if no enemy found or screen conversion failed: press key as-is
    logger.log('try_key_cast: FALLBACK, pressing key without aim')
    utility.send_key_press(vk_code)
    return true
end

-- Force Stand Still + Skill Key: hold modifier, press skill slot key, release modifier
-- Moves cursor to target_pos before casting so the skill fires at the correct target,
-- then restores the cursor to its original position.
-- Slot 0=key '1' (0x31), slot 1=key '2' (0x32), etc.
local function try_force_standstill_cast(spell_id, hold_key, slot, is_virtual, target_pos)
    if not is_virtual then
        if not utility.is_spell_ready(spell_id) then return false end
        if not utility.is_spell_affordable(spell_id) then return false end
    end

    hold_key = hold_key or 0x10  -- default: Shift
    slot = slot or 0
    local slot_key = 0x31 + slot  -- 0x31='1', 0x32='2', etc.

    -- Move cursor to the target position so FSS fires in the right direction
    local cur_sx, cur_sy = nil, nil
    if target_pos then
        local sx, sy = _world_to_screen(target_pos)
        if sx and sy then
            local cur = get_cursor_position()
            cur_sx, cur_sy = _world_to_screen(cur)
            utility.send_mouse_move(sx, sy)
        end
    end

    utility.send_key_down(hold_key)
    utility.send_key_press(slot_key)
    utility.send_key_up(hold_key)

    -- Restore cursor
    if cur_sx and cur_sy then
        utility.send_mouse_move(cur_sx, cur_sy)
    end
    return true
end

-- Cursor-targeted cast: cast at the current mouse cursor world position
local function try_cursor_cast(spell_id, anim_delay)
    anim_delay = anim_delay or 0.05

    if not utility.is_spell_ready(spell_id) then return false end
    if not utility.is_spell_affordable(spell_id) then return false end

    local cursor_pos = get_cursor_position()
    if not cursor_pos then return false end

    local ok = cast_spell.position(spell_id, cursor_pos, anim_delay)
    return ok or false
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
    logger.log('--- tick ---')

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
                local eff_pri = _effective_priority(spell_id, cfg.priority, cfg)
                table.insert(spell_list, {
                    spell_id = spell_id,
                    cfg      = cfg,
                    name     = name,
                    eff_pri  = eff_pri,
                    is_virtual = false,
                })
            end
        end
    end

    -- Inject virtual evade spell if enabled
    local evade_id = spell_config.VIRTUAL_EVADE_ID
    local evade_cfg = spell_config.get(evade_id)
    if evade_cfg.enabled then
        table.insert(spell_list, {
            spell_id = evade_id,
            cfg      = evade_cfg,
            name     = 'Evade',
            eff_pri  = _effective_priority(evade_id, evade_cfg.priority, evade_cfg),
            is_virtual = true,
        })
    end

    table.sort(spell_list, function(a, b)
        return a.eff_pri < b.eff_pri
    end)

    for _, entry in ipairs(spell_list) do
        local spell_id = entry.spell_id
        local cfg      = entry.cfg

        local is_virtual = entry.is_virtual

        local spell_name = is_virtual and 'Evade' or (entry.name or tostring(spell_id))
        logger.log(string.format('eval: %s (id=%s pri=%d eff=%d method=%d)',
            spell_name, tostring(spell_id), cfg.priority, entry.eff_pri, cfg.cast_method or 0))

        -- Self-cast and cursor-targeted spells don't need enemies present
        if not cfg.self_cast and (cfg.target_mode or 0) ~= 5 then
            if not targets.is_valid or (targets.enemy_count or 0) <= 0 then
                logger.log('  SKIP: no enemies nearby')
                goto next_spell
            end
        end

        if not spell_tracker.is_off_cooldown(spell_id, cfg.cooldown, cfg.charges) then
            logger.log('  SKIP: on cooldown')
            goto next_spell
        end

        -- Virtual spells don't have real spell IDs, skip API checks
        if not is_virtual then
            if not utility.is_spell_ready(spell_id) then logger.log('  SKIP: spell not ready'); goto next_spell end
            if not utility.is_spell_affordable(spell_id) then logger.log('  SKIP: spell not affordable'); goto next_spell end
        end

        -- Resource condition check
        if not _check_resource_condition(cfg) then logger.log('  SKIP: resource condition'); goto next_spell end

        -- Health condition check
        if not _check_health_condition(cfg) then logger.log('  SKIP: health condition'); goto next_spell end

        if not cfg.self_cast then
            if cfg.boss_only and not targets.has_boss then logger.log('  SKIP: boss_only, no boss'); goto next_spell end
            if cfg.elite_only and not targets.has_elite
                and not targets.has_boss and not targets.has_champion
            then logger.log('  SKIP: elite_only, no elite/boss/champ'); goto next_spell end
        end

        if cfg.require_buff then
            if not _player_has_buff(cfg.buff_hash, cfg.buff_stacks) then
                logger.log('  SKIP: required buff not active')
                goto next_spell
            end
        end

        -- Min enemies check: use the higher of global minimum and per-spell minimum.
        -- Bosses and champions always bypass this — they are never ignored due to low mob count.
        local aoe_check = cfg.aoe_range or 6.0
        local effective_min = math.max(cfg.min_enemies or 0, settings.global_min_enemies or 0)
        if effective_min > 0 then
            if not (targets.has_boss or targets.has_champion) then
                local nearby = target_selector.count_near(targets, player_pos, aoe_check)
                if nearby < effective_min then
                    logger.log(string.format('  SKIP: min_enemies %d, have %d', effective_min, nearby))
                    goto next_spell
                end
            end
        end

        -- Determine cast method: 0=Normal, 1=Key Press, 2=Force Stand Still + Key
        local cast_method = cfg.cast_method or 0
        local METHOD_TAGS = { [0]='', [1]=' [KEY]', [2]=' [FSS]' }

        -- Dispatch a cast using the configured method.
        -- aim_pos: world position to move the cursor to before FSS cast (nil = leave cursor as-is)
        -- When stack_pri_targeted is enabled and the spell is still in its build phase,
        -- always use the normal targeted cast regardless of configured cast_method.
        local function dispatch_cast(fallback_fn, aim_pos)
            local in_build_phase = false
            if cfg.use_stack_pri and cfg.stack_pri_targeted then
                local sc = _stack_pri_counts[spell_id]
                local count = sc and sc.count or 0
                in_build_phase = count < (cfg.stack_pri_count or 4)
                logger.log(string.format('  dispatch: stack_pri count=%d/%d build_phase=%s',
                    count, cfg.stack_pri_count or 4, tostring(in_build_phase)))
            end

            if in_build_phase then
                logger.log('  dispatch: FORCED normal cast (build phase)')
                return fallback_fn()
            elseif cast_method == 1 then
                logger.log('  dispatch: KEY PRESS')
                return try_key_cast(spell_id, cfg.evade_key, is_virtual, cfg.evade_aim_mode, player_pos, range)
            elseif cast_method == 2 then
                logger.log('  dispatch: FORCE STAND STILL')
                return try_force_standstill_cast(spell_id, cfg.force_hold_key, cfg.skill_slot, is_virtual, aim_pos)
            else
                logger.log('  dispatch: NORMAL cast')
                return fallback_fn()
            end
        end

        -- For self-cast, aim at player position
        if cfg.self_cast then
            logger.log('  path: SELF CAST')
            local did_cast = dispatch_cast(function()
                return try_cast(spell_id, nil, player_pos, settings.anim_delay or 0.05, true)
            end, player_pos)
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (self)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    console.print(string.format('[UniversalRota] Self-Cast: %s (id=%s pri=%d eff=%d%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri, METHOD_TAGS[cast_method] or ''))
                end
                return true
            end
            goto next_spell
        end

        -- Cursor targeting mode (target_mode == 5): cast at cursor position, no enemy needed
        if (cfg.target_mode or 0) == 5 then
            logger.log('  path: CURSOR CAST')
            local did_cast = dispatch_cast(function()
                return try_cursor_cast(spell_id, settings.anim_delay or 0.05)
            end, nil)  -- nil = leave cursor as-is for FSS too
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (cursor)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    console.print(string.format('[UniversalRota] Cursor-Cast: %s (id=%s pri=%d eff=%d%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri, METHOD_TAGS[cast_method] or ''))
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
                logger.log('  SKIP: no valid target in range')
                local stype = cfg.spell_type or 0
                local is_melee = (stype == 1) or (stype == 0 and (spell_range or 0) <= 6.0)
                if is_melee and targets.closest then
                    logger.log('  moving towards closest enemy')
                    try_move_towards(targets.closest, player_pos, spell_range)
                end
                goto next_spell
            end

            logger.log('  path: TARGETED CAST')
            local target_pos = nil
            pcall(function() target_pos = target:get_position() end)
            local did_cast = dispatch_cast(function()
                return try_cast(spell_id, target, player_pos, settings.anim_delay or 0.05, false)
            end, target_pos)
            if did_cast then
                logger.log(string.format('  CAST SUCCESS: %s (targeted)', spell_name))
                spell_tracker.record_cast(spell_id, cfg.charges)
                _apply_chain(cfg)
                _record_stack_pri_cast(spell_id, cfg)
                _gcd_until = get_time_since_inject() + GLOBAL_GCD
                if settings.debug then
                    local mode_names = { [0]='Priority', [1]='Closest', [2]='LowestHP', [3]='HighestHP', [4]='Cleave', [5]='Cursor' }
                    console.print(string.format('[UniversalRota] Cast: %s (id=%s pri=%d eff=%d mode=%s%s)',
                        entry.name, tostring(spell_id), cfg.priority, entry.eff_pri,
                        mode_names[cfg.target_mode or 0] or '?', METHOD_TAGS[cast_method] or ''))
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

function rotation_engine.reset()
    _gcd_until        = 0.0
    _move_until       = 0.0
    _chain_boosts     = {}
    _stack_pri_counts = {}
end

return rotation_engine
