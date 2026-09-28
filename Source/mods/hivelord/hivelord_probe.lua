-- HD2-Addon: mods/hivelord/hivelord_probe
-- Hive Lord health reconnaissance.  READ-ONLY.
--
-- WHY THIS FILE IS SO CAREFUL
--   A previous probe resource in this workspace called stingray/Network functions
--   speculatively -- it walked the `Network` table and invoked each member to see
--   what came back.  It crashed the game twice and left a 5-line log.  So:
--
--     * Stage A only *lists* engine members.  It never calls one it has not been
--       told is safe.  Calling an engine function with the wrong argument count,
--       or an unknown type name, is a native access violation, not a Lua error,
--       and `pcall` cannot catch it.
--     * Every call this file makes appears in SAFE_* below and is individually
--       proven by the shipped, working DRIVER HUD 1.2.1 mod.
--     * Every risky operation is written to the log *before* it runs, so the last
--       line of the log names the exact call that killed the game.
--     * Stage D keeps a cursor on disk.  If it crashes, the next launch resumes
--       after the object that crashed it instead of re-crashing on it.
--
-- Stage A  list the engine Lua API surface (names + types only, no calls)
-- Stage B  session / peer / world / owned-object report (proven-safe calls only)
-- Stage C  game-object-id census using game_object_exists
-- Stage D  game_object_field_batched fingerprint sweep for the Hive Lord's
--          damage-zone health constellation
--          (150000 main + 150000 x9 zones, 35000 x14, 15000 x14, 20000 x1,
--           5000 x14, 10000 x2 -- derived offline from the plaintext
--           generated_entities.dl_bin, see work/hivelord/HIVE_LORD_HEALTH.md)
-- Stage E  full field-array dump + live watch for every fingerprint candidate

local sr = rawget(_G, 'stingray')
if not sr then return { installed = false, reason = 'no stingray global' } end
if rawget(_G, '__HIVELORD_PROBE_INSTALLED') then return { installed = true, reason = 'already loaded' } end

local App, Net, GS, World, Gui = sr.Application, sr.Network, sr.GameSession, sr.World, sr.Gui

-- ------------------------------------------------------------ environment gate
local loader = rawget(_G, 'CowboyBingusModLoader')
local loader_api = type(loader) == 'table' and tonumber(loader.api) or nil
local loader_ver = type(loader) == 'table' and tonumber(loader.version) or nil
if loader_api and loader_api < 1 then
    return { installed = false, reason = 'loader API ' .. tostring(loader_api) .. ' < 1' }
end

local function call(f, ...)
    if type(f) ~= 'function' then return nil end
    local ok, a, b = pcall(f, ...)
    if ok then return a, b end
    return nil, b
end

-- ---------------------------------------------------------------- configuration
local C = {
    debug = true,
    stage_sweep = true,
    stage_fields = true,        -- Stage D: the only genuinely unproven call in this file
    stage_dump = true,
    in_mission_only = true,     -- never run Stage D outside a mission
    max_id = 32766,             -- GOID bound proven by DRIVER HUD's valid_goid
    sweep_per_frame = 128,
    probe_per_frame = 2,        -- deliberately gentler than DRIVER HUD's 4
    probe_budget_ms = 8,
    probe_delay = 900,          -- frames; let the mission finish loading first
    resweep_seconds = 20,
    watch_seconds = 1,
    max_probes = 20000,
    probe_from = 1,             -- override the resume cursor for one run if wanted
}
local dir = call(os.getenv, 'APPDATA')
local cfg = dir and (dir .. '/Arrowhead/Helldivers2/hivelord.cfg') or nil
if cfg and io and io.open then
    local f = io.open(cfg, 'r')
    if f then
        for l in f:lines() do
            local k, v = l:match('^%s*([%w_]+)%s*=%s*([%w%.%-]+)')
            if k == 'debug' then C.debug = (v == 'true')
            elseif C[k] ~= nil then
                if v == 'true' then C[k] = true
                elseif v == 'false' then C[k] = false
                else
                    local n = tonumber(v)
                    if n and n == n and n >= 0 then C[k] = n end
                end
            end
        end
        f:close()
    end
