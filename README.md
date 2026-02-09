# MemScope v1.0.0 - Memory Monitoring Addon for Ashita v4

A comprehensive memory monitoring tool that tracks per-addon memory usage, process memory, and provides leak detection with historical analysis.

## Features

- **Process Memory Tracking** - Working set, page file, and peak usage via Windows APIs (FFI)
- **Per-Addon Memory Breakdown** - Polling via `/addon list` capture with silent interception
- **Historical Trends** - Ring buffer storage with configurable history (720 process samples, 120 per addon)
- **Leak Detection** - EMA (exponential moving average) of delta to detect sustained memory growth
- **Spike Detection** - Alerts on sudden memory increases (% threshold + minimum absolute change)
- **GC Monitoring** - Track garbage collection events and freed memory
- **ImGui Dashboard** - Real-time visualization with charts, sortable tables, and compact mode
- **Export to Excel** - Session data exported as `.xls` with multiple worksheet tabs
- **Pre-allocated Buffers** - Ring buffers, object pools, cached chart data (zero per-frame allocation)

## Requirements

- Ashita v4.30
	- This release has only been tested with Ashita v4.3


## Installation

1. Copy the `memscope` folder to your Ashita `addons` directory
2. Load with `/addon load memscope`

## Commands

| Command | Description |
|---------|-------------|
| `/memscope` | Toggle the main window |
| `/memscope show` | Show the window |
| `/memscope hide` | Hide the window |
| `/memscope compact` | Toggle compact overlay mode |
| `/memscope pause` | Pause/resume data collection |
| `/memscope snapshot` | Take a manual memory snapshot |
| `/memscope report` | Print memory report to chat |
| `/memscope export` | Export session data to Excel (.xls) |
| `/memscope gc` | Force garbage collection |
| `/memscope alerts [on/off]` | Toggle leak/spike alerts |
| `/memscope resetui` | Reset window size and position to defaults |
| `/memscope debug` | Debug addon list capture (writes to debug.log) |
| `/memscope help` | Show command help |

## File Structure

```
memscope/
  memscope.lua   -- Entry point, events, commands, state, export
  monitor.lua    -- FFI + /addon list capture + GC monitoring
  analysis.lua   -- Ring buffers, trend/leak/spike analysis, addon pool
  ui.lua         -- ImGui dashboard rendering
  README.md      -- This file
  LICENSE        -- MIT License
  exports/       -- Exported .xls files (gitignored)
```

Settings are managed by Ashita's settings module and saved per-character under `config/addons/memscope/<CharName>_<ID>/settings.lua`.

## Dashboard Sections

### Process Memory
- **Working Set** - Physical RAM pages mapped into the process
- **Committed** - Virtual memory committed (RAM + swap reserved)
- Progress bars show usage vs the process virtual address limit (2 GB or 4 GB with LAA)
- Hover for peak values, deltas, and system memory info

### Lua Memory
- MemScope's own Lua state memory
- All loaded addons combined total (from `/addon list`)
- GC collection statistics (count and last freed amount)

### Addon Breakdown
Sortable, scrollable table (click column headers to sort). Displays up to 10 rows before scrolling, with frozen header row:
- **Name** - Addon name (color-coded: red=leak alert, green=self)
- **Memory** - Current memory usage
- **Status** - Running/Ok/Unloaded
- **Delta** - Memory change per second (green=decreasing, red=increasing)
- **Trend** - UP/DOWN/FLAT based on EMA of delta

Click any row for detailed stats and mini-chart. Right-click unloaded addons to remove from tracking.

### Memory Charts
- Process working set over time
- All addons combined total over time (displayed in MB)
- Time scale shown below each chart

### Compact Mode
Minimal overlay showing just the working set bar, top 3 addons, and pause/expand buttons. Toggle via the Compact button or `/memscope compact`. Window size restores automatically when expanding back to full mode.

### Reset UI
Use the **Reset UI** button (bottom-right) or `/memscope resetui` to restore the window to its default size and position.

## Alert System

### Leak Detection
Triggers when an addon shows sustained memory growth:
- Default threshold: 10.0 KB/sec
- Uses EMA (exponential moving average) of delta for responsive trend tracking
- Requires 3+ samples before trend calculation begins

