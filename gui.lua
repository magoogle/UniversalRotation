local plugin_label   = 'magoogles_universal_rotation'
local plugin_version = '1.0.1'
console.print('Lua Plugin - Magoogles Universal Rotation - v' .. plugin_version)

local gui = {}

local _spell_trees = {}

local function _get_spell_tree(spell_id)
    local id = tostring(spell_id)
    if _spell_trees[id] then return _spell_trees[id] end
    local t = tree_node:new(2)
    _spell_trees[id] = t
    return t
end

local function _pretty_spell_name(raw)
    if not raw or raw == '' then return nil end
    raw = tostring(raw):gsub('[%[%]]', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local parts = {}
    for p in raw:gmatch('[^_]+') do parts[#parts + 1] = p end
    if #parts >= 2 then table.remove(parts, 1) end -- drop class prefix
    local phrase = table.concat(parts, ' ')
    phrase = phrase:lower():gsub('(%a)([%w\']*)', function(a, b) return a:upper() .. b end)
    return phrase
end


local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end
local function sf(min, max, default, key)
    return slider_float:new(min, max, default, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree      = tree_node:new(0),
    enabled        = cb(false, 'enabled'),
    use_keybind    = cb(false, 'use_keybind'),
    keybind        = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind')),

    global_tree    = tree_node:new(1),
    scan_range     = sf(5.0, 30.0, 16.0, 'scan_range'),
    anim_delay     = sf(0.0, 0.5,  0.05, 'anim_delay'),
    debug_mode     = cb(false, 'debug_mode'),


    overlay_enabled = cb(true, 'overlay_enabled'),
    overlay_x       = si(0, 3000, 20, 'overlay_x'),
    overlay_y       = si(0, 3000, 20, 'overlay_y'),
    overlay_show_buffs = cb(false, 'overlay_show_buffs'),

    export_profile = cb(false, 'export_profile'),
    import_profile = cb(false, 'import_profile'),

    equipped_tree  = tree_node:new(1),
    inactive_tree  = tree_node:new(1),
}

gui.render = function(spell_config, equipped_ids, all_known_ids)
    if not gui.elements.main_tree:push('Magoogles Universal Rotation | v' .. plugin_version) then return end

    gui.elements.enabled:render('Enable', 'Enable the universal rotation')
    gui.elements.use_keybind:render('Use keybind', 'Toggle rotation on/off with a key')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind:render('Toggle Key', 'Key to toggle the rotation')
    end

    if gui.elements.global_tree:push('Global Settings') then
        gui.elements.scan_range:render('Scan Range (yds)', 'How far to scan for enemies', 1)
        gui.elements.anim_delay:render('Animation Delay (s)', 'Global animation delay after each cast', 2)
        gui.elements.debug_mode:render('Debug Mode', 'Print cast info to console')

        gui.elements.overlay_enabled:render('Overlay', 'Show/hide the on-screen overlay')
        if gui.elements.overlay_enabled:get() then
            gui.elements.overlay_x:render('Overlay X', 'Overlay left position (px)', 1)
            gui.elements.overlay_y:render('Overlay Y', 'Overlay top position (px)', 1)
            gui.elements.overlay_show_buffs:render('Show Active Buff List', 'Show active buffs in the overlay')
        end

        gui.elements.export_profile:render('Export class profile', 'Write current settings to a JSON file for sharing')
        gui.elements.import_profile:render('Import class profile', 'Load settings from the class JSON file (overwrites current)')
        gui.elements.global_tree:pop()
    end

    local equipped_set = {}
    for _, id in ipairs(equipped_ids) do
        if id and id > 1 then equipped_set[id] = true end
    end

    if gui.elements.equipped_tree:push('Equipped Spells') then
        render_menu_header('These spells are currently on your skill bar.')
        local any = false
        for _, spell_id in ipairs(equipped_ids) do
            if spell_id and spell_id > 1 then
                any = true
                local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                local spell_tree = _get_spell_tree(spell_id)
                if spell_tree:push(name) then
                    spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                    spell_tree:pop()
                end
            end
        end
        if not any then
            render_menu_header('No spells detected on skill bar.')
        end
        gui.elements.equipped_tree:pop()
    end

    if all_known_ids and #all_known_ids > 0 then
        if gui.elements.inactive_tree:push('Other Known Spells') then
            render_menu_header('Spells detected previously but not currently on bar.')
            for _, spell_id in ipairs(all_known_ids) do
                if not equipped_set[spell_id] then
                    local name = _pretty_spell_name(get_name_for_spell(spell_id)) or ('Spell ' .. spell_id)
                    local spell_tree = _get_spell_tree(spell_id)
                    if spell_tree:push(name) then
                        spell_config.render(spell_id, name, equipped_ids, all_known_ids)
                        spell_tree:pop()
                    end
                end
            end
            gui.elements.inactive_tree:pop()
        end
    end

    gui.elements.main_tree:pop()
end

return gui
