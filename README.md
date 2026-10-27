# Agents

One bar icon and one panel for every AI coding subscription on the machine.
The panel is strictly a display: it watches the usage records that
`omarchy-agent-usage-update` writes to `~/.local/state/omarchy/agents/usage/`
and draws whatever appears there. `Panel.qml` owns the bar button and the
popup; `Main.qml` discovers and watches the records (and handles the optional
cross-device aggregation); `Agent.qml` is the per-record file watcher.

## Panel

- **Hero** — the mark, the tool, and the plan it runs on ("Max 20x", "Pro").
  Auth and endpoint problems replace the plan line and repeat in a card.
- **Subscription switch** — one chip per enabled agent (`h`/`l` or click).
  It appears only when more than one agent is enabled.
- **Limits** — the percentage of each allowance used, a matching meter, and
  each window's own reset (weekday and time for windows longer than a day).
  Claude limits also show where the window lands at the usual pace: the
  meter runs on to the projection, then fainter to the busy-day bound, in a
  green → yellow → orange → red ink set by the projection; the line under it
  reads "Usual pace → 47% (42–54%)", or the time the cap would be hit.
- **Balance** — prepaid agents report a credit ledger instead of limits:
  remaining credit, a fuel-gauge meter that drains toward empty, and
  funded-versus-spent detail.
- **Last 90 days** (Claude) — one bar per day of tokens, month names
  underneath, total on the right. No cap or projection: Claude limits
  are 5-hour and weekly percentages, not a monthly allowance. Needs the
  history watcher below.
- **Tokens by day** — one row per day for the last week: day, bar, tokens, with today
  bolded at the bottom. A gold, silver or bronze cup marks a day on the last
  30 days' podium. Hover today for its prompt and session count.
- **Tokens by model** — tokens per model with the bar behind each row scaled
  to the heaviest model,
  the same way the weekly chart scales to its busiest day. Hover for the
  input / output / cache split.

A subscription appears only when it is enabled in settings and has actually
recorded usage — on this machine or on a synced one. With one such agent
there is no switch row at all; with none, the module leaves the bar entirely
rather than sitting there with nothing to say. A CLI installed mid-session
shows up at the next refresh, so nothing polls the disk waiting for it.

That self-hiding is why the widget ships in the default bar layout: a machine
that has never run an AI coding agent draws nothing, and the icon arrives on
its own the first time a scan finds usage. Drop it with
`omarchy plugin disable omarchy.agents`.

## Data

Each agent is one JSON record in `~/.local/state/omarchy/agents/usage/`,
written by `omarchy-agent-usage-update`. That command runs one
`omarchy-agent-usage-<agent>` collector per agent; the widget invokes it
on its refresh timer and whenever you ask for a refresh, and picks up any
record that lands in the directory regardless of who wrote it.

Adding an agent therefore never touches this plugin: ship a collector that
prints the record contract (see the `claude` and `codex` collectors in
`bin/`), and the panel gains a tab. An `assets/<id>.svg` mark is optional —
with an `assets/<id>-light.svg` twin if the mark needs a dark variant for
light surfaces — and the bar glyph stands in when there is none.

| Collector | Limits | Local stats |
|---|---|---|
| `claude` | Anthropic's OAuth usage endpoint (5-hour session + 7-day weekly) | `~/.claude/projects` transcripts, opencode sessions on an Anthropic provider, plus `stats-cache.json` and `history.jsonl` as fallback |
| `codex` | The Codex app-server RPC | native Codex CLI session files (plus pi and opencode sessions) |
| `fireworks` | Estimated prepaid balance: configured funding minus rated account costs | Fireworks billing API, grouped by day and model for the last 30 days |

Claude limits need a signed-in CLI; without credentials the panel says so and
falls back to local stats only. A non-default Claude directory is honored via
`CLAUDE_CONFIG_DIR`, Codex via `CODEX_HOME`. Fireworks reads
`FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID` first, then
`~/.fireworks/auth.ini` (which `firectl set-api-key` creates), then the key
opencode stores in `~/.local/share/opencode/auth.json` when Fireworks is
signed in there.

### Fireworks balance

