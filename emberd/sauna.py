"""Finnmark FD-5 client — sole owner of the single Tuya LAN connection.

All device I/O is serialized through one asyncio.Lock and pinned to a dedicated
single-thread executor (tinytuya is synchronous and not thread-safe). A background
task polls status so API reads are served from a cache. DP map mirrors schema.json.

tinytuya returns error *dicts* (e.g. {"Err":"905"}) rather than raising on device
failures, so we detect those explicitly and force a reconnect.
"""
import asyncio
import concurrent.futures
import contextlib
import logging
import time
from typing import Any, Optional

import tinytuya

log = logging.getLogger("emberd.sauna")

# Writable controls (DP numbers from schema.json, verified hands-on 2026-10-25).
# Unlike the Sun Home Eclipse 2 that ember was built for, power and heater on the FD-5
# are plain levels: writing true while already on leaves it on.
DP_POWER = "102"
DP_HEATER = "101"
DP_TARGET_F = "107"
DP_TIMER = "105"        # writable AND counts down while running (set == remaining)
DP_LIGHT = "111"        # enum; only applies while powered on
DP_UNIT_F = "109"       # true = °F
# Read-only
DP_CURRENT_F = "108"    # stale while powered off — see state()
DP_CURRENT_C = "106"
DP_TARGET_C = "104"

LIGHT_VALUES = ["White", "Purple", "Blue", "Cyan", "Green", "Yellow", "Red",
                "Scroll", "Orange", "Magenta", "Off"]
TARGET_F_RANGE = (86, 170)
TIMER_RANGE = (0, 90)

POLL_CEILING_SEC = 25.0          # keep well under the Tuya idle-drop (~30s); poll = keepalive
STICKY_TTL_SEC = 8.0             # hold a commanded DP over a lagging poll
FATAL_ERR = "914"                # ERR_KEY_OR_VER — wrong localKey/protocol version


def _err_code(st: Any) -> Optional[str]:
    """tinytuya returns {'Err': '905', 'Error': '...'} on failure instead of raising."""
    if isinstance(st, dict) and ("Err" in st or "Error" in st):
        return str(st.get("Err", "?"))
    return None


