"""Schedule storage + fire-time logic for saunad.

The iOS app edits schedules and syncs them here; saunad runs the loop (app.py) that
actually fires them, so they work whether or not a phone is around. Mirrors the app's
ScheduleEngine rules (Swift) — keep the two in step.

Persisted to <state>/schedules.json, where <state> is $SAUNAD_STATE, else /state (a
writable volume on the Pi), else a local .state dir. options.json is read-only, so
schedules get their own writable file.
"""
import json
import logging
import os
from datetime import datetime, timedelta
from typing import Optional

from pydantic import BaseModel, Field

log = logging.getLogger("saunad.sched")

# Assumed cold-cabin temp when estimating a "ready by" lead with no live reading.
ASSUMED_AMBIENT_F = 70

_STATE_CANDIDATES = [
    os.environ.get("SAUNAD_STATE"),
    "/state",
    os.path.join(os.path.dirname(__file__), ".state"),
]


class Schedule(BaseModel):
    id: str
    enabled: bool = True
    hour: int = Field(6, ge=0, le=23)
    minute: int = Field(30, ge=0, le=59)
    # Weekdays this repeats on, 1..7 with 1=Sunday (Apple Calendar convention, matching
    # the app). Empty list = a one-time schedule (see onceDate).
    weekdays: list[int] = []
    onceDate: Optional[float] = None       # one-time: epoch seconds of the day to fire
    turnOn: bool = True                    # True = power on + heat (apply fields); False = off
    readyBy: bool = False                  # hour:minute is when target is REACHED (preheat earlier)
    autoPreheat: bool = True               # learned lead (heat rate) vs the manual preheatLeadMin
    preheatLeadMin: int = 45
    targetTempF: Optional[int] = 150
    chromoColor: Optional[str] = "White"
    timerMin: Optional[int] = None


class SchedulePayload(BaseModel):
    schedules: list[Schedule] = []
    heatRatePerMin: float = 2.5            # synced from the app's HeatingModel, for "ready by"


_schedules: list[Schedule] = []
_heat_rate: float = 2.5


def _state_dir() -> str:
    for p in _STATE_CANDIDATES:
        if p and os.path.isdir(p):
            return p
    d = _STATE_CANDIDATES[-1]
    os.makedirs(d, exist_ok=True)
    return d


def _file() -> str:
    return os.path.join(_state_dir(), "schedules.json")


def state_dir() -> str:
    """Public accessor for the writable state directory, so app.py can keep its own
    persisted state (the armed timer) alongside schedules.json on the same volume."""
    return _state_dir()


def load() -> None:
    """Load persisted schedules at startup (no-op if none stored yet)."""
    global _schedules, _heat_rate
    try:
        with open(_file()) as f:
            p = SchedulePayload(**json.load(f))
        _schedules, _heat_rate = p.schedules, p.heatRatePerMin
        log.info("loaded %d schedule(s), heat rate %.2f F/min", len(_schedules), _heat_rate)
    except FileNotFoundError:
        _schedules, _heat_rate = [], 2.5
    except Exception as e:  # corrupt file shouldn't crash the bridge
        log.warning("schedule load failed (%s); starting empty", e)
        _schedules, _heat_rate = [], 2.5


def save(payload: SchedulePayload) -> None:
    """Replace the stored schedules + heat rate (atomic write)."""
    global _schedules, _heat_rate
    _schedules, _heat_rate = payload.schedules, payload.heatRatePerMin
    tmp = _file() + ".tmp"
    with open(tmp, "w") as f:
        json.dump(payload.model_dump(), f)
    os.replace(tmp, _file())
    log.info("stored %d schedule(s), heat rate %.2f F/min", len(_schedules), _heat_rate)


def current() -> list[Schedule]:
    return _schedules


def as_payload() -> SchedulePayload:
    return SchedulePayload(schedules=_schedules, heatRatePerMin=_heat_rate)


def _lead_minutes(s: Schedule, current_temp: Optional[int]) -> int:
    """Preheat lead for a 'ready by' schedule: learned from heat rate when auto, else the
    manual lead; 0 when not 'ready by'. Mirrors ScheduleEngine.leadMinutes (Swift)."""
    if not s.readyBy or not s.turnOn:
        return 0
    if not s.autoPreheat:
        return s.preheatLeadMin
    target = s.targetTempF or 150
    cur = current_temp if current_temp is not None else ASSUMED_AMBIENT_F
    delta = max(0, target - cur)
    mins = delta / max(0.5, _heat_rate)
    return max(5, min(180, round(mins)))


def start_dt(s: Schedule, day: datetime, current_temp: Optional[int]) -> Optional[datetime]:
    """The moment heating should start on `day`, or None if the schedule doesn't apply /
    is disabled. For 'ready by' this is the target time minus the live-recomputed lead."""
    if not s.enabled:
        return None
    if not s.weekdays:  # one-time
        if s.onceDate is None:
            return None
        if datetime.fromtimestamp(s.onceDate).date() != day.date():
            return None
    else:
        # Python isoweekday(): Mon=1..Sun=7 → Apple weekday: Sun=1..Sat=7.
        swift_wd = (day.isoweekday() % 7) + 1
        if swift_wd not in s.weekdays:
            return None
    anchor = day.replace(hour=s.hour, minute=s.minute, second=0, microsecond=0)
    lead = _lead_minutes(s, current_temp)
    return anchor - timedelta(minutes=lead) if lead else anchor
