#!/usr/bin/env python3
"""
Real-time transcription engine using parakeet-mlx.

The Mac app writes speaker-tagged PCM frames to stdin. This process detects
speech with energy-based VAD and transcribes it with NVIDIA Parakeet TDT v2
on Apple Silicon via MLX.

Communication protocol:
  - stdin: each frame is one speaker byte (0 = you, 1 = caller) followed by
    960 bytes of 16 kHz mono int16le PCM
  - stdout: newline-delimited JSON messages
  - stderr: human-readable log/progress messages
"""

import sys
import json
import signal
import collections
import threading
import time
from datetime import datetime, timezone

import numpy as np

SAMPLE_RATE = 16000
FRAME_DURATION_MS = 30
FRAME_SIZE = int(SAMPLE_RATE * FRAME_DURATION_MS / 1000)  # 480 samples

# Energy-based VAD settings
RMS_THRESHOLD = 300  # RMS energy threshold for speech (int16 scale, 0-32767)
SPEECH_FRAMES_THRESHOLD = 6  # consecutive voiced frames to trigger speech start
SILENCE_FRAMES_THRESHOLD = 20  # consecutive unvoiced frames to trigger speech end (~600ms)
MAX_SPEECH_SECONDS = 30  # force-transcribe after this duration
MIN_SPEECH_SECONDS = 0.5  # ignore segments shorter than this

# Adaptive threshold settings
NOISE_FLOOR_FRAMES = 100  # frames to sample for ambient noise level on startup
NOISE_FLOOR_MULTIPLIER = 3.0  # speech threshold = noise_floor * this


def log(msg):
    """Log to stderr so it doesn't interfere with the JSON protocol on stdout."""
    print(msg, file=sys.stderr, flush=True)


def emit(msg_type, **kwargs):
    """Send a JSON message to stdout for the Mac app."""
    msg = {"type": msg_type, **kwargs}
    print(json.dumps(msg), flush=True)


def rms_energy(pcm_bytes):
    """Calculate RMS energy of a PCM int16 audio frame."""
    samples = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float64)
    if len(samples) == 0:
        return 0.0
    return np.sqrt(np.mean(samples ** 2))


def extract_text(result):
    """Extract the clean text string from a transcription result."""
    if hasattr(result, "text"):
        return result.text.strip()
    elif isinstance(result, dict):
        return result.get("text", "").strip()
    elif isinstance(result, str):
        return result.strip()
    elif isinstance(result, (list, tuple)) and len(result) > 0:
        first = result[0]
        if hasattr(first, "text"):
            return first.text.strip()
        elif isinstance(first, dict):
            return first.get("text", "").strip()
        return str(first).strip()
    return str(result).strip()


def transcribe_segment(model, frames):
    """Transcribe int16 PCM frames and return (text, raw_output).

    parakeet-mlx's file API shells out to ffmpeg. The app already captured
    16 kHz mono PCM, which is the same format ffmpeg would have produced.
    """
    import mlx.core as mx
    from parakeet_mlx.audio import get_logmel

    pcm = np.frombuffer(b"".join(frames), dtype=np.int16)
    samples = pcm.astype(np.float32) / 32768.0
    target_rate = int(model.preprocessor_config.sample_rate)
    if target_rate != SAMPLE_RATE and len(samples) > 1:
        target_length = max(1, int(round(len(samples) * target_rate / SAMPLE_RATE)))
        source_x = np.linspace(0.0, 1.0, num=len(samples), endpoint=False)
        target_x = np.linspace(0.0, 1.0, num=target_length, endpoint=False)
        samples = np.interp(target_x, source_x, samples).astype(np.float32)

    audio = mx.array(samples)
    mel = get_logmel(audio, model.preprocessor_config)
    result = model.generate(mel)[0]
    return extract_text(result), repr(result)


MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v2"


def _cached_file(model_id, filename):
    """Return a local HF cache path for filename, or None if missing."""
    from huggingface_hub import try_to_load_from_cache

    path = try_to_load_from_cache(model_id, filename)
    return path if isinstance(path, str) else None


