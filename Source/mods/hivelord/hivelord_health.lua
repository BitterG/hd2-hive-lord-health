-- HD2-Addon: mods/hivelord/hivelord_health
-- Hive Lord Health & Locator 2.3.0 -- Real-time exact Boss Health Bar & Tactical Locator for Helldivers 2.
-- Adapted for MDL3 (PUC Lua 5.1 game VM + MDL3.gui API 1) + HD2 Data Hub >= 0.3.0 (HD2Data API 1).
-- Strictly READ-ONLY: zero FFI, zero process memory writes, zero hardcoded build RVAs.

local ADDON_ID = 'mods/hivelord/hivelord_health'
local VERSION = '2.3.0'
local HIVE_LORD_SEMANTIC = 'enemy/v1/terminids/hive_lord'
local HIVE_LORD_TYPE_HEX = 'D465D9C7F77A07CB'
local DEFAULT_MAX_HP = 150000
local DEBUG_FONT_ID = 'core/performance_hud/debug'
local MAX_RECTS = 4             -- outer frame + trough + damage trail + health fill
local MAX_TEXTS = 2             -- boss HP title + status subtitle

-- Pure-ASCII UTF-8 string table for Chinese + English UI labels in MDL3 & native font HUD.
local ZH = {
    cjk_probe = '\233\156\184\231\142\139\232\153\171',
    mod_title = '\233\156\184\231\142\139\232\153\171\232\161\128\233\135\143\228\184\142\229\174\154\228\189\141 (Hive Lord HP & Locator)',
    mod_desc = '\229\159\186\228\186\142 MDL3 + HD2 Data Hub \231\154\132\233\156\184\231\142\139\232\153\171\229\174\158\230\151\182\231\178\190\231\161\174\232\161\128\233\135\143\230\157\161\228\184\142\230\150\185\228\189\141\229\174\154\228\189\141\233\155\183\232\190\190\230\168\161\231\187\132\239\188\136\231\186\175\229\143\170\232\175\187\239\188\137\227\128\130',
    boss_name = '\233\156\184\231\142\139\232\153\171 HIVE LORD',
    slain = '\229\183\178\229\135\187\230\157\128 SLAIN',
    submerged = '\230\189\156\229\156\176 SUBMERGED',
    preview_tag = '\233\162\132\232\167\136\230\168\161\229\188\143 PREVIEW',
    active_tag = '\229\174\158\230\151\182\232\191\189\232\184\170 LIVE',
    loc_radar_title = '\233\156\184\231\142\139\232\153\171\229\174\154\228\189\141',
    loc_waiting = '\231\173\137\229\190\133\229\174\154\228\189\141\228\191\161\229\143\183...',
    loc_live = '\229\174\158\230\151\182',
    loc_last_seen = '\230\156\128\229\144\142\228\189\141\231\189\174',
    loc_range_tag = '\232\140\131\229\155\180',
    loc_sec_ago = '\231\167\146\229\137\141',
    loc_burrow_short = '\230\189\156\229\156\176',
    dir_f = '\230\173\163\229\137\141',
    dir_fr = '\229\143\179\229\137\141',
    dir_r = '\229\143\179\228\190\167',
    dir_br = '\229\143\179\229\144\142',
    dir_b = '\230\173\163\229\144\142',
    dir_bl = '\229\183\166\229\144\142',
    dir_l = '\229\183\166\228\190\167',
    dir_fl = '\229\183\166\229\137\141',
    dir_near = '\230\158\129\232\191\145',
    opt_hud = '\230\152\190\231\164\186\233\156\184\231\142\139\232\153\171\232\161\128\230\157\161 (Show Boss Bar)',
    opt_hud_desc = '\229\156\168\228\187\187\229\138\161\228\184\173\233\156\184\231\142\139\232\153\171\229\135\186\231\142\176\230\136\150\229\143\151\228\188\164\230\151\182\230\152\190\231\164\186\229\174\158\230\151\182\232\161\128\233\135\143\230\157\161\228\184\142\231\178\190\231\161\174\230\149\176\229\128\188\227\128\130',
    opt_preview = '\232\136\176\230\161\165\233\162\132\232\167\136\232\161\128\230\157\161 (Preview HUD)',
    opt_preview_desc = '\231\171\139\229\141\179\230\152\190\231\164\186\231\164\186\228\190\139\232\161\128\230\157\161\228\184\142\229\174\154\228\189\141\233\155\183\232\190\190/\231\174\173\229\164\180\239\188\140\230\150\185\228\190\191\229\156\168\232\136\176\230\161\165\230\136\150\228\187\187\229\138\161\228\184\173\229\174\158\230\151\182\232\176\131\230\149\180\228\189\141\231\189\174\228\184\142\231\188\169\230\148\190\227\128\130',
    opt_pos = '\232\161\128\230\157\161\228\189\141\231\189\174 (Position)',
    opt_pos_top = '\233\161\182\233\131\168\229\177\133\228\184\173 (Top Boss Bar)',
    opt_pos_bottom = '\229\186\149\233\131\168\229\177\133\228\184\173 (Bottom Classic)',
    opt_scale = '\231\149\140\233\157\162\231\188\169\230\148\190 (HUD Scale)',
    opt_offset_y = '\229\158\130\231\155\180\232\190\185\232\183\157 (Vertical Margin)',
    opt_offset_y_desc = '\232\183\157\231\166\187\229\177\143\229\185\149\233\161\182\233\131\168\230\136\150\229\186\149\233\131\168\231\154\132\229\131\143\231\180\160\232\190\185\232\183\157\239\188\136\230\140\137 1080p \229\159\186\229\135\134\232\135\170\233\128\130\229\186\148\231\188\169\230\148\190\239\188\137\227\128\130',
    opt_offset_x = '\230\176\180\229\185\179\229\129\143\231\167\187 (Horizontal Offset)',
    opt_offset_x_desc = '\232\183\157\231\166\187\229\177\143\229\185\149\230\176\180\229\185\179\228\184\173\229\191\131\231\154\132\229\131\143\231\180\160\229\129\143\231\167\187\239\188\136\232\180\159\230\149\176\229\129\143\229\183\166\239\188\140\230\173\163\230\149\176\229\129\143\229\143\179\239\188\1400 \228\184\186\229\177\133\228\184\173\239\188\137\227\128\130',
    opt_alpha = '\228\184\141\233\128\143\230\152\142\229\186\166 (Opacity)',
    opt_bar = '\231\187\152\229\136\182\229\174\158\229\191\131\232\161\128\233\135\143\230\157\161 (Solid Progress Bar)',
    opt_death_hold = '\229\135\187\230\157\128\229\144\142\228\191\157\231\149\153\231\167\146\230\149\176 (Death Hold s)',
    opt_loc_radar = '\230\152\190\231\164\186\230\136\152\230\156\175\229\174\154\228\189\141\233\155\183\232\190\190 (Tactical Radar)',
    opt_loc_radar_desc = '\229\156\168\229\177\143\229\185\149\228\184\138\230\152\190\231\164\186\228\187\165\228\189\160\228\184\186\228\184\173\229\191\131\231\154\132\233\156\184\231\142\139\232\153\171\230\150\185\228\189\141\229\176\143\229\156\176\229\155\190\228\184\142\229\174\158\230\151\182\232\183\157\231\166\187\239\188\136\233\156\128 MDL3 dev.41+\239\188\137\227\128\130',
    opt_loc_pointer = '\230\152\190\231\164\186\228\184\173\229\191\131\230\150\185\228\189\141\231\174\173\229\164\180 (Direction Pointer)',
    opt_loc_pointer_desc = '\229\156\168\229\177\143\229\185\149\229\135\134\230\152\159\229\164\150\229\155\180\230\152\190\231\164\186\230\140\135\229\144\145\233\156\184\231\142\139\232\153\171\231\154\132\229\138\168\230\128\129\230\150\185\229\144\145\231\174\173\229\164\180\228\184\142\232\183\157\231\166\187\230\160\135\231\173\190\227\128\130',
    opt_loc_bar_dist = '\232\161\128\230\157\161\229\137\175\230\160\135\233\162\152\230\152\190\231\164\186\232\183\157\231\166\187 (Distance in HP Bar)',
    opt_loc_bar_dist_desc = '\229\156\168\233\156\184\231\142\139\232\153\171\232\161\128\233\135\143\230\157\161\228\184\139\230\150\185\231\154\132\231\138\182\230\128\129\230\160\143\229\144\140\230\151\182\230\152\190\231\164\186\229\189\147\229\137\141\232\183\157\231\166\187\228\184\142\231\155\184\229\175\185\230\150\185\228\189\141\227\128\130',
    opt_loc_squad = '\233\155\183\232\190\190\230\152\190\231\164\186\233\152\159\229\143\139\228\189\141\231\189\174 (Show Squad on Radar)',
    opt_loc_squad_desc = '\229\156\168\230\136\152\230\156\175\229\174\154\228\189\141\233\155\183\232\190\190\228\184\138\231\148\168\232\147\157\231\130\185\230\160\135\229\135\186\233\152\159\229\143\139\228\189\141\231\189\174\228\189\156\228\184\186\231\169\186\233\151\180\229\143\130\231\133\167\227\128\130',
    opt_loc_range = '\233\155\183\232\190\190\230\142\162\230\181\139\229\141\138\229\190\132 m (Radar Range)',
    opt_loc_range_desc = '\230\136\152\230\156\175\233\155\183\232\190\190\229\156\134\229\156\136\232\190\185\231\188\152\229\175\185\229\186\148\231\154\132\229\174\158\233\153\133\232\183\157\231\166\187\239\188\136\231\177\179\239\188\137\239\188\155\232\182\133\229\135\186\230\151\182\232\190\185\231\188\152\230\152\190\231\164\186\230\150\185\229\144\145\228\184\137\232\167\146\230\160\135\227\128\130',
    opt_loc_radar_scale = '\233\155\183\232\190\190\229\164\167\229\176\143\231\188\169\230\148\190 (Radar Scale)',
    opt_loc_radar_x = '\233\155\183\232\190\190\230\176\180\229\185\179\229\129\143\231\167\187 (Radar X Offset)',
    opt_loc_radar_y = '\233\155\183\232\190\190\229\158\130\231\155\180\229\129\143\231\167\187 (Radar Y Offset)',
    opt_loc_ptr_radius = '\230\150\185\228\189\141\231\174\173\229\164\180\231\142\175\231\187\149\229\141\138\229\190\132 (Pointer Radius)',
    opt_lang = '\231\149\140\233\157\162\232\175\173\232\168\128 (Language)',
    opt_lang_desc = '\229\136\135\230\141\162\232\161\128\230\157\161\227\128\129\229\174\154\228\189\141\233\155\183\232\190\190\228\184\142\232\174\190\231\189\174\232\143\156\229\141\149\231\154\132\230\152\190\231\164\186\232\175\173\232\168\128\239\188\136\232\135\170\229\138\168\230\168\161\229\188\143\232\183\159\233\154\143\230\184\184\230\136\143\228\184\142 MDL3 \232\175\173\232\168\128\239\188\137\227\128\130',
    opt_lang_auto = '\232\135\170\229\138\168\232\183\159\233\154\143\230\184\184\230\136\143 (Auto)',
    opt_lang_zh = '\228\184\173\230\150\135 (Chinese)',
    opt_lang_en = '\232\139\177\230\150\135 (English)',
}

