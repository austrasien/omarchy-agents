#!/usr/bin/env python3
"""Keep Claude's daily token totals beyond the stock seven-day window.

omarchy-agent-usage-claude rebuilds recentDays from ~/.claude/projects on
every run and forgets anything older than a week. This folds each run into a
ledger outside the usage directory (every file there becomes a provider) and
writes the full series back into claude.json as historyDays, the same shape
the Cursor collector produces.
"""

import json
import os
import tempfile
from datetime import date, timedelta
from pathlib import Path

STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "omarchy" / "agents"
USAGE_FILE = STATE / "usage" / "claude.json"
LEDGER_FILE = STATE / "history" / "claude.json"


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


def valid_day(value) -> bool:
  try:
    date.fromisoformat(str(value))
    return len(str(value)) == 10
  except ValueError:
    return False


def main() -> None:
  record = read_json(USAGE_FILE)
  if not isinstance(record, dict):
    return

  ledger = read_json(LEDGER_FILE)
  days = ledger.get("days") if isinstance(ledger, dict) else None
  if not isinstance(days, dict):
    days = {}

  # recentDays.messageCount is a token total. Keep the highest count seen for
  # a day so transcripts pruned later cannot shrink a day already recorded.
  for row in record.get("recentDays") or []:
    if not isinstance(row, dict) or not valid_day(row.get("date")):
      continue
    tokens = row.get("messageCount")
    if not isinstance(tokens, (int, float)) or tokens < 0:
      continue
    key = str(row["date"])
    days[key] = max(int(tokens), int(days.get(key) or 0))

  if not days:
    return
  write_json(LEDGER_FILE, {"schemaVersion": 1, "days": dict(sorted(days.items()))})

  history = []
  day = date.fromisoformat(min(days))
  last = max(date.today(), date.fromisoformat(max(days)))
  while day <= last:
    key = day.isoformat()
    history.append({"date": key, "tokens": int(days.get(key) or 0), "cents": 0})
    day += timedelta(days=1)

  if record.get("historyDays") == history:
    return
  record["historyDays"] = history
  write_json(USAGE_FILE, record)


if __name__ == "__main__":
  main()
