--[[
    MemScope v1.0.0 - Analysis Engine
    Ring buffers, trend analysis, leak/spike detection, addon pool management.
]]--

local analysis = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local HISTORY_SIZE = 720;
local ADDON_HISTORY_SIZE = 120;
local MAX_TRACKED_ADDONS = 64;
local MIN_SAMPLES_FOR_TREND = 3;
local TREND_ALPHA = 0.3;  -- EMA weight: 0.3 = responsive, 0.1 = smooth

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local math_max = math.max;
local math_min = math.min;
local os_time = os.time;
local string_format = string.format;
local table_sort = table.sort;

-------------------------------------------------------------------------------
-- Module State (set via init)
-------------------------------------------------------------------------------
local state = nil;

-------------------------------------------------------------------------------
-- Public Constants (for other modules)
-------------------------------------------------------------------------------
analysis.HISTORY_SIZE = HISTORY_SIZE;
analysis.ADDON_HISTORY_SIZE = ADDON_HISTORY_SIZE;
analysis.MAX_TRACKED_ADDONS = MAX_TRACKED_ADDONS;
analysis.MIN_SAMPLES_FOR_TREND = MIN_SAMPLES_FOR_TREND;

-------------------------------------------------------------------------------
-- Ring Buffer Operations (zero allocation after init)
-------------------------------------------------------------------------------
function analysis.ring_push(ring, value, max_size)
    ring[ring.head] = value;
    ring.head = ring.head % max_size + 1;
    if ring.count < max_size then
        ring.count = ring.count + 1;
    end
end

function analysis.ring_get(ring, index, max_size)
    if index < 1 or index > ring.count then return nil; end
    local actual = (ring.head - ring.count + index - 2) % max_size + 1;
    return ring[actual];
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function analysis.init(shared_state)
    state = shared_state;

    -- Sort state (tracked so prune_and_sort respects current sort)
    state.sort_col = 1;      -- default: Memory
    state.sort_asc = false;   -- default: descending

    -- Pre-allocate process memory history ring buffers
    state.history = {
        working_set = {},
        pagefile = {},
        addon_total = {},
        timestamps = {},
        head = 1,
        count = 0,
    };
    for i = 1, HISTORY_SIZE do
        state.history.working_set[i] = 0;
        state.history.pagefile[i] = 0;
        state.history.addon_total[i] = 0;
        state.history.timestamps[i] = 0;
    end

    -- Addon tracking
    state.addons = {};
    state.addon_order = {};
    state.addon_pool = {};
    state.pool_index = 1;

    -- Pre-allocate addon data pool
    for i = 1, MAX_TRACKED_ADDONS do
        state.addon_pool[i] = {
            name = '',
            memory_kb = 0,
            status = 'Unknown',
            peak_kb = 0,
            min_kb = 999999,
            last_delta = 0,
            trend_slope = 0,
            history = {},
            history_head = 1,
            history_count = 0,
            last_update = 0,
            alert_active = false,
        };
        for j = 1, ADDON_HISTORY_SIZE do
            state.addon_pool[i].history[j] = 0;
        end
    end

    -- Alerts ring buffer
    state.alerts = {};
    state.alert_head = 1;
    state.alert_count = 0;
    state.max_alerts = 20;
    for i = 1, state.max_alerts do
        state.alerts[i] = {
            time = 0,
            addon_name = '',
            alert_type = '',
            message = '',
        };
    end
end

