local buff_provider = {}

local function safe_call(fn, ...)
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

function buff_provider.get_player_buff_choices()
    local items = { 'None' }
    local hashes = { 0 }
    local index_by_hash = { [0] = 0 }

    local player = get_local_player and get_local_player()
    if not player or type(player.get_buffs) ~= 'function' then
        return items, hashes, index_by_hash
    end

    local buffs = safe_call(player.get_buffs, player) or {}
    local tmp = {}

    for _, b in ipairs(buffs) do
        local h = nil
        if type(b.get_name_hash) == 'function' then
            h = safe_call(b.get_name_hash, b)
        elseif type(b.name_hash) == 'number' then
            h = b.name_hash
        end

        if type(h) == 'number' and h ~= 0 then
            local n = nil
            if type(b.name) == 'function' then
                n = safe_call(b.name, b)
            elseif type(b.get_name) == 'function' then
                n = safe_call(b.get_name, b)
            elseif type(b.name) == 'string' then
                n = b.name
            end
            n = tostring(n or ('Buff #' .. tostring(h)))

            tmp[#tmp + 1] = { name = n, hash = h }
        end
    end

    table.sort(tmp, function(a, b) return a.name < b.name end)

    for i, it in ipairs(tmp) do
        items[#items + 1] = it.name
        hashes[#hashes + 1] = it.hash
        index_by_hash[it.hash] = i -- because i=1 corresponds to items index 2, but combo index is 0-based:
    end

    return items, hashes, index_by_hash
end


function buff_provider.get_available_buffs_and_missing(saved_hash, saved_name)
    local items, hashes, index_by_hash = buff_provider.get_player_buff_choices()

    if type(saved_hash) ~= 'number' then saved_hash = 0 end
    if saved_hash == 0 then
        return items, hashes
    end

    if index_by_hash and index_by_hash[saved_hash] ~= nil then
        return items, hashes
    end

    local label = tostring(saved_name or '')
    if label == '' then
        label = 'Buff #' .. tostring(saved_hash)
    end
    label = label .. ' (missing)'

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
        local h = nil
        if type(b.get_name_hash) == 'function' then
            h = safe_call(b.get_name_hash, b)
        elseif type(b.name_hash) == 'number' then
            h = b.name_hash
        end
        if type(h) == 'number' and h ~= 0 then
            local n = nil
            if type(b.name) == 'function' then
                n = safe_call(b.name, b)
            elseif type(b.get_name) == 'function' then
                n = safe_call(b.get_name, b)
            end
            n = tostring(n or ('Buff #' .. tostring(h)))

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
            elseif type(b.get_end_time) == 'function' then
                rem = nil
            end
            out[#out + 1] = { name = n, hash = h, stacks = stacks, remaining = rem }
        end
    end
    table.sort(out, function(a, b)
        if a.stacks ~= b.stacks then return a.stacks > b.stacks end
        return a.name < b.name
    end)
    return out
end

return buff_provider
