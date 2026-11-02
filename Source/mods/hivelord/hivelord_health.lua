-- HD2-Addon: mods/hivelord/hivelord_health
-- Hive Lord Health 2.0.0 -- Real-time exact Boss Health Bar for Helldivers 2.
-- Adapted for MDL3 (PUC Lua 5.1 game VM) + HD2 Data Hub >= 0.3.0 (HD2Data API 1).
-- Strictly READ-ONLY: zero FFI, zero process memory writes, zero hardcoded build RVAs.

local ADDON_ID = 'mods/hivelord/hivelord_health'
local VERSION = '2.0.0'
local HIVE_LORD_SEMANTIC = 'enemy/v1/terminids/hive_lord'
local HIVE_LORD_TYPE_HEX = 'D465D9C7F77A07CB'
local DEFAULT_MAX_HP = 150000
local DEBUG_FONT_ID = 'core/performance_hud/debug'

-- Pure-ASCII UTF-8 string table for Chinese + English UI labels in MDL3 & native font HUD.
local ZH = {
    cjk_probe = '\233\156\184\231\142\139\232\153\171',
    mod_title = '\233\156\184\231\142\139\232\153\171\232\161\128\233\135\143\230\152\190\231\164\186 (Hive Lord HP)',
    mod_desc = '\229\159\186\228\186\142 MDL3 + HD2 Data Hub 0.3.0 \231\154\132\233\156\184\231\142\139\232\153\171\229\174\158\230\151\182\231\178\190\231\161\174\232\161\128\233\135\143\230\157\161\230\152\190\231\164\186\230\168\161\231\187\132\239\188\136\231\186\175\229\143\170\232\175\187\239\188\137\227\128\130',
    boss_name = '\233\156\184\231\142\139\232\153\171 HIVE LORD',
    slain = '\229\183\178\229\135\187\230\157\128 SLAIN',
    submerged = '\230\189\156\229\156\176 SUBMERGED',
    preview_tag = '\233\162\132\232\167\136\230\168\161\229\188\143 PREVIEW',
    active_tag = '\229\174\158\230\151\182\232\191\189\232\184\170 LIVE',
    opt_hud = '\230\152\190\231\164\186\233\156\184\231\142\139\232\153\171\232\161\128\230\157\161 (Show Boss Bar)',
    opt_hud_desc = '\229\156\168\228\187\187\229\138\161\228\184\173\233\156\184\231\142\139\232\153\171\229\135\186\231\142\176\230\136\150\229\143\151\228\188\164\230\151\182\230\152\190\231\164\186\229\174\158\230\151\182\232\161\128\233\135\143\230\157\161\228\184\142\231\178\190\231\161\174\230\149\176\229\128\188\227\128\130',
    opt_preview = '\232\136\176\230\161\165\233\162\132\232\167\136\232\161\128\230\157\161 (Preview HUD)',
    opt_preview_desc = '\231\171\139\229\141\179\230\152\190\231\164\186\231\164\186\228\190\139\232\161\128\230\157\161\239\188\140\230\150\185\228\190\191\229\156\168\232\136\176\230\161\165\230\136\150\228\187\187\229\138\161\228\184\173\229\174\158\230\151\182\232\176\131\230\149\180\228\189\141\231\189\174\228\184\142\231\188\169\230\148\190\227\128\130',
    opt_pos = '\232\161\128\230\157\161\228\189\141\231\189\174 (Position)',
    opt_pos_top = '\233\161\182\233\131\168\229\177\133\228\184\173 (Top Boss Bar)',
    opt_pos_bottom = '\229\186\149\233\131\168\229\177\133\228\184\173 (Bottom Classic)',
    opt_scale = '\231\149\140\233\157\162\231\188\169\230\148\190 (HUD Scale)',
    opt_offset_y = '\229\158\130\231\155\180\232\190\185\232\183\157 (Vertical Margin)',
    opt_offset_y_desc = '\232\183\157\231\166\187\229\177\143\229\185\149\233\161\182\233\131\168\230\136\150\229\186\149\233\131\168\231\154\132\229\131\143\231\180\160\232\190\185\232\183\157\239\188\136\230\140\137 1080p \229\159\186\229\135\134\232\135\170\233\128\130\229\186\148\231\188\169\230\148\190\239\188\137\227\128\130',
    opt_alpha = '\228\184\141\233\128\143\230\152\142\229\186\166 (Opacity)',
    opt_bar = '\231\187\152\229\136\182\229\174\158\229\191\131\232\161\128\233\135\143\230\157\161 (Solid Progress Bar)',
    opt_death_hold = '\229\135\187\230\157\128\229\144\142\228\191\157\231\149\153\231\167\146\230\149\176 (Death Hold s)',
}

local EN = {
    mod_title = 'Hive Lord Health Bar',
    opt_hud = 'Show Boss Health Bar',
    opt_hud_desc = 'Display real-time exact health bar and HP numbers when a Hive Lord spawns or takes damage.',
    opt_preview = 'Preview HUD on Ship',
    opt_preview_desc = 'Show a sample Boss Health Bar immediately to tune scale and vertical margin.',
    opt_pos = 'Bar Anchor Position',
    opt_pos_top = 'Top Center (Boss Bar)',
    opt_pos_bottom = 'Bottom Center (Classic)',
    opt_scale = 'HUD Scale',
    opt_offset_y = 'Vertical Margin (px)',
    opt_offset_y_desc = 'Distance from the anchored top or bottom screen edge (scaled from 1080p).',
    opt_alpha = 'Opacity',
    opt_bar = 'Draw Solid Progress Bar',
    opt_death_hold = 'Post-Kill Hold (seconds)',
}

local function is_ctor(v)
    local t = type(v)
    return t == 'function' or t == 'table' or t == 'userdata'
end

local function ok_call(fn, ...)
    if not is_ctor(fn) then return nil end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
    return nil
end