class SaunaClient:
    def __init__(self, ip: str, dev_id: str, local_key: str,
                 version: float = 3.5, poll_interval: float = 5.0):
        self.ip = ip
        self.dev_id = dev_id
        self.local_key = local_key
        self.version = version
        self.poll_interval = min(float(poll_interval), POLL_CEILING_SEC)
        # one dedicated worker thread → device calls never land on different threads
        self._executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="sauna-io")
        self._dev: Optional[tinytuya.Device] = None
        self._lock: Optional[asyncio.Lock] = None  # created in start() under the running loop
        self._raw: dict[str, Any] = {}
        self._pending: dict[str, tuple[Any, float]] = {}  # dp -> (commanded value, expires_at)
        self._timer_set: Optional[int] = None  # last commanded timer (the device only reports remaining)
        self._online = False
        self._updated = 0.0
        self._temp_history: list[tuple[float, int]] = []  # (ts, currentTempF)
        self._task: Optional[asyncio.Task] = None

    # ---- connection / io ----
    def _connect(self) -> tinytuya.Device:
        d = tinytuya.Device(self.dev_id, self.ip, self.local_key, version=self.version)
        d.set_socketPersistent(True)
        d.set_socketTimeout(5)
        d.set_socketRetryLimit(1)  # a dead device can't hold the lock for retries*timeout
        return d

    async def _io(self, fn):
        """Run a sync device call under the lock, pinned to the single io thread."""
        loop = asyncio.get_running_loop()
        async with self._lock:
            if self._dev is None:
                self._dev = await loop.run_in_executor(self._executor, self._connect)
            try:
                return await loop.run_in_executor(self._executor, lambda: fn(self._dev))
            except Exception:
                self._dev = None  # python-level error → drop socket, reconnect next call
                raise

    async def _drop_connection(self):
        """Close + null the device so the next _io reconnects (after an error dict)."""
        loop = asyncio.get_running_loop()
        async with self._lock:
            dev, self._dev = self._dev, None
        if dev is not None:
            with contextlib.suppress(Exception):
                await loop.run_in_executor(self._executor, dev.close)

    def _handle_error(self, code: str, st: Any) -> None:
        self._online = False
        if code == FATAL_ERR:
            log.error("sauna FATAL error %s (check localKey/version): %s", code, st)
        else:
            log.warning("sauna device error %s: %s", code, st)

    # ---- lifecycle ----
    async def start(self):
        self._lock = asyncio.Lock()  # bind to the running loop
        try:
            await self.refresh()  # prime the cache (best effort)
        except Exception as e:
            log.warning("initial refresh failed: %s", e)
        self._task = asyncio.create_task(self._poll_loop())

    async def stop(self):
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
        if self._lock is not None:
            await self._drop_connection()
        self._executor.shutdown(wait=False)

    async def _poll_loop(self):
        while True:
            try:
                await self.refresh()
            except asyncio.CancelledError:
                raise
            except Exception as e:
                self._online = False
                log.warning("poll error: %s", e)
            finally:
                # Fresh socket every cycle: on the Eclipse 2 a long-lived socket drifted
                # stale, and reconnecting is cheap insurance on the FD-5 too. Still only
                # ever one connection at a time.
                with contextlib.suppress(Exception):
                    await self._drop_connection()
            await asyncio.sleep(self.poll_interval)

    # ---- state ----
    async def _read_dps(self) -> dict:
        """One fresh, successful status read merged into the cache — raises instead of
        silently serving the cache, so write verification never runs on a failed read."""
        st = await self._io(lambda d: d.status())
        code = _err_code(st)
        if code:
            self._handle_error(code, st)
            await self._drop_connection()  # any device error → force reconnect
            raise RuntimeError(f"device read failed (Err {code})")
        dps = st.get("dps") if isinstance(st, dict) else None
        if not dps:
            self._online = False
            raise RuntimeError("device returned no dps")
        self._merge_polled(dps)
        return dps

    async def refresh(self) -> dict:
        with contextlib.suppress(RuntimeError):
            await self._read_dps()
        return self.state()

    def _merge_polled(self, dps: dict) -> None:
        if DP_POWER in dps and DP_POWER in self._raw and dps[DP_POWER] != self._raw[DP_POWER]:
            log.info("device: power %s -> %s", self._raw[DP_POWER], dps[DP_POWER])
            if not dps[DP_POWER]:
                self._timer_set = None  # the device resets its timer on the next power-on
        self._raw.update(dps)
        self._apply_pending(dps)
        self._online = True
        self._updated = time.time()
        cf = self.state()["currentTempF"]
        if isinstance(cf, int):
            self._temp_history.append((self._updated, cf))
            self._temp_history = self._temp_history[-5000:]

    def state(self) -> dict:
        r = self._raw
        power = bool(r.get(DP_POWER, False))
        # The FD-5 keeps reporting the last session's temperature while powered off
        # (read 156°F in a cool cabin), so only trust it while on.
        cur_f = r.get(DP_CURRENT_F) if power else None
        cur_c = r.get(DP_CURRENT_C) if power else None
        remaining = r.get(DP_TIMER)
        return {
            "power": power,
            "heater": bool(r.get(DP_HEATER, False)),
            "currentTempF": cur_f,
            "currentTempC": cur_c,
            "targetTempF": r.get(DP_TARGET_F),
            "targetTempC": r.get(DP_TARGET_C),
            "timerSetMin": self._timer_set,
            "timerRemainingMin": remaining if power else None,
            "chromoColor": r.get(DP_LIGHT) if power else "Off",
            "unit": "f" if r.get(DP_UNIT_F, True) else "c",
            "online": self._online,
            "updatedAt": self._updated,
        }

    def _stick(self, dp: str, value: Any, ttl: float = STICKY_TTL_SEC) -> None:
        """Reflect a just-commanded DP onto the cache and hold it over a lagging poll.
        Dropped as soon as the device confirms it, or after the TTL so a write that
        didn't take still reconciles to reality."""
        self._raw[str(dp)] = value
        self._pending[str(dp)] = (value, time.time() + ttl)
        self._updated = time.time()

    def _apply_pending(self, polled: dict) -> None:
        now = time.time()
        for dp, (val, exp) in list(self._pending.items()):
            if (dp in polled and polled[dp] == val) or now >= exp:
                del self._pending[dp]
            else:
                self._raw[dp] = val

    def overlay_bools(self, *, power=None, heater=None) -> None:
        """Stick just-commanded power/heater onto the cache so the /control response
        and the next poll aren't transiently stale."""
        for dp, v in ((DP_POWER, power), (DP_HEATER, heater)):
            if v is not None:
                self._stick(dp, bool(v))

    def peak_since(self, ts: float) -> Optional[int]:
        hist = list(self._temp_history)  # snapshot — poll loop may append concurrently
        vals = [t for (s, t) in hist if s >= ts and isinstance(t, int)]
        return max(vals) if vals else None

    # ---- controls ----
    async def set_dp(self, dp: str, value: Any) -> dict:
        st = await self._io(lambda d: d.set_value(dp, value))
        code = _err_code(st)
        if code:
            self._handle_error(code, st)
            await self._drop_connection()
            raise RuntimeError(f"device rejected write (Err {code})")
        self._stick(dp, value)
        return self.state()

    async def _set_verified(self, dp: str, value: Any) -> dict:
        """Write, then confirm the device actually reports the value. The FD-5 silently
        ignores some writes (e.g. a light color while powered off) — fail loudly rather
        than report phantom success."""
        await self.set_dp(dp, value)
        for delay in (0.5, 1.0, 1.5):
            await asyncio.sleep(delay)
            with contextlib.suppress(RuntimeError):
                dps = await self._read_dps()
                if dps.get(dp) == value:
                    return self.state()
        raise RuntimeError(f"device did not apply DP{dp}={value!r}")

    async def set_power(self, on: bool) -> dict:
        st = await self._set_verified(DP_POWER, bool(on))
        if not on:
            self._timer_set = None  # the device resets its timer on the next power-on
            st = self.state()
        return st

    async def start_heating(self) -> dict:
        """Power + heater on as one intent. Power-on resets the timer to 80 min and the
        lights to White, so callers apply their timer/color after this."""
        if not self._raw.get(DP_POWER):
            await self.set_power(True)
        return await self.set_heater(True)

    async def set_heater(self, on: bool) -> dict:
        if on and not self._raw.get(DP_POWER):
            raise ValueError("power the sauna on before heating")
        return await self._set_verified(DP_HEATER, bool(on))

    async def set_target_temp(self, temp_f: int) -> dict:
        lo, hi = TARGET_F_RANGE
        return await self._set_verified(DP_TARGET_F, max(lo, min(hi, int(temp_f))))

    async def set_timer(self, minutes: int) -> dict:
        lo, hi = TIMER_RANGE
        minutes = max(lo, min(hi, int(minutes)))
        await self._set_verified(DP_TIMER, minutes)
        self._timer_set = minutes or None
        return self.state()

    async def set_light(self, value: str) -> dict:
        if value not in LIGHT_VALUES:
            raise ValueError(f"chromoColor must be one of {LIGHT_VALUES}")
        if not self._raw.get(DP_POWER):
            raise ValueError("power the sauna on before changing the lights")
        return await self._set_verified(DP_LIGHT, value)
