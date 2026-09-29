"""One bounded Wearable event context. No device registry, coordination, or commands."""
import math
import threading
import uuid
from coordination import ProtocolError
from event_gate import observe_event_gate, finish_event_gate


def identifier(value):
    try:
        if not isinstance(value, str) or str(uuid.UUID(value)) != value.lower():
            raise ValueError()
        return value.lower()
    except (ValueError, AttributeError):
        raise ProtocolError(400, "invalid_wearable_metadata", "Expected a session/event UUID.") from None


def direction_metadata(values):
    if values is None:
        return None
    if len(values) != 1 or values[0] not in ("left", "center", "right", "unavailable"):
        raise ProtocolError(400, "invalid_direction", "Direction must be left, center, right or unavailable.")
    return None if values[0] == "unavailable" else values[0]


class WearableEvents:
    def __init__(self, automatic, max_age):
        # Same actual configured policy as the existing automatic path; independent event state.
        self.clock = automatic.clock
        self.trigger_dbfs = automatic.trigger_dbfs
        self.cooldown = automatic.cooldown
        self.rearm_quiet = automatic.rearm_quiet
        self.audio_timeout = automatic.audio_timeout
        self.max_age = max_age
        self.lock = threading.Lock()
        self.session_id = None
        self.pending = None
        self.busy = None
        self.armed = True
        self.cooldown_until = 0
        self.quiet_since = self.quiet_observed = None

    def observe(self, body):
        session_id = identifier(body.get("session_id"))
        level, ready = body.get("rms_dbfs"), body.get("buffer_ready")
        if isinstance(level, bool) or not isinstance(level, (int, float)) or not math.isfinite(level) or not -100 <= level <= 0 or type(ready) is not bool:
            raise ProtocolError(400, "invalid_observation", "Expected finite RMS and boolean buffer_ready.")
        with self.lock:
            now = self.clock()
            if self.session_id != session_id:
                if self.busy:
                    raise ProtocolError(409, "wearable_busy", "Previous Wearable inference is still finishing.")
                self.session_id = session_id
                self.pending = None
                self.armed = True
                self.cooldown_until = 0
                self.quiet_since = self.quiet_observed = None
            if self.pending and not self.busy and now >= self.pending["deadline"]:
                self.pending = None
                finish_event_gate(self, now)
            event_id = None
            if not self.pending and not self.busy and observe_event_gate(
                    self, [level], level if ready else None, now, max_age=self.max_age, can_trigger=True):
                event_id = str(uuid.uuid4())
                self.pending = {"id": event_id, "deadline": now + self.audio_timeout}
                self.armed = False
            # Event is delivered once. A lost reply expires; sustained sound cannot retrigger.
            return {"session_id": session_id, "event_id": event_id}

    def claim(self, session_id, event_id):
        if (session_id is None) != (event_id is None):
            raise ProtocolError(400, "invalid_wearable_metadata", "Supply both session and event IDs.")
        if session_id is not None:
            session_id, event_id = identifier(session_id), identifier(event_id)
        with self.lock:
            if self.busy:
                raise ProtocolError(409, "wearable_busy", "A Wearable inference is already in flight.")
            if event_id is not None:
                if (self.session_id != session_id or not self.pending or self.pending["id"] != event_id
                        or self.clock() >= self.pending["deadline"]):
                    raise ProtocolError(409, "stale_event", "Wearable event is stale or already consumed.")
            elif self.pending:
                raise ProtocolError(409, "wearable_busy", "An automatic Wearable event is pending.")
            self.busy = str(uuid.uuid4())
            return self.busy

    def finish(self, token):
        with self.lock:
            if self.busy == token:
                self.busy = self.pending = None
                self.armed = False
                finish_event_gate(self, self.clock())


def result_metadata(result, direction):
    if result.get("label") not in ("horn", "siren", "crash", "normal"):
        raise ProtocolError(502, "unsupported_label", "Unsupported classifier label.")
    for key in ("confidence", "inference_ms"):
        value = result.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ProtocolError(502, "invalid_response", "Invalid classifier result.")
    if result["confidence"] > 1 or type(result.get("danger")) is not bool:
        raise ProtocolError(502, "invalid_response", "Invalid classifier confidence/decision.")
    return {key: result[key] for key in ("label", "confidence", "inference_ms", "danger")} | {"direction": direction}
