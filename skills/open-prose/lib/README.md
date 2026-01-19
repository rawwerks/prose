# OpenProse Standard Library

Core programs that ship with OpenProse. These are production-quality, well-tested programs for common tasks.

## Programs

| Program | Description |
|---------|-------------|
| `inspector.prose` | Post-run analysis for runtime fidelity and task effectiveness |

## Usage

```bash
# Run directly
prose run lib/inspector.prose

# Or via registry (when published)
prose run @openprose/lib/inspector
```

## Design Principles

Programs in `lib/` follow these principles:

1. **Production-ready** — Tested, documented, handles edge cases
2. **Composable** — Can be imported via `use` in other programs
3. **User-scoped state** — Cross-project utilities use `persist: user`
4. **Minimal dependencies** — No external services required
5. **Clear contracts** — Well-defined inputs and outputs