def resolve_model_files(model_id=MODEL_ID):
    """
    Resolve config.json + model.safetensors, preferring the local HF cache.

    Avoids parakeet_mlx.from_pretrained's hub-then-local fallback, which turns
    SSL/network failures into a misleading FileNotFoundError on the repo id path.
    """
    from huggingface_hub import hf_hub_download

    config_path = _cached_file(model_id, "config.json")
    weight_path = _cached_file(model_id, "model.safetensors")
    if config_path and weight_path:
        log(f"Using cached model files for {model_id}")
        return config_path, weight_path

    log(f"Model not fully cached; downloading {model_id}...")
    try:
        config_path = hf_hub_download(model_id, "config.json")
        weight_path = hf_hub_download(model_id, "model.safetensors")
        return config_path, weight_path
    except Exception as e:
        raise RuntimeError(
            f"Could not download model '{model_id}'. "
            "On macOS with the python.org installer, run "
            "'Install Certificates.command' from /Applications/Python 3.x/, "
            "then retry. "
            f"Underlying error: {e}"
        ) from e


def load_model(model_id=MODEL_ID):
    """Load Parakeet from HF cache or download, without relying on from_pretrained."""
    import json

    import mlx.core as mx
    from mlx.utils import tree_flatten, tree_unflatten
    from parakeet_mlx.utils import from_config

    config_path, weight_path = resolve_model_files(model_id)
    with open(config_path, "r") as f:
        config = json.load(f)

    model = from_config(config)
    model.load_weights(weight_path)

    dtype = mx.bfloat16
    curr_weights = [(k, v.astype(dtype)) for k, v in dict(tree_flatten(model.parameters())).items()]
    model.update(tree_unflatten(curr_weights))
    return model


def start_speaker_reader(audio_queue, stdin_closed):
    """Read speaker-tagged PCM frames: 1 byte speaker + 960 bytes PCM."""
    frame_len = FRAME_SIZE * 2

    def run():
        while True:
            header = sys.stdin.buffer.read(1)
            if not header:
                stdin_closed.set()
                break
            payload = sys.stdin.buffer.read(frame_len)
            if len(payload) != frame_len:
                stdin_closed.set()
                break
            speaker = "you" if header[0] == 0 else "caller"
            audio_queue.append((speaker, payload))

    threading.Thread(target=run, daemon=True).start()


class SpeechSegmenter:
    """Energy VAD for one speaker. Emits a transcription when a phrase ends."""

    def __init__(self, speaker, threshold):
        self.speaker = speaker
        self.threshold = threshold
        self.ring_buffer = collections.deque(maxlen=5)
        self.speech_frames = []
        self.is_speaking = False
        self.voiced_count = 0
        self.unvoiced_count = 0
        self.total_speech_frames = 0

    def push(self, model, frame_bytes):
        energy = rms_energy(frame_bytes)
        is_voiced = energy > self.threshold

        if not self.is_speaking:
            self.ring_buffer.append(frame_bytes)
            if is_voiced:
                self.voiced_count += 1
            else:
                self.voiced_count = 0

            if self.voiced_count >= SPEECH_FRAMES_THRESHOLD:
                self.is_speaking = True
                self.speech_frames = list(self.ring_buffer)
                self.total_speech_frames = len(self.speech_frames)
                self.voiced_count = 0
                self.unvoiced_count = 0
                self.ring_buffer.clear()
                log(f"Speech detected ({self.speaker})...")
            return

        self.speech_frames.append(frame_bytes)
        self.total_speech_frames += 1
        if is_voiced:
            self.unvoiced_count = 0
        else:
            self.unvoiced_count += 1

        speech_duration = self.total_speech_frames * FRAME_DURATION_MS / 1000.0
        silence_triggered = self.unvoiced_count >= SILENCE_FRAMES_THRESHOLD
        max_duration_reached = speech_duration >= MAX_SPEECH_SECONDS
        if silence_triggered or max_duration_reached:
            self._finish(model, speech_duration)

    def flush(self, model):
        if not self.speech_frames:
            return
        speech_duration = self.total_speech_frames * FRAME_DURATION_MS / 1000.0
        self._finish(model, speech_duration)

    def _finish(self, model, speech_duration):
        if speech_duration >= MIN_SPEECH_SECONDS:
            log(f"Transcribing {speech_duration:.1f}s {self.speaker} segment...")
            try:
                text, raw_output = transcribe_segment(model, self.speech_frames)
                if text:
                    timestamp = datetime.now(timezone.utc).isoformat()
                    emit(
                        "transcription",
                        text=text,
                        raw_output=raw_output,
                        timestamp=timestamp,
                        speaker=self.speaker,
                    )
                    log(f"Transcribed ({self.speaker}): {text}")
            except Exception as e:
                log(f"Transcription error: {e}")
                emit("error", message=f"Transcription error: {e}")
        else:
            log(f"Skipping short {self.speaker} segment ({speech_duration:.1f}s)")

        self.speech_frames = []
        self.is_speaking = False
        self.voiced_count = 0
        self.unvoiced_count = 0
        self.total_speech_frames = 0
        self.ring_buffer.clear()


