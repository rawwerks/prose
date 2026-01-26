---
role: primitive-specification
summary: |
  The exec primitive enables direct shell command execution by the VM without
  spawning a subagent. For deterministic operations where no AI reasoning is
  needed—syncing tools, running builds, querying databases—exec eliminates
  the overhead of a full session.
status: draft
see-also:
  - ../prose.md: Execution semantics
  - ../compiler.md: Full syntax grammar
---

# Exec Primitive

## Motivation

Every computation in OpenProse currently flows through `session`, which spawns a subagent via the Task tool. This is correct for tasks requiring intelligence—but many workflow steps are deterministic shell commands:

```prose
# Current: spawns a full Opus subagent just to type one command
let sync = session "Run ru sync --non-interactive"

# Proposed: VM runs the command directly
let sync = exec "ru sync --non-interactive"
```

The cost difference is significant:

| Metric       | `session` for a bash command | `exec`        |
| ------------ | ---------------------------- | ------------- |
| Tokens       | ~2,000–10,000 (subagent)     | 0 (no LLM)    |
| Latency      | 5–30s (Task spawn + LLM)    | <1s (shell)   |
| Context      | Subagent gets own window     | VM stays lean |

When a program runs 6 tool commands sequentially via sessions, `exec` can reduce that from ~60s and ~30,000 tokens to <6s and 0 tokens.

---

## Syntax

### Simple Exec

```prose
exec "command string"
```

### Exec with Binding

```prose
let result = exec "command string"
const snapshot = exec "git rev-parse HEAD"
output build_log = exec "make build 2>&1"
```

### Exec with Properties

```prose
let result = exec "npm test"
  timeout: "5m"
  on-fail: "continue"
```

### Multi-line Commands

```prose
exec """
cd /project &&
npm install &&
npm run build
"""
```

---

## Grammar

Add `execStatement` as a production. Like `session`, `exec` appears in both the statement and expression positions—this is the same dual nature that `session` already has:

```
# New production
execStatement → "exec" string ( NEWLINE INDENT execProperty* DEDENT )?
execProperty  → "timeout:" string
              | "on-fail:" string
              | "cwd:" string

# Updated statement production (add execStatement)
statement   → useStatement | inputDecl | agentDef | session | resumeStmt
            | letBinding | constBinding | assignment | outputBinding
            | parallelBlock | repeatBlock | forEachBlock | loopBlock
            | tryBlock | choiceBlock | ifStatement | doBlock | blockDef
            | throwStatement | gateStatement | execStatement | comment

# Updated expression production (add execStatement)
expression  → session | execStatement | doBlock | parallelBlock | repeatBlock
            | forEachBlock | loopBlock | arrowExpr | pipeExpr | programCall
            | string | IDENTIFIER | array | objectContext
```

---

## Properties

| Property   | Required | Default     | Description                                           |
| ---------- | -------- | ----------- | ----------------------------------------------------- |
| `timeout`  | No       | `"2m"`      | Max duration before the command is killed              |
| `on-fail`  | No       | `"throw"`   | Action on non-zero exit: "throw", "continue", "ignore" |
| `cwd`      | No       | (inherited) | Working directory for the command                     |

Property naming follows existing conventions: `on-fail` matches `parallel (on-fail: ...)` (kebab-case), and `timeout` uses duration strings matching `gate` (e.g., `"30s"`, `"5m"`, `"1h"`).

### on-fail Actions

| Action       | Behavior                                                     |
| ------------ | ------------------------------------------------------------ |
| `"throw"`    | Raise an error with stderr and exit code (default)           |
| `"continue"` | Bind the full result (stdout, stderr, exit_code); do not error |
| `"ignore"`   | Bind stdout only; omit stderr and exit_code from binding     |

---

## Execution Semantics

When the OpenProse VM encounters an `exec` statement:

1. **Resolve Command**: Evaluate the command string (including interpolation if present)
2. **Execute Directly**: Run via the VM's shell execution capability—**NOT** via Task/subagent
3. **Capture Output**: Collect stdout, stderr, and exit code
4. **Truncate**: If stdout or stderr exceeds 30,000 characters, truncate to 30,000 and set `stdout_truncated` or `stderr_truncated` in the binding metadata
5. **Handle Exit Code**: If non-zero, apply `on-fail` policy
6. **Bind Result**: If used in a binding, the VM writes the output directly to `bindings/`
7. **Continue**: Proceed to next statement

### Execution Flow

```
OpenProse VM                    Shell
    |                              |
    |  shell command               |
    |----------------------------->|
    |                              |
    |  stdout + stderr + exit      |
    |<-----------------------------|
    |                              |
    |  write binding, continue     |
    v                              v
```

### Substrate Mapping

