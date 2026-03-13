#!/usr/bin/env python3
"""
Real-time microphone transcription engine using parakeet-mlx.

Captures audio from the default microphone, detects speech segments
using energy-based VAD, and transcribes them with NVIDIA Parakeet TDT v2
running on Apple Silicon via the MLX framework.

Communication protocol:
  - stdout: newline-delimited JSON messages (consumed by Node.js)
  - stderr: human-readable log/progress messages
"""

import sys
import json
import signal
import tempfile
import os
import wave
import collections
from datetime import datetime, timezone

import numpy as np
import sounddevice as sd

SAMPLE_RATE = 16000
CHANNELS = 1
FRAME_DURATION_MS = 30
FRAME_SIZE = int(SAMPLE_RATE * FRAME_DURATION_MS / 1000)  # 480 samples

# Energy-based VAD settings
RMS_THRESHOLD = 300  # RMS energy threshold for speech (int16 scale, 0-32767)
SPEECH_FRAMES_THRESHOLD = 6  # consecutive voiced frames to trigger speech start
SILENCE_FRAMES_THRESHOLD = 20  # consecutive unvoiced frames to trigger speech end (~600ms)
MAX_SPEECH_SECONDS = 30  # force-transcribe after this duration
MIN_SPEECH_SECONDS = 0.5  # ignore segments shorter than this

# Adaptive threshold settings
ADAPTIVE_THRESHOLD = True
NOISE_FLOOR_FRAMES = 100  # frames to sample for ambient noise level on startup
NOISE_FLOOR_MULTIPLIER = 3.0  # speech threshold = noise_floor * this


def log(msg):
    """Log to stderr so it doesn't interfere with the JSON protocol on stdout."""
    print(msg, file=sys.stderr, flush=True)


def emit(msg_type, **kwargs):
    """Send a JSON message to stdout for the Node.js orchestrator."""
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
    """Write speech frames to a temp WAV file, transcribe, and return (text, raw_output)."""
    raw = b"".join(frames)
    tmp_path = None
    try:
        fd, tmp_path = tempfile.mkstemp(suffix=".wav")
        with wave.open(os.fdopen(fd, "wb"), "wb") as wf:
            wf.setnchannels(CHANNELS)
            wf.setsampwidth(2)  # 16-bit
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(raw)
        result = model.transcribe(tmp_path)
        text = extract_text(result)
        raw_output = repr(result)
        return text, raw_output
    finally:
        if tmp_path and os.path.exists(tmp_path):
            os.unlink(tmp_path)


def calibrate_noise_floor(audio_queue, stream):
    """Sample ambient noise for a few seconds to set an adaptive threshold."""
    log("Calibrating noise floor (stay quiet for 2 seconds)...")
    emit("status", message="Calibrating noise floor (stay quiet for 2 seconds)...")
    energies = []
    while len(energies) < NOISE_FLOOR_FRAMES:
        if not audio_queue:
            sd.sleep(10)
            continue
        frame_bytes = audio_queue.popleft()
        expected_bytes = FRAME_SIZE * 2
        if len(frame_bytes) != expected_bytes:
            continue
        energies.append(rms_energy(frame_bytes))

    noise_floor = np.mean(energies)
    threshold = max(noise_floor * NOISE_FLOOR_MULTIPLIER, 200)  # minimum threshold of 200
    log(f"Noise floor: {noise_floor:.0f}, speech threshold: {threshold:.0f}")
    return threshold


