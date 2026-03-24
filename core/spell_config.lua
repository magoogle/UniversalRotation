local plugin_label = 'magoogles_universal_rotation'

local spell_config = {}

local _elements = {}
local _buff_name_cache = {}
local _buff_state = {}

local buff_provider = require 'core.buff_provider'

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

        spell_type   = combo_box:new(0, get_hash(key(spell_id, 'spell_type'))),

        range        = slider_float:new(1.0, 30.0, 12.0, get_hash(key(spell_id, 'range'))),
        aoe_range    = slider_float:new(1.0, 20.0, 6.0,  get_hash(key(spell_id, 'aoe_range'))),

        require_buff = checkbox:new(false, get_hash(key(spell_id, 'require_buff'))),
        buff_combo   = nil,
        buff_stacks  = slider_int:new(1, 50, 1, get_hash(key(spell_id, 'buff_stacks'))),

        elite_only   = checkbox:new(false, get_hash(key(spell_id, 'elite_only'))),
        boss_only    = checkbox:new(false, get_hash(key(spell_id, 'boss_only'))),
        min_enemies  = slider_int:new(0, 15, 0, get_hash(key(spell_id, 'min_enemies'))),
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

function spell_config.render(spell_id, display_name)
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)

    e.enabled:render('Enable', 'Enable this spell in the rotation')
    if not e.enabled:get() then return end

    e.priority:render('Priority (1=highest)', 'Lower number = cast first')
    e.spell_type:render('Spell type', { 'Auto', 'Melee', 'Ranged' }, 'Auto = default; Melee will move into range before casting')

    local stype = e.spell_type:get() or 0
    local range_label = (stype == 1) and 'Engage range (yds)' or 'Spell range (yds)'
    local range_tip = (stype == 1) and 'Melee: will move toward the closest valid enemy until within this range' or 'Skip this spell if no valid enemy is within this range'
    e.range:render(range_label, range_tip, 1)
    e.aoe_range:render('AOE check radius (yds)', 'Count enemies within this radius of your character (used for Min enemies near you)', 1)

    e.min_enemies:render('Min enemies near you', 'Minimum enemies within AOE check radius (0 = always)', 2)

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

    e.cooldown:render('Min cooldown (s)', 'Minimum seconds between casts once charges are spent', 3)
    e.charges:render('Charges', 'Casts allowed before cooldown applies (1 = normal)', 3)

    e.elite_only:render('Elite / Champion only', 'Only cast against elites and champions')
    e.boss_only:render('Boss only', 'Only cast against bosses')
end

function spell_config.get(spell_id)
    local e = get_elements(spell_id)
    local st = _get_buff_state(spell_id)

    return {
        enabled       = e.enabled:get(),
        priority      = e.priority:get(),
        cooldown      = e.cooldown:get(),
        charges       = e.charges:get(),
        spell_type    = e.spell_type:get(),
        range         = e.range:get(),
        aoe_range     = e.aoe_range:get(),
        elite_only    = e.elite_only:get(),
        boss_only     = e.boss_only:get(),
        min_enemies   = e.min_enemies:get(),
        require_buff  = e.require_buff:get(),
        buff_hash     = st.buff_hash or 0,
        buff_name     = (st.buff_name ~= '' and st.buff_name) or (_buff_name_cache[tostring(spell_id)] or ''),
        buff_stacks   = e.buff_stacks:get(),
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

    _set_element(e.enabled, cfg.enabled)
    _set_element(e.priority, cfg.priority)
    _set_element(e.cooldown, cfg.cooldown)
    _set_element(e.charges, cfg.charges)
    _set_element(e.spell_type, cfg.spell_type)
    _set_element(e.range, cfg.range)
    _set_element(e.aoe_range, cfg.aoe_range)
    _set_element(e.elite_only, cfg.elite_only)
    _set_element(e.boss_only, cfg.boss_only)
    _set_element(e.min_enemies, cfg.min_enemies)
    _set_element(e.require_buff, cfg.require_buff)
    _set_element(e.buff_stacks, cfg.buff_stacks)

    if type(cfg.buff_hash) == 'number' then st.buff_hash = cfg.buff_hash end
    if type(cfg.buff_name) == 'string' then st.buff_name = cfg.buff_name end
    if type(cfg.buff_name) == 'string' and cfg.buff_name ~= '' then
        _buff_name_cache[tostring(spell_id)] = cfg.buff_name
    end

    st.last_list_sig = nil
    e.buff_combo = nil
end

return spell_config