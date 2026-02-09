--[[
    MemScope v1.0.0 - Memory Monitoring Addon for Ashita v4

    Tracks per-addon memory usage via /addon list capture, process memory
    via Windows FFI, and provides leak detection with historical analysis.

    Author: SQLCommit
    Version: 1.0.0
]]--

addon.name    = 'memscope';
addon.author  = 'SQLCommit';
addon.version = '1.0.0';
addon.desc    = 'Memory monitoring and leak detection for Ashita addons';
addon.link    = 'https://github.com/SQLCommit/memscope';

require 'common';

local chat     = require('chat');
local settings = require('settings');

local analysis = require('analysis');
local monitor  = require('monitor');
local ui       = require('ui');

-------------------------------------------------------------------------------
-- Default Settings
-------------------------------------------------------------------------------
local default_settings = T{
    sample_interval     = 5,
    addon_poll_interval = 30,
    show_process_memory = true,
    show_addon_breakdown = true,
    show_charts         = true,
    chart_height        = 80,
    alerts_enabled      = true,
    leak_threshold      = 10.0,
    spike_threshold     = 100,
    spike_min_kb        = 512,
    auto_gc_monitoring  = true,
};

-------------------------------------------------------------------------------
-- Shared State
-------------------------------------------------------------------------------
local state = {
    settings = nil,
    chat = nil,

    -- Timing
    last_sample_time = 0,
    last_addon_poll_time = 0,

    -- Current readings (reused table)
    current = {
        working_set_mb = 0,
        peak_working_set_mb = 0,
        pagefile_mb = 0,
        peak_pagefile_mb = 0,
        total_phys_mb = 0,
        avail_phys_mb = 0,
        total_pagefile_mb = 0,
        avail_pagefile_mb = 0,
        total_virtual_mb = 0,
        avail_virtual_mb = 0,
        memory_load_pct = 0,
        own_lua_kb = 0,
        own_memory_kb = 0,
        addon_total_kb = 0,
        timestamp = 0,
    },

    -- UI state
    ui_selected_addon = nil,

    -- Action flags (decouple UI from logic)
    paused = false,
    force_refresh = false,
    force_gc = false,
    settings_save_requested = false,

    -- Populated by modules:
    -- state.history (analysis)
    -- state.addons, state.addon_order, state.addon_pool (analysis)
    -- state.alerts, state.alert_head, state.alert_count (analysis)
    -- state.gc (monitor)
};

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local os_clock = os.clock;
local os_time = os.time;
local string_format = string.format;
local math_min = math.min;
local collectgarbage = collectgarbage;

-------------------------------------------------------------------------------
-- Helper: Print with addon header
-------------------------------------------------------------------------------
local function msg(text)
    print(chat.header('MemScope') .. chat.message(text));
end

local function msg_warning(text)
    print(chat.header('MemScope') .. chat.warning(text));
end

-------------------------------------------------------------------------------
-- Core: Collect a memory sample
-------------------------------------------------------------------------------
local function collect_sample()
    state.current.timestamp = os_time();

    monitor.query_process_memory();
    monitor.query_system_memory();
    monitor.query_lua_memory();
    monitor.monitor_gc();

    analysis.push_history(
        state.current.working_set_mb,
        state.current.pagefile_mb,
        state.current.addon_total_kb
    );
end

-------------------------------------------------------------------------------
-- Core: Export session data to XML Spreadsheet (opens in Excel with tabs)
-- Produces a single .xml file with worksheets:
--   Session          - Session info + addon summary snapshot
--   Process Timeline - Full process memory timeline
--   Addons Timeline  - All addons wide-format (one column per addon)
--   <addon_name>     - Per-addon detailed timeline with deltas
-------------------------------------------------------------------------------

--- XML-escape special characters.
local function esc(s)
    return tostring(s):gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;');
end

--- Sanitize a worksheet name (max 31 chars, no special chars).
local function sheet_name(s)
    return esc(tostring(s):sub(1, 31):gsub('[\\/%*%?:%[%]]', '_'));
end

--- XML cell helpers (inlined for speed).
local function hcell(val)
    return string_format('<Cell ss:StyleID="hdr"><Data ss:Type="String">%s</Data></Cell>', esc(val));
end
local function scell(val)
    return string_format('<Cell><Data ss:Type="String">%s</Data></Cell>', esc(val));
