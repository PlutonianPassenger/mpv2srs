-- miner.lua — word picker + capture: JPG screenshot (no subs), audio from selected track, TSV with basenames
-- Keys: F9 to open picker, ←/→ to choose word, Enter to capture
-- Requires: ffmpeg in PATH (set FFMPEG below if needed)

local utils = require 'mp.utils'

-- ====== CONFIG ======


-- ---- Cross-platform mkdir and ffmpeg path ----------------------------------

local is_windows = package.config:sub(1,1) == "\\"

-- Escape a path for the shell we’re calling
local function quote_for_shell(path)
    if is_windows then
        -- PowerShell: wrap in "..." and double inner quotes
        return '"' .. tostring(path):gsub('"','""') .. '"'
    else
        -- POSIX: single-quote, escape existing single quotes safely
        return "'" .. tostring(path):gsub("'", [['"'"']]) .. "'"
    end
end

local function mkdir_p(dir)
    local q = quote_for_shell(dir)

    if is_windows then
        -- Use PowerShell (ships with Windows 10+ by default)
        local res = mp.command_native({
            name = "subprocess",
            args = {"powershell", "-NoProfile", "-Command",
                    "New-Item -ItemType Directory -Force -Path " .. q},
            playback_only = false
        })
        if res and res.status == 0 then return end
    else
        -- POSIX path
        local res = mp.command_native({
            name = "subprocess",
            args = {"bash", "-lc", "mkdir -p -- " .. q},
            playback_only = false
        })
        if res and res.status == 0 then return end
    end

    -- Last-ditch: try python3 then python (works on both, if installed)
    local res = mp.command_native({
        name = "subprocess",
        args = {"python3", "-c", "import os,sys; os.makedirs(sys.argv[1], exist_ok=True)", dir},
        playback_only = false
    })
    if not res or res.status ~= 0 then
        mp.command_native({
            name = "subprocess",
            args = {"python", "-c", "import os,sys; os.makedirs(sys.argv[1], exist_ok=True)", dir},
            playback_only = false
        })
    end
end

-- ffmpeg path: keep default on Windows; set absolute path on Linux if you want
local FFMPEG = is_windows and "ffmpeg" or "/usr/bin/ffmpeg"

local PAD_MS = 120
local SUB_FALLBACK_HALFSPAN_MS = 800
local SCREENSHOT_MODE = "video"      -- "video" = no subtitles
local SCREENSHOT_EXT  = ".jpg"       -- save JPGs
-- ====================

local state = {
    active = false,
    words = {},
    idx = 1,
    tl_text = "",
    en_text = "",
    t0 = 0,
    t1 = 0,
    osd_timer = nil,
    out_dir = nil,
    out_tsv = nil,
}

local function srt_time(t)
    if not t then t = 0 end
    local h = math.floor(t/3600)
    local m = math.floor((t%3600)/60)
    local s = math.floor(t%60)
    local ms = math.floor((t - math.floor(t)) * 1000)
    return string.format("%02d:%02d:%02d,%03d", h, m, s, ms)
end

local function fmt_secs(t)
    if not t or t < 0 then t = 0 end
    return string.format("%.3f", t)
end

local function strip_ext(name)
    return (name:gsub("%.[^%.]+$", ""))
end

local function ensure_outputs()
    local path = mp.get_property("path")
    if not path then return end
    local dir, fname = utils.split_path(path)
    if not dir or dir == "" then dir = mp.get_property("working-directory") or "." end
    if not fname or fname == "" then fname = "unknown" end
    local base = strip_ext(fname)

    local capdir = utils.join_path(dir, base .. ".captures")


mkdir_p(capdir)
state.out_dir = capdir
state.out_tsv = utils.join_path(capdir, "mined.tsv")

    local f = io.open(state.out_tsv, "r")
    if f then f:close() else
        local w = assert(io.open(state.out_tsv, "w"))
        w:write("word\ttl_text\ten_text\tstart_s\tend_s\taudio\tscreenshot\tvideo\n")
        w:close()
    end
end

local function split_words(s)
    local words = {}
    for w in s:gmatch("%S+") do
        table.insert(words, w)
    end
    return words
end

local function show_picker_osd()
    if not state.active then return end
    local ass = mp.get_property_osd("osd-ass-cc")
    ass = ass .. "{\\an7\\fs28\\bord2\\shad0\\1c&HFFFFFF&\\3c&H000000&}"
    ass = ass .. "Pick a word (←/→, Enter):\\N"
    for i, w in ipairs(state.words) do
        if i == state.idx then
            ass = ass .. "{\\1c&H00FF00&}"
        else
            ass = ass .. "{\\1c&HFFFFFF&}"
        end
        ass = ass .. w .. "{\\1c&HFFFFFF&} "
    end
    mp.set_osd_ass(0, 0, ass)
end

local function clear_osd()
    mp.set_osd_ass(0, 0, "")
end

local function deactivate_picker()
    state.active = false
    if state.osd_timer then
        state.osd_timer:kill()
        state.osd_timer = nil
    end
    clear_osd()
end

local function toggle_picker()
    local ar = mp.get_property("sub-text") or ""
    if ar == "" then
        mp.osd_message("No TEXT subtitle on screen")
        return
    end
    local s0 = mp.get_property_number("sub-start")
    local s1 = mp.get_property_number("sub-end")
    local now = mp.get_property_number("time-pos") or 0
    if not s0 or not s1 or s1 <= s0 then
        s0 = now - SUB_FALLBACK_HALFSPAN_MS/1000.0
        s1 = now + SUB_FALLBACK_HALFSPAN_MS/1000.0
        if s0 < 0 then s0 = 0 end
    end

    ensure_outputs()

    state.active  = true
    state.tl_text = ar:gsub("\\N", "\n"):gsub("\r?\n", " ")
    state.en_text = (mp.get_property("secondary-sub-text") or ""):gsub("\\N", "\n"):gsub("\r?\n", " ")
    state.t0, state.t1 = s0, s1
    state.words = split_words(state.tl_text)
    if #state.words == 0 then state.words = {"(no-word)"} end
    if state.idx < 1 or state.idx > #state.words then state.idx = 1 end

    if state.osd_timer then state.osd_timer:kill() end
    state.osd_timer = mp.add_periodic_timer(0.15, show_picker_osd)
    show_picker_osd()
end

local function step_left()
    if not state.active or #state.words == 0 then return end
    state.idx = ((state.idx - 2) % #state.words) + 1
    show_picker_osd()
end

local function step_right()
    if not state.active or #state.words == 0 then return end
    state.idx = (state.idx % #state.words) + 1
    show_picker_osd()
end

local function pad_times(t0, t1, pad_ms)
    local p = pad_ms/1000.0
    t0 = t0 - p
    if t0 < 0 then t0 = 0 end
    t1 = t1 + p
    return t0, t1
end

local function safe_name(s)
    s = s or ""
    s = s:gsub("[\\/:*?\"<>|]", "_")
    s = s:gsub("%s+", "_")
    if #s > 48 then s = s:sub(1,48) end
    if s == "" then s = "capture" end
    return s
end

-- Resolve the currently selected audio track to an ffmpeg -map argument
-- Strategy:
--  1) Find selected audio in track-list; prefer its ff-index if present => "-map 0:a:<ff-index>"
--  2) If ff-index missing, fall back to first selected audio order => "-map 0:a"
--  3) Always return something so capture never silently fails
local function build_map_for_selected_audio()
    local tracks = mp.get_property_native("track-list") or {}
    local selected = nil
    for _, t in ipairs(tracks) do
        if t.type == "audio" and t.selected then
            selected = t
            break
        end
    end
    if selected and type(selected["ff-index"]) == "number" then
        return "0:" .. tostring(selected["ff-index"]), "(ffidx " .. tostring(selected["ff-index"]) .. ")"
    end
    if selected then
        return "0:a", "(fallback 0:a)"
    end
    return "0:a", "(no selection; default 0:a)"
end

local function capture_current()
    if not state.active then return end
    deactivate_picker()

    local word  = state.words[state.idx] or "(no-word)"
    local vpath = mp.get_property("path") or "unknown"
    local dir, fname = utils.split_path(vpath)
    if not dir or dir == "" then dir = mp.get_property("working-directory") or "." end
    if not fname or fname == "" then fname = "unknown" end
    local base = strip_ext(fname)
    ensure_outputs()

    -- unique suffix with sub-second precision
    local tnow = mp.get_time()
    local suffix = string.format("%d_%03d", math.floor(tnow), math.floor((tnow - math.floor(tnow))*1000))

    -- ---------- SCREENSHOT (no subtitles) ----------
    local snap_full = utils.join_path(state.out_dir, string.format("%s_%s_%s%s", base, safe_name(word), suffix, SCREENSHOT_EXT))
    mp.commandv("screenshot-to-file", snap_full, SCREENSHOT_MODE)
    -- Verify write; keep going even if it failed
    local snap_ok = false
    do
        local f = io.open(snap_full, "rb")
        if f then f:close(); snap_ok = true end
    end

    -- ---------- AUDIO SLICE ----------
    local at0, at1 = pad_times(state.t0, state.t1, PAD_MS)
    local dur = math.max(0.05, at1 - at0)
    local audio_full = utils.join_path(state.out_dir, string.format("%s_%s_%s.mp3", base, safe_name(word), suffix))

    local map_arg, map_note = build_map_for_selected_audio()
    local ff_log = utils.join_path(state.out_dir, string.format("ffmpeg_%s.log", suffix))
    local args = {
        FFMPEG, "-hide_banner", "-nostdin",
        "-ss", fmt_secs(at0),
        "-i", vpath,
        "-t", fmt_secs(dur),
        "-map", map_arg,
        "-vn",
        "-y", audio_full
    }
    mp.command_native_async(
		{ name = "subprocess", args = args, playback_only = false, capture_stderr = true },
		function(success, result, errstr)
			-- Handle both callback styles (old/new)
			local ok, status, stderr

			if type(success) == "table" and result == nil then
				-- Old style: first arg is actually the result table
				local res = success
				ok     = (res.status == 0)
				status = res.status
				stderr = res.stderr
			else
				ok     = (success == true)
				status = (result and result.status) or nil
				stderr = (result and result.stderr) or errstr
			end

			if not ok or (status and status ~= 0) then
				local f = io.open(ff_log, "w")
				if f then
					f:write(tostring(stderr or "ffmpeg failed (no stderr)"))
					f:close()
				end
				mp.osd_message("⚠️ FFmpeg audio failed. See " .. ff_log)
			end
		end
	)


    -- ---------- TSV APPEND (basenames only for screenshot/audio) ----------
    local _, snap_name = utils.split_path(snap_full)
    local _, audio_name = utils.split_path(audio_full)
    -- Build Anki field strings (empty if missing)
	local audio_anki = audio_name and ("[sound:" .. audio_name .. "]") or ""
	local image_anki = snap_name  and ('<img src="' .. snap_name .. '">') or ""

	local w = assert(io.open(state.out_tsv, "a"))
	w:write(table.concat({
		word,
		state.tl_text,
		(state.en_text ~= "" and state.en_text or ""),
		string.format("%.3f", state.t0),
		string.format("%.3f", state.t1),
		audio_anki,          -- <- Anki audio tag
		image_anki,          -- <- Anki image tag
		fname                -- video filename only
	}, "\t") .. "\n")
	w:close()

    -- Single OSD feedback (no duplicate locals)
    local snap_msg = snap_ok and "" or " (⚠️ screenshot write failed)"
    mp.osd_message("Saved: "..word.." "..map_note..snap_msg.." @"..srt_time(state.t0))
end

-- ---------- SAFE WRAPPER + BINDINGS REINSTALL ----------

-- write errors to a tiny log, and show on OSD without killing the script
local function safe(fn)
    return function(...)
        local ok, res = pcall(fn, ...)
        if not ok then
            local outdir = state.out_dir or (mp.get_property("working-directory") or ".")
            local logp = (outdir .. "/miner_error.log")
            local f = io.open(logp, "a")
            if f then
                f:write(os.date("!%Y-%m-%d %H:%M:%S UTC"), "  ", tostring(res), "\n")
                f:close()
            end
            mp.osd_message("miner.lua error → see miner_error.log")
        end
    end
end

-- (re)install key bindings; wrap each target in 'safe' so errors don't unbind us
local function install_bindings()
    mp.add_forced_key_binding("F9",    "miner_toggle",  safe(toggle_picker))
    mp.add_forced_key_binding("LEFT",  "miner_left",    safe(step_left),  { repeatable = true })
    mp.add_forced_key_binding("RIGHT", "miner_right",   safe(step_right), { repeatable = true })
    mp.add_forced_key_binding("ENTER", "miner_capture", safe(capture_current))
end

-- make sure bindings exist now and after every file load (some setups reset them)
install_bindings()
mp.register_event("file-loaded", install_bindings)

-- also re-affirm bindings after each capture completes (in case mpv/scripts shuffle)
-- add this line at the VERY END of your capture_current() function:
--   install_bindings()
