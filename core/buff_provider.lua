local buff_provider = {}

-- Persistent history of all buffs ever seen (survives buff expiration)
-- Keyed by hash: { [hash] = raw_name_string }
local _buff_history = {}

-- Spell-name remap table: maps known internal buff name fragments to friendly names.
-- Built from spell ID reference. Buff names from the API often match spell names
-- (e.g. "Barbarian_Rallying_Cry", "Necro_Bone_Storm").
-- We strip the class prefix and pretty-print, but this table catches special cases.
local _name_overrides = {
    -- Add manual overrides here if a buff name doesn't match any spell pattern.
    -- e.g. ["Some_Weird_Internal_Name"] = "Friendly Name",
}

local function safe_call(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

-- Pretty-print a raw buff name: strip class prefix, replace underscores, title case
local function pretty_name(raw)
    if not raw or raw == '' then return raw end

    -- Check overrides first (exact match on raw name)
    if _name_overrides[raw] then return _name_overrides[raw] end

    local s = tostring(raw)
    -- Strip brackets
    s = s:gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')

    -- Split on underscores
    local parts = {}
    for p in s:gmatch('[^_]+') do parts[#parts + 1] = p end

    -- Known class prefixes to strip (first segment only)
    local class_prefixes = {
        Barbarian = true, Barb = true,
        Druid = true,
        Necro = true, Necromancer = true,
        Paladin = true,
        Rogue = true,
        Sorc = true, Sorcerer = true, Sorceress = true,
        Spiritborn = true, SpiritBorn = true,
        Warlock = true,
    }

    if #parts >= 2 and class_prefixes[parts[1]] then
        table.remove(parts, 1)
    end

    -- Title case each part
    for i, p in ipairs(parts) do
        parts[i] = p:sub(1, 1):upper() .. p:sub(2):lower()
    end

    return table.concat(parts, ' ')
end

-- Extract hash and raw name from a buff object
local function read_buff(b)
    local h = nil
    if type(b.get_name_hash) == 'function' then
        h = safe_call(b.get_name_hash, b)
    elseif type(b.name_hash) == 'number' then
        h = b.name_hash
    end
    if type(h) ~= 'number' or h == 0 then return nil, nil end

    local n = nil
    if type(b.name) == 'function' then
        n = safe_call(b.name, b)
    elseif type(b.get_name) == 'function' then
        n = safe_call(b.get_name, b)
    elseif type(b.name) == 'string' then
        n = b.name
    end
    n = tostring(n or ('Buff #' .. tostring(h)))

    return h, n
end

-- Record a buff into the persistent history
local function remember_buff(hash, raw_name)
    if not hash or hash == 0 then return end
    _buff_history[hash] = raw_name or _buff_history[hash] or ('Buff #' .. tostring(hash))
end

-- Get the set of currently active buff hashes (for tagging inactive ones)
local function get_active_hash_set()
    local active = {}
    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return active end

    local buffs = safe_call(player.get_buffs, player) or {}
    for _, b in ipairs(buffs) do
        local h = read_buff(b)
        if h then active[h] = true end
    end
    return active
end

function buff_provider.get_player_buff_choices()
    local items  = { 'None' }
    local hashes = { 0 }
    local index_by_hash = { [0] = 0 }

    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then
        -- Still include history even if player isn't available
        local tmp = {}
        for h, raw in pairs(_buff_history) do
            tmp[#tmp + 1] = { name = raw, hash = h, active = false }
        end
        table.sort(tmp, function(a, b) return a.name < b.name end)
        for i, it in ipairs(tmp) do
            local label = pretty_name(it.name) .. ' (Not Active)'
            items[#items + 1] = label
            hashes[#hashes + 1] = it.hash
            index_by_hash[it.hash] = i
        end
        return items, hashes, index_by_hash
    end

    -- Read current buffs and update history
    local buffs = safe_call(player.get_buffs, player) or {}
    local active_set = {}
    local seen_hashes = {}

    for _, b in ipairs(buffs) do
        local h, n = read_buff(b)
        if h then
            remember_buff(h, n)
            active_set[h] = true
            seen_hashes[h] = true
        end
    end

    -- Build combined list: active buffs first, then inactive from history
    local active_list = {}
    local inactive_list = {}

    for h, raw in pairs(_buff_history) do
        if active_set[h] then
            active_list[#active_list + 1] = { name = raw, hash = h, active = true }
        else
            inactive_list[#inactive_list + 1] = { name = raw, hash = h, active = false }
        end
    end

    table.sort(active_list, function(a, b) return a.name < b.name end)
    table.sort(inactive_list, function(a, b) return a.name < b.name end)

    -- Active buffs first
    for i, it in ipairs(active_list) do
        local label = pretty_name(it.name)
        items[#items + 1] = label
        hashes[#hashes + 1] = it.hash
        index_by_hash[it.hash] = #items - 1 -- 0-based combo index
    end

    -- Then inactive (previously seen) buffs
    for i, it in ipairs(inactive_list) do
        local label = pretty_name(it.name) .. ' (Not Active)'
        items[#items + 1] = label
        hashes[#hashes + 1] = it.hash
        index_by_hash[it.hash] = #items - 1
    end

    return items, hashes, index_by_hash
end


function buff_provider.get_available_buffs_and_missing(saved_hash, saved_name)
    local items, hashes, index_by_hash = buff_provider.get_player_buff_choices()

    if type(saved_hash) ~= 'number' then saved_hash = 0 end
    if saved_hash == 0 then
        return items, hashes
    end

    -- If the saved buff is already in our list (active or from history), we're good
    if index_by_hash and index_by_hash[saved_hash] ~= nil then
        return items, hashes
    end

    -- Buff was never seen in this session — add it from saved name
    -- Also remember it in history so it persists
    local raw_name = tostring(saved_name or '')
    if raw_name == '' then raw_name = 'Buff #' .. tostring(saved_hash) end

    remember_buff(saved_hash, raw_name)

    local label = pretty_name(raw_name) .. ' (Not Active)'

    table.insert(items, 2, label)
    table.insert(hashes, 2, saved_hash)

    return items, hashes
end

function buff_provider.get_active_buffs()
    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then return {} end

    local buffs = safe_call(player.get_buffs, player) or {}
    local out = {}
    for _, b in ipairs(buffs) do
        local h, n = read_buff(b)
        if h then
            remember_buff(h, n)

            local stacks = nil
            if type(b.get_stacks) == 'function' then
                stacks = safe_call(b.get_stacks, b)
            elseif type(b.stacks) == 'number' then
                stacks = b.stacks
            end
            stacks = tonumber(stacks) or 0

            local rem = nil
            if type(b.get_remaining_time) == 'function' then
                rem = safe_call(b.get_remaining_time, b)
            end
            out[#out + 1] = { name = pretty_name(n), hash = h, stacks = stacks, remaining = rem }
        end
    end
    table.sort(out, function(a, b)
        if a.stacks ~= b.stacks then return a.stacks > b.stacks end
        return a.name < b.name
    end)
    return out
end

-- Import buff history from a profile (called during profile load)
function buff_provider.import_history(history_table)
    if type(history_table) ~= 'table' then return end
    for hash_str, raw_name in pairs(history_table) do
        local h = tonumber(hash_str)
        if h and h ~= 0 and type(raw_name) == 'string' then
            _buff_history[h] = raw_name
        end
    end
end

-- Export buff history for profile save
function buff_provider.export_history()
    local out = {}
    for h, raw_name in pairs(_buff_history) do
        out[tostring(h)] = raw_name
    end
    return out
end

-- Clear history (called on class change)
function buff_provider.clear_history()
    _buff_history = {}
end

return buff_provider
