local spell_tracker = {}

local _state = {}  -- [spell_id] = { last_cast = number|nil, charges_left = int|nil, empty_since = number|nil }

local function now()
    return get_time_since_inject()
end

local function ensure(spell_id)
    local s = _state[spell_id]
    if s then return s end
    s = {}
    _state[spell_id] = s
    return s
end

function spell_tracker.record_cast(spell_id, max_charges)
    local s = ensure(spell_id)
    local t = now()
    s.last_cast = t

    max_charges = tonumber(max_charges) or 1
    if max_charges <= 1 then
        s.charges_left = nil
        s.empty_since  = nil
        return
    end

    if type(s.charges_left) ~= 'number' or s.charges_left <= 0 or s.charges_left > max_charges then
        s.charges_left = max_charges
    end

    s.charges_left = s.charges_left - 1
    if s.charges_left <= 0 then
        s.charges_left = 0
        s.empty_since = t
    end
end

function spell_tracker.time_since_cast(spell_id)
    local s = _state[spell_id]
    if not s or not s.last_cast then return math.huge end
    return now() - s.last_cast
end

function spell_tracker.is_off_cooldown(spell_id, min_cooldown, max_charges)
    min_cooldown = tonumber(min_cooldown) or 0
    max_charges  = tonumber(max_charges) or 1

    if max_charges <= 1 then
        return spell_tracker.time_since_cast(spell_id) >= min_cooldown
    end

    local s = ensure(spell_id)

    if type(s.charges_left) ~= 'number' then
        s.charges_left = max_charges
        s.empty_since = nil
        return true
    end
    if s.charges_left > 0 then
        return true
    end

    local empty_since = s.empty_since or s.last_cast
    if not empty_since then
        s.charges_left = max_charges
        s.empty_since = nil
        return true
    end

    if (now() - empty_since) >= min_cooldown then
        s.charges_left = max_charges
        s.empty_since = nil
        return true
    end

    return false
end


function spell_tracker.get_charges(spell_id, max_charges)
    max_charges = tonumber(max_charges) or 1
    if max_charges <= 1 then
        return 1, 1
    end
    local s = ensure(spell_id)
    if type(s.charges_left) ~= 'number' or s.charges_left < 0 or s.charges_left > max_charges then
        s.charges_left = max_charges
        s.empty_since = nil
    end
    return s.charges_left, max_charges
end

function spell_tracker.reset(spell_id)
    _state[spell_id] = nil
end

function spell_tracker.reset_all()
    _state = {}
end

return spell_tracker
