#!/usr/bin/env python3
"""Forecast where each Claude limit lands when its window resets.

claude_history.py calls update() on every claude.json refresh. It writes a
`forecast` object onto each entry of record["limits"]:

  {"mid": 0.50, "low": 0.45, "high": 0.58, "capAt": "<iso>|''",
   "method": "limits"|"cost", "days": 5}

Two sources feed the same model:

- "limits": the limit percentages themselves, logged at every refresh into
  history/claude-limits.jsonl. Rises between two samples are the burn, in the
  limit's own unit, account-wide (every machine counts). Preferred once the
  log covers MIN_LOG_DAYS.
- "cost": until then, an API-price-weighted cost per hour read from this
  machine's ~/.claude/projects transcripts. Raw tokens are mostly cache reads
  and say little about the quota; price weighting is the closest public
  proxy. The current window's percent / cost calibrates % per dollar.

The model: an expected burn per hour, from the recent days' totals (weekday
and weekend apart, recency-weighted) spread over the hours of the day the way
those days were, summed over the hours left before the reset. The low/high
band rescales that sum by the spread of past days around their mean.

Everything is computed as of record["updatedAt"], never the wall clock, so
re-running on an unchanged claude.json writes the same bytes and the
claude-usage-history.path unit does not loop.
"""

import json
import os
import re
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HOUR = 3600
DAY = 86400
LOG_KEEP_DAYS = 56
PROFILE_DAYS = 28
HALF_LIFE_DAYS = 14
MIN_LOG_DAYS = 3
PROJECTS = Path.home() / ".claude" / "projects"

# $ per million tokens: input, output, cache read. First substring match wins.
# Cache writes bill 1.25x input for the 5-minute TTL and 2x for the 1-hour one.
PRICES = (
  ("fable", 10.0, 50.0, 0.25),
  ("mythos", 10.0, 50.0, 0.25),
  ("opus-5-5", 4.0, 20.0, 0.20),
  ("opus", 5.0, 25.0, 0.50),
  ("sonnet-5", 2.0, 10.0, 0.20),
  ("sonnet", 3.0, 15.0, 0.30),
  ("haiku-5", 0.10, 0.50, 0.01),
  ("haiku", 1.0, 5.0, 0.10),
)
FAMILIES = ("fable", "mythos", "opus", "sonnet", "haiku")


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


def parse_ts(value):
  try:
    stamp = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
  except ValueError:
    return None
  if stamp.tzinfo is None:
    stamp = stamp.replace(tzinfo=timezone.utc)
  return stamp.timestamp()


def iso(ts: float) -> str:
  return datetime.fromtimestamp(ts, timezone.utc).isoformat()


def num(value) -> float:
  return float(value) if isinstance(value, (int, float)) else 0.0


def family(model: str) -> str:
  for name in FAMILIES:
    if name in model:
      return name
  return ""


def limit_family(entry: dict) -> str:
  return family((str(entry.get("label") or "") + " " + str(entry.get("title") or "")).lower())


def limit_span(entry: dict) -> float:
  text = (str(entry.get("label") or "") + " " + str(entry.get("title") or "")).lower()
  if "week" in text or "7-day" in text:
    return 7 * DAY
  hours = re.search(r"(\d+)\s*-?\s*h(?:our)?\b", text)
  if hours:
    return int(hours.group(1)) * HOUR
  return 0.0


# ------------------------------------------------------------------ limit log