def main():
    shutdown = False

    def handle_signal(signum, frame):
        nonlocal shutdown
        shutdown = True
        log("Received shutdown signal, finishing up...")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    # Load model
    emit("status", message="Loading model (first run will download ~1.2GB)...")
    log("Loading parakeet-mlx model...")
    try:
        from parakeet_mlx import from_pretrained
        model = from_pretrained("mlx-community/parakeet-tdt-0.6b-v2")
    except Exception as e:
        emit("error", message=f"Failed to load model: {e}")
        log(f"Error loading model: {e}")
        sys.exit(1)

    emit("status", message="Model loaded. Setting up microphone...")
    log("Model loaded. Setting up microphone...")

    # Ring buffer for pre-speech padding
    PADDING_FRAMES = 5
    ring_buffer = collections.deque(maxlen=PADDING_FRAMES)

    speech_frames = []
    is_speaking = False
    voiced_count = 0
    unvoiced_count = 0
    total_speech_frames = 0

    audio_queue = collections.deque()

    def audio_callback(indata, frame_count, time_info, status):
        if status:
            log(f"Audio status: {status}")
        pcm = (indata[:, 0] * 32767).astype(np.int16).tobytes()
        audio_queue.append(pcm)

    try:
        stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            blocksize=FRAME_SIZE,
            callback=audio_callback,
        )
        stream.start()
    except Exception as e:
        emit("error", message=f"Microphone not available: {e}")
        log(f"Error opening microphone: {e}")
        sys.exit(1)

    # Calibrate noise floor for adaptive threshold
    if ADAPTIVE_THRESHOLD:
        speech_threshold = calibrate_noise_floor(audio_queue, stream)
    else:
        speech_threshold = RMS_THRESHOLD

    emit("status", message="Listening...")
    log("Listening on default microphone...")

    try:
        while not shutdown:
            if not audio_queue:
                sd.sleep(10)
                continue

            frame_bytes = audio_queue.popleft()

            expected_bytes = FRAME_SIZE * 2
            if len(frame_bytes) != expected_bytes:
                continue

            energy = rms_energy(frame_bytes)
            is_voiced = energy > speech_threshold

            if not is_speaking:
                ring_buffer.append(frame_bytes)
                if is_voiced:
                    voiced_count += 1
                else:
                    voiced_count = 0

                if voiced_count >= SPEECH_FRAMES_THRESHOLD:
                    is_speaking = True
                    speech_frames = list(ring_buffer)
                    total_speech_frames = len(speech_frames)
                    voiced_count = 0
                    unvoiced_count = 0
                    ring_buffer.clear()
                    log("Speech detected...")
            else:
                speech_frames.append(frame_bytes)
                total_speech_frames += 1

                if is_voiced:
                    unvoiced_count = 0
                else:
                    unvoiced_count += 1

                speech_duration = total_speech_frames * FRAME_DURATION_MS / 1000.0
                silence_triggered = unvoiced_count >= SILENCE_FRAMES_THRESHOLD
                max_duration_reached = speech_duration >= MAX_SPEECH_SECONDS

                if silence_triggered or max_duration_reached:
                    if speech_duration >= MIN_SPEECH_SECONDS:
                        log(f"Transcribing {speech_duration:.1f}s segment...")
                        try:
                            text, raw_output = transcribe_segment(model, speech_frames)
                            if text:
                                timestamp = datetime.now(timezone.utc).isoformat()
                                emit("transcription", text=text, raw_output=raw_output, timestamp=timestamp)
                                log(f"Transcribed: {text}")
                        except Exception as e:
                            log(f"Transcription error: {e}")
                            emit("error", message=f"Transcription error: {e}")
                    else:
                        log(f"Skipping short segment ({speech_duration:.1f}s)")

                    speech_frames = []
                    is_speaking = False
                    voiced_count = 0
                    unvoiced_count = 0
                    total_speech_frames = 0
                    ring_buffer.clear()

    except KeyboardInterrupt:
        log("Interrupted by user.")
    finally:
        stream.stop()
        stream.close()

        if speech_frames:
            speech_duration = total_speech_frames * FRAME_DURATION_MS / 1000.0
            if speech_duration >= MIN_SPEECH_SECONDS:
                log(f"Transcribing final {speech_duration:.1f}s segment...")
                try:
                    text, raw_output = transcribe_segment(model, speech_frames)
                    if text:
                        timestamp = datetime.now(timezone.utc).isoformat()
                        emit("transcription", text=text, raw_output=raw_output, timestamp=timestamp)
                except Exception as e:
                    log(f"Final transcription error: {e}")

        log("Transcriber shut down.")


if __name__ == "__main__":
    main()