end
local function ncell(val)
    return string_format('<Cell><Data ss:Type="Number">%s</Data></Cell>', tostring(val));
end

local function export_session()
    -- Ensure exports/ directory exists
    local base_dir = string_format('%s\\addons\\memscope\\exports', AshitaCore:GetInstallPath());
    os.execute(string_format('if not exist "%s" mkdir "%s"', base_dir, base_dir));

    local timestamp = os.date('%Y%m%d_%H%M%S');
    local file_path = string_format('%s\\memscope_%s.xls', base_dir, timestamp);

    local f, err = io.open(file_path, 'w');
    if not f then
        msg_warning(string_format('Failed to create export: %s', tostring(err)));
        return;
    end

    local c = state.current;
    local vlimit = math.max(c.total_virtual_mb, 1);
    local is_laa = vlimit > 2200;
    local uptime = os_clock() - (state.session_start or 0);
    local h = state.history;
    local HISTORY_SIZE = analysis.HISTORY_SIZE;
    local ADDON_HISTORY_SIZE = analysis.ADDON_HISTORY_SIZE;
    local sheet_count = 0;

    -- XML header (SpreadsheetML — opens natively in Excel/LibreOffice with tabs)
    f:write('<?xml version="1.0" encoding="UTF-8"?>\n');
    f:write('<?mso-application progid="Excel.Sheet"?>\n');
    f:write('<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"\n');
    f:write(' xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">\n');
    f:write('<Styles>\n');
    f:write(' <Style ss:ID="Default" ss:Name="Normal"/>\n');
    f:write(' <Style ss:ID="hdr"><Font ss:Bold="1"/></Style>\n');
    f:write('</Styles>\n');

    -- ================================================================
    -- Tab 1: Session — info + addon summary
    -- ================================================================
    f:write('<Worksheet ss:Name="Session"><Table>\n');

    f:write(string_format('<Row>%s%s</Row>\n', hcell('Property'), hcell('Value')));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Date'), scell(os.date('%Y-%m-%d %H:%M:%S'))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Duration'), scell(string_format('%dm %ds', math.floor(uptime / 60), math.floor(uptime % 60)))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Paused'), scell(state.paused and 'Yes' or 'No')));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Virtual Limit'), scell(string_format('%.0f MB (%s)', vlimit, is_laa and 'LAA' or '32-bit'))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('System RAM'), scell(string_format('%.0f MB (%d%% used)', c.total_phys_mb, c.memory_load_pct))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Working Set'), scell(string_format('%.1f MB (Peak %.1f MB)', c.working_set_mb, c.peak_working_set_mb))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Committed'), scell(string_format('%.1f MB (Peak %.1f MB)', c.pagefile_mb, c.peak_pagefile_mb))));
    if state.gc then
        f:write(string_format('<Row>%s%s</Row>\n', scell('GC Collections'), scell(string_format('%d (freed %.2f KB last)', state.gc.collections, state.gc.freed_kb))));
    end
    f:write(string_format('<Row>%s%s</Row>\n', scell('Process Samples'), ncell(h.count)));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Sample Interval'), scell(string_format('%d sec', state.settings.sample_interval))));
    f:write(string_format('<Row>%s%s</Row>\n', scell('Addon Poll Interval'), scell(string_format('%d sec', state.settings.addon_poll_interval))));

    -- Addon summary table
    f:write('<Row/>\n');
    local loaded_count = 0;
    local unloaded_count = 0;
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data then
            if data.status == 'Unloaded' then unloaded_count = unloaded_count + 1;
            else loaded_count = loaded_count + 1; end
        end
    end
    f:write(string_format('<Row>%s%s</Row>\n', hcell('Addon Summary'), scell(string_format('%d loaded, %d unloaded', loaded_count, unloaded_count))));
    f:write(string_format('<Row>%s%s%s%s%s%s%s%s%s</Row>\n',
        hcell('Name'), hcell('Memory KB'), hcell('Memory MB'), hcell('Status'),
        hcell('Peak KB'), hcell('Min KB'), hcell('Delta KB/s'), hcell('Trend'), hcell('Samples')));
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data then
            local min_kb = data.min_kb == 999999 and 0 or data.min_kb;
            f:write(string_format('<Row>%s%s%s%s%s%s%s%s%s</Row>\n',
                scell(data.name),
                ncell(string_format('%.2f', data.memory_kb)),
                ncell(string_format('%.4f', data.memory_kb / 1024)),
                scell(data.status),
                ncell(string_format('%.2f', data.peak_kb)),
                ncell(string_format('%.2f', min_kb)),
                ncell(string_format('%.4f', data.last_delta)),
                ncell(string_format('%.6f', data.trend_slope)),
                ncell(data.history_count)));
        end
    end
    f:write('</Table></Worksheet>\n');
    sheet_count = sheet_count + 1;

    -- ================================================================
    -- Tab 2: Process Timeline
    -- ================================================================
    if h.count > 0 then
        f:write('<Worksheet ss:Name="Process Timeline"><Table>\n');
        f:write(string_format('<Row>%s%s%s%s%s%s%s</Row>\n',
            hcell('Sample'), hcell('Epoch'), hcell('Time'),
            hcell('Working Set MB'), hcell('Pagefile MB'),
            hcell('Addon Total KB'), hcell('Addon Total MB')));
        for i = 1, h.count do
            local idx = (h.head - h.count + i - 2) % HISTORY_SIZE + 1;
            local ts = h.timestamps[idx];
            local addon_kb = h.addon_total[idx];
            f:write(string_format('<Row>%s%s%s%s%s%s%s</Row>\n',
                ncell(i),
                ncell(ts),
                scell(os.date('%H:%M:%S', ts)),
                ncell(string_format('%.2f', h.working_set[idx])),
                ncell(string_format('%.2f', h.pagefile[idx])),
                ncell(string_format('%.2f', addon_kb)),
                ncell(string_format('%.4f', addon_kb / 1024))));
        end
        f:write('</Table></Worksheet>\n');
        sheet_count = sheet_count + 1;
    end

    -- ================================================================
    -- Tab 3: Addons Timeline — wide format, one column per addon
    -- ================================================================
    local max_samples = 0;
    local active_addons = {};
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.history_count > 0 then
            active_addons[#active_addons + 1] = name;
            if data.history_count > max_samples then
                max_samples = data.history_count;
            end
        end
    end

    if max_samples > 0 and #active_addons > 0 then
        f:write('<Worksheet ss:Name="Addons Timeline"><Table>\n');
        -- Header: Sample + one column per addon
        local row_str = hcell('Sample');
        for _, name in ipairs(active_addons) do
            row_str = row_str .. hcell(state.addons[name].name .. ' KB');
        end
        f:write(string_format('<Row>%s</Row>\n', row_str));

        -- Data rows (oldest to newest, aligned to end)
        for row = 1, max_samples do
            row_str = ncell(row);
            for _, name in ipairs(active_addons) do
                local data = state.addons[name];
                local offset = max_samples - data.history_count;
                if row <= offset then
                    row_str = row_str .. '<Cell><Data ss:Type="String"></Data></Cell>';
                else
                    local i = row - offset;
                    local idx = (data.history_head - data.history_count + i - 2) % ADDON_HISTORY_SIZE + 1;
                    row_str = row_str .. ncell(string_format('%.2f', data.history[idx]));
                end
            end
            f:write(string_format('<Row>%s</Row>\n', row_str));
        end
        f:write('</Table></Worksheet>\n');
        sheet_count = sheet_count + 1;
    end

    -- ================================================================
    -- Tab 4+: Per-addon detailed timeline (one tab per addon)
    -- ================================================================
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.history_count > 0 then
            f:write(string_format('<Worksheet ss:Name="%s"><Table>\n', sheet_name(data.name)));

            -- Metadata header
            f:write(string_format('<Row>%s%s</Row>\n', hcell('Property'), hcell('Value')));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Addon'), scell(data.name)));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Status'), scell(data.status)));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Current KB'), ncell(string_format('%.2f', data.memory_kb))));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Peak KB'), ncell(string_format('%.2f', data.peak_kb))));
            local min_kb = data.min_kb == 999999 and 0 or data.min_kb;
            f:write(string_format('<Row>%s%s</Row>\n', scell('Min KB'), ncell(string_format('%.2f', min_kb))));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Trend'), ncell(string_format('%.6f', data.trend_slope))));
            f:write(string_format('<Row>%s%s</Row>\n', scell('Samples'), ncell(data.history_count)));
            f:write('<Row/>\n');

            -- Timeline with deltas
            f:write(string_format('<Row>%s%s%s%s%s</Row>\n',
                hcell('Sample'), hcell('Memory KB'), hcell('Memory MB'),
                hcell('Delta KB'), hcell('Change From Start KB')));
            local first_val = nil;
            local prev_val = nil;
            for i = 1, data.history_count do
                local idx = (data.history_head - data.history_count + i - 2) % ADDON_HISTORY_SIZE + 1;
                local val = data.history[idx];
                if not first_val then first_val = val; end
                local delta = prev_val and (val - prev_val) or 0;
                local from_start = val - first_val;
                f:write(string_format('<Row>%s%s%s%s%s</Row>\n',
                    ncell(i),
                    ncell(string_format('%.2f', val)),
                    ncell(string_format('%.4f', val / 1024)),
                    ncell(string_format('%.2f', delta)),
                    ncell(string_format('%.2f', from_start))));
                prev_val = val;
            end

            f:write('</Table></Worksheet>\n');
            sheet_count = sheet_count + 1;
        end
    end

    -- Close workbook
    f:write('</Workbook>\n');
    f:close();

    msg(string_format('Exported %d tabs to exports\\memscope_%s.xls',
        sheet_count, timestamp));
