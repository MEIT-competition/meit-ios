"""Central auto event gate. Lock order is auto -> registry; never held during AI."""
import math
import threading
import uuid
from coordination import ProtocolError, identity


class AutomaticDetection:
    def __init__(self, coordinator, *, trigger_dbfs=-30.0, cooldown=3.0,
                 audio_timeout=3.0, rearm_quiet=0.75):
        if not math.isfinite(trigger_dbfs) or not -97 < trigger_dbfs <= 0:
            raise ValueError("auto trigger must be finite and greater than -97 and at most 0 dBFS.")
        if any(not math.isfinite(v) or v <= 0 for v in (cooldown, audio_timeout, rearm_quiet)):
            raise ValueError("Auto durations must be finite and positive.")
        self.coordinator = coordinator
        self.clock = lambda: coordinator.clock()
        self.trigger_dbfs, self.cooldown = trigger_dbfs, cooldown
        self.audio_timeout, self.rearm_quiet = audio_timeout, rearm_quiet
        self.lock = threading.Lock()
        self.enabled = False
        self.state = "IDLE"
        self.active = None
        self.last_event = None  # Exactly one completed record; never stores PCM.
        self.cooldown_until = 0
        self.armed = True
        self.quiet_since = None
        self.quiet_observed = None

    def _record(self, event, outcome, result=None):
        return {"event_id": event["event_id"], "source_role": event["source"]["role"],
                "outcome": outcome, "result": result,
                "direction": event["selection"].result["direction"],
                "direction_details": event["selection"].result}

    def _finish(self, outcome, result=None):
        event = self.active
        self.coordinator.cancel_event_commands(event["event_id"])
        self.last_event = self._record(event, outcome, result)
        self.active = None
        self.state = "COOLDOWN"
        self.cooldown_until = self.clock() + self.cooldown
        self.quiet_since = self.quiet_observed = None

    def _tick(self):
        now = self.clock()
        if self.state == "WAITING_FOR_AUDIO" and now >= self.active["deadline"]:
            self._finish("audio_timeout")
        if self.state == "COOLDOWN" and now >= self.cooldown_until:
            self.state = "IDLE"

    def tick(self):
        with self.lock:
            self._tick()

    def _status(self):
        return {"enabled": self.enabled, "state": self.state, "armed": self.armed,
                "trigger_dbfs": self.trigger_dbfs, "release_dbfs": self.trigger_dbfs - 3,
                "cooldown_ms": self.cooldown * 1000,
                "audio_timeout_ms": self.audio_timeout * 1000,
                "rearm_quiet_ms": self.rearm_quiet * 1000,
                "active_event": self._record(self.active, self.state) if self.active else None,
                "last_event": self.last_event}

    def status(self):
        with self.lock:
            self._tick()
            return self._status()

    def set_enabled(self, enabled):
        with self.lock:
            self._tick()
            self.enabled = enabled
            if not enabled and self.active is not None:
                self.coordinator.cancel_event_commands(self.active["event_id"])
                if self.state == "WAITING_FOR_AUDIO":
                    self._finish("stopped")
                else:
                    # Cannot interrupt TensorFlow safely. Retain the one occupied slot
                    # until its call returns, suppressing its result/haptic even after ON.
                    self.active["cancelled"] = True
            if not enabled and self.last_event is not None:
                self.coordinator.cancel_event_commands(self.last_event["event_id"])
            return self._status()

    def observe(self):
        with self.lock:
            self._tick()
            if not self.enabled:
                return
            selected, source = self.coordinator.auto_observation()
            now = self.clock()
            if self.active is not None:
                return
            # Require observed quiet, not missing/stale reports, before another burst.
            # All fresh RMS readings count here, including phones whose buffer is not ready.
            levels = [s["corrected_rms_dbfs"] for s in selected.result["devices"].values() if s["fresh"]]
            if levels and max(levels) < self.trigger_dbfs - 3:
                if self.quiet_observed is None or now - self.quiet_observed > self.coordinator.rms_max_age:
                    self.quiet_since = now
                self.quiet_observed = now
                if now - self.quiet_since >= self.rearm_quiet:
                    self.armed = True
            else:
                self.quiet_since = self.quiet_observed = None
            if self.state != "IDLE" or not self.armed or source is None or source["rms_dbfs"] < self.trigger_dbfs:
                return
            event = {"event_id": str(uuid.uuid4()), "source": source, "selection": selected,
                     "deadline": now + self.audio_timeout, "cancelled": False}
            self.active = event
            self.state = "WAITING_FOR_AUDIO"
            self.armed = False
            try:
                queued = self.coordinator.enqueue_snapshot(source, event["event_id"], self.audio_timeout)
            except ProtocolError:
                queued = False
            if not queued:
                self._finish("command_unavailable")

    def claim_audio(self, metadata):
        device_id, role = identity(metadata)
        event_id = metadata.get("event_id")
        try:
            if not isinstance(event_id, str) or str(uuid.UUID(event_id)) != event_id.lower():
                raise ValueError()
        except (ValueError, AttributeError):
            raise ProtocolError(400, "invalid_event", "event_id must be a UUID.") from None
        with self.lock:
            self._tick()
            event = self.active
            if not self.enabled or event is None or event["event_id"] != event_id.lower():
                raise ProtocolError(409, "inactive_event", "Event is stopped, expired or not active.")
            if event["source"]["device_id"] != device_id or event["source"]["role"] != role:
                raise ProtocolError(409, "wrong_source", "Audio must come from the selected source.")
            if self.state != "WAITING_FOR_AUDIO":
                raise ProtocolError(409, "event_already_claimed", "This event already accepted audio.")
            self.coordinator.validate_auto_source(event["source"])
            self.state = "INFERENCING"  # Atomic claim BEFORE waiting for the model lock.
            self.coordinator.cancel_event_commands(event["event_id"])
            return event["event_id"]

    def check_inference(self, event_id):
        with self.lock:
            if self.active is None or self.active["event_id"] != event_id or self.active["cancelled"]:
                raise ProtocolError(409, "event_stopped", "Automatic event was stopped.")

    def complete(self, event_id, result=None):
        with self.lock:
            event = self.active
            if event is None or event["event_id"] != event_id:
                raise ProtocolError(409, "inactive_event", "Automatic event no longer exists.")
            if event["cancelled"]:
                self._finish("stopped")
                raise ProtocolError(409, "event_stopped", "Automatic event was stopped.")
            if result is None:
                self._finish("inference_failed")
                return None
            selected = event["selection"]
            haptic = (self.coordinator.enqueue(selected, "auto_inference", event_id)
                      if result["danger"] and result["label"] in ("horn", "siren", "crash")
                      else {"queued": False, "reason": "ai_decision_suppressed"})
            result = {**result, "event_id": event_id, "source_role": event["source"]["role"],
                      "direction": selected.result["direction"],
                      "direction_margin_db": selected.result["margin_db"],
                      "direction_details": selected.result, "haptic": haptic}
            # Keep a newly queued haptic; the snapshot command was consumed on claim.
            self.last_event = self._record(event, "completed", result)
            self.active = None
            self.state = "COOLDOWN"
            self.cooldown_until = self.clock() + self.cooldown
            self.quiet_since = self.quiet_observed = None
            return result
