local mp = require("mp")
local msg = require("mp.msg")

local PANEL_RATIO = 0.32
local HEADER_HEIGHT = 72
local TEXT_SIZE = 18
local LINE_HEIGHT = 24
local SCROLL_ROWS = 3

local overlay = mp.create_osd_overlay("ass-events")
local subtitles = {}
local subtitle_file = nil
local visible = true
local follow_current = true
local top_index = 1
local last_anchor = nil
local last_width = nil
local saved_margin = nil
local mouse_bindings_enabled = false
local row_hits = {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(value, maximum))
end

local function basename(path)
    return (path or ""):match("([^/\\]+)$") or path or ""
end

local function parse_time(value)
    local hours, minutes, seconds, fraction =
        value:match("^(%d+):(%d+):(%d+)[,.](%d+)$")
    if not hours then return nil end
    return tonumber(hours) * 3600 + tonumber(minutes) * 60
        + tonumber(seconds) + tonumber(fraction) / 10 ^ #fraction
end

local function format_time(value)
    local seconds = math.floor(math.max(value or 0, 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
    end
    return string.format("%02d:%02d", minutes, seconds % 60)
end

local function parse_srt(data)
    local result = {}
    data = data:gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    for block in (data .. "\n\n"):gmatch("(.-)\n\n") do
        local lines = {}
        for line in (block .. "\n"):gmatch("(.-)\n") do
            table.insert(lines, line)
        end
        for index, line in ipairs(lines) do
            local first, second = line:match(
                "^%s*(%d+:%d+:%d+[,.]%d+)%s*%-%->%s*(%d+:%d+:%d+[,.]%d+)"
            )
            if first and second then
                local start_time, end_time = parse_time(first), parse_time(second)
                if start_time and end_time and end_time > start_time then
                    local text_lines = {}
                    for text_index = index + 1, #lines do
                        if lines[text_index] ~= "" then
                            table.insert(text_lines, lines[text_index])
                        end
                    end
                    local text = table.concat(text_lines, "\n")
                        :gsub("<[^>]+>", "")
                    if text:match("%S") then
                        table.insert(result, {
                            start = start_time,
                            finish = end_time,
                            text = text,
                        })
                    end
                end
                break
            end
        end
    end
    table.sort(result, function(a, b) return a.start < b.start end)
    return result
end

local function load_secondary_srt()
    local path = mp.get_property("current-tracks/sub2/external-filename")
    if path then path = mp.command_native({"normalize-path", path}) end
    if path == subtitle_file then return end

    subtitles = {}
    subtitle_file = nil
    top_index = 1
    last_anchor = nil
    follow_current = true

    if not path or not path:lower():match("%.srt$") then
        return
    end
    local file, err = io.open(path, "rb")
    if not file then
        msg.error("无法读取 SRT：" .. tostring(err))
        return
    end
    local data = file:read("*a")
    file:close()
    subtitles = parse_srt(data or "")
    subtitle_file = path
    msg.info(string.format("字幕栏已加载 %s（%d 条）", path, #subtitles))
end

local function select_subtitle_tracks()
    local tracks = mp.get_property_native("track-list", {})
    local ass_id, srt_id
    for _, track in ipairs(tracks) do
        local path = track["external-filename"]
        if track.type == "sub" and track.external and path then
            local extension = path:lower():match("%.([^.]+)$")
            if extension == "ass" then ass_id = track.id end
            if extension == "srt" then srt_id = track.id end
        end
    end
    if ass_id then mp.set_property_number("sid", ass_id) end
    if srt_id then mp.set_property_number("secondary-sid", srt_id) end
    if not ass_id or not srt_id then
        msg.warn("没有同时找到 ASS 和 SRT 外挂字幕轨")
    end
    load_secondary_srt()
end

local function find_anchor(time_pos)
    if #subtitles == 0 then return nil end
    local lo, hi, result = 1, #subtitles, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if subtitles[mid].start <= time_pos then
            result = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return result
end

local function geometry()
    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then return nil end
    local panel_x = math.floor(width * (1 - PANEL_RATIO))
    return {w = width, h = height, x = panel_x, width = width - panel_x}
end

local function wrap_text(text, max_units)
    local lines, current, used = {}, {}, 0
    for char in text:gmatch("[^\128-\191][\128-\191]*") do
        if char == "\n" then
            table.insert(lines, table.concat(current))
            current, used = {}, 0
        else
            local units = #char == 1 and 1 or 2
            if used + units > max_units and used > 0 then
                table.insert(lines, table.concat(current))
                current, used = {}, 0
            end
            table.insert(current, char)
            used = used + units
        end
    end
    table.insert(lines, table.concat(current))
    return lines
end

local function row_layout(sub, panel_width)
    local units = math.max(10, math.floor((panel_width - 104) / (TEXT_SIZE / 2)))
    local lines = wrap_text(sub.text, units)
    return lines, math.max(68, #lines * LINE_HEIGHT + 28)
end

local function center_on(index, g)
    local available = g.h - HEADER_HEIGHT
    local accumulated = 0
    local first = index
    while first > 1 and accumulated < available / 2 do
        local _, height = row_layout(subtitles[first - 1], g.width)
        if accumulated + height > available / 2 then break end
        accumulated = accumulated + height
        first = first - 1
    end
    top_index = first
end

local function rectangle(x1, y1, x2, y2, color)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\p1}"
        .. "m %d %d l %d %d l %d %d l %d %d",
        color, x1, y1, x2, y1, x2, y2, x1, y2
    )
end

local function text_event(x, y, size, color, text, clip)
    local tags = string.format(
        "{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&",
        x, y, size, color
    )
    if clip then
        tags = tags .. string.format("\\clip(%d,%d,%d,%d)",
            clip[1], clip[2], clip[3], clip[4])
    end
    local escaped = {}
    for _, line in ipairs(text) do
        table.insert(escaped, mp.command_native({"escape-ass", line}))
    end
    return tags .. "}" .. table.concat(escaped, "\\N")
end

local function render()
    if not visible then return end
    local g = geometry()
    if not g then return end

    local time_pos = mp.get_property_number("time-pos", 0)
    local delay = mp.get_property_number("secondary-sub-delay", 0)
    local anchor = find_anchor(time_pos - delay)
    local active = anchor and time_pos - delay < subtitles[anchor].finish and anchor or nil
    if follow_current and anchor and (anchor ~= last_anchor or g.width ~= last_width) then
        center_on(anchor, g)
    end
    last_anchor, last_width = anchor, g.width

    local events = {
        rectangle(g.x, 0, g.w, g.h, "1C2026"),
        rectangle(g.x, 0, g.x + 2, g.h, "48515D"),
        rectangle(g.x, HEADER_HEIGHT - 1, g.w, HEADER_HEIGHT, "3B424D"),
        text_event(g.x + 18, 11, 23, "FFFFFF",
            {g.width < 340 and "字幕" or "字幕 / Transcript"}),
    }
    local status = follow_current and "跟随中" or "回到当前"
    table.insert(events, text_event(g.w - 102, 16, 14, "A8C9FF", {status}))
    local detail = subtitle_file and
        (basename(subtitle_file) .. "  ·  " .. #subtitles .. " 条") or "未找到 secondary SRT"
    table.insert(events, text_event(g.x + 18, 43, 13, "AAB3C0", {detail},
        {g.x + 18, 42, g.w - 12, 66}))

    row_hits = {}
    if #subtitles == 0 then
        table.insert(events, text_event(g.x + 18, HEADER_HEIGHT + 24, 18,
            "AAB3C0", {"请加载同名 ASS 和 SRT 文件"}))
    else
        local y = HEADER_HEIGHT
        for index = top_index, #subtitles do
            local sub = subtitles[index]
            local lines, height = row_layout(sub, g.width)
            if y >= g.h then break end
            if index == active then
                table.insert(events, rectangle(g.x + 7, y + 3,
                    g.w - 7, math.min(y + height - 3, g.h), "343F50"))
                table.insert(events, rectangle(g.x + 7, y + 3,
                    g.x + 11, math.min(y + height - 3, g.h), "72A7F5"))
            end
            table.insert(events, text_event(g.x + 18, y + 14, 14,
                index == active and "B9D6FF" or "929CAB",
                {format_time(sub.start)}))
            table.insert(events, text_event(g.x + 82, y + 12, TEXT_SIZE,
                index == active and "FFFFFF" or "DCE2EA", lines,
                {g.x + 78, y + 5, g.w - 12, math.min(y + height - 4, g.h)}))
            table.insert(row_hits, {index = index, top = y, bottom = y + height})
            y = y + height
        end
    end
    overlay.res_x, overlay.res_y = g.w, g.h
    overlay.data = table.concat(events, "\n")
    overlay:update()
end

local function in_sidebar()
    local mouse, g = mp.get_property_native("mouse-pos"), geometry()
    return mouse and mouse.hover and g and mouse.x >= g.x and mouse.x < g.w
        and mouse.y >= 0 and mouse.y < g.h, mouse, g
end

local function click_sidebar()
    local inside, mouse, g = in_sidebar()
    if not visible or not inside then return end
    if mouse.y < HEADER_HEIGHT then
        follow_current = true
        last_anchor = nil
        render()
        return
    end
    for _, row in ipairs(row_hits) do
        if mouse.y >= row.top and mouse.y < row.bottom then
            follow_current = true
            last_anchor = nil
            mp.commandv("seek", tostring(subtitles[row.index].start), "absolute+exact")
            center_on(row.index, g)
            render()
            return
        end
    end
end

local function scroll(direction)
    local inside = in_sidebar()
    if not visible or not inside or #subtitles == 0 then return end
    follow_current = false
    top_index = clamp(top_index + direction * SCROLL_ROWS, 1, #subtitles)
    render()
end

local function enable_mouse_bindings()
    if mouse_bindings_enabled then return end
    mouse_bindings_enabled = true
    mp.add_forced_key_binding("MBTN_LEFT", "sidebar-click", click_sidebar)
    mp.add_forced_key_binding("WHEEL_UP", "sidebar-up", function() scroll(-1) end)
    mp.add_forced_key_binding("WHEEL_DOWN", "sidebar-down", function() scroll(1) end)
end

local function disable_mouse_bindings()
    if not mouse_bindings_enabled then return end
    mouse_bindings_enabled = false
    mp.remove_key_binding("sidebar-click")
    mp.remove_key_binding("sidebar-up")
    mp.remove_key_binding("sidebar-down")
end

mp.observe_property("mouse-pos", "native", function()
    local inside = in_sidebar()
    if visible and inside then enable_mouse_bindings() else disable_mouse_bindings() end
end)

local function show_sidebar()
    if saved_margin == nil then
        saved_margin = mp.get_property_number("video-margin-ratio-right", 0)
    end
    visible = true
    follow_current = true
    last_anchor = nil
    mp.set_property_number("video-margin-ratio-right", PANEL_RATIO)
    render()
end

local function hide_sidebar()
    visible = false
    disable_mouse_bindings()
    overlay:remove()
    if saved_margin ~= nil then
        mp.set_property_number("video-margin-ratio-right", saved_margin)
        saved_margin = nil
    end
end

mp.add_key_binding("T", "toggle-subtitle-sidebar", function()
    if visible then hide_sidebar() else show_sidebar() end
end)

mp.register_event("file-loaded", function()
    mp.add_timeout(0.1, function()
        select_subtitle_tracks()
        if visible then show_sidebar() end
        render()
    end)
end)

mp.register_event("end-file", function()
    subtitles = {}
    subtitle_file = nil
    row_hits = {}
    hide_sidebar()
    visible = true
end)

mp.observe_property("secondary-sid", "native", function()
    mp.add_timeout(0.1, function()
        load_secondary_srt()
        render()
    end)
end)

mp.add_periodic_timer(0.2, render)
