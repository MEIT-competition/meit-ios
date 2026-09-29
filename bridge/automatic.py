"""Central auto event gate. Lock order is auto -> registry; never held during AI."""
import logging
from collections import deque
import math
import threading
import uuid
from coordination import ProtocolError, identity


LOGGER = logging.getLogger("meit.auto")
COUNTER_MAX = (1 << 63) - 1


def increment(counters, key):
    # Fixed keys and saturation keep diagnostics storage bounded even over long runs.
    counters[key] = min(COUNTER_MAX, counters[key] + 1)


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
        self.last_event = None  # Existing UI contract remains one most recent outcome.
        self.started_at = self.clock()
        self.recent_events = deque(maxlen=20)  # Compact metadata only, never PCM or device IDs.
        self.counters = dict.fromkeys(("trigger_count", "completed_count", "timeout_count",
                                      "stopped_count", "source_unavailable_count", "inference_failed_count",
                                      "duplicate_rejects", "inactive_rejects", "source_rejects"), 0)
        self.cooldown_until = 0
        self.armed = True
        self.quiet_since = None
        self.quiet_observed = None

    def _timing(self, event):
        times = event["times"]
        def elapsed(start, end):
            if start not in times or end not in times:
                return None
            return max(0.0, (times[end] - times[start]) * 1000)
        return {"trigger_to_command_ms": elapsed("triggered", "snapshot_requested"),
                "command_to_audio_ms": elapsed("snapshot_requested", "snapshot_received"),
                "audio_to_inference_start_ms": elapsed("snapshot_received", "inference_started"),
                "inference_ms": elapsed("inference_started", "inference_completed"),
                "total_event_ms": elapsed("triggered", "finished")}

    def _record(self, event, outcome, result=None):
        return {"event_id": event["event_id"], "source_role": event["source"]["role"],
                "outcome": outcome, "result": result,
                "trigger_rms_dbfs": event["source"]["rms_dbfs"],
                "trigger_threshold_dbfs": self.trigger_dbfs,
                # This is the existing armed level gate, not a new edge detector or AI dB gate.
                "trigger_reason": "armed_rms_at_or_above_threshold",
                "timestamps_ms": {key: (value - self.started_at) * 1000 for key, value in event["times"].items()},
                "latency": self._timing(event),
                "direction": event["selection"].result["direction"],
                "direction_details": event["selection"].result}

    @staticmethod
    def _summary(record):
        if record is None:
            return None
        result = record["result"]
        return {"event_id_prefix": record["event_id"][:8], "source": record["source_role"],
                "trigger_rms_dbfs": record["trigger_rms_dbfs"],
                "trigger_threshold_dbfs": record["trigger_threshold_dbfs"],
                "trigger_reason": record["trigger_reason"], "outcome": record["outcome"],
                "label": result["label"] if result else None,
                "confidence": result["confidence"] if result else None,
                "direction": record["direction"], "latency": record["latency"],
                "timestamps_ms": record["timestamps_ms"]}

    def _remember(self, outcome, result=None):
        self.active["times"]["finished"] = self.clock()
        self.last_event = self._record(self.active, outcome, result)
        # Retain a full EVENT id internally only to classify recent duplicate rejections.
        # Export only its prefix, never a device id or the direction registry snapshot.
        self.recent_events.append({"event_id": self.active["event_id"],
                                   "summary": self._summary(self.last_event)})
        key = {"completed": "completed_count", "audio_timeout": "timeout_count",
               "stopped": "stopped_count", "command_unavailable": "source_unavailable_count",
               "inference_failed": "inference_failed_count"}[outcome]
        increment(self.counters, key)
        LOGGER.info("[AUTO] %s event=%s total=%.1f ms direction=%s", outcome,
                    self.active["event_id"][:8], self.last_event["latency"]["total_event_ms"],
                    self.last_event["direction"])

    def _finish(self, outcome, result=None):
        event = self.active
        self.coordinator.cancel_event_commands(event["event_id"])
        self._remember(outcome, result)
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
        now = self.clock()
        quiet_ms = (min(self.rearm_quiet, self.quiet_observed - self.quiet_since) * 1000
                    if self.quiet_observed is not None and now - self.quiet_observed <= self.coordinator.rms_max_age else 0.0)
        return {"enabled": self.enabled, "state": self.state, "armed": self.armed,
                "trigger_dbfs": self.trigger_dbfs, "release_dbfs": self.trigger_dbfs - 3,
                "cooldown_ms": self.cooldown * 1000,
                "audio_timeout_ms": self.audio_timeout * 1000,
                "rearm_quiet_ms": self.rearm_quiet * 1000,
                "server_uptime_ms": max(0.0, (now - self.started_at) * 1000),
                "cooldown_remaining_ms": max(0.0, (self.cooldown_until - now) * 1000),
                "waiting_for_quiet": self.enabled and not self.armed and self.active is None,
                "quiet_elapsed_ms": quiet_ms,
                "active_event": self._record(self.active, self.state) if self.active else None,
                "last_event": self.last_event}

    def status(self):
        with self.lock:
            self._tick()
            return self._status()

    def diagnostics(self):
        with self.lock:
            self._tick()
            status = self._status()
            status["active_event"] = self._summary(status["active_event"])
            status["last_event"] = self._summary(status["last_event"])
            return {**status, "recent_event_count": len(self.recent_events),
                    "recent_event_limit": self.recent_events.maxlen,
                    "recent_events": [entry["summary"] for entry in self.recent_events],
                    "counters": dict(self.counters)}

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
                     "deadline": now + self.audio_timeout, "cancelled": False, "times": {"triggered": now}}
            self.active = event
            increment(self.counters, "trigger_count")
            LOGGER.info("[AUTO] trigger event=%s source=%s rms=%.1f threshold=%.1f", event["event_id"][:8],
                        source["role"], source["rms_dbfs"], self.trigger_dbfs)
            self.state = "WAITING_FOR_AUDIO"
            self.armed = False
            try:
                queued = self.coordinator.enqueue_snapshot(source, event["event_id"], self.audio_timeout)
            except ProtocolError:
                queued = False
            if not queued:
                self._finish("command_unavailable")
            else:
                event["times"]["snapshot_requested"] = self.clock()
                LOGGER.info("[AUTO] snapshot requested event=%s", event["event_id"][:8])

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
                duplicate = any(entry["event_id"] == event_id.lower() and
                                entry["summary"]["timestamps_ms"].get("snapshot_received") is not None
                                for entry in self.recent_events)
                increment(self.counters, "duplicate_rejects" if duplicate else "inactive_rejects")
                raise ProtocolError(409, "inactive_event", "Event is stopped, expired or not active.")
            if event["source"]["device_id"] != device_id or event["source"]["role"] != role:
                increment(self.counters, "source_rejects")
                raise ProtocolError(409, "wrong_source", "Audio must come from the selected source.")
            if self.state != "WAITING_FOR_AUDIO":
                increment(self.counters, "duplicate_rejects")
                raise ProtocolError(409, "event_already_claimed", "This event already accepted audio.")
            self.coordinator.validate_auto_source(event["source"])
            event["times"]["snapshot_received"] = self.clock()
            LOGGER.info("[AUTO] audio received event=%s", event["event_id"][:8])
            self.state = "INFERENCING"  # Atomic claim BEFORE waiting for the model lock.
            self.coordinator.cancel_event_commands(event["event_id"])
            return event["event_id"]

    def check_inference(self, event_id):
        with self.lock:
            if self.active is None or self.active["event_id"] != event_id or self.active["cancelled"]:
                raise ProtocolError(409, "event_stopped", "Automatic event was stopped.")
            self.active["times"]["inference_started"] = self.clock()
            LOGGER.info("[AUTO] inference started event=%s", event_id[:8])

    def complete(self, event_id, result=None):
        with self.lock:
            event = self.active
            if event is None or event["event_id"] != event_id:
                raise ProtocolError(409, "inactive_event", "Automatic event no longer exists.")
            if "inference_started" in event["times"]:
                event["times"]["inference_completed"] = self.clock()
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
            LOGGER.info("[AI] event=%s label=%s confidence=%.3f alert=%s", event_id[:8],
                        result["label"], result["confidence"], result["danger"])
            self._remember("completed", result)
            self.active = None
            self.state = "COOLDOWN"
            self.cooldown_until = self.clock() + self.cooldown
            self.quiet_since = self.quiet_observed = None
            return result