local EN = {
    mod_title = 'Hive Lord HP & Locator',
    mod_desc = 'Real-time Hive Lord exact HP bar & tactical locator radar/pointer via MDL3 + HD2 Data Hub (read-only).',
    boss_name = 'HIVE LORD',
    slain = 'SLAIN',
    submerged = 'SUBMERGED',
    preview_tag = 'PREVIEW',
    active_tag = 'LIVE',
    loc_radar_title = 'HIVE LORD RADAR',
    loc_waiting = 'LOCATING...',
    loc_live = 'LIVE',
    loc_last_seen = 'LAST SEEN',
    loc_range_tag = 'RANGE',
    loc_sec_ago = 's ago',
    loc_burrow_short = 'SUB',
    dir_f = 'FRONT',
    dir_fr = 'FR',
    dir_r = 'RIGHT',
    dir_br = 'BR',
    dir_b = 'BEHIND',
    dir_bl = 'BL',
    dir_l = 'LEFT',
    dir_fl = 'FL',
    dir_near = 'NEAR',
    opt_hud = 'Show Boss Health Bar',
    opt_hud_desc = 'Display real-time exact health bar and HP numbers when a Hive Lord spawns or takes damage.',
    opt_preview = 'Preview HUD on Ship',
    opt_preview_desc = 'Show a sample Boss Bar and Locator Radar/Pointer immediately to tune position and scale.',
    opt_pos = 'Bar Anchor Position',
    opt_pos_top = 'Top Center (Boss Bar)',
    opt_pos_bottom = 'Bottom Center (Classic)',
    opt_scale = 'HUD Scale',
    opt_offset_y = 'Vertical Margin (px)',
    opt_offset_y_desc = 'Distance from the anchored top or bottom screen edge (scaled from 1080p).',
    opt_offset_x = 'Horizontal Offset (px)',
    opt_offset_x_desc = 'Horizontal pixel offset from screen center (negative = left, positive = right, 0 = centered).',
    opt_alpha = 'Opacity',
    opt_bar = 'Draw Solid Progress Bar',
    opt_death_hold = 'Post-Kill Hold (seconds)',
    opt_loc_radar = 'Show Tactical Locator Radar',
    opt_loc_radar_desc = 'Draw a top-down player-relative mini-radar showing Hive Lord position and distance (MDL3 dev.41+).',
    opt_loc_pointer = 'Show Center Direction Pointer',
    opt_loc_pointer_desc = 'Draw a dynamic directional arrow and distance badge around screen center pointing to the Hive Lord.',
    opt_loc_bar_dist = 'Show Distance on Boss Bar',
    opt_loc_bar_dist_desc = 'Include live distance and relative direction in the Boss Health Bar subtitle.',
    opt_loc_squad = 'Show Squadmates on Radar',
    opt_loc_squad_desc = 'Plot live squadmate dots on the tactical radar as spatial reference.',
    opt_loc_range = 'Radar Range (m)',
    opt_loc_range_desc = 'Distance in meters corresponding to the outer radar ring; distant targets clamp to the rim.',
    opt_loc_radar_scale = 'Radar Scale',
    opt_loc_radar_x = 'Radar X Offset (px)',
    opt_loc_radar_y = 'Radar Y Offset (px)',
    opt_loc_ptr_radius = 'Pointer Orbit Radius (px)',
    opt_lang = 'Display Language',
    opt_lang_desc = 'Language for Boss Bar, Locator Radar, and Settings (Auto follows game/MDL3 locale).',
    opt_lang_auto = 'Auto (Follow Game / MDL3)',
    opt_lang_zh = 'Chinese',
    opt_lang_en = 'English',
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

local atan2_native = math.atan2
local function atan2(y, x)
    if atan2_native then return atan2_native(y, x) end
    if x > 0 then return math.atan(y / x) end
    if x < 0 then
        if y >= 0 then return math.atan(y / x) + math.pi end
        return math.atan(y / x) - math.pi
    end
    if y > 0 then return math.pi * 0.5 end
    if y < 0 then return -math.pi * 0.5 end
    return 0
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
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
    cands[#cands + 1] = 'C:/ProgramData/MDL/Helldivers2'
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
    language = 'auto',          -- 'auto' (follow game/MDL3), 'zh', or 'en'
    hud_position = 'top',       -- 'top' (Boss Bar below compass) or 'bottom'
    hud_scale = 1.0,
    hud_offset_y = 135,         -- pixels from top/bottom at 1080p
    hud_offset_x = 0,
    hud_alpha = 0.90,
    hud_bar = true,
    hud_native_font = true,
    locator_radar = true,
    locator_pointer = true,
    locator_bar_distance = true,
    locator_squad = true,
    locator_range = 250,
    locator_radar_scale = 1.00,
    locator_radar_x = 770,      -- offset from screen center (1080p ref px)
    locator_radar_y = -180,     -- offset from screen center (1080p ref px)
    locator_pointer_radius = 165,
    poll_seconds = 0.25,
    burrow_hold_seconds = 60.0,
    death_hold_seconds = 5.0,
    surface_cap = 12,
    debug = false,
}

local C = {}
for k, v in pairs(DEFAULTS) do C[k] = v end
local cfg_explicit = {}
local cfg_path = nil
local cfg_created = false

local NUM_BOUNDS = {
    hud_scale = { 0.25, 4.00 },
    hud_offset_y = { 0, 2000 },
    hud_offset_x = { -2000, 2000 },
    hud_alpha = { 0.05, 1.00 },
    locator_range = { 50, 1000 },
    locator_radar_scale = { 0.40, 3.00 },
    locator_radar_x = { -1500, 1500 },
    locator_radar_y = { -1000, 1000 },
    locator_pointer_radius = { 40, 500 },
    poll_seconds = { 0.05, 10.0 },
    burrow_hold_seconds = { 0, 600.0 },
    death_hold_seconds = { 0, 120.0 },
    surface_cap = { 1, 100 },
}

local function clamp_num(key, n)
    local b = NUM_BOUNDS[key]
    if not b then return n end
    if n < b[1] then return b[1] end
    if n > b[2] then return b[2] end
    return n
end

local function render_config_text()
    return string.format([[# Hive Lord Health & Locator v%s settings (MDL3 + HD2 Data Hub >= 0.3.0)
# Edit here or adjust live in-game via ESC -> MDL Settings -> Hive Lord HP & Locator.
# In-game adjustments are saved automatically to this file.
# Delete this file to regenerate defaults.

# Show the Hive Lord Boss Health Bar on screen (true / false).
hud = %s

# Display language: auto (follow game/MDL3), zh (Chinese), or en (English).
language = %s

# Anchor position: top (below compass) or bottom (above lower edge).
hud_position = %s

# Scale factor on top of 1080p resolution scaling (e.g. 0.75, 1.00, 1.25).
hud_scale = %.2f

# Distance in 1080p pixels from the anchored top or bottom edge.
hud_offset_y = %d

# Horizontal offset in 1080p pixels from screen center (negative = left, positive = right, 0 = centered).
hud_offset_x = %d

# Overall opacity from 0.20 to 1.00.
hud_alpha = %.2f

# Draw solid progress bar frame and fill rectangles (true / false).
hud_bar = %s

# Show tactical top-down radar overlay via MDL3.gui (true / false).
locator_radar = %s

# Show screen-center directional arrow + distance via MDL3.gui (true / false).
locator_pointer = %s

# Include live distance and direction in the Boss Health Bar subtitle (true / false).
locator_bar_distance = %s

# Plot squadmate positions on the tactical radar (true / false).
locator_squad = %s

# Tactical radar outer ring radius in meters (50 - 1000).
locator_range = %d

# Tactical radar size multiplier (0.40 - 3.00).
locator_radar_scale = %.2f

# Radar horizontal offset in 1080p pixels from screen center.
locator_radar_x = %d

# Radar vertical offset in 1080p pixels from screen center (negative = upper half).
locator_radar_y = %d

# Center directional pointer orbit radius in 1080p pixels.
locator_pointer_radius = %d

# Status / hub diagnostic check interval in seconds.
poll_seconds = %.2f

# Seconds to keep last HP visible when the Hive Lord burrows underground.
burrow_hold_seconds = %.1f

# Seconds to keep 0 / 150000 visible after the Hive Lord is slain.
death_hold_seconds = %.1f

# Verbose per-hit event logging to hivelord_health.log.
debug = %s
]],
        VERSION,
        tostring(C.hud == true),
        (C.language == 'zh' or C.language == 'en') and C.language or 'auto',
        (C.hud_position == 'bottom') and 'bottom' or 'top',
        tonumber(C.hud_scale) or DEFAULTS.hud_scale,
        math.floor((tonumber(C.hud_offset_y) or DEFAULTS.hud_offset_y) + 0.5),
        math.floor((tonumber(C.hud_offset_x) or DEFAULTS.hud_offset_x) + 0.5),
        tonumber(C.hud_alpha) or DEFAULTS.hud_alpha,
        tostring(C.hud_bar == true),
        tostring(C.locator_radar == true),
        tostring(C.locator_pointer == true),
        tostring(C.locator_bar_distance == true),
        tostring(C.locator_squad == true),
        math.floor((tonumber(C.locator_range) or DEFAULTS.locator_range) + 0.5),
        tonumber(C.locator_radar_scale) or DEFAULTS.locator_radar_scale,
        math.floor((tonumber(C.locator_radar_x) or DEFAULTS.locator_radar_x) + 0.5),
        math.floor((tonumber(C.locator_radar_y) or DEFAULTS.locator_radar_y) + 0.5),
        math.floor((tonumber(C.locator_pointer_radius) or DEFAULTS.locator_pointer_radius) + 0.5),
        tonumber(C.poll_seconds) or DEFAULTS.poll_seconds,
        tonumber(C.burrow_hold_seconds) or DEFAULTS.burrow_hold_seconds,
        tonumber(C.death_hold_seconds) or DEFAULTS.death_hold_seconds,
        tostring(C.debug == true))
end

local LANG_ALIASES = {
    auto = 'auto',
    default = 'auto',
    ['1'] = 'auto',
    zh = 'zh',
    cn = 'zh',
    zhs = 'zh',
    zht = 'zh',
    ['zh-cn'] = 'zh',
    ['zh-hans'] = 'zh',
    ['zh-hant'] = 'zh',
    chinese = 'zh',
    ['2'] = 'zh',
    en = 'en',
    ['en-us'] = 'en',
    ['en-gb'] = 'en',
    english = 'en',
    ['3'] = 'en',
}

local POS_ALIASES = {
    top = 'top',
    ['1'] = 'top',
    upper = 'top',
    bottom = 'bottom',
    ['2'] = 'bottom',
    lower = 'bottom',
}

local BOOL_ALIASES = {
    ['true'] = true,
    ['1'] = true,
    yes = true,
    on = true,
    ['false'] = false,
    ['0'] = false,
    no = false,
    off = false,
}

local function parse_config_handle(f, mark_explicit)
    local legacy_v1 = false
    for raw_l in f:lines() do
        local l = raw_l:gsub('^\239\187\191', ''):gsub('\r', ''):gsub('[#;].*$', '')
        local k, raw_v = l:match('^%s*([%w_]+)%s*=%s*(.-)%s*$')
        if k and raw_v and raw_v ~= '' then
            if k == 'draw_every' or k == 'start_delay' then
                legacy_v1 = true
            end
            local v = raw_v:match('^"(.*)"$') or raw_v:match("^'(.*)'$") or raw_v
            if C[k] ~= nil then
                if type(DEFAULTS[k]) == 'boolean' then
                    local bv = BOOL_ALIASES[v:lower()]
                    if bv ~= nil then
                        C[k] = bv
                        if mark_explicit then cfg_explicit[k] = true end
                    end
                elseif k == 'language' then
                    local lv = LANG_ALIASES[v:lower()]
                    if lv then
                        C[k] = lv
                        if mark_explicit then cfg_explicit[k] = true end
                    end
                elseif k == 'hud_position' then
                    local sv = POS_ALIASES[v:lower()]
                    if sv then
                        C[k] = sv
                        if mark_explicit then cfg_explicit[k] = true end
                    end
                elseif type(DEFAULTS[k]) == 'number' then
                    local n = tonumber(v)
                    if n and n == n and n > -1e9 and n < 1e9 then
                        C[k] = clamp_num(k, n)
                        if mark_explicit then cfg_explicit[k] = true end
                    end
                end
            end
        end
    end
    if legacy_v1 and C.poll_seconds == 1 then
        C.poll_seconds = DEFAULTS.poll_seconds
    end
end

local function config_candidate_dirs()
    local dirs = {}
    local seen = {}
    local function push(d)
        if type(d) == 'string' and d ~= '' and not seen[d] then
            seen[d] = true
            dirs[#dirs + 1] = d
        end
    end
    local app = ok_call(os.getenv, 'APPDATA')
    if app then push(app .. '/Arrowhead/Helldivers2') end
    push(outdir)
    push('C:/ProgramData/MDL/Helldivers2')
    return dirs
end

do
    local dirs = config_candidate_dirs()
    local p = dirs[1] and (dirs[1] .. '/hivelord_health.cfg') or nil
    if io and io.open then
        for _, d in ipairs(dirs) do
            local cand = d .. '/hivelord_health.cfg'
            local probe = io.open(cand, 'r')
            if probe then
                probe:close()
                p = cand
                break
            end
        end
    end
    if p and io and io.open then
        local f = io.open(p, 'r')
        if not f then
            for _, d in ipairs(dirs) do
                local cand = d .. '/hivelord_health.cfg'
                local nf = io.open(cand, 'w')
                if nf then
                    p = cand
                    pcall(function() nf:write(render_config_text()); nf:close() end)
                    cfg_created = true
                    wf('CONFIG created %s', p)
                    break
                end
            end
            f = io.open(p, 'r')
        end
        cfg_path = p
        if f then
            parse_config_handle(f, not cfg_created)
            f:close()
            wf('CONFIG loaded %s (hud=%s pos=%s scale=%.2f offset_y=%d offset_x=%d alpha=%.2f)',
                p, tostring(C.hud), tostring(C.hud_position),
                C.hud_scale, C.hud_offset_y, C.hud_offset_x, C.hud_alpha)
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
    -- MDL3 ESC menu foreground, live slider preview & persistent config sync state:
    live_menu_preview = false,
    fg_sig = nil,
    fg_dirty = false,
    fg_due_at = 0,
    fg_next_at = 0,
    options_bound = false,
    mom_ref = nil,
    mom_entries = nil,
    syncing_mom = false,
    mom_post_boot_synced = false,
    was_settings_open = false,
    cfg_dirty = false,
    cfg_save_due_at = 0,
    cfg_last_save_at = -100,
    -- Tactical Locator (HD2Data positions + GameSession live polling + MDL3.gui API 1):
    last_fx = nil,
    last_fy = nil,
    last_player_pos = nil,
    next_goid_poll = 0,
    spatial = nil,
    loc_gui_ref = nil,
    loc_shape_canvas = nil,
    loc_text_canvas = nil,
    loc_visible = false,
    loc_text_key = nil,
    loc_text_last_at = -100,
    loc_warned_err = false,
    last_loc_state = nil,
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
    if C.language == 'zh' then return true end
    if C.language == 'en' then return false end
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
    lines[#lines + 1] = string.format(
        'config: hud=%s lang=%s pos=%s offset_y=%d offset_x=%d scale=%.2f alpha=%.2f radar=%s ptr=%s range=%dm path=%s',
        tostring(C.hud), tostring(C.language or 'auto'), tostring(C.hud_position),
        C.hud_offset_y, C.hud_offset_x, C.hud_scale, C.hud_alpha,
        tostring(C.locator_radar), tostring(C.locator_pointer),
        math.floor((tonumber(C.locator_range) or DEFAULTS.locator_range) + 0.5),
        tostring(cfg_path or 'none'))
    if M.best then
        local r = M.best
        local pct = r.max > 0 and (100.0 * r.hp / r.max) or 0.0
        local tag = r.dead and 'SLAIN' or (r.burrowed and 'SUBMERGED' or 'LIVE')
        local pos_str = r.pos and string.format(' pos=(%.1f,%.1f,%.1f) pos_src=%s',
            r.pos.x, r.pos.y, r.pos.z, tostring(r.pos_source or '?')) or ''
        local prim = M.spatial and M.spatial.primary
        local dist_str = (prim and prim.rec == r and prim.dist)
            and string.format(' dist=%.1fm deg=%d', prim.dist, prim.deg or 0) or ''
        lines[#lines + 1] = string.format('hive_lord: %d / %d (%.1f%%) [%s] entity_id=%s net_id=%s%s%s',
            r.hp, r.max, pct, tag, tostring(r.id), tostring(r.network_id), pos_str, dist_str)
    end
    if M.last_hud then
        lines[#lines + 1] = 'hud: ' .. M.last_hud
    end
    if M.last_loc_state then
        lines[#lines + 1] = 'locator: ' .. M.last_loc_state
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

local function write_config_now(reason)
    if not io or not io.open then return false end
    local targets = {}
    local seen = {}
    local function push_target(p)
        if type(p) == 'string' and p ~= '' and not seen[p] then
            seen[p] = true
            targets[#targets + 1] = p
        end
    end
    push_target(cfg_path)
    for _, d in ipairs(config_candidate_dirs()) do
        push_target(d .. '/hivelord_health.cfg')
    end
    local body = render_config_text()
    for _, p in ipairs(targets) do
        local f = io.open(p, 'w')
        if f then
            local ok = pcall(function()
                f:write(body)
                f:flush()
                f:close()
            end)
            if ok then
                cfg_path = p
                M.cfg_dirty = false
                M.cfg_last_save_at = M.clock
                wf('CONFIG saved %s (%s: hud=%s pos=%s offset_y=%d offset_x=%d scale=%.2f alpha=%.2f)',
                    p, tostring(reason or 'update'), tostring(C.hud),
                    tostring(C.hud_position), C.hud_offset_y, C.hud_offset_x, C.hud_scale, C.hud_alpha)
                update_status_snapshot()
                return true
            end
        end
    end
    wf('CONFIG save_failed (%s)', tostring(reason or 'update'))
    return false
end

local function request_config_save(key, immediate)
    cfg_explicit[key] = true
    M.cfg_dirty = true
    if immediate or (M.clock - (M.cfg_last_save_at or -100)) >= 0.10 then
        write_config_now(key)
    else
        M.cfg_save_due_at = M.clock + 0.10
    end
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

local function mom_values_differ(a, b)
    if type(a) == 'number' and type(b) == 'number' then
        return math.abs(a - b) > 1e-4
    end
    return a ~= b
end

local function sync_mom_from_config(MOM)
    if not MOM or type(MOM.set) ~= 'function' or type(M.mom_entries) ~= 'table' then return end
    M.syncing_mom = true
    for _, ent in ipairs(M.mom_entries) do
        if ent.sync_to_mom then
            local want = ent.to_mom()
            local cur = (type(MOM.get) == 'function') and ok_call(MOM.get, ent.id) or nil
            if cur == nil or mom_values_differ(cur, want) then
                ok_call(MOM.set, ent.id, want)
            end
        end
    end
    M.syncing_mom = false
end

local function bind_mod_options()
    local MOM = find_options_api()
    if not MOM then return end
    if M.options_bound and M.mom_ref == MOM then return end
    M.options_bound = true
    M.mom_ref = MOM
    M.mom_entries = {}
    M.mom_post_boot_synced = false

    local function reg(key, spec, to_mom, from_mom, apply_fn, persist, immediate, visual_preview)
        local id = 'hivelord_health.' .. key
        spec.mod_id = ADDON_ID
        spec.mod = L('mod_title')
        spec.default = to_mom()
        local ok = ok_call(MOM.register_option, id, spec)
        if not ok then return end

        if key == 'hud_preview' and not cfg_explicit[key] then
            if type(MOM.get) == 'function' and type(MOM.set) == 'function'
                and ok_call(MOM.get, id) == true then
                M.syncing_mom = true
                ok_call(MOM.set, id, false)
                M.syncing_mom = false
            end
        elseif cfg_explicit[key] then
            if type(MOM.set) == 'function' then
                local want = to_mom()
                local cur = (type(MOM.get) == 'function') and ok_call(MOM.get, id) or nil
                if cur == nil or mom_values_differ(cur, want) then
                    M.syncing_mom = true
                    ok_call(MOM.set, id, want)
                    M.syncing_mom = false
                end
            end
        elseif type(MOM.get) == 'function' then
            local saved = ok_call(MOM.get, id)
            if saved ~= nil then apply_fn(from_mom(saved), false) end
        end

        M.mom_entries[#M.mom_entries + 1] = {
            id = id,
            key = key,
            to_mom = to_mom,
            sync_to_mom = persist == true,
        }

        if type(MOM.on_change) == 'function' then
            ok_call(MOM.on_change, id, function(val)
                if M.syncing_mom then return end
                local applied = apply_fn(from_mom(val), true)
                if applied and persist then
                    request_config_save(key, immediate)
                end
                M.draw_key, M.bar_key, M.loc_text_key = nil, nil, nil
                M.text_last_rebuild = -100
                if visual_preview then trigger_mdl_live_preview() end
            end)
        end
    end

    local id_fn = function(v) return v end
    reg('hud', {
        type = 'toggle',
        label = L('opt_hud'), description = L('opt_hud_desc'),
    }, function() return C.hud == true end, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud = v
            if changed then wf('OPTION hud=%s', tostring(v)) end
            return true
        end
        return false
    end, true, true, false)

    reg('hud_preview', {
        type = 'toggle',
        label = L('opt_preview'), description = L('opt_preview_desc'),
    }, function() return C.hud_preview == true end, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud_preview = v
            if changed then wf('OPTION hud_preview=%s', tostring(v)) end
            return true
        end
        return false
    end, false, false, true)

    reg('language', {
        type = 'choice',
        choices = { L('opt_lang_auto'), L('opt_lang_zh'), L('opt_lang_en') },
        label = L('opt_lang'), description = L('opt_lang_desc'),
    }, function()
        if C.language == 'zh' then return 2 end
        if C.language == 'en' then return 3 end
        return 1
    end, function(v)
        if v == 2 then return 'zh' end
        if v == 3 then return 'en' end
        return 'auto'
    end, function(v, changed)
        if v == 'auto' or v == 'zh' or v == 'en' then
            C.language = v
            if changed then
                wf('OPTION language=%s', v)
                update_status_snapshot()
            end
            return true
        end
        return false
    end, true, true, true)

    reg('hud_position', {
        type = 'choice',
        choices = { L('opt_pos_top'), L('opt_pos_bottom') },
        label = L('opt_pos'),
    }, function() return C.hud_position == 'bottom' and 2 or 1 end,
    function(v) return v == 2 and 'bottom' or 'top' end, function(v, changed)
        if v == 'top' or v == 'bottom' then
            C.hud_position = v
            if changed then wf('OPTION hud_position=%s', v) end
            return true
        end
        return false
    end, true, true, true)

    reg('hud_scale', {
        type = 'slider', min = 0.50, max = 2.50, step = 0.05,
        label = L('opt_scale'),
    }, function() return math.max(0.50, math.min(2.50, tonumber(C.hud_scale) or DEFAULTS.hud_scale)) end,
    id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0.25 and v <= 4.0 then
            C.hud_scale = v
            if changed then wf('OPTION hud_scale=%.2f', v) end
            return true
        end
        return false
    end, true, false, true)

    reg('hud_offset_y', {
        type = 'slider', min = 10, max = 540, step = 5,
        label = L('opt_offset_y'), description = L('opt_offset_y_desc'),
    }, function()
        return math.max(10, math.min(540, math.floor((tonumber(C.hud_offset_y) or DEFAULTS.hud_offset_y) + 0.5)))
    end, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0 and v <= 2000 then
            C.hud_offset_y = math.floor(v + 0.5)
            if changed then wf('OPTION hud_offset_y=%d', C.hud_offset_y) end
            return true
        end
        return false
    end, true, false, true)

    reg('hud_offset_x', {
        type = 'slider', min = -600, max = 600, step = 10,
        label = L('opt_offset_x'), description = L('opt_offset_x_desc'),
    }, function()
        return math.max(-600, math.min(600, math.floor((tonumber(C.hud_offset_x) or DEFAULTS.hud_offset_x) + 0.5)))
    end, id_fn, function(v, changed)
        if type(v) == 'number' and v >= -2000 and v <= 2000 then
            C.hud_offset_x = math.floor(v + 0.5)
            if changed then wf('OPTION hud_offset_x=%d', C.hud_offset_x) end
            return true
        end
        return false
    end, true, false, true)

    reg('hud_alpha', {
        type = 'slider', min = 0.20, max = 1.00, step = 0.05,
        label = L('opt_alpha'),
    }, function() return math.max(0.20, math.min(1.00, tonumber(C.hud_alpha) or DEFAULTS.hud_alpha)) end,
    id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0.05 and v <= 1.0 then
            C.hud_alpha = v
            if changed then wf('OPTION hud_alpha=%.2f', v) end
            return true
        end
        return false
    end, true, false, true)

    reg('hud_bar', {
        type = 'toggle',
        label = L('opt_bar'),
    }, function() return C.hud_bar == true end, id_fn, function(v, changed)
        if type(v) == 'boolean' then
            C.hud_bar = v
            if changed then wf('OPTION hud_bar=%s', tostring(v)) end
            return true
        end
        return false
    end, true, true, true)

    reg('death_hold_seconds', {
        type = 'slider', min = 0, max = 15, step = 1,
        label = L('opt_death_hold'),
    }, function()
        return math.max(0, math.min(15, math.floor((tonumber(C.death_hold_seconds) or DEFAULTS.death_hold_seconds) + 0.5)))
    end, id_fn, function(v, changed)
        if type(v) == 'number' and v >= 0 and v <= 120 then
            C.death_hold_seconds = v
            if changed then wf('OPTION death_hold_seconds=%d', v) end
            return true
        end
        return false
    end, true, false, false)

    local function reg_bool(key, label_key, desc_key, immediate, visual_preview)
        local spec = { type = 'toggle', label = L(label_key) }
        if desc_key then spec.description = L(desc_key) end
        reg(key, spec, function() return C[key] == true end, id_fn, function(v, changed)
            if type(v) == 'boolean' then
                C[key] = v
                if changed then wf('OPTION %s=%s', key, tostring(v)) end
                return true
            end
            return false
        end, true, immediate, visual_preview)
    end

    local function reg_num(key, min_v, max_v, step_v, label_key, desc_key, is_int, visual_preview)
        local spec = { type = 'slider', min = min_v, max = max_v, step = step_v, label = L(label_key) }
        if desc_key then spec.description = L(desc_key) end
        local b = NUM_BOUNDS[key]
        reg(key, spec, function()
            local cur = tonumber(C[key]) or DEFAULTS[key]
            local clamped = clamp(cur, min_v, max_v)
            return is_int and math.floor(clamped + 0.5) or clamped
        end, id_fn, function(v, changed)
            if type(v) == 'number' and (not b or (v >= b[1] and v <= b[2])) then
                C[key] = is_int and math.floor(v + 0.5) or v
                if changed then
                    wf(is_int and ('OPTION %s=%d') or ('OPTION %s=%.2f'), key, C[key])
                end
                return true
            end
            return false
        end, true, false, visual_preview)
    end

    reg_bool('locator_radar', 'opt_loc_radar', 'opt_loc_radar_desc', true, true)
    reg_bool('locator_pointer', 'opt_loc_pointer', 'opt_loc_pointer_desc', true, true)
    reg_bool('locator_bar_distance', 'opt_loc_bar_dist', 'opt_loc_bar_dist_desc', true, true)
    reg_bool('locator_squad', 'opt_loc_squad', 'opt_loc_squad_desc', true, true)
    reg_num('locator_range', 100, 500, 25, 'opt_loc_range', 'opt_loc_range_desc', true, true)
    reg_num('locator_radar_scale', 0.60, 2.00, 0.05, 'opt_loc_radar_scale', nil, false, true)
    reg_num('locator_radar_x', -900, 900, 10, 'opt_loc_radar_x', nil, true, true)
    reg_num('locator_radar_y', -450, 450, 10, 'opt_loc_radar_y', nil, true, true)
    reg_num('locator_pointer_radius', 80, 360, 5, 'opt_loc_ptr_radius', nil, true, true)

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

local function read_pos_xyz(p)
    if type(p) ~= 'table' then return nil end
    local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
    if not (x and y and z) then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    if math.abs(x) > 100000 or math.abs(y) > 100000 or math.abs(z) > 100000 then return nil end
    return { x = x, y = y, z = z }
end

local function extract_event_position(e)
    if type(e) ~= 'table' then return nil end
    local direct = read_pos_xyz(e.position)
    if direct then return direct end
    local ent = e.entity
    if type(ent) == 'table' then
        if type(ent.position) == 'function' then
            local parsed = read_pos_xyz(ok_call(ent.position, ent))
            if parsed then return parsed end
        end
        local cached = read_pos_xyz(ent.pos)
        if cached then return cached end
    end
    return nil
end

local function pos_dist(a, b)
    if not a or not b then return nil end
    local dx = a.x - b.x
    local dy = a.y - b.y
    local dz = (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function read_sr_vec3(v)
    local tv = type(v)
    if tv == 'table' then
        return read_pos_xyz(v)
    end
    if tv ~= 'userdata' then return nil end
    local ok_s, ts = pcall(tostring, v)
    if not ok_s or type(ts) ~= 'string' or not ts:find('^Vector3%(') then
        return nil
    end
    local sr = _G.stingray
    local V3 = sr and sr.Vector3
    if (type(V3) == 'table' or type(V3) == 'userdata') and type(V3.x) == 'function'
        and type(V3.y) == 'function' and type(V3.z) == 'function' then
        local x = ok_call(V3.x, v)
        local y = ok_call(V3.y, v)
        local z = ok_call(V3.z, v)
        if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
            return read_pos_xyz({ x = x, y = y, z = z })
        end
    end
    local sx, sy, sz = ts:match('^Vector3%(([^,]+),%s*([^,]+),%s*([^%)]+)%)')
    if sx and sy and sz then
        return read_pos_xyz({ x = tonumber(sx), y = tonumber(sy), z = tonumber(sz) })
    end
    return nil
end

local function is_world_pos_vec(v, ref_pos)
    if not v then return false end
    if math.abs(v.x) > 5000 or math.abs(v.y) > 5000 or math.abs(v.z) > 2000 then return false end
    local n2 = v.x * v.x + v.y * v.y + v.z * v.z
    if n2 < 4.0 then
        if not ref_pos or (ref_pos.x * ref_pos.x + ref_pos.y * ref_pos.y) > 100.0 then
            return false
        end
    end
    return true
end

local function get_game_session()
    local sr = _G.stingray
    if not sr then return nil, nil end
    local Net, GS = sr.Network, sr.GameSession
    if type(Net) ~= 'table' and type(Net) ~= 'userdata' then return nil, nil end
    if type(GS) ~= 'table' and type(GS) ~= 'userdata' then return nil, nil end
    if type(Net.game_session) ~= 'function'
        or type(GS.game_object_exists) ~= 'function'
        or type(GS.game_object_field_batched) ~= 'function' then
        return nil, nil
    end
    local session = ok_call(Net.game_session)
    if not session then return nil, nil end
    if type(GS.in_session) == 'function' and ok_call(GS.in_session, session) == false then
        return nil, nil
    end
    return session, GS
end

local function update_record_pos(rec, pos, source)
    if not rec or not pos then return end
    rec.pos = pos
    rec.pos_at = M.clock
    rec.pos_source = source
end

local function reset_goid_tracking(rec)
    if not rec then return end
    rec.goid_cands = nil
    rec.goid_locked = nil
    rec.goid_cluster_built = nil
    rec.goid_live_moved = false
    rec.goid_last_at = nil
    rec.goid_retry_at = nil
    rec.goid_retries = nil
    rec.goid_diag_logged = nil
    rec.goid_scan_cursor = nil
    rec.goid_scan_done = nil
end

local function max_field_index(fields)
    local n = 0
    for k in pairs(fields) do
        if type(k) == 'number' and k >= 1 and k <= 256 and k == math.floor(k) and k > n then
            n = k
        end
    end
    return n
end

local function discover_goid_cands(session, GS, rec)
    local base = tonumber(rec.network_id)
    if not base then return end
    local ref = rec.spawn_pos or rec.event_pos or M.last_player_pos

    local targets = {}
    local seen_g = {}
    local function push_g(g, prio)
        if type(g) == 'number' and g >= 0 and g < 65536 and g == math.floor(g) and not seen_g[g] then
            seen_g[g] = true
            targets[#targets + 1] = { goid = g, prio = prio }
        end
    end

    push_g(base, 3)
    local base_fields = nil
    if ok_call(GS.game_object_exists, session, base) == true then
        base_fields = ok_call(GS.game_object_field_batched, session, base, {})
        if type(base_fields) == 'table' then
            local n_bf = max_field_index(base_fields)
            for i = 1, n_bf do
                local v = base_fields[i]
                if type(v) == 'table' and not read_sr_vec3(v) then
                    local count = 0
                    for _, raw_lid in pairs(v) do
                        local lid = tonumber(raw_lid)
                        if lid then
                            push_g(lid, 2)
                            count = count + 1
                            if count >= 16 then break end
                        end
                    end
                end
            end
        end
    end
    for delta = -6, 6 do
        if delta ~= 0 then push_g(base + delta, 1) end
    end

    local cands = {}
    local n_cands = 0
    local diag_parts = {}
    for _, entry in ipairs(targets) do
        local g, prio = entry.goid, entry.prio
        local fields = (g == base) and base_fields or nil
        if fields == nil and ok_call(GS.game_object_exists, session, g) == true then
            fields = ok_call(GS.game_object_field_batched, session, g, {})
        end
        if type(fields) == 'table' then
            local n_f = max_field_index(fields)
            for i = 1, n_f do
                local vec = read_sr_vec3(fields[i])
                if vec and is_world_pos_vec(vec, ref) then
                    local d = ref and pos_dist(vec, ref) or nil
                    local max_d = (prio >= 2 and 1500.0) or ((rec.spawn_pos and 35.0) or 1500.0)
                    if (not d or d <= max_d) then
                        local key = tostring(g) .. ':' .. tostring(i)
                        cands[key] = {
                            goid = g,
                            idx = i,
                            prio = prio,
                            init = vec,
                            cur = vec,
                            moved = 0,
                            init_dist = d or 0,
                        }
                        n_cands = n_cands + 1
                        if #diag_parts < 8 then
                            diag_parts[#diag_parts + 1] = string.format('%d[%d]:(%.1f,%.1f,%.1f)',
                                g, i, vec.x, vec.y, vec.z)
                        end
                    end
                end
            end
        end
    end

    rec.goid_cands = cands
    rec.goid_cluster_built = true
    if not rec.goid_diag_logged then
        rec.goid_diag_logged = true
        wf('GOID_VECS id=%s base=%d spawn=%s cands=%d [%s]',
            tostring(rec.id), base,
            rec.spawn_pos and string.format('(%.1f,%.1f,%.1f)', rec.spawn_pos.x, rec.spawn_pos.y, rec.spawn_pos.z) or 'nil',
            n_cands, table.concat(diag_parts, ' '))
    end
    if n_cands == 0 then
        rec.goid_retries = (rec.goid_retries or 0) + 1
        if rec.goid_retries < 4 then
            rec.goid_cluster_built = false
            rec.goid_retry_at = M.clock + 0.5
        end
    end
end

local function scan_goid_for_record(session, GS, rec)
    if rec.goid_scan_done or rec.network_id ~= nil then return end
    local want_max = rec.max or DEFAULT_MAX_HP
    local ref = rec.spawn_pos or rec.event_pos
    local cur = rec.goid_scan_cursor or 1
    local stop = math.min(16384, cur + 255)
    for g = cur, stop do
        if ok_call(GS.game_object_exists, session, g) == true then
            local fields = ok_call(GS.game_object_field_batched, session, g, {})
            if type(fields) == 'table' then
                local has_max, has_vec = false, false
                local n_f = max_field_index(fields)
                for i = 1, n_f do
                    local v = fields[i]
                    if v == want_max then has_max = true end
                    if not has_vec and ref then
                        local vec = read_sr_vec3(v)
                        if vec and is_world_pos_vec(vec, ref) and (pos_dist(vec, ref) or 9999) <= 80.0 then
                            has_vec = true
                        end
                    end
                    if has_max and (has_vec or not ref) then break end
                end
                if has_max and (has_vec or not ref) then
                    rec.network_id = g
                    rec.goid_scan_done = true
                    wf('GOID_SCAN_MATCH id=%s goid=%d max=%d', tostring(rec.id), g, want_max)
                    return
                end
            end
        end
    end
    if stop >= 16384 then
        rec.goid_scan_done = true
    else
        rec.goid_scan_cursor = stop + 1
    end
end

local function candidate_better(a, b)
    local ma = (a.moved or 0) >= 0.5
    local mb = (b.moved or 0) >= 0.5
    if ma ~= mb then return ma end
    if a.prio ~= b.prio then return a.prio > b.prio end
    return (a.init_dist or 0) < (b.init_dist or 0)
end

local function poll_record_live_pos(session, GS, rec)
    if rec.dead then return end
    if rec.network_id == nil then
        scan_goid_for_record(session, GS, rec)
        if rec.network_id == nil then return end
    end

    if rec.goid_locked then
        local c = rec.goid_locked
        if ok_call(GS.game_object_exists, session, c.goid) == true then
            local fields = ok_call(GS.game_object_field_batched, session, c.goid, {})
            local v = type(fields) == 'table' and read_sr_vec3(fields[c.idx]) or nil
            if v and is_world_pos_vec(v, rec.spawn_pos or c.init) then
                local step_d = pos_dist(v, c.cur) or 0
                if step_d <= 350.0 then
                    c.cur = v
                    c.moved = math.max(c.moved or 0, pos_dist(v, c.init) or 0)
                    rec.goid_last_at = M.clock
                    rec.goid_live_moved = (c.moved >= 0.5)
                    update_record_pos(rec, v, 'goid_live')
                    return
                end
            end
        end
        rec.goid_locked = nil
        rec.goid_live_moved = false
        return
    end

    if not rec.goid_cluster_built and M.clock >= (rec.goid_retry_at or 0) then
        discover_goid_cands(session, GS, rec)
    end
    if not rec.goid_cands or next(rec.goid_cands) == nil then return end

    local by_goid = {}
    for _, c in pairs(rec.goid_cands) do
        local list = by_goid[c.goid]
        if not list then
            list = {}
            by_goid[c.goid] = list
        end
        list[#list + 1] = c
    end

    local best_c = nil
    for g, list in pairs(by_goid) do
        if ok_call(GS.game_object_exists, session, g) == true then
            local fields = ok_call(GS.game_object_field_batched, session, g, {})
            if type(fields) == 'table' then
                for _, c in ipairs(list) do
                    local v = read_sr_vec3(fields[c.idx])
                    if v and is_world_pos_vec(v, rec.spawn_pos or c.init) then
                        local step_d = pos_dist(v, c.cur) or 0
                        if step_d <= 350.0 then
                            c.cur = v
                            c.moved = math.max(c.moved or 0, pos_dist(v, c.init) or 0)
                            if not best_c or candidate_better(c, best_c) then
                                best_c = c
                            end
                        end
                    end
                end
            end
        end
    end

    if best_c then
        rec.goid_last_at = M.clock
        update_record_pos(rec, best_c.cur, 'goid_live')
        if (best_c.moved or 0) >= 0.5 then
            rec.goid_locked = best_c
            rec.goid_live_moved = true
            wf('GOID_LIVE_LOCK id=%s goid=%d idx=%d prio=%d moved=%.1fm pos=(%.1f,%.1f,%.1f)',
                tostring(rec.id), best_c.goid, best_c.idx, best_c.prio, best_c.moved,
                best_c.cur.x, best_c.cur.y, best_c.cur.z)
        end
    end
end

local function poll_live_positions()
    if not M.in_mission or next(M.records) == nil then return end
    local want_any = C.locator_radar or C.locator_pointer or C.locator_bar_distance
    if not want_any then return end
    if M.clock < (M.next_goid_poll or 0) then return end
    M.next_goid_poll = M.clock + 0.033

    local session, GS = get_game_session()
    if not session or not GS then return end
    for _, rec in pairs(M.records) do
        if not rec.dead then
            poll_record_live_pos(session, GS, rec)
        end
    end
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
    M.spatial = nil
    M.last_fx = nil
    M.last_fy = nil
    M.last_player_pos = nil
    M.next_goid_poll = 0
    if new_epoch ~= nil then M.epoch = new_epoch end
    if had then
        wf('MISSION_RESET reason=%s epoch=%s', tostring(reason), tostring(M.epoch))
        update_status_snapshot()
    end
end

local function sync_event_epoch(e)
    local ep = type(e) == 'table' and (e.epoch ~= nil and e.epoch or e.mission) or nil
    if ep ~= nil then
        if M.epoch ~= nil and ep ~= M.epoch and M.in_mission then
            reset_records('event_epoch_change', ep)
        else
            M.epoch = ep
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
    local pos = extract_event_position(e)
    local old_k, carry = find_carry_record(id, e.network_id)
    if carry then
        if old_k ~= id then M.records[old_k] = nil end
        local net_changed = e.network_id ~= nil and carry.network_id ~= nil
            and tostring(e.network_id) ~= tostring(carry.network_id)
        carry.id = id
        carry.max = max_hp > 0 and max_hp or carry.max
        if carry.hp > carry.max then carry.hp = carry.max end
        carry.entity = e.entity or carry.entity
        carry.unit_id = e.unit_id or carry.unit_id
        carry.network_id = e.network_id or carry.network_id
        carry.burrowed = false
        carry.invalid_since = nil
        carry.updated_at = M.clock
        if pos then
            carry.spawn_pos = pos
            carry.event_pos = pos
        end
        if pos or net_changed then
            reset_goid_tracking(carry)
        end
        update_record_pos(carry, pos, 'resurface')
        M.records[id] = carry
        wf('HIVE_LORD_RESURFACE id=%s hp=%d/%d net=%s',
            tostring(id), carry.hp, carry.max, tostring(carry.network_id))
    else
        M.ever_seen = M.ever_seen + 1
        local rec = {
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
            pos = nil,
            pos_at = nil,
            pos_source = nil,
            spawn_pos = pos,
            event_pos = pos,
        }
        update_record_pos(rec, pos, 'spawn')
        M.records[id] = rec
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
    if not rec then
        local old_k, carry = find_carry_record(id, e.network_id)
        if carry then
            if old_k ~= id then M.records[old_k] = nil end
            rec = carry
            rec.id = id
            M.records[id] = rec
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

    local prev_net = rec.network_id
    rec.hp = hp
    rec.max = max_hp
    if not rec.trail_hp or rec.trail_hp < hp then rec.trail_hp = hp end
    rec.entity = e.entity or rec.entity
    rec.unit_id = e.unit_id or rec.unit_id
    rec.network_id = e.network_id or rec.network_id
    if e.network_id ~= nil and prev_net ~= nil and tostring(e.network_id) ~= tostring(prev_net) then
        reset_goid_tracking(rec)
    end
    rec.last_damage = dmg
    rec.last_hit_at = M.clock
    rec.updated_at = M.clock
    rec.dead = false
    rec.died_at = nil
    rec.burrowed = false
    rec.invalid_since = nil
    rec.downed = e.downed == true
    rec.local_attacker = e.local_attacker == true
    local epos = extract_event_position(e)
    if epos then
        rec.event_pos = epos
        if not rec.spawn_pos then rec.spawn_pos = epos end
        local freeze_at_emerge = rec.goid_live_moved
            and rec.goid_last_at
            and (M.clock - rec.goid_last_at) <= 0.25
            and rec.spawn_pos
            and (pos_dist(epos, rec.spawn_pos) or 0) <= 1.0
        if not freeze_at_emerge then
            update_record_pos(rec, epos, 'hit')
        end
    end

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
    update_record_pos(rec, extract_event_position(e), 'died')
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
    if type(e) == 'table' and e.epoch == nil and e.mission ~= nil then M.epoch = e.mission end
    M.gui_epoch = nil
end

local function on_mission_ended(e)
    M.in_mission = false
    reset_records('mission_ended', type(e) == 'table' and e.epoch or nil)
    if type(e) == 'table' and e.epoch == nil and e.mission ~= nil then M.epoch = e.mission end
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
            local was_in_m = M.in_mission
            if was_in_m and not in_m then
                M.in_mission = false
                reset_records('mission_inactive', ms.epoch)
            else
                M.in_mission = in_m
            end
            if ms.epoch ~= nil and M.epoch ~= nil and ms.epoch ~= M.epoch then
                -- Do not wipe a Hive Lord that was just spawned on the transition into mission!
                if not was_in_m and in_m and next(M.records) ~= nil then
                    M.epoch = ms.epoch
                else
                    reset_records('mission_epoch_poll', ms.epoch)
                end
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
        for i = 1, MAX_RECTS do
            if M.rects[i] then pcall(Gui.update_rect, M.gui, M.rects[i], zpos, zsize, zcol) end
        end
    elseif M.rects and type(Gui.destroy_rect) == 'function' then
        for i = 1, MAX_RECTS do
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
                for i = 1, MAX_RECTS do if M.rects[i] then pcall(Gui.destroy_rect, M.gui, M.rects[i]) end end
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
            for i = 1, MAX_RECTS do if M.rects[i] then pcall(Gui.update_rect, M.gui, M.rects[i], zpos, zsz, zcol) end end
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
        if (M.rect_creates or 0) >= MAX_RECTS then return end
        local ok, id = pcall(Gui.rect, M.gui, pos, sz, col)
        if ok and id then
            M.rects[slot] = id
            M.rect_creates = (M.rect_creates or 0) + 1
        end
    end

    local pad = math.max(2, math.floor(bh * 0.22 + 0.5))
    local bg_a = math.floor(a * 0.78)
    local tr_a = math.floor(a * 0.85)
    local cr, cg, cb = bar_fill_color(q_ratio / 1000, dead)

    put_rect(1, bx - pad, by - pad, bw + pad * 2, bh + pad * 2, 900, bg_a, 10, 12, 16)
    put_rect(2, bx, by, bw, bh, 901, tr_a, 38, 42, 50)
    put_rect(3, bx, by, bw * (q_trail / 1000), bh, 902, math.floor(a * 0.90), 255, 238, 150)
    put_rect(4, bx, by, bw * (q_ratio / 1000), bh, 903, a, cr, cg, cb)
    M.bar_key = bkey
end

local function dir_label(deg, horiz_dist, use_zh, short_form)
    if horiz_dist and horiz_dist < 3.0 then
        return use_zh and ZH.dir_near or EN.dir_near
    end
    local a = math.abs(deg or 0)
    local key
    if a <= 22 then key = 'dir_f'
    elseif a > 157 then key = 'dir_b'
    elseif deg > 0 then
        if deg <= 67 then key = 'dir_fr'
        elseif deg <= 112 then key = 'dir_r'
        else key = 'dir_br' end
    else
        if deg >= -67 then key = 'dir_fl'
        elseif deg >= -112 then key = 'dir_l'
        else key = 'dir_bl' end
    end
    if use_zh then return ZH[key] end
    if short_form and key == 'dir_f' then return 'FWD' end
    if short_form and key == 'dir_b' then return 'BACK' end
    return EN[key]
end

local function make_preview_record()
    return {
        hp = 112500,
        max = DEFAULT_MAX_HP,
        trail_hp = 127500,
        last_damage = 15000,
        last_hit_at = M.clock,
        preview = true,
        dead = false,
        burrowed = false,
        pos = { x = 71.5, y = 114.5, z = 0 },
        pos_at = M.clock,
        pos_source = 'preview',
    }
end

local function target_for_record(r)
    if not r or not M.spatial then return nil end
    if M.spatial.primary and (M.spatial.primary.rec == r or (r.preview and M.spatial.preview)) then
        return M.spatial.primary
    end
    for _, t in ipairs(M.spatial.targets or {}) do
        if t.rec == r then return t end
    end
    return nil
end

local function compute_target_metrics(rec, ref_pos, fx, fy, is_primary)
    if not rec or not rec.pos or not ref_pos then return nil end
    local dx = rec.pos.x - ref_pos.x
    local dy = rec.pos.y - ref_pos.y
    local dz = (rec.pos.z or 0) - (ref_pos.z or 0)
    local horiz = math.sqrt(dx * dx + dy * dy)
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local fwd_m = dx * fx + dy * fy
    local right_m = dx * fy - dy * fx
    local angle = (horiz >= 0.1) and atan2(right_m, fwd_m) or 0
    local deg = math.floor(angle * (180.0 / math.pi) + 0.5)
    if deg > 180 then deg = deg - 360 elseif deg < -180 then deg = deg + 360 end
    local age = math.max(0, M.clock - (rec.pos_at or M.clock))
    return {
        rec = rec,
        primary = is_primary == true,
        dist = dist,
        horiz = horiz,
        dz = dz,
        fwd = fwd_m,
        right = right_m,
        angle = angle,
        deg = deg,
        age = age,
    }
end

local function sample_spatial_state(preview_rec)
    local want_any = C.locator_radar or C.locator_pointer or C.locator_bar_distance
    if not want_any then
        M.spatial = nil
        return
    end

    if preview_rec and not M.best then
        local fx, fy = 0, 1
        local me_pos = { x = 0, y = 0, z = 0 }
        local prim = compute_target_metrics(preview_rec, me_pos, fx, fy, true)
        M.spatial = {
            preview = true,
            me_pos = me_pos,
            fx = fx,
            fy = fy,
            has_heading = true,
            squad = {
                { right = -48, fwd = 62 },
                { right = 92, fwd = -34 },
            },
            targets = prim and { prim } or {},
            primary = prim,
        }
        return
    end

    if not M.best or not M.in_mission then
        M.spatial = nil
        return
    end

    local D = M.hub_ref
    if not D then
        M.spatial = nil
        return
    end

    local me = (type(D.player) == 'function') and ok_call(D.player) or nil
    local aim = (type(D.aim) == 'function') and ok_call(D.aim) or nil
    local me_pos = read_pos_xyz(type(me) == 'table' and me.position or nil)
    local aim_cam = read_pos_xyz(type(aim) == 'table' and aim.camera or nil)
    local aim_pt = read_pos_xyz(type(aim) == 'table' and aim.camera_point or nil)
    local ref_pos = me_pos or aim_cam
    M.last_player_pos = ref_pos

    local fx, fy, has_heading = nil, nil, false
    local afwd = type(aim) == 'table' and aim.forward or nil
    if type(afwd) == 'table' then
        local ax, ay = tonumber(afwd.x), tonumber(afwd.y)
        if ax and ay and ax == ax and ay == ay then
            local len2 = ax * ax + ay * ay
            if len2 > 1e-6 then
                local inv = 1.0 / math.sqrt(len2)
                fx, fy, has_heading = ax * inv, ay * inv, true
            end
        end
    end
    if not has_heading and aim_cam and aim_pt then
        local ax, ay = aim_pt.x - aim_cam.x, aim_pt.y - aim_cam.y
        local len2 = ax * ax + ay * ay
        if len2 > 1e-6 then
            local inv = 1.0 / math.sqrt(len2)
            fx, fy, has_heading = ax * inv, ay * inv, true
        end
    end
    if has_heading then
        M.last_fx, M.last_fy = fx, fy
    elseif M.last_fx and M.last_fy then
        fx, fy, has_heading = M.last_fx, M.last_fy, true
    else
        fx, fy, has_heading = 0, 1, false
    end

    local squad = {}
    if C.locator_radar and C.locator_squad and ref_pos and type(D.players) == 'function' then
        local plist = ok_call(D.players, false)
        if type(plist) == 'table' then
            for _, p in ipairs(plist) do
                if type(p) == 'table' and p.is_local ~= true and p.alive ~= false then
                    local sp = read_pos_xyz(p.position)
                    if sp then
                        local sdx, sdy = sp.x - ref_pos.x, sp.y - ref_pos.y
                        squad[#squad + 1] = {
                            fwd = sdx * fx + sdy * fy,
                            right = sdx * fy - sdy * fx,
                        }
                        if #squad >= 3 then break end
                    end
                end
            end
        end
    end

    local targets = {}
    if ref_pos then
        local pt = compute_target_metrics(M.best, ref_pos, fx, fy, true)
        if pt then targets[#targets + 1] = pt end
        for _, r in pairs(M.records) do
            if r ~= M.best and not r.dead and r.pos then
                local st = compute_target_metrics(r, ref_pos, fx, fy, false)
                if st then targets[#targets + 1] = st end
                if #targets >= 3 then break end
            end
        end
    end

    M.spatial = {
        preview = false,
        me_pos = ref_pos,
        fx = fx,
        fy = fy,
        has_heading = has_heading,
        squad = squad,
        targets = targets,
        primary = (targets[1] and targets[1].primary) and targets[1] or nil,
    }
end

local function format_hud_lines(r, use_zh)
    local hp = math.max(0, r.hp or 0)
    local max_hp = math.max(1, r.max or DEFAULT_MAX_HP)
    local pct = math.max(0, math.min(100, (hp / max_hp) * 100.0))
    local name = use_zh and ZH.boss_name or EN.boss_name
    local txt = string.format('%s   %s / %s  (%.1f%%)', name, format_int(hp), format_int(max_hp), pct)

    local parts = {}
    if r.preview then
        parts[#parts + 1] = use_zh and ZH.preview_tag or EN.preview_tag
    elseif r.dead then
        parts[#parts + 1] = use_zh and ZH.slain or EN.slain
    elseif r.burrowed then
        parts[#parts + 1] = use_zh and ZH.submerged or EN.submerged
    else
        parts[#parts + 1] = use_zh and ZH.active_tag or EN.active_tag
    end
    if M.live_count > 1 and not r.preview then
        parts[#parts + 1] = string.format('[%d ACTIVE]', M.live_count)
    end
    if C.locator_bar_distance then
        local tm = target_for_record(r)
        if tm and tm.dist then
            local d_int = math.floor(tm.dist + 0.5)
            local dir_s = dir_label(tm.deg, tm.horiz, use_zh, true)
            if use_zh then
                parts[#parts + 1] = string.format('%d m (%s)', d_int, dir_s)
            else
                parts[#parts + 1] = string.format('%dm %s', d_int, dir_s)
            end
        end
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
        if (M.text_creates or 0) >= MAX_TEXTS then return false end
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
    local ok1 = put_line(1, txt, x1, math.floor(title_y + 0.5), sz1, tr, tg, tb, a)
    local ok2 = put_line(2, sub, x2, math.floor(sub_y + 0.5), sz2, 200, 206, 214, math.floor(a * 0.88))
    M.font_mode = 'debug'
    return (ok1 and ok2) and true or false, txt
end

local function locator_gui_api()
    local m = rawget(_G, 'MDL3')
    if type(m) == 'table' and type(m.gui) == 'table' then return m.gui end
    local mdl = rawget(_G, 'MDL')
    if type(mdl) == 'table' and type(mdl.gui) == 'table' then return mdl.gui end
    return nil
end

local function loc_state(text)
    if text ~= M.last_loc_state then
        M.last_loc_state = text
        wf('LOCATOR_STATE %s', text)
    end
end

local function hide_locator_guis()
    if M.loc_visible then
        if M.loc_shape_canvas and type(M.loc_shape_canvas.show) == 'function' then
            pcall(M.loc_shape_canvas.show, M.loc_shape_canvas, false)
        end
        if M.loc_text_canvas and type(M.loc_text_canvas.show) == 'function' then
            pcall(M.loc_text_canvas.show, M.loc_text_canvas, false)
        end
        M.loc_visible = false
        M.loc_text_key = nil
    end
end

local function dispose_locator_guis()
    if M.loc_shape_canvas and type(M.loc_shape_canvas.destroy) == 'function' then
        pcall(M.loc_shape_canvas.destroy, M.loc_shape_canvas)
    end
    if M.loc_text_canvas and type(M.loc_text_canvas.destroy) == 'function' then
        pcall(M.loc_text_canvas.destroy, M.loc_text_canvas)
    end
    M.loc_shape_canvas = nil
    M.loc_text_canvas = nil
    M.loc_gui_ref = nil
    M.loc_visible = false
    M.loc_text_key = nil
end

local function target_urgency_color(r, tm)
    if not r then return 255, 213, 44 end
    if r.preview then return 255, 213, 44 end
    if r.dead then return 215, 85, 80 end
    if r.burrowed then return 240, 165, 55 end
    if tm and tm.dist then
        if tm.dist < 60 or (math.abs(tm.deg or 0) >= 115 and tm.dist < 150) then
            return 255, 76, 56
        elseif tm.dist < 130 then
            return 255, 168, 42
        end
    end
    return 255, 213, 44
end

local function radar_geometry(sw, sh)
    local rsc = clamp(tonumber(C.locator_radar_scale) or DEFAULTS.locator_radar_scale, 0.40, 3.00)
    local R = 68 * rsc
    local off_x = tonumber(C.locator_radar_x) or DEFAULTS.locator_radar_x
    local off_y = tonumber(C.locator_radar_y) or DEFAULTS.locator_radar_y
    local cx = clamp(sw * 0.5 + off_x, R + 20 * rsc, math.max(R + 20 * rsc, sw - R - 20 * rsc))
    local cy = clamp(sh * 0.5 + off_y, R + 28 * rsc, math.max(R + 28 * rsc, sh - R - 52 * rsc))
    local range_m = clamp(tonumber(C.locator_range) or DEFAULTS.locator_range, 50, 1000)
    return cx, cy, R, rsc, range_m
end

local function project_to_radar(right_m, fwd_m, cx, cy, R, rsc, range_m)
    local max_r = math.max(8, R - 7 * rsc)
    local m_to_px = max_r / range_m
    local ox = right_m * m_to_px
    local oy = -fwd_m * m_to_px
    local d2 = ox * ox + oy * oy
    local clamped = false
    if d2 > max_r * max_r then
        local inv = max_r / math.sqrt(d2)
        ox, oy = ox * inv, oy * inv
        clamped = true
    end
    return cx + ox, cy + oy, clamped
end

local function paint_locator_shapes(c, sw, sh, active_r, sp, a)
    local OFF = -2000
    local CLEAR = { 0, 0, 0, 0 }
    local show_radar = C.locator_radar == true
    local show_ptr = C.locator_pointer == true
    local prim = sp and sp.primary or nil

    local cx, cy, R, rsc, range_m = radar_geometry(sw, sh)
    local rim_w = math.max(1, math.floor(2 * rsc + 0.5))
    local ring_w = math.max(1, math.floor(1.8 * rsc + 0.5))
    local tr, tg, tb = target_urgency_color(active_r, prim)

    local function put_circle_disc(x, y, rad, col, segs)
        c:circle(x, y, rad, col, { segments = segs })
    end
    local function put_circle_ring(x, y, rad, col, segs, rthick)
        c:circle(x, y, rad, col, { segments = segs, ring = rthick })
    end
    local function put_line(x1, y1, x2, y2, wpx, col)
        c:line(x1, y1, x2, y2, wpx, col)
    end
    local function put_tri(x1, y1, x2, y2, x3, y3, col)
        c:triangle(x1, y1, x2, y2, x3, y3, col)
    end

    c:begin()

    -- Slots 1-7: Radar backdrop, rings, crosshairs, player FOV cone
    if show_radar then
        put_circle_disc(cx, cy, R, { 10, 13, 18, math.floor(a * 0.72) }, 48)
        put_circle_ring(cx, cy, R, { 220, 188, 92, math.floor(a * 0.86) }, 48, rim_w)
        put_circle_ring(cx, cy, R * 0.5, { 130, 145, 165, math.floor(a * 0.36) }, 36, 1)
        local pad = 4 * rsc
        put_line(cx - R + pad, cy, cx + R - pad, cy, 1, { 120, 135, 155, math.floor(a * 0.28) })
        put_line(cx, cy - R + pad, cx, cy + R - pad, 1, { 120, 135, 155, math.floor(a * 0.28) })
        local fw = math.max(1, 1.2 * rsc)
        put_line(cx, cy, cx - R * 0.46, cy - R * 0.58, fw, { 150, 205, 255, math.floor(a * 0.28) })
        put_line(cx, cy, cx + R * 0.46, cy - R * 0.58, fw, { 150, 205, 255, math.floor(a * 0.28) })
    else
        put_circle_disc(OFF, OFF, 10, CLEAR, 48)
        put_circle_ring(OFF, OFF, 10, CLEAR, 48, rim_w)
        put_circle_ring(OFF, OFF, 10, CLEAR, 36, 1)
        put_line(OFF, OFF, OFF + 10, OFF, 1, CLEAR)
        put_line(OFF, OFF, OFF, OFF + 10, 1, CLEAR)
        put_line(OFF, OFF, OFF + 10, OFF + 10, 1, CLEAR)
        put_line(OFF, OFF, OFF - 10, OFF + 10, 1, CLEAR)
    end

    -- Slots 8-10: North 'N' glyph on radar rim
    if show_radar then
        local fx = (sp and sp.fx) or 0
        local fy = (sp and sp.fy) or 1
        local n_rad = R + 9 * rsc
        local nx = cx - fx * n_rad
        local ny = cy - fy * n_rad
        local nw = 2.4 * rsc
        local nh = 3.6 * rsc
        local nl_w = math.max(1.2, 1.5 * rsc)
        local ncol = { 225, 232, 240, math.floor(a * 0.90) }
        put_line(nx - nw, ny + nh, nx - nw, ny - nh, nl_w, ncol)
        put_line(nx - nw, ny - nh, nx + nw, ny + nh, nl_w, ncol)
        put_line(nx + nw, ny + nh, nx + nw, ny - nh, nl_w, ncol)
    else
        put_line(OFF, OFF, OFF, OFF + 6, 1, CLEAR)
        put_line(OFF, OFF, OFF + 4, OFF + 6, 1, CLEAR)
        put_line(OFF + 4, OFF, OFF + 4, OFF + 6, 1, CLEAR)
    end

    -- Slots 11-13: Up to 3 squadmate dots
    local squad = (show_radar and sp and sp.squad) or {}
    local sq_r = math.max(2.5, 3.2 * rsc)
    for i = 1, 3 do
        local mate = squad[i]
        if show_radar and mate then
            local mx, my = project_to_radar(mate.right, mate.fwd, cx, cy, R, rsc, range_m)
            put_circle_disc(mx, my, sq_r, { 110, 210, 255, math.floor(a * 0.85) }, 12)
        else
            put_circle_disc(OFF, OFF, 4, CLEAR, 12)
        end
    end

    -- Primary target radar coordinates
    local bx, by, clamped = nil, nil, false
    if show_radar and prim then
        bx, by, clamped = project_to_radar(prim.right, prim.fwd, cx, cy, R, rsc, range_m)
    end

    -- Slot 14: Bearing line from center to primary Hive Lord
    if show_radar and bx and by and ((bx - cx) * (bx - cx) + (by - cy) * (by - cy)) > 9 then
        put_line(cx, cy, bx, by, math.max(1, 1.4 * rsc), { tr, tg, tb, math.floor(a * 0.42) })
    else
        put_line(OFF, OFF, OFF + 8, OFF, 1, CLEAR)
    end

    -- Slots 15-16: Secondary Hive Lords (if > 1 live)
    local sec_idx = 0
    local targets = (show_radar and sp and sp.targets) or {}
    for _, t in ipairs(targets) do
        if not t.primary and sec_idx < 2 then
            sec_idx = sec_idx + 1
            local sx2, sy2 = project_to_radar(t.right, t.fwd, cx, cy, R, rsc, range_m)
            put_circle_disc(sx2, sy2, math.max(3.5, 4.4 * rsc), { 235, 155, 55, math.floor(a * 0.85) }, 16)
        end
    end
    while sec_idx < 2 do
        sec_idx = sec_idx + 1
        put_circle_disc(OFF, OFF, 4, CLEAR, 16)
    end

    -- Slots 17-18: Primary Hive Lord outer ring + core dot
    if show_radar and bx and by and prim then
        local fresh = not active_r.burrowed and not active_r.dead and (prim.age or 0) <= 2.5
        local pr = 8.5 * rsc
        local pa = math.floor(a * 0.72)
        if fresh and not active_r.preview then
            local pulse = 0.5 + 0.5 * math.sin(M.clock * 5.0)
            pr = (8.0 + 3.5 * pulse) * rsc
            pa = math.floor(a * (0.45 + 0.42 * (1.0 - pulse)))
        end
        local core_a = active_r.burrowed and math.floor(a * 0.65) or a
        local core_r = math.max(4.0, (active_r.burrowed and 4.2 or 5.2) * rsc)
        put_circle_ring(bx, by, math.max(ring_w + 2, pr), { tr, tg, tb, pa }, 24, ring_w)
        put_circle_disc(bx, by, core_r, { tr, tg, tb, core_a }, 20)
    else
        put_circle_ring(OFF, OFF, math.max(ring_w + 2, 8), CLEAR, 24, ring_w)
        put_circle_disc(OFF, OFF, 5, CLEAR, 20)
    end

    -- Slot 19: Rim overflow arrow when primary target is outside radar range
    if show_radar and clamped and prim then
        local ux = math.sin(prim.angle)
        local uy = -math.cos(prim.angle)
        local px = -uy
        local py = ux
        local tip_x = cx + ux * (R + 3.5 * rsc)
        local tip_y = cy + uy * (R + 3.5 * rsc)
        local base_x = cx + ux * (R - 5.0 * rsc)
        local base_y = cy + uy * (R - 5.0 * rsc)
        local w_wing = 4.5 * rsc
        put_tri(tip_x, tip_y, base_x + px * w_wing, base_y + py * w_wing,
            base_x - px * w_wing, base_y - py * w_wing, { tr, tg, tb, a })
    else
        put_tri(OFF, OFF, OFF + 8, OFF, OFF + 4, OFF + 6, CLEAR)
    end

    -- Slot 20: Local player center chevron pointing UP
    if show_radar then
        put_tri(cx, cy - 6.5 * rsc, cx - 4.5 * rsc, cy + 4.5 * rsc, cx + 4.5 * rsc, cy + 4.5 * rsc,
            { 245, 250, 255, math.floor(a * 0.95) })
    else
        put_tri(OFF, OFF, OFF + 8, OFF, OFF + 4, OFF + 6, CLEAR)
    end

    -- Slots 21-22: Center-screen directional pointer (outline + fill)
    if show_ptr and prim and not active_r.dead then
        local scx, scy = sw * 0.5, sh * 0.5
        local prad = clamp(tonumber(C.locator_pointer_radius) or DEFAULTS.locator_pointer_radius, 40, 500)
        local ux = math.sin(prim.angle)
        local uy = -math.cos(prim.angle)
        local px = -uy
        local py = ux
        local ax = scx + ux * prad
        local ay = scy + uy * prad
        -- Outline backing triangle
        put_tri(
            ax + ux * 16, ay + uy * 16,
            ax - ux * 10 + px * 12, ay - uy * 10 + py * 12,
            ax - ux * 10 - px * 12, ay - uy * 10 - py * 12,
            { 10, 12, 16, math.floor(a * 0.85) }
        )
        -- Bright directional arrow triangle
        local ptr_a = active_r.burrowed and math.floor(a * 0.78) or math.floor(a * 0.96)
        put_tri(
            ax + ux * 13, ay + uy * 13,
            ax - ux * 7 + px * 9.5, ay - uy * 7 + py * 9.5,
            ax - ux * 7 - px * 9.5, ay - uy * 7 - py * 9.5,
            { tr, tg, tb, ptr_a }
        )
    else
        put_tri(OFF, OFF, OFF + 8, OFF, OFF + 4, OFF + 6, CLEAR)
        put_tri(OFF, OFF, OFF + 8, OFF, OFF + 4, OFF + 6, CLEAR)
    end

    c:finish()
end

local function paint_locator_texts(c, sw, sh, active_r, sp, a)
    local show_radar = C.locator_radar == true
    local show_ptr = C.locator_pointer == true
    local prim = sp and sp.primary or nil
    local use_zh = is_chinese_ui()

    local st = (type(c.status) == 'function') and ok_call(c.status, c) or nil
    local font_ok = (type(st) ~= 'table') or (st.font ~= false)

    local cx, cy, R, rsc, range_m = radar_geometry(sw, sh)
    local title_s = use_zh and ZH.loc_radar_title or EN.loc_radar_title
    local line1_s, line2_s = '', ''
    if show_radar then
        if prim and prim.dist then
            local d_int = math.floor(prim.dist + 0.5)
            local dir_s = dir_label(prim.deg, prim.horiz, use_zh, false)
            if prim.horiz and prim.horiz < 3.0 then
                line1_s = string.format(use_zh and '%d m  %s' or '%dm  %s', d_int, dir_s)
            else
                line1_s = string.format(use_zh and '%d m  %s %d\194\176' or '%dm  %s %d\194\176',
                    d_int, dir_s, math.abs(prim.deg or 0))
            end

            local range_part = string.format('%s %dm',
                use_zh and ZH.loc_range_tag or EN.loc_range_tag, math.floor(range_m + 0.5))
            if active_r.preview then
                line2_s = string.format('%s | %s', use_zh and ZH.preview_tag or EN.preview_tag, range_part)
            elseif active_r.dead then
                line2_s = use_zh and ZH.slain or EN.slain
            elseif active_r.burrowed then
                local age_s = math.floor((prim.age or 0) + 0.5)
                line2_s = use_zh
                    and string.format('%s %d%s | %s', ZH.loc_burrow_short, age_s, ZH.loc_sec_ago, range_part)
                    or string.format('SUB %ds ago | %s', age_s, range_part)
            elseif (prim.age or 0) >= 2.5 then
                local age_s = math.floor((prim.age or 0) + 0.5)
                line2_s = use_zh
                    and string.format('%s %d%s | %s', ZH.loc_last_seen, age_s, ZH.loc_sec_ago, range_part)
                    or string.format('%s %ds ago | %s', EN.loc_last_seen, age_s, range_part)
            else
                line2_s = string.format('%s | %s', use_zh and ZH.loc_live or EN.loc_live, range_part)
            end
        else
            line1_s = use_zh and ZH.loc_waiting or EN.loc_waiting
            line2_s = string.format('%s %dm',
                use_zh and ZH.loc_range_tag or EN.loc_range_tag, math.floor(range_m + 0.5))
        end
    end

    local ptr_label, tx, ty = nil, 0, 0
    if show_ptr and prim and not active_r.dead and prim.dist then
        local prad = clamp(tonumber(C.locator_pointer_radius) or DEFAULTS.locator_pointer_radius, 40, 500)
        local ux = math.sin(prim.angle)
        local uy = -math.cos(prim.angle)
        tx = clamp(sw * 0.5 + ux * (prad + 28), 44, math.max(44, sw - 44))
        ty = clamp(sh * 0.5 + uy * (prad + 28), 20, math.max(20, sh - 20))
        local d_int = math.floor(prim.dist + 0.5)
        if active_r.burrowed then
            ptr_label = string.format('%dm %s', d_int, use_zh and ZH.loc_burrow_short or EN.loc_burrow_short)
        elseif (prim.age or 0) >= 3.0 then
            ptr_label = string.format('%dm %ds', d_int, math.floor(prim.age + 0.5))
        else
            ptr_label = string.format('%dm', d_int)
        end
    end

    local qtx = math.floor(tx / 4 + 0.5)
    local qty = math.floor(ty / 4 + 0.5)
    local tkey = string.format('%s|%s|%s|%s|%d|%d|%d|%d|%d|%d|%s|%s',
        title_s, line1_s, line2_s, tostring(ptr_label or ''),
        math.floor(cx), math.floor(cy), math.floor(R), qtx, qty, a,
        tostring(font_ok), tostring(show_radar))

    if M.loc_text_key == nil then M.loc_text_has_pos = false end
    local force = (M.loc_text_key == nil) or (prim ~= nil and not M.loc_text_has_pos)
    if tkey == M.loc_text_key then return end
    if not force and (M.clock - (M.loc_text_last_at or -100)) < 0.10 then return end

    c:begin()
    if font_ok then
        local tr, tg, tb = target_urgency_color(active_r, prim)
        if show_radar then
            local sz_title = math.max(10, math.floor(14 * rsc + 0.5))
            local sz_l1 = math.max(12, math.floor(17 * rsc + 0.5))
            local sz_l2 = math.max(10, math.floor(12 * rsc + 0.5))
            c:text(title_s, cx, cy - R - 13 * rsc, {
                size = sz_title,
                color = { 255, 224, 130, a },
                align = 'center',
                valign = 'middle',
            })
            c:text(line1_s, cx, cy + R + 16 * rsc, {
                size = sz_l1,
                color = { tr, tg, tb, a },
                align = 'center',
                valign = 'middle',
            })
            c:text(line2_s, cx, cy + R + 35 * rsc, {
                size = sz_l2,
                color = { 200, 210, 222, math.floor(a * 0.88) },
                align = 'center',
                valign = 'middle',
            })
        end
        if ptr_label then
            local mw = (type(c.measure) == 'function') and ok_call(c.measure, c, ptr_label, 14) or nil
            local pw = math.max(44, (type(mw) == 'number' and mw > 0 and mw or (#ptr_label * 8)) + 14)
            local ph = 20
            c:rect(tx - pw * 0.5, ty - ph * 0.5, pw, ph, { 10, 12, 16, math.floor(a * 0.78) })
            c:text(ptr_label, tx, ty, {
                size = 14,
                color = { tr, tg, tb, a },
                align = 'center',
                valign = 'middle',
            })
        end
    end
    c:finish()

    M.loc_text_key = tkey
    M.loc_text_last_at = M.clock
    M.loc_text_has_pos = (prim ~= nil)
end

local function locator_tick(active_r)
    if not (C.locator_radar or C.locator_pointer) then
        hide_locator_guis()
        return loc_state('off (disabled in settings)')
    end
    if not active_r then
        hide_locator_guis()
        return loc_state('idle')
    end

    local gui = locator_gui_api()
    if not gui or (tonumber(gui.api) or 0) < 1 or type(gui.canvas) ~= 'function' then
        if M.loc_shape_canvas or M.loc_text_canvas then dispose_locator_guis() end
        return loc_state('unavailable (requires MDL3.gui api>=1)')
    end

    if gui ~= M.loc_gui_ref then
        dispose_locator_guis()
        M.loc_gui_ref = gui
    end

    if not M.loc_shape_canvas then
        local ok_s, cs = pcall(gui.canvas, { layer = 62, units = 'reference' })
        local ok_t, ct = pcall(gui.canvas, { layer = 64, units = 'reference' })
        if not (ok_s and cs and ok_t and ct) then
            if cs and type(cs.destroy) == 'function' then pcall(cs.destroy, cs) end
            if ct and type(ct.destroy) == 'function' then pcall(ct.destroy, ct) end
            if not M.loc_warned_err then
                M.loc_warned_err = true
                wf('LOCATOR_CANVAS_ERR shape=%s text=%s', tostring(cs), tostring(ct))
            end
            return loc_state('canvas create failed')
        end
        M.loc_shape_canvas = cs
        M.loc_text_canvas = ct
        M.loc_visible = true
        M.loc_text_key = nil
    elseif not M.loc_visible then
        if type(M.loc_shape_canvas.show) == 'function' then
            pcall(M.loc_shape_canvas.show, M.loc_shape_canvas, true)
        end
        if type(M.loc_text_canvas.show) == 'function' then
            pcall(M.loc_text_canvas.show, M.loc_text_canvas, true)
        end
        M.loc_visible = true
        M.loc_text_key = nil
    end

    local s = ok_call(M.loc_shape_canvas.screen, M.loc_shape_canvas)
    local sw = type(s) == 'table' and tonumber(s.w) or nil
    local sh = type(s) == 'table' and tonumber(s.h) or nil
    if not (sw and sh and sw > 0 and sh > 0) then
        return loc_state('no screen dims')
    end

    local a = clamp(math.floor(C.hud_alpha * 255 + 0.5), 0, 255)
    local ok1, err1 = pcall(paint_locator_shapes, M.loc_shape_canvas, sw, sh, active_r, M.spatial, a)
    local ok2, err2 = pcall(paint_locator_texts, M.loc_text_canvas, sw, sh, active_r, M.spatial, a)
    if not (ok1 and ok2) then
        if not M.loc_warned_err then
            M.loc_warned_err = true
            wf('LOCATOR_DRAW_ERR shape=%s text=%s', tostring(err1), tostring(err2))
        end
        return loc_state('draw error')
    end

    local prim = M.spatial and M.spatial.primary
    if prim and prim.dist then
        return loc_state(string.format('active dist=%.1fm deg=%d', prim.dist, prim.deg or 0))
    end
    return loc_state('active waiting_pos')
end

local function hud_tick(preview_rec)
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

    local r = M.best or preview_rec

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
    local has_dist = (C.locator_bar_distance and target_for_record(r) ~= nil) == true
    local core_key = string.format('%s|%s|%s|%d|%d|%d|%d|%s|%s|%s',
        sig_txt, tostring(r.burrowed), tostring(r.last_damage or 0),
        math.floor(w_px), math.floor(h_px),
        math.floor(center_x), math.floor(by), a, want_mode, tostring(C.hud_bar))
    local dkey = core_key .. '\n' .. sig_sub

    if dkey ~= M.draw_key then
        -- Throttle native text GUI rebuilds: 20 Hz for HP/damage ticks, 5 Hz when only distance changes
        -- (except when distance first becomes available or state/preview changes).
        if want_mode == 'native' and M.text_gui ~= nil and not r.dead and not r.preview then
            local dist_appeared = has_dist and not M.last_bar_has_dist
            if not dist_appeared then
                local min_gap = (core_key == M.last_bar_core_key) and 0.20 or 0.05
                if (M.clock - M.text_last_rebuild) < min_gap then
                    return
                end
            end
        end
        local title_y = by + bh + 6 * sc
        local sub_y = by - 19 * sc
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
        M.last_bar_core_key = core_key
        M.last_bar_has_dist = has_dist
        hud_state(string.format('painted=%s font=%s text="%s"',
            tostring(ok), tostring(M.font_mode), tostring(shown_txt)))
    end
end

-- ------------------------------------------------------------------- lifecycle
local function step(dt)
    if not M.active then return end
    local d = (type(dt) == 'number' and dt == dt) and math.max(0, math.min(1, dt)) or 0.016
    M.clock = M.clock + d
    local cur_mom = find_options_api()
    if cur_mom and (not M.options_bound or M.mom_ref ~= cur_mom) then
        M.options_bound = false
        bind_mod_options()
    end
    if M.options_bound and not M.mom_post_boot_synced then
        local mdl = rawget(_G, 'MDL3')
        local ui = type(mdl) == 'table' and mdl.ui or nil
        if (type(ui) == 'table' and ui.state == 'ready') or M.clock >= 2.0 then
            sync_mom_from_config(M.mom_ref)
            M.mom_post_boot_synced = true
        end
    end
    local settings_open = mdl_settings_open()
    if settings_open and not M.was_settings_open then
        sync_mom_from_config(M.mom_ref)
    elseif not settings_open then
        if M.was_settings_open and M.cfg_dirty then
            write_config_now('menu_close')
        end
        if M.live_menu_preview then
            M.live_menu_preview = false
        end
    end
    M.was_settings_open = settings_open
    if M.cfg_dirty and M.clock >= (M.cfg_save_due_at or 0) then
        write_config_now('debounced')
    end
    hub_tick()
    prune_and_select(d)
    poll_live_positions()
    local preview_rec = (not M.best and (C.hud_preview or M.live_menu_preview)) and make_preview_record() or nil
    sample_spatial_state(preview_rec)
    hud_tick(preview_rec)
    locator_tick(M.best or preview_rec)
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
        if M.cfg_dirty then write_config_now('shutdown') end
        unsubscribe_all()
        dispose_locator_guis()
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
    name = is_chinese_ui() and ZH.mod_title or EN.mod_title,
    version = VERSION,
    author = 'hivelord',
    description = is_chinese_ui() and ZH.mod_desc or EN.mod_desc,
}
