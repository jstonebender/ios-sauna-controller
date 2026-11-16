"""saunad — local bridge for the Finnmark FD-5 infrared sauna.

Owns the single Tuya LAN connection (sauna.py), exposes a small HTTP API for the
ember iOS app, controls the 'Sauna' Sonos (sonos.py), and pushes Live Activity
updates via APNs (apns.py). Runs natively (systemd) on the Homebridge Pi, or in Docker.
"""
import asyncio
import contextlib
import logging
import time
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

import config
import schedules
from sauna import SaunaClient
from sonos import SonosController
from datetime import datetime, timedelta

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("saunad")

# Runtime singletons — constructed in lifespan (no import-time I/O).
sauna: Optional[SaunaClient] = None
sonos: Optional[SonosController] = None
apns = None
_api_key: Optional[str] = None
_heater_max_on_sec: Optional[int] = None
_poll_interval = 5.0
_debug_enabled = False

# In-memory state
_activity_tokens: set[str] = set()
_push_to_start_token: Optional[str] = None
_session: Optional[dict] = None
_last_pushed_content: Optional[dict] = None
_last_push_at = 0.0
_heater_on_since: Optional[float] = None
_alerted_interruption: Optional[float] = None

# Timer end-action: what to do when the running heat timer reaches 0. Armed when the
# app sets a timer; applied by the watchdog at timer-0; cleared on power-off / timer-off.
_timer_end_action: Optional[dict] = None     # {"mode","color","waitMin"}
_timer_end_armed = False                     # a commanded countdown is running, not yet ended
_timer_end_deadline: Optional[float] = None  # wall-clock moment the timer should reach 0
_power_off_at: Optional[float] = None        # wait-mode: when to cut power after the heat ends
_timer_pending_min: Optional[int] = None     # timer set below target: counts only once at temp


def _at_temp(cur: Optional[int], tgt: Optional[int]) -> bool:
    """Has the cabin reached target (within the app's ~2°F 'ready' margin)? No target to wait
    for → treat as at-temp; unknown temp → not yet (wait for a reading)."""
    if tgt is None:
        return True
    if cur is None:
        return False
    return cur >= tgt - 2

# Schedule firing: id -> the ISO date it last fired, so a schedule fires once per day even
# though its start window spans several scheduler ticks.
_sched_fired: dict[str, str] = {}

STALE_AFTER_SEC = 120
KEEPALIVE_SEC = 90  # re-push before the Live Activity goes stale, even if temp unchanged


# ---------- request models ----------
class EndActionBody(BaseModel):
    """What saunad does when the heat timer reaches 0, as one sequence: cut the heater,
    optionally change the light, hold power for a delay, then power off."""
    changeLight: bool = False                        # switch the light at timer end?
    color: str = "Blue"                              # FD-5 light, used when changeLight
    powerOffDelayMin: int = Field(0, ge=0, le=90)    # minutes to stay powered, then off (0 = now)


class ControlBody(BaseModel):
    power: Optional[bool] = None
    heater: Optional[bool] = None
    targetTempF: Optional[int] = Field(None, ge=86, le=170)   # FD-5 setpoint range
    timerMin: Optional[int] = Field(None, ge=0, le=90)
    chromoColor: Optional[str] = None   # FD-5 light: White, Red, …, Scroll, Off
    timerEndAction: Optional[EndActionBody] = None   # applied when the timer above runs out


class AudioBody(BaseModel):
    action: str
    volume: Optional[int] = Field(None, ge=0, le=100)


class TokenBody(BaseModel):
    pushToken: str


# ---------- auth ----------
async def require_auth(authorization: Optional[str] = Header(None)):
    """Bearer-token gate on mutating endpoints. Disabled if server.apiKey is unset."""
    if _api_key is None:
        return
    if authorization != f"Bearer {_api_key}":
        raise HTTPException(401, "unauthorized")


async def require_debug():
    """Hide the /debug/* routes unless server.debugEndpoints is true (default off)."""
    if not _debug_enabled:
        raise HTTPException(404, "not found")


