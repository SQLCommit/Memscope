--[[
    MemScope v1.0.1 - Monitor Module
    FFI for Windows memory APIs, /addon list capture, GC monitoring.
]]--

local ffi = require 'ffi';

local monitor = {};

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------
local BYTES_TO_MB = 1 / (1024 * 1024);
local BYTES_TO_KB = 1 / 1024;
local CAPTURE_TIMEOUT = 2.0;
local MAX_CAPTURE = 64;

-------------------------------------------------------------------------------
-- Cached References
-------------------------------------------------------------------------------
local collectgarbage = collectgarbage;
local tonumber = tonumber;
local os_clock = os.clock;

-------------------------------------------------------------------------------
-- Module State (set via init)
-------------------------------------------------------------------------------
local state = nil;
local process_handle = nil;
local mem_counters = nil;
local ffi_available = false;

-- Capture state for /addon list interception
local capture = {
    active = false,
    start_time = 0,
    callback = nil,
    results = {},
    result_count = 0,
    debug = false,
    debug_count = 0,
    seen_data = false,       -- true after first ">>" format data line
};

-- Debug log buffer (flushed from d3d_present, never from text_in)
local debug_log = {};
local debug_log_count = 0;
local MAX_DEBUG_LOG = 80;

--- Buffer a debug line (NEVER print from inside text_in — causes recursion crash).
local function dbg(msg)
    if debug_log_count < MAX_DEBUG_LOG then
        debug_log_count = debug_log_count + 1;
        debug_log[debug_log_count] = msg;
    end
end

-- Pre-allocate capture result entries
for i = 1, MAX_CAPTURE do
    capture.results[i] = { name = '', status = '', memory_kb = 0 };
end

-------------------------------------------------------------------------------
-- FFI Definitions (Windows Memory APIs)
-------------------------------------------------------------------------------
local mem_status = nil;
local mem_status_available = false;

local function define_ffi()
    local ok, err = pcall(function()
        ffi.cdef[[
            typedef unsigned long DWORD;
            typedef unsigned long long DWORDLONG;
            typedef size_t SIZE_T;
            typedef void* HANDLE;
            typedef int BOOL;

            typedef struct {
                DWORD  cb;
                DWORD  PageFaultCount;
                SIZE_T PeakWorkingSetSize;
                SIZE_T WorkingSetSize;
                SIZE_T QuotaPeakPagedPoolUsage;
                SIZE_T QuotaPagedPoolUsage;
                SIZE_T QuotaPeakNonPagedPoolUsage;
                SIZE_T QuotaNonPagedPoolUsage;
                SIZE_T PagefileUsage;
                SIZE_T PeakPagefileUsage;
            } PROCESS_MEMORY_COUNTERS;

            typedef struct {
                DWORD     dwLength;
                DWORD     dwMemoryLoad;
                DWORDLONG ullTotalPhys;
                DWORDLONG ullAvailPhys;
                DWORDLONG ullTotalPageFile;
                DWORDLONG ullAvailPageFile;
                DWORDLONG ullTotalVirtual;
                DWORDLONG ullAvailVirtual;
                DWORDLONG ullAvailExtendedVirtual;
            } MEMORYSTATUSEX;

            HANDLE GetCurrentProcess(void);
            BOOL K32GetProcessMemoryInfo(HANDLE Process, PROCESS_MEMORY_COUNTERS* ppsmemCounters, DWORD cb);
            BOOL GlobalMemoryStatusEx(MEMORYSTATUSEX* lpBuffer);

            // Working set trim — from atom0s's freemem addon.
            // Passing (-1, -1) tells Windows to trim the working set to its minimum,
            // releasing pages the OS is holding onto lazily. Shows actual memory usage
            // vs Win10/11 inflated values.
            BOOL SetProcessWorkingSetSize(HANDLE hProcess, SIZE_T dwMinimumWorkingSetSize, SIZE_T dwMaximumWorkingSetSize);
        ]];
    end);
    return ok;
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------
function monitor.init(shared_state)
    state = shared_state;

    -- Initialize FFI with safety
    local ok = define_ffi();
    if ok then
        local pok, _ = pcall(function()
            process_handle = ffi.C.GetCurrentProcess();
            mem_counters = ffi.new('PROCESS_MEMORY_COUNTERS');
            mem_counters.cb = ffi.sizeof('PROCESS_MEMORY_COUNTERS');
        end);
        ffi_available = pok;
    end

    -- Initialize system memory query struct
    if ffi_available then
        local sok, _ = pcall(function()
            mem_status = ffi.new('MEMORYSTATUSEX');
            mem_status.dwLength = ffi.sizeof('MEMORYSTATUSEX');
        end);
        mem_status_available = sok;
    end

    -- Initialize GC state
    state.gc = {
        last_count = collectgarbage('count'),
        collections = 0,
        freed_kb = 0,
    };
