# kibod

The phase-one Kibo server and browser client.

## Data layout

```text
kibo-data/
  projects/<project-id>/
    project.json
    knowledge/
      instructions.md
      ingested.json
      web/<source-id>/versions/<content-sha256>/content.md
      wiki/index.md
      wiki/sources/<kind>--<source-id>.md
    conversations/<conversation-id>/
      conversation.json
      turns.jsonl
      clips/<clip-id>.wav
      tts/<turn-id>.wav
```

`turns.jsonl` is the durable source of truth and has one monotonic `seq` per
conversation. Blob files are synced and renamed before their events are
appended. The Gemini `interaction_id` saved on replies is only a continuation
cache: if it is absent or rejected, kibod reconstructs context from durable
turns.

Projects are folders and may contain zero conversations. Creating a project no
longer creates a special `general` conversation. The browser project page
starts unnamed chats and lists existing chats by recent activity.

`conversation.json` caches that ordering in `last_activity_at`. Event commits
update it on a best-effort basis after the authoritative JSONL append, and
startup reconciles it from the maximum durable event timestamp. Legacy
conversation metadata without the field remains readable and is backfilled.

## Knowledge ingestion

The project-level browser page at `/app/{project}/knowledge` compiles canonical
conversation transcripts and Jina Reader URL imports into Markdown source
notes. It hashes semantic content, skips unchanged inputs, and supports forced
re-ingestion into the same stable note filename. `ingested.json` advances only
after the note and deterministic index have been durably replaced.

Set `JINA_API_KEY` for authenticated Reader requests. The browser can import a
new public webpage or PDF, refresh an existing URL, and render or show the raw
Markdown files.

## Conversation names

New conversations begin as `New conversation`. Their first successful,
non-placeholder transcription supplies a short deterministic title, capped by
both words and characters. A name explicitly supplied through the API is
manual and is never replaced automatically.

TODO: after a conversation has a few completed turns, ask the AI for a concise
title. Apply that result only when the current title came from the first
transcription, record the rename as a durable `conversation_renamed` event, and
never overwrite a manual name.

## Main protocol

- `GET/POST /v1/projects`
- `GET/POST /v1/projects/{project}/conversations`
- `PUT /v1/projects/{project}/conversations/{conversation}/clips/{clip}`
- `POST /v1/projects/{project}/conversations/{conversation}/turns`
- `GET or WS /v1/projects/{project}/conversations/{conversation}/events`
- `GET /v1/projects/{project}/conversations/{conversation}/turns/{turn}/speech`
- `GET /v1/projects/{project}/conversations/{conversation}/clips/{clip}/audio`

Clip uploads require `X-Content-Sha256`, `X-Duration-Ms`, and `X-Peak-Pct`.
The speech response is chunked signed 16-bit little-endian mono PCM with its
sample rate in `X-Audio-Sample-Rate`; `from_sample` resumes at a stable offset.

## Checks

```sh
just check-generated-types
cargo test -p kibod
cargo clippy -p kibod --all-targets -- -D warnings
```