# ---------- lifespan ----------
@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    global sauna, sonos, apns, _api_key, _heater_max_on_sec, _poll_interval, _debug_enabled
    opts = config.load()
    s = opts["sauna"]
    srv = opts.get("server", {})
    _api_key = srv.get("apiKey") or None
    if _api_key and _api_key.startswith("CHANGE-ME"):
        raise RuntimeError(
            "server.apiKey is still the example placeholder. Set a real random key "
            "(python3 -c 'import secrets; print(secrets.token_urlsafe(32))'), or null to disable auth.")
    _debug_enabled = bool(srv.get("debugEndpoints", False))
    _poll_interval = float(srv.get("pollIntervalSec", 5))
    mins = srv.get("heaterMaxOnMinutes")
    _heater_max_on_sec = int(mins) * 60 if mins else None

    sauna = SaunaClient(ip=s["ip"], dev_id=s["devId"], local_key=s["localKey"],
                        version=float(s.get("version", 3.5)), poll_interval=_poll_interval)
    scfg = opts.get("sonos", {})
    sonos = SonosController(scfg.get("name", "Sauna"), ip=scfg.get("ip"))
    acfg = opts.get("apns", {})
    if acfg.get("enabled"):
        from apns import APNsClient
        apns = APNsClient(key_id=acfg["keyId"], team_id=acfg["teamId"], p8_path=acfg["p8Path"],
                          bundle_id=acfg["bundleId"], sandbox=acfg.get("sandbox", True))

    await sauna.start()
    schedules.load()
    tasks = [asyncio.create_task(_push_loop()),
             asyncio.create_task(_heater_watchdog()),
             asyncio.create_task(_scheduler_loop())]
    log.info("saunad started (sauna %s, APNs %s, auth %s, deadman %s)",
             s["ip"], "on" if apns else "off", "on" if _api_key else "OFF",
             f"{_heater_max_on_sec // 60}min" if _heater_max_on_sec else "off")
    if not _api_key:
        log.warning("AUTH OFF: /control and other mutating routes are open to anyone who can "
                    "reach this port — including powering on the heater. Set server.apiKey.")
    try:
        yield
    finally:
        for t in tasks:
            t.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await t
        await sauna.stop()
        if apns:
            await apns.close()


app = FastAPI(title="saunad", lifespan=lifespan)


# ---------- endpoints ----------
@app.get("/health")
async def health():
    return {"ok": True, "online": sauna.state()["online"] if sauna else False}


@app.get("/state")
async def get_state():
    st = sauna.state()
    if _session:
        st["session"] = {"active": True, "startedAt": _session["start"],
                         "elapsedSec": int(time.time() - _session["start"])}
    st["timerEndAction"] = _timer_end_action if _timer_end_armed else None
    if _timer_pending_min is not None:
        st["timerSetMin"] = _timer_pending_min   # show the configured duration during preheat
        st["timerPending"] = True                # set, but not counting until at temp
    return st


@app.get("/debug/raw", dependencies=[Depends(require_debug), Depends(require_auth)])
async def debug_raw():
    r = sauna._raw if sauna else {}
    items = sorted(r.items(), key=lambda kv: int(kv[0]) if str(kv[0]).isdigit() else 999)
    return {"raw": {k: str(v) for k, v in items}, "online": sauna._online if sauna else False}


@app.post("/debug/set", dependencies=[Depends(require_debug), Depends(require_auth)])
async def debug_set(body: dict):
    try:
        return await sauna.set_dp(str(body["dp"]), body["value"])
    except KeyError:
        raise HTTPException(400, "need {dp, value}")
    except Exception:
        log.exception("debug_set failed")
        raise HTTPException(502, "set failed")


