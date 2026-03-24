local target_selector = {}

local SCAN_RANGE = 16.0

local function _try(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

local function _truthy(fn, ...)
    local v = _try(fn, ...)
    return v and true or false
end

local function _pos(obj)
    return _try(function() return obj:get_position() end)
end

local function _dist2(a_pos, b_pos)
    if a_pos and a_pos.squared_dist_to_ignore_z then
        return _try(function() return a_pos:squared_dist_to_ignore_z(b_pos) end) or math.huge
    end
    if not (a_pos and b_pos and a_pos.x and b_pos.x) then return math.huge end
    local dx = a_pos:x() - b_pos:x()
    local dy = a_pos:y() - b_pos:y()
    return dx * dx + dy * dy
end

function target_selector.dist2(a_pos, b_pos)
    return _dist2(a_pos, b_pos)
end

local function _is_dead(obj)
    return _truthy(function() return obj:is_dead() end)
end

local function _is_valid_enemy(obj)
    if not obj then return false end
    if _is_dead(obj) then return false end
    if obj.is_enemy and not _truthy(function() return obj:is_enemy() end) then return false end
    if obj.is_hidden and _truthy(function() return obj:is_hidden() end) then return false end
    if obj.is_invulnerable and _truthy(function() return obj:is_invulnerable() end) then return false end
    if obj.is_town_npc and _truthy(function() return obj:is_town_npc() end) then return false end
    return true
end

local function _enemy_list()
    if not actors_manager then return {} end
    if type(actors_manager.get_enemy_npcs) == 'function' then
        return _try(actors_manager.get_enemy_npcs) or {}
    end
    if type(actors_manager.get_enemies) == 'function' then
        return _try(actors_manager.get_enemies) or {}
    end
    return {}
end

local function _is_boss(obj)     return obj.is_boss and _truthy(function() return obj:is_boss() end) end
local function _is_elite(obj)    return obj.is_elite and _truthy(function() return obj:is_elite() end) end
local function _is_champion(obj) return obj.is_champion and _truthy(function() return obj:is_champion() end) end

function target_selector.get_targets(player_pos, range)
    range = range or SCAN_RANGE
    local r2 = range * range

    local enemies = _enemy_list()
    local result = {
        is_valid       = false,
        closest        = nil,
        closest_elite  = nil,
        closest_boss   = nil,
        closest_champ  = nil,
        has_elite      = false,
        has_boss       = false,
        has_champion   = false,
        enemy_count    = 0,
        all_enemies    = {},
    }

    local closest_dist       = math.huge
    local closest_elite_dist = math.huge
    local closest_boss_dist  = math.huge
    local closest_champ_dist = math.huge

    for _, enemy in ipairs(enemies or {}) do
        if not _is_valid_enemy(enemy) then goto continue end

        local epos = _pos(enemy)
        if not epos then goto continue end

        local d2 = _dist2(epos, player_pos)
        if d2 > r2 then goto continue end

        result.is_valid = true
        result.enemy_count = result.enemy_count + 1
        result.all_enemies[#result.all_enemies + 1] = enemy

        if d2 < closest_dist then
            closest_dist = d2
            result.closest = enemy
        end

        if _is_boss(enemy) then
            result.has_boss = true
            if d2 < closest_boss_dist then
                closest_boss_dist = d2
                result.closest_boss = enemy
            end
        elseif _is_elite(enemy) then
            result.has_elite = true
            if d2 < closest_elite_dist then
                closest_elite_dist = d2
                result.closest_elite = enemy
            end
        elseif _is_champion(enemy) then
            result.has_champion = true
            if d2 < closest_champ_dist then
                closest_champ_dist = d2
                result.closest_champ = enemy
            end
        end

        ::continue::
    end

    return result
end

function target_selector.pick_target(targets, spell_cfg, player_pos, range)
    if not (targets and targets.is_valid) then return nil end

    local r2 = nil
    if range and player_pos then r2 = range * range end

    local function in_range(enemy)
        if not r2 then return true end
        local epos = _pos(enemy)
        if not epos then return false end
        return _dist2(epos, player_pos) <= r2
    end

    local function best_of(candidates)
        if not (candidates and player_pos and r2) then
            for _, e in ipairs(candidates or {}) do
                if e and in_range(e) then return e end
            end
            return nil
        end
        local best, best_d2 = nil, math.huge
        for _, e in ipairs(candidates or {}) do
            if e and in_range(e) then
                local d2 = _dist2(_pos(e), player_pos)
                if d2 < best_d2 then
                    best, best_d2 = e, d2
                end
            end
        end
        return best
    end

    if spell_cfg and spell_cfg.boss_only then
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
    elseif spell_cfg and spell_cfg.elite_only then
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
        if targets.closest_elite and in_range(targets.closest_elite) then return targets.closest_elite end
        if targets.closest_champ and in_range(targets.closest_champ) then return targets.closest_champ end
    else
        if targets.closest_boss and in_range(targets.closest_boss) then return targets.closest_boss end
        if targets.closest_elite and in_range(targets.closest_elite) then return targets.closest_elite end
        if targets.closest_champ and in_range(targets.closest_champ) then return targets.closest_champ end
        if targets.closest and in_range(targets.closest) then return targets.closest end
    end

    if not targets.all_enemies then return nil end

    local bosses, elites, champs, any = {}, {}, {}, {}
    for _, e in ipairs(targets.all_enemies) do
        if in_range(e) then
            any[#any + 1] = e
            if _is_boss(e) then bosses[#bosses + 1] = e
            elseif _is_elite(e) then elites[#elites + 1] = e
            elseif _is_champion(e) then champs[#champs + 1] = e
            end
        end
    end

    if spell_cfg and spell_cfg.boss_only then
        return best_of(bosses)
    end
    if spell_cfg and spell_cfg.elite_only then
        local b = best_of(bosses); if b then return b end
        local e = best_of(elites); if e then return e end
        return best_of(champs)
    end

    local b = best_of(bosses); if b then return b end
    local e = best_of(elites); if e then return e end
    local c = best_of(champs); if c then return c end
    return best_of(any)
end

function target_selector.count_near(targets, pos, radius)
    if not (targets and targets.all_enemies) then return 0 end
    local r2 = radius * radius
    local c = 0
    for _, enemy in ipairs(targets.all_enemies) do
        local epos = _pos(enemy)
        if epos and _dist2(epos, pos) <= r2 then c = c + 1 end
    end
    return c
end

return target_selector
