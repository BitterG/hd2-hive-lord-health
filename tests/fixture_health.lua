-- Offline simulation fixture for Source/mods/hivelord/hivelord_health.lua (v2.0.0)
-- Models the MDL3 PUC Lua 5.1 game VM (no ffi), Stingray GUI/World API (including
-- frame-temporary IdString64 lifetime checks!), HD2Data API 1 event hub, and ModOptionsMenu.

local test_appdata = os.getenv('HIVELORD_TEST_APPDATA')
local orig_getenv = os.getenv
os.getenv = function(name)
    if name == 'APPDATA' or name == 'LOCALAPPDATA' or name == 'TEMP' then
        return test_appdata
    end
    return orig_getenv(name)
end

-- Enforce MDL3 game VM rule: require('ffi') and _G.ffi are unavailable in PUC Lua 5.1.
rawset(_G, 'ffi', nil)
local orig_require = require
rawset(_G, 'require', function(name)
    if name == 'ffi' or name == 'jit' then
        error("MDL3: require('" .. tostring(name) .. "') is not available in the game VM (Lua 5.1)", 2)
    end
    return orig_require(name)
end)

-- ------------------------------------------------------- Stingray mock + traps
local frame_counter = 1
local gui_seq = 0
local item_seq = 0
local guis = {}
local gui_created = 0
local world_destroys = 0
local stale_world_destroy = false
local stale_id64_used = false
local native_text_mutated = false
local gui_text_destroys = 0
local churn_counter = 0

local MAIN_WORLD = setmetatable({ kind = 'main' }, { __tostring = function() return '[World:main]' end })
local SHIP_WORLD = setmetatable({ kind = 'ship' }, { __tostring = function() return '[World:ship]' end })
local MISSION_WORLD = setmetatable({ kind = 'mission' }, { __tostring = function() return '[World:mission]' end })
local current_worlds = { MAIN_WORLD, SHIP_WORLD }

local function check_id64(v)
    if type(v) == 'table' and v.__id64 then
        if v.frame ~= frame_counter then
            stale_id64_used = true
            error('Stingray fault: temporary IdString64 reused across frames!', 2)
        end
    end
end

local function make_vec(x, y, z)
    return { x or 0, y or 0, z or 0, x = x or 0, y = y or 0, z = z or 0 }
end

local sr = {}
sr.Vector2 = setmetatable({
    x = function(v) return v[1] end,
    y = function(v) return v[2] end,
}, {
    __call = function(_, x, y) return make_vec(x, y, 0) end,
})
sr.Vector3 = setmetatable({
    x = function(v) return v[1] end,
    y = function(v) return v[2] end,
    z = function(v) return v[3] end,
}, {
    __call = function(_, x, y, z) return make_vec(x, y, z) end,
})
sr.Color = function(a, r, g, b)
    return { a = a, r = r, g = g, b = b }
end

