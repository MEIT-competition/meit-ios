"""Thread-safe, in-memory role/RMS registry and bounded, best-effort commands."""
import math
import threading
import time
import uuid
from dataclasses import dataclass

ROLES = ("front", "right", "back", "left")
RMS_MAX_AGE_SECONDS = 0.5
DEVICE_TIMEOUT_SECONDS = 5.0
DIRECTION_MARGIN_DB = 3.0
COMMAND_TTL_SECONDS = 2.0
MAX_DEVICES = 16


class ProtocolError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


def identity(payload):
    if not isinstance(payload, dict):
        raise ProtocolError(400, "invalid_device", "Expected a device object.")
    device_id, role = payload.get("device_id"), payload.get("role")
    try:
        if not isinstance(device_id, str) or str(uuid.UUID(device_id)) != device_id.lower():
            raise ValueError()
    except (ValueError, AttributeError):
        raise ProtocolError(400, "invalid_device", "device_id must be a UUID.") from None
    if role not in ROLES:
        raise ProtocolError(400, "invalid_role", "role must be front, right, back or left.")
    return device_id.lower(), role


@dataclass
class Device:
    device_id: str
    role: str
    last_seen: float
    registration_id: str
    latest_rms_dbfs: float | None = None
    latest_rms_timestamp: float | None = None
    calibration_offset_db: float = 0.0
    pending: dict | None = None
    command_expires: float = 0.0


@dataclass(frozen=True)
class DirectionSelection:
    result: dict
    target: tuple | None


