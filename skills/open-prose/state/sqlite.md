---
role: sqlite-state-management
status: experimental
summary: |
  SQLite-based state management for OpenProse programs. This approach persists
  execution state to a SQLite database, enabling structured queries, atomic
  transactions, and flexible schema evolution.
requires: sqlite3 CLI tool in PATH
see-also:
  - ../prose.md: VM execution semantics
  - filesystem.md: File-based state (default, more prescriptive)
  - in-context.md: In-context state (for simple programs)
  - ../primitives/session.md: Session context and compaction guidelines
---

# SQLite State Management (Experimental)

This document describes how the OpenProse VM tracks execution state using a **SQLite database**. This is an experimental alternative to file-based state (`filesystem.md`) and in-context state (`in-context.md`).

## Prerequisites

**Requires:** The `sqlite3` command-line tool must be available in your PATH.

| Platform | Installation |
|----------|--------------|
| macOS | Pre-installed |
| Linux | `apt install sqlite3` / `dnf install sqlite3` / etc. |
| Windows | `winget install SQLite.SQLite` or download from sqlite.org |

If `sqlite3` is not available, the VM will fall back to filesystem state and warn the user.

---

## Overview

SQLite state provides:

- **Atomic transactions**: State changes are ACID-compliant
- **Structured queries**: Find specific bindings, filter by status, aggregate results
- **Flexible schema**: Add columns and tables as needed
- **Single-file portability**: The entire run state is one `.db` file
- **Concurrent access**: SQLite handles locking automatically

**Key principle:** The database is a flexible workspace. The VM and subagents share it as a coordination mechanism, not a rigid contract.

---

## Database Location

The database lives within the standard run directory:

```
.prose/runs/{YYYYMMDD}-{HHMMSS}-{random}/
├── state.db          # SQLite database (this file)
├── program.prose     # Copy of running program
└── attachments/      # Large outputs that don't fit in DB (optional)
```

**Run ID format:** Same as filesystem state: `{YYYYMMDD}-{HHMMSS}-{random6}`

Example: `.prose/runs/20260116-143052-a7b3c9/state.db`

### Project-Scoped and User-Scoped Agents

Execution-scoped agents (the default) live in the per-run `state.db`. However, **project-scoped agents** (`persist: project`) and **user-scoped agents** (`persist: user`) must survive across runs.

For project-scoped agents, use a separate database:

```
.prose/
├── agents.db                 # Project-scoped agent memory (survives runs)
└── runs/
    └── {id}/
        └── state.db          # Execution-scoped state (dies with run)
```

For user-scoped agents, use a database in the home directory:

```
~/.prose/
└── agents.db                 # User-scoped agent memory (survives across projects)
```

The `agents` and `agent_segments` tables for project-scoped agents live in `.prose/agents.db`, and for user-scoped agents live in `~/.prose/agents.db`. The VM initializes these databases on first use and provides the correct path to subagents.

---

## Responsibility Separation

This section defines **who does what**. This is the contract between the VM and subagents.

### VM Responsibilities

The VM (the orchestrating agent running the .prose program) is responsible for:

| Responsibility | Description |
|----------------|-------------|
| **Database creation** | Create `state.db` and initialize core tables at run start |
| **Program registration** | Store the program source and metadata |
| **Execution tracking** | Append completion records (not update-per-statement) |
| **Subagent spawning** | Spawn sessions via Task tool with database path and instructions |
| **Parallel coordination** | Track branch status, implement join strategies |
| **Loop management** | Track iteration counts, evaluate conditions |
| **Error aggregation** | Record failures, manage retry state |
| **Completion detection** | Mark the run as complete when finished |

**Critical:** The VM's conversation history is the primary execution state. The database exists for persistence and coordination, not as the source of truth during normal execution. The VM appends records on completion events—it does NOT update the database after every statement.

### Subagent Responsibilities

Subagents (sessions spawned by the VM) are responsible for:

