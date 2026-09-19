# docker-runner — File-by-File Development Plan

## Role

`infocyph/docker-runner` is the background execution image for LocalDevStack. It owns Supervisor, cron, log rotation, and small helper wrappers. It should remain intentionally narrow.

## Invariants

- Supervisor stays PID 1.
- Cron and logrotate continue to be supervised services.
- User-provided supervisor/cron definitions remain mountable from LocalDevStack.
- Log handling must remain resilient when some service log directories are absent.
- The image may need Docker CLI access, but Docker socket mounting is a LocalDevStack orchestration decision, not an image default.

## Existing Files

### `.github/workflows/docker.publish.yml`

Replace the legacy publication workflow with the current ecosystem contract:

- current GitHub Action majors matching `docker-llm-ollama` where compatible;
- release event: publish immutable `<release>` + `latest`;
- scheduled event: resolve latest published release source but publish only `latest`;
- never overwrite a release-version tag on schedule;
- Buildx setup + cache;
- Docker Hub + GHCR from the same build digest;
- provenance attestation;
- add concurrency guard;
- add sensible `timeout-minutes`;
- preserve the existing every-two-weeks cadence unless we intentionally standardize schedules later.

### New `.github/workflows/check.yml`

Add PR/push validation:

- `bash -n` for Bash scripts;
- ShellCheck;
- validate Supervisor configuration inside a built image;
- real Docker image build;
- start container and wait for health;
- verify `supervisorctl status` reports `cron` and `logrotate` RUNNING;
- verify stop signal shuts down cleanly.

### `Dockerfile`

Plan:

- parameterize the Alpine base version instead of relying blindly on `alpine:latest`;
- add immutable Scriptomatic/Toolset refs for `banner.sh` and `chromacat`;
- replace floating `ADD raw.githubusercontent.com/.../master|main` with explicit ref-driven fetch/copy;
- keep package list minimal: bash, curl, CA, supervisor, docker-cli, logrotate, cronie, tzdata, presentation dependencies;
- verify whether `gawk`/other current packages are actually required before removing anything;
- preserve healthcheck against Supervisor;
- preserve `STOPSIGNAL SIGTERM`;
- add OCI revision/version metadata through workflow rather than hard-coded release values;
- keep root user if required for cron/logrotate/Docker access; do not force non-root and break the role.

### `scripts/supervisord.conf`

Plan:

- keep `nodaemon=true` and UNIX control socket;
- validate included `/etc/supervisor/conf.d/*.conf` behavior when directory is empty;
- keep cron/logrotate stdout/stderr on container streams;
- add/verify `stopasgroup`/`killasgroup` only if child-process tests show signal leakage;
- do not add unrelated application workers to the base image.

### `scripts/logrotate-worker.sh`

Plan:

- validate `LOGROTATE_INTERVAL` as a positive integer before sleeping;
- keep configurable state file;
- preserve `/etc/logrotate.conf` preference and per-file fallback;
- ensure one invalid optional logrotate fragment does not create an uncontrolled tight restart loop;
- expose useful failure logs through stderr/stdout;
- test a temporary log file rotation end-to-end.

### `scripts/pexe.sh`

Plan:

- review argument quoting/TTY forwarding;
- keep helper single-purpose;
- ensure target process exit code is propagated;
- add shell smoke coverage.

### `scripts/dexe.sh`

Plan:

- same quoting/exit-code review as `pexe.sh`;
- confirm Docker CLI/container-name assumptions are still required by LocalDevStack runner workflows;
- do not duplicate `lds exec` features into this script.

### `loggables/daily`

Plan:

- validate with `logrotate -d`/debug mode in CI;
- confirm paths match LocalDevStack-mounted `/global/log` layout;
- preserve retention policy unless a bug is found.

### `loggables/dailyold`

Plan:

- determine active use vs legacy compatibility;
- if still used, validate separately;
- if unused across LocalDevStack, deprecate first rather than silently delete.

### `loggables/supervisord`

Plan:

- validate configured path and ownership against the current Supervisor logfile path;
- ensure rotation does not break the active file descriptor/process.

### `README.md`

Update after code is stable:

- define the image as LocalDevStack background-process infrastructure;
- document mounted supervisor/cron/log paths;
- document required Docker socket only as an integration choice;
- document health behavior and environment variables;
- document immutable release tags + `latest` semantics.

### `.dockerignore`

Review against actual build context and keep only files required by Docker build. No cosmetic expansion.

### `.gitignore` / `.gitattributes`

Keep unless validation finds missing generated files/line-ending rules.

### `LICENSE`

No change.

## New Tests

Suggested `tests/` files:

- `tests/shell-check.sh` — syntax entrypoint for local/CI use;
- `tests/supervisor-smoke.sh` — run built container, verify supervisor/cron/logrotate;
- `tests/logrotate-smoke.sh` — temporary log + forced rotation validation.

Tests should be executable from CI and locally without LocalDevStack running.

## Integration Follow-Up in LocalDevStack

After release:

- pin/raise `infocyph/runner` version in LocalDevStack;
- confirm mounted cron/supervisor definitions work;
- inventory why Runner receives Docker socket;
- remove socket mount later only if no required runner workflow uses it.

## Acceptance Criteria

1. ShellCheck/syntax green.
2. Real image build green.
3. Container reaches healthy state.
4. Supervisor sees cron/logrotate running.
5. Log rotation smoke test passes.
6. Release workflow cannot overwrite immutable version tags from schedule.
7. Scriptomatic/Toolset dependencies are immutable/ref-driven.
8. Existing LocalDevStack scheduler/supervisor behavior remains compatible.