def calibrate_you(audio_queue, stdin_closed):
    """Sample the local microphone. Call audio that arrives early is kept."""
    log("Calibrating noise floor (stay quiet for 2 seconds)...")
    emit("status", message="Calibrating noise floor (stay quiet for 2 seconds)...")
    energies = []
    parked_caller = []
    while len(energies) < NOISE_FLOOR_FRAMES:
        if stdin_closed.is_set() and not audio_queue:
            raise RuntimeError("Audio stream ended during calibration")
        if not audio_queue:
            time.sleep(0.01)
            continue
        speaker, frame_bytes = audio_queue.popleft()
        if speaker == "you":
            energies.append(rms_energy(frame_bytes))
        else:
            parked_caller.append(frame_bytes)

    noise_floor = float(np.mean(energies))
    threshold = max(noise_floor * NOISE_FLOOR_MULTIPLIER, 200)
    log(f"Noise floor: {noise_floor:.0f}, speech threshold: {threshold:.0f}")
    return threshold, parked_caller


def run_speaker_session(model, audio_queue, stdin_closed, should_stop):
    threshold, parked_caller = calibrate_you(audio_queue, stdin_closed)
    you = SpeechSegmenter("you", threshold)
    caller = SpeechSegmenter("caller", RMS_THRESHOLD)
    caller_noise = []

    def push_caller(frame_bytes):
        if len(caller_noise) < NOISE_FLOOR_FRAMES:
            energy = rms_energy(frame_bytes)
            if energy < caller.threshold:
                caller_noise.append(energy)
            if len(caller_noise) == NOISE_FLOOR_FRAMES:
                floor = float(np.mean(caller_noise))
                caller.threshold = max(floor * NOISE_FLOOR_MULTIPLIER, 200)
                log(f"Caller noise floor: {floor:.0f}, speech threshold: {caller.threshold:.0f}")
        caller.push(model, frame_bytes)

    emit("status", message="Listening...")
    log("Listening...")
    for frame_bytes in parked_caller:
        push_caller(frame_bytes)

    while not should_stop():
        if not audio_queue:
            if stdin_closed.is_set():
                break
            time.sleep(0.01)
            continue
        speaker, frame_bytes = audio_queue.popleft()
        if speaker == "you":
            you.push(model, frame_bytes)
        else:
            push_caller(frame_bytes)

    you.flush(model)
    caller.flush(model)


def main():
    shutdown = False

    def handle_signal(signum, frame):
        nonlocal shutdown
        shutdown = True
        log("Received shutdown signal, finishing up...")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    emit("status", message="Loading model (first run will download ~1.2GB)...")
    log("Loading parakeet-mlx model...")
    try:
        model = load_model()
    except Exception as e:
        emit("error", message=f"Failed to load model: {e}")
        log(f"Error loading model: {e}")
        sys.exit(1)

    emit("status", message="Model loaded. Waiting for audio...")
    log("Model loaded. Waiting for audio...")

    audio_queue = collections.deque()
    stdin_closed = threading.Event()
    start_speaker_reader(audio_queue, stdin_closed)
    try:
        run_speaker_session(model, audio_queue, stdin_closed, lambda: shutdown)
    except Exception as e:
        emit("error", message=str(e))
        log(f"Error reading speaker audio: {e}")
        sys.exit(1)
    log("Transcriber shut down.")


if __name__ == "__main__":
    main()