def append_log(log_path: Path, now: float, limits: list) -> list:
  """Log this refresh's percentages once, prune old lines, return samples."""
  samples = []
  try:
    with open(log_path, encoding="utf-8") as handle:
      for line in handle:
        try:
          row = json.loads(line)
        except ValueError:
          continue
        if isinstance(row, dict) and isinstance(row.get("l"), dict):
          samples.append((float(row.get("t") or 0), row["l"]))
  except OSError:
    pass

  current = {}
  for entry in limits:
    percent = entry.get("percent")
    if isinstance(entry, dict) and isinstance(percent, (int, float)) and percent >= 0:
      current[str(entry.get("label") or "")] = [float(percent), str(entry.get("resetsAt") or "")]

  cutoff = now - LOG_KEEP_DAYS * DAY
  pruned = bool(samples) and samples[0][0] < cutoff - DAY
  if pruned:
    samples = [s for s in samples if s[0] >= cutoff]
  fresh = current and (not samples or now > samples[-1][0])
  if fresh:
    samples.append((now, current))

  if pruned:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=log_path.parent, prefix="." + log_path.name + ".")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
      for t, row in samples:
        handle.write(json.dumps({"t": t, "l": row}, separators=(",", ":")) + "\n")
    os.replace(tmp, log_path)
  elif fresh:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as handle:
      handle.write(json.dumps({"t": now, "l": current}, separators=(",", ":")) + "\n")
  return samples