| Responsibility | Description |
|----------------|-------------|
| **Writing own outputs** | Insert/update their binding in the `bindings` table |
| **Memory management** | For persistent agents: read and update their memory record |
| **Segment recording** | For persistent agents: append segment history |
| **Attachment handling** | Write large outputs to `attachments/` directory, store path in DB |
| **Atomic writes** | Use transactions when updating multiple related records |

**Critical:** Subagents write ONLY to `bindings`, `agents`, and `agent_segments` tables. The VM owns the `execution` table entirely. Completion signaling happens through the substrate (Task tool return), not database updates.

**Critical:** Subagents must write their outputs directly to the database. The VM does not write subagent outputs—it only reads them after the subagent completes.

**What subagents return to the VM:** A confirmation message with the binding location—not the full content:

**Root scope:**
```
Binding written: research
Location: .prose/runs/20260116-143052-a7b3c9/state.db (bindings table, name='research', execution_id=NULL)
Summary: AI safety research covering alignment, robustness, and interpretability with 15 citations.
```

**Inside block invocation:**
```
Binding written: result
Location: .prose/runs/20260116-143052-a7b3c9/state.db (bindings table, name='result', execution_id=43)
Execution ID: 43
Summary: Processed chunk into 3 sub-parts for recursive processing.
```

The VM tracks locations, not values. This keeps the VM's context lean and enables arbitrarily large intermediate values.

### Shared Concerns

| Concern | Who Handles |
|---------|-------------|
| Schema evolution | Either (use `CREATE TABLE IF NOT EXISTS`, `ALTER TABLE` as needed) |
| Custom tables | Either (prefix with `x_` for extensions) |
| Indexing | Either (add indexes for frequently-queried columns) |
| Cleanup | VM (at run end, optionally vacuum) |

---

## Core Schema

The VM initializes these tables. This is a **minimum viable schema**—extend freely.

```sql
-- Run metadata
CREATE TABLE IF NOT EXISTS run (
    id TEXT PRIMARY KEY,
    program_path TEXT,
    program_source TEXT,
    started_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    status TEXT DEFAULT 'running',  -- running, completed, failed, interrupted
    state_mode TEXT DEFAULT 'sqlite'
);

-- Execution position and history
CREATE TABLE IF NOT EXISTS execution (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    statement_index INTEGER,
    statement_text TEXT,
    status TEXT,  -- pending, executing, completed, failed, skipped
    started_at TEXT,
    completed_at TEXT,
    error_message TEXT,
    parent_id INTEGER REFERENCES execution(id),  -- for nested blocks
    metadata TEXT  -- JSON for construct-specific data (loop iteration, parallel branch, etc.)
);

-- All named values (input, output, let, const)
CREATE TABLE IF NOT EXISTS bindings (
    name TEXT,
    execution_id INTEGER,  -- NULL for root scope, non-null for block invocations
    kind TEXT,  -- input, output, let, const
    value TEXT,
    source_statement TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now')),
    attachment_path TEXT,  -- if value is too large, store path to file
    PRIMARY KEY (name, IFNULL(execution_id, -1))  -- IFNULL handles NULL for root scope
);

-- Persistent agent memory
CREATE TABLE IF NOT EXISTS agents (
    name TEXT PRIMARY KEY,
    scope TEXT,  -- execution, project, user, custom
    memory TEXT,
    created_at TEXT DEFAULT (datetime('now')),
    updated_at TEXT DEFAULT (datetime('now'))
);

-- Agent invocation history
CREATE TABLE IF NOT EXISTS agent_segments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    agent_name TEXT REFERENCES agents(name),
    segment_number INTEGER,
    timestamp TEXT DEFAULT (datetime('now')),
    prompt TEXT,
    summary TEXT,
    UNIQUE(agent_name, segment_number)
);

-- Import registry
CREATE TABLE IF NOT EXISTS imports (
    alias TEXT PRIMARY KEY,
    source_url TEXT,
    fetched_at TEXT,
    inputs_schema TEXT,  -- JSON
    outputs_schema TEXT  -- JSON
);

-- Approval gates (for approve statements)
CREATE TABLE IF NOT EXISTS gates (
    id TEXT PRIMARY KEY,              -- gate_id from the approve statement
    run_id TEXT REFERENCES run(id),
    execution_id INTEGER REFERENCES execution(id),
    prompt TEXT,                      -- rendered prompt shown to user
    allow TEXT DEFAULT '["user"]',    -- JSON array of allowed principals
    timeout TEXT,                     -- timeout duration for display (e.g., "4h")
    timeout_at TEXT,                  -- computed deadline timestamp (ISO 8601)
    on_reject TEXT,                   -- action on rejection
    status TEXT DEFAULT 'pending',    -- pending, approved, rejected, timeout
    created_at TEXT DEFAULT (datetime('now')),
    resolved_at TEXT,
    resolved_by TEXT,                 -- principal who resolved (e.g., "user", "raymond")
    resolution_comment TEXT,          -- optional comment from approver
    metadata TEXT                     -- JSON for additional data
);

-- Index for querying pending gates
CREATE INDEX IF NOT EXISTS idx_gates_status ON gates(status);
CREATE INDEX IF NOT EXISTS idx_gates_run ON gates(run_id);
CREATE INDEX IF NOT EXISTS idx_gates_timeout ON gates(timeout_at) WHERE timeout_at IS NOT NULL;

-- Gate audit log (append-only compliance trail)
CREATE TABLE IF NOT EXISTS gate_audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    gate_id TEXT NOT NULL,
    run_id TEXT NOT NULL,
    event_type TEXT NOT NULL,  -- created, viewed, approved, rejected, timeout, resumed
    principal TEXT,            -- who triggered the event (NULL for system events)
    comment TEXT,              -- optional context or reason
    timestamp TEXT DEFAULT (datetime('now')),
    metadata TEXT              -- JSON for additional event-specific data
);
CREATE INDEX IF NOT EXISTS idx_gate_audit_gate ON gate_audit_log(gate_id);
CREATE INDEX IF NOT EXISTS idx_gate_audit_run ON gate_audit_log(run_id);
```

