local mp = require("mp")
local msg = require("mp.msg")

local PANEL_RATIO = 0.35
local HEADER_HEIGHT = 126
local TEXT_SIZE = 34
local LINE_HEIGHT = 42
local CJK_WIDTH_RATIO = 0.68
local SCROLL_ROWS = 3
local FILTER_OPTION_HEIGHT = 32

local overlay = mp.create_osd_overlay("ass-events")
local subtitles = {}
local filtered_indices = {}
local speakers = {}
local filter_speaker = nil
local subtitle_file = nil
local visible = true
local follow_current = true
local top_index = 1
local last_anchor = nil
local last_width = nil
local saved_margin = nil
local mouse_bindings_enabled = false
local keyboard_bindings_enabled = false
local row_hits = {}
local filter_hits = {}
local filter_menu_open = false
local filter_menu_top = 1
local filter_menu_hits = {}
local scrollbar = nil
local scrollbar_dragging = false
local browse_index = nil

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
                        local speaker, content = text:match("^%s*%[(S%d+)%]%s*(.*)$")
                        table.insert(result, {
                            start = start_time,
                            finish = end_time,
                            text = text,
                            speaker = speaker,
                            content = content or text,
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

local function rebuild_filter()
    filtered_indices = {}
    for index, sub in ipairs(subtitles) do
        if filter_speaker == nil or sub.speaker == filter_speaker then
            table.insert(filtered_indices, index)
        end
    end
    top_index = 1
    last_anchor = nil
    follow_current = true
    browse_index = nil
end

local function set_filter(speaker)
    filter_menu_open = false
    filter_speaker = speaker
    rebuild_filter()
end

local function load_secondary_srt()
    local path = mp.get_property("current-tracks/sub2/external-filename")
    if path then path = mp.command_native({"normalize-path", path}) end
    if path == subtitle_file then return end

    subtitles = {}
    filtered_indices = {}
    speakers = {}
    filter_speaker = nil
    filter_menu_open = false
    filter_menu_hits = {}
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
    local seen = {}
    for _, sub in ipairs(subtitles) do
        if sub.speaker and not seen[sub.speaker] then
            seen[sub.speaker] = true
            table.insert(speakers, sub.speaker)
        end
    end
    table.sort(speakers)
    rebuild_filter()
    subtitle_file = path
    msg.info(string.format("字幕栏已加载 %s（%d 条，%d 位说话人）",
        path, #subtitles, #speakers))
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
    if #filtered_indices == 0 then return nil end
    local lo, hi, result = 1, #filtered_indices, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if subtitles[filtered_indices[mid]].start <= time_pos then
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

local function filter_menu_capacity(g)
    return math.max(0, math.floor((g.h - HEADER_HEIGHT) / FILTER_OPTION_HEIGHT))
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
    -- ASS 的实际中文字宽小于字号，按实际宽度估算换行位置。
    local units = math.max(8, math.floor(
        (panel_width - 115) / (TEXT_SIZE * CJK_WIDTH_RATIO / 2)))
    local text = filter_speaker and sub.content or sub.text
    local lines = wrap_text(text, units)
    return lines, math.max(62, #lines * LINE_HEIGHT + 18)
end

local function last_top_index(g)
    local available = g.h - HEADER_HEIGHT
    local used = 0
    for index = #filtered_indices, 1, -1 do
        local _, height = row_layout(subtitles[filtered_indices[index]], g.width)
        if used + height > available then
            return math.min(#filtered_indices, index + 1)
        end
        used = used + height
    end
    return 1
end

local function center_on(index, g)
    local available = g.h - HEADER_HEIGHT
    local accumulated = 0
    local first = index
    while first > 1 and accumulated < available / 2 do
        local _, height = row_layout(subtitles[filtered_indices[first - 1]], g.width)
        if accumulated + height > available / 2 then break end
        accumulated = accumulated + height
        first = first - 1
    end
    top_index = math.min(first, last_top_index(g))
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
    local active = anchor and
        time_pos - delay < subtitles[filtered_indices[anchor]].finish and anchor or nil
    if follow_current and anchor and (anchor ~= last_anchor or g.width ~= last_width) then
        center_on(anchor, g)
    end
    last_anchor, last_width = anchor, g.width
    top_index = clamp(top_index, 1, last_top_index(g))

    local events = {
        rectangle(g.x, 0, g.w, g.h, "1C2026"),
        rectangle(g.x, 0, g.x + 2, g.h, "48515D"),
        rectangle(g.x, HEADER_HEIGHT - 1, g.w, HEADER_HEIGHT, "3B424D"),
        text_event(g.x + 18, 9, 32, "FFFFFF",
            {g.width < 370 and "字幕" or "字幕 / Transcript"}),
    }
    local status = follow_current and "跟随中" or "回到当前"
    table.insert(events, text_event(g.w - 130, 12, 27, "A8C9FF", {status}))
    local detail = subtitle_file and
        (basename(subtitle_file) .. "  ·  " .. #subtitles .. " 条") or "未找到 secondary SRT"
    table.insert(events, text_event(g.x + 18, 53, 18, "AAB3C0", {detail},
        {g.x + 18, 52, g.w - 16, 80}))

    filter_hits = {}
    filter_menu_hits = {}
    if #speakers > 0 and g.width >= 108 + #speakers * 73 then
        filter_menu_open = false
        local x = g.x + 18
        for index = 0, #speakers do
            local speaker = index == 0 and nil or speakers[index]
            local label = speaker or "全部"
            local button_width = speaker and 66 or 72
            local selected = speaker == filter_speaker
            table.insert(events, rectangle(x, 87, x + button_width, 118,
                selected and "465B78" or "2B333E"))
            table.insert(events, text_event(x + 10, 89, 19,
                selected and "FFFFFF" or "BEC8D5", {label}))
            table.insert(filter_hits, {
                left = x, right = x + button_width, speaker = speaker,
            })
            x = x + button_width + 7
        end
    elseif #speakers > 0 then
        local label = "说话人: " .. (filter_speaker or "全部") ..
            (filter_menu_open and "  ▴" or "  ▾")
        table.insert(events, rectangle(g.x + 18, 87, g.w - 18, 118, "2B333E"))
        table.insert(events, text_event(g.x + 28, 89, 19, "FFFFFF", {label}))
        table.insert(filter_hits, {left = g.x + 18, right = g.w - 18, dropdown = true})
    else
        filter_menu_open = false
        table.insert(events, text_event(g.x + 18, 89, 19,
            "929CAB", {"无说话人标签"}))
    end

    row_hits = {}
    scrollbar = nil
    if #filtered_indices == 0 then
        table.insert(events, text_event(g.x + 18, HEADER_HEIGHT + 24, 25,
            "AAB3C0", {"请加载同名 ASS 和 SRT 文件"}))
    else
        local y = HEADER_HEIGHT
        for position = top_index, #filtered_indices do
            local index = filtered_indices[position]
            local sub = subtitles[index]
            local lines, height = row_layout(sub, g.width)
            if y >= g.h then break end
            if position == active or position == browse_index then
                table.insert(events, rectangle(g.x + 7, y + 3,
                    g.w - 20, math.min(y + height - 3, g.h),
                    position == browse_index and "45546A" or "343F50"))
                table.insert(events, rectangle(g.x + 7, y + 3,
                    g.x + 11, math.min(y + height - 3, g.h), "72A7F5"))
            end
            table.insert(events, text_event(g.x + 18, y + 15, 21,
                (position == active or position == browse_index)
                    and "B9D6FF" or "929CAB",
                {format_time(sub.start)}))
            table.insert(events, text_event(g.x + 90, y + 8, TEXT_SIZE,
                (position == active or position == browse_index)
                    and "FFFFFF" or "DCE2EA", lines,
                {g.x + 86, y + 4, g.w - 25, math.min(y + height - 3, g.h)}))
            table.insert(row_hits, {
                index = index, position = position, top = y, bottom = y + height,
            })
            y = y + height
        end

        local track_top = HEADER_HEIGHT + 8
        local track_bottom = g.h - 10
        local track_height = math.max(1, track_bottom - track_top)
        local thumb_height = math.min(track_height, math.max(38,
            math.floor(track_height * #row_hits / #filtered_indices)))
        local max_top = last_top_index(g)
        local progress = max_top > 1 and (top_index - 1) / (max_top - 1) or 0
        local thumb_top = track_top + math.floor(
            progress * (track_height - thumb_height))
        scrollbar = {
            top = track_top, bottom = track_bottom,
            thumb_height = thumb_height, max_top = max_top,
        }
        table.insert(events, rectangle(g.w - 14, track_top, g.w - 6,
            track_bottom, "38414C"))
        table.insert(events, rectangle(g.w - 15, thumb_top, g.w - 5,
            thumb_top + thumb_height, "A4B5CB"))
    end
    -- 下拉框最后绘制，覆盖字幕；超出窗口高度的选项可用滚轮浏览。
    if filter_menu_open then
        local capacity = filter_menu_capacity(g)
        if capacity == 0 then
            filter_menu_open = false
        else
            filter_menu_top = clamp(filter_menu_top, 1,
                math.max(1, #speakers + 2 - capacity))
            local left, right, y = g.x + 18, g.w - 18, 118
            for position = filter_menu_top,
                math.min(#speakers + 1, filter_menu_top + capacity - 1) do
                local speaker = speakers[position - 1]
                local selected = speaker == filter_speaker
                table.insert(events, rectangle(left, y, right,
                    y + FILTER_OPTION_HEIGHT, selected and "465B78" or "2B333E"))
                table.insert(events, text_event(left + 10, y + 3, 19,
                    selected and "FFFFFF" or "BEC8D5", {speaker or "全部"}))
                table.insert(filter_menu_hits, {
                    left = left, right = right, top = y,
                    bottom = y + FILTER_OPTION_HEIGHT, speaker = speaker,
                })
                y = y + FILTER_OPTION_HEIGHT
            end
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

local function scrollbar_to(y)
    if not scrollbar or scrollbar.max_top <= 1 then return end
    local travel = scrollbar.bottom - scrollbar.top - scrollbar.thumb_height
    local progress = travel > 0 and
        clamp((y - scrollbar.top - scrollbar.thumb_height / 2) / travel, 0, 1) or 0
    top_index = 1 + math.floor(progress * (scrollbar.max_top - 1) + 0.5)
    follow_current = false
    browse_index = top_index
    render()
end

local function click_sidebar()
    local inside, mouse, g = in_sidebar()
    if not visible or not inside then return end
    if filter_menu_open then
        for _, hit in ipairs(filter_menu_hits) do
            if mouse.x >= hit.left and mouse.x < hit.right and
                mouse.y >= hit.top and mouse.y < hit.bottom then
                set_filter(hit.speaker)
                render()
                return
            end
        end
        filter_menu_open = false
        render()
        return
    end
    if mouse.y < HEADER_HEIGHT then
        if mouse.y >= 87 and mouse.y < 118 then
            for _, hit in ipairs(filter_hits) do
                if mouse.x >= hit.left and mouse.x < hit.right then
                    if hit.dropdown then
                        filter_menu_open = true
                        filter_menu_top = 1
                        for index, speaker in ipairs(speakers) do
                            if speaker == filter_speaker then
                                filter_menu_top = index + 1
                                break
                            end
                        end
                    else
                        set_filter(hit.speaker)
                    end
                    render()
                    return
                end
            end
        elseif mouse.y < 46 and mouse.x >= g.w - 140 then
            follow_current = true
            last_anchor = nil
            browse_index = nil
        end
        render()
        return
    end
    if mouse.x >= g.w - 22 then
        scrollbar_to(mouse.y)
        return
    end
    for _, row in ipairs(row_hits) do
        if mouse.y >= row.top and mouse.y < row.bottom then
            follow_current = true
            last_anchor = nil
            browse_index = nil
            mp.commandv("seek", tostring(subtitles[row.index].start), "absolute+exact")
            center_on(row.position, g)
            render()
            return
        end
    end
end

local function scroll(direction)
    local inside = in_sidebar()
    if not visible or not inside then return end
    local g = geometry()
    if not g then return end
    if filter_menu_open then
        filter_menu_top = clamp(filter_menu_top + direction * SCROLL_ROWS,
            1, math.max(1, #speakers + 2 - filter_menu_capacity(g)))
        render()
        return
    end
    if #filtered_indices == 0 then return end
    follow_current = false
    top_index = clamp(top_index + direction * SCROLL_ROWS,
        1, last_top_index(g))
    browse_index = top_index
    render()
end

local function filter_clicked_speaker(event)
    if event.event ~= "down" and event.event ~= "press" then return end
    if filter_menu_open then return end
    local inside, mouse, g = in_sidebar()
    if not visible or not inside or mouse.y < HEADER_HEIGHT or
        mouse.x >= g.w - 22 then return end
    for _, row in ipairs(row_hits) do
        if mouse.y >= row.top and mouse.y < row.bottom then
            local speaker = subtitles[row.index].speaker
            if speaker then
                set_filter(speaker)
                render()
            end
            return
        end
    end
end

local function scroll_page(direction)
    if not visible or #filtered_indices == 0 then return end
    local g = geometry()
    if not g then return end
    local step = math.max(1, #row_hits - 1)
    top_index = clamp(top_index + direction * step, 1, last_top_index(g))
    follow_current = false
    browse_index = top_index
    render()
end

local function navigate(direction)
    if not visible or #filtered_indices == 0 then return end
    local g = geometry()
    if not g then return end
    local time_pos = mp.get_property_number("time-pos", 0)
        - mp.get_property_number("secondary-sub-delay", 0)
    local base = browse_index
    if not base and follow_current then base = find_anchor(time_pos) end
    if not base and not follow_current then base = top_index end
    if not base then base = direction > 0 and 0 or 1 end
    browse_index = clamp(base + direction, 1, #filtered_indices)
    follow_current = false
    center_on(browse_index, g)
    render()
end

local function seek_selected()
    if not visible or #filtered_indices == 0 then return end
    local time_pos = mp.get_property_number("time-pos", 0)
        - mp.get_property_number("secondary-sub-delay", 0)
    local position = browse_index or find_anchor(time_pos) or top_index
    local sub = subtitles[filtered_indices[position]]
    mp.commandv("seek", tostring(sub.start), "absolute+exact")
    follow_current = true
    browse_index = nil
    last_anchor = nil
    render()
end

local function sidebar_mouse(event)
    if event.event == "up" then
        scrollbar_dragging = false
    elseif event.event == "down" or event.event == "press" then
        local inside, mouse, g = in_sidebar()
        if visible and inside and not filter_menu_open and mouse.y >= HEADER_HEIGHT and
            mouse.x >= g.w - 22 then
            scrollbar_dragging = true
            scrollbar_to(mouse.y)
        else
            click_sidebar()
        end
    end
end

local function enable_mouse_bindings()
    if mouse_bindings_enabled then return end
    mouse_bindings_enabled = true
    mp.add_forced_key_binding("MBTN_LEFT", "sidebar-click", sidebar_mouse,
        {complex = true})
    mp.add_forced_key_binding("MBTN_RIGHT", "sidebar-filter-speaker",
        filter_clicked_speaker, {complex = true})
    mp.add_forced_key_binding("WHEEL_UP", "sidebar-up", function() scroll(-1) end)
    mp.add_forced_key_binding("WHEEL_DOWN", "sidebar-down", function() scroll(1) end)
end

local function disable_mouse_bindings()
    if not mouse_bindings_enabled then return end
    mouse_bindings_enabled = false
    scrollbar_dragging = false
    mp.remove_key_binding("sidebar-click")
    mp.remove_key_binding("sidebar-filter-speaker")
    mp.remove_key_binding("sidebar-up")
    mp.remove_key_binding("sidebar-down")
end

local function enable_keyboard_bindings()
    if keyboard_bindings_enabled then return end
    keyboard_bindings_enabled = true
    mp.add_forced_key_binding("UP", "sidebar-previous", function()
        navigate(-1)
    end, {repeatable = true})
    mp.add_forced_key_binding("DOWN", "sidebar-next", function()
        navigate(1)
    end, {repeatable = true})
    mp.add_forced_key_binding("ENTER", "sidebar-seek", seek_selected)
    mp.add_forced_key_binding("KP_ENTER", "sidebar-seek-keypad", seek_selected)
    mp.add_forced_key_binding("PGUP", "sidebar-page-up", function()
        scroll_page(-1)
    end, {repeatable = true})
    mp.add_forced_key_binding("PGDWN", "sidebar-page-down", function()
        scroll_page(1)
    end, {repeatable = true})
end

local function disable_keyboard_bindings()
    if not keyboard_bindings_enabled then return end
    keyboard_bindings_enabled = false
    mp.remove_key_binding("sidebar-previous")
    mp.remove_key_binding("sidebar-next")
    mp.remove_key_binding("sidebar-seek")
    mp.remove_key_binding("sidebar-seek-keypad")
    mp.remove_key_binding("sidebar-page-up")
    mp.remove_key_binding("sidebar-page-down")
end

mp.observe_property("mouse-pos", "native", function(_, mouse)
    if scrollbar_dragging then
        if mouse and mouse.hover then
            scrollbar_to(mouse.y)
            return
        end
        scrollbar_dragging = false
    end
    local inside = in_sidebar()
    if not inside and filter_menu_open then
        filter_menu_open = false
        render()
    end
    if visible and inside then enable_mouse_bindings() else disable_mouse_bindings() end
end)

local function show_sidebar()
    if saved_margin == nil then
        saved_margin = mp.get_property_number("video-margin-ratio-right", 0)
    end
    visible = true
    follow_current = true
    last_anchor = nil
    browse_index = nil
    mp.set_property_number("video-margin-ratio-right", PANEL_RATIO)
    enable_keyboard_bindings()
    render()
end

local function hide_sidebar()
    visible = false
    filter_menu_open = false
    filter_menu_hits = {}
    disable_mouse_bindings()
    disable_keyboard_bindings()
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
    filtered_indices = {}
    speakers = {}
    filter_speaker = nil
    subtitle_file = nil
    row_hits = {}
    filter_hits = {}
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