The exec primitive requires shell access from the host environment. The specific mechanism depends on the substrate:

| Substrate      | Exec maps to                         |
| -------------- | ------------------------------------ |
| Claude Code    | Bash tool call                       |
| OpenCode       | Shell tool call                      |
| Other agents   | Whatever shell execution is available |

The language does not mandate a specific tool—only that the VM can execute shell commands and capture output.

### Key Difference: exec vs session

| Aspect         | `session`                           | `exec`                              |
| -------------- | ----------------------------------- | ----------------------------------- |
| Executor       | Spawns subagent via Task tool       | VM runs directly (shell tool)       |
| Cost           | Full LLM call (tokens + latency)    | Zero LLM cost (shell only)          |
| Output         | AI-generated text                   | Raw command output (string)         |
| Intelligence   | Subagent reasons, uses tools        | No intelligence—deterministic       |
| Use case       | Tasks requiring judgment            | Deterministic operations            |
| Binding writer | Subagent writes its own binding     | VM writes the binding               |
| Permissions    | Governed by agent `permissions:`    | VM's own permissions (parent env)   |

---

## Result Value

An exec result is a **string** containing stdout. Metadata (stderr, exit code) is stored in the binding file and available when the binding is passed as context to a session.

When exec is used as a bare statement without a binding (`exec "cmd"`), no binding file is created—the command runs for its side effects only, and the VM checks the exit code for `on-fail` policy.

There is no property access syntax in OpenProse—you cannot write `result.exit_code`. Instead, use discretion markers to evaluate exec results:

```prose
let test = exec "npm test"
  on-fail: "continue"

# The VM reads the binding (including exit_code metadata) and evaluates
if **the test output indicates failures**:
  session "Diagnose test failures"
    context: test
```

When an exec binding is passed via `context:`, the receiving session sees the full binding file including exit code and stderr metadata, enabling informed reasoning.

### Binding Storage

Exec bindings are stored in `bindings/` like session bindings. **This is an exception to the normal ownership model**: for session bindings, the subagent writes the file; for exec bindings, the VM writes the file directly since there is no subagent.

Format:

````markdown
# sync_output

kind: let

source:
```prose
let sync_output = exec "ru sync --non-interactive"
```

exit_code: 0
stderr: (empty)

---

[stdout content here]
````

Truncation is applied **per-stream**: if stdout exceeds 30,000 characters, the binding includes `stdout_truncated: true`; if stderr exceeds 30,000 characters, the binding includes `stderr_truncated: true`. Only the first 30,000 characters of each stream are stored.

---

## String Interpolation

Exec command strings support the same `{varname}` interpolation as all OpenProse strings:

```prose
let branch = exec "git rev-parse --abbrev-ref HEAD"
exec "git push origin {branch}"
```

**Security note**: Interpolated values are inserted directly into the shell command string. This means variable values can contain shell metacharacters. Program authors should be aware that interpolation into exec commands carries the same risks as shell interpolation in any language. Use with trusted values only.

To suppress interpolation, escape braces with backslash:

```prose
exec "echo \{not interpolated\}"
```

---

## Error Handling

Non-zero exit codes are errors by default:

```prose
# Default: throws on failure
exec "make build"

# With try/catch
try:
  exec "make build"
catch as err:
  session "The build failed, diagnose the error"
    context: err

# Ignore failures (e.g., cleanup commands)
exec "rm -f /tmp/cache"
  on-fail: "ignore"

# Continue with error info available
let result = exec "npm test"
  on-fail: "continue"
# result binding includes exit_code metadata; program continues
```

### Interaction with parallel

When `exec` appears inside a `parallel` block, failure semantics compose:

1. **exec `on-fail` resolves first**: If `on-fail: "throw"`, the exec raises an error. If `on-fail: "continue"` or `"ignore"`, the exec succeeds (no error).
2. **parallel `on-fail` resolves second**: Only sees errors that exec actually raised (i.e., `on-fail: "throw"` cases).

```prose
parallel (on-fail: "continue"):
  # This exec throws on failure → parallel's on-fail catches it
  a = exec "npm test"

  # This exec never throws → parallel never sees an error from it
  b = exec "npm run lint"
    on-fail: "continue"
```

### Interaction with try/catch

Exec errors from `on-fail: "throw"` propagate to `try/catch` like any other error. The `catch` binding contains the exec's stderr and exit code.

---

## Parallel Exec

Exec works naturally inside `parallel` blocks. The VM issues multiple shell calls concurrently:

```prose
parallel:
  tests = exec "npm test"
    on-fail: "continue"
  lint = exec "npm run lint"
    on-fail: "continue"
  types = exec "npm run typecheck"
    on-fail: "continue"

if **any of tests, lint, or types indicate failures**:
  session "Diagnose the CI failures"
    context: { tests, lint, types }
```

