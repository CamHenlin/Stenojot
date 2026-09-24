# Stenojot

## About

I wanted a transcription tool that stayed on my computer and was still useful after the words were written down. The local tools I tried could turn speech into text, and then they stopped. I wanted one app that could do all of this:

- Transcribe a conversation well, including both sides of a call
- Force replacements, so names, terms, and recurring mistakes come out the way I want
- Annotate the transcript as it happens, and keep those notes with the text
- Use a local language model to pull action items out of what was said
- Use a local language model to write a summary of the day
- Ask that same model questions about part of a transcript, or about the whole day

Nothing I found did all of that together, so I built Stenojot.

The name is steno and jot. Steno is shorthand for writing down what was said. Jot is the note that stays with it. The speech model inside the app is still NVIDIA Parakeet. That name is the model, not the app.

## Download

[Download Stenojot](https://github.com/CamHenlin/Stenojot/releases/latest/download/Stenojot.zip) for an Apple Silicon Mac on macOS 14 or later.

Unzip it and move **Stenojot** to Applications. The first time you open it, Control-click the app and choose Open, then Open again. macOS does not recognize this copy's signature, so a normal double-click stays blocked until you do that.

The zip does not include the transcription packages or the model weights. Those download on first launch.

It is a Mac app. It listens while you talk, writes the transcript down as you go, and keeps everything on the machine. The language model runs on the Mac too, so questions, action items, and daily summaries stay there with the transcript.

## Features

### Transcription

- Listens to the microphone and, with permission, to call audio, so both sides of a conversation are transcribed
- Labels each line **You** or **Others**
- On headphones, the two sides stay separate on their own. On speakers, call audio is taken out of the microphone so the other person is not written down twice
- If call audio is declined, the microphone is still transcribed
- Starts listening when the app opens. Closing the window leaves it running. Quitting stops it
- New lines appear as they are saved. The transcript stays pinned to the latest line until you scroll up
- Drops a stray "Yeah" or "Okay" that shows up in a notification sound or other background noise
- Can be restarted from the window if listening stops

### Reading the transcript

- Days are listed in a sidebar. The window opens on the latest day
- Search filters the day list and the lines on the selected day. Matches include the transcript and notes
- Click one line, then another, to select a stretch. Copy puts that stretch on the clipboard, including notes that fall inside it
- Escape clears a selection in progress

### Notes

- Click the gap between lines to insert a note
- Type a longer note in the composer at the bottom of the window
- Notes can be edited or deleted

### Text replacements

- A list of find-and-replace rules, edited from the toolbar
- Each new line is rewritten before it is saved
- Matching is by whole word and ignores case
- A rule with an empty replacement deletes the matched text
- Leftover punctuation and extra spaces are cleaned up
- Apply to All Past Transcripts rewrites what is already saved. A line that becomes empty is removed, along with notes attached to it

### Asking questions

- A language model runs on the Mac. It downloads once and stays on disk
- Ask about the full day, or about the stretch you selected. The same selection you can copy is what the model sees
- The question includes who said each line, and any notes in that stretch
- The reply streams into the panel and is saved on the transcript
- The instruction that steers those answers can be edited in the panel
- Several model sizes are available, from a small one that fits a short question on an 8 GB Mac to larger ones that handle a full day more comfortably

### Action items

- A checklist sits beside the transcript and can be shown or hidden
- After a pause of about 30 seconds, the model reads the latest stretch and adds concrete tasks
- A stretch is only scanned once
- Add, check off, and delete items yourself
- The list still accepts items you type when no model is downloaded

### Daily summaries

- Each day has Generate, or View once a summary exists
- The day is split into stretches. A new stretch starts after more than a minute with nothing said, so two conversations that follow each other closely can stay in one stretch
- Notes are included when they add something the transcript does not
- Action items for the day are appended on their own
- A second pass reads the finished summary and removes passages that add nothing, such as a note that someone only said "Yeah"
- The result can be edited and saved
- If the app stays open past midnight, it writes summaries for the days that ended while it was running. A day it was closed for is left alone until you press Generate
- The instruction for each stretch, and the instruction for the cleanup pass, can each be edited. An empty instruction uses the built-in one

### Your files

- Transcripts, notes, action items, and summaries live in a database on this Mac
- Replacements, prompts, and the chosen model live in a settings file on this Mac
- On first launch, start empty or import an existing database, and optionally an existing settings file
- Import Database… and Import Settings… can replace those files later

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

To publish a downloadable build, tag a Release and upload a zip named `Stenojot.zip`. The README link always points at that file on the latest release:

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

## First launch

1. Launch Stenojot.
2. Choose an existing `transcriptions.db`, or click Start Empty. Import uses a SQLite backup, so the `-wal` file is included. The copy lives at `~/Library/Application Support/Stenojot/transcriptions.db`. The original file stays where it was.
3. Optionally choose an existing `config.json` in the same sheet. A new install starts with an empty replacement list.
4. Allow the microphone, then allow system audio recording so the other person on a call is transcribed separately.
5. Wait for the one-time `pip install` of `parakeet-mlx` and `numpy`. The Parakeet weights stay in the Hugging Face cache (`~/.cache/huggingface`). The first sidecar launch downloads `mlx-community/parakeet-tdt-0.6b-v2` if it is not already there.

File > Import Database… and File > Import Settings… can replace those files later. Importing a database replaces the app's copy. Importing settings replaces `config.json`.

## Daily use

Launching the app starts listening and opens the transcript window. Closing the window leaves transcription running. Quit the app to stop the sidecar and unload the language model.

The window opens on the latest day. The sidebar lists days, and the search field filters both the day list and the lines on the selected day. Matches include transcript text and notes. New lines show up as they are saved, and the list stays pinned to the bottom until you scroll up.

Each line is labeled **You** or **Others**. Headphones keep the two streams apart on their own. On speakers, the app subtracts the call audio from the microphone so the other side is not transcribed twice. If system audio is declined, the app still transcribes the microphone and labels those lines You.

### Notes and ranges

Click the gap between lines to insert a note, or type a longer note in the composer at the bottom. Notes can be edited or deleted. Click a transcript line, then another, to select a range. Copy puts that range on the clipboard, including notes that fall inside it. The same range is what the language-model panel sends when you ask a question. Escape clears a selection in progress.

### Text replacements

Text Replacements, in the toolbar, stores find-and-replace rules in `config.json`. Rules run on each new line before it is inserted. Matching is word-boundary and case-insensitive, then punctuation and extra spaces are cleaned up. A rule with an empty replacement deletes the matched text. Apply to All Past Transcripts rewrites existing rows and deletes a row, plus notes anchored to it, when the text becomes empty.

A lone "Yeah" after more than 30 seconds of silence is dropped. Parakeet often hears that in notification sounds.

### Language model

The app runs a language model in-process with MLX. Choose a model from LLM Settings in the menu bar (⇧⌘L). Weights download once into `~/Library/Application Support/Stenojot/models/` and stay there after you quit. Open the LLM panel at the bottom of the transcript to ask about the day.

| Model | Hugging Face id | Download | Memory while loaded |
|---|---|---|---|
| Gemma 3 1B | `mlx-community/gemma-3-1b-it-qat-4bit` | 0.8 GB | About 2 GB |
| Llama 3.2 3B | `mlx-community/Llama-3.2-3B-Instruct-4bit` | 1.8 GB | About 4 GB |
| Qwen 2.5 7B (recommended) | `mlx-community/Qwen2.5-7B-Instruct-4bit` | 4.3 GB | About 7 GB |
| Qwen 3 8B | `mlx-community/Qwen3-8B-4bit` | 4.6 GB | About 8 GB |

Memory above is the weights before a long transcript adds more. Gemma fits a short question on an 8 GB Mac. Qwen 2.5 7B is the better fit for a full day, and is comfortable on 16 GB.

Ask a question about the full day, or about the selected range. The prompt includes transcript lines, with speaker labels, and any notes in that context. The reply streams into the panel and is saved on the transcript as an LLM note. The instruction sent with those questions is edited from System Prompt > Transcript… in the menu bar and stored as `systemPrompt`. Leave it empty to send only the transcript and the question. Reset clears it. Qwen-style `<think>` spans are stripped from the streamed text.

The same loaded model writes action items and daily summaries. Switching models unloads the previous one.

### Action items

The checklist inspector is open by default. After about 30 seconds of silence, a finished stretch of transcript is sent to the language model, which returns a JSON array of concrete tasks. Those tasks are appended to the list. You can also add, check off, and delete items yourself. The panel still accepts manual items when no model is downloaded. The app remembers the last transcription id it has already scanned, so a stretch is not extracted twice.

### Daily summaries

Each day in the sidebar has Generate, or View once a summary exists. A summary is built from stretches of that day. A new stretch starts only after more than a minute with no transcript, so two conversations that follow each other closely can still land in one stretch. The model summarizes each stretch, notes are included when they add something the transcript does not, and action items are appended separately. A second pass then reads that full summary and removes passages that add no information, such as a note that someone only said "Yeah". The result is editable. Save writes it back.

If the app stays running across local midnight, it generates summaries for the days that ended while it was open. Opening the app the next morning does not summarize a day it missed. Use Generate for those.

The instruction for each stretch is edited from System Prompt > Summary… in the menu bar. The cleanup pass is edited from System Prompt > Summary Pass 2…. An empty prompt uses the built-in one. Reset in either window restores its built-in text.

### Logs

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
| `config.json` | Replacements, chat system prompt, summary prompts, selected model id |
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
