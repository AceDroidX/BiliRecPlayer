local mp = require("mp")
local msg = require("mp.msg")

local BIN_SECONDS = 10
local MAX_POINTS = 240
local CHART_HEIGHT = 45
local BOTTOM_OFFSET = 90

local overlay = mp.create_osd_overlay("ass-events")
local times = {}
local values = {}
local duration = nil
local max_xml_time = 0
local xml_file = nil
local chart_cache = nil
local mouse_binding_enabled = false
local visible = true

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(value, maximum))
end

local function format_time(seconds)
    seconds = math.floor(math.max(0, seconds or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, seconds % 60)
    end
    return string.format("%02d:%02d", minutes, seconds % 60)
end

local function xml_for_video(path)
    if not path or path:find("://", 1, true) then return nil end
    path = mp.command_native({"normalize-path", path})
    return path:gsub("%.[^./\\]+$", ".xml")
end

local function load_xml(path)
    times = {}
    max_xml_time = 0
    xml_file = nil
    chart_cache = nil
    local file = io.open(path, "r")
    if not file then
        msg.warn("没有同名 XML，跳过弹幕热度图：" .. path)
        return
    end
    for line in file:lines() do
        for value in line:gmatch('<d%s+.-p="([%d%.]+),') do
            local seconds = tonumber(value)
            if seconds and seconds >= 0 then
                table.insert(times, seconds)
                max_xml_time = math.max(max_xml_time, seconds)
            end
        end
    end
    file:close()
    xml_file = path
    msg.info(string.format("弹幕热度已加载：%s（%d 条）", path, #times))
end

local function calculate_density()
    values = {}
    chart_cache = nil
    if not duration or duration <= 0 or #times == 0 then return end

    local count = math.max(1, math.ceil(duration / BIN_SECONDS))
    local bins = {}
    for index = 1, count do bins[index] = 0 end
    for _, seconds in ipairs(times) do
        if seconds <= duration then
            local index = math.min(count, math.floor(seconds / BIN_SECONDS) + 1)
            bins[index] = bins[index] + 1
        end
    end

    -- 平滑相邻时间段，降低瞬时刷屏造成的尖峰。
    local sorted = {}
    for index = 1, count do
        local weighted, total_weight = 0, 0
        for offset = -2, 2 do
            local neighbor = index + offset
            if neighbor >= 1 and neighbor <= count then
                local weight = 3 - math.abs(offset)
                weighted = weighted + bins[neighbor] * weight
                total_weight = total_weight + weight
            end
        end
        values[index] = weighted / total_weight
        table.insert(sorted, values[index])
    end
    table.sort(sorted)
    local high = sorted[math.max(1, math.ceil(#sorted * 0.95))]
    if high <= 0 then high = sorted[#sorted] end
    for index = 1, count do
        values[index] = high > 0 and math.sqrt(
            clamp(values[index] / high, 0, 1)) or 0
    end
end

local function geometry()
    local width, height = mp.get_osd_size()
    if not width or not height or width <= 0 or height <= 0 then return nil end
    local margin = clamp(mp.get_property_number("video-margin-ratio-right", 0), 0, 0.9)
    local available = math.floor(width * (1 - margin))
    if available < 120 or height < 180 then return nil end
    local left, right = 18, available - 18
    local baseline = height - BOTTOM_OFFSET
    return {
        w = width, h = height, left = left, right = right,
        baseline = baseline, top = baseline - CHART_HEIGHT,
    }
end

local function rectangle(x1, y1, x2, y2, color, alpha)
    return string.format(
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\alpha&H%s&\\p1}"
        .. "m %d %d l %d %d l %d %d l %d %d",
        color, alpha or "00", x1, y1, x2, y1, x2, y2, x1, y2
    )
end

local function sample_value(seconds)
    local position = clamp(seconds / BIN_SECONDS + 1, 1, #values)
    local first = math.floor(position)
    local second = math.min(#values, first + 1)
    local fraction = position - first
    return values[first] * (1 - fraction) + values[second] * fraction
end

local function chart_shape(g)
    local width = g.right - g.left
    local count = math.min(MAX_POINTS, math.max(2, math.floor(width / 3)))
    local top_points = {}
    for index = 0, count do
        local fraction = index / count
        local x = math.floor(g.left + width * fraction + 0.5)
        local level = sample_value(duration * fraction)
        local y = math.floor(g.baseline - 4 - level * CHART_HEIGHT + 0.5)
        table.insert(top_points, {x, y})
    end

    local area = {
        string.format("m %d %d", g.left, g.baseline),
    }
    for _, point in ipairs(top_points) do
        table.insert(area, string.format("l %d %d", point[1], point[2]))
    end
    table.insert(area, string.format("l %d %d", g.right, g.baseline))

    local line = {string.format("m %d %d", top_points[1][1], top_points[1][2])}
    for _, point in ipairs(top_points) do
        table.insert(line, string.format("l %d %d", point[1], point[2]))
    end
    for index = #top_points, 1, -1 do
        local point = top_points[index]
        table.insert(line, string.format("l %d %d", point[1], point[2] + 2))
    end
    return {
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H3279C8&"
            .. "\\alpha&H75&\\p1}" .. table.concat(area, " "),
        "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H67A8FF&"
            .. "\\alpha&H00&\\p1}" .. table.concat(line, " "),
    }
end

local function mouse_on_chart(g)
    local mouse = mp.get_property_native("mouse-pos")
    if not mouse or not mouse.hover then return nil end
    if mouse.x < g.left or mouse.x > g.right or
        mouse.y < g.top - 15 or mouse.y > g.baseline + 14 then
        return nil
    end
    return mouse
end

local function render()
    if not visible or not duration or #values == 0 then
        overlay:remove()
        return
    end
    local g = geometry()
    if not g then
        overlay:remove()
        return
    end
    local key = string.format("%d:%d:%d:%d", g.left, g.right,
        g.baseline, #values)
    if not chart_cache or chart_cache.key ~= key then
        chart_cache = {key = key, events = chart_shape(g)}
    end

    local events = {
        rectangle(g.left, g.top - 20, g.right, g.baseline + 13, "11151B", "88"),
        chart_cache.events[1],
        chart_cache.events[2],
        rectangle(g.left, g.baseline + 5, g.right, g.baseline + 9,
            "5B6573", "00"),
    }
    local time_pos = clamp(mp.get_property_number("time-pos", 0), 0, duration)
    local played_x = math.floor(g.left +
        (g.right - g.left) * time_pos / duration + 0.5)
    table.insert(events, rectangle(g.left, g.baseline + 5, played_x,
        g.baseline + 9, "FFFFFF", "00"))
    table.insert(events, rectangle(played_x - 2, g.baseline - 6,
        played_x + 2, g.baseline + 11, "FFFFFF", "00"))

    local mouse = mouse_on_chart(g)
    if mouse then
        local hover_seconds = clamp((mouse.x - g.left) /
            (g.right - g.left), 0, 1) * duration
        local hover_x = math.floor(mouse.x + 0.5)
        table.insert(events, rectangle(hover_x, g.top - 11, hover_x + 1,
            g.baseline + 8, "FFFFFF", "88"))
        local label = string.format("%s  弹幕热度 %d%%",
            format_time(hover_seconds),
            math.floor(sample_value(hover_seconds) * 100 + 0.5))
        local label_width = math.min(270, g.right - g.left)
        local label_x = clamp(hover_x - math.floor(label_width / 2),
            g.left, g.right - label_width)
        table.insert(events, string.format(
            "{\\an7\\pos(%d,%d)\\fs26\\bord2\\shad0\\1c&HFFFFFF&}"
            .. "%s", label_x, g.top - 52,
            mp.command_native({"escape-ass", label})))
    end

    overlay.res_x, overlay.res_y = g.w, g.h
    overlay.data = table.concat(events, "\n")
    overlay:update()
end

local function click_chart()
    if not visible then return end
    local g = geometry()
    if not g then return end
    local mouse = mouse_on_chart(g)
    if not mouse then return end
    local seconds = clamp((mouse.x - g.left) / (g.right - g.left), 0, 1) * duration
    mp.commandv("seek", tostring(seconds), "absolute+exact")
end

local function update_mouse_binding()
    local g = visible and geometry() or nil
    local hovering = g and duration and #values > 0 and mouse_on_chart(g)
    if hovering and not mouse_binding_enabled then
        mp.add_forced_key_binding("MBTN_LEFT", "heatmap-seek", click_chart)
        mouse_binding_enabled = true
    elseif not hovering and mouse_binding_enabled then
        mp.remove_key_binding("heatmap-seek")
        mouse_binding_enabled = false
    end
end

mp.observe_property("mouse-pos", "native", function()
    update_mouse_binding()
    render()
end)

mp.add_key_binding("H", "toggle-danmaku-heatmap", function()
    visible = not visible
    update_mouse_binding()
    render()
    if visible and #values == 0 then
        mp.osd_message("弹幕热度：没有可用弹幕")
    else
        mp.osd_message("弹幕热度：" .. (visible and "开启" or "关闭"))
    end
end)

mp.register_event("file-loaded", function()
    local path = xml_for_video(mp.get_property("path"))
    if path then load_xml(path) end
    duration = mp.get_property_number("duration")
    if not duration or duration <= 0 then
        duration = max_xml_time
    end
    calculate_density()
    update_mouse_binding()
    render()
end)

mp.observe_property("duration", "number", function(_, value)
    if value and value > 0 and duration and math.abs(value - duration) > 0.5 then
        duration = value
        calculate_density()
        render()
    end
end)

mp.register_event("end-file", function()
    times, values, duration, xml_file, chart_cache = {}, {}, nil, nil, nil
    max_xml_time = 0
    overlay:remove()
    update_mouse_binding()
end)

mp.add_periodic_timer(0.25, render)
