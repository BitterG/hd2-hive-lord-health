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

local vec3_mt = {
    __tostring = function(v)
        return string.format('Vector3(%g, %g, %g)', v[1] or 0, v[2] or 0, v[3] or 0)
    end,
}
local quat_mt = {
    __tostring = function(q)
        return string.format('Quaternion(%g, %g, %g, %g)', q[1] or 0, q[2] or 0, q[3] or 0, q[4] or 1)
    end,
}
local function make_vec(x, y, z)
    return { x or 0, y or 0, z or 0, x = x or 0, y = y or 0, z = z or 0 }
end
local function make_sr_vec3(x, y, z)
    return setmetatable(make_vec(x, y, z), vec3_mt)
end
local function make_sr_quat(x, y, z, w)
    return setmetatable({ __quat = true, x or 0, y or 0, z or 0, w or 1 }, quat_mt)
end

local sr = {}
sr.Vector2 = setmetatable({
    x = function(v) return v[1] end,
    y = function(v) return v[2] end,
}, {
    __call = function(_, x, y) return make_vec(x, y, 0) end,
})
sr.Vector3 = setmetatable({
    x = function(v) assert(not v.__quat, 'Vector3.x called on Quaternion'); return v[1] end,
    y = function(v) assert(not v.__quat, 'Vector3.y called on Quaternion'); return v[2] end,
    z = function(v) assert(not v.__quat, 'Vector3.z called on Quaternion'); return v[3] end,
}, {
    __call = function(_, x, y, z) return make_sr_vec3(x, y, z) end,
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

-- ---------------------------------------------------------- HD2Data API 1 mock
local hub_epoch = 0
local hub_in_mission = false
local hub_now = 0
local hub_state_name = 'wait'
local hub_reason = 'mission world not started'
local hub_build_id = '26251122'
local gone_entities = {}

-- ------------------------------------------ Network & GameSession (goid) mock
local SESSION_OBJ = { __session = true }
local goid_objects = {}
local goid_queries = 0

local function copy_goid_val(v)
    if type(v) == 'table' and not getmetatable(v) then
        local out = {}
        for k, sv in pairs(v) do out[k] = sv end
        return out
    end
    return v
end

sr.Network = {
    game_session = function()
        return hub_in_mission and SESSION_OBJ or nil
    end,
}

sr.GameSession = {
    in_session = function(sess)
        return sess == SESSION_OBJ and hub_in_mission
    end,
    game_object_exists = function(sess, id)
        assert(sess == SESSION_OBJ, 'bad session')
        return type(id) == 'number' and goid_objects[id] ~= nil
    end,
    game_object_field_batched = function(sess, id, out)
        assert(sess == SESSION_OBJ, 'bad session')
        local obj = assert(goid_objects[id], 'missing goid ' .. tostring(id))
        goid_queries = goid_queries + 1
        local res = (type(out) == 'table') and out or {}
        for k, v in pairs(obj) do
            res[k] = copy_goid_val(v)
        end
        return res
    end,
}

local player_pose = { x = 0, y = 0, z = 0, fx = 0, fy = 1, fz = 0 }
local mock_squad = {}
local mdl_gui_canvases = {}
local mdl_gui_errors = {}

local function make_pos_obj(p)
    if type(p) ~= 'table' or p.x == nil or p.y == nil then return nil end
    local obj = { x = p.x, y = p.y, z = p.z or 0 }
    function obj:distance(o)
        if type(o) ~= 'table' then return nil end
        local dx, dy, dz = self.x - (o.x or 0), self.y - (o.y or 0), self.z - (o.z or 0)
        return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    function obj:unpack() return self.x, self.y, self.z end
    function obj:copy() return { x = self.x, y = self.y, z = self.z } end
    return obj
end

rawset(_G, 'stingray', sr)
rawset(_G, 'update', function() end)
rawset(_G, 'shutdown', function() end)

local function make_hub(api_ver)
    local subs = {}
    local sub_seq = 0
    local leases = {}
    local function lease_ready(name)
        local prev = leases[name]
        leases[name] = frame_counter
        if not prev or (frame_counter - prev) > 180 then
            -- Realistic HD2Data contract: first call returns nil; active on next frame!
            return false
        end
        return frame_counter > prev
    end

    local D = {
        api = api_ver or 1,
        version = '0.6.6',
    }
    function D.state()
        return hub_state_name, hub_reason
    end
    function D.ready()
        return hub_state_name == 'ready'
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
    function D.player()
        if not lease_ready('player') or not hub_in_mission then return nil, 0 end
        return {
            peer = '0000000000000001',
            slot = 0,
            is_local = true,
            name = 'Host',
            alive = true,
            life = 'alive',
            health = 100,
            health_max = 100,
            position = make_pos_obj(player_pose),
        }, 0.016
    end
    function D.players(detail)
        if not lease_ready('players') or not hub_in_mission then return nil end
        local out = {
            {
                peer = '0000000000000001',
                slot = 0,
                is_local = true,
                name = 'Host',
                alive = true,
                position = make_pos_obj(player_pose),
            },
        }
        for i, m in ipairs(mock_squad) do
            out[#out + 1] = {
                peer = string.format('000000000000000%d', i + 1),
                slot = m.slot or i,
                is_local = false,
                name = m.name or ('Mate' .. i),
                alive = m.alive ~= false,
                position = make_pos_obj(m),
            }
        end
        return out
    end
    function D.aim()
        if not lease_ready('aim') or not hub_in_mission then return nil end
        return {
            avatar = 1,
            aiming = false,
            camera = make_pos_obj(player_pose),
            forward = { x = player_pose.fx, y = player_pose.fy, z = player_pose.fz or 0 },
            screen = { x = 960, y = 540, depth = 10 },
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

local function make_mdl3_gui_mock(with_fonts)
    local gui_seq_m = 0
    local function check_num(v, name)
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then
            mdl_gui_errors[#mdl_gui_errors + 1] = 'bad number ' .. tostring(name)
            error('MDL3.gui: bad number ' .. tostring(name), 2)
        end
    end
    local function check_color(c)
        if type(c) == 'string' then return end
        if type(c) ~= 'table' then
            mdl_gui_errors[#mdl_gui_errors + 1] = 'bad color'
            error('MDL3.gui: bad color', 2)
        end
        local r = c[1] or c.r
        local g = c[2] or c.g
        local b = c[3] or c.b
        local a = c[4] or c.a or 255
        check_num(r, 'r'); check_num(g, 'g'); check_num(b, 'b'); check_num(a, 'a')
        return { r = r, g = g, b = b, a = a }
    end

    return {
        api = 1,
        canvas = function(opts)
            local live_count = 0
            for _, cv in pairs(mdl_gui_canvases) do
                if not cv.destroyed then live_count = live_count + 1 end
            end
            if live_count >= 16 then
                mdl_gui_errors[#mdl_gui_errors + 1] = 'canvas limit 16 exceeded'
                error('MDL3.gui: canvas limit', 2)
            end
            gui_seq_m = gui_seq_m + 1
            local state = {
                id = gui_seq_m,
                layer = (opts and opts.layer) or 50,
                units = (opts and opts.units) or 'reference',
                visible = true,
                destroyed = false,
                rebuilds = 0,
                updates = 0,
                items = {},
                draft = nil,
                in_frame = false,
            }
            mdl_gui_canvases[gui_seq_m] = state

            local function ensure_draft()
                assert(not state.destroyed and state.in_frame, 'MDL3.gui: not inside begin/finish')
                assert(#state.draft < 4000, 'MDL3.gui: item limit exceeded')
            end

            local cv = {}
            function cv:screen() return { w = 1920, h = 1080, scale = 1, pixel_w = 1920, pixel_h = 1080 } end
            function cv:measure(str, size)
                check_num(size, 'size')
                return #(tostring(str or '')) * size * 0.5
            end
            function cv:status()
                return {
                    items = #state.items,
                    font = with_fonts == true,
                    problem = nil,
                    missing_image = nil,
                }
            end
            function cv:show(v) state.visible = v ~= false end
            function cv:clear() state.items = {}; state.rebuilds = state.rebuilds + 1 end
            function cv:destroy() state.destroyed = true; state.items = {}; state.visible = false end
            function cv:begin()
                assert(not state.destroyed, 'destroyed canvas')
                state.in_frame = true
                state.draft = {}
            end
            function cv:finish()
                assert(state.in_frame, 'finish without begin')
                state.in_frame = false
                local prev = state.items
                local cur = state.draft
                state.draft = nil
                local same_shape = (#prev == #cur)
                local has_text = false
                if same_shape then
                    for i = 1, #cur do
                        if prev[i].kind ~= cur[i].kind then same_shape = false; break end
                        if cur[i].kind == 'text' then
                            has_text = true
                            if prev[i].text ~= cur[i].text or prev[i].x ~= cur[i].x or prev[i].y ~= cur[i].y then
                                same_shape = false; break
                            end
                        end
                    end
                end
                if #prev == 0 or not same_shape then
                    if #cur > 0 then state.rebuilds = state.rebuilds + 1 end
                elseif not has_text then
                    state.updates = state.updates + 1
                end
                state.items = cur
            end
            function cv:rect(x, y, w, h, col)
                ensure_draft()
                check_num(x, 'x'); check_num(y, 'y'); check_num(w, 'w'); check_num(h, 'h')
                assert(w > 0 and h > 0, 'rect size > 0')
                state.draft[#state.draft + 1] = { kind = 'rect', x = x, y = y, w = w, h = h, col = check_color(col) }
            end
            function cv:frame(x, y, w, h, thick, col)
                ensure_draft()
                check_num(x, 'x'); check_num(y, 'y'); check_num(w, 'w'); check_num(h, 'h'); check_num(thick, 'thick')
                assert(w > 0 and h > 0 and thick > 0, 'frame dims > 0')
                state.draft[#state.draft + 1] = { kind = 'frame', x = x, y = y, w = w, h = h, col = check_color(col) }
            end
            function cv:line(x1, y1, x2, y2, w, col)
                ensure_draft()
                check_num(x1, 'x1'); check_num(y1, 'y1'); check_num(x2, 'x2'); check_num(y2, 'y2')
                w = w or 2
                check_num(w, 'width'); assert(w > 0, 'line width > 0')
                state.draft[#state.draft + 1] = {
                    kind = 'line', x1 = x1, y1 = y1, x2 = x2, y2 = y2, w = w, col = check_color(col)
                }
            end
            function cv:triangle(x1, y1, x2, y2, x3, y3, col)
                ensure_draft()
                check_num(x1, 'x1'); check_num(y1, 'y1')
                check_num(x2, 'x2'); check_num(y2, 'y2')
                check_num(x3, 'x3'); check_num(y3, 'y3')
                state.draft[#state.draft + 1] = {
                    kind = 'triangle', x1 = x1, y1 = y1, x2 = x2, y2 = y2, x3 = x3, y3 = y3, col = check_color(col)
                }
            end
            function cv:circle(x, y, r, col, copts)
                ensure_draft()
                check_num(x, 'x'); check_num(y, 'y'); check_num(r, 'r')
                assert(r > 0, 'circle radius > 0')
                if copts and copts.ring ~= nil then
                    check_num(copts.ring, 'ring')
                    assert(copts.ring > 0 and copts.ring < r, 'bad ring thickness')
                end
                state.draft[#state.draft + 1] = {
                    kind = 'circle', x = x, y = y, r = r,
                    ring = copts and copts.ring or nil,
                    col = check_color(col),
                }
            end
            function cv:text(str, x, y, topts)
                ensure_draft()
                assert(type(str) == 'string', 'text string required')
                check_num(x, 'x'); check_num(y, 'y')
                local sz = (topts and topts.size) or 20
                check_num(sz, 'size'); assert(sz > 0, 'text size > 0')
                local col = check_color((topts and topts.color) or { 255, 255, 255, 255 })
                state.draft[#state.draft + 1] = {
                    kind = 'text', text = str, x = x, y = y, size = sz, col = col
                }
                return #str * sz * 0.5, sz * 1.25
            end
            return cv
        end,
    }
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
        __silent_corrupt = function(id, val)
            mom_vals[id] = val
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
        version = '3.0.0-dev.57-preview',
        options = { revision = 1 },
        panel = { visible = false, page = 'mods', builds = 1 },
        gui = (not rawget(_G, '__NO_MDL3_GUI')) and make_mdl3_gui_mock(with_fonts) or nil,
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

function __set_player_pose(x, y, z, fx, fy, fz)
    player_pose.x = x or 0
    player_pose.y = y or 0
    player_pose.z = z or 0
    player_pose.fx = fx or 0
    player_pose.fy = fy or 1
    player_pose.fz = fz or 0
end

function __set_squad(mates)
    mock_squad = mates or {}
end

function __start_mission()
    hub_epoch = hub_epoch + 1
    hub_in_mission = true
    hub_state_name = 'ready'
    hub_reason = nil
    gone_entities = {}
    goid_objects = {}
    goid_queries = 0
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

local function make_entity_handle(id, sem, typ, max_hp, pos)
    local e_epoch = hub_epoch
    local pos_obj = make_pos_obj(pos)
    return {
        id = id,
        semantic_id = sem,
        type = typ,
        mh = max_hp,
        pos = pos_obj,
        is_valid = function() return e_epoch == hub_epoch and not gone_entities[id] end,
        max_health = function(self) return self.mh end,
        position = function(self) return self.pos end,
        is = function(self, s) return self.semantic_id == s end,
    }
end

function __spawn_entity(id, sem, typ, max_hp, net_id, pos)
    gone_entities[id] = nil
    local ent = make_entity_handle(id, sem, typ, max_hp, pos)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_spawned', {
            t = hub_now,
            epoch = hub_epoch,
            mission = hub_epoch,
            entity = ent,
            entity_id = id,
            type = typ,
            semantic_id = sem,
            unit_id = id * 10,
            network_id = net_id,
        })
    end
end

function __damage_entity(id, sem, typ, hp, max_hp, dmg, net_id, pos)
    gone_entities[id] = nil
    local ent = make_entity_handle(id, sem, typ, max_hp, pos)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_damaged', {
            t = hub_now,
            epoch = hub_epoch,
            mission = hub_epoch,
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

function __kill_entity(id, sem, typ, max_hp, net_id, pos)
    gone_entities[id] = true
    local ent = make_entity_handle(id, sem, typ, max_hp, pos)
    local D = rawget(_G, 'HD2Data')
    if D and D.__emit then
        D.__emit('entity_died', {
            t = hub_now,
            epoch = hub_epoch,
            entity = ent,
            entity_id = id,
            type = typ,
            semantic_id = sem,
            position = make_pos_obj(pos),
            local_killer = true,
            observed = 'dead_state',
            network_id = net_id,
        })
    end
end

function __mdl_gui_errors() return #mdl_gui_errors end

function __mdl_gui_canvas_count()
    local n = 0
    for _, cv in pairs(mdl_gui_canvases) do
        if not cv.destroyed then n = n + 1 end
    end
    return n
end

function __mdl_gui_visible_canvases()
    local n = 0
    for _, cv in pairs(mdl_gui_canvases) do
        if not cv.destroyed and cv.visible then n = n + 1 end
    end
    return n
end

function __mdl_gui_canvas_stats(layer)
    for _, cv in pairs(mdl_gui_canvases) do
        if not cv.destroyed and cv.layer == layer then
            local texts = {}
            for _, it in ipairs(cv.items) do
                if it.kind == 'text' then texts[#texts + 1] = it.text end
            end
            return {
                rebuilds = cv.rebuilds,
                updates = cv.updates,
                visible = cv.visible,
                items = #cv.items,
                texts = table.concat(texts, '\n'),
            }
        end
    end
    return nil
end

function __mdl_gui_locator_snapshot()
    local shape_cv, text_cv
    for _, cv in pairs(mdl_gui_canvases) do
        if not cv.destroyed then
            if cv.layer == 62 then shape_cv = cv end
            if cv.layer == 64 then text_cv = cv end
        end
    end
    if not shape_cv or not shape_cv.visible then return nil end
    local items = shape_cv.items
    local radar_bg = items[1]
    local squad1 = items[11]
    local squad2 = items[12]
    local blip = items[18]
    local rim_arrow = items[19]
    local ptr = items[22]
    local texts = {}
    if text_cv and text_cv.visible then
        for _, it in ipairs(text_cv.items) do
            if it.kind == 'text' then texts[#texts + 1] = it.text end
        end
    end
    return {
        radar_cx = radar_bg and radar_bg.x or nil,
        radar_cy = radar_bg and radar_bg.y or nil,
        radar_r = radar_bg and radar_bg.r or nil,
        blip_x = blip and blip.x or nil,
        blip_y = blip and blip.y or nil,
        blip_a = blip and blip.col and blip.col.a or 0,
        rim_a = rim_arrow and rim_arrow.col and rim_arrow.col.a or 0,
        squad1_a = squad1 and squad1.col and squad1.col.a or 0,
        squad2_a = squad2 and squad2.col and squad2.col.a or 0,
        ptr_tip_x = ptr and ptr.x1 or nil,
        ptr_tip_y = ptr and ptr.y1 or nil,
        ptr_a = ptr and ptr.col and ptr.col.a or 0,
        texts = table.concat(texts, '\n'),
        shape_rebuilds = shape_cv.rebuilds,
        shape_updates = shape_cv.updates,
    }
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

function __gui_main_bar_rect()
    for _, g in pairs(guis) do
        if g.alive then
            for _, r in pairs(g.rects) do
                if r.col and r.col.r == 38 and r.col.g == 42 and r.col.b == 50 and (r.size[1] or 0) > 0 then
                    local rx = r.pos.x or r.pos[1]
                    local ry = r.pos.y or r.pos[2]
                    local rw = r.size.x or r.size[1]
                    local rh = r.size.y or r.size[2]
                    return { x = rx, y = ry, w = rw, h = rh, cx = rx + rw * 0.5 }
                end
            end
        end
    end
    return nil
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
function __sr_vec3(x, y, z) return make_sr_vec3(x, y, z) end
function __sr_quat(x, y, z, w) return make_sr_quat(x, y, z, w) end
function __set_goid_fields(id, fields) goid_objects[id] = fields end
function __remove_goid(id) goid_objects[id] = nil end
function __goid_queries() return goid_queries end
