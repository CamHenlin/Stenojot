# Developing Stenojot

How the app is built and how the pieces fit together. For what it does and how to use it, see [Stenojot](README.md).

## Requirements

- Apple Silicon Mac
- Xcode 15 or later (the app targets macOS 14)
- Network on the first build, so the build can download a relocatable CPython
- Network on first launch, so the app can install `parakeet-mlx` and download the Parakeet weights if they are not already in the Hugging Face cache

## Build and run

Open [macos/Stenojot.xcodeproj](macos/Stenojot.xcodeproj) and run the Stenojot scheme.

The first build does two setup steps:

1. [macos/Scripts/ensure-codesign-identity.sh](macos/Scripts/ensure-codesign-identity.sh) creates a local code-signing identity named `StenojotDev` in `macos/.codesign/` (gitignored). Screen Recording permission is tied to the signature. A stable identity means a rebuild does not look like a new app to macOS. Delete that keychain and macOS will ask for microphone and system audio again.
2. [macos/Scripts/prepare-python.sh](macos/Scripts/prepare-python.sh) downloads CPython 3.12 from [python-build-standalone](https://github.com/astral-sh/python-build-standalone) into `macos/Vendor/` (gitignored). [macos/Scripts/bundle-resources.sh](macos/Scripts/bundle-resources.sh) copies that runtime, [sidecar/transcriber.py](sidecar/transcriber.py), and [sidecar/requirements-app.txt](sidecar/requirements-app.txt) into the app. Later builds reuse the download.

From the command line:

```bash
xcodebuild -project macos/Stenojot.xcodeproj -scheme Stenojot -configuration Debug build
```

The product is `Stenojot.app`. Copy it to `/Applications` when you want it there. The Python virtualenv records the path of the bundled interpreter. Move the app after that environment exists and the next launch rebuilds it.

To publish a downloadable build, tag a Release and upload a zip named `Stenojot.zip`. The download link in the [README](README.md) always points at that file on the latest release:

```bash
macos/Scripts/release.sh v1.0.0
```

Core logic tests, with no microphone and no model:

```bash
cd macos/TranscriberCore && swift test
```

[macos/project.yml](macos/project.yml) is the XcodeGen spec. If it changes, regenerate the Xcode project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
cd macos && xcodegen generate
```

## Logs

Transcription logs go to the macOS unified log. In Console.app, filter on subsystem `com.stenojot.app`, or from Terminal:

```bash
log stream --predicate 'subsystem == "com.stenojot.app"' --level info
```

That stream includes Python setup, model download progress, voice detection, and each transcribed line.

## How it works

```
Microphone → echo cancellation → "you"
Call audio  →                  → "caller"
                ↓ tagged 30 ms frames
           Python sidecar (one VAD per speaker + parakeet-mlx)
                ↓ JSON lines, with speaker
           Swift → SQLite → SwiftUI
                              ↘ MLX language model
                                 action items, daily summaries, questions
```

Swift captures both streams, aligns them, and runs a normalized LMS echo canceller with the call audio as the reference. The mixer emits 30 ms frames (480 samples at 16 kHz) tagged with who was speaking. The app writes those frames to the sidecar's stdin: one speaker byte (`0` = you, `1` = caller) followed by 960 bytes of mono int16 PCM.

The sidecar keeps a separate energy-based voice detector for each speaker. It calibrates a noise floor at startup, ends a segment after about 600 ms of silence, and transcribes with Parakeet. Results come back as newline-delimited JSON on stdout. Logs stay on stderr. The model stays loaded in the sidecar until you quit.

[macos/TranscriberCore](macos/TranscriberCore) holds the pieces that do not need a microphone or a window: the SQLite schema, replacements, echo cancellation, speaker mixing, prompts, action-item parsing, and daily-summary assembly. The app target is SwiftUI plus audio capture, the sidecar process, and the MLX model runner.

## Project structure

```
├── macos/
│   ├── project.yml                  # XcodeGen spec
│   ├── Stenojot.xcodeproj
│   ├── Scripts/
│   │   ├── ensure-codesign-identity.sh
│   │   ├── prepare-python.sh
│   │   ├── bundle-resources.sh
│   │   └── release.sh
│   ├── Transcriber/                 # SwiftUI app, audio capture, sidecar, MLX runner
│   └── TranscriberCore/             # Library and unit tests
├── sidecar/
│   ├── transcriber.py               # VAD + Parakeet
│   └── requirements-app.txt         # parakeet-mlx, numpy
```

`macos/Vendor/`, `macos/.codesign/`, and `macos/TranscriberCore/.build/` are created locally and gitignored.

Swift packages, pinned in [macos/project.yml](macos/project.yml) and [macos/TranscriberCore/Package.swift](macos/TranscriberCore/Package.swift):

- [GRDB](https://github.com/groue/GRDB.swift) for SQLite
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) 3.31.4, plus Hugging Face and swift-transformers, for the in-app language model

## Data on disk

Everything the app writes lives under `~/Library/Application Support/Stenojot/`:

| Path | Contents |
|---|---|
| `transcriptions.db` | Transcripts, notes, action items, daily summaries |
| `config.json` | Replacements, chat, action-item, and summary prompts, selected model id |
| `models/` | Downloaded MLX weights |
| `venv/` | Virtualenv created from the bundled CPython |

The Parakeet weights themselves stay in `~/.cache/huggingface`.

## Database schema

Existing databases are migrated on open. Rows from before the speaker column existed are backfilled as `caller`. Annotations from before `kind` existed are ordinary notes.

```sql
CREATE TABLE transcriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL,
    raw_output TEXT NOT NULL,
    speaker TEXT NOT NULL DEFAULT 'caller'
);