end

-------------------------------------------------------------------------------
-- Process Memory Query (FFI)
-------------------------------------------------------------------------------
function monitor.query_process_memory()
    if not ffi_available then return false; end

    if ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb) ~= 0 then
        state.current.working_set_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;
        state.current.peak_working_set_mb = tonumber(mem_counters.PeakWorkingSetSize) * BYTES_TO_MB;
        state.current.pagefile_mb = tonumber(mem_counters.PagefileUsage) * BYTES_TO_MB;
        state.current.peak_pagefile_mb = tonumber(mem_counters.PeakPagefileUsage) * BYTES_TO_MB;
        return true;
    end
    return false;
end

-------------------------------------------------------------------------------
-- System Memory Query (FFI)
-------------------------------------------------------------------------------
function monitor.query_system_memory()
    if not mem_status_available then return false; end

    if ffi.C.GlobalMemoryStatusEx(mem_status) ~= 0 then
        state.current.total_phys_mb = tonumber(mem_status.ullTotalPhys) * BYTES_TO_MB;
        state.current.avail_phys_mb = tonumber(mem_status.ullAvailPhys) * BYTES_TO_MB;
        state.current.total_pagefile_mb = tonumber(mem_status.ullTotalPageFile) * BYTES_TO_MB;
        state.current.avail_pagefile_mb = tonumber(mem_status.ullAvailPageFile) * BYTES_TO_MB;
        state.current.total_virtual_mb = tonumber(mem_status.ullTotalVirtual) * BYTES_TO_MB;
        state.current.avail_virtual_mb = tonumber(mem_status.ullAvailVirtual) * BYTES_TO_MB;
        state.current.memory_load_pct = tonumber(mem_status.dwMemoryLoad);
        return true;
    end
    return false;
end

-------------------------------------------------------------------------------
-- Lua Memory Query
-------------------------------------------------------------------------------
function monitor.query_lua_memory()
    -- This addon's own Lua state only (not global)
    state.current.own_lua_kb = collectgarbage('count');

    -- This addon's tracked memory via Ashita API
    if addon.instance then
        state.current.own_memory_kb = addon.instance:get_memory_usage() * BYTES_TO_KB;
    end
end

-------------------------------------------------------------------------------
-- Working Set Trim
-- Technique from atom0s's freemem addon (Ashita built-in).
-- SetProcessWorkingSetSize(-1, -1) forces Windows to release pages it is
-- holding onto lazily. Win10/11 inflates Working Set values — trimming shows
-- the actual memory footprint. Safe to call; the OS will page back in as needed.
-------------------------------------------------------------------------------
function monitor.trim_working_set()
    if not ffi_available then return 0, 0; end

    -- Read working set before trim
    ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb);
    local before_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;

    -- Trim
    ffi.C.SetProcessWorkingSetSize(process_handle, -1, -1);

    -- Read working set after trim
    ffi.C.K32GetProcessMemoryInfo(process_handle, mem_counters, mem_counters.cb);
    local after_mb = tonumber(mem_counters.WorkingSetSize) * BYTES_TO_MB;

    return before_mb, after_mb;
end

