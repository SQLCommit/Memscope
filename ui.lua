--[[
    MemScope v1.0.1 - UI Module
    ImGui dashboard rendering with correct widget patterns.

    Data accuracy notes (per atom0s, Feb 2026):
    - /addon list memory = Lua-tracked only (excludes FFI, ImGui, C++ internals)
    - Working set on Win10/11 is inflated (OS delays page release)
    - GC monitoring only sees this addon's own Lua state
    - Growth alerts are informational, not confirmed leaks
]]--

local imgui = require 'imgui';

local ui = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local KB_TO_MB = 1 / 1024;

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local math_max = math.max;
local math_min = math.min;
local string_format = string.format;

-------------------------------------------------------------------------------
-- Module State
-------------------------------------------------------------------------------
local state = nil;
local analysis = nil;
local defaults = nil;

-- UI-local state (table references for ImGui widgets)
local is_open = { true };
local show_settings = { false };
local compact_mode = false;
local restore_full_size = false;
local reset_pending = false;

-- Pre-allocated chart buffers (filled in-place each frame, no allocation)
local CHART_BUFFER_SIZE = 120;
local ws_chart = {};
local addon_chart = {};
local addon_detail_chart = {};
for i = 1, CHART_BUFFER_SIZE do
    ws_chart[i] = 0;
    addon_chart[i] = 0;
    addon_detail_chart[i] = 0;
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

--- Show a (?) help marker with tooltip on hover.
local function help_marker(text)
    imgui.SameLine();
    imgui.TextDisabled('(?)');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(text);
    end
end

--- Format memory value: show MB if >= 1024 KB, otherwise KB.
local function fmt_mem(kb)
    if kb >= 1024 then
        return string_format('%.2f MB', kb * KB_TO_MB);
    end
    return string_format('%.2f KB', kb);
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function ui.init(shared_state, analysis_mod, default_settings)
    state = shared_state;
    analysis = analysis_mod;
    defaults = default_settings;
end

-------------------------------------------------------------------------------
-- Process Memory Section
-------------------------------------------------------------------------------
local prev_working_set_mb = 0;
local prev_pagefile_mb = 0;