### Schema Conventions

- **Timestamps**: Use ISO 8601 format (`datetime('now')`)
- **JSON fields**: Store structured data as JSON text in `metadata`, `*_schema` columns
- **Large values**: If a binding value exceeds ~100KB, write to `attachments/{name}.md` and store path
- **Extension tables**: Prefix with `x_` (e.g., `x_metrics`, `x_audit_log`)
- **Anonymous bindings**: Sessions without explicit capture (`session "..."` without `let x =`) use auto-generated names: `anon_001`, `anon_002`, etc.
- **Import bindings**: Prefix with import alias for scoping: `research.findings`, `research.sources`
- **Scoped bindings**: Use `execution_id` column—NULL for root scope, non-null for block invocations

### Scope Resolution Query

For recursive blocks, bindings are scoped to their execution frame. Resolve variables by walking up the call stack:

```sql
-- Find binding 'result' starting from execution_id 43
WITH RECURSIVE scope_chain AS (
  -- Start with current execution
  SELECT id, parent_id FROM execution WHERE id = 43
  UNION ALL
  -- Walk up to parent
  SELECT e.id, e.parent_id
  FROM execution e
  JOIN scope_chain s ON e.id = s.parent_id
)
SELECT b.* FROM bindings b
LEFT JOIN scope_chain s ON b.execution_id = s.id
WHERE b.name = 'result'
  AND (b.execution_id IN (SELECT id FROM scope_chain) OR b.execution_id IS NULL)
ORDER BY
  CASE WHEN b.execution_id IS NULL THEN 1 ELSE 0 END,  -- Prefer scoped over root
  s.id DESC NULLS LAST  -- Prefer deeper (more local) scope
LIMIT 1;
```

**Simpler version if you know the scope chain:**

```sql
-- Direct lookup: check current scope, then parent, then root
SELECT * FROM bindings
WHERE name = 'result'
  AND (execution_id = 43 OR execution_id = 42 OR execution_id IS NULL)
ORDER BY execution_id DESC NULLS LAST
LIMIT 1;
```

