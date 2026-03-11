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