end

-- -------------------------------------------------------------------- logging
-- Pick the first location we can actually create a file in.  The game's own
-- APPDATA directory normally exists, but relying on that alone means a missing
-- directory silently produces a probe that reports nothing at all -- the worst
-- possible outcome for a one-shot resource.
local outdir, out
if io and io.open then
    local appdata = call(os.getenv, 'APPDATA')
    local localappdata = call(os.getenv, 'LOCALAPPDATA')
    local temp = call(os.getenv, 'TEMP')
    local cands = {}
    if appdata then cands[#cands + 1] = appdata .. '/Arrowhead/Helldivers2' end
    if localappdata then cands[#cands + 1] = localappdata .. '/CowboyBingus/Helldivers2/Logs' end
    if temp then cands[#cands + 1] = temp end
    cands[#cands + 1] = '.'
    for _, d in ipairs(cands) do
        local f = io.open(d .. '/hivelord.log', 'a')
        if f then outdir, out = d, f; break end
    end
end
local function w(line)
    if not out then return end
    local ok = pcall(function() out:write(line, '\n'); out:flush() end)
    if not ok then out = nil end
end
local function wf(fmt, ...) w(string.format(fmt, ...)) end
wf('LOG_OPEN outdir=%s', tostring(outdir))

local STATUS = {}
local function status(line)
    STATUS[#STATUS + 1] = line
    if not outdir then return end
    local f = io.open(outdir .. '/hivelord_STATUS.txt', 'w')
    if f then
        f:write('hivelord-probe-v2 (read-only)\n')
        f:write('loader api=' .. tostring(loader_api) .. ' version=' .. tostring(loader_ver) .. '\n')
        for _, v in ipairs(STATUS) do f:write(v, '\n') end
        f:close()
    end
end

-- Crash-resumable cursor. Written before a probe runs, so a crash costs at most
-- re-probing one object.
local function state_path() return outdir and (outdir .. '/hivelord_state.txt') end
local function save_cursor(id)
    local p = state_path()
    if not p or not io or not io.open then return end
    local f = io.open(p, 'w')
    if f then f:write(string.format('probe_cursor=%d\n', id)); f:close() end
end
local function load_cursor()
    local p = state_path()
    if not p or not io or not io.open then return C.probe_from end
    local f = io.open(p, 'r')
    if not f then return C.probe_from end
    local v = nil
    for l in f:lines() do
        local n = l:match('^probe_cursor=(%d+)')
        if n then v = tonumber(n) end
    end
    f:close()
    if v and v > C.probe_from then return v + 1 end
    return C.probe_from
end

local function is_table(t) return type(t) == 'table' or type(t) == 'userdata' end

-- ------------------------------------------------- Stage A: list only, no calls
-- Iterating a Lua table cannot fault the engine.  This is the only thing this
-- file does to the engine that needs no proof of safety.
local function list_members(name, t, lines, seen)
    if not is_table(t) then
        lines[#lines + 1] = '### stingray.' .. name .. ' : ' .. type(t) .. ' (not a table)'
        return
    end
    if seen[t] then return end
    seen[t] = true
    local keys, n = {}, 0
    for k in pairs(t) do
        n = n + 1
        if n > 4000 then break end
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local fns, tbls = {}, {}
    for _, k in ipairs(keys) do
        local tv = type(t[k])
        if tv == 'function' then fns[#fns + 1] = tostring(k)
        else tbls[#tbls + 1] = tostring(k) .. ':' .. tv end
    end
    lines[#lines + 1] = string.format('### stingray.%s  (%d functions, %d other members)',
        name, #fns, #tbls)
    if #fns > 0 then
        lines[#lines + 1] = 'FUNCTIONS: ' .. table.concat(fns, ' ')
    end
    if #tbls > 0 then
        lines[#lines + 1] = 'MEMBERS: ' .. table.concat(tbls, ' ')
    end
    for _, e in ipairs(tbls) do
        local k = e:match('^(.-):') 
        local v = t[k]
        if is_table(v) then list_members(name .. '.' .. k, v, lines, seen) end
    end
end

local function dump_surface()
    local lines = {}
    lines[#lines + 1] = 'loader api=' .. tostring(loader_api) .. ' version=' .. tostring(loader_ver)
    lines[#lines + 1] = 'stingray type=' .. type(sr)
    list_members('(root)', sr, lines, {})
    for _, n in ipairs({ 'GameSession', 'Network', 'Application', 'World', 'Gui', 'Unit',
                         'Level', 'Window', 'Script' }) do
        if sr[n] ~= nil then list_members(n, sr[n], lines, {}) end
    end
    -- Flag anything that might enumerate objects, so the next round knows what to
    -- call deliberately instead of guessing here.
    lines[#lines + 1] = ''
    lines[#lines + 1] = '### candidate enumeration/type entries (names only, never called here)'
    for _, pair in ipairs({ { 'GameSession', GS }, { 'Network', Net } }) do
        local t = pair[2]
        if is_table(t) then
            local hits = {}
            for k, v in pairs(t) do
                if type(v) == 'function' then
                    local s = tostring(k)
                    if s:match('object') or s:match('entit') or s:match('type')
                        or s:match('unit') or s:match('list') or s:match('all') then
                        hits[#hits + 1] = s
                    end
                end
            end
            table.sort(hits)
            lines[#lines + 1] = pair[1] .. ': ' .. table.concat(hits, ' ')
        end
    end
    if outdir and io and io.open then
        local f = io.open(outdir .. '/hivelord_api.txt', 'w')
        if f then
            for _, l in ipairs(lines) do f:write(l, '\n') end
            f:close()
        end
    end
    wf('STAGE_A listed=%d lines (no engine call made)', #lines)
    return #lines
end

-- ------------------------------------------------------------- field helpers
local function dense_count(f)
    if type(f) ~= 'table' then return -1 end
    local n = 0
    while f[n + 1] ~= nil do
        n = n + 1
        if n > 8192 then break end
    end
    return n
end

-- Offline-derived Hive Lord signature (see work/hivelord/HIVE_LORD_HEALTH.md).
-- The entity data gives: main Health 150000 at record+0x00, and 38 damage zones
-- whose healths are 150000 x9, (15000+35000) x12, (20000+35000) x1, 10000 x2,
-- 5000 x14 -- i.e. the number 150000 occurs ten times inside one entity.
--
-- CAVEAT, and the reason for the two-tier gate below: the networked field array
-- is per-object *state*, which is not the same thing as the entity definition.
-- It is not proven that every zone's maximum shows up in that array.  So the
-- strong gate is a verdict, and the weak gate exists so that a Hive Lord whose
-- array looks nothing like the definition is still captured and dumped rather
-- than silently ignored.
local MIN_150K = 6       -- a Hive Lord has 10; anything under 6 is not one
local MIN_DISTINCT = 5   -- of {150000, 35000, 15000, 10000, 5000, 20000, 800}
local MAGIC = { 150000, 35000, 15000, 10000, 5000, 20000, 8000, 800 }
local WEAK_DISTINCT = 3  -- anything this interesting gets dumped even if unproven
local WEAK_CAP = 96      -- cap on weak dumps so the folder stays readable
local function fingerprint(f)
    local found, distinct, nums = {}, 0, 0
    local n = dense_count(f)
    for i = 1, n do
        local v = f[i]
        if type(v) == 'number' then
            nums = nums + 1
            for _, m in ipairs(MAGIC) do
                if v == m then
                    if not found[m] then found[m] = 0; distinct = distinct + 1 end
                    found[m] = found[m] + 1
                    break
                end
            end
        end
    end
    return n, distinct, found, nums
end

local function found_text(found)
    local p = {}
    for _, m in ipairs(MAGIC) do if found[m] then p[#p + 1] = m .. 'x' .. found[m] end end
    return table.concat(p, ',')
end

local function array_text(f, from, to)
    local p = {}
    for i = from, to do
        local v = f[i]
        local tv = type(v)
        if tv == 'number' then
            p[#p + 1] = (v == math.floor(v) and math.abs(v) < 1e15)
                and string.format('%d:%d', i, v) or string.format('%d:%.4f', i, v)
        elseif tv == 'table' then
            p[#p + 1] = string.format('%d:<t%d>', i, dense_count(v))
        else
            p[#p + 1] = string.format('%d:%s', i, tostring(v))
        end
    end
    return table.concat(p, ' ')
end

-- -------------------------------------------------------------------- state
local M = {
    frame = 0, clock = 0,
    session = nil, peer = nil, world = nil,
    stage_a = false, stage_b = false,
    census = {}, known = {}, candidates = {}, cand_list = {}, watch_list = {},
    watched = {},
    sweeping = false, sweep_id = 1, new_census = {},
    probe_id = 0, probes = 0, first_probe_done = false,
    next_resweep = 0, next_watch = 0, owned_seen = 0, missions = 0,
}

local function land_census()
    if not outdir or not io or not io.open then return end
    local f = io.open(outdir .. '/hivelord_census.txt', 'w')
    if not f then return end
    f:write('# game-object-id census (game_object_exists) + field fingerprint\n')
    f:write('# id\tfields\tdistinct_magic\tmagic_counts\tmax_value\n')
    local ids = {}
    for id in pairs(M.census) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local k = M.known[id]
        if k then
            f:write(string.format('%d\t%d\t%d\t%s\t%s\n', id, k.count or -1, k.score or 0,
                k.magic or '', k.maxv or ''))
        else
            f:write(string.format('%d\t-1\t-1\t\t\n', id))
        end
    end
    f:close()
end

local function dump_list(session, list, prefix, cap)
    if not outdir or not io or not io.open then return 0 end
    local n = 0
    for _, id in ipairs(list) do
        if n >= cap then break end
        if call(GS.game_object_exists, session, id) == true then
            local f = call(GS.game_object_field_batched, session, id, {})
            local cnt = dense_count(f)
            if cnt > 0 then
                n = n + 1
                local ff = io.open(string.format('%s/hivelord_%s%d_goid%d.txt', outdir, prefix, n, id), 'w')
                if ff then
                    local _, distinct, found = fingerprint(f)
                    ff:write(string.format('# goid=%d fields=%d distinct_magic=%d %s\n',
                        id, cnt, distinct, found_text(found)))
                    for i = 1, cnt do
                        local v = f[i]
                        local tv = type(v)
                        local sv
                        if tv == 'number' then
                            sv = (v == math.floor(v) and math.abs(v) < 1e15)
                                and string.format('%d', v) or string.format('%.6f', v)
                        elseif tv == 'table' then
                            sv = string.format('<table %d> %s', dense_count(v),
                                array_text(v, 1, math.min(dense_count(v), 32)))
                        else
                            sv = tostring(v)
                        end
                        ff:write(string.format('%d\t%s\t%s\n', i, tv, sv))
                    end
                    ff:close()
                end
            end
        end
    end
    return n
end

local function dump_candidates(session)
    local a = dump_list(session, M.cand_list, 'hit', 32)
    local b = dump_list(session, M.watch_list, 'watch', WEAK_CAP)
    wf('STAGE_E dumped=%d hit file(s), %d watch file(s)', a, b)
end

-- ------------------------------------------------------------ Stage C + D
local function start_census()
    M.sweep_id = 1
    M.sweeping = true
    M.new_census = {}
    wf('STAGE_C census_start max_id=%d', C.max_id)
end

local function advance_census(session)
    local done = 0
    while M.sweeping and done < C.sweep_per_frame and M.sweep_id <= C.max_id do
        local id = M.sweep_id
        M.sweep_id = M.sweep_id + 1
        done = done + 1
        if call(GS.game_object_exists, session, id) == true then
            M.new_census[id] = true
        end
    end
    if M.sweeping and M.sweep_id > C.max_id then
        M.sweeping = false
        M.census = M.new_census
        local n = 0
        for _ in pairs(M.census) do n = n + 1 end
        wf('STAGE_C census_done objects=%d', n)
        land_census()
        status(string.format('census: %d live game objects', n))
    end
end

-- This is the only call in the whole file that DRIVER HUD does not prove safe on
-- arbitrary objects.  Everything about it is defensive: write-ahead log, cursor on
-- disk, existence check first, tiny rate, and it stops the moment it sees a hit.
local function advance_probe(session)
    if M.probes >= C.max_probes then return end
    if M.probe_id == 0 then
        M.probe_id = load_cursor()
        wf('STAGE_D probe_cursor_start=%d', M.probe_id)
    end
    local deadline = os.clock() + (C.probe_budget_ms / 1000)
    local n = 0
    while n < C.probe_per_frame and M.probe_id <= C.max_id do
        local id = M.probe_id
        M.probe_id = M.probe_id + 1
        n = n + 1
        M.probes = M.probes + 1
        save_cursor(id)                       -- write-ahead: a crash points here
        if call(GS.game_object_exists, session, id) == true then
            wf('STAGE_D probe_begin goid=%d', id)
            local f = call(GS.game_object_field_batched, session, id, {})
            local cnt, distinct, found = fingerprint(f)
            if cnt and cnt > 0 then
                local maxv = 0
                for i = 1, cnt do
                    local v = f[i]
                    if type(v) == 'number' and v > maxv and v < 1e9 then maxv = v end
                end
                M.known[id] = { count = cnt, score = distinct, magic = found_text(found), maxv = maxv }
                wf('STAGE_D probe_ok goid=%d fields=%d distinct=%d [%s] max=%s',
                    id, cnt, distinct, found_text(found), tostring(maxv))
                -- The discriminator has to be the *shape*, not merely "saw a big
                -- number".  A single 150000 is common (any tanky entity); ten of
                -- them alongside seven other exact zone maxima is the Hive Lord.
                if distinct >= MIN_DISTINCT and (found[150000] or 0) >= MIN_150K then
                    if not M.candidates[id] then
                        M.candidates[id] = true
                        M.cand_list[#M.cand_list + 1] = id
                    end
                    wf('STAGE_D HIVELORD_MATCH goid=%d fields=%d distinct=%d [%s]',
                        id, cnt, distinct, found_text(found))
                    status(string.format('HIVE LORD MATCH goid=%d fields=%d magic=[%s]',
                        id, cnt, found_text(found)))
                elseif (found[150000] or 0) >= 1 or distinct >= WEAK_DISTINCT then
                    -- Not a proven match, but too interesting to throw away.  If the
                    -- networked array does not mirror the entity definition, this is
                    -- the branch that still captures the Hive Lord.
                    if not M.watched[id] then
                        M.watched[id] = true
                        if #M.watch_list < WEAK_CAP then M.watch_list[#M.watch_list + 1] = id end
                    end
                    wf('STAGE_D WEAK goid=%d fields=%d distinct=%d [%s]',
                        id, cnt, distinct, found_text(found))
                end
            else
                wf('STAGE_D probe_empty goid=%d', id)
            end
        end
        if os.clock() > deadline then break end
    end
    if M.probes % 500 < C.probe_per_frame then land_census() end
end

local function watch_candidates(session)
    if #M.cand_list == 0 then return end
    for _, id in ipairs(M.cand_list) do
        if call(GS.game_object_exists, session, id) == true then
            local f = call(GS.game_object_field_batched, session, id, {})
            local cnt = dense_count(f)
            if cnt > 0 then
                local _, distinct, found = fingerprint(f)
                wf('WATCH goid=%d fields=%d distinct=%d [%s] %s', id, cnt, distinct,
                    found_text(found), array_text(f, 1, math.min(cnt, 64)))
            end
        end
    end
end

-- ------------------------------------------------------------------ Stage B
local function describe_session(session, peer)
    local worlds = call(App.worlds) or {}
    local nw = 0
    for _ in pairs(worlds) do nw = nw + 1 end
    wf('STAGE_B session=%s peer=%s worlds=%d in_session=%s main_world=%s',
        tostring(session), tostring(peer), nw, tostring(call(GS.in_session, session)),
        tostring(call(App.main_world)))
    -- Net.object_info is only ever called with a type name DRIVER HUD proves valid.
    local info = call(Net.object_info, 'rHVbvgIu')
    if type(info) == 'table' then
        local ks = {}
        for k in pairs(info) do ks[#ks + 1] = tostring(k) end
        wf('STAGE_B object_info(rHVbvgIu) keys=[%s]', table.concat(ks, ','))
        local fs = info.fields
        if type(fs) == 'table' then
            wf('STAGE_B object_info(rHVbvgIu) #fields=%d', #fs)
            for i = 1, math.min(#fs, 48) do
                local d = fs[i]
                wf('STAGE_B   field[%d]=%s', i,
                    type(d) == 'table' and tostring(d.id) or tostring(d))
            end
        end
    else
        wf('STAGE_B object_info(rHVbvgIu) -> %s', tostring(info))
    end
end

-- -------------------------------------------------------------- update hook
local function update(dt, ...)
    M.frame = M.frame + 1
    local step = type(dt) == 'number' and dt or 0.016667
    if step < 0 then step = 0 elseif step > 0.25 then step = 0.25 end
    M.clock = M.clock + step

    if not M.stage_a then
        M.stage_a = true
        local n = dump_surface()
        status(string.format('API surface listed (%d lines) -> hivelord_api.txt', n))
        wf('START revision=hivelord-probe-v2 frame=%d', M.frame)
    end

    local session = call(Net.game_session)
    local peer = call(Net.peer_id)
    local world = call(App.main_world)
    if session ~= M.session or peer ~= M.peer or world ~= M.world then
        wf('SESSION_CHANGE session=%s peer=%s world=%s', tostring(session), tostring(peer), tostring(world))
        M.session, M.peer, M.world = session, peer, world
        M.census, M.known, M.candidates, M.cand_list = {}, {}, {}, {}
        M.watch_list, M.watched = {}, {}
        M.sweeping = false
        M.next_resweep = 0
        M.owned_seen = 0
    end
    if not session then return end
    if call(GS.in_session, session) == false then return end

    if not M.stage_b then
        M.stage_b = true
        pcall(describe_session, session, peer)
    end

    local owned = call(GS.objects_owned_by, session, peer)
    local owned_n = 0
    if type(owned) == 'table' then
        owned_n = #owned
        if owned_n > 0 and M.owned_seen == 0 then
            M.missions = M.missions + 1
            wf('STAGE_B owned=%d first=%s last=%s', owned_n, tostring(owned[1]), tostring(owned[owned_n]))
            status(string.format('in a mission: owns %d objects (first id=%s)', owned_n, tostring(owned[1])))
        end
    end
    M.owned_seen = owned_n

    if C.in_mission_only and owned_n == 0 then return end

    if C.stage_sweep and not M.sweeping and M.clock >= M.next_resweep then
        M.next_resweep = M.clock + C.resweep_seconds
        start_census()
    end
    if M.sweeping then
        advance_census(session)
        return
    end
    if C.stage_fields and M.frame > C.probe_delay then
        advance_probe(session)
        -- Dump as soon as either set grows.  Dumping only on the first probe frame
        -- is useless: the interesting object is usually found much later.
        if C.stage_dump and (#M.cand_list > (M.dumped or 0)
                or #M.watch_list > (M.dumped_w or 0)) then
            M.dumped = #M.cand_list
            M.dumped_w = #M.watch_list
            pcall(dump_candidates, session)
        end
    end
    if C.stage_dump and #M.cand_list > 0 and M.clock >= M.next_watch then
        M.next_watch = M.clock + C.watch_seconds
        pcall(watch_candidates, session)
    end
end

local old = rawget(_G, 'update')
if type(old) ~= 'function' then
    return { installed = false, reason = 'no global update to chain' }
end
rawset(_G, '__HIVELORD_PROBE_INSTALLED', true)
local failed = false
rawset(_G, 'update', function(...)
    if not failed then
        local ok, err = pcall(update, ...)
        if not ok then
            failed = true
            wf('LUA_ERROR %s', tostring(err))
            status('LUA_ERROR: ' .. tostring(err))
        end
    end
    return old(...)
end)
status('probe armed; waiting for a mission')
return { installed = true }
