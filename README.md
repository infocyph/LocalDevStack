# LocalDevStack

**Docker-based XAMPP alternative for PHP and Node.js local development.**

LocalDevStack gives you local domains, trusted HTTPS, selectable PHP/Node runtimes, databases and admin UIs, Mailpit, background jobs, and optional local AI behind one `lds` CLI.

## What you get

- Nginx as the front door on ports 80/443, with optional Apache behind it.
- Interactive PHP and Node runtime selection per domain.
- PostgreSQL, MySQL, MariaDB, MongoDB, Redis, and Elasticsearch profiles.
- CloudBeaver, RedisInsight, Mongo Express, and Kibana where applicable.
- Persistent Mailpit with local SMTP TLS.
- Runner-based cron, Supervisor, and log rotation.
- Optional local AI via `llm-sm`, available internally at `http://llm-sm:11434` and through `https://llm.localhost`.
- Dynamic Docker networking through service DNS; no fixed `172.28/29/30` addresses.

LocalDevStack is for **trusted local development infrastructure**, not production deployment.

## Prerequisites

Install Docker first:

- Docker Engine is preferred on Linux.
- Docker Desktop is supported on Windows/macOS and can also be used on Linux.
- Windows CLI access uses `lds.bat` + Git Bash.

## Recommended layout

```text
project-root/
├─ application/
│  ├─ site1/
│  ├─ site2/
│  └─ ...
└─ LocalDevStack/
```

Set `PROJECT_DIR` in `docker/.env` when your project directory lives elsewhere.

## Quick start

```bash
git clone https://github.com/infocyph/LocalDevStack.git
cd LocalDevStack

chmod +x ./lds 2>/dev/null || true
sudo ./lds setup permissions   # Linux/macOS
./lds setup init
./lds setup profile
./lds up
./lds setup domain
```

On Windows, run the equivalent commands through `lds.bat` or Git Bash. The permissions command configures the wrapper path and does not apply Unix chmod logic.

Install the generated LocalDevStack root CA when you want browser-trusted HTTPS:

```bash
sudo lds certificate install
```

## Common commands

```bash
lds help

lds up
lds down
lds restart
lds status
lds logs [service]
lds rebuild [all|service...]

lds setup profile
lds setup domain
lds profiles list

lds urls
lds images
lds doctor

lds config show
lds config show --json
lds config show --raw       # explicitly shows secret-bearing effective config
lds config env-used
lds config validate
```

`lds config show` is **redacted by default**.

## Runtime selection

The domain wizard keeps the runtime selector as the source of truth:

- PHP: select the PHP version for that domain.
- Node: select a Node version/tag for that domain.

Generated local images remain version-specific:

```text
localdevstack-php:<selected-version>
localdevstack-node:<selected-version>
```

Selected PHP and Node images use Alpine variants.

The local build path consumes Scriptomatic from `main` by default. Advanced users/releases may set `SCRIPTOMATIC_REF` to a full 40-character commit SHA.

## Service image policy

Default image selection follows this rule:

> Prefer the moving Alpine variant when that image family publishes a suitable one; otherwise use its normal moving latest tag.

Examples:

- PostgreSQL: `postgres:alpine`
- Tools / Runner / Nginx / Apache: their published `:latest` images (already built on their intended Alpine bases)
- LLM: `infocyph/llm-sm:latest`
- AMD LLM: `infocyph/llm-sm:amd-latest`

Elasticsearch, Kibana, and Filebeat are kept on one aligned version because those image families do not provide a supported moving `latest` contract for this stack.

Run `lds images` to see the effective image set after release, user, and shell overrides.

## Profiles and environment

Tracked product defaults live in:

```text
docker/release.env
```

User stack settings live in:

```text
docker/.env
```

Precedence is:

```text
built-in fallback
    < docker/release.env
    < docker/.env
    < command-scoped shell environment
```

LocalDevStack never shell-sources `docker/.env` as executable code.

## Optional local AI

Enable the `ai` profile from the profile setup flow, then choose the runtime mode:

```bash
lds llm runtime cpu
lds llm runtime nvidia
lds llm runtime amd
```

Useful commands:

```bash
lds ai status
lds ai ask "explain this error"
lds ai troubleshoot ...
lds llm models
lds llm pull <model>
lds llm chat ...
```

Models persist in the `LLMModels` named volume.

Default access is through:

```text
https://llm.localhost
```

Direct Ollama host access is disabled by default. When explicitly enabled:

```bash
lds llm host-port on
```

it binds only to:

```text
127.0.0.1:11434
```

The LLM container does **not** receive the Docker socket or a project mount by default.

## Storage and trust boundaries

Important named volumes include:

- `NginxHosts` / `ApacheHosts`
- `SSLKeys` / `SSLRootCA`
- `FPMPools` / `FPMSocks`
- database/admin-client stores
- `EmailStore`
- `LLMModels`

Host-owned configuration remains under `configuration/`, including PHP overrides, scheduler files, SOPS data, optional SSH material, and generated Compose fragments.

`server-tools` and `runner` intentionally mount `/var/run/docker.sock`. That socket is equivalent to powerful host Docker control and is limited to those trusted control-plane components. Ordinary databases/admin clients and `llm-sm` do not receive it.

## Networking

Core networks are still logically separated as:

```text
Frontend
Backend
DataStore
```

Docker assigns their subnets dynamically. Services communicate by Docker DNS names such as:

```text
server-tools
runner
mailpit
postgres
mysql
mariadb
mongodb
redis
elasticsearch
llm-sm
```

The legacy `lds vpn-fix` command is deprecated because LocalDevStack no longer owns fixed private subnets.

## Documentation

- Full docs: https://docs.infocyph.com/projects/LocalDevStack
- Quick reference: `lds help`
- Local AI: `docs/guides/local-ai.rst`
- Profiles/env: `docs/concepts/profiles-and-env.rst`
- Storage: `docs/concepts/storage-layout.rst`

## License

MIT