@app.post("/control", dependencies=[Depends(require_auth)])
async def control(body: ControlBody):
    st = sauna.state()
    try:
        started = body.power is True and body.heater is True
        # power first: powering on resets the timer to 80 min and the lights to White,
        # so the timer/color in the same request must land after it
        if started:
            st = await sauna.start_heating()
        elif body.power is not None:
            st = await sauna.set_power(body.power)
        if body.targetTempF is not None:
            st = await sauna.set_target_temp(body.targetTempF)
        if body.timerMin is not None:
            # Arm the end-action on INTENT, BEFORE the (sometimes flaky) device write — so a
            # Tuya write the FD-5 ignores can't lose it. saunad fires the end-action off its
            # own deadline, so it holds even if the device never accepted the timer.
            _arm_timer_end(body.timerMin, body.timerEndAction)
            # Program the FD-5's own timer only when it's counting now; a pending (temp-gated)
            # timer gets set on the device once the watchdog sees target reached.
            if body.timerMin == 0 or _timer_pending_min is None:
                st = await sauna.set_timer(body.timerMin)
        if body.heater is not None and not started:
            st = await sauna.set_heater(body.heater)
        if body.chromoColor is not None:
            st = await sauna.set_light(body.chromoColor)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        log.exception("control failed")
        raise HTTPException(502, "sauna control failed")
    # reflect commanded power/heater so the response isn't transiently stale;
    # the poll reconciles real device state.
    sauna.overlay_bools(power=body.power, heater=body.heater)
    return sauna.state()


@app.get("/schedules")
async def get_schedules():
    """Return the schedules saunad will fire (the app reads these back after syncing)."""
    return schedules.as_payload().model_dump()


@app.post("/schedules", dependencies=[Depends(require_auth)])
async def put_schedules(body: schedules.SchedulePayload):
    """Replace saunad's schedules + heat rate (the app syncs its whole set on every edit)."""
    schedules.save(body)
    # Keep the "already fired today" record (so a sync during a fire window can't re-fire a
    # schedule that just ran), but drop ids that no longer exist.
    live = {s.id for s in body.schedules}
    for sid in [k for k in _sched_fired if k not in live]:
        del _sched_fired[sid]
    return {"ok": True, "count": len(body.schedules)}


@app.post("/audio", dependencies=[Depends(require_auth)])
async def audio(body: AudioBody):
    try:
        return await sonos.control(body.action, body.volume)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except Exception:
        log.exception("audio failed")
        raise HTTPException(502, "sonos control failed")


@app.get("/audio/state")
async def audio_state():
    """Read-only Sonos snapshot (volume, transport, track) — open like /state."""
    try:
        return await sonos.now_playing()
    except Exception:
        raise HTTPException(502, "sonos unavailable")


@app.post("/session/start", dependencies=[Depends(require_auth)])
async def session_start():
    global _session, _last_pushed_content
    if _session:  # idempotent — don't clobber an active session's accounting
        return {"active": True, "startedAt": _session["start"], "alreadyActive": True}
    _session = {"start": time.time()}
    _last_pushed_content = None  # bust the push dedupe so the Lock-Screen counter appears next tick
    return {"active": True, "startedAt": _session["start"]}


@app.post("/session/end", dependencies=[Depends(require_auth)])
async def session_end():
    global _session, _last_pushed_content
    if not _session:
        raise HTTPException(400, "no active session")
    start = _session["start"]
    end = time.time()
    peak = sauna.peak_since(start)
    _session = None
    _last_pushed_content = None  # bust the push dedupe so the counter clears next tick
    return {"startedAt": start, "endedAt": end, "durationSec": int(end - start), "peakTempF": peak}


@app.post("/activity/token", dependencies=[Depends(require_auth)])
async def register_activity_token(body: TokenBody):
    _activity_tokens.add(body.pushToken)
    # push current state to the new activity immediately so it starts updating right away,
    # instead of waiting for the next temp change / keepalive (fixes the slow-to-start lag).
    if apns and sauna:
        st = sauna.state()
        if st.get("currentTempF") is not None:
            try:
                await apns.update_activity(body.pushToken, _activity_content(st),
                                           priority=10, stale_after_sec=STALE_AFTER_SEC)
            except Exception as e:
                log.warning("immediate activity push failed: %s", e)
    return {"registered": len(_activity_tokens)}


