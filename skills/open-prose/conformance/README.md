# OpenProse Conformance Suite

This directory is the executable conformance surface for OpenProse.

The important distinction is:

- `compiler.md` and `prose.md` are the human-readable normative spec
- `conformance/manifest.json` is the machine-readable expectation contract
- `examples/` are illustrative and historical, but not release truth

## Ownership

The spec repo owns:

- the version contract in `../spec-version.json`
- the conformance manifest
- the source `.prose` programs used for conformance
- the expected profile outcomes for those programs

The linter repo owns:

- parsing and diagnostics implementation
- the conformance runner
- release binaries
- linter-internal regression tests

## Solo workflow

For direct pushes to `main`, install the versioned pre-push hook:

```bash
./scripts/install-hooks.sh
```

The hook validates the local manifest and then runs the conformance suite through a local `openprose-lint` checkout.

By default it expects the linter repo at `../openprose-lint`.
If your clone lives elsewhere, set `OPENPROSE_LINT_REPO=/path/to/openprose-lint`.

## Profiles

- `strict`: current normative spec behavior
- `compat`: accepted historical or migration syntax, typically with warnings

If a case needs different outcomes per profile, encode both in `manifest.json`.

## Update Rule

Any normative change to the language must update one of:

- the conformance manifest expectations
- the conformance source cases
- both

If no conformance delta is needed, the change should be editorial only.
