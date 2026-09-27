# charts - Agent Instructions

Helm charts published as OCI artifacts to `ghcr.io/nulcell/charts`. Keep this file accurate.

## Commandments

1. Minimal code - the smallest change that does the job.
2. Simplicity over complexity - no speculative abstraction, options, or config.
3. Comments only when necessary, and concise - state constraints, not mechanics.
4. Low verbosity everywhere: code, config, docs, and agent output.

## Layout

- `charts/<name>/` - one chart each. `ci/*-values.yaml` are render scenarios (ct lints each),
  `tests/` are helm-unittest suites, `values.schema.json` is hand-maintained alongside `values.yaml`.
- `.github/workflows/lint-test.yaml` - PRs: `ct lint` (version bump required), helm-unittest, kubeconform.
- `.github/workflows/release.yaml` - `main`: pushes any chart version missing from GHCR.

## Conventions

- Charts stay environment-neutral: no cluster names, storage classes, gateways or secret stores in defaults.
- Every values change updates `values.yaml` comments, `values.schema.json`, and a `ci/` or `tests/` case.
- Bump `version` (semver) on every chart change.

## Commands

```bash
mise install
helm lint charts/<chart> --strict
helm unittest charts/<chart>
ct lint --config ct.yaml
```
