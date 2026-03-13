# Parakeet Transcriber

Real-time speech-to-text transcription for Mac using NVIDIA's Parakeet TDT v2 model, running locally on Apple Silicon via the MLX framework.

Captures audio from your Mac's default microphone, transcribes it in real time, and stores everything in a local SQLite database. Includes a web UI for browsing, searching, and annotating your transcriptions.

## Requirements

- **macOS** with Apple Silicon (M1/M2/M3/M4)
- **Node.js** 18+
- **Python** 3.10+

## Setup

```bash
# Clone the repo and install Node.js dependencies
npm install

# That's it. The first run handles everything else automatically:
# - Creates a Python virtual environment (.venv/)
# - Installs Python dependencies (parakeet-mlx, sounddevice, numpy)
# - Downloads the Parakeet TDT v2 model (~1.2GB, one-time)
```

## Usage

### 1. Start the transcriber

```bash
npm start
```

This captures audio from your default microphone and transcribes it in real time. Transcriptions are saved to `transcriptions.db` as they come in.

Your Mac will ask for microphone permission the first time you run this. On the very first launch, the model will download from HuggingFace (~1.2GB) which takes a minute or two.

Press `Ctrl+C` to stop.

### 2. Start the web UI

```bash
npm run serve
```

Opens a web viewer at [http://localhost:3000](http://localhost:3000) where you can:

- **Browse by date** using the left sidebar
- **View all messages** across all dates
- **Search** across all transcriptions
- **Add notes** between transcript lines (click the gap between messages)
- **Add longer notes** using the input at the bottom of the page
- **Edit or delete** existing notes by clicking on them

The web UI auto-updates every 2 seconds, so you can run the transcriber and viewer side by side.

## How it works

```
Microphone → Python sidecar (parakeet-mlx on Apple GPU)
                ↓
           Voice Activity Detection (energy-based)
                ↓
           Transcribe speech segments
                ↓
           Node.js orchestrator → SQLite database
                                       ↓
                                  Express web server → Vue.js UI
```

1. **Audio capture**: The Python sidecar captures 16kHz mono audio from the default mic using `sounddevice`
2. **Voice detection**: An energy-based VAD detects when you start and stop speaking. It calibrates to your ambient noise level on startup (stay quiet for 2 seconds)
3. **Transcription**: When a speech segment ends (~600ms of silence), the audio is sent to the Parakeet TDT v2 model running on the Apple GPU via MLX
4. **Storage**: The Node.js process receives the transcription and inserts it into SQLite immediately
5. **Viewing**: A separate Express server reads the same database and serves a Vue.js web UI

## Project structure

```
├── index.js                 # Node.js orchestrator (manages Python sidecar, writes to DB)
├── server.js                # Express API + static file server for the web UI
├── package.json
├── public/
│   └── index.html           # Vue 3 single-page app (no build step)
├── sidecar/
│   ├── transcriber.py       # Python audio capture + transcription engine
│   └── requirements.txt     # Python dependencies
├── .venv/                   # Auto-created Python virtual environment
└── transcriptions.db        # Auto-created SQLite database
```

## Database schema

```sql
-- Each transcribed speech segment
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,       -- ISO 8601 UTC
    text TEXT NOT NULL,            -- Clean transcription text
    raw_output TEXT NOT NULL       -- Full model output with word-level timing and confidence
);

-- User-added notes anchored between transcription lines
CREATE TABLE annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    after_transcription_id INTEGER,  -- Which transcription this note follows (NULL = top)
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL,
    FOREIGN KEY (after_transcription_id) REFERENCES transcriptions(id)
);
```

## Configuration

The Python sidecar has tunable constants at the top of `sidecar/transcriber.py`:

| Setting | Default | Description |
|---|---|---|
| `SAMPLE_RATE` | 16000 | Audio sample rate in Hz |
| `SILENCE_FRAMES_THRESHOLD` | 20 | Frames of silence before ending a segment (~600ms) |
| `MAX_SPEECH_SECONDS` | 30 | Force-transcribe after this duration |
| `MIN_SPEECH_SECONDS` | 0.5 | Ignore segments shorter than this |
| `NOISE_FLOOR_MULTIPLIER` | 3.0 | Speech threshold = ambient noise level x this |