sr.IdString64 = {
    from_hex = function(hex)
        assert(type(hex) == 'string' and #hex == 16, 'bad IdString64 hex')
        return { __id64 = true, hex = hex:lower(), frame = frame_counter }
    end,
}

sr.Material = {
    set_scalar = function(ink, slot, val)
        check_id64(slot)
        ink.scalars[slot.hex] = val
    end,
    set_vector2 = function(ink, slot, val)
        check_id64(slot)
        ink.vec2[slot.hex] = val
    end,
    set_vector4 = function(ink, slot, val)
        check_id64(slot)
        ink.vec4[slot.hex] = val
    end,
    set_texture = function(ink, slot, tex)
        check_id64(slot)
        check_id64(tex)
        ink.textures[slot.hex] = tex.hex
    end,
}

sr.Application = {
    main_world = function() return MAIN_WORLD end,
    worlds = function()
        if rawget(_G, '__WORLD_CHURN') then
            churn_counter = churn_counter + 1
            local cw = setmetatable({ churn = churn_counter }, {
                __tostring = function() return '[World:churn_' .. tostring(churn_counter) .. ']' end,
            })
            return { MAIN_WORLD, cw }
        end
        if rawget(_G, '__FRESH_WORLD_WRAPPERS') then
            -- Simulates wrappers that stringify identically without reference equality.
            local w = setmetatable({}, { __tostring = function() return tostring(current_worlds[2]) end })
            return { MAIN_WORLD, w }
        end
        return { current_worlds[1], current_worlds[2] }
    end,
    can_get = function(kind, id)
        check_id64(id)
        if rawget(_G, '__FONT_NOT_LOADED') then return false end
        return true
    end,
}

sr.World = {
    create_screen_gui = function(world, mode, sx, sy)
        assert(world ~= nil, 'world required')
        gui_seq = gui_seq + 1
        gui_created = gui_created + 1
        local g = {
            id = gui_seq,
            world = world,
            alive = true,
            texts = {},
            rects = {},
            materials = {},
        }
        guis[gui_seq] = g
        return g
    end,
    destroy_gui = function(world, gui)
        world_destroys = world_destroys + 1
        local live = false
        for _, w in ipairs(current_worlds) do
            if w == world then live = true; break end
        end
        if not live or not gui or gui.world ~= world then
            stale_world_destroy = true
            error('Stingray fault: World.destroy_gui called on stale/mismatched world!', 2)
        end
        gui.alive = false
        gui.texts = {}
        gui.rects = {}
    end,
}

sr.Gui = {
    resolution = function() return 1920, 1080 end,
    material = function(gui, mat_id)
        assert(gui and gui.alive, 'dead gui')
        check_id64(mat_id)
        local ink = { mat = mat_id.hex, scalars = {}, vec2 = {}, vec4 = {}, textures = {} }
        gui.materials[mat_id.hex] = ink
        return ink
    end,
    text_extents = function(gui, text, font, size)
        assert(gui and gui.alive, 'dead gui')
        check_id64(font)
        local cjk_ok = not rawget(_G, '__LATIN_ONLY_ATLAS')
        local w = 0
        for ch in tostring(text):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
            if #ch > 1 then
                w = w + (cjk_ok and (size * 1.0) or (size * 0.5))
            else
                w = w + size * 0.5
            end
        end
        return make_vec(0, 0, 0), make_vec(w, size, 0)
    end,
    text = function(gui, str, font, size, mat, pos, col)
        assert(gui and gui.alive, 'dead gui')
        check_id64(font)
        check_id64(mat)
        item_seq = item_seq + 1
        local is_native = type(font) == 'table' and font.__id64 == true
        gui.texts[item_seq] = {
            text = str,
            size = size,
            pos = pos,
            col = col,
            native = is_native,
            font = is_native and font.hex or tostring(font),
        }
        return item_seq
    end,
    update_text = function(gui, id, str, font, size, mat, pos, col)
        assert(gui and gui.alive, 'dead gui')
        check_id64(font)
        check_id64(mat)
        local entry = assert(gui.texts[id], 'unknown text handle')
        if entry.native then
            native_text_mutated = true
            error('Native game-UI font handle must not be passed to Gui.update_text!', 2)
        end
        entry.text = str
        entry.size = size
        entry.pos = pos
        entry.col = col
    end,
    destroy_text = function(gui, id)
        assert(gui and gui.alive, 'dead gui')
        gui_text_destroys = gui_text_destroys + 1
        local entry = gui.texts[id]
        if entry and entry.native then
            native_text_mutated = true
            error('Native game-UI font handle must not be passed to Gui.destroy_text!', 2)
        end
        gui.texts[id] = nil
    end,
    rect = function(gui, pos, size, col)
        assert(gui and gui.alive, 'dead gui')
        item_seq = item_seq + 1
        gui.rects[item_seq] = { pos = pos, size = size, col = col }
        return item_seq
    end,
    update_rect = function(gui, id, pos, size, col)
        assert(gui and gui.alive, 'dead gui')
        local r = assert(gui.rects[id], 'unknown rect handle')
        r.pos, r.size, r.col = pos, size, col
    end,
    destroy_rect = function(gui, id)
        assert(gui and gui.alive, 'dead gui')
        gui.rects[id] = nil
    end,
}

rawset(_G, 'stingray', sr)
rawset(_G, 'update', function() end)
rawset(_G, 'shutdown', function() end)

-- ---------------------------------------------------------- HD2Data API 1 mock
local hub_epoch = 0
local hub_in_mission = false
local hub_now = 0
local hub_state_name = 'wait'
local hub_reason = 'mission world not started'
local hub_build_id = '26251122'
local gone_entities = {}

local function make_hub(api_ver)
    local subs = {}
    local sub_seq = 0
    local D = {
        api = api_ver or 1,
        version = '0.3.0',
    }
    function D.state()
        return hub_state_name, hub_reason
    end
    function D.status()
        return {
            ready = hub_state_name == 'ready',
            state = hub_state_name,
            build_id = hub_build_id,
            reason = hub_reason,
        }
    end
    function D.mission()
        return {
            in_mission = hub_in_mission,
            epoch = hub_epoch,
            now = hub_now,
        }
    end
    function D.on(event, fn, opts)
        sub_seq = sub_seq + 1
        local s = {
            id = sub_seq,
            event = event,
            fn = fn,
            owner = opts and opts.owner or 'anon',
            state = 'active',
        }
        function s:active() return self.state == 'active' end
        function s:unsubscribe() self.state = 'removed'; subs[self.id] = nil; return self end
        subs[sub_seq] = s
        return s
    end
    function D.__emit(event, payload)
        for _, s in pairs(subs) do
            if s.state == 'active' and s.event == event then
                s.fn(payload)
            end
        end
    end
    function D.__active_sub_count()
        local n = 0
        for _, s in pairs(subs) do
            if s.state == 'active' then n = n + 1 end
        end
        return n
    end
    function D.__drop_subs()
        for _, s in pairs(subs) do s.state = 'removed' end
    end
    return D
end

if not rawget(_G, '__NO_HUB_AT_BOOT') then
    rawset(_G, 'HD2Data', make_hub(rawget(_G, '__BAD_HUB_API') or 1))
end

-- Optional MDL3 + ModOptionsMenu mock when requested by test pre-script.
function __install_mdl3_mock(with_fonts, lang)
    local mom_vals = {}
    local mom_cbs = {}
    local mom_opts = {}
    local MOM = {
        api = 1,
        provider = 'MDL',
        register_option = function(id, spec)
            mom_opts[id] = spec
            if mom_vals[id] == nil then mom_vals[id] = spec.default end
            return true
        end,
        get = function(id) return mom_vals[id] end,
        set = function(id, val)
            mom_vals[id] = val
            for _, cb in ipairs(mom_cbs[id] or {}) do cb(val, id) end
            return true
        end,
        on_change = function(id, cb)
            mom_cbs[id] = mom_cbs[id] or {}
            table.insert(mom_cbs[id], cb)
            return true
        end,
    }
    rawset(_G, 'ModOptionsMenu', MOM)
    rawset(_G, 'MDL', { i18n = { code = lang or 'zh-Hans' } })
    rawset(_G, 'MDL3', {
        version = '3.0.0-dev.21-preview',
        options = { revision = 1 },
        panel = { visible = false, page = 'mods', builds = 1 },
        ui = {
            state = 'ready',
            open = false,
            active = false,
            language = lang or 'zh-Hans',
            fonts = with_fonts and {
                font = '1122334455667788',
                material = '99aabbccddeeff00',
                atlas = 'deadbeefcafebabe',
            } or nil,
        },
        __mom_opts = mom_opts,
    })
end

if rawget(_G, '__WITH_MDL3') then
    __install_mdl3_mock(true, rawget(_G, '__MDL3_LANG') or 'zh-Hans')
end

-- ----------------------------------------------------- Test driver & inspectors
function __advance_frame(dt)
    frame_counter = frame_counter + 1
    hub_now = hub_now + (dt or 0.016)
    _G.update(dt or 0.016)
end

function __install_hub(api_ver)
    rawset(_G, 'HD2Data', make_hub(api_ver or 1))
end

function __start_mission()
    hub_epoch = hub_epoch + 1
    hub_in_mission = true
    hub_state_name = 'ready'
    hub_reason = nil
    gone_entities = {}
    current_worlds = { MAIN_WORLD, MISSION_WORLD }
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('mission_started', { t = hub_now, epoch = hub_epoch })
    end
end

function __end_mission()
    hub_in_mission = false
    hub_state_name = 'wait'
    hub_reason = 'mission ended'
    current_worlds = { MAIN_WORLD, SHIP_WORLD }
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('mission_ended', { t = hub_now, epoch = hub_epoch })
    end
end

local function make_entity_handle(id, sem, typ, max_hp)
    local e_epoch = hub_epoch
    return {
        id = id,
        semantic_id = sem,
        type = typ,
        mh = max_hp,
        is_valid = function() return e_epoch == hub_epoch and not gone_entities[id] end,
        max_health = function(self) return self.mh end,
        is = function(self, s) return self.semantic_id == s end,
    }
end

function __spawn_entity(id, sem, typ, max_hp, net_id)
    gone_entities[id] = nil
    local ent = make_entity_handle(id, sem, typ, max_hp)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_spawned', {
            t = hub_now,
            epoch = hub_epoch,
            entity = ent,
            entity_id = id,
            type = typ,
            semantic_id = sem,
            unit_id = id * 10,
            network_id = net_id,
        })
    end