local function render_process_memory()
    if not state.settings.show_process_memory then return; end

    local c = state.current;
    local vlimit = math_max(c.total_virtual_mb, 1);
    local is_laa = vlimit > 2200;  -- LAA = ~4096 MB, non-LAA = ~2048 MB
    local laa_label = is_laa and 'LAA' or '32-bit';

    imgui.Text(string_format('Process Memory (%s, %.0f MB limit)', laa_label, vlimit));
    help_marker(
        'Memory used by the entire FFXI process.\n' ..
        'FFXI is 32-bit: 2 GB limit (4 GB with LAA patch).\n' ..
        'Bars show usage vs the process virtual address limit.\n\n' ..
        'NOTE: Windows 10/11 inflates Working Set values.\n' ..
        'The OS holds onto memory pages aggressively and\n' ..
        'delays releasing them. Actual usage may be much\n' ..
        'lower than reported. Use the Trim button above\n' ..
        'to force a working set trim for accurate readings.'
    );
    imgui.Separator();

    local ws_delta = c.working_set_mb - prev_working_set_mb;
    local pf_delta = c.pagefile_mb - prev_pagefile_mb;

    -- Working Set bar: FFXI usage / process virtual limit
    local ws_pct = c.working_set_mb / vlimit;
    local ws_label = string_format('%.0f / %.0f MB (%.0f%%)', c.working_set_mb, vlimit, ws_pct * 100);
    imgui.Text('Working Set:');
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Physical RAM pages mapped into FFXI\'s address space.\n' ..
            'Win10/11 inflates this — OS delays page release.\n' ..
            'Use the Trim button to see actual values.'
        );
    end
    imgui.SameLine();
    imgui.ProgressBar(ws_pct, { -1, 0 }, ws_label);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(string_format(
            'Current: %.1f MB\n' ..
            'Peak: %.1f MB\n' ..
            'Delta: %+.1f MB\n' ..
            'Process Limit: %.0f MB (%s)\n' ..
            'Free Address Space: %.0f MB\n' ..
            '---\n' ..
            'System RAM: %.0f MB (%.0f MB free, %d%% used)',
            c.working_set_mb,
            c.peak_working_set_mb,
            ws_delta,
            vlimit, laa_label,
            c.avail_virtual_mb,
            c.total_phys_mb,
            c.avail_phys_mb,
            c.memory_load_pct
        ));
    end

    -- Page File bar: FFXI committed memory / process virtual limit
    local pf_pct = c.pagefile_mb / vlimit;
    local pf_label = string_format('%.0f / %.0f MB (%.0f%%)', c.pagefile_mb, vlimit, pf_pct * 100);
    imgui.Text('Committed:  ');
    if imgui.IsItemHovered() then
        imgui.SetTooltip('Virtual memory committed (RAM + swap reserved for FFXI).');
    end
    imgui.SameLine();
    imgui.ProgressBar(pf_pct, { -1, 0 }, pf_label);
    if imgui.IsItemHovered() then
        imgui.SetTooltip(string_format(
            'Current: %.1f MB\n' ..
            'Peak: %.1f MB\n' ..
            'Delta: %+.1f MB\n' ..
            'Process Limit: %.0f MB (%s)\n' ..
            '---\n' ..
            'System Page File: %.0f MB (%.0f MB free)',
            c.pagefile_mb,
            c.peak_pagefile_mb,
            pf_delta,
            vlimit, laa_label,
            c.total_pagefile_mb,
            c.avail_pagefile_mb
        ));
    end

    -- Track deltas for next frame
    prev_working_set_mb = c.working_set_mb;
    prev_pagefile_mb = c.pagefile_mb;

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Lua Memory Section
-------------------------------------------------------------------------------
local function render_lua_memory()
    imgui.Text('Lua Memory');
    help_marker(
        'Memory tracked by Lua addon scripts.\n' ..
        'Each addon runs in its own isolated Lua state.\n' ..
        '"All Addons Total" is the sum from /addon list.\n\n' ..
        'IMPORTANT: These values only reflect Lua-tracked\n' ..
        'memory. FFI allocations, ImGui resources, and\n' ..
        'C++ internals are NOT included. Actual addon\n' ..
        'memory usage may be higher than shown.'
    );
    imgui.Separator();

    imgui.Text(string_format('MemScope Lua State: %s', fmt_mem(state.current.own_lua_kb or 0)));
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Memory used by this addon\'s own Lua VM.\n' ..
            'Only includes Lua-managed objects (tables, strings,\n' ..
            'functions). Does not include FFI allocations.'
        );
    end

    imgui.Text(string_format('All Addons Total: %s', fmt_mem(state.current.addon_total_kb or 0)));
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Combined Lua-tracked memory of all loaded addons\n' ..
            '(from /addon list). This understates actual usage —\n' ..
            'FFI, ImGui, and manual C allocations are excluded.'
        );
    end

    if state.settings.auto_gc_monitoring and state.gc then
        imgui.Text(string_format('GC Collections: %d (freed %s last)',
            state.gc.collections, fmt_mem(state.gc.freed_kb)));
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Lua garbage collector activity for MemScope only.\n' ..
                'Each addon has its own isolated GC — this does\n' ..
                'NOT show GC activity of other addons.\n' ..
                'Collections: times GC has reclaimed memory.\n' ..
                'Freed: amount reclaimed in the last cycle.'
            );
        end
    end

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Addon Table
-------------------------------------------------------------------------------
local function render_addon_table()
    if not state.settings.show_addon_breakdown then return; end

    imgui.Text(string_format('Addon Memory (%d tracked)', #state.addon_order));
    help_marker(
        'Click a row for details. Right-click unloaded addons to remove.\n\n' ..
        'Values are Lua-tracked memory only (from /addon list).\n' ..
        'FFI, ImGui, and C++ allocations are not reflected.\n' ..
        'Trend/delta may show normal LuaJIT jitting behavior.'
    );
    imgui.Separator();

    local table_flags = ImGuiTableFlags_Resizable
        + ImGuiTableFlags_RowBg
        + ImGuiTableFlags_BordersInnerV
        + ImGuiTableFlags_SizingFixedFit
        + ImGuiTableFlags_Sortable
        + ImGuiTableFlags_ScrollY;

    -- Cap table height to ~10 rows; scrollbar appears if more addons are tracked
    local row_height = imgui.GetTextLineHeightWithSpacing();
    local max_rows = 10;
    local header_height = row_height + 4;
    local table_height = header_height + (row_height * math.min(#state.addon_order, max_rows));

    if not imgui.BeginTable('addon_table', 5, table_flags, { 0, table_height }) then return; end

    imgui.TableSetupScrollFreeze(0, 1);
    imgui.TableSetupColumn('Name',   ImGuiTableColumnFlags_WidthStretch + ImGuiTableColumnFlags_PreferSortAscending, 0, 0);
    imgui.TableSetupColumn('Memory', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_DefaultSort + ImGuiTableColumnFlags_PreferSortDescending, 90, 1);
    imgui.TableSetupColumn('Status', ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortAscending, 60, 2);
    imgui.TableSetupColumn('Delta',  ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 70, 3);
    imgui.TableSetupColumn('Trend',  ImGuiTableColumnFlags_WidthFixed + ImGuiTableColumnFlags_PreferSortDescending, 50, 4);
    imgui.TableHeadersRow();

    -- Handle sort spec changes
    local sort_specs = imgui.TableGetSortSpecs();
    if sort_specs then
        local spec = sort_specs.Specs;
        if spec then
            local col = spec.ColumnUserID;
            local asc = spec.SortDirection == ImGuiSortDirection_Ascending;
            if col ~= state.sort_col or asc ~= state.sort_asc then
                state.sort_col = col;
                state.sort_asc = asc;
                analysis.sort_addons(col, asc);
            end
        end
    end

    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data then
            imgui.TableNextRow();

            local is_unloaded = data.status == 'Unloaded';
            local needs_pop = false;
            if is_unloaded then
                imgui.PushStyleColor(ImGuiCol_Text, { 0.5, 0.5, 0.5, 0.6 });
                needs_pop = true;
            elseif data.alert_active then
                imgui.PushStyleColor(ImGuiCol_Text, { 1.0, 0.6, 0.2, 1.0 });
                needs_pop = true;
            elseif name == addon.name then
                imgui.PushStyleColor(ImGuiCol_Text, { 0.5, 0.8, 0.5, 1.0 });
                needs_pop = true;
            end

            -- Name
            imgui.TableNextColumn();
            if imgui.Selectable(data.name, state.ui_selected_addon == name, ImGuiSelectableFlags_SpanAllColumns) then
                if state.ui_selected_addon == name then
                    state.ui_selected_addon = nil;
                else
                    state.ui_selected_addon = name;
                end
            end
            if is_unloaded and imgui.BeginPopupContextItem('ctx_' .. name) then
                if imgui.MenuItem('Remove from tracking') then
                    state.remove_addon = name;
                end
                imgui.EndPopup();
            end

            -- Memory
            imgui.TableNextColumn();
            imgui.Text(fmt_mem(data.memory_kb));

            -- Status
            imgui.TableNextColumn();
            imgui.Text(data.status);

            -- Delta
            imgui.TableNextColumn();
            local delta_color;
            if data.last_delta > 0.1 then
                delta_color = { 1, 0.5, 0.5, 1 };
            elseif data.last_delta < -0.1 then
                delta_color = { 0.5, 1, 0.5, 1 };
            else
                delta_color = { 0.7, 0.7, 0.7, 1 };
            end
            imgui.TextColored(delta_color, string_format('%+.2f', data.last_delta));

            -- Trend
            imgui.TableNextColumn();
            if is_unloaded then
                imgui.Text('---');
            else
                local trend_text;
                if data.trend_slope > 0.1 then
                    trend_text = 'UP';
                elseif data.trend_slope < -0.1 then
                    trend_text = 'DOWN';
                else
                    trend_text = 'FLAT';
                end
                imgui.Text(trend_text);
            end

            if needs_pop then
                imgui.PopStyleColor();
            end
        end
    end

    imgui.EndTable();
    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Charts
-------------------------------------------------------------------------------

--- Format a time span in seconds to a compact human-readable label.
local function fmt_time(sec)
    if sec >= 3600 then
        return string_format('%.1fh', sec / 3600);
    elseif sec >= 60 then
        return string_format('%dm', math.floor(sec / 60));
    else
        return string_format('%ds', sec);
    end
end

--- Render a time scale under a chart.
local function render_time_scale(count, interval, content_width)
    local span = count * interval;
    imgui.TextDisabled(fmt_time(span) .. ' ago');
    imgui.SameLine(content_width - 20);
    imgui.TextDisabled('now');
end

local function render_charts()
    if not state.settings.show_charts then return; end

    local h = state.history;
    if h.count < 2 then return; end

    imgui.Text('Memory Over Time');
    help_marker('Historical graphs. Hover for values. Updates every sample interval.');
    imgui.Separator();

    local count = math_min(h.count, CHART_BUFFER_SIZE);
    local chart_height = state.settings.chart_height;
    local content_width = imgui.GetContentRegionAvail();
    local sample_iv = state.settings.sample_interval;

    -- Working set chart ceiling = process virtual limit (LAA or 2 GB)
    local vlimit = math_max(state.current.total_virtual_mb, 1);

    -- Fill working set chart buffer in-place
    for i = 1, count do
        local idx = (h.head - h.count + (h.count - count) + i - 2) % analysis.HISTORY_SIZE + 1;
        ws_chart[i] = h.working_set[idx];
    end

    imgui.PlotLines('##ws_chart', ws_chart, count, 0,
        string_format('Working Set (%.1f / %.0f MB)', state.current.working_set_mb, vlimit),
        0, vlimit,
        { content_width, chart_height });
    render_time_scale(count, sample_iv, content_width);

    -- Fill addon total chart buffer in-place (converted to MB for readable hover tooltips)
    local max_addon = 0;
    for i = 1, count do
        local idx = (h.head - h.count + (h.count - count) + i - 2) % analysis.HISTORY_SIZE + 1;
        local v = h.addon_total[idx] * KB_TO_MB;
        addon_chart[i] = v;
        if v > max_addon then max_addon = v; end
    end

    local total_kb = state.current.addon_total_kb or 0;
    imgui.PlotLines('##addon_chart', addon_chart, count, 0,
        string_format('All Addons (%s)', fmt_mem(total_kb)),
        0, math_max(max_addon * 1.1, 0.1),
        { content_width, chart_height });
    render_time_scale(count, sample_iv, content_width);

    imgui.Spacing();
end

-------------------------------------------------------------------------------
-- Selected Addon Detail
-------------------------------------------------------------------------------
local function render_addon_detail()
    if not state.ui_selected_addon then return; end

    local data = state.addons[state.ui_selected_addon];
    if not data then return; end

    imgui.Separator();
    imgui.Text(string_format('Details: %s', data.name));
    imgui.Indent();

    imgui.Text(string_format('Current: %s', fmt_mem(data.memory_kb)));
    imgui.Text(string_format('Peak: %s', fmt_mem(data.peak_kb)));
    imgui.Text(string_format('Min: %s', fmt_mem(data.min_kb == analysis.MIN_KB_SENTINEL and 0 or data.min_kb)));
    imgui.Text(string_format('Trend: %.3f KB/sec', data.trend_slope));
    if imgui.IsItemHovered() then
        imgui.SetTooltip(
            'Exponential moving average of delta (rate of change).\n' ..
            'Positive = growing, Negative = shrinking.\n' ..
            'Requires 3+ samples for accuracy.\n\n' ..
            'NOTE: Positive trends are often normal. LuaJIT compiles\n' ..
            'hot paths (loops with 56+ iterations, frequent calls)\n' ..
            'into machine code (up to ~2 MB cache). This growth is\n' ..
            'expected behavior, not a leak.'
        );
    end
    imgui.Text(string_format('Samples: %d', data.history_count));

    if data.history_count >= 2 then
        local detail_count = math_min(data.history_count, CHART_BUFFER_SIZE);
        for i = 1, detail_count do
            local idx = (data.history_head - data.history_count + (data.history_count - detail_count) + i - 2)
                        % analysis.ADDON_HISTORY_SIZE + 1;
            addon_detail_chart[i] = data.history[idx] * KB_TO_MB;
        end

        local content_width = imgui.GetContentRegionAvail();
        imgui.PlotLines('##addon_detail', addon_detail_chart, detail_count, 0,
            nil,
            math_max(data.min_kb * KB_TO_MB * 0.9, 0), math_max(data.peak_kb * KB_TO_MB * 1.1, 0.01),
            { content_width, 60 });
        render_time_scale(detail_count, state.settings.addon_poll_interval, content_width);
    end

    imgui.Unindent();
end

-------------------------------------------------------------------------------
-- Settings Window
-------------------------------------------------------------------------------
local function render_settings()
    if not show_settings[1] then return; end

    if imgui.Begin('MemScope Settings', show_settings, ImGuiWindowFlags_AlwaysAutoResize) then
        imgui.Text('Sampling');
        imgui.Separator();

        local v;

        v = { state.settings.sample_interval };
        if imgui.SliderInt('Sample Interval (sec)', v, 1, 30) then
            state.settings.sample_interval = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('How often to read process memory (Working Set, Page File).\nLower = more responsive charts, slightly more CPU.');
        end

        v = { state.settings.addon_poll_interval };
        if imgui.SliderInt('Addon Poll Interval (sec)', v, 5, 120) then
            state.settings.addon_poll_interval = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('How often to query per-addon memory via /addon list.\nOutput is silently captured (hidden from chat).\n5-10s for active monitoring, 30+ for background use.');
        end

        imgui.Spacing();
        imgui.Text('Display');
        imgui.Separator();

        v = { state.settings.show_process_memory };
        if imgui.Checkbox('Show Process Memory', v) then
            state.settings.show_process_memory = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show the Working Set and Page File bars at the top.');
        end

        v = { state.settings.show_addon_breakdown };
        if imgui.Checkbox('Show Addon Breakdown', v) then
            state.settings.show_addon_breakdown = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show the per-addon memory table.');
        end

        v = { state.settings.show_charts };
        if imgui.Checkbox('Show Charts', v) then
            state.settings.show_charts = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Show the historical memory graphs.');
        end

        v = { state.settings.chart_height };
        if imgui.SliderInt('Chart Height', v, 40, 150) then
            state.settings.chart_height = v[1];
            state.settings_save_requested = true;
        end

        v = { state.settings.auto_gc_monitoring };
        if imgui.Checkbox('Auto GC Monitoring', v) then
            state.settings.auto_gc_monitoring = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Track garbage collection events for MemScope\'s own Lua state.\nOther addons have isolated GC — only this addon\'s GC is visible.');
        end

        imgui.Spacing();
        imgui.Text('Alerts');
        help_marker(
            'Alerts notify you in chat about unusual memory patterns.\n' ..
            'Growth: sustained increase detected via EMA of delta.\n' ..
            'Spike: sudden large jump between consecutive polls.\n\n' ..
            'IMPORTANT: These alerts are informational only.\n' ..
            'LuaJIT jits code after 56 loop iterations, which\n' ..
            'causes normal memory growth (up to ~2 MB cache).\n' ..
            'Most alerts are NOT actual leaks — investigate first.'
        );
        imgui.Separator();

        v = { state.settings.alerts_enabled };
        if imgui.Checkbox('Enable Alerts', v) then
            state.settings.alerts_enabled = v[1];
            state.settings_save_requested = true;
        end

        v = { state.settings.growth_threshold };
        if imgui.SliderFloat('Growth Threshold (KB/sec)', v, 1.0, 200.0, '%.1f') then
            state.settings.growth_threshold = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Sustained growth rate that triggers an informational alert.\n' ..
                'Measured via EMA of delta (3+ samples).\n' ..
                'Default 50 KB/s. Higher = fewer notifications.\n\n' ..
                'NOTE: LuaJIT jitting causes normal memory growth.\n' ..
                'Most alerts are false positives — investigate\n' ..
                'before assuming a real leak exists.'
            );
        end

        v = { state.settings.spike_threshold };
        if imgui.SliderFloat('Spike Threshold (%)', v, 25, 200, '%.0f') then
            state.settings.spike_threshold = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Percentage increase between polls that triggers a spike alert.\n' ..
                'Default 100% = memory must double in one poll interval.\n' ..
                'Also requires minimum absolute change (see below).'
            );
        end

        v = { state.settings.spike_min_kb or 512 };
        if imgui.SliderFloat('Spike Min Change (KB)', v, 64, 2048, '%.0f') then
            state.settings.spike_min_kb = v[1];
            state.settings_save_requested = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Minimum absolute KB change required for a spike alert.\n' ..
                'Prevents false alarms from small addons with big %% swings.\n' ..
                'Default 512 KB.'
            );
        end

        imgui.Spacing();
        if defaults and imgui.Button('Restore Defaults') then
            for k, v in pairs(defaults) do
                state.settings[k] = v;
            end
            state.settings_save_requested = true;
        end
        if defaults then imgui.SameLine(); end
        if imgui.Button('Close') then
            show_settings[1] = false;
        end
    end
    imgui.End();