@app.post("/activity/start-token", dependencies=[Depends(require_auth)])
async def register_push_to_start(body: TokenBody):
    global _push_to_start_token
    _push_to_start_token = body.pushToken
    return {"ok": True}


# ---------- background tasks ----------
def _activity_content(st: dict) -> dict:
    """Live Activity ContentState payload — must decode against the iOS ContentState.

    Every key mirrors a stored ContentState property; extra keys are ignored by Codable
    but a null in a non-optional field makes the WHOLE push silently undecodable, so the
    ints/bools are coerced. sessionStartEpoch is plain Unix epoch seconds — never send a
    raw Date: ActivityKit decodes push content-state with a default JSONDecoder
    (reference-date seconds, not epoch), which is a silent off-by-31-years trap.
    """
    return {
        "currentTempF": int(st.get("currentTempF") or 0),
        "targetTempF": int(st.get("targetTempF") or 0),
        "heater": bool(st.get("heater")),
        "power": bool(st.get("power")),
        "chromoColor": st.get("chromoColor"),
        "sessionStartEpoch": _session["start"] if _session else None,
    }


async def _push_loop():
    """Push state to Live Activities whenever anything they render changes,
    plus a keep-alive before stale."""
    global _last_pushed_content, _last_push_at
    while True:
        try:
            await asyncio.sleep(_poll_interval)
            if not apns or not _activity_tokens:
                continue
            st = sauna.state()
            await _alert_interruption(st)
            if st.get("currentTempF") is None:
                continue
            now = time.time()
            content = _activity_content(st)
            if content == _last_pushed_content and (now - _last_push_at) < KEEPALIVE_SEC:
                continue
            sent_ok = False
            dead: set[str] = set()
            for tok in list(_activity_tokens):
                try:
                    status, text = await apns.update_activity(
                        tok, content, priority=5, stale_after_sec=STALE_AFTER_SEC)
                    sent_ok = sent_ok or status == 200
                    if status == 410 or (status == 400 and
                                         ("BadDeviceToken" in text or "DeviceTokenNotForTopic" in text)):
                        dead.add(tok)
                except Exception as e:
                    log.warning("APNs send failed for %s…: %s", tok[:8], e)
            _activity_tokens.difference_update(dead)
            if sent_ok:  # only advance dedupe after a successful round
                _last_pushed_content = content
                _last_push_at = now
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("push loop error: %s", e)


async def _alert_interruption(st: dict):
    """Once per interruption, push a Live Activity update that carries an alert, so a
    heater switched off at the panel lights up the Lock Screen even with the app closed."""
    global _alerted_interruption
    at = st.get("heaterInterruptedAt")
    if not at or at == _alerted_interruption:
        return
    _alerted_interruption = at
    alert = {"title": "Sauna heater turned off",
             "body": "Heat stopped before the timer ran out — maybe a panel tap. Open the app to resume.",
             "sound": "default"}
    for tok in list(_activity_tokens):
        try:
            await apns.update_activity(tok, _activity_content(st), priority=10,
                                       stale_after_sec=STALE_AFTER_SEC, alert=alert)
        except Exception as e:
            log.warning("interruption alert failed for %s…: %s", tok[:8], e)


async def _stop_sauna(reason: str):
    """Full stop (heater, then power) — same as the app's Stop."""
    log.warning("%s — stopping the sauna", reason)
    with contextlib.suppress(Exception):
        await sauna.set_heater(False)
    with contextlib.suppress(Exception):
        await sauna.set_power(False)