class Coordinator:
    def __init__(self, *, clock=time.monotonic, rms_max_age=RMS_MAX_AGE_SECONDS,
                 device_timeout=DEVICE_TIMEOUT_SECONDS, margin_db=DIRECTION_MARGIN_DB,
                 command_ttl=COMMAND_TTL_SECONDS):
        for value in (rms_max_age, device_timeout, margin_db, command_ttl):
            if not math.isfinite(value) or value <= 0:
                raise ValueError("Coordination settings must be finite and positive.")
        self.clock = clock
        self.rms_max_age, self.device_timeout = rms_max_age, device_timeout
        self.margin_db, self.command_ttl = margin_db, command_ttl
        self.lock = threading.Lock()
        self.devices = {}
        # Rejected competing claims remain visible until resolved or timed out.
        self.conflicts = {}

    def _prune(self, now):
        self.conflicts = {key: item for key, item in self.conflicts.items()
                          if now - item[1] <= self.device_timeout}
        self.devices = {key: item for key, item in self.devices.items()
                        if now - item.last_seen <= self.device_timeout * 2}

    def register(self, payload):
        device_id, role = identity(payload)
        with self.lock:
            now = self.clock()
            self._prune(now)
            for item in self.devices.values():
                if item.role == role and item.device_id != device_id and now - item.last_seen <= self.device_timeout:
                    if len(self.conflicts) < MAX_DEVICES or device_id in self.conflicts:
                        self.conflicts[device_id] = (role, now)
                    raise ProtocolError(409, "role_conflict", f"Role {role.upper()} is already occupied.")
            if device_id not in self.devices and len(self.devices) >= MAX_DEVICES:
                raise ProtocolError(503, "registry_full", "Wait for offline devices to expire.")
            # A stale owner may be replaced, but never a live owner.
            for key in list(self.devices):
                if key != device_id and self.devices[key].role == role:
                    del self.devices[key]
            old = self.devices.get(device_id)
            if old is None or old.role != role or now - old.last_seen > self.device_timeout:
                self.devices[device_id] = Device(device_id, role, now, str(uuid.uuid4()))
            else:
                old.last_seen = now
            self.conflicts.pop(device_id, None)
            return {"status": "registered", "device_id": device_id, "role": role}

    def _device(self, device_id, role, now):
        item = self.devices.get(device_id)
        if item is None or now - item.last_seen > self.device_timeout:
            raise ProtocolError(404, "not_registered", "Register this device again.")
        if item.role != role:
            raise ProtocolError(409, "registration_mismatch", "Device role changed; register again.")
        return item

    def report_rms(self, payload):
        device_id, role = identity(payload)
        rms = payload.get("rms_dbfs")
        if isinstance(rms, bool) or not isinstance(rms, (int, float)) or not -100 <= rms <= 0 or not math.isfinite(rms):
            raise ProtocolError(400, "invalid_rms", "rms_dbfs must be a finite number between -100 and 0.")
        with self.lock:
            now = self.clock()
            item = self._device(device_id, role, now)
            item.last_seen = item.latest_rms_timestamp = now
            item.latest_rms_dbfs = float(rms)
            return {"status": "ok"}

    def _selection(self, now):
        self._prune(now)
        states, fresh, missing, stale = {}, [], [], []
        conflicts = sorted({role for role, _ in self.conflicts.values()})
        for role in ROLES:
            item = next((d for d in self.devices.values() if d.role == role), None)
            online = item is not None and now - item.last_seen <= self.device_timeout
            age = None if item is None or item.latest_rms_timestamp is None else now - item.latest_rms_timestamp
            is_fresh = online and age is not None and age <= self.rms_max_age
            corrected = None if item is None or item.latest_rms_dbfs is None else item.latest_rms_dbfs + item.calibration_offset_db
            states[role] = {"device_id": item.device_id if item else None,
                            "rms_dbfs": item.latest_rms_dbfs if item else None,
                            "corrected_rms_dbfs": corrected,
                            "rms_age_ms": age * 1000 if age is not None else None,
                            "online": online, "fresh": is_fresh}
            if not online:
                missing.append(role)
            elif not is_fresh:
                stale.append(role)
            if is_fresh:
                fresh.append((corrected, item))
        fresh.sort(key=lambda pair: pair[0], reverse=True)
        winner = fresh[0][0] if fresh else None
        runner = fresh[1][0] if len(fresh) > 1 else None
        margin = winner - runner if runner is not None else None
        reason = ("role_conflict" if conflicts else "waiting_for_roles" if missing else
                  "stale_rms" if stale else "insufficient_margin" if margin < self.margin_db else "ok")
        target = fresh[0][1] if reason == "ok" else None
        result = {"direction": target.role if target else "unknown", "reason": reason,
                  "winner_dbfs": winner, "runner_up_dbfs": runner, "margin_db": margin,
                  "required_margin_db": self.margin_db, "rms_max_age_ms": self.rms_max_age * 1000,
                  "missing_roles": missing, "stale_roles": stale, "conflict_roles": conflicts,
                  "devices": states}
        return DirectionSelection(result, (target.device_id, target.registration_id) if target else None)

    def selection(self):
        with self.lock:
            return self._selection(self.clock())

    def list_devices(self):
        with self.lock:
            now = self.clock()
            selection = self._selection(now)
            return {"devices": [{"device_id": d.device_id, "role": d.role,
                                 "last_seen": d.last_seen, "last_seen_age_ms": (now - d.last_seen) * 1000,
                                 "online": now - d.last_seen <= self.device_timeout,
                                 "latest_rms_dbfs": d.latest_rms_dbfs,
                                 "latest_rms_timestamp": d.latest_rms_timestamp,
                                 "calibration_offset_db": d.calibration_offset_db}
                                for d in self.devices.values()], "direction": selection.result}

    def enqueue(self, selection, source):
        if selection.target is None:
            return {"queued": False, "reason": "direction_unknown"}
        with self.lock:
            now = self.clock()
            self._prune(now)
            device_id, registration_id = selection.target
            item = self.devices.get(device_id)
            if (item is None or item.registration_id != registration_id
                    or now - item.last_seen > self.device_timeout
                    or any(role == item.role for role, _ in self.conflicts.values())):
                return {"queued": False, "reason": "target_changed_or_offline"}
            if item.pending is not None and item.command_expires > now:
                return {"queued": False, "reason": "command_pending"}
            command = {"command_id": str(uuid.uuid4()), "kind": "direction_haptic",
                       "role": item.role, "source": source}
            item.pending = command
            item.command_expires = now + self.command_ttl
            return {"queued": True, "command_id": command["command_id"], "target_role": item.role}

    def after_inference(self, result, selection):
        haptic = (self.enqueue(selection, "inference") if result["label"] in ("horn", "siren", "crash")
                  else {"queued": False, "reason": "non_danger_class"})
        return {**result, "direction": selection.result["direction"],
                "direction_margin_db": selection.result["margin_db"],
                "direction_details": selection.result, "haptic": haptic}

    def test_haptic(self):
        selected = self.selection()
        return {"direction": selected.result, "haptic": self.enqueue(selected, "direction_test")}

    def poll(self, payload):
        device_id, role = identity(payload)
        with self.lock:
            now = self.clock()
            item = self._device(device_id, role, now)
            item.last_seen = now  # Polls are heartbeats, but never refresh RMS timestamps.
            command = item.pending
            item.pending = None  # Atomic consume: a retry cannot deliver the same command twice.
            if command is not None:
                if item.command_expires <= now or any(r == role and now - t <= self.device_timeout for r, t in self.conflicts.values()):
                    command = None
                else:
                    command = {**command, "expires_in_ms": (item.command_expires - now) * 1000}
            return {"command": command, "direction": self._selection(now).result}
