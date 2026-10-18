#!/usr/bin/env python3
"""Keep Claude's daily token totals beyond the stock seven-day window.

omarchy-agent-usage-claude rebuilds recentDays from ~/.claude/projects on
every run and forgets anything older than a week. This folds each run into a
ledger outside the usage directory (every file there becomes a provider) and
writes the full series back into claude.json as historyDays, the same shape
the Cursor collector produces.

When the widget's synced aggregation is on, the day totals also include the
snapshots other machines (or bin/pull-remote-usage) dropped in syncDir, so
the 90-day chart covers every machine the panel's today/week numbers do.
"""

import importlib.util
import json
import os
import re
import socket
import tempfile
from datetime import date, timedelta
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "omarchy" / "agents"
USAGE_FILE = STATE / "usage" / "claude.json"
LEDGER_FILE = STATE / "history" / "claude.json"
SHELL_JSON = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "omarchy" / "shell.json"
WIDGET_ID = "austraz.agents"


def read_json(path: Path):
  try:
    return json.loads(path.read_text(encoding="utf-8"))
  except (OSError, ValueError):
    return None


def write_json(path: Path, data) -> None:
  path.parent.mkdir(parents=True, exist_ok=True)
  fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="." + path.name + ".")
  with os.fdopen(fd, "w", encoding="utf-8") as handle:
    json.dump(data, handle, separators=(",", ":"))
    handle.write("\n")
  os.replace(tmp, path)


def widget_settings() -> dict:
  data = read_json(SHELL_JSON)
  layout = data.get("bar", {}).get("layout", {}) if isinstance(data, dict) else {}
  for section in layout.values() if isinstance(layout, dict) else []:
    for entry in section if isinstance(section, list) else []:
      if isinstance(entry, dict) and entry.get("id") == WIDGET_ID:
        return entry
  return {}


def expand(path: str) -> Path:
  value = str(path or "").strip()
  if value in ("", "~"):
    return HOME
  if value.startswith("~/"):
    return HOME / value[2:]
  if value.startswith("$HOME/"):
    return HOME / value[6:]
  return Path(value) if value.startswith("/") else HOME / value


def safe_device_id(raw) -> str:
  value = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(raw or "").strip()).strip("._-")
  return value or "device"


def remote_day_tokens() -> dict:
  """Per-date Claude token sums over every synced snapshot but our own.

  Mirrors Main.qml: syncMode on + syncDir set, own file is syncFileName or
  <deviceId>.json, own device id is syncDeviceId or the file stem/hostname.
  """
  settings = widget_settings()
  mode = str(settings.get("syncMode", settings.get("syncEnabled", ""))).strip().lower()
  sync_dir = str(settings.get("syncDir") or "").strip()
  if mode not in ("on", "enabled", "true", "yes", "1") or not sync_dir:
    return {}
  own_device = str(settings.get("syncDeviceId") or "").strip()
  own_file = str(settings.get("syncFileName") or "").strip()
  if not own_file:
    own_file = safe_device_id(own_device or socket.gethostname()) + ".json"
  elif not own_file.lower().endswith(".json"):
    own_file += ".json"
  own_device = safe_device_id(own_device or own_file[:-5])

  totals: dict = {}
  for path in sorted(expand(sync_dir).glob("*.json")):
    if path.name == own_file:
      continue
    snapshot = read_json(path)
    if not isinstance(snapshot, dict):
      continue
    if safe_device_id(snapshot.get("deviceId")) == own_device:
      continue
    claude = (snapshot.get("providers") or {}).get("claude") or {}
    if str(claude.get("scope") or "device") == "account":
      continue
    for row in claude.get("recentDays") or []:
      if not isinstance(row, dict) or not valid_day(row.get("date")):
        continue
      tokens = row.get("messageCount")
      if isinstance(tokens, (int, float)) and tokens >= 0:
        totals[str(row["date"])] = totals.get(str(row["date"]), 0) + int(tokens)
  return totals


def valid_day(value) -> bool:
  try:
    date.fromisoformat(str(value))
    return len(str(value)) == 10
  except ValueError:
    return False


def load_forecast():
  # -I keeps the script's own folder off sys.path, so load the sibling by path.
  path = Path(__file__).resolve().with_name("forecast.py")
  spec = importlib.util.spec_from_file_location("agents_forecast", path)
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  return module


def main() -> None:
  record = read_json(USAGE_FILE)
  if not isinstance(record, dict):
    return
  before = json.dumps(record, sort_keys=True)

  ledger = read_json(LEDGER_FILE)
  days = ledger.get("days") if isinstance(ledger, dict) else None
  if not isinstance(days, dict):
    days = {}

  # recentDays.messageCount is a token total. Keep the highest count seen for
  # a day so transcripts pruned later cannot shrink a day already recorded.
  local = {}
  for row in record.get("recentDays") or []:
    if not isinstance(row, dict) or not valid_day(row.get("date")):
      continue
    tokens = row.get("messageCount")
    if not isinstance(tokens, (int, float)) or tokens < 0:
      continue
    local[str(row["date"])] = int(tokens)

  # Other machines' snapshots add to each day, the same way the panel sums
  # device-scoped stats across devices for today and the last week.
  remote = remote_day_tokens()
  for key in set(local) | set(remote):
    days[key] = max(local.get(key, 0) + remote.get(key, 0), int(days.get(key) or 0))

  if days:
    write_json(LEDGER_FILE, {"schemaVersion": 1, "days": dict(sorted(days.items()))})

    history = []
    day = date.fromisoformat(min(days))
    last = max(date.today(), date.fromisoformat(max(days)))
    while day <= last:
      key = day.isoformat()
      history.append({"date": key, "tokens": int(days.get(key) or 0), "cents": 0})
      day += timedelta(days=1)
    record["historyDays"] = history

  load_forecast().update(record, STATE)

  # Writing claude.json fires claude-usage-history.path again; an unchanged
  # record must not be rewritten or the unit would loop.
  if json.dumps(record, sort_keys=True) == before:
    return
  write_json(USAGE_FILE, record)


if __name__ == "__main__":
  main()