def _arm_timer_end(timer_min: Optional[int], ea: Optional[EndActionBody]):
    """Record what to do when the just-set timer runs out. A timer > 0 arms the end-action
    (defaulting to a plain full-off); timer 0 / off clears it."""
    global _timer_end_action, _timer_end_armed, _timer_end_deadline, _power_off_at, _timer_pending_min
    if timer_min and timer_min > 0:
        _timer_end_action = ea.model_dump() if ea else {"changeLight": False, "color": "Blue", "powerOffDelayMin": 0}
        _timer_end_armed = True
        _power_off_at = None   # a fresh timer cancels any pending deferred power-off
        st = sauna.state() if sauna else {}
        if _at_temp(st.get("currentTempF"), st.get("targetTempF")):
            # Already hot — count down now.
            _timer_end_deadline = time.time() + timer_min * 60
            _timer_pending_min = None
            log.info("timer armed: %s min, end-action %s (counting — at temp)", timer_min, _timer_end_action)
        else:
            # Below target — hold the timer until the cabin reaches temp, so a 30-min timer
            # means 30 min AT temperature, not 30 min that burns down during preheat.
            _timer_end_deadline = None
            _timer_pending_min = timer_min
            log.info("timer armed: %s min, end-action %s (pending — waits to reach %s°F)",
                     timer_min, _timer_end_action, st.get("targetTempF"))
    else:
        _timer_end_action = None
        _timer_end_armed = False
        _timer_end_deadline = None
        _power_off_at = None
        _timer_pending_min = None


async def _apply_timer_end_action():
    """Run the armed end-action now that the heat timer has reached 0, as one sequence:
    cut the heater (always — safety invariant), optionally change the light, then either
    hold power for a delay (lights stay on) or power off immediately."""
    global _timer_end_armed, _timer_end_deadline, _power_off_at, _heater_on_since
    ea = _timer_end_action or {}
    change_light = bool(ea.get("changeLight"))
    color = ea.get("color", "Blue")
    delay_min = int(ea.get("powerOffDelayMin", 0) or 0)
    _timer_end_armed = False
    _timer_end_deadline = None
    _heater_on_since = None
    # Cancel the FD-5's own countdown first, so the device doesn't cut power out from under us
    # during the light change / hold (it powers the sauna off when ITS timer reaches 0).
    with contextlib.suppress(Exception):
        await sauna.set_timer(0)
    # Heat always stops at timer end.
    with contextlib.suppress(Exception):
        await sauna.set_heater(False)
    # Optionally switch the light (power is still on, so the FD-5 accepts it).
    if change_light:
        with contextlib.suppress(Exception):
            await sauna.set_light(color)
        log.info("timer end: light -> %s", color)
    # Hold power for the delay (lights stay on), or power off now.
    if delay_min > 0:
        _power_off_at = time.time() + delay_min * 60
        log.info("timer end: holding power %s min, then off", delay_min)
    else:
        with contextlib.suppress(Exception):
            await sauna.set_power(False)
        log.info("timer end: power off")


