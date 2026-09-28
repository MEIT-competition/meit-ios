"""Transport adapter for the separately installed, unmodified meit-ai repository."""
import importlib
import importlib.util
import math
import sys
import time
from pathlib import Path

PAYLOAD_BYTES = 80_000


class MEITAIAdapter:
    def __init__(self, repository):
        root = Path(repository).expanduser().resolve()
        entry = root / "classifier" / "adapter.py"
        model = root / "model" / "saved_model" / "danger_sound_classifier"
        if not entry.is_file():
            raise ValueError("MEIT_AI_PATH must contain classifier/adapter.py.")
        if not (model / "saved_model.pb").is_file():
            raise ValueError("Existing meit-ai SavedModel is missing.")
        # Use the existing package API, without installing or copying its source.
        sys.path.insert(0, str(root))
        importlib.invalidate_caches()
        previous = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            spec = importlib.util.find_spec("classifier.adapter")
            if spec is None or Path(spec.origin or "").resolve() != entry:
                raise ValueError("classifier.adapter resolves outside MEIT_AI_PATH.")
            self.api = importlib.import_module("classifier.adapter")
            self.np = importlib.import_module("numpy")
        finally:
            sys.dont_write_bytecode = previous
        if self.api.SR != 16_000 or self.api.CLIP_SEC != 2.5:
            raise ValueError("Existing AI input contract differs from 16000 Hz / 2.5 s.")
        self.api.load_model()
        self.api.load_temperature()

    def infer(self, payload):
        if len(payload) != PAYLOAD_BYTES:
            raise ValueError("Expected exactly 80000 PCM16LE bytes.")
        # Decode the wire representation only. All model preprocessing stays in meit-ai.
        waveform = self.np.frombuffer(payload, dtype="<i2").astype(self.np.float32)
        waveform /= 32768.0
        started = time.perf_counter()
        probabilities, _dbfs = self.api.predict_array(waveform)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
        if set(probabilities) != set(self.api.CLASSES) or not probabilities:
            raise ValueError("Unexpected AI class output.")
        if any(not math.isfinite(p) or not 0.0 <= p <= 1.0 for p in probabilities.values()):
            raise ValueError("Invalid AI confidence output.")
        label = max(probabilities, key=probabilities.get)
        return {"label": label, "confidence": float(probabilities[label]),
                "inference_ms": elapsed_ms}