-------------------------------------------------------------------------------
-- GC Monitoring
-------------------------------------------------------------------------------
function monitor.monitor_gc()
    if not state.settings.auto_gc_monitoring then return; end

    local current_count = collectgarbage('count');
    if current_count < state.gc.last_count then
        state.gc.collections = state.gc.collections + 1;
        state.gc.freed_kb = state.gc.last_count - current_count;
    end
    state.gc.last_count = current_count;
end

-------------------------------------------------------------------------------
-- /addon list Capture System
--
-- Uses plain substring detection (string.find with plain=true) for reliable
-- blocking, then targeted pattern extraction for data. Strips all non-ASCII
-- control bytes to handle FFXI color codes of any format.
-------------------------------------------------------------------------------

--- Strip all non-printable control bytes from a string.
--- Removes any byte < 0x20 (space) or = 0x7F (DEL) and the byte following
--- color escape bytes 0x1E/0x1F. Also strips high-byte Shift-JIS lead bytes
--- that could interfere with matching.
local function strip_controls(s)
    -- First pass: strip two-byte color sequences (\x1E\xNN and \x1F\xNN)
    local r = s:gsub('\x1e.', ''):gsub('\x1f.', '');
    -- Second pass: strip any remaining control chars (< 0x20 except \n)
    r = r:gsub('[%z\1-\9\11-\31\127]', '');
    return r;
end

--- Start an async capture of /addon list output.
--- The callback receives (results_table, count) when complete.
function monitor.start_addon_capture(callback)
    if capture.active then return; end

    capture.active = true;
    capture.result_count = 0;
    capture.start_time = os_clock();
    capture.callback = callback;
    capture.debug = false;
    capture.seen_data = false;

    -- Inject command silently (type 1 = injected, no echo)
    AshitaCore:GetChatManager():QueueCommand(1, '/addon list');
end

--- Start a debug capture that writes diagnostics to debug.log file.
function monitor.start_debug_capture()
    if capture.active then
        print('[MemScope DEBUG] Capture already active, aborting.');
        return;
    end

    -- Open debug log file (overwrite)
    local log_path = ('%s\\addons\\memscope\\debug.log'):format(AshitaCore:GetInstallPath());
    local f = io.open(log_path, 'w');
    if f then
        f:write('MemScope Debug Capture Log\n');
        f:write('==========================\n\n');
        f:close();
    end

    capture.active = true;
    capture.result_count = 0;
    capture.start_time = os_clock();
    capture.callback = function(results, count)
        -- Write results to log file
        local lf = io.open(log_path, 'a');
        if lf then
            lf:write(string.format('\n=== CAPTURE COMPLETE: %d addons found ===\n', count));
            for i = 1, count do
                lf:write(string.format('  [%d] %s = %.2f KB (%s)\n',
                    i, results[i].name, results[i].memory_kb, results[i].status));
            end
            lf:close();
        end
        dbg(string.format('[DEBUG] Capture complete: %d addons found. See debug.log', count));
        for i = 1, math.min(count, 5) do
            dbg(string.format('  [%d] %s = %.2f KB (%s)',
                i, results[i].name, results[i].memory_kb, results[i].status));
        end
    end;
    capture.debug = true;
    capture.debug_count = 0;
    capture.seen_data = false;

    print('[MemScope DEBUG] Debug capture started. Results go to debug.log');

    AshitaCore:GetChatManager():QueueCommand(1, '/addon list');
end

--- Returns true if a capture is currently in progress.
function monitor.is_capturing()
    return capture.active;
end

--- Called from d3d_present to check for capture timeout.
function monitor.check_capture_timeout()
    if capture.active and (os_clock() - capture.start_time > CAPTURE_TIMEOUT) then
        monitor.finish_capture();
    end
end

