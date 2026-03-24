local plugin_label = 'magoogles_universal_rotation'

local spell_config = {}

local _elements = {}
local _buff_name_cache = {}
local _buff_state = {}

-- Chain state: [spell_id] = { chain_spell_id, chain_boost_amount, chain_duration }
-- These are plain numbers/values so we store them in a side table, not UI elements
local _chain_state = {}

local buff_provider = require 'core.buff_provider'
local target_selector = require 'core.target_selector'

local TARGET_MODE_LABELS = { 'Priority', 'Closest', 'Lowest HP', 'Highest HP', 'Cleave Center' }
local RESOURCE_MODE_LABELS = { 'Below %', 'Above %' }

local function key(spell_id, suffix)
    return plugin_label .. '_spell_' .. tostring(spell_id) .. '_' .. suffix
end

local function _get_buff_state(spell_id)
    local k = tostring(spell_id)
    local st = _buff_state[k]
    if st then return st end
    st = { buff_hash = 0, buff_name = '', last_list_sig = nil }
    _buff_state[k] = st
    return st
end

local function _get_chain_state(spell_id)
    local k = tostring(spell_id)
    local cs = _chain_state[k]
    if cs then return cs end
    cs = { target_id = 0, boost = 3, duration = 5.0 }
    _chain_state[k] = cs
    return cs
end

local function _ensure_buff_combo(e, spell_id)
    if e.buff_combo then return end
    local st = _get_buff_state(spell_id)
    local default_idx = (type(st.buff_hash) == 'number' and st.buff_hash ~= 0) and 1 or 0
    e.buff_combo = combo_box:new(default_idx, get_hash(key(spell_id, 'buff_combo')))
end

local function get_elements(spell_id)
    local id = tostring(spell_id)
    if _elements[id] then return _elements[id] end

    local e = {
        enabled      = checkbox:new(true,  get_hash(key(spell_id, 'enabled'))),
        priority     = slider_int:new(1, 10, 5, get_hash(key(spell_id, 'priority'))),

        cooldown     = slider_float:new(0.0, 5.0, 0.4, get_hash(key(spell_id, 'cooldown'))),
        charges      = slider_int:new(1, 5, 1, get_hash(key(spell_id, 'charges'))),

        -- Target mode: 0=Priority, 1=Closest, 2=Lowest HP, 3=Highest HP, 4=Cleave Center
        target_mode  = combo_box:new(0, get_hash(key(spell_id, 'target_mode'))),

        spell_type   = combo_box:new(0, get_hash(key(spell_id, 'spell_type'))),

        range        = slider_float:new(1.0, 30.0, 12.0, get_hash(key(spell_id, 'range'))),
        aoe_range    = slider_float:new(1.0, 20.0, 6.0,  get_hash(key(spell_id, 'aoe_range'))),

        require_buff = checkbox:new(false, get_hash(key(spell_id, 'require_buff'))),
        buff_combo   = nil,
        buff_stacks  = slider_int:new(1, 50, 1, get_hash(key(spell_id, 'buff_stacks'))),

        elite_only   = checkbox:new(false, get_hash(key(spell_id, 'elite_only'))),
        boss_only    = checkbox:new(false, get_hash(key(spell_id, 'boss_only'))),
        min_enemies  = slider_int:new(0, 15, 0, get_hash(key(spell_id, 'min_enemies'))),

        -- Self cast: cast on player position, no target needed
        self_cast    = checkbox:new(false, get_hash(key(spell_id, 'self_cast'))),

        -- Combo chain: after casting THIS spell, boost priority of another spell
        use_chain       = checkbox:new(false, get_hash(key(spell_id, 'use_chain'))),
        chain_combo     = nil,   -- built lazily when equipped_ids list is available
        chain_boost     = slider_int:new(1, 9, 3, get_hash(key(spell_id, 'chain_boost'))),
        chain_duration  = slider_float:new(0.5, 10.0, 3.0, get_hash(key(spell_id, 'chain_duration'))),

        -- Resource condition
        use_resource    = checkbox:new(false, get_hash(key(spell_id, 'use_resource'))),
        resource_mode   = combo_box:new(1, get_hash(key(spell_id, 'resource_mode'))),  -- default: Above %
        resource_pct    = slider_int:new(1, 100, 50, get_hash(key(spell_id, 'resource_pct'))),
    }

    _elements[id] = e
    return e