---

## Database Interaction

Both VM and subagents interact via the `sqlite3` CLI.

### From the VM

```bash
# Initialize database
sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "CREATE TABLE IF NOT EXISTS..."

# Update execution position
sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "
  INSERT INTO execution (statement_index, statement_text, status, started_at)
  VALUES (3, 'session \"Research AI safety\"', 'executing', datetime('now'))
"

# Read a binding
sqlite3 -json .prose/runs/20260116-143052-a7b3c9/state.db "
  SELECT value FROM bindings WHERE name = 'research'
"

# Check parallel branch status
sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "
  SELECT statement_text, status FROM execution
  WHERE json_extract(metadata, '$.parallel_id') = 'p1'
"
```

### From Subagents

The VM provides the database path and instructions when spawning:

**Root scope (outside block invocations):**

```
Your output database is:
  .prose/runs/20260116-143052-a7b3c9/state.db

When complete, write your output:

sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "
  INSERT OR REPLACE INTO bindings (name, execution_id, kind, value, source_statement, updated_at)
  VALUES (
    'research',
    NULL,  -- root scope
    'let',
    'AI safety research covers alignment, robustness...',
    'let research = session: researcher',
    datetime('now')
  )
"
```

**Inside block invocation (include execution_id):**

```
Execution scope:
  execution_id: 43
  block: process
  depth: 3

Your output database is:
  .prose/runs/20260116-143052-a7b3c9/state.db

When complete, write your output:

sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "
  INSERT OR REPLACE INTO bindings (name, execution_id, kind, value, source_statement, updated_at)
  VALUES (
    'result',
    43,  -- scoped to this execution
    'let',
    'Processed chunk into 3 sub-parts...',
    'let result = session \"Process chunk\"',
    datetime('now')
  )
"
```

For persistent agents (execution-scoped):

```
Your memory is in the database:
  .prose/runs/20260116-143052-a7b3c9/state.db

Read your current state:
  sqlite3 -json .prose/runs/20260116-143052-a7b3c9/state.db "SELECT memory FROM agents WHERE name = 'captain'"

Update when done:
  sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "UPDATE agents SET memory = '...', updated_at = datetime('now') WHERE name = 'captain'"

Record this segment:
  sqlite3 .prose/runs/20260116-143052-a7b3c9/state.db "INSERT INTO agent_segments (agent_name, segment_number, prompt, summary) VALUES ('captain', 3, '...', '...')"
```

For project-scoped agents, use `.prose/agents.db`. For user-scoped agents, use `~/.prose/agents.db`.

---

## Context Preservation in Main Thread

The VM's conversation history is the primary execution state. The database exists for persistence and debugging.

### Compact Narration

Use minimal markers in conversation (same as filesystem/in-context state):

```
1→ research ✓
∥ [a b c] done
loop:2/5 exit
```

The Task tool calls and results are in the conversation—no need to narrate them verbosely.

### Why Both Conversation and Database?

| Purpose | Mechanism |
|---------|-----------|
| **Working memory** | Conversation (what the VM "remembers" without querying) |
| **Durable state** | Database (survives context limits, enables resumption) |
| **Debugging/inspection** | Database (queryable history) |

The conversation is primary; the database is for persistence and inspection.

---

## Parallel Execution

For parallel blocks, **append completion records** rather than updating status. Only the VM writes to the `execution` table.

```sql
-- VM appends parallel start
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (5, 'parallel:', 'started', '{"parallel_id": "p1", "branches": ["a", "b", "c"]}');

-- Subagents write to bindings table, Task tool signals completion
-- VM appends completion record for each branch as it returns
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (5, 'parallel:a', 'completed', '{"parallel_id": "p1", "branch": "a"}');

-- When all branches complete, VM appends join record
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (5, 'parallel:', 'joined', '{"parallel_id": "p1"}');
```

**Append-only:** No UPDATEs to existing rows. Each event is a new INSERT.