end

-------------------------------------------------------------------------------
-- Core: Poll addons via /addon list capture (async)
-------------------------------------------------------------------------------
local function on_addon_capture_complete(results, count)
    -- Collect current addon names for marking absent ones as Unloaded
    local current_names = {};
    for i = 1, count do
        local entry = results[i];
        analysis.update_addon(entry.name, entry.memory_kb, entry.status);
        current_names[i] = entry.name;
    end
    -- Mark absent addons as Unloaded (preserves history), then sort
    analysis.prune_and_sort(current_names);
    state.current.addon_total_kb = analysis.get_addon_total_kb();
end

local function start_addon_poll()
    if not monitor.is_capturing() then
        monitor.start_addon_capture(on_addon_capture_complete);
    end
end

-------------------------------------------------------------------------------
-- Event: Load
-------------------------------------------------------------------------------
ashita.events.register('load', 'memscope_load', function()
    state.settings = settings.load(default_settings);
    state.chat = chat;

    state.session_start = os_clock();

    analysis.init(state);
    monitor.init(state);
    ui.init(state, analysis, default_settings);

    collect_sample();

    -- Schedule the first addon poll ~3 seconds from now via d3d_present timing.
    -- All polls use the same d3d_present path — no ashita.tasks.once needed.
    -- The 3-second delay lets stale /addon list output from a previous instance clear.
    local now = os_clock();
    state.last_sample_time = now;
    state.last_addon_poll_time = now - state.settings.addon_poll_interval + 3;

    msg('v1.0.0 loaded. Use /memscope to toggle window.');
end);