The collector first asks the account's `:getBalance` endpoint for the real
prepaid ledger. That endpoint exists but is permission-gated, and as of
August 2026 no console-issued API key passes it — Fireworks appears to
reserve it for the dashboard session. The probe stays because it is cheap
and the live figure lights up automatically if Fireworks ever opens it to
keys. Until then the collector falls back to estimating the balance from
configuration in `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

Set `fundedAmount` to the credits purchased and optionally `fundedAt` to the
purchase date; with no date, the collector uses the account creation time. It
subtracts rated account costs and the panel labels the result as estimated.
For a later top-up, increase `fundedAmount` by the new credit while keeping
the original `fundedAt`, so both the funding and spend still cover the same
period. `accountId` only matters when one API key can access several
accounts. Without a configured `fundedAmount` the tab still shows token
usage, just no balance. With a live ledger, `fundedAmount` is optional and
only adds the meter and the spent-of-funded line under the real figure.

### Claude history

The stock Claude collector rebuilds the last seven days from transcripts on
every run and forgets everything older. `claude_history.py` merges each run into
`~/.local/state/omarchy/agents/history/claude.json`, keeping the highest count
seen per day so pruned transcripts never shrink a recorded day, and writes the
full series back into the record as `historyDays`. A systemd path unit runs it
whenever `claude.json` changes, whoever wrote it:

```sh
cd ~/.config/omarchy/plugins/austraz.agents
systemctl --user link "$PWD/systemd/claude-usage-history.service"
systemctl --user enable --now "$PWD/systemd/claude-usage-history.path"
```

History starts the day the watcher is enabled; earlier days only appear while
they are still in the seven-day window.

### Claude limit forecast

The same run calls `forecast.py`, which adds a `forecast` object
(`mid`, `low`, `high`, `capAt`, `method`, `days`) to each Claude limit:

- **Limit log** — every refresh appends the limit percentages to
  `history/claude-limits.jsonl` (kept 8 weeks). Rises between samples are the
  burn in the limit's own unit, account-wide, so every machine counts. Used
  once the log covers 3 days.
- **Profile** — the expected burn per hour is the recent days' total
  (weekdays and weekends apart, half-life 14 days) spread over the hours of
  the day the way those days were, summed until the reset. The band rescales
  that sum by the quieter and busier quarter of past days.
- **Until then** — an API-price-weighted cost per hour from this machine's
  transcripts (cache reads weigh a fraction of fresh input), calibrated to
  percent by the current window. The panel marks it "est.".

Everything is computed as of the record's `updatedAt`, so an unchanged
`claude.json` is never rewritten and the path unit does not loop.

### Minimap band

`minimap-band/` is a rim band for [austraz.minimap](https://github.com/austrasien/omarchy-minimap):
link it as the minimap's `bands/ai`
(`ln -s ~/.config/omarchy/plugins/austraz.agents/minimap-band ~/.config/omarchy/plugins/austraz.minimap/bands/ai`).
It reads `usage/claude.json` and fetches nothing.

- Three gauges apart from the clock around them, each labelled in the gap
  before it and filling clockwise to its own 100 %, read on a 12-hour face:
  the week (`7j`) from ten to two over the top, the 5-hour session (`5h`)
  from two to six, the week's Fable share (`F`) from six to ten.
- In each: the share used, then a pale arc on to the forecast at the reset
  (`forecast.mid`), and a notch for how much of the window has gone by; past
  the notch, the pace would not last.
- Neutral while the forecast stays under 80 %, amber over it, red when the
  limit would be hit before the reset.
- Hover a gauge: its details in the minimap's middle circle (used, forecast
  or "plein vers" the cap time, reset). Click: this panel.
- A gauge turning red blinks and shows its details for a few seconds, once
  per window; those already red when the shell starts stay quiet. Data older
  than 15 minutes fades the band and sends no alert.

## Interactions

- Bar icon: left = panel, right = launch agent, middle = next subscription.
- Panel: `h`/`l` switch subscription, `j`/`k` scroll, `r` or Enter refresh,
  Tab moves to the neighboring bar panel, Esc closes.
- IPC: `omarchy-shell omarchy.agents <open|close|toggle|refresh|next>`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. The
top-level keys can be set with
`omarchy bar set omarchy.agents <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the usage records regenerate |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |
| `remoteHosts` | `""` | SSH destinations whose usage `bin/pull-remote-usage` fetches (see Remote machines) |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set omarchy.agents refreshIntervalSec 300 --json
omarchy bar set omarchy.agents syncDir '~/Sync/agent-usage'
```

Per-agent enablement is nested, and `set` writes its key literally rather
than walking a dotted path — so pass the whole `providers` object as JSON (or
edit `shell.json` directly):

```bash
omarchy bar set omarchy.agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": false },
  "fireworks": { "enabled": true }
}' --json
```

`enabled` defaults to `true` for every discovered agent; set it to `false` to
hide a subscription that is installed. Disabled agents are also skipped when
the records regenerate.

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. Rate limits stay
per-account and are never merged. A record may declare `"scope": "account"`
when its stats are account-global rather than machine-local (Fireworks'
billing API); those merge by taking the widest value instead of summing, so
the same account synced from two machines is not counted twice.

One caveat on "all-time": the Codex collector only reads native session files
touched in the last 30 days, and Fireworks requests the last 30 days from its
billing API, so their totals and day counts cover that window. Claude's cover
every transcript still on disk.

### Remote machines

Agents running on a headless server never write a transcript on this
machine, and a server without an Omarchy shell never writes a sync snapshot.
`bin/pull-remote-usage` closes that gap from here: for every SSH destination
in the `remoteHosts` setting it runs `omarchy-agent-usage-update` on the
remote, reads the records it produced, and writes `<syncDir>/<host>.json` in
the same shape the widget's own `localSnapshot()` produces. With `syncMode`
on, the panel merges it like any other device, and `claude_history.py` folds
the remote days into the 90-day chart. The shell also rescans `syncDir` after
each of its own refreshes, so a fresh snapshot shows up within one interval.

```sh
omarchy bar set austraz.agents syncMode On
omarchy bar set austraz.agents syncDir '~/.local/state/omarchy/agents/sync'
omarchy bar set austraz.agents remoteHosts 'myserver'
cd ~/.config/omarchy/plugins/austraz.agents
systemctl --user link "$PWD/systemd/agents-remote-usage.service"
systemctl --user enable --now "$PWD/systemd/agents-remote-usage.timer"
journalctl --user -u agents-remote-usage.service -n 5
```

The remote needs Omarchy's `omarchy-agent-usage-update` on its PATH and the
SSH connection must work non-interactively (agent, passphrase-less key, or a
persistent ControlMaster socket). An unreachable host keeps its last snapshot
until the next 10-minute run. Note the IPC target stays `omarchy.agents` even
though the plugin id is `austraz.agents`.