async def _heater_watchdog():
    """Runs every 5s and handles timer-end plus two safety nets:
    - timer end-action: fires a few seconds BEFORE the armed deadline — taking over from the
      FD-5's own timer (which cuts power when IT reaches 0) — then runs the configured
      sequence. Driven off saunad's own deadline, so a flaky device-timer write can't lose it.
    - un-armed expiry safety: if no end-action is managing it, a heater still on with 0
      remaining is force-stopped (belt-and-braces; the FD-5's own timer didn't).
    - deadman: heater on longer than server.heaterMaxOnMinutes (if configured)."""
    global _heater_on_since, _timer_end_armed, _timer_end_deadline, _power_off_at, _timer_pending_min
    FIRE_LEAD = 20   # fire this many seconds before the deadline, to beat the device power-cut
    stuck_ticks = 0
    while True:
        try:
            await asyncio.sleep(5)
            st = sauna.state()
            now = time.time()
            heater = st.get("heater")
            power = st.get("power")
            rem = st.get("timerRemainingMin")
            cur = st.get("currentTempF")
            tgt = st.get("targetTempF")

            # Armed countdown due? Drive off OUR deadline (immune to device-timer flakiness),
            # firing a little early so power is still on for the light change + hold. This runs
            # even if power already dropped, so a timer-end power-cut can't pre-empt the action.
            if (_timer_end_armed and _timer_end_deadline is not None
                    and now >= _timer_end_deadline - FIRE_LEAD):
                await _apply_timer_end_action()
                stuck_ticks = 0
                continue

            # Power off BEFORE the deadline = a real early/manual stop → drop everything.
            if not power:
                _timer_end_armed = False
                _timer_end_deadline = None
                _power_off_at = None
                _timer_pending_min = None
                _heater_on_since = None
                stuck_ticks = 0
                continue

            # Temp-gated timer: once the cabin reaches target, start the full duration counting
            # (and program the FD-5's own display) — so the session is measured FROM temperature,
            # not burned down during preheat.
            if _timer_end_armed and _timer_pending_min is not None and _at_temp(cur, tgt):
                mins = _timer_pending_min
                _timer_pending_min = None
                _timer_end_deadline = now + mins * 60
                with contextlib.suppress(Exception):
                    await sauna.set_timer(mins)
                log.info("timer started: %s min at temp (reached %s°F, target %s°F)", mins, cur, tgt)

            # wait-mode: cut power once the hold elapses.
            if _power_off_at is not None and now >= _power_off_at:
                _power_off_at = None
                with contextlib.suppress(Exception):
                    await sauna.set_power(False)
                log.info("timer end: wait elapsed — powered off")

            # un-armed safety: a heater stuck on at 0 that saunad isn't managing (e.g. a
            # panel-set timer) — force stop after two ticks to ride out a transient 0.
            if not _timer_end_armed and heater and rem == 0:
                stuck_ticks += 1
                if stuck_ticks >= 2:
                    await _stop_sauna("timer reached 0 with the heater still on")
                    stuck_ticks = 0
            else:
                stuck_ticks = 0

            # deadman: heater on too long with nothing managing shutoff. A timer that's COUNTING
            # (deadline set) owns shutoff, so defer to it — preheat + a full at-temp session must
            # not trip the deadman. Preheat itself (pending, no deadline) is still capped.
            if not heater or (_timer_end_armed and _timer_end_deadline is not None):
                _heater_on_since = None
            elif _heater_max_on_sec is not None:
                if _heater_on_since is None:
                    _heater_on_since = now
                elif now - _heater_on_since >= _heater_max_on_sec:
                    await _stop_sauna(f"heater on > {_heater_max_on_sec}s (deadman)")
                    _heater_on_since = None
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("watchdog error: %s", e)


async def _fire_schedule(s: "schedules.Schedule"):
    """Apply a schedule's action: power on + heat (with its target/light/timer), or power off.
    Order mirrors /control (power first — it resets the timer/lights)."""
    log.info("schedule %s firing: %s", s.id, "ON" if s.turnOn else "OFF")
    try:
        if s.turnOn:
            await sauna.start_heating()
            if s.targetTempF is not None:
                await sauna.set_target_temp(s.targetTempF)
            if s.timerMin:
                # Temp-gated: at a scheduled start the cabin is cold, so this holds pending and
                # counts only once at target — the session isn't eaten by preheat.
                _arm_timer_end(s.timerMin, None)   # scheduled timer ends in a plain full-off
                if _timer_pending_min is None:
                    await sauna.set_timer(s.timerMin)
            if s.chromoColor and s.chromoColor != "Off":
                await sauna.set_light(s.chromoColor)
        else:
            await sauna.set_power(False)
    except Exception as e:
        log.warning("schedule %s fire failed: %s", s.id, e)


async def _scheduler_loop():
    """Every 30s, fire any schedule whose start moment has arrived. Fires each schedule at
    most once per day (tracked in _sched_fired), riding out the multi-tick start window."""
    while True:
        try:
            await asyncio.sleep(30)
            now = datetime.now()
            today = now.date().isoformat()
            cur = sauna.state().get("currentTempF") if sauna else None
            for s in schedules.current():
                if _sched_fired.get(s.id) == today:
                    continue
                start = schedules.start_dt(s, now, cur)
                if start is None:
                    continue
                if start <= now < start + timedelta(seconds=90):
                    await _fire_schedule(s)
                    _sched_fired[s.id] = today
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log.warning("scheduler error: %s", e)