CREATE TABLE annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    after_transcription_id INTEGER,
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'note',
    FOREIGN KEY (after_transcription_id) REFERENCES transcriptions(id)
);

CREATE TABLE action_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL,
    done INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE action_extractor_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    last_transcription_id INTEGER NOT NULL
);

CREATE TABLE daily_summaries (
    day TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
```

`speaker` is `you` or `caller`. `kind` is `note` or `llm`. `raw_output` is stored and is not loaded into the message list. `day` is the local calendar day (`YYYY-MM-DD`).

## Configuration

`config.json` stores:

| Key | Role |
|---|---|
| `replacements` | `{ "from", "to" }` rules applied before insert |
| `systemPrompt` | Instruction sent with questions about the transcript |
| `summarySystemPrompt` | Instruction sent with each stretch of a daily summary. Empty uses the built-in prompt |
| `summaryPass2SystemPrompt` | Instruction for the cleanup pass over a finished daily summary. Empty uses the built-in prompt |
| `actionItemsSystemPrompt` | Instruction sent when extracting action items from a finished transcript stretch. Empty uses the built-in prompt |
| `localModelId` | Hugging Face id of the model chosen in LLM Settings |

An older settings file may still contain an `ollama` block. The app keeps that block when it saves and runs the in-process MLX model instead.

## Sidecar tuning

Constants at the top of [sidecar/transcriber.py](sidecar/transcriber.py):

| Setting | Default | Description |
|---|---|---|
| `SAMPLE_RATE` | 16000 | Audio sample rate in Hz |
| `FRAME_DURATION_MS` | 30 | Frame size written by the app |
| `SPEECH_FRAMES_THRESHOLD` | 6 | Consecutive voiced frames before speech starts |
| `SILENCE_FRAMES_THRESHOLD` | 20 | Frames of silence before ending a segment (~600 ms) |
| `MAX_SPEECH_SECONDS` | 30 | Force-transcribe after this duration |
| `MIN_SPEECH_SECONDS` | 0.5 | Ignore segments shorter than this |
| `NOISE_FLOOR_MULTIPLIER` | 3.0 | Speech threshold = ambient noise level × this |
| `MODEL_ID` | `mlx-community/parakeet-tdt-0.6b-v2` | Parakeet weights |
