# Changelog

All notable changes to OpenProse will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Exec Primitive** (`exec`): Direct shell command execution without spawning subagents
  - Zero LLM cost for deterministic operations (builds, syncs, git commands)
  - Properties: `timeout` (duration), `on-fail` (`throw`/`continue`/`ignore`), `cwd`
  - Full interpolation support with security warnings
  - Parallel exec in `parallel` blocks
  - Composes with `try/catch`, `gate`, and `session` context passing
  - VM writes bindings directly (exception to subagent binding ownership)
  - Validated by dual-VM dogfood testing (Claude Opus 4.5 + OpenAI Codex GPT-5.2)

- **Approval Gates** (`approve gate:`): Deterministic user checkpoints that cannot be bypassed by agents
  - `prompt`: Message shown to user describing what is being approved
  - `allow`: List of principals who can approve (default: `["user"]`)
  - `timeout`: Maximum wait time (e.g., "4h", "30m")
  - `on_reject`: Action on rejection - `throw`, `retry`, `continue`, `session "prompt"`, or string shorthand
  - New example: `51-approval-gates.prose` demonstrating 8 usage patterns

## [0.8.1] - 2025-01-23

### Changed

- **Token efficiency improvements**: State tracking is now significantly more compact, reducing context usage during long-running programs. Append-only logs replace verbose state files, and compact markers replace verbose narration.

## [0.8.0] - 2025-01-23

### Breaking Changes

- **Registry syntax simplified**: The `@` prefix is no longer required for registry references.
  - **Migration**: Update your imports and run commands:
    - `prose run @irl-danb/habit-miner` becomes `prose run irl-danb/habit-miner`
    - `use "@alice/research"` becomes `use "alice/research"`
  - Resolution rules: URLs fetch directly, paths with `/` resolve to p.prose.md, otherwise local file

### Added

- **Memory Programs** (recommend sqlite+ backend):
  - `user-memory.prose`: Cross-project persistent personal memory with teach/query/reflect modes
  - `project-memory.prose`: Project-scoped institutional memory with ingest/query/update/summarize modes

- **Analysis Programs**:
  - `cost-analyzer.prose`: Token usage and cost pattern analysis with single/compare/trend scopes
  - `calibrator.prose`: Validates light vs deep evaluation reliability
  - `error-forensics.prose`: Root cause analysis for failed runs

- **Improvement Loop Programs**:
  - `vm-improver.prose`: Analyzes inspection reports and proposes PRs to improve the OpenProse VM
  - `program-improver.prose`: Analyzes inspection reports and proposes PRs to improve .prose source code

- **Skill Security Scanner v2**: Enhanced with progressive disclosure, model tiering (Sonnet for checklist, Opus for deep analysis), parallel scanners with graceful degradation, and persistent scan history

- **Interactive Example**: New example demonstrating input primitives
- **System Prompt**: Added system prompt configuration

### Removed

- **Telemetry system**: Removed all telemetry-related code, config, and documentation including USER_ID/SESSION_ID tracking and analytics endpoint calls

### Changed

- User-scoped persistent agents now stored in `~/.prose/agents/`
- Documentation updates for registry syntax changes