end

function __damage_entity(id, sem, typ, hp, max_hp, dmg, net_id)
    gone_entities[id] = nil
    local ent = make_entity_handle(id, sem, typ, max_hp)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_damaged', {
            t = hub_now,
            epoch = hub_epoch,
            entity = ent,
            entity_id = id,
            type = typ,
            semantic_id = sem,
            health = hp,
            max_health = max_hp,
            damage = dmg or 1000,
            downed = false,
            local_attacker = true,
            network_id = net_id,
        })
    end
end

function __submerge_entity(id)
    gone_entities[id] = true
end

function __kill_entity(id, sem, typ, max_hp, net_id)
    gone_entities[id] = true
    local ent = make_entity_handle(id, sem, typ, max_hp)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_died', {
            t = hub_now,
            epoch = hub_epoch,
            entity = ent,
            entity_id = id,
            type = typ,
            semantic_id = sem,
            local_killer = true,
            observed = 'dead_state',
            network_id = net_id,
        })
    end
end

function __gui_visible_texts()
    local out = {}
    for _, g in pairs(guis) do
        if g.alive then
            for _, t in pairs(g.texts) do
                if t.col and (t.col.a or 0) > 0 and t.text:match('%S') then
                    out[#out + 1] = t.text
                end
            end
        end
    end
    table.sort(out)
    return table.concat(out, '\n')
end

function __gui_visible_rects()
    local n = 0
    for _, g in pairs(guis) do
        if g.alive then
            for _, r in pairs(g.rects) do
                if r.col and (r.col.a or 0) > 0 and (r.size[1] or 0) > 0 and (r.size[2] or 0) > 0 then
                    n = n + 1
                end
            end
        end
    end
    return n
end

function __gui_live_text_handles()
    local n = 0
    for _, g in pairs(guis) do
        if g.alive then
            for _ in pairs(g.texts) do n = n + 1 end
        end
    end
    return n
end

function __gui_created() return gui_created end
function __world_destroys() return world_destroys end
function __stale_world_destroy() return stale_world_destroy end
function __stale_id64_used() return stale_id64_used end
function __native_text_mutated() return native_text_mutated end
function __hub_sub_count()
    local D = rawget(_G, 'HD2Data')
    return (D and D.__active_sub_count) and D.__active_sub_count() or 0
end