-------------------------------------------------------------------------------
-- Event: Unload
-------------------------------------------------------------------------------
ashita.events.register('unload', 'memscope_unload', function()
    settings.save();
    msg('Unloaded.');
end);

-------------------------------------------------------------------------------
-- Event: Text In (intercept /addon list output)
-- e.blocked = true successfully suppresses /addon list output from chat.
-- IMPORTANT: Never print() from inside this handler — it causes recursive
-- text_in events and stack overflow. Use the debug buffer instead.
-------------------------------------------------------------------------------
local text_in_guard = false;

ashita.events.register('text_in', 'memscope_text_in', function(e)
    if text_in_guard then return; end
    text_in_guard = true;

    local should_block = monitor.process_text_in(e.message_modified);
    if should_block then
        e.blocked = true;
    end

    text_in_guard = false;
end);

-------------------------------------------------------------------------------
-- Event: Command
-------------------------------------------------------------------------------
ashita.events.register('command', 'memscope_command', function(e)
    local args = e.command:args();
    if #args == 0 or not args[1]:any('/memscope') then return; end

    e.blocked = true;

    local cmd = (#args >= 2) and args[2]:lower() or 'toggle';

    if cmd == 'toggle' then
        ui.toggle();

    elseif cmd == 'show' then
        ui.show();

    elseif cmd == 'hide' then
        ui.hide();

    elseif cmd == 'snapshot' then
        collect_sample();
        start_addon_poll();
        msg('Snapshot taken.');

    elseif cmd == 'report' then
        msg('Memory Report:');
        print(string_format('  Process: %.1f MB (peak %.1f MB)',
            state.current.working_set_mb, state.current.peak_working_set_mb));
        print(string_format('  MemScope Lua: %.2f KB', state.current.own_lua_kb));
        print(string_format('  All Addons: %.2f KB', state.current.addon_total_kb));
        print(string_format('  Tracked Addons: %d', #state.addon_order));
        for i = 1, math_min(5, #state.addon_order) do
            local name = state.addon_order[i];
            local data = state.addons[name];
            if data then
                print(string_format('    %s: %.2f KB (%s)', data.name, data.memory_kb, data.status));
            end
        end

    elseif cmd == 'gc' then
        local before = collectgarbage('count');
        collectgarbage('collect');
        local after = collectgarbage('count');
        msg(string_format('GC freed %.2f KB', before - after));

    elseif cmd == 'alerts' then
        local subcmd = (#args >= 3) and args[3]:lower() or 'status';
        if subcmd == 'on' then
            state.settings.alerts_enabled = true;
            msg('Alerts enabled.');
        elseif subcmd == 'off' then
            state.settings.alerts_enabled = false;
            msg('Alerts disabled.');
        else
            msg(string_format('Alerts: %s', state.settings.alerts_enabled and 'enabled' or 'disabled'));
        end

    elseif cmd == 'export' then
        export_session();

    elseif cmd == 'pause' then
        state.paused = not state.paused;
        msg(state.paused and 'Paused. Data frozen for review.' or 'Resumed.');

    elseif cmd == 'compact' then
        ui.toggle_compact();

    elseif cmd == 'resetui' or cmd == 'reset' then
        ui.reset_ui();
        msg('UI reset to defaults.');

    elseif cmd == 'debug' then
        msg('Starting debug capture...');
        monitor.start_debug_capture();

    elseif cmd == 'help' then
        msg('Commands:');
        print('  /memscope [toggle] - Toggle window');
        print('  /memscope show/hide - Show/hide window');
        print('  /memscope compact - Toggle compact mode');
        print('  /memscope resetui - Reset window size and position');
        print('  /memscope pause - Pause/resume data collection');
        print('  /memscope snapshot - Take manual snapshot');
        print('  /memscope report - Print memory report');
        print('  /memscope export - Export session data to Excel (.xls)');
        print('  /memscope gc - Force garbage collection');
        print('  /memscope alerts [on/off] - Toggle alerts');
        print('  /memscope debug - Debug addon list capture');

    else
        msg_warning('Unknown command. Use /memscope help');
    end
end);

-------------------------------------------------------------------------------
-- Event: d3d_present (every frame)
-------------------------------------------------------------------------------
ashita.events.register('d3d_present', 'memscope_render', function()
    local now = os_clock();

    -- Check for capture timeout + flush debug log
    monitor.check_capture_timeout();
    monitor.flush_debug_log();

    -- Handle action flags from UI
    if state.force_refresh then
        state.force_refresh = false;
        collect_sample();
        start_addon_poll();
    end

    if state.force_gc then
        state.force_gc = false;
        local before = collectgarbage('count');
        collectgarbage('collect');
        local after = collectgarbage('count');
        msg(string_format('GC freed %.2f KB', before - after));
        collect_sample();
    end

    if state.settings_save_requested then
        state.settings_save_requested = false;
        settings.save();
    end

    if state.force_export then
        state.force_export = false;
        export_session();
    end

    if state.remove_addon then
        local name = state.remove_addon;
        state.remove_addon = nil;
        if state.ui_selected_addon == name then
            state.ui_selected_addon = nil;
        end
        analysis.remove_addon(name);
    end

    -- Periodic sample collection (skip when paused)
    if not state.paused and now - state.last_sample_time >= state.settings.sample_interval then
        state.last_sample_time = now;
        collect_sample();
    end

    -- Periodic addon polling (skip when paused)
    if not state.paused and now - state.last_addon_poll_time >= state.settings.addon_poll_interval then
        state.last_addon_poll_time = now;
        start_addon_poll();
    end

    -- Render UI
    ui.render();
end);

-------------------------------------------------------------------------------
-- Event: Settings changed externally
-------------------------------------------------------------------------------
settings.register('settings', 'memscope_settings_update', function(s)
    if s then
        state.settings = s;
    end
end);
