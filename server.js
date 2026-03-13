#!/usr/bin/env node

/**
 * Transcription Viewer — Express API + Static File Server
 *
 * Opens transcriptions.db and serves a Vue 3 web UI
 * for browsing, searching, and annotating transcriptions.
 */

import express from "express";
import Database from "better-sqlite3";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync } from "node:fs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const DB_PATH = join(__dirname, "transcriptions.db");
const PORT = process.env.PORT || 3000;

if (!existsSync(DB_PATH)) {
  console.error(`Database not found: ${DB_PATH}`);
  console.error("Run the transcriber first: npm start");
  process.exit(1);
}

const db = new Database(DB_PATH);
db.pragma("journal_mode = WAL");

// Create annotations table if it doesn't exist
db.exec(`
  CREATE TABLE IF NOT EXISTS annotations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    after_transcription_id INTEGER,
    timestamp TEXT NOT NULL,
    text TEXT NOT NULL,
    FOREIGN KEY (after_transcription_id) REFERENCES transcriptions(id)
  )
`);

const app = express();
app.use(express.json());

// GET /api/dates — distinct dates, most recent first
app.get("/api/dates", (req, res) => {
  const rows = db
    .prepare(
      `SELECT DISTINCT d FROM (
         SELECT date(timestamp) as d FROM transcriptions
         UNION
         SELECT date(timestamp) as d FROM annotations
       ) ORDER BY d DESC`
    )
    .all();
  res.json(rows.map((r) => r.d));
});

// GET /api/transcriptions?date=YYYY-MM-DD&search=term&after=id
app.get("/api/transcriptions", (req, res) => {
  const { date, search, after } = req.query;

  let sql = "SELECT id, timestamp, text, raw_output FROM transcriptions";
  const conditions = [];
  const params = {};

  if (date) {
    conditions.push("date(timestamp) = @date");
    params.date = date;
  }

  if (search) {
    conditions.push("text LIKE @search");
    params.search = `%${search}%`;
  }

  if (after) {
    conditions.push("id > @after");
    params.after = Number(after);
  }

  if (conditions.length > 0) {
    sql += " WHERE " + conditions.join(" AND ");
  }

  sql += " ORDER BY timestamp ASC";

  const rows = db.prepare(sql).all(params);
  res.json(rows);
});

// GET /api/annotations?date=YYYY-MM-DD&search=term&after_anno_id=id
app.get("/api/annotations", (req, res) => {
  const { date, search, after_anno_id } = req.query;

  let sql = "SELECT id, after_transcription_id, timestamp, text FROM annotations";
  const conditions = [];
  const params = {};

  if (date) {
    conditions.push("date(timestamp) = @date");
    params.date = date;
  }

  if (search) {
    conditions.push("text LIKE @search");
    params.search = `%${search}%`;
  }

  if (after_anno_id) {
    conditions.push("id > @after_anno_id");
    params.after_anno_id = Number(after_anno_id);
  }

  if (conditions.length > 0) {
    sql += " WHERE " + conditions.join(" AND ");
  }

  sql += " ORDER BY timestamp ASC";

  const rows = db.prepare(sql).all(params);
  res.json(rows);
});

// POST /api/annotations — create annotation
const insertAnnotation = db.prepare(
  "INSERT INTO annotations (after_transcription_id, timestamp, text) VALUES (@after_transcription_id, @timestamp, @text)"
);

app.post("/api/annotations", (req, res) => {
  const { after_transcription_id, text } = req.body;
  if (!text || text.trim().length === 0) {
    return res.status(400).json({ error: "text is required" });
  }
  const timestamp = new Date().toISOString();
  const result = insertAnnotation.run({
    after_transcription_id: after_transcription_id ?? null,
    timestamp,
    text: text.trim(),
  });
  res.json({
    id: result.lastInsertRowid,
    after_transcription_id: after_transcription_id ?? null,
    timestamp,
    text: text.trim(),
  });
});

// PUT /api/annotations/:id — update annotation text
const updateAnnotation = db.prepare(
  "UPDATE annotations SET text = @text WHERE id = @id"
);

app.put("/api/annotations/:id", (req, res) => {
  const { text } = req.body;
  if (!text || text.trim().length === 0) {
    return res.status(400).json({ error: "text is required" });
  }
  updateAnnotation.run({ id: Number(req.params.id), text: text.trim() });
  const row = db
    .prepare("SELECT id, after_transcription_id, timestamp, text FROM annotations WHERE id = @id")
    .get({ id: Number(req.params.id) });
  res.json(row);
});

// DELETE /api/annotations/:id
const deleteAnnotation = db.prepare("DELETE FROM annotations WHERE id = @id");

app.delete("/api/annotations/:id", (req, res) => {
  deleteAnnotation.run({ id: Number(req.params.id) });
  res.json({ ok: true });
});

// Static files served after API routes
app.use(express.static(join(__dirname, "public")));

app.listen(PORT, () => {
  console.log(`Transcription viewer running at http://localhost:${PORT}`);
});

process.on("SIGINT", () => {
  db.close();
  process.exit(0);
});