end

local function _hash_list_sig(hashes)
    if type(hashes) ~= 'table' then return '' end
    local out = {}
    for i = 1, #hashes do
        out[#out + 1] = tostring(hashes[i] or 0)
    end
    return table.concat(out, ',')
end

-- Build the chain spell combo box items from equipped_ids + all_known_ids
-- Returns items (strings), ids (spell_id numbers)
local function _build_chain_items(spell_id, equipped_ids, all_known_ids)
    local items = { 'None' }
    local ids   = { 0 }
    local seen  = {}
    local all   = {}

    local function add_list(list)
        for _, sid in ipairs(list or {}) do
            if sid and sid > 1 and not seen[sid] and sid ~= spell_id then
                seen[sid] = true
                all[#all + 1] = sid
            end
        end
    end
    add_list(equipped_ids)
    add_list(all_known_ids)

    for _, sid in ipairs(all) do
        local raw = get_name_for_spell and get_name_for_spell(sid) or tostring(sid)
        -- pretty-print same as gui.lua does
        if raw then
            raw = tostring(raw):gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
            local parts = {}
            for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
            if #parts >= 2 then table.remove(parts, 1) end
            local phrase = table.concat(parts, ' ')
            phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
            raw = phrase
        end
        items[#items + 1] = raw or tostring(sid)
        ids[#ids + 1] = sid
    end

    return items, ids
end

-- Lazy-build (or rebuild) the chain combo for a spell, given available spell lists
local function _ensure_chain_combo(e, spell_id, equipped_ids, all_known_ids)
    -- Always rebuild so new spells appear; we track by spell list signature
    local sig_parts = {}
    for _, sid in ipairs(equipped_ids or {}) do sig_parts[#sig_parts+1] = tostring(sid) end
    local sig = table.concat(sig_parts, ',')

    if e.chain_combo and e._chain_sig == sig then return end

    local cs = _get_chain_state(spell_id)
    e._chain_sig = sig

    -- Build list
    local items, ids = _build_chain_items(spell_id, equipped_ids, all_known_ids)

    -- Determine current index from saved target_id
    local cur_idx = 0
    if cs.target_id and cs.target_id ~= 0 then
        for i, sid in ipairs(ids) do
            if sid == cs.target_id then cur_idx = i - 1; break end
        end
    end

    e.chain_combo = combo_box:new(cur_idx, get_hash(key(spell_id, 'chain_combo')))
    e._chain_ids  = ids
    e._chain_items = items
end

function spell_config.render(spell_id, display_name, equipped_ids, all_known_ids)
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)

    e.enabled:render('Enable', 'Enable this spell in the rotation')
    if not e.enabled:get() then return end

    e.priority:render('Priority (1=highest)', 'Lower number = cast first')

    -- Self Cast
    e.self_cast:render('Self Cast', 'Cast on yourself — no target required (useful for buffs, movement, and AoE centered on player)')

    local is_self = e.self_cast:get()

    -- Spell type & range only relevant for non-self casts
    if not is_self then
        e.spell_type:render('Spell type', { 'Auto', 'Melee', 'Ranged' }, 'Auto = default; Melee will move into range before casting')

        local stype = e.spell_type:get() or 0
        local range_label = (stype == 1) and 'Engage range (yds)' or 'Spell range (yds)'
        local range_tip = (stype == 1) and 'Melee: will move toward the closest valid enemy until within this range' or 'Skip this spell if no valid enemy is within this range'
        e.range:render(range_label, range_tip, 1)

        -- Target mode
        e.target_mode:render('Target Mode', TARGET_MODE_LABELS, 'How to select which enemy to target for this spell')

        local tmode = e.target_mode:get() or 0
        if tmode == target_selector.MODE_CLEAVE then
            e.aoe_range:render('Cleave radius (yds)', 'Picks the enemy with the most others within this radius', 1)
        else
            e.aoe_range:render('AOE check radius (yds)', 'Count enemies within this radius of your character (used for Min enemies)', 1)
        end
    else
        -- For self-cast, still show aoe range for min_enemies check
        e.aoe_range:render('AOE check radius (yds)', 'Count enemies within this radius of your character (used for Min enemies)', 1)
    end

    e.min_enemies:render('Min enemies near you', 'Minimum enemies within AOE check radius (0 = always)', 2)

    -- ---- Require Buff ----
    e.require_buff:render('Require Buff', 'Only trigger when a specific buff is active on you')
    if e.require_buff:get() then
        _ensure_buff_combo(e, spell_id)

        local stored_hash = st.buff_hash or 0
        local stored_name = st.buff_name
        if (not stored_name or stored_name == '') then
            stored_name = _buff_name_cache[tostring(spell_id)] or ''
        end

        local items, hashes = buff_provider.get_available_buffs_and_missing(stored_hash, stored_name)

        local desired_idx = 0
        if stored_hash ~= 0 then
            for i = 1, #hashes do
                if hashes[i] == stored_hash then
                    desired_idx = i - 1
                    break
                end
            end
        end

        local sig = tostring(desired_idx) .. '|' .. _hash_list_sig(hashes)
        if st.last_list_sig ~= sig then
            if type(e.buff_combo.set) == 'function' then
                pcall(e.buff_combo.set, e.buff_combo, desired_idx)
            end
            st.last_list_sig = sig
        else
            local cur = e.buff_combo:get()
            if type(cur) == 'number' then
                local cur_hash = hashes[cur + 1] or 0
                if cur_hash ~= stored_hash then
                    if type(e.buff_combo.set) == 'function' then
                        pcall(e.buff_combo.set, e.buff_combo, desired_idx)
                    end
                end
            end
        end

        e.buff_combo:render('Buff', items, 'Buff must be active on you to allow the spell (missing entry shows saved selection)')

        local sel = e.buff_combo:get()
        if type(sel) ~= 'number' then sel = 0 end
        local sel_hash = hashes[sel + 1] or 0

        st.buff_hash = sel_hash

        if sel_hash ~= 0 then
            local label = items[sel + 1] or ''
            label = tostring(label):gsub('%s*%(missing%)%s*$', '')
            _buff_name_cache[tostring(spell_id)] = label
            st.buff_name = label
        end

        e.buff_stacks:render('Min stacks', 'Minimum buff stacks required', 1)
    end

    -- ---- Resource Condition ----
    e.use_resource:render('Resource Condition', 'Only cast when your primary resource (mana, fury, etc.) meets a threshold')
    if e.use_resource:get() then
        e.resource_mode:render('Mode', RESOURCE_MODE_LABELS, 'Below %: cast when resource is low. Above %: cast when resource is high (e.g. spenders)')
        e.resource_pct:render('Threshold %', 'Percentage of max resource (1-100). Skipped gracefully if API returns 0 (e.g. Rogue energy)')
    end

    -- ---- Combo Chain ----
    e.use_chain:render('Combo Chain', 'After casting this spell, temporarily boost another spell\'s priority')
    if e.use_chain:get() then
        _ensure_chain_combo(e, spell_id, equipped_ids or {}, all_known_ids or {})

        if e.chain_combo and e._chain_items then
            e.chain_combo:render('Chain to Spell', e._chain_items, 'The spell whose priority will be boosted after casting this one')

            -- Sync target_id from combo selection
            local sel = e.chain_combo:get() or 0
            local cs = _get_chain_state(spell_id)
            cs.target_id = (e._chain_ids and e._chain_ids[sel + 1]) or 0
        end

        e.chain_boost:render('Priority Boost', 'How much to reduce the target spell\'s priority number (e.g. 3 = drop from 5 to 2)', 1)
        e.chain_duration:render('Boost Duration (s)', 'How long the priority boost lasts after this spell is cast', 2)
    end

    -- ---- Cooldown / Charges ----
    e.cooldown:render('Min cooldown (s)', 'Minimum seconds between casts once charges are spent', 3)
    e.charges:render('Charges', 'Casts allowed before cooldown applies (1 = normal)', 3)

    -- ---- Filters ----
    if not is_self then
        e.elite_only:render('Elite / Champion only', 'Only cast against elites and champions')
        e.boss_only:render('Boss only', 'Only cast against bosses')
    end
end

function spell_config.get(spell_id)
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)
    local cs = _get_chain_state(spell_id)

    -- Read chain combo selection live
    if e.use_chain and e.use_chain:get() and e.chain_combo and e._chain_ids then
        local sel = e.chain_combo:get() or 0
        cs.target_id = e._chain_ids[sel + 1] or 0
    end

    return {
        enabled         = e.enabled:get(),
        priority        = e.priority:get(),
        cooldown        = e.cooldown:get(),
        charges         = e.charges:get(),
        spell_type      = e.spell_type:get(),
        target_mode     = e.target_mode:get(),
        range           = e.range:get(),
        aoe_range       = e.aoe_range:get(),
        elite_only      = e.elite_only:get(),
        boss_only       = e.boss_only:get(),
        min_enemies     = e.min_enemies:get(),
        self_cast       = e.self_cast:get(),

        require_buff    = e.require_buff:get(),
        buff_hash       = st.buff_hash or 0,
        buff_name       = (st.buff_name ~= '' and st.buff_name) or (_buff_name_cache[tostring(spell_id)] or ''),
        buff_stacks     = e.buff_stacks:get(),

        use_resource    = e.use_resource:get(),
        resource_mode   = e.resource_mode:get(),   -- 0=Below, 1=Above
        resource_pct    = e.resource_pct:get(),

        use_chain       = e.use_chain:get(),
        chain_target_id = cs.target_id or 0,
        chain_boost     = e.chain_boost:get(),
        chain_duration  = e.chain_duration:get(),
    }
end

local function _set_element(el, val)
    if not el then return end
    if type(el.set) == 'function' then
        pcall(el.set, el, val)
        return
    end
    if type(el.set_value) == 'function' then
        pcall(el.set_value, el, val)
        return
    end
end

function spell_config.apply(spell_id, cfg)
    if type(cfg) ~= 'table' then return end
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)
    local cs = _get_chain_state(spell_id)

    _set_element(e.enabled,       cfg.enabled)
    _set_element(e.priority,      cfg.priority)
    _set_element(e.cooldown,      cfg.cooldown)
    _set_element(e.charges,       cfg.charges)
    _set_element(e.spell_type,    cfg.spell_type)
    _set_element(e.target_mode,   cfg.target_mode)
    _set_element(e.range,         cfg.range)
    _set_element(e.aoe_range,     cfg.aoe_range)
    _set_element(e.elite_only,    cfg.elite_only)
    _set_element(e.boss_only,     cfg.boss_only)
    _set_element(e.min_enemies,   cfg.min_enemies)
    _set_element(e.self_cast,     cfg.self_cast)

    _set_element(e.require_buff,  cfg.require_buff)
    _set_element(e.buff_stacks,   cfg.buff_stacks)

    _set_element(e.use_resource,  cfg.use_resource)
    _set_element(e.resource_mode, cfg.resource_mode)
    _set_element(e.resource_pct,  cfg.resource_pct)

    _set_element(e.use_chain,     cfg.use_chain)
    _set_element(e.chain_boost,   cfg.chain_boost)
    _set_element(e.chain_duration, cfg.chain_duration)

    if type(cfg.buff_hash) == 'number' then st.buff_hash = cfg.buff_hash end
    if type(cfg.buff_name) == 'string' then st.buff_name = cfg.buff_name end
    if type(cfg.buff_name) == 'string' and cfg.buff_name ~= '' then
        _buff_name_cache[tostring(spell_id)] = cfg.buff_name
    end

    -- Restore chain state
    if type(cfg.chain_target_id) == 'number' then cs.target_id = cfg.chain_target_id end

    st.last_list_sig = nil
    e.buff_combo  = nil
    e.chain_combo = nil  -- will be rebuilt lazily with fresh spell list
end

return spell_config