---

## Loop Tracking

```sql
-- VM appends loop start
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (10, 'loop', 'started', '{"loop_id": "l1", "max": 5, "condition": "**complete**"}');

-- VM appends each iteration completion
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (10, 'loop', 'iteration', '{"loop_id": "l1", "iteration": 1}');

INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (10, 'loop', 'iteration', '{"loop_id": "l1", "iteration": 2}');

-- VM appends exit
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (10, 'loop', 'exited', '{"loop_id": "l1", "iteration": 2, "reason": "condition_satisfied"}');
```

**Append-only:** Iterations are appended, not updated. Query `MAX(iteration)` to find current state.

---

## Error Handling

```sql
-- Append failure record
INSERT INTO execution (statement_index, statement_text, status, error_message, metadata)
VALUES (15, 'session "Risky"', 'failed', 'Connection timeout after 30s', '{}');

-- Append retry attempt
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (15, 'session "Risky"', 'retry', '{"attempt": 2, "max": 3}');

-- Append eventual success or final failure
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (15, 'session "Risky"', 'completed', '{"attempt": 2}');
```

**Append-only:** Each retry is a new record. Query for the latest status by statement_index.

---

## Approval Gates

Approval gates (`approve gate_id:`) create deterministic user checkpoints. The `gates` table tracks pending and resolved gates.

### Creating a Gate

When the VM encounters an `approve` statement:

```sql
-- Insert pending gate (compute timeout_at from timeout string)
INSERT INTO gates (id, run_id, execution_id, prompt, allow, timeout, timeout_at, on_reject, status)
VALUES (
  'production_deploy',
  '20260125-125506-002755',
  3,
  'Ready to deploy to production. Changes: ...',
  '["user"]',
  '4h',
  datetime('now', '+4 hours'),  -- computed deadline
  'throw "Deployment cancelled"',
  'pending'
);

-- Also append to execution table
INSERT INTO execution (statement_index, statement_text, status, metadata)
VALUES (3, 'approve production_deploy:', 'pending', '{"gate_id": "production_deploy"}');
```

### Resolving a Gate

Resolution can come from CLI, UI, or another process:

```sql
-- Approve the gate
UPDATE gates SET
  status = 'approved',
  resolved_at = datetime('now'),
  resolved_by = 'raymond',
  resolution_comment = 'LGTM - reviewed changes'
WHERE id = 'production_deploy' AND run_id = '20260125-125506-002755';

-- Reject the gate
UPDATE gates SET
  status = 'rejected',
  resolved_at = datetime('now'),
  resolved_by = 'user',
  resolution_comment = 'Need more testing first'
WHERE id = 'production_deploy' AND run_id = '20260125-125506-002755';
```

### Querying Gates

```sql
-- Find all pending gates (for a CLI "prose gates" command)
SELECT g.id, g.prompt, g.created_at, r.program_path
FROM gates g
JOIN run r ON g.run_id = r.id
WHERE g.status = 'pending'
ORDER BY g.created_at;

-- Find gates for a specific run
SELECT id, status, prompt, resolved_by, resolved_at
FROM gates
WHERE run_id = '20260125-125506-002755';

-- Check if a run has any pending gates (for resume logic)
SELECT COUNT(*) as pending_count
FROM gates
WHERE run_id = '20260125-125506-002755' AND status = 'pending';
```

### CLI Integration

The sqlite backend enables a `prose approve` CLI command:

```bash
# List pending gates across all runs
prose gates --pending

# Approve a specific gate
prose approve 20260125-125506-002755 production_deploy --approve --comment "LGTM"

# Reject a gate
prose approve 20260125-125506-002755 production_deploy --reject --reason "Need review"

# These commands translate to SQL:
sqlite3 .prose/runs/20260125-125506-002755/state.db "
  UPDATE gates SET status='approved', resolved_at=datetime('now'), resolved_by='user'
  WHERE id='production_deploy'
"
```

### Timeout Handling

Gates can specify a timeout duration using human-readable strings. The VM parses these into a computed `timeout_at` timestamp at creation time.