--- Helper: convert a string to its hex byte representation (for debug).
local function to_hex(s)
    local out = {};
    for i = 1, math.min(#s, 80) do
        out[#out + 1] = string.format('%02X', s:byte(i));
    end
    return table.concat(out, ' ');
end

--- Write a line to the debug.log file (only during debug captures).
local function debug_file(msg)
    if not capture.debug then return; end
    local log_path = ('%s\\addons\\memscope\\debug.log'):format(AshitaCore:GetInstallPath());
    local f = io.open(log_path, 'a');
    if f then
        f:write(msg .. '\n');
        f:close();
    end
end

--- Process a text_in event line. Returns true if the line should be blocked.
--- e.blocked = true DOES suppress /addon list output from chat.
---
--- Only blocks during active capture — normal addon messages (load/unload
--- notifications) pass through. The first poll after load may leak once;
--- all subsequent polls are silently captured.
function monitor.process_text_in(message)
    if not message or #message == 0 then return false; end

    -- Only intercept during active capture — let all other messages through
    if not capture.active then return false; end

    local clean = strip_controls(message);

    -- Debug: write every message to debug.log
    if capture.debug then
        capture.debug_count = capture.debug_count + 1;
        debug_file(string.format('[MSG %d] raw_len=%d hex=%s',
            capture.debug_count, #message, to_hex(message)));
        debug_file(string.format('[MSG %d] clean="%s"',
            capture.debug_count, clean:sub(1, 200)));
    end

    -- 1) Addon data line: ">>" prefix with "Memory"
    --    Format: [Addons]   >> name version X.X - by: author - State: Ok - Memory: X.XX MB
    if clean:find('>>', 1, true) and clean:find('Memory', 1, true) then
        capture.seen_data = true;

        -- Extract name: first word after ">>"
        local name = clean:match('>>%s+(%S+)');
        -- Extract memory value and unit (KB or MB)
        local mem_val, mem_unit = clean:match('([%d%.]+)%s*(%a+)%s*$');
        if not mem_val then
            mem_val, mem_unit = clean:match('Memory:%s*([%d%.]+)%s*(%a+)');
        end
        local status = clean:match('State:%s*(%w+)') or 'Running';

        -- Convert to KB
        local mem_kb = 0;
        if mem_val then
            mem_kb = tonumber(mem_val) or 0;
            if mem_unit and mem_unit:upper() == 'MB' then
                mem_kb = mem_kb * 1024;
            end
        end

        debug_file(string.format('[DATA] name=%s mem_val=%s unit=%s mem_kb=%.2f status=%s',
            tostring(name), tostring(mem_val), tostring(mem_unit), mem_kb, tostring(status)));

        if name and mem_val then
            local n = capture.result_count + 1;
            if n <= MAX_CAPTURE then
                local entry = capture.results[n];
                entry.name = name;
                entry.status = status;
                entry.memory_kb = mem_kb;
                capture.result_count = n;
            end
        end
        return true;
    end

    -- 2) Footer: "Total loaded addons" — finishes capture if we've seen data
    if clean:find('Total loaded addons', 1, true) then
        debug_file(string.format('[FOOTER] seen_data=%s result_count=%d',
            tostring(capture.seen_data), capture.result_count));
        if capture.seen_data then
            monitor.finish_capture();
            return true;
        end
        return true;  -- Block but don't finish (startup notification)
    end

    -- 3) "Loaded addon:" startup notification — block during capture
    if clean:find('Loaded addon', 1, true) then
        return true;
    end

    -- 4) Header/separator line containing "[Addons]" — block during capture
    if clean:find('[Addons]', 1, true) then
        return true;
    end

    return false;
end

--- Flush buffered debug log lines (call from d3d_present, NOT text_in).
function monitor.flush_debug_log()
    if debug_log_count == 0 then return; end
    for i = 1, debug_log_count do
        print(debug_log[i]);
        debug_log[i] = nil;
    end
    debug_log_count = 0;
end

--- Complete the capture and fire the callback.
function monitor.finish_capture()
    capture.active = false;
    -- After active=false, process_text_in returns false (no blocking)
    if capture.callback then
        capture.callback(capture.results, capture.result_count);
        capture.callback = nil;
    end
end

return monitor;