end

-------------------------------------------------------------------------------
-- Compact Mode Window
-------------------------------------------------------------------------------
local function render_compact()
    imgui.SetNextWindowSize({ 280, 0 }, ImGuiCond_FirstUseEver);

    if imgui.Begin('MemScope', is_open, ImGuiWindowFlags_AlwaysAutoResize + ImGuiWindowFlags_NoScrollbar) then
        local c = state.current;
        local vlimit = math_max(c.total_virtual_mb, 1);

        -- Working set bar
        local ws_pct = c.working_set_mb / vlimit;
        local ws_label = string_format('%.0f / %.0f MB', c.working_set_mb, vlimit);
        imgui.ProgressBar(ws_pct, { -1, 0 }, ws_label);
        if imgui.IsItemHovered() then
            imgui.SetTooltip(string_format(
                'Working Set: %.1f MB (Peak: %.1f MB)\n' ..
                'Committed: %.1f MB\n' ..
                'Addons: %s (%d tracked)',
                c.working_set_mb, c.peak_working_set_mb,
                c.pagefile_mb,
                fmt_mem(c.addon_total_kb or 0), #state.addon_order));
        end

        -- Top addons by memory (up to 3)
        local shown = 0;
        for _, name in ipairs(state.addon_order) do
            if shown >= 3 then break; end
            local data = state.addons[name];
            if data and data.status ~= 'Unloaded' then
                shown = shown + 1;
                local trend_icon = '';
                if data.trend_slope > 0.1 then trend_icon = ' ^';
                elseif data.trend_slope < -0.1 then trend_icon = ' v'; end
                imgui.TextDisabled(string_format('  %s: %s%s', data.name, fmt_mem(data.memory_kb), trend_icon));
            end
        end

        -- Buttons
        if imgui.SmallButton(state.paused and 'Resume' or 'Pause') then
            state.paused = not state.paused;
        end
        imgui.SameLine();
        if imgui.SmallButton('Expand') then
            compact_mode = false;
            restore_full_size = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Switch to full dashboard');
        end
    end
    imgui.End();
end

-------------------------------------------------------------------------------
-- Main Window (Full Mode)
-------------------------------------------------------------------------------
local function render_full()
    if reset_pending then
        reset_pending = false;
        restore_full_size = false;
        imgui.SetNextWindowSize({ 460, 520 }, ImGuiCond_Always);
        imgui.SetNextWindowPos({ 100, 100 }, ImGuiCond_Always);
    elseif restore_full_size then
        restore_full_size = false;
        imgui.SetNextWindowSize({ 460, 520 }, ImGuiCond_Always);
    else
        imgui.SetNextWindowSize({ 460, 520 }, ImGuiCond_FirstUseEver);
    end

    if imgui.Begin('MemScope', is_open, ImGuiWindowFlags_NoScrollbar + ImGuiWindowFlags_NoScrollWithMouse) then
        -- Toolbar: [Pause] [Refresh] | [Export] [GC] [Trim] | [Settings] [Compact]  Samples
        if imgui.Button(state.paused and 'Resume' or 'Pause') then
            state.paused = not state.paused;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(state.paused and 'Resume data collection.' or 'Pause data collection for review.');
        end
        imgui.SameLine();
        if imgui.Button('Refresh') then
            state.force_refresh = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Take an immediate snapshot and poll all addons.');
        end
        imgui.SameLine();
        imgui.TextDisabled('|');
        imgui.SameLine();
        if imgui.Button('Export') then
            state.force_export = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Export session data to Excel workbook (.xls).');
        end
        imgui.SameLine();
        if imgui.Button('GC') then
            state.force_gc = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Force Lua garbage collection for MemScope only.\n' ..
                'Each addon has its own isolated Lua state —\n' ..
                'this does NOT affect other addons\' memory.'
            );
        end
        imgui.SameLine();
        if imgui.Button('Trim') then
            state.force_trim = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip(
                'Trim the process working set (from atom0s\'s freemem addon).\n' ..
                'Releases pages Windows is holding onto lazily.\n' ..
                'Win10/11 inflates Working Set — trimming shows\n' ..
                'actual memory usage. Safe; OS pages back as needed.'
            );
        end
        imgui.SameLine();
        imgui.TextDisabled('|');
        imgui.SameLine();
        if imgui.Button('Settings') then
            show_settings[1] = not show_settings[1];
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Configure sampling, display, and alert thresholds.');
        end
        imgui.SameLine();
        if imgui.Button('Compact') then
            compact_mode = true;
        end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Switch to compact overlay.');
        end
        imgui.SameLine();
        imgui.TextDisabled(string_format('| %d', state.history.count));
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Total process memory samples collected this session.');
        end

        imgui.Separator();

        -- Scrollable content area (reserves 26px at bottom for footer)
        imgui.BeginChild('##content', { 0, -26 });
            render_process_memory();
            render_lua_memory();
            render_addon_table();
            render_charts();
            render_addon_detail();
        imgui.EndChild();

        -- Footer (fixed, outside scroll area)
        imgui.Separator();
        local avail_w = imgui.GetContentRegionAvail();
        imgui.SameLine(imgui.GetCursorPosX() + avail_w - 90);
        imgui.PushStyleColor(ImGuiCol_Button, { 0.3, 0.3, 0.3, 1.0 });
        if imgui.Button('Reset UI') then
            reset_pending = true;
        end
        imgui.PopStyleColor();
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Reset window size and position to defaults.');
        end
    end
    imgui.End();

    render_settings();
end

-------------------------------------------------------------------------------
-- Main Render Entry Point
-------------------------------------------------------------------------------
function ui.render()
    if not is_open[1] then return; end

    if compact_mode then
        render_compact();
    else
        render_full();
    end
end

-------------------------------------------------------------------------------
-- Public: Window visibility control
-------------------------------------------------------------------------------
function ui.is_visible()
    return is_open[1];
end

function ui.toggle()
    is_open[1] = not is_open[1];
end

function ui.show()
    is_open[1] = true;
end

function ui.hide()
    is_open[1] = false;
end

function ui.toggle_compact()
    compact_mode = not compact_mode;
    if not compact_mode then
        restore_full_size = true;
    end
end

function ui.reset_ui()
    compact_mode = false;
    reset_pending = true;
end

return ui;