---

## Security Model

The `exec` primitive runs commands with the **VM's own permissions**—the parent environment's sandbox and approval rules. This is a direct tool call, not a delegated task.

Implications:

- Commands inherit the VM's working directory, environment, and file access
- Agent-level `permissions:` blocks do **not** apply (those govern subagent sessions, not the VM itself)
- The VM's own tool approval policies (hooks, sandbox) still apply
- The host environment's existing safety checks remain in effect

**Recommended practice**: Use `gate` before destructive or irreversible `exec` commands:

```prose
gate confirm_deploy:
  prompt: "About to deploy to production. Continue?"
  timeout: "5m"

exec "kamal deploy"
  timeout: "10m"
```

---

## Shell Semantics

Each `exec` is a single shell invocation. Understanding what persists and what doesn't:

| Aspect              | Persists across exec calls? | Notes                                    |
| ------------------- | --------------------------- | ---------------------------------------- |
| Working directory   | Yes                         | `cd` in one exec affects subsequent ones |
| Shell variables     | No                          | Each exec starts a fresh shell           |
| Environment variables| Yes                        | Inherited from VM's environment          |
| Aliases/functions   | No                          | Not loaded between exec calls            |

This matches the behavior of the underlying shell tool in most agent substrates (e.g., Claude Code's Bash tool persists cwd but not shell state).

### Parallel cwd isolation

Inside a `parallel` block, each branch operates on a **snapshot** of the working directory at fork time. A `cd` inside one parallel branch does not affect other branches. After the parallel block completes, the working directory reverts to its pre-parallel value. This prevents race conditions from concurrent cwd mutations.

---

## What Exec Is Not

- **Not an agent**: Exec cannot reason, make decisions, or use tools. If you need interpretation of the output, pass it as context to a session.
- **Not a REPL**: Each exec is stateless except for working directory. Shell variables do not carry between calls.
- **Not a replacement for session**: When the task requires judgment—interpreting output, deciding next steps, using multiple tools—use `session`. Exec is for deterministic operations only.

---

## Validation Rules

| Code | Check                           | Severity | Message                                           |
| ---- | ------------------------------- | -------- | ------------------------------------------------- |
| E050 | Empty command string            | Error    | exec command cannot be empty                      |
| E051 | Invalid timeout format          | Error    | timeout must be a duration (e.g., "30s", "5m")    |
| E052 | Invalid on-fail value           | Error    | on-fail must be "throw", "continue", or "ignore"  |
| E053 | Undefined interpolation variable| Error    | Variable {name} is not defined                    |
| W050 | Timeout exceeds 10m             | Warning  | exec timeout exceeds 10 minutes                   |
| W051 | Interpolation in exec command   | Warning  | Interpolated exec commands may have injection risk |

---

## Examples

### Tool Synchronization (The Motivating Case)

```prose
# Before: 6 subagent spawns for 6 bash commands (~60s, ~30k tokens)
for tool in tools:
  session "Run sync for {tool}"

# After: VM runs commands directly, session only for interpretation
let sync = exec "ru sync --non-interactive"
let subs = exec "cd ~/Documents/GitHub/skills-library && git submodule update --remote --merge"
let health = exec "gt-doctor"

output report = session: analyst
  prompt: "Interpret these results, identify failures, suggest fixes"
  context: { sync, subs, health }
```

### Build Pipeline

```prose
exec "npm install"
  timeout: "2m"

let test = exec "npm test"
  on-fail: "continue"

let lint = exec "npm run lint"
  on-fail: "continue"

if **tests or lint indicate failures**:
  session "Diagnose failures and suggest fixes"
    context: { test, lint }
else:
  exec "npm run build"
```

### Git Workflow

```prose
let status = exec "git status --porcelain"

if **there are uncommitted changes in status**:
  gate confirm_commit:
    prompt: "Uncommitted changes detected. Commit before proceeding?"
    on_reject: throw "Aborted: uncommitted changes"

  exec "git add -A && git commit -m 'auto-commit before deploy'"

exec "git push origin main"
```

### Database Operations

```prose
exec "pg_dump mydb > /tmp/backup.sql"
  timeout: "5m"

let count = exec "psql mydb -t -c 'SELECT count(*) FROM users'"

session "Analyze database and suggest optimizations"
  context: count
```

### Parallel CI Check

```prose
parallel (on-fail: "continue"):
  test = exec "npm test"
  lint = exec "npm run lint"
  typecheck = exec "npm run typecheck"
  security = exec "npm audit"

session "Summarize CI results and recommend next steps"
  context: { test, lint, typecheck, security }
```
