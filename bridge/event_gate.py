"""Shared side-effect-free RMS/quiet/cooldown policy. Callers hold their own lock."""
def observe_event_gate(gate, levels, source_rms, now, *, max_age, can_trigger):
    if levels and max(levels) < gate.trigger_dbfs - 3:
        if gate.quiet_observed is None or now - gate.quiet_observed > max_age:
            gate.quiet_since = now
        gate.quiet_observed = now
        if now - gate.quiet_since >= gate.rearm_quiet:
            gate.armed = True
    else:
        gate.quiet_since = gate.quiet_observed = None
    return (can_trigger and now >= gate.cooldown_until and gate.armed
            and source_rms is not None and source_rms >= gate.trigger_dbfs)


def finish_event_gate(gate, now):
    gate.cooldown_until = now + gate.cooldown
    gate.quiet_since = gate.quiet_observed = None