### Spike Detection
Triggers on sudden memory jumps:
- Default threshold: 100% increase between polls
- Also requires minimum absolute change (default 512 KB)
- Prevents false alarms from small addons with large percentage swings

## Export

`/memscope export` creates a SpreadsheetML `.xls` file in the `exports/` directory. Opens natively in Excel and LibreOffice with multiple worksheet tabs:

- **Session** - Metadata (date, duration, LAA status, system RAM) + addon summary table
- **Process Timeline** - Full process memory history with timestamps
- **Addons Timeline** - Wide format with one column per addon (all addons side-by-side)
- **Per-Addon Tabs** - One tab per addon with metadata header, timeline, deltas, and change-from-start

## Settings

Access via the **Settings** button in the dashboard:

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| Sample Interval | 5 sec | 1-30 | How often to collect process memory data |
| Addon Poll Interval | 30 sec | 5-120 | How often to query per-addon memory via /addon list |
| Show Process Memory | true | | Display process memory bars |
| Show Addon Breakdown | true | | Display addon table |
| Show Charts | true | | Display history charts |
| Chart Height | 80 px | 40-150 | Height of chart widgets |
| Enable Alerts | true | | Show leak/spike warnings in chat |
| Leak Threshold | 10.0 KB/s | 1-200 | Sustained growth rate for leak alert |
| Spike Threshold | 100% | 25-200 | Sudden increase percentage for spike alert |
| Spike Min Change | 512 KB | 64-2048 | Minimum absolute change for spike alert |
| Auto GC Monitoring | true | | Track garbage collection events |

## Technical Notes

### Addon List Capture

Per-addon memory data comes from silently injecting `/addon list` and intercepting the chat output in the `text_in` event. The capture system:
- Pre-allocates result buffer (no per-capture allocation)
- Strips FFXI color codes before pattern matching
- Uses `seen_data` flag to avoid premature footer detection from startup notifications
- Timeout safety (2 seconds) prevents hanging on missed footer
- Only blocks chat lines during active capture; normal addon notifications pass through

Note: `AddonManager` API exists in annotations but is only accessible from C++ plugins, not Lua addons.

### Memory Data Sources

| Metric | Source | Scope |
|--------|--------|-------|
| Working Set | K32GetProcessMemoryInfo (FFI) | Entire FFXI process |
| Page File | K32GetProcessMemoryInfo (FFI) | Entire FFXI process |
| System RAM | GlobalMemoryStatusEx (FFI) | System-wide |
| Own Lua State | collectgarbage('count') | This addon's Lua VM only |
| Own Tracked | addon.instance:get\_memory\_usage() | This addon only |
| Per-Addon | /addon list capture | All loaded addons |

### Performance Design
- **Ring buffers**: O(1) push, fixed-size, no reallocation after init
- **Object pool**: 64 pre-allocated addon tracking slots, no GC pressure
- **Chart buffers**: Pre-allocated arrays filled in-place each frame
- **Action flags**: UI sets flags, d3d_present processes them (decouples rendering from logic)
- **Safe text_in**: Never print() from text_in handler (causes recursive crash); uses debug buffer flushed from d3d_present

## Version History

### v1.0.0
- Split into 4 files (memscope, monitor, analysis, ui)
- Per-addon memory tracking via /addon list capture with silent interception
- Process memory monitoring via Windows FFI (working set, page file)
- EMA trend analysis with leak/spike detection and alerts
- Historical ring buffers (720 process samples, 120 per addon)
- Compact overlay mode with automatic window size restore on expand
- Pause/resume data collection
- Export to Excel (.xls) with multiple worksheet tabs
- Scrollable addon table (10-row max with frozen headers) with sorting and right-click context menu
- Reset UI button and `/memscope resetui` command
- Debug capture mode for troubleshooting
- Pre-allocated chart buffers, action flag decoupling
- Per-character settings via Ashita's settings module
- Uses Ashita `chat` module for standard colored output

## Thanks

- **Ashita Team** - atom0s, thorny, and the [Ashita Discord](https://discord.gg/Ashita) community

## License

MIT License - See LICENSE file
