#!/usr/bin/env node

/**
 * Parakeet Transcriber — Node.js Orchestrator
 *
 * Manages a Python sidecar process that captures microphone audio and
 * transcribes it using NVIDIA Parakeet TDT v2 via parakeet-mlx on Apple Silicon.
 *
 * Transcriptions are stored in a SQLite database (transcriptions.db).
 */

import { spawn, execSync, execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { createInterface } from "node:readline";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";
import Database from "better-sqlite3";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const VENV_DIR = join(__dirname, ".venv");
const SIDECAR_DIR = join(__dirname, "sidecar");
const DB_PATH = join(__dirname, "transcriptions.db");
const REQUIREMENTS_FILE = join(SIDECAR_DIR, "requirements.txt");
const TRANSCRIBER_SCRIPT = join(SIDECAR_DIR, "transcriber.py");

const isWindows = process.platform === "win32";
const pythonBin = join(VENV_DIR, isWindows ? "Scripts" : "bin", "python3");
const pipBin = join(VENV_DIR, isWindows ? "Scripts" : "bin", "pip");

function findPython() {
  for (const cmd of ["python3", "python"]) {
    try {
      const version = execSync(`${cmd} --version 2>&1`, {
        encoding: "utf-8",
      }).trim();
      const match = version.match(/Python (\d+)\.(\d+)/);
      if (match) {
        const major = parseInt(match[1]);
        const minor = parseInt(match[2]);
        if (major >= 3 && minor >= 10) {
          console.log(`Found ${version}`);
          return cmd;
        }
        console.error(
          `${version} found but Python >=3.10 is required for parakeet-mlx.`
        );
      }
    } catch {
      // not found, try next
    }
  }
  return null;
}

async function ensurePythonEnvironment() {
  const systemPython = findPython();
  if (!systemPython) {
    console.error(
      "Python 3.10+ not found. Install it from https://www.python.org or via Homebrew:"
    );
    console.error("  brew install python@3.12");
    process.exit(1);
  }

  const needsCreate = !existsSync(pythonBin);

  if (needsCreate) {
    console.log("Creating Python virtual environment...");
    execSync(`${systemPython} -m venv "${VENV_DIR}"`, { stdio: "inherit" });
    console.log("Virtual environment created.");
  }

  // Only run pip install if venv was just created or requirements changed
  const markerFile = join(VENV_DIR, ".deps-installed");
  let needsInstall = needsCreate;

  if (!needsInstall) {
    try {
      const currentReqs = await readFile(REQUIREMENTS_FILE, "utf-8");
      const installedReqs = existsSync(markerFile)
        ? await readFile(markerFile, "utf-8")
        : "";
      needsInstall = currentReqs !== installedReqs;
    } catch {
      needsInstall = true;
    }
  }

  if (needsInstall) {
    console.log("Installing Python dependencies...");
    try {
      execFileSync(pipBin, ["install", "-r", REQUIREMENTS_FILE], {
        stdio: "inherit",
      });
      const reqs = await readFile(REQUIREMENTS_FILE, "utf-8");
      await writeFile(markerFile, reqs, "utf-8");
    } catch (err) {
      console.error("Failed to install Python dependencies:", err.message);
      process.exit(1);
    }
  }

  console.log("Python environment ready.");
}

// --- SQLite setup ---

function initDatabase() {
  const db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.exec(`
    CREATE TABLE IF NOT EXISTS transcriptions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp TEXT NOT NULL,
      text TEXT NOT NULL,
      raw_output TEXT NOT NULL
    )
  `);
  return db;
}

// --- Console grouping (5-second rule for display only) ---

const GROUP_GAP_MS = 5000;
let lastTimestamp = null;

function getTimeString(isoTimestamp) {
  const d = new Date(isoTimestamp);
  const hours = String(d.getHours()).padStart(2, "0");
  const minutes = String(d.getMinutes()).padStart(2, "0");
  const seconds = String(d.getSeconds()).padStart(2, "0");
  return `${hours}:${minutes}:${seconds}`;
}

function insertTranscription(db, insertStmt, text, rawOutput, timestamp) {
  const now = new Date(timestamp);
  const timeStr = getTimeString(timestamp);

  // Insert into SQLite
  insertStmt.run(timestamp, text, rawOutput);

  // Console output with 5-second grouping for readability
  const gap = lastTimestamp ? now.getTime() - lastTimestamp.getTime() : Infinity;
  if (gap <= GROUP_GAP_MS) {
    console.log(`           ${text}`);
  } else {
    console.log(`[${timeStr}] ${text}`);
  }

  lastTimestamp = now;
}

function spawnTranscriber(db, insertStmt) {
  const child = spawn(pythonBin, [TRANSCRIBER_SCRIPT], {
    stdio: ["ignore", "pipe", "pipe"],
    cwd: __dirname,
  });

  const rl = createInterface({ input: child.stdout });

  rl.on("line", (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      console.log(`[sidecar] ${line}`);
      return;
    }

    switch (msg.type) {
      case "status":
        console.log(`[status] ${msg.message}`);
        break;
      case "transcription":
        insertTranscription(
          db,
          insertStmt,
          msg.text,
          msg.raw_output || "",
          msg.timestamp
        );
        break;
      case "error":
        console.error(`[error] ${msg.message}`);
        break;
      default:
        console.log(`[sidecar] ${JSON.stringify(msg)}`);
    }
  });

  // Forward Python stderr to console for logs/progress
  const stderrRl = createInterface({ input: child.stderr });
  stderrRl.on("line", (line) => {
    console.error(`[sidecar] ${line}`);
  });

  child.on("error", (err) => {
    console.error(`Failed to start transcriber: ${err.message}`);
    process.exit(1);
  });

  child.on("exit", (code, signal) => {
    db.close();
    if (code !== 0 && code !== null) {
      console.error(`Transcriber exited with code ${code}`);
    }
    if (signal) {
      console.log(`Transcriber terminated by signal ${signal}`);
    }
    process.exit(code ?? 0);
  });

  return child;
}

async function main() {
  console.log("Parakeet Transcriber");
  console.log("====================\n");

  await ensurePythonEnvironment();

  const db = initDatabase();
  const insertStmt = db.prepare(
    "INSERT INTO transcriptions (timestamp, text, raw_output) VALUES (?, ?, ?)"
  );

  console.log(`Database: ${DB_PATH}\n`);

  const child = spawnTranscriber(db, insertStmt);

  // Graceful shutdown
  let shuttingDown = false;
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("\nShutting down...");
    child.kill("SIGTERM");
    // Force kill after 5 seconds if child doesn't exit
    setTimeout(() => {
      console.error("Force killing transcriber...");
      child.kill("SIGKILL");
      db.close();
      process.exit(1);
    }, 5000).unref();
  };

  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main();