#### Timeout Parsing Rules

| Format | Example | Seconds | SQLite Modifier |
|--------|---------|---------|-----------------|
| Seconds | `30s` | 30 | `'+30 seconds'` |
| Minutes | `30m` | 1800 | `'+30 minutes'` |
| Hours | `4h` | 14400 | `'+4 hours'` |
| Days | `7d` | 604800 | `'+7 days'` |
| Combined | `2h30m` | 9000 | `'+2 hours', '+30 minutes'` |

**Design principle:** Keep the original `timeout` string for display ("Expires in 4h"), compute `timeout_at` as the actual deadline timestamp for queries.

#### Computing timeout_at

```sql
-- Simple durations
INSERT INTO gates (id, timeout, timeout_at, ...)
VALUES ('gate1', '30s', datetime('now', '+30 seconds'), ...);

INSERT INTO gates (id, timeout, timeout_at, ...)
VALUES ('gate2', '4h', datetime('now', '+4 hours'), ...);

INSERT INTO gates (id, timeout, timeout_at, ...)
VALUES ('gate3', '7d', datetime('now', '+7 days'), ...);

-- Combined duration (2h30m = 2 hours + 30 minutes)
INSERT INTO gates (id, timeout, timeout_at, ...)
VALUES ('gate4', '2h30m', datetime('now', '+2 hours', '+30 minutes'), ...);
```

#### Querying Timed-Out Gates

With `timeout_at` pre-computed, timeout checks are simple:

```sql
-- Find all gates that have timed out
SELECT id, run_id, timeout, timeout_at
FROM gates
WHERE status = 'pending'
  AND timeout_at IS NOT NULL
  AND timeout_at < datetime('now');

-- Find gates expiring in the next hour (for notifications)
SELECT id, run_id, prompt, timeout_at
FROM gates
WHERE status = 'pending'
  AND timeout_at IS NOT NULL
  AND timeout_at BETWEEN datetime('now') AND datetime('now', '+1 hour');

-- Mark timed-out gates
UPDATE gates
SET status = 'timeout', resolved_at = datetime('now')
WHERE status = 'pending'
  AND timeout_at IS NOT NULL
  AND timeout_at < datetime('now');
```

### Gate Resolution from Suspended Run

When a program is suspended at a gate and later resumed:

```sql
-- Check if gate was resolved while suspended
SELECT status, resolved_by, resolution_comment
FROM gates
WHERE id = 'production_deploy' AND run_id = '20260125-125506-002755';
```

If `status = 'approved'`, the VM continues. If `status = 'rejected'`, execute `on_reject`. If still `pending`, continue waiting.

---

## Gate Resolution Protocol (Reference)

Quick reference for discovering and resolving approval gates.

### Gate Lifecycle

```
pending → approved | rejected | timeout
```

### Discovery SQL

```sql
-- All pending gates across runs
SELECT * FROM gates WHERE status = 'pending';

-- Pending gates with run context
SELECT g.id, g.run_id, g.prompt, g.created_at, r.program_path
FROM gates g
JOIN run r ON g.run_id = r.id
WHERE g.status = 'pending'
ORDER BY g.created_at;
```

### Resolution SQL

```sql
-- Approve
UPDATE gates SET
  status = 'approved',
  resolved_at = datetime('now'),
  resolved_by = 'user'
WHERE id = '<gate_id>' AND run_id = '<run_id>';

-- Reject
UPDATE gates SET
  status = 'rejected',
  resolved_at = datetime('now'),
  resolved_by = 'user',
  resolution_comment = 'Reason here'
WHERE id = '<gate_id>' AND run_id = '<run_id>';

-- Timeout (set by VM or background process)
UPDATE gates SET
  status = 'timeout',
  resolved_at = datetime('now'),
  resolved_by = 'system'
WHERE id = '<gate_id>' AND run_id = '<run_id>';
```

### CLI Commands

