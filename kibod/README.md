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
appended. New events use strict typed write constructors; historical reads stay
open so legacy and unknown records can still be projected or recovered. The
Gemini `interaction_id` saved on replies is only a continuation
cache. New replies persist the latest durable reply sequence covered by that
provider context; out-of-order recovery invalidates an unproven legacy anchor.
If the cache is absent, stale, or rejected, kibod reconstructs context from
durable turns.

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

## Agentic knowledge query

Open `/app/{project}/knowledge/query`, or choose **Ask knowledge** from the
Knowledge page, to ask multi-turn questions across the generated wiki. Each
turn starts Codex app-server over its private JSONL stdio transport, has the
agent read `wiki/index.md` before following relevant notes, and streams a
normalized research trail and Markdown answer back to the browser. Answers are
rendered and sanitized by kibod, and relative citations open the corresponding
wiki file.

The HTTP interface is:

```http
POST /v1/projects/{project}/knowledge/query
Content-Type: application/json

{"question":"Which themes recur?","thread_id":"query-..."}
```

`thread_id` is optional for the first turn. The response is newline-delimited
JSON with `started`, `activity`, `delta`, `completed`, or `error` events. The
`query_id` in `started` is an opaque, process-local continuation token; send it
as `thread_id` for a follow-up in the same project. Restarting kibod or choosing
**New conversation** starts a fresh Codex conversation.

Knowledge queries fail closed unless app-server confirms a read-only sandbox,
network denial, disabled approvals, one exact runtime root, and no loaded
instruction sources. Every app-server connection receives an unpredictable
permission-profile ID granting read access only to the canonical project wiki
plus Codex's curated `:minimal` runtime paths. A legacy
restricted-`sandboxPolicy` shape is tried only for compatible app-server
versions and is accepted only if the returned readable root exactly matches the
wiki. The wiki is explicitly treated as an untrusted project, and before every
turn kibod queries app-server's effective MCP inventory and requires it to be
empty—including servers from managed or system config layers. kibod also
disables apps, plugins, web search, browser/computer tools, image generation,
hooks, and subagents for this surface. The agent cannot write the wiki.

Codex authentication is separate from `GEMINI_API_KEY`. By default kibod uses
the installed `codex` command and copies only `auth.json` from the normal Codex
home into a fresh, process-private runtime home. User `config.toml`, MCP
servers, plugins, permission profiles, `AGENTS.md`, skills, and saved threads
are never inherited. The isolated runtime keeps follow-up threads only for the
life of kibod and is removed on shutdown. Set `KIBO_CODEX_HOME` when the source
authentication file lives somewhere other than the normal Codex home; an
inherited API-key environment also remains available to Codex.

| Variable | Default | Purpose |
|---|---|---|
| `KIBO_CODEX_BIN` | `codex` | Codex CLI/app-server executable |
| `KIBO_CODEX_HOME` | normal Codex home | Source directory for `auth.json` only; configuration and instructions are not inherited |
| `KIBO_CODEX_MODEL` | app-server default | Optional model override |
| `KIBO_CODEX_EFFORT` | `medium` | Reasoning effort for knowledge turns |
| `KIBO_CODEX_MAX_CONCURRENT` | `2` | Concurrent query limit (clamped to 1–16) |
| `KIBO_CODEX_TIMEOUT_SECONDS` | `300` | Maximum time for a query turn |
| `KIBO_CODEX_START_TIMEOUT_SECONDS` | `20` | App-server initialize/start timeout |

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
- `POST /v1/projects/{project}/knowledge/query` (streaming NDJSON)

Clip uploads require `X-Content-Sha256`, `X-Duration-Ms`, and `X-Peak-Pct`.
The speech response is chunked signed 16-bit little-endian mono PCM with its
sample rate in `X-Audio-Sample-Rate`. `X-Speech-Generation` identifies one
exact synthesis, and `from_sample` resumes at a stable offset only within that
generation. Resumed clients echo the generation header. The server returns
`412 Precondition Failed` for a mismatch, and for an unversioned nonzero resume
after a synthesis rollover; either case must restart at sample zero.
Persisted WAVs from a headerless legacy server are adopted under a stable token
derived from their bytes and are treated as already rolled over, because the old
journal cannot prove that no earlier synthesis prefix reached a client.

## Checks

```sh
just check-generated-types
cargo test -p kibod
cargo clippy -p kibod --all-targets -- -D warnings
```