-- ---------------------------------------------------------------------- logging
local outdir, out
if io and io.open then
    local app = ok_call(os.getenv, 'APPDATA')
    local loc = ok_call(os.getenv, 'LOCALAPPDATA')
    local tmp = ok_call(os.getenv, 'TEMP')
    local cands = {}
    if app then cands[#cands + 1] = app .. '/Arrowhead/Helldivers2' end
    if loc then cands[#cands + 1] = loc .. '/MDL3' end
    if loc then cands[#cands + 1] = loc .. '/CowboyBingus/Helldivers2/Logs' end
    if tmp then cands[#cands + 1] = tmp end
    cands[#cands + 1] = '.'
    for _, d in ipairs(cands) do
        local f = io.open(d .. '/hivelord_health.log', 'a')
        if f then outdir, out = d, f; break end
    end
end

local function w(line)
    if not out then return end
    if not pcall(function() out:write(line, '\n'); out:flush() end) then out = nil end
end
local function wf(fmt, ...) w(string.format(fmt, ...)) end

wf('=== hivelord-health v%s  vm=%s  outdir=%s ===', VERSION, tostring(_VERSION), tostring(outdir))

-- ---------------------------------------------------------------- configuration
local DEFAULTS = {
    hud = true,
    hud_preview = false,
    hud_position = 'top',       -- 'top' (Boss Bar below compass) or 'bottom'
    hud_scale = 1.0,
    hud_offset_y = 135,         -- pixels from top/bottom at 1080p
    hud_offset_x = 0,
    hud_alpha = 0.90,
    hud_bar = true,
    hud_native_font = true,
    poll_seconds = 0.25,
    burrow_hold_seconds = 60.0,
    death_hold_seconds = 5.0,
    surface_cap = 12,
    debug = false,
}

local C = {}
for k, v in pairs(DEFAULTS) do C[k] = v end
local cfg_explicit = {}

local DEFAULT_CFG = [[# Hive Lord Health v2.0.0 settings (MDL3 + HD2 Data Hub 0.3.0)
# Edit here or adjust live in-game via ESC -> MDL Settings -> Hive Lord HP.
# Delete this file to regenerate defaults; existing files are never overwritten.

# Show the Hive Lord Boss Health Bar on screen (true / false).
hud = true

# Anchor position: top (below compass) or bottom (above lower edge).
hud_position = top

# Scale factor on top of 1080p resolution scaling (e.g. 0.75, 1.0, 1.25).
hud_scale = 1.00

# Distance in 1080p pixels from the anchored top or bottom edge.
hud_offset_y = 135

# Overall opacity from 0.20 to 1.00.
hud_alpha = 0.90

# Draw solid progress bar frame and fill rectangles (true / false).
hud_bar = true

# Status / hub diagnostic check interval in seconds.
poll_seconds = 0.25

# Seconds to keep last HP visible when the Hive Lord burrows underground.
burrow_hold_seconds = 60.0

# Seconds to keep 0 / 150000 visible after the Hive Lord is slain.
death_hold_seconds = 5.0

# Verbose per-hit event logging to hivelord_health.log.
debug = false
]]

local STRING_KEYS = { hud_position = { top = true, bottom = true } }

do
    local app = ok_call(os.getenv, 'APPDATA')
    local p = (app and (app .. '/Arrowhead/Helldivers2') or outdir)
    p = p and (p .. '/hivelord_health.cfg') or nil
    if p and io and io.open then
        local f = io.open(p, 'r')
        if not f then
            local nf = io.open(p, 'w')
            if nf then
                pcall(function() nf:write(DEFAULT_CFG); nf:close() end)
                wf('CONFIG created %s', p)
            end
            f = io.open(p, 'r')
        end
        if f then
            for raw_l in f:lines() do
                local l = raw_l:gsub('#.*$', '')
                local k, v = l:match('^%s*([%w_]+)%s*=%s*([%w_%.%-]+)')
                if k and C[k] ~= nil then
                    if type(DEFAULTS[k]) == 'boolean' then
                        if v == 'true' then C[k] = true; cfg_explicit[k] = true
                        elseif v == 'false' then C[k] = false; cfg_explicit[k] = true end
                    elseif STRING_KEYS[k] then
                        local sv = v:lower()
                        if STRING_KEYS[k][sv] then C[k] = sv; cfg_explicit[k] = true end
                    elseif type(DEFAULTS[k]) == 'number' then
                        local n = tonumber(v)
                        if n and n == n then C[k] = n; cfg_explicit[k] = true end
                    end
                end
            end
            f:close()
            wf('CONFIG loaded %s (hud=%s pos=%s scale=%.2f offset_y=%d alpha=%.2f)',
                p, tostring(C.hud), tostring(C.hud_position), C.hud_scale, C.hud_offset_y, C.hud_alpha)
        end
    end
end

-- ------------------------------------------------------------------ environment
local function write_status_file(head, extra_lines)
    if not outdir or not io or not io.open then return end
    local f = io.open(outdir .. '/hivelord_health_STATUS.txt', 'w')
    if not f then return end
    pcall(function()
        local mdl3 = rawget(_G, 'MDL3')
        local mdl_ver = type(mdl3) == 'table' and tostring(mdl3.version or 'present') or 'none'
        f:write('hivelord-health-v' .. VERSION .. ' (read-only, MDL3 + HD2Data)\n')
        f:write('vm=' .. tostring(_VERSION) .. '  mdl3=' .. mdl_ver .. '\n')
        f:write('RESULT: ' .. tostring(head) .. '\n')
        for _, line in ipairs(extra_lines or {}) do f:write(line, '\n') end
        f:close()
    end)
end

local function refuse(why)
    wf('REFUSED %s', why)
    write_status_file('REFUSED - ' .. why, {})
    return {
        installed = false,
        status = 'failed',
        name = ZH.mod_title,
        version = VERSION,
        reason = why,
    }
end

local sr = rawget(_G, 'stingray')
if type(sr) ~= 'table' and type(sr) ~= 'userdata' then
    return refuse('no stingray global (engine Lua API unavailable)')
end
local existing = rawget(_G, '__HIVELORD_HEALTH')
if type(existing) == 'table' and existing.active == true then
    wf('ALREADY_LOADED')
    return {
        installed = true,
        name = ZH.mod_title,
        version = VERSION,
        reason = 'already loaded',
    }
end

-- ------------------------------------------------------------------------ state
local M = {
    version = VERSION,
    active = true,
    clock = 0,
    next_poll = 0,
    hub_ref = nil,
    subs = {},
    hub_state = 'waiting_for_hub',
    hub_reason = nil,
    hub_build = nil,
    hub_version = nil,
    in_mission = false,
    epoch = nil,
    records = {},
    best = nil,
    live_count = 0,
    ever_seen = 0,
    last_logged_diag = nil,
    last_hud = nil,
    -- Primary bar / debug-font surface:
    gui = nil,
    gui_world = nil,
    gui_world_key = nil,
    gui_epoch = nil,
    surfaces = 0,
    surface_capped = false,
    texts = nil,
    text_creates = 0,
    rects = nil,
    rect_creates = 0,
    -- Dedicated native-font text surface (created above M.gui; rebuilt on text change,
    -- never passing native-font handles to Gui.update_text or Gui.destroy_text):
    text_gui = nil,
    text_world = nil,
    text_last_rebuild = -100,
    font_retry_at = 0,
    cjk_cache = {},
    measure_cache = {},
    measure_cache_count = 0,
    draw_key = nil,
    bar_key = nil,
    font_mode = nil,
    -- MDL3 ESC menu foreground & live slider preview state:
    live_menu_preview = false,
    fg_sig = nil,
    fg_dirty = false,
    fg_due_at = 0,
    fg_next_at = 0,
    options_bound = false,
}

local function format_int(n)
    local raw = tostring(math.max(0, math.floor((tonumber(n) or 0) + 0.5)))
    local out = ''
    while #raw > 3 do
        out = ',' .. raw:sub(-3) .. out
        raw = raw:sub(1, #raw - 3)
    end
    return raw .. out
end

local function is_chinese_ui()
    local shared = rawget(_G, 'BingusTranslations')
    local tag = type(shared) == 'table' and shared.game_language or nil
    if type(tag) ~= 'string' or tag == '' then
        local mdl = rawget(_G, 'MDL')
        local i18n = type(mdl) == 'table' and mdl.i18n or nil
        tag = type(i18n) == 'table' and i18n.code or nil
    end
    if type(tag) ~= 'string' or tag == '' then
        local mdl3 = rawget(_G, 'MDL3')
        local ui = type(mdl3) == 'table' and mdl3.ui or nil
        tag = type(ui) == 'table' and (ui.language or ui.language_code or ui.lang) or nil
    end
    if type(tag) ~= 'string' or tag == '' then
        -- MDL3's default UI locale is Chinese unless configured to English.
        return rawget(_G, 'MDL3') ~= nil
    end
    local norm = tag:lower():gsub('_', '-')
    return norm:find('^zh') ~= nil or norm == 'cn' or norm == 'zhs' or norm == 'zht'
        or norm == 'schinese' or norm == 'tchinese'
end

local function L(key)
    return function()
        return is_chinese_ui() and ZH[key] or (EN[key] or ZH[key])
    end
end

local function update_status_snapshot()
    local lines = {}
    lines[#lines + 1] = string.format('hub: state=%s version=%s build=%s%s',
        tostring(M.hub_state), tostring(M.hub_version or '?'), tostring(M.hub_build or '?'),
        M.hub_reason and (' reason=' .. tostring(M.hub_reason)) or '')
    lines[#lines + 1] = string.format('mission: in_mission=%s epoch=%s seen_total=%d live=%d',
        tostring(M.in_mission), tostring(M.epoch), M.ever_seen, M.live_count)
    if M.best then
        local r = M.best
        local pct = r.max > 0 and (100.0 * r.hp / r.max) or 0.0
        local tag = r.dead and 'SLAIN' or (r.burrowed and 'SUBMERGED' or 'LIVE')
        lines[#lines + 1] = string.format('hive_lord: %d / %d (%.1f%%) [%s] entity_id=%s net_id=%s',
            r.hp, r.max, pct, tag, tostring(r.id), tostring(r.network_id))
    end
    if M.last_hud then
        lines[#lines + 1] = 'hud: ' .. M.last_hud
    end

    local head
    if M.best then
        head = string.format('HIVE LORD  %d / %d  (%s)',
            M.best.hp, M.best.max, M.best.dead and 'SLAIN' or 'LIVE')
    elseif M.hub_state == 'waiting_for_hub' then
        head = 'WAITING - HD2Data global not found yet (enable HD2 Data Hub >= 0.3.0)'
    elseif M.hub_state == 'unsupported' or M.hub_state == 'error' or M.hub_state == 'bad_api' then
        head = 'HUB UNAVAILABLE - ' .. tostring(M.hub_state)
            .. (M.hub_reason and (' (' .. tostring(M.hub_reason) .. ')') or '')
    else
        head = string.format('READY (%s) - waiting for Hive Lord in mission', tostring(M.hub_state))
    end
    write_status_file(head, lines)
end

-- ---------------------------------------------------------- ModOptionsMenu (MDL3)
local function mdl_settings_open()
    local mdl = rawget(_G, 'MDL3')
    local panel = type(mdl) == 'table' and mdl.panel or nil
    return type(panel) == 'table' and panel.visible == true and panel.page == 'settings'
end

local function trigger_mdl_live_preview()
    if mdl_settings_open() then
        M.live_menu_preview = true
        M.fg_dirty = true
        M.fg_due_at = math.min(M.fg_due_at, M.clock + 0.05)
    end
end

local function find_options_api()
    local mom = rawget(_G, 'ModOptionsMenu')
    if type(mom) == 'table' and type(mom.register_option) == 'function' then return mom end
    local mdl = rawget(_G, 'MDL3')
    local compat = type(mdl) == 'table' and (mdl.mod_options_menu or mdl.mod_options) or nil
    if type(compat) == 'table' and type(compat.register_option) == 'function' then return compat end
    return nil
end

local function bind_mod_options()
    if M.options_bound then return end
    local MOM = find_options_api()
    if not MOM then return end
    M.options_bound = true

    local function reg(key, spec, from_mom, apply_fn, visual_preview)
        local id = 'hivelord_health.' .. key
        spec.mod_id = ADDON_ID
        spec.mod = L('mod_title')
        local ok = ok_call(MOM.register_option, id, spec)
        if not ok then return end
        if type(MOM.get) == 'function' and not cfg_explicit[key] then
            local saved = ok_call(MOM.get, id)
            if saved ~= nil then apply_fn(from_mom(saved), false) end
        end
        if type(MOM.on_change) == 'function' then
            ok_call(MOM.on_change, id, function(val)
                apply_fn(from_mom(val), true)
                M.draw_key, M.bar_key = nil, nil
                if visual_preview then trigger_mdl_live_preview() end
            end)
        end
    end

    local id_fn = function(v) return v end
    reg('hud', {
        type = 'toggle', default = DEFAULTS.hud,
        label = L('opt_hud'), description = L('opt_hud_desc'),
    }, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud = v
            if changed then wf('OPTION hud=%s', tostring(v)) end
        end
    end, false)

    reg('hud_preview', {
        type = 'toggle', default = DEFAULTS.hud_preview,
        label = L('opt_preview'), description = L('opt_preview_desc'),
    }, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud_preview = v
            if changed then wf('OPTION hud_preview=%s', tostring(v)) end
        end
    end, true)

    reg('hud_position', {
        type = 'choice', default = 1,
        choices = { L('opt_pos_top'), L('opt_pos_bottom') },
        label = L('opt_pos'),
    }, function(v) return v == 2 and 'bottom' or 'top' end, function(v, changed)
        if v == 'top' or v == 'bottom' then
            C.hud_position = v
            if changed then wf('OPTION hud_position=%s', v) end
        end
    end, true)

    reg('hud_scale', {
        type = 'slider', min = 0.50, max = 2.50, step = 0.05, default = DEFAULTS.hud_scale,
        label = L('opt_scale'),
    }, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0.5 and v <= 2.5 then
            C.hud_scale = v
            if changed then wf('OPTION hud_scale=%.2f', v) end
        end
    end, true)

    reg('hud_offset_y', {
        type = 'slider', min = 20, max = 500, step = 5, default = DEFAULTS.hud_offset_y,
        label = L('opt_offset_y'), description = L('opt_offset_y_desc'),
    }, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 20 and v <= 500 then
            C.hud_offset_y = v
            if changed then wf('OPTION hud_offset_y=%d', v) end
        end
    end, true)

    reg('hud_alpha', {
        type = 'slider', min = 0.20, max = 1.00, step = 0.05, default = DEFAULTS.hud_alpha,
        label = L('opt_alpha'),
    }, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0.2 and v <= 1.0 then
            C.hud_alpha = v
            if changed then wf('OPTION hud_alpha=%.2f', v) end
        end
    end, true)

    reg('hud_bar', {
        type = 'toggle', default = DEFAULTS.hud_bar,
        label = L('opt_bar'),
    }, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud_bar = v
            if changed then wf('OPTION hud_bar=%s', tostring(v)) end
        end
    end, true)

    reg('death_hold_seconds', {
        type = 'slider', min = 0, max = 15, step = 1, default = DEFAULTS.death_hold_seconds,
        label = L('opt_death_hold'),
    }, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0 and v <= 15 then
            C.death_hold_seconds = v
            if changed then wf('OPTION death_hold_seconds=%d', v) end
        end
    end, false)

    wf('MOD_OPTIONS registered with ModOptionsMenu')
end

-- ---------------------------------------------------------- Hive Lord detection
local function is_hive_lord(e)
    if type(e) ~= 'table' then return false end
    if e.semantic_id == HIVE_LORD_SEMANTIC then return true end
    if type(e.type) == 'string' and e.type:upper() == HIVE_LORD_TYPE_HEX then return true end
    local ent = e.entity
    if type(ent) == 'table' and type(ent.is) == 'function' then
        if ok_call(ent.is, ent, HIVE_LORD_SEMANTIC) == true then return true end
    end
    return false
end

local function entity_max_hp(e, fallback)
    if type(e) == 'table' then
        local direct = tonumber(e.max_health)
        if direct and direct > 0 then return math.floor(direct) end
        local ent = e.entity
        if type(ent) == 'table' and type(ent.max_health) == 'function' then
            local mh = tonumber(ok_call(ent.max_health, ent))
            if mh and mh > 0 then return math.floor(mh) end
        end
    end
    return fallback or DEFAULT_MAX_HP
end

local function entity_is_valid(ent)
    if type(ent) ~= 'table' or type(ent.is_valid) ~= 'function' then return true end
    local v = ok_call(ent.is_valid, ent)
    if type(v) == 'boolean' then return v end
    return true
end

local function reset_records(reason, new_epoch)
    local had = next(M.records) ~= nil or M.best ~= nil
    M.records = {}
    M.best = nil
    M.live_count = 0
    if new_epoch ~= nil then M.epoch = new_epoch end
    if had then
        wf('MISSION_RESET reason=%s epoch=%s', tostring(reason), tostring(M.epoch))
        update_status_snapshot()
    end
end

local function sync_event_epoch(e)
    if type(e) == 'table' and e.epoch ~= nil then
        if M.epoch ~= nil and e.epoch ~= M.epoch then
            reset_records('event_epoch_change', e.epoch)
        else
            M.epoch = e.epoch
        end
    end
    M.in_mission = true
end

local function find_carry_record(id, net_id)
    if id ~= nil and M.records[id] and not M.records[id].dead then
        return id, M.records[id]
    end
    if net_id ~= nil then
        for k, r in pairs(M.records) do
            if not r.dead and r.network_id == net_id then return k, r end
        end
    end
    local candidate_k, candidate_r, other_live = nil, nil, 0
    for k, r in pairs(M.records) do
        if not r.dead then
            if r.burrowed and r.hp < r.max and r.invalid_since
                and (M.clock - r.invalid_since) <= C.burrow_hold_seconds then
                candidate_k, candidate_r = k, r
            else
                other_live = other_live + 1
            end
        end
    end
    if other_live == 0 and candidate_r then
        return candidate_k, candidate_r
    end
    return nil, nil
end

local function on_entity_spawned(e)
    if not is_hive_lord(e) then return end
    sync_event_epoch(e)
    local id = tonumber(e.entity_id) or tostring(e.entity_id or '0')
    local max_hp = entity_max_hp(e, DEFAULT_MAX_HP)
    local old_k, carry = find_carry_record(id, e.network_id)
    if carry then
        if old_k ~= id then M.records[old_k] = nil end
        carry.id = id
        carry.max = max_hp > 0 and max_hp or carry.max
        if carry.hp > carry.max then carry.hp = carry.max end
        carry.entity = e.entity or carry.entity
        carry.unit_id = e.unit_id or carry.unit_id
        carry.network_id = e.network_id or carry.network_id
        carry.burrowed = false
        carry.invalid_since = nil
        carry.updated_at = M.clock
        M.records[id] = carry
        wf('HIVE_LORD_RESURFACE id=%s hp=%d/%d net=%s',
            tostring(id), carry.hp, carry.max, tostring(carry.network_id))
    else
        M.ever_seen = M.ever_seen + 1
        M.records[id] = {
            id = id,
            hp = max_hp,
            max = max_hp,
            trail_hp = max_hp,
            entity = e.entity,
            unit_id = e.unit_id,
            network_id = e.network_id,
            spawned_at = M.clock,
            updated_at = M.clock,
            last_hit_at = nil,
            last_damage = 0,
            last_logged_hp = max_hp,
            last_logged_at = M.clock,
            dead = false,
            died_at = nil,
            burrowed = false,
            invalid_since = nil,
        }
        wf('HIVE_LORD_SPAWN id=%s hp=%d/%d net=%s unit=%s',
            tostring(id), max_hp, max_hp, tostring(e.network_id), tostring(e.unit_id))
    end
    if not M.best or M.best.dead or M.best.id == id then
        M.best = M.records[id]
    end
    update_status_snapshot()
end

local function on_entity_damaged(e)
    if not is_hive_lord(e) then return end
    sync_event_epoch(e)
    local id = tonumber(e.entity_id) or tostring(e.entity_id or '0')
    local rec = M.records[id]
    if not rec and e.network_id ~= nil then
        for k, r in pairs(M.records) do
            if r.network_id == e.network_id then
                M.records[k] = nil
                rec = r
                rec.id = id
                M.records[id] = rec
                break
            end
        end
    end
    local raw_hp = tonumber(e.health)
    if not raw_hp then return end
    local hp = math.max(0, math.floor(raw_hp + 0.5))
    local max_hp = entity_max_hp(e, rec and rec.max or DEFAULT_MAX_HP)
    if hp > max_hp then max_hp = hp end
    local dmg = math.max(0, math.floor((tonumber(e.damage) or 0) + 0.5))

    local is_new = (rec == nil)
    if is_new then
        M.ever_seen = M.ever_seen + 1
        rec = {
            id = id,
            hp = hp,
            max = max_hp,
            trail_hp = math.min(max_hp, hp + dmg),
            spawned_at = M.clock,
            last_logged_hp = nil,
            last_logged_at = -100,
        }
        M.records[id] = rec
    end

    rec.hp = hp
    rec.max = max_hp
    if not rec.trail_hp or rec.trail_hp < hp then rec.trail_hp = hp end
    rec.entity = e.entity or rec.entity
    rec.unit_id = e.unit_id or rec.unit_id
    rec.network_id = e.network_id or rec.network_id
    rec.last_damage = dmg
    rec.last_hit_at = M.clock
    rec.updated_at = M.clock
    rec.dead = false
    rec.died_at = nil
    rec.burrowed = false
    rec.invalid_since = nil
    rec.downed = e.downed == true
    rec.local_attacker = e.local_attacker == true

    local step = math.max(1, math.floor(max_hp * 0.05))
    local should_log = C.debug or is_new or hp == 0
        or not rec.last_logged_hp
        or math.abs(rec.last_logged_hp - hp) >= step
        or (M.clock - (rec.last_logged_at or -100)) >= 1.0
    if should_log then
        rec.last_logged_hp = hp
        rec.last_logged_at = M.clock
        M.best = rec
        wf('HIVE_LORD_HP id=%s hp=%d/%d dmg=%d%s',
            tostring(id), hp, max_hp, dmg, is_new and ' (mid-fight attach)' or '')
        update_status_snapshot()
    end
end

local function on_entity_died(e)
    if not is_hive_lord(e) then return end
    sync_event_epoch(e)
    local id = tonumber(e.entity_id) or tostring(e.entity_id or '0')
    local rec = M.records[id]
    local max_hp = entity_max_hp(e, rec and rec.max or DEFAULT_MAX_HP)
    if not rec then
        M.ever_seen = M.ever_seen + 1
        rec = { id = id, max = max_hp, trail_hp = 0, spawned_at = M.clock }
        M.records[id] = rec
    end
    rec.hp = 0
    rec.max = max_hp
    rec.entity = e.entity or rec.entity
    rec.network_id = e.network_id or rec.network_id
    rec.dead = true
    rec.died_at = M.clock
    rec.updated_at = M.clock
    rec.burrowed = false
    rec.invalid_since = nil
    rec.local_killer = e.local_killer == true
    rec.observed = e.observed
    wf('HIVE_LORD_DIED id=%s max=%d observed=%s local_killer=%s',
        tostring(id), max_hp, tostring(e.observed), tostring(rec.local_killer))
    if not M.best or M.best.id == id or M.best.dead then
        M.best = rec
    end
    update_status_snapshot()
end

local function on_mission_started(e)
    M.in_mission = true
    reset_records('mission_started', type(e) == 'table' and e.epoch or nil)
    M.gui_epoch = nil
end

local function on_mission_ended(e)
    M.in_mission = false
    reset_records('mission_ended', type(e) == 'table' and e.epoch or nil)
    M.gui_epoch = nil
end

local EVENT_HANDLERS = {
    { 'mission_started', on_mission_started },
    { 'mission_ended',   on_mission_ended   },
    { 'entity_spawned',  on_entity_spawned  },
    { 'entity_damaged',  on_entity_damaged  },
    { 'entity_died',     on_entity_died     },
}

local function sub_is_active(sub)
    if type(sub) ~= 'table' then return false end
    if type(sub.active) == 'function' then
        local ok, a = pcall(sub.active, sub)
        return ok and a == true
    end
    return sub.state == 'active'
end

local function unsubscribe_all()
    for name, sub in pairs(M.subs) do
        M.subs[name] = nil
        if type(sub) == 'table' and type(sub.unsubscribe) == 'function' then
            pcall(sub.unsubscribe, sub)
        end
    end
    M.hub_ref = nil
end

-- ---------------------------------------------------------------------- HD2Data
local function hub_tick()
    local D = rawget(_G, 'HD2Data')
    if D == nil then
        if M.hub_ref ~= nil then unsubscribe_all() end
        M.hub_state, M.hub_reason = 'waiting_for_hub', nil
        local diag = 'HUB waiting for _G.HD2Data'
        if diag ~= M.last_logged_diag then
            M.last_logged_diag = diag
            wf('%s', diag)
            update_status_snapshot()
        end
        return
    end
    if type(D) ~= 'table' or tonumber(D.api) ~= 1 or type(D.on) ~= 'function' then
        if M.hub_ref ~= nil then unsubscribe_all() end
        M.hub_state = 'bad_api'
        M.hub_reason = 'expected HD2Data.api == 1, got ' .. tostring(type(D) == 'table' and D.api or type(D))
        local diag = 'HUB refused: ' .. M.hub_reason
        if diag ~= M.last_logged_diag then
            M.last_logged_diag = diag
            wf('%s', diag)
            update_status_snapshot()
        end
        return
    end

    if D ~= M.hub_ref then
        unsubscribe_all()
        M.hub_ref = D
        M.hub_version = tostring(D.version or '?')
        M.next_poll = 0
        wf('HUB_BOUND version=%s api=%s', M.hub_version, tostring(D.api))
    end

    if M.clock < M.next_poll then return end
    M.next_poll = M.clock + math.max(0.05, C.poll_seconds)

    -- Ensure all 5 event subscriptions stay active (recovers if Hub dropped/reset one).
    for _, pair in ipairs(EVENT_HANDLERS) do
        local name, fn = pair[1], pair[2]
        if not sub_is_active(M.subs[name]) then
            local sub = ok_call(D.on, name, fn, { owner = ADDON_ID, id = name, priority = 50 })
            if sub then M.subs[name] = sub end
        end
    end

    if type(D.status) == 'function' then
        local st = ok_call(D.status)
        if type(st) == 'table' then
            M.hub_state = tostring(st.state or (st.ready and 'ready' or 'unknown'))
            M.hub_reason = st.reason and tostring(st.reason) or nil
            M.hub_build = st.build_id and tostring(st.build_id) or M.hub_build
        end
    elseif type(D.state) == 'function' then
        local st, why = ok_call(D.state)
        if st then
            M.hub_state = tostring(st)
            M.hub_reason = why and tostring(why) or nil
        end
    else
        M.hub_state = 'ready'
    end

    if type(D.mission) == 'function' then
        local ms = ok_call(D.mission)
        if type(ms) == 'table' then
            local in_m = ms.in_mission == true
            if M.in_mission and not in_m then
                M.in_mission = false
                reset_records('mission_inactive', ms.epoch)
            else
                M.in_mission = in_m
            end
            if ms.epoch ~= nil and M.epoch ~= nil and ms.epoch ~= M.epoch then
                reset_records('mission_epoch_poll', ms.epoch)
            elseif ms.epoch ~= nil then
                M.epoch = ms.epoch
            end
        end
    end

    local diag = string.format('HUB state=%s build=%s in_mission=%s reason=%s',
        tostring(M.hub_state), tostring(M.hub_build), tostring(M.in_mission), tostring(M.hub_reason))
    if diag ~= M.last_logged_diag then
        M.last_logged_diag = diag
        wf('%s', diag)
        update_status_snapshot()
    end
end

-- ------------------------------------------------------- target prune & select
local function rank_record(r)
    if r.dead then return 1 end
    if r.burrowed then return 2 end
    return 3
end

local function prune_and_select(dt)
    local best = nil
    local live_count = 0
    local blend = 1 - math.exp(-5.0 * math.min(0.5, math.max(0, dt)))
    for id, r in pairs(M.records) do
        local drop = false
        if r.dead then
            if (M.clock - (r.died_at or M.clock)) > C.death_hold_seconds then
                drop = true
            end
        else
            if not entity_is_valid(r.entity) then
                if not r.burrowed then
                    r.burrowed = true
                    r.invalid_since = M.clock
                    wf('HIVE_LORD_SUBMERGED id=%s hp=%d/%d', tostring(id), r.hp, r.max)
                end
                if (M.clock - (r.invalid_since or M.clock)) > C.burrow_hold_seconds then
                    drop = true
                    wf('HIVE_LORD_EXPIRED id=%s after %.1fs submerged', tostring(id), C.burrow_hold_seconds)
                end
            else
                r.burrowed = false
                r.invalid_since = nil
            end
        end

        if drop then
            M.records[id] = nil
        else
            if not r.dead then live_count = live_count + 1 end
            -- Frame-rate-independent smooth trail approach after a brief 0.18s hit hold.
            local target_hp = r.hp
            if not r.trail_hp or r.trail_hp < target_hp then
                r.trail_hp = target_hp
            elseif r.trail_hp > target_hp and (M.clock - (r.last_hit_at or 0)) > 0.18 then
                r.trail_hp = r.trail_hp + (target_hp - r.trail_hp) * blend
                if r.trail_hp - target_hp < 25 then r.trail_hp = target_hp end
            end

            if not best then
                best = r
            else
                local ra, rb = rank_record(r), rank_record(best)
                if ra ~= rb then
                    if ra > rb then best = r end
                else
                    local ha = r.last_hit_at or -1
                    local hb = best.last_hit_at or -1
                    if math.abs(ha - hb) > 0.001 then
                        if ha > hb then best = r end
                    elseif r.updated_at ~= best.updated_at then
                        if (r.updated_at or 0) > (best.updated_at or 0) then best = r end
                    elseif tostring(r.id) < tostring(best.id) then
                        best = r
                    end
                end
            end
        end
    end
    local prev_best = M.best
    M.best = best
    M.live_count = live_count
    if prev_best and not best then
        update_status_snapshot()
    end
end

-- -------------------------------------------------------------------------- HUD
-- Stingray GUI safety rules (verified against MDL3 3.0.0-dev.21 + BFV v2.0 reference):
--   1. Stingray IdString64.from_hex() values are frame-temporary and MUST NEVER be cached
--      across frames; recreate them inside the draw pass on each fresh text GUI.
--   2. Native game-UI font text (MDL3.ui.fonts) is rendered on its own tiny dedicated
--      `M.text_gui` created AFTER `M.gui` (so text sits above bar rects) and replaced as a
--      whole GUI on text change (never passing native-font handles to Gui.update_text or
--      Gui.destroy_text). Only call World.destroy_gui when `world_is_live` by identity holds.
--   3. When MDL3.ui.fonts is unavailable, fall back seamlessly to retained `Gui.text` +
--      `Gui.update_text` on `M.gui` with `'core/performance_hud/debug'` (ASCII only, zero
--      World.destroy_gui calls, surface creation bounded by C.surface_cap).

local function world_key(v) return tostring(v) end

local function world_by_identity(worlds, wanted)
    if wanted == nil then return false end
    for _, v in pairs(worlds or {}) do
        if v == wanted then return true end
    end
    return false
end

local function live_world(worlds, wanted_obj, wanted_key)
    if not wanted_key then return nil end
    for _, v in pairs(worlds or {}) do
        if (wanted_obj ~= nil and v == wanted_obj) or world_key(v) == wanted_key then
            return v
        end
    end
    return nil
end

local function hud_state(text)
    if text ~= M.last_hud then
        M.last_hud = text
        wf('HUD_STATE %s', text)
    end
end

local function read_mdl3_font_hex()
    if not C.hud_native_font or M.clock < (M.font_retry_at or 0) then return nil end
    local mdl3 = rawget(_G, 'MDL3')
    local mdl = rawget(_G, 'MDL')
    local ui3 = type(mdl3) == 'table' and mdl3.ui or nil
    local ui = type(mdl) == 'table' and mdl.ui or nil
    local cands = {
        type(ui3) == 'table' and ui3.fonts or nil,
        type(mdl3) == 'table' and mdl3.fonts or nil,
        type(ui) == 'table' and ui.fonts or nil,
    }
    local function clean_hex(val)
        if type(val) ~= 'string' then return nil end
        local h = val:lower():gsub('^0x', '')
        if #h == 16 and h:match('^[0-9a-f]+$') then return h end
        return nil
    end
    for _, f in pairs(cands) do
        if type(f) == 'table' then
            local fh = clean_hex(f.font or f.font_hex)
            local mh = clean_hex(f.material or f.material_hex)
            local ah = clean_hex(f.atlas or f.atlas_hex or f.texture)
            if fh and mh and ah then
                return { font = fh, material = mh, atlas = ah }
            end
        end
    end
    return nil
end

local function dispose_text_gui(worlds)
    if M.text_gui ~= nil then
        local sr = _G.stingray
        local World = sr and sr.World
        if M.text_world ~= nil and world_by_identity(worlds, M.text_world)
            and World and type(World.destroy_gui) == 'function' then
            pcall(World.destroy_gui, M.text_world, M.text_gui)
        end
        M.text_gui, M.text_world = nil, nil
    end
end

local function clear_hud(worlds)
    local sr = _G.stingray
    dispose_text_gui(worlds)
    if not sr or not M.gui then
        M.draw_key, M.bar_key = nil, nil
        return
    end
    local Gui = sr.Gui
    if M.rects and type(Gui.update_rect) == 'function' and is_ctor(sr.Vector3)
        and is_ctor(sr.Vector2) and is_ctor(sr.Color) then
        local zpos = sr.Vector3(-20000, -20000, 0)
        local zsize = sr.Vector2(0, 0)
        local zcol = sr.Color(0, 0, 0, 0)
        for i = 1, 4 do
            if M.rects[i] then pcall(Gui.update_rect, M.gui, M.rects[i], zpos, zsize, zcol) end
        end
    elseif M.rects and type(Gui.destroy_rect) == 'function' then
        for i = 1, 4 do
            if M.rects[i] then pcall(Gui.destroy_rect, M.gui, M.rects[i]) end
        end
        M.rects, M.rect_creates = nil, 0
    end

    if M.texts then
        if type(Gui.update_text) == 'function' and is_ctor(sr.Vector2)
            and is_ctor(sr.Color) then
            local p0 = sr.Vector2(0, 0)
            local c0 = sr.Color(0, 255, 255, 255)
            for _, t in ipairs(M.texts) do
                pcall(Gui.update_text, M.gui, t, ' ', DEBUG_FONT_ID, 12, DEBUG_FONT_ID, p0, c0)
            end
        elseif type(Gui.destroy_text) == 'function' then
            for _, t in ipairs(M.texts) do
                pcall(Gui.destroy_text, M.gui, t)
            end
            M.texts, M.text_creates = nil, 0
        end
    end
    M.draw_key, M.bar_key = nil, nil
end

-- Keep preview/combat bar above MDL3's recreated panel GUI while editing settings in ESC.
local function refresh_foreground_over_mdl_panel(worlds)
    if not mdl_settings_open() then
        M.fg_sig, M.fg_dirty = nil, false
        M.fg_next_at = 0
        if M.live_menu_preview then
            M.live_menu_preview = false
            clear_hud(worlds)
        end
        return
    end
    local mdl = rawget(_G, 'MDL3')
    local panel = mdl and mdl.panel
    local rev = type(mdl.options) == 'table' and mdl.options.revision or nil
    local sig = tostring(panel and panel.builds) .. ':' .. tostring(rev)
    if sig ~= M.fg_sig then
        M.fg_sig = sig
        M.fg_dirty = true
        M.fg_due_at = M.clock + 0.14
    end
    if not M.fg_dirty or M.clock < M.fg_due_at or M.clock < M.fg_next_at then return end
    M.fg_dirty = false
    M.fg_next_at = M.clock + 0.30
    if M.gui ~= nil or M.text_gui ~= nil then
        local sr = _G.stingray
        local World, Gui = sr.World, sr.Gui
        dispose_text_gui(worlds)
        if M.gui ~= nil and M.gui_world ~= nil and world_by_identity(worlds, M.gui_world) then
            if M.rects and Gui and type(Gui.destroy_rect) == 'function' then
                for i = 1, 4 do if M.rects[i] then pcall(Gui.destroy_rect, M.gui, M.rects[i]) end end
            end
            if World and type(World.destroy_gui) == 'function' then
                pcall(World.destroy_gui, M.gui_world, M.gui)
                M.surfaces = math.max(0, (M.surfaces or 1) - 1)
            end
        end
        M.gui, M.gui_world, M.gui_world_key = nil, nil, nil
        M.rects, M.rect_creates = nil, 0
        M.texts, M.text_creates = nil, 0
        M.draw_key, M.bar_key = nil, nil
    end
end

local function vector_x(v)
    if v == nil then return nil end
    local sr = _G.stingray
    if type(sr.Vector3) == 'table' and type(sr.Vector3.x) == 'function' then
        local ok, x = pcall(sr.Vector3.x, v)
        if ok and type(x) == 'number' then return x end
    end
    if type(sr.Vector2) == 'table' and type(sr.Vector2.x) == 'function' then
        local ok, x = pcall(sr.Vector2.x, v)
        if ok and type(x) == 'number' then return x end
    end
    local ok, x = pcall(function() return v[1] end)
    return ok and tonumber(x) or nil
end

local function measure_text_uncached(target_gui, text, font_id, size)
    local sr = _G.stingray
    local Gui = sr.Gui
    if target_gui and type(Gui.text_extents) == 'function' then
        local ok, lo, hi = pcall(Gui.text_extents, target_gui, text, font_id, size)
        if ok and lo ~= nil and hi ~= nil then
            local x0, x1 = vector_x(lo), vector_x(hi)
            if x0 ~= nil and x1 ~= nil and x1 > x0 then return x1 - x0, x0 end
        end
    end
    local units = 0
    for ch in tostring(text or ''):gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        if #ch > 1 then units = units + 1.0
        elseif ch == ' ' then units = units + 0.32
        elseif ch == 'I' or ch == 'i' or ch == 'l' or ch == '1' or ch == '.' or ch == ',' then units = units + 0.30
        elseif ch == '[' or ch == ']' or ch == '(' or ch == ')' or ch == '|' then units = units + 0.36
        elseif ch == 'W' or ch == 'M' then units = units + 0.78
        elseif ch == '+' or ch == '-' or ch == '/' or ch == '%' then units = units + 0.52
        elseif ch >= '0' and ch <= '9' then units = units + 0.55
        elseif ch >= 'A' and ch <= 'Z' then units = units + 0.60
        else units = units + 0.50 end
    end
    return units * size, 0
end

local function measure_text(target_gui, font_key, text, font_id, size)
    if type(text) ~= 'string' or #text > 160 or not font_key then
        return measure_text_uncached(target_gui, text, font_id, size)
    end
    local ckey = font_key .. '|' .. tostring(size) .. '|' .. text
    local hit = M.measure_cache[ckey]
    if hit then return hit[1], hit[2] end
    local w_px, bearing = measure_text_uncached(target_gui, text, font_id, size)
    if M.measure_cache_count >= 128 then
        M.measure_cache, M.measure_cache_count = {}, 0
    end
    M.measure_cache[ckey] = { w_px, bearing }
    M.measure_cache_count = M.measure_cache_count + 1
    return w_px, bearing
end

-- Bind native game-UI font on a fresh GUI within the current frame (no cross-frame IdString64).
local function bind_native_font_this_frame(target_gui, fonts)
    local sr = _G.stingray
    local App, Gui, Id64, Mat = sr.Application, sr.Gui, sr.IdString64, sr.Material
    if type(Id64) ~= 'table' and type(Id64) ~= 'userdata' then return nil end
    if type(Mat) ~= 'table' and type(Mat) ~= 'userdata' then return nil end
    if type(Id64.from_hex) ~= 'function' or type(Gui.material) ~= 'function'
        or type(Mat.set_texture) ~= 'function' or not is_ctor(sr.Vector3) then
        return nil
    end

    local ok, res = pcall(function()
        if App and type(App.can_get) == 'function' then
            if ok_call(App.can_get, 'font', Id64.from_hex(fonts.font)) ~= true
                or ok_call(App.can_get, 'material', Id64.from_hex(fonts.material)) ~= true
                or ok_call(App.can_get, 'texture', Id64.from_hex(fonts.atlas)) ~= true then
                return nil
            end
        end
        local fid = Id64.from_hex(fonts.font)
        local mid = Id64.from_hex(fonts.material)
        local aid = Id64.from_hex(fonts.atlas)
        if not (fid and mid and aid) then return nil end
        local ink = Gui.material(target_gui, mid)
        if not ink then return nil end
        local function slot(h) return Id64.from_hex(h .. '00000000') end
        if type(Mat.set_scalar) == 'function' then
            for _, h in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
                pcall(Mat.set_scalar, ink, slot(h), 0)
            end
        end
        if type(Mat.set_vector2) == 'function' and is_ctor(sr.Vector2) then
            pcall(Mat.set_vector2, ink, slot('e13777ce'), sr.Vector2(1, -1))
        end
        if type(Mat.set_vector4) == 'function' and is_ctor(sr.Color) then
            pcall(Mat.set_vector4, ink, slot('7701209e'), sr.Color(0, 0, 0, 0))
        end
        Mat.set_texture(ink, slot('88bac99b'), aid)

        local cjk = M.cjk_cache[fonts.font]
        if cjk == nil then
            local sw = measure_text_uncached(target_gui, ZH.cjk_probe, fid, 20)
            local qw = measure_text_uncached(target_gui, '???', fid, 20)
            cjk = not (sw ~= nil and qw ~= nil and math.abs(sw - qw) < 0.01)
            M.cjk_cache[fonts.font] = cjk
        end
        return { font_id = fid, mat_id = mid, font_hex = fonts.font, cjk = cjk }
    end)
    if ok and res then return res end
    return nil
end

local function draw_api()
    local sr = _G.stingray
    if not sr or not sr.Gui or type(sr.Gui.text) ~= 'function' then
        return nil, 'Gui.text missing'
    end
    if not is_ctor(sr.Color) then
        return nil, 'Color missing'
    end
    if not is_ctor(sr.Vector2) and not is_ctor(sr.Vector3) then
        return nil, 'Vector2/Vector3 missing'
    end
    return true
end

local function bar_fill_color(ratio, dead)
    if dead or ratio <= 0 then return 120, 45, 45 end
    if ratio > 0.60 then return 255, 208, 44 end   -- Helldivers tactical gold
    if ratio > 0.30 then return 255, 138, 32 end   -- warning amber-orange
    return 235, 56, 48                              -- critical crimson
end

local function paint_bar(bx, by, bw, bh, ratio, trail_ratio, dead, a)
    local sr = _G.stingray
    local Gui = sr.Gui
    if not C.hud_bar then
        if M.rects and M.bar_key ~= 'hidden' and type(Gui.update_rect) == 'function'
            and is_ctor(sr.Vector3) and is_ctor(sr.Vector2) then
            local zpos, zsz, zcol = sr.Vector3(-20000, -20000, 0), sr.Vector2(0, 0), sr.Color(0, 0, 0, 0)
            for i = 1, 4 do if M.rects[i] then pcall(Gui.update_rect, M.gui, M.rects[i], zpos, zsz, zcol) end end
            M.bar_key = 'hidden'
        end
        return
    end
    if type(Gui.rect) ~= 'function' or type(Gui.update_rect) ~= 'function'
        or not is_ctor(sr.Vector3) or not is_ctor(sr.Vector2) then
        return
    end
    local q_ratio = math.floor(math.max(0, math.min(1, ratio)) * 1000 + 0.5)
    local q_trail = math.floor(math.max(q_ratio, math.min(1000, trail_ratio * 1000 + 0.5)))
    local bkey = string.format('%d|%d|%d|%d|%d|%d|%d|%s',
        math.floor(bx), math.floor(by), math.floor(bw), math.floor(bh),
        q_ratio, q_trail, a, tostring(dead))
    if bkey == M.bar_key then return end

    M.rects = M.rects or {}
    local function put_rect(slot, rx, ry, rw, rh, z, ca, cr, cg, cb)
        local pos = sr.Vector3(rx, ry, z)
        local sz = sr.Vector2(math.max(0, rw), math.max(0, rh))
        local col = sr.Color(ca, cr, cg, cb)
        if M.rects[slot] then
            pcall(Gui.update_rect, M.gui, M.rects[slot], pos, sz, col)
            return
        end
        if (M.rect_creates or 0) >= 4 then return end
        local ok, id = pcall(Gui.rect, M.gui, pos, sz, col)
        if ok and id then
            M.rects[slot] = id
            M.rect_creates = (M.rect_creates or 0) + 1
        end
    end

    local pad = math.max(2, math.floor(bh * 0.22 + 0.5))
    local bg_a = math.floor(a * 0.78)
    local tr_a = math.floor(a * 0.85)
    local r, g, b = bar_fill_color(q_ratio / 1000, dead)

    put_rect(1, bx - pad, by - pad, bw + pad * 2, bh + pad * 2, 900, bg_a, 10, 12, 16)
    put_rect(2, bx, by, bw, bh, 901, tr_a, 38, 42, 50)
    put_rect(3, bx, by, bw * (q_trail / 1000), bh, 902, math.floor(a * 0.90), 255, 238, 150)
    put_rect(4, bx, by, bw * (q_ratio / 1000), bh, 903, a, r, g, b)
    M.bar_key = bkey
end

local function format_hud_lines(r, use_zh)
    local hp = math.max(0, r.hp or 0)
    local max_hp = math.max(1, r.max or DEFAULT_MAX_HP)
    local pct = math.max(0, math.min(100, (hp / max_hp) * 100.0))
    local name = use_zh and ZH.boss_name or 'HIVE LORD'
    local txt = string.format('%s   %s / %s  (%.1f%%)', name, format_int(hp), format_int(max_hp), pct)

    local parts = {}
    if r.preview then
        parts[#parts + 1] = use_zh and ZH.preview_tag or 'PREVIEW'
    elseif r.dead then
        parts[#parts + 1] = use_zh and ZH.slain or 'SLAIN'
    elseif r.burrowed then
        parts[#parts + 1] = use_zh and ZH.submerged or 'SUBMERGED'
    else
        parts[#parts + 1] = use_zh and ZH.active_tag or 'LIVE'
    end
    if M.live_count > 1 and not r.preview then
        parts[#parts + 1] = string.format('[%d ACTIVE]', M.live_count)
    end
    if (r.last_damage or 0) > 0 and r.last_hit_at and (M.clock - r.last_hit_at) <= 3.5 then
        parts[#parts + 1] = string.format('-%s DMG', format_int(r.last_damage))
    end
    local sub = table.concat(parts, '   |   ')
    return txt, sub
end

local function paint_native_texts(worlds, center_x, title_y, sub_y, sc, r, fonts, a)
    local sr = _G.stingray
    local World, Gui = sr.World, sr.Gui
    if not World or type(World.create_screen_gui) ~= 'function' or not M.gui_world
        or not world_by_identity(worlds, M.gui_world) then
        return false, nil
    end
    dispose_text_gui(worlds)
    local ok, tgui = pcall(World.create_screen_gui, M.gui_world, 'scale', 1, 1)
    if not (ok and tgui) then return false, nil end
    M.text_gui, M.text_world = tgui, M.gui_world

    local nf = bind_native_font_this_frame(tgui, fonts)
    if not nf then
        dispose_text_gui(worlds)
        M.font_retry_at = M.clock + 1.5
        return false, nil
    end

    local use_zh = nf.cjk and is_chinese_ui()
    local txt, sub = format_hud_lines(r, use_zh)
    local sz1 = math.max(12, math.floor(20 * sc + 0.5))
    local sz2 = math.max(10, math.floor(14 * sc + 0.5))
    local w1, b1 = measure_text(tgui, nf.font_hex, txt, nf.font_id, sz1)
    local w2, b2 = measure_text(tgui, nf.font_hex, sub, nf.font_id, sz2)
    local x1 = math.floor(center_x - (b1 or 0) - w1 * 0.5 + 0.5)
    local x2 = math.floor(center_x - (b2 or 0) - w2 * 0.5 + 0.5)

    local tr, tg, tb = 255, 245, 215
    if r.dead then tr, tg, tb = 255, 110, 100 end
    local ok1, id1 = pcall(Gui.text, tgui, txt, nf.font_id, sz1, nf.mat_id,
        sr.Vector3(x1, math.floor(title_y + 0.5), 910), sr.Color(a, tr, tg, tb))
    local ok2, id2 = pcall(Gui.text, tgui, sub, nf.font_id, sz2, nf.mat_id,
        sr.Vector3(x2, math.floor(sub_y + 0.5), 910), sr.Color(math.floor(a * 0.88), 205, 212, 220))
    if not (ok1 and id1 and ok2 and id2) then
        dispose_text_gui(worlds)
        M.font_retry_at = M.clock + 1.5
        return false, nil
    end
    M.text_last_rebuild = M.clock
    M.font_mode = 'native'
    return true, txt
end

local function paint_debug_texts(center_x, bx, title_y, sub_y, sc, r, a)
    local sr = _G.stingray
    local Gui = sr.Gui
    local txt, sub = format_hud_lines(r, false)
    local sz1 = math.max(12, math.floor(20 * sc + 0.5))
    local sz2 = math.max(10, math.floor(14 * sc + 0.5))
    local w1, b1 = measure_text(M.gui, 'debug', txt, DEBUG_FONT_ID, sz1)
    local w2, b2 = measure_text(M.gui, 'debug', sub, DEBUG_FONT_ID, sz2)
    local x1 = math.max(bx, math.floor(center_x - (b1 or 0) - w1 * 0.5 + 0.5))
    local x2 = math.max(bx, math.floor(center_x - (b2 or 0) - w2 * 0.5 + 0.5))

    M.texts = M.texts or {}
    local function put_line(i, str, lx, ly, size, cr, cg, cb, ca)
        local pos = is_ctor(sr.Vector2) and sr.Vector2(lx, ly) or sr.Vector3(lx, ly, 905)
        local col = sr.Color(ca, cr, cg, cb)
        if M.texts[i] and type(Gui.update_text) == 'function' then
            return (pcall(Gui.update_text, M.gui, M.texts[i], str, DEBUG_FONT_ID, size, DEBUG_FONT_ID, pos, col))
        end
        if M.texts[i] then
            if type(Gui.destroy_text) ~= 'function' then
                return false
            end
            if pcall(Gui.destroy_text, M.gui, M.texts[i]) then
                M.text_creates = math.max(0, (M.text_creates or 1) - 1)
            end
            M.texts[i] = nil
        end
        if (M.text_creates or 0) >= 2 then return false end
        local ok, id = pcall(Gui.text, M.gui, str, DEBUG_FONT_ID, size, DEBUG_FONT_ID, pos, col)
        if ok and id then
            M.texts[i] = id
            M.text_creates = (M.text_creates or 0) + 1
            return true
        end
        return false
    end

    local tr, tg, tb = 255, 245, 215
    if r.dead then tr, tg, tb = 255, 110, 100 end
    local ok1 = put_line(1, txt, x1, title_y, sz1, tr, tg, tb, a)
    local ok2 = put_line(2, sub, x2, sub_y, sz2, 200, 206, 214, math.floor(a * 0.88))
    M.font_mode = 'debug'
    return (ok1 and ok2) and true or false, txt
end

local function hud_tick()
    local sr = _G.stingray
    local App, World, Gui = sr.Application, sr.World, sr.Gui
    local worlds = (App and type(App.worlds) == 'function') and (App.worlds() or {}) or nil

    if not C.hud then
        if M.gui or M.text_gui then clear_hud(worlds) end
        return hud_state('hud=off (disabled in settings)')
    end
    if not worlds then
        return hud_state('no Application.worlds')
    end

    refresh_foreground_over_mdl_panel(worlds)

    local r = M.best
    if not r and (C.hud_preview or M.live_menu_preview) then
        r = {
            hp = 112500,
            max = DEFAULT_MAX_HP,
            trail_hp = 127500,
            last_damage = 15000,
            last_hit_at = M.clock,
            preview = true,
            dead = false,
            burrowed = false,
        }
    end

    -- Abandon stale surfaces if their world disappeared or mission epoch changed.
    if M.gui and (not live_world(worlds, M.gui_world, M.gui_world_key)
        or (M.gui_epoch ~= nil and M.epoch ~= nil and M.gui_epoch ~= M.epoch)) then
        clear_hud(worlds)
        M.gui, M.gui_world, M.gui_world_key = nil, nil, nil
        M.texts, M.text_creates = nil, 0
        M.rects, M.rect_creates = nil, 0
    end

    if not r then
        if M.gui or M.text_gui then clear_hud(worlds) end
        return hud_state('idle (waiting for Hive Lord)')
    end

    local okapi, why = draw_api()
    if not okapi then
        M.draw_key, M.bar_key = nil, nil
        return hud_state('refused (' .. tostring(why) .. ')')
    end

    if not M.gui then
        local main = type(App.main_world) == 'function' and ok_call(App.main_world) or nil
        local pick = nil
        for _, v in ipairs(worlds) do
            if main ~= nil and v ~= main then pick = v; break end
        end
        if not pick then pick = worlds[1] end
        if pick and World and type(World.create_screen_gui) == 'function' then
            M.surfaces = (M.surfaces or 0) + 1
            if M.surfaces > C.surface_cap then
                if not M.surface_capped then
                    M.surface_capped = true
                    wf('HUD_SURFACE giving up after %d surfaces; drawing disabled', M.surfaces - 1)
                end
                return hud_state('drawing disabled: too many surfaces created')
            end
            local ok, g = pcall(World.create_screen_gui, pick, 'scale', 1, 1)
            if ok and g then
                M.gui = g
                M.gui_world = pick
                M.gui_world_key = world_key(pick)
                M.gui_epoch = M.epoch
                M.texts, M.text_creates = nil, 0
                M.rects, M.rect_creates = nil, 0
                M.draw_key, M.bar_key = nil, nil
                wf('HUD_SURFACE created on %s (worlds=%d surface=#%d)',
                    M.gui_world_key, #worlds, M.surfaces)
            end
        end
    end

    if not M.gui then
        return hud_state(string.format('no surface: worlds=%d create_screen_gui=%s',
            #worlds, tostring(World and type(World.create_screen_gui))))
    end
    if type(Gui.resolution) ~= 'function' then
        return hud_state('no Gui.resolution')
    end
    local w_px, h_px = Gui.resolution()
    if type(w_px) ~= 'number' or type(h_px) ~= 'number' or w_px <= 0 or h_px <= 0 then
        return hud_state('bad resolution ' .. tostring(w_px) .. 'x' .. tostring(h_px))
    end

    local sc = math.min(w_px / 1920, h_px / 1080) * C.hud_scale
    local bw = 560 * sc
    local bh = 14 * sc
    local center_x = w_px * 0.5 + (C.hud_offset_x or 0) * sc
    local bx = center_x - bw * 0.5
    local by = (C.hud_position == 'bottom') and (C.hud_offset_y * sc) or (h_px - C.hud_offset_y * sc)
    local a = math.max(0, math.min(255, math.floor(C.hud_alpha * 255 + 0.5)))

    local max_hp = math.max(1, r.max or DEFAULT_MAX_HP)
    local ratio = math.max(0, math.min(1, (r.hp or 0) / max_hp))
    local trail_ratio = math.max(ratio, math.min(1, (r.trail_hp or r.hp or 0) / max_hp))

    paint_bar(bx, by, bw, bh, ratio, trail_ratio, r.dead, a)

    local fonts = read_mdl3_font_hex()
    local want_mode = fonts and 'native' or 'debug'
    local sig_txt, sig_sub = format_hud_lines(r, want_mode == 'native' and is_chinese_ui())
    local dkey = string.format('%s\n%s\n%d|%d|%d|%d|%s|%s|%s',
        sig_txt, sig_sub, math.floor(w_px), math.floor(h_px),
        math.floor(by), a, want_mode, tostring(C.hud_bar), tostring(r.dead))

    if dkey ~= M.draw_key then
        -- Throttle native text GUI rebuilds during ultra-high-ROF damage ticks (<= 20 Hz),
        -- except on immediate state changes (spawn, death, preview).
        if want_mode == 'native' and M.text_gui ~= nil and not r.dead and not r.preview
            and (M.clock - M.text_last_rebuild) < 0.05 then
            return
        end
        local title_y = by + bh + 6 * sc
        local sub_y = by - 18 * sc
        if not C.hud_bar then
            title_y = by + 10 * sc
            sub_y = by - 12 * sc
        end

        local ok, shown_txt = false, sig_txt
        if fonts then
            -- Blank any prior debug-font text on M.gui when transitioning to native text_gui.
            if M.texts and type(Gui.update_text) == 'function' and is_ctor(sr.Vector2) then
                local p0, c0 = sr.Vector2(0, 0), sr.Color(0, 255, 255, 255)
                for _, t in ipairs(M.texts) do
                    pcall(Gui.update_text, M.gui, t, ' ', DEBUG_FONT_ID, 12, DEBUG_FONT_ID, p0, c0)
                end
            end
            ok, shown_txt = paint_native_texts(worlds, center_x, title_y, sub_y, sc, r, fonts, a)
        end
        if not ok then
            dispose_text_gui(worlds)
            ok, shown_txt = paint_debug_texts(center_x, bx, title_y, sub_y, sc, r, a)
        end
        M.draw_key = dkey
        hud_state(string.format('painted=%s font=%s text="%s"',
            tostring(ok), tostring(M.font_mode), tostring(shown_txt)))
    end
end

-- ------------------------------------------------------------------- lifecycle
local function step(dt)
    if not M.active then return end
    local d = (type(dt) == 'number' and dt == dt) and math.max(0, math.min(1, dt)) or 0.016
    M.clock = M.clock + d
    if not M.options_bound then bind_mod_options() end
    hub_tick()
    prune_and_select(d)
    hud_tick()
end

local prev_update = rawget(_G, 'update')
local prev_shutdown = rawget(_G, 'shutdown')

rawset(_G, 'update', function(dt, ...)
    if type(prev_update) == 'function' then prev_update(dt, ...) end
    local ok, err = pcall(step, dt)
    if not ok then wf('STEP_ERR %s', tostring(err)) end
end)

rawset(_G, 'shutdown', function(...)
    pcall(function()
        M.active = false
        unsubscribe_all()
        local App = sr and sr.Application
        local worlds = (App and type(App.worlds) == 'function') and ok_call(App.worlds) or nil
        clear_hud(worlds)
        wf('SHUTDOWN')
        if out then out:close(); out = nil end
        if rawget(_G, '__HIVELORD_HEALTH') == M then
            rawset(_G, '__HIVELORD_HEALTH', nil)
        end
    end)
    if type(prev_shutdown) == 'function' then return prev_shutdown(...) end
end)

rawset(_G, '__HIVELORD_HEALTH', M)
bind_mod_options()
pcall(hub_tick)
update_status_snapshot()
wf('INSTALLED version=%s', VERSION)

return {
    installed = true,
    name = ZH.mod_title,
    version = VERSION,
    author = 'hivelord',
    description = ZH.mod_desc,
}