def spread(hours: dict, start: float, end: float, amount: float) -> None:
  if amount <= 0:
    return
  if end <= start:
    key = int(end // HOUR) * HOUR
    hours[key] = hours.get(key, 0.0) + amount
    return
  t = start
  while t < end:
    key = int(t // HOUR) * HOUR
    stop = min(key + HOUR, end)
    hours[key] = hours.get(key, 0.0) + amount * (stop - t) / (end - start)
    t = stop


def same_window(a: str, b: str) -> bool:
  ta, tb = parse_ts(a), parse_ts(b)
  if ta is None or tb is None:
    return a == b
  return abs(ta - tb) < 300


def log_hours(samples: list, label: str):
  """Hourly burn of one limit, in its own fraction-of-limit unit."""
  hours = {}
  prev = None
  first = None
  for t, row in samples:
    cur = row.get(label)
    if not isinstance(cur, list) or len(cur) < 2:
      prev = None
      continue
    percent, reset = num(cur[0]), str(cur[1] or "")
    if first is None:
      first = t
    if prev is not None:
      t0, p0, r0 = prev
      if same_window(reset, r0):
        spread(hours, t0, t, max(0.0, percent - p0))
      else:
        # The window rolled over in between: what shows now was burnt after
        # the old reset.
        rolled = parse_ts(r0)
        start = t0 if rolled is None else min(max(t0, rolled), t)
        spread(hours, start, t, percent)
    prev = (t, percent, reset)
  return hours, first


# ------------------------------------------------------------- cost fallback

def message_cost(model: str, usage: dict) -> float:
  price = next((p for p in PRICES if p[0] in model), None)
  if price is None:
    return 0.0
  _, p_in, p_out, p_read = price
  created = usage.get("cache_creation")
  if isinstance(created, dict) and ("ephemeral_5m_input_tokens" in created or "ephemeral_1h_input_tokens" in created):
    write = num(created.get("ephemeral_5m_input_tokens")) * 1.25 + num(created.get("ephemeral_1h_input_tokens")) * 2.0
  else:
    write = num(usage.get("cache_creation_input_tokens")) * 1.25
  return (num(usage.get("input_tokens")) * p_in + write * p_in
          + num(usage.get("output_tokens")) * p_out
          + num(usage.get("cache_read_input_tokens")) * p_read) / 1e6


def scan_transcript(path: Path) -> dict:
  entries = {}
  try:
    with open(path, encoding="utf-8", errors="replace") as handle:
      for line in handle:
        if '"usage"' not in line:
          continue
        try:
          row = json.loads(line)
        except ValueError:
          continue
        message = row.get("message") if isinstance(row, dict) else None
        if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
          continue
        model = str(message.get("model") or "")
        ts = parse_ts(row.get("timestamp"))
        cost = message_cost(model, message["usage"])
        if ts is None or cost <= 0:
          continue
        # One API response is written once per content block; keep one.
        key = str(message.get("id") or "") + ":" + str(row.get("requestId") or "")
        entries[key] = [int(ts), family(model), round(cost, 6)]
  except OSError:
    pass
  return entries


def cost_entries(cache_path: Path, now: float) -> list:
  """[ts, family, cost] per API response from local transcripts, cached by mtime."""
  cache = read_json(cache_path)
  files = cache.get("files") if isinstance(cache, dict) else None
  if not isinstance(files, dict):
    files = {}
  horizon = now - (PROFILE_DAYS + 8) * DAY
  seen = {}
  changed = False
  for path in PROJECTS.rglob("*.jsonl") if PROJECTS.is_dir() else []:
    try:
      stat = path.stat()
    except OSError:
      continue
    if stat.st_mtime < horizon:
      continue
    key = str(path)
    cached = files.get(key)
    if not (isinstance(cached, dict) and cached.get("m") == stat.st_mtime_ns and cached.get("s") == stat.st_size):
      cached = {"m": stat.st_mtime_ns, "s": stat.st_size, "e": scan_transcript(path)}
      changed = True
    seen[key] = cached
  if changed or set(seen) != set(files):
    write_json(cache_path, {"schemaVersion": 1, "files": seen})

  merged = {}
  for cached in seen.values():
    merged.update(cached.get("e") or {})
  return [e for e in merged.values() if horizon <= e[0] < now]


# --------------------------------------------------------------------- model

def local_midnight(ts: float) -> float:
  return datetime.fromtimestamp(ts).replace(hour=0, minute=0, second=0, microsecond=0).timestamp()


def next_midnight(ts: float) -> float:
  day = datetime.fromtimestamp(ts).replace(hour=0, minute=0, second=0, microsecond=0)
  return (day + timedelta(days=1)).timestamp()


def is_weekend(ts: float) -> bool:
  return datetime.fromtimestamp(ts).weekday() >= 5


def weighted_quantile(pairs: list, q: float) -> float:
  """Linear interpolation between weighted midpoints."""
  pairs = sorted(pairs)
  total = sum(w for _, w in pairs)
  if total <= 0:
    return 1.0
  points = []
  acc = 0.0
  for value, weight in pairs:
    points.append(((acc + weight / 2) / total, value))
    acc += weight
  if q <= points[0][0]:
    return points[0][1]
  for (q0, v0), (q1, v1) in zip(points, points[1:]):
    if q <= q1:
      return v0 + (v1 - v0) * (q - q0) / (q1 - q0)
  return points[-1][1]


class Profile:
  """Expected burn per hour, from the finished local days in [start, now)."""

  def __init__(self, hours: dict, start: float, now: float):
    days = []
    day = start if local_midnight(start) == start else next_midnight(start)
    day = max(day, local_midnight(now - PROFILE_DAYS * DAY))
    today = local_midnight(now)
    while day < today:
      end = next_midnight(day)
      by_hour = [0.0] * 24
      h = day
      while h < end:
        by_hour[datetime.fromtimestamp(h).hour] += hours.get(int(h // HOUR) * HOUR, 0.0)
        h += HOUR
      age = (now - end) / DAY
      days.append({"weekend": is_weekend(day), "hours": by_hour, "total": sum(by_hour),
                   "w": 0.5 ** (age / HALF_LIFE_DAYS)})
      day = end
    self.days = len(days)

    weight = sum(d["w"] for d in days)
    mean = sum(d["w"] * d["total"] for d in days) / weight if weight > 0 else 0.0
    share_all = self._share(days, None, mean)
    self.mean = {}
    self.share = {}
    raw = {}
    for weekend in (False, True):
      group = [d for d in days if d["weekend"] == weekend]
      w = sum(d["w"] for d in group)
      raw[weekend] = sum(d["w"] * d["total"] for d in group) / w if len(group) >= 2 and w > 0 else 0.0
      # One pseudo-day of the overall mean keeps a type with one sample sane.
      self.mean[weekend] = (sum(d["w"] * d["total"] for d in group) + mean) / (w + 1.0)
      self.share[weekend] = self._share(group, share_all, mean)

    # Spread around each day type's own mean. A type seen once always sits on
    # its mean and one that never burns has no spread: neither says anything.
    ratios = [(d["total"] / raw[d["weekend"]], d["w"]) for d in days if raw[d["weekend"]] > 0]
    if len(ratios) >= 3:
      self.low, self.high = weighted_quantile(ratios, 0.25), weighted_quantile(ratios, 0.75)
    else:
      self.low, self.high = 0.5, 1.5

  @staticmethod
  def _share(days: list, prior, mean: float) -> list:
    """Each hour's share of a day, shrunk toward the prior (uniform at top)."""
    if prior is None:
      prior, strength = [1.0 / 24] * 24, 0.5 * mean
    else:
      strength = 2.0 * mean
    sums = [0.0] * 24
    total = 0.0
    for d in days:
      for i in range(24):
        sums[i] += d["w"] * d["hours"][i]
      total += d["w"] * d["total"]
    if total + strength <= 0:
      return list(prior)
    return [(sums[i] + strength * prior[i]) / (total + strength) for i in range(24)]

  def expected(self, ts: float) -> float:
    weekend = is_weekend(ts)
    return self.mean[weekend] * self.share[weekend][datetime.fromtimestamp(ts).hour]


def project(percent: float, now: float, reset: float, profile: Profile, scale: float):
  cum = 0.0
  cap = None
  t = now
  while t < reset:
    stop = min(int(t // HOUR) * HOUR + HOUR, reset)
    burn = profile.expected(t) * (stop - t) / HOUR * scale
    if cap is None and percent < 1.0 and burn > 0 and percent + cum + burn >= 1.0:
      cap = t + (1.0 - percent - cum) / burn * (stop - t)
    cum += burn
    t = stop
  return {
    "mid": round(percent + cum, 4),
    "low": round(percent + cum * profile.low, 4),
    "high": round(percent + cum * profile.high, 4),
    "capAt": iso(cap) if cap is not None else "",
  }


# ---------------------------------------------------------------------- entry

def update(record: dict, state_dir: Path) -> None:
  limits = record.get("limits")
  now = parse_ts(record.get("updatedAt"))
  if not isinstance(limits, list) or now is None:
    return
  samples = append_log(state_dir / "history" / "claude-limits.jsonl", now, limits)
  entries = None

  for entry in limits:
    if not isinstance(entry, dict):
      continue
    entry.pop("forecast", None)
    percent = entry.get("percent")
    reset = parse_ts(entry.get("resetsAt"))
    if not isinstance(percent, (int, float)) or percent < 0 or reset is None or reset <= now:
      continue

    hours, first = log_hours(samples, str(entry.get("label") or ""))
    if first is not None and now - first >= MIN_LOG_DAYS * DAY:
      profile = Profile(hours, first, now)
      if profile.days >= MIN_LOG_DAYS:
        entry["forecast"] = dict(project(float(percent), now, reset, profile, 1.0),
                                 method="limits", days=profile.days)
        continue

    span = limit_span(entry)
    if span <= 0 or percent < 0.02:
      continue
    if entries is None:
      entries = cost_entries(state_dir / "history" / "claude-cost-cache.json", now)
    fam = limit_family(entry)
    profile, in_window = cost_profile([e for e in entries if e[1] == fam], now, reset - span) if fam else (None, 0)
    if profile is None or profile.days < MIN_LOG_DAYS:
      # A model with too short a past borrows the all-models profile. Scaling
      # by the all-models window cost assumes its share of the burn holds.
      profile, in_window = cost_profile(entries, now, reset - span)
    if profile is None or profile.days < 1:
      continue
    entry["forecast"] = dict(project(float(percent), now, reset, profile, float(percent) / in_window),
                             method="cost", days=profile.days)


def cost_profile(entries: list, now: float, window_start: float):
  in_window = sum(e[2] for e in entries if e[0] >= window_start)
  if not entries or in_window <= 0:
    return None, 0.0
  cost_hours = {}
  for ts, _, cost in entries:
    key = int(ts // HOUR) * HOUR
    cost_hours[key] = cost_hours.get(key, 0.0) + cost
  start = max(min(e[0] for e in entries), now - PROFILE_DAYS * DAY)
  return Profile(cost_hours, start, now), in_window