-------------------------------------------------------------------------------
-- Addon Data Management
-------------------------------------------------------------------------------
local function get_or_create_addon_data(name)
    local data = state.addons[name];
    if not data then
        if state.pool_index > MAX_TRACKED_ADDONS then
            return nil;
        end
        data = state.addon_pool[state.pool_index];
        state.pool_index = state.pool_index + 1;

        data.name = name;
        data.memory_kb = 0;
        data.status = 'Unknown';
        data.peak_kb = 0;
        data.min_kb = 999999;
        data.last_delta = 0;
        data.trend_slope = 0;
        data.history_head = 1;
        data.history_count = 0;
        data.last_update = 0;
        data.alert_active = false;

        state.addons[name] = data;
        state.addon_order[#state.addon_order + 1] = name;
    end
    return data;
end

-------------------------------------------------------------------------------
-- Alert System
-------------------------------------------------------------------------------
local function add_alert(addon_name, alert_type, message)
    local alert = state.alerts[state.alert_head];
    alert.time = os_time();
    alert.addon_name = addon_name;
    alert.alert_type = alert_type;
    alert.message = message;

    state.alert_head = state.alert_head % state.max_alerts + 1;
    if state.alert_count < state.max_alerts then
        state.alert_count = state.alert_count + 1;
    end

    if state.settings.alerts_enabled then
        local chat = state.chat;
        if chat then
            print(chat.header('MemScope') .. chat.warning(string_format('%s: %s', addon_name, message)));
        else
            print(string_format('\30\02[MemScope]\30\01 %s: %s', addon_name, message));
        end
    end
end

local function check_addon_alerts(data)
    if not state.settings.alerts_enabled then return; end

    -- Leak detection (sustained growth)
    if data.trend_slope > state.settings.leak_threshold then
        if not data.alert_active then
            data.alert_active = true;
            add_alert(data.name, 'leak',
                string_format('Potential leak: %.2f KB/sec sustained growth', data.trend_slope));
        end
    else
        data.alert_active = false;
    end

    -- Spike detection (requires both % threshold AND minimum absolute change)
    if data.history_count >= 2 then
        local prev_idx = (data.history_head - 2) % ADDON_HISTORY_SIZE + 1;
        local prev = data.history[prev_idx];
        if prev > 0 then
            local abs_change = data.memory_kb - prev;
            local pct_change = (abs_change / prev) * 100;
            local min_abs = state.settings.spike_min_kb or 512;
            if pct_change > state.settings.spike_threshold and abs_change > min_abs then
                add_alert(data.name, 'spike',
                    string_format('Memory spike: %.1f%% increase (%.2f -> %.2f KB)',
                        pct_change, prev, data.memory_kb));
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Public: Update addon tracking data
-------------------------------------------------------------------------------
function analysis.update_addon(name, memory_kb, status_val)
    local data = get_or_create_addon_data(name);
    if not data then return; end

    local now = os_time();
    local old_memory = data.memory_kb;

    data.memory_kb = memory_kb;
    data.status = status_val;
    data.peak_kb = math_max(data.peak_kb, memory_kb);
    data.min_kb = math_min(data.min_kb, memory_kb);

    if data.last_update > 0 then
        local dt = now - data.last_update;
        if dt > 0 then
            data.last_delta = (memory_kb - old_memory) / dt;
        end
    end
    data.last_update = now;

    -- Push to per-addon history
    data.history[data.history_head] = memory_kb;
    data.history_head = data.history_head % ADDON_HISTORY_SIZE + 1;
    if data.history_count < ADDON_HISTORY_SIZE then
        data.history_count = data.history_count + 1;
    end

    -- Trend: EMA of delta (directly tracks rate of change, very responsive)
    if data.history_count >= MIN_SAMPLES_FOR_TREND then
        data.trend_slope = data.trend_slope * (1 - TREND_ALPHA) + data.last_delta * TREND_ALPHA;
    end

    check_addon_alerts(data);
end

-------------------------------------------------------------------------------
-- Public: Push to process memory history
-------------------------------------------------------------------------------
function analysis.push_history(ws_mb, pf_mb, addon_total_kb)
    local h = state.history;
    h.working_set[h.head] = ws_mb;
    h.pagefile[h.head] = pf_mb;
    h.addon_total[h.head] = addon_total_kb;
    h.timestamps[h.head] = os_time();

    h.head = h.head % HISTORY_SIZE + 1;
    if h.count < HISTORY_SIZE then
        h.count = h.count + 1;
    end
end

-------------------------------------------------------------------------------
-- Public: Mark absent addons as Unloaded (preserving history), then sort
-------------------------------------------------------------------------------
function analysis.prune_and_sort(current_names)
    -- Build lookup set from current poll results
    local present = {};
    for i = 1, #current_names do
        present[current_names[i]] = true;
    end

    -- Mark absent addons as Unloaded (keep history for analysis)
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and not present[name] and data.status ~= 'Unloaded' then
            data.status = 'Unloaded';
            data.memory_kb = 0;
            data.last_delta = 0;
            -- Push 0 to history so the chart shows the unload event
            data.history[data.history_head] = 0;
            data.history_head = data.history_head % ADDON_HISTORY_SIZE + 1;
            if data.history_count < ADDON_HISTORY_SIZE then
                data.history_count = data.history_count + 1;
            end
        end
    end

    -- Re-sort using current sort state
    analysis.sort_addons(state.sort_col, state.sort_asc);
end

-------------------------------------------------------------------------------
-- Public: Sort addons by column (unloaded always at bottom)
-- col_id: 0=Name, 1=Memory, 2=Status, 3=Delta, 4=Trend
-- ascending: true = A-Z / low-high, false = Z-A / high-low
-------------------------------------------------------------------------------
analysis.SORT_NAME   = 0;
analysis.SORT_MEMORY = 1;
analysis.SORT_STATUS = 2;
analysis.SORT_DELTA  = 3;
analysis.SORT_TREND  = 4;

function analysis.sort_addons(col_id, ascending)
    table_sort(state.addon_order, function(a, b)
        local da = state.addons[a];
        local db_data = state.addons[b];
        if not da or not db_data then return false; end

        -- Unloaded always at bottom regardless of sort
        local a_loaded = da.status ~= 'Unloaded';
        local b_loaded = db_data.status ~= 'Unloaded';
        if a_loaded ~= b_loaded then
            return a_loaded;
        end

        local va, vb;
        if col_id == 0 then         -- Name
            va, vb = da.name:lower(), db_data.name:lower();
        elseif col_id == 1 then     -- Memory
            va, vb = da.memory_kb, db_data.memory_kb;
        elseif col_id == 2 then     -- Status
            va, vb = da.status, db_data.status;
        elseif col_id == 3 then     -- Delta
            va, vb = da.last_delta, db_data.last_delta;
        elseif col_id == 4 then     -- Trend
            va, vb = da.trend_slope, db_data.trend_slope;
        else
            va, vb = da.memory_kb, db_data.memory_kb;
        end

        if ascending then
            return va < vb;
        else
            return va > vb;
        end
    end);
end

-------------------------------------------------------------------------------
-- Public: Remove a specific addon from tracking
-------------------------------------------------------------------------------
function analysis.remove_addon(name)
    -- Remove from lookup table
    state.addons[name] = nil;

    -- Remove from ordered list
    local new_order = {};
    for _, n in ipairs(state.addon_order) do
        if n ~= name then
            new_order[#new_order + 1] = n;
        end
    end
    state.addon_order = new_order;
end

-------------------------------------------------------------------------------
-- Public: Calculate total addon memory
-------------------------------------------------------------------------------
function analysis.get_addon_total_kb()
    local total = 0;
    for _, name in ipairs(state.addon_order) do
        local data = state.addons[name];
        if data and data.status ~= 'Unloaded' then
            total = total + data.memory_kb;
        end
    end
    return total;
end

return analysis;