```bash
# List pending gates
prose gates

# Approve a gate
prose approve <run_id> <gate_id>

# Reject a gate
prose reject <run_id> <gate_id> --reason="explanation"
```

---

## Gate Audit Logging

The `gate_audit_log` table provides an **append-only compliance trail** for all approval gate activity. Unlike the `gates` table (which tracks current state), the audit log captures every event for forensic and compliance purposes.

### Event Types

| Event Type | When Logged | Principal | Typical Metadata |
|------------|-------------|-----------|------------------|
| `created` | VM creates a new gate | `system` | `{"prompt_hash": "...", "allow": [...]}` |
| `viewed` | User or process queries gate details | The viewer | `{"client": "cli", "ip": "..."}` |
| `approved` | Gate is approved | The approver | `{"comment": "LGTM"}` |
| `rejected` | Gate is rejected | The rejector | `{"comment": "Need review", "on_reject": "throw"}` |
| `timeout` | Gate times out without resolution | `system` | `{"timeout_at": "...", "on_reject": "continue"}` |
| `resumed` | Suspended run resumes at this gate | `system` | `{"resume_source": "cli", "previous_status": "pending"}` |

### Logging Pattern

The audit log follows an **append-only pattern**—records are never updated or deleted. This ensures a tamper-evident history.

**When creating a gate:**

```sql
-- VM logs gate creation
INSERT INTO gate_audit_log (gate_id, run_id, event_type, principal, metadata)
VALUES (
  'production_deploy',
  '20260125-125506-002755',
  'created',
  'system',
  '{"prompt_hash": "sha256:abc123...", "allow": ["user", "ops-team"]}'
);
```

**When resolving a gate:**

```sql
-- Log the approval event
INSERT INTO gate_audit_log (gate_id, run_id, event_type, principal, comment, metadata)
VALUES (
  'production_deploy',
  '20260125-125506-002755',
  'approved',
  'raymond',
  'Reviewed changes, LGTM',
  '{"client": "cli", "approval_time_seconds": 847}'
);

-- Then update the gates table (existing pattern)
UPDATE gates SET status = 'approved', resolved_at = datetime('now'), ...
```

**When a gate times out:**

```sql
INSERT INTO gate_audit_log (gate_id, run_id, event_type, principal, metadata)
VALUES (
  'optional_review',
  '20260125-125506-002755',
  'timeout',
  'system',
  '{"timeout_at": "2026-01-25T16:00:00Z", "on_reject": "continue"}'
);
```

### Common Audit Queries

**Complete history for a specific gate:**

```sql
SELECT event_type, principal, comment, timestamp
FROM gate_audit_log
WHERE gate_id = 'production_deploy' AND run_id = '20260125-125506-002755'
ORDER BY timestamp;
```

**All approval activity by a principal:**

```sql
SELECT gate_id, run_id, event_type, comment, timestamp
FROM gate_audit_log
WHERE principal = 'raymond' AND event_type IN ('approved', 'rejected')
ORDER BY timestamp DESC;
```

**Gates that timed out (compliance reporting):**

```sql
SELECT gate_id, run_id, timestamp, json_extract(metadata, '$.timeout_at') as deadline
FROM gate_audit_log
WHERE event_type = 'timeout'
ORDER BY timestamp DESC;
```

**Approval activity within a time window:**

```sql
SELECT gate_id, run_id, event_type, principal, timestamp
FROM gate_audit_log
WHERE event_type IN ('approved', 'rejected')
  AND timestamp >= datetime('now', '-24 hours')
ORDER BY timestamp DESC;
```

**Gate resolution time analysis:**

```sql
-- How long did gates wait before resolution?
SELECT
  g.id as gate_id,
  g.run_id,
  g.created_at,
  a.timestamp as resolved_at,
  (julianday(a.timestamp) - julianday(g.created_at)) * 24 * 60 as wait_minutes
FROM gates g
JOIN gate_audit_log a ON g.id = a.gate_id AND g.run_id = a.run_id
WHERE a.event_type IN ('approved', 'rejected', 'timeout')
ORDER BY wait_minutes DESC;
```

**Aggregate stats for compliance dashboard:**

```sql
SELECT
  event_type,
  COUNT(*) as count,
  COUNT(DISTINCT principal) as unique_principals
FROM gate_audit_log
WHERE timestamp >= datetime('now', '-30 days')
GROUP BY event_type;
```

### Responsibility

| Actor | Audit Responsibilities |
|-------|------------------------|
| **VM** | Log `created`, `timeout`, `resumed` events |
| **CLI/UI** | Log `viewed`, `approved`, `rejected` events |
| **Background process** | Log `timeout` events for expired gates |

The VM must log `created` when creating a gate and `resumed` when resuming at a gate. Resolution tools (CLI, UI) must log their events before updating gate status.

---

## Large Outputs

When a binding value is too large for comfortable database storage (>100KB):

1. Write content to `attachments/{binding_name}.md`
2. Store the path in the `attachment_path` column
3. Leave `value` as a summary or null

```sql
INSERT INTO bindings (name, kind, value, attachment_path, source_statement)
VALUES (
  'full_report',
  'let',
  'Full analysis report (847KB) - see attachment',
  'attachments/full_report.md',
  'let full_report = session "Generate comprehensive report"'
);
```

---

## Resuming Execution

To resume an interrupted run:

```sql
-- Find current position
SELECT statement_index, statement_text, status
FROM execution
WHERE status = 'executing'
ORDER BY id DESC LIMIT 1;

-- Get all completed bindings
SELECT name, kind, value, attachment_path FROM bindings;

-- Get agent memory states
SELECT name, memory FROM agents;

-- Check parallel block status
SELECT json_extract(metadata, '$.branch') as branch, status
FROM execution
WHERE json_extract(metadata, '$.parallel_id') IS NOT NULL
  AND parent_id = (SELECT id FROM execution WHERE status = 'executing' AND statement_text LIKE 'parallel:%');
```

---

## Flexibility Encouragement

Unlike filesystem state, SQLite state is intentionally **less prescriptive**. The core schema is a starting point. You are encouraged to:

- **Add columns** to existing tables as needed
- **Create extension tables** (prefix with `x_`)
- **Store custom metrics** (timing, token counts, model info)
- **Build indexes** for your query patterns
- **Use JSON functions** for semi-structured data

Example extensions:

```sql
-- Custom metrics table
CREATE TABLE x_metrics (
    execution_id INTEGER REFERENCES execution(id),
    metric_name TEXT,
    metric_value REAL,
    recorded_at TEXT DEFAULT (datetime('now'))
);

-- Add custom column
ALTER TABLE bindings ADD COLUMN token_count INTEGER;

-- Create index for common query
CREATE INDEX idx_execution_status ON execution(status);
```

The database is your workspace. Use it.

---

## Comparison with Other Modes

| Aspect | filesystem.md | in-context.md | sqlite.md |
|--------|---------------|---------------|-----------|
| **State location** | `.prose/runs/{id}/` files | Conversation history | `.prose/runs/{id}/state.db` |
| **Queryable** | Via file reads | No | Yes (SQL) |
| **Atomic updates** | No | N/A | Yes (transactions) |
| **Schema flexibility** | Rigid file structure | N/A | Flexible (add tables/columns) |
| **Resumption** | Read state.md | Re-read conversation | Query database |
| **Complexity ceiling** | High | Low (<30 statements) | High |
| **Dependency** | None | None | sqlite3 CLI |
| **Status** | Stable | Stable | **Experimental** |

---

## Summary

SQLite state management:

1. Uses a **single database file** per run
2. Uses **append-only writes** for minimal token overhead
3. Provides **clear responsibility separation** between VM and subagents
4. Enables **structured queries** for state inspection
5. Allows **flexible schema evolution** as needed
6. Requires the **sqlite3 CLI** tool
7. Is **experimental**—expect changes

The core contract: the VM appends execution events (not updates); subagents write their own outputs directly to the database. The conversation is primary state; the database is for persistence and inspection.
