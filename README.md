# LocalDevStack

**A Docker-based XAMPP alternative for modern PHP and Node.js local development.**

LocalDevStack provides local domains, trusted HTTPS, selectable PHP and Node runtimes, databases and admin UIs, Mailpit, background workers, developer utilities, diagnostics, and optional local AI behind one `lds` command.

It is designed for **trusted local development infrastructure**. It is not a production deployment stack.

## Highlights

- Nginx is the local HTTP/HTTPS front door on ports 80/443.
- Apache is always available as an alternate HTTP backend for domains that need it.
- PHP and Node runtimes are selected per domain and built as version-specific Alpine images.
- PostgreSQL, MySQL, MariaDB, MongoDB, Redis, and Elasticsearch are profile-driven.
- CloudBeaver, RedisInsight, Mongo Express, and Kibana are enabled with their related profiles.
- Mailpit is part of the core stack and persists captured mail.
- Runner provides cron, Supervisor, and log-rotation support.
- Tools owns domains, certificates, the admin UI, developer helpers, secrets integration, diagnostics, monitoring, and AI-consumer features.
- Optional `llm-sm` provides a small local Ollama runtime with persistent models.
- Dynamic Docker networking through service DNS removes fixed subnet dependencies.
- Linux, Windows/Git Bash, WSL, and Docker Desktop workflows are supported by the host CLI.

## Architecture at a glance

```text
Host
 └─ lds / lds.bat
      │
      ├─ Docker Compose
      │    ├─ server-tools
      │    ├─ runner
      │    ├─ mailpit
      │    ├─ nginx
      │    ├─ apache
      │    ├─ optional databases/admin clients
      │    ├─ generated PHP/Node runtimes
      │    └─ optional llm-sm
      │
      ├─ configuration/
      └─ logs/
```

LocalDevStack uses three logical Docker networks: `Frontend`, `Backend`, and `DataStore`. Docker assigns their address ranges dynamically. Internal communication uses service names such as `nginx`, `postgres`, `redis`, `server-tools`, and `llm-sm`.

## Prerequisites

Install Docker first:

- **Linux:** Docker Engine is preferred; Docker Desktop is also usable.
- **Windows:** Docker Desktop plus Git Bash. `lds.bat` bridges into the Bash CLI.
- **macOS:** Docker Desktop.

Useful host tools such as `jq`, `yq`, `rg`, `fd`, `tree`, and `shellcheck` can be proxied through the running `server-tools` container when they are not installed on the host. Docker itself always remains a host requirement.

## Recommended layout

```text
project-root/
├─ application/
│  ├─ site1/
│  ├─ site2/
│  └─ ...
└─ LocalDevStack/
```

The default application bind mount is the sibling `application/` directory. Set `PROJECT_DIR` in `docker/.env` when your projects live elsewhere.

## Quick start

```bash
git clone https://github.com/infocyph/LocalDevStack.git
cd LocalDevStack

chmod +x ./lds 2>/dev/null || true
sudo ./lds setup permissions      # Linux/macOS
./lds setup init
./lds setup profile
./lds up
```

The first `up` starts the control plane and web stack. Then create a domain:

```bash
./lds setup domain
```

For browser-trusted HTTPS, install the generated root CA:

```bash
sudo ./lds certificate install    # Linux
```

On Windows, use `lds.bat` or Git Bash. Certificate installation targets the current user's Windows root store and does not require the Unix `sudo` path.

Run these checks after setup:

```bash
lds doctor
lds urls
lds config validate
```

## Built-in endpoints

The exact optional endpoints shown by `lds urls` depend on enabled profiles.

| Purpose | URL |
| --- | --- |
| Tools/Admin | `https://admin.localhost` |
| Mailpit | `https://webmail.localhost` |
| CloudBeaver | `https://db.localhost` |
| RedisInsight | `https://ri.localhost` |
| Mongo Express | `https://me.localhost` |
| Kibana | `https://kibana.localhost` |
| Local AI | `https://llm.localhost` |

Use `lds open admin`, `lds open mail`, `lds open db`, `lds open redis`, `lds open mongo`, `lds open kibana`, or `lds open ai` to open a known endpoint.

## Profiles

The guided profile selector is:

```bash
lds setup profile
```

Catalog-managed optional profiles are `postgresql`, `mysql`, `mariadb`, `mongodb`, `redis`, `elasticsearch`, and `ai`.

Re-running the wizard **replaces the catalog-managed selection** while preserving generated domain/runtime profiles.

Manual profile operations remain available:

```bash
lds profiles list
lds profiles add redis
lds profiles remove redis
```

## PHP and Node runtimes

The domain wizard keeps runtime version choice in the user's hands. A selected version becomes a version-specific local image:

```text
localdevstack-php:<selected-version>
localdevstack-node:<selected-version>
```

Both runtime families use Alpine variants. Runtime builds consume Scriptomatic from `main` by default. For reproducible debugging/release work, `SCRIPTOMATIC_REF` also accepts a full 40-character commit SHA.

Rebuild selected services with normal Docker cache preserved:

```bash
lds rebuild php84
lds rebuild nginx
lds rebuild all
```

## Service image policy

Release-owned defaults live in `docker/release.env`.

> Prefer the moving Alpine variant when the image family provides a suitable Alpine variant; otherwise use the normal moving latest tag.

Examples:

- PostgreSQL: `postgres:alpine`
- Tools / Runner / Nginx / Apache: published `:latest`
- MySQL / MariaDB / MongoDB / Redis: their supported moving defaults
- local AI: `infocyph/llm-sm:latest`
- AMD local AI: `infocyph/llm-sm:amd-latest`

Elasticsearch, Kibana, and Filebeat stay on one aligned Elastic version.

Inspect the effective defaults with `lds images`.

## Environment ownership and precedence

Tracked release defaults live in `docker/release.env`; user LocalDevStack settings live in `docker/.env`; the repository-root `.env` remains application-facing state where applicable.

LocalDevStack control precedence is:

```text
built-in fallback
    < docker/release.env
    < docker/.env
    < command-scoped shell environment
```

`docker/.env` is read as dotenv data; it is not shell-sourced as executable code.

Useful inspection commands:

```bash
lds config env-used
lds config show
lds config show --json
lds config show --raw
lds config services
lds config profiles
lds config validate
```

`config show` is redacted by default. `--raw` can expose credentials.

## Databases and clients

Applications connect through Docker DNS names, not fixed IP addresses: `postgres`, `mysql`, `mariadb`, `mongodb`, `redis`, and `elasticsearch`.

Host-side wrappers forward into the appropriate LocalDevStack service:

```bash
lds pg ...
lds psql ...
lds my ...
lds mysql ...
lds maria ...
lds mariadb ...
lds redis-cli ...
lds mongo ...
lds mongosh ...
lds es ...
```

See `docs/guides/databases-and-clients.rst` for the profile/client map.

## Optional local AI

Enable the `ai` profile through `lds setup profile`.

```text
Tools consumer -> http://llm-sm:11434
User HTTPS     -> https://llm.localhost
Default model  -> qwen2.5:3b
Model store    -> LLMModels
```

Choose the runtime explicitly:

```bash
lds llm runtime cpu
lds llm runtime nvidia
lds llm runtime amd
```

CPU/NVIDIA use `infocyph/llm-sm:latest`; AMD uses `infocyph/llm-sm:amd-latest`.

Common commands:

```bash
lds ai status
lds ai ask "Explain this error"
lds ai troubleshoot ...
lds ai review ...
lds ai repo-review ...

lds llm models
lds llm pull <model>
lds llm show <model>
lds llm chat ...
```

Direct host Ollama access is off by default. `lds llm host-port on` binds only to `127.0.0.1:11434` by default.

The `llm-sm` container receives **no Docker socket and no project/repository bind mount** by default. Current published `llm-sm` images are `linux/amd64`; the rest of LocalDevStack can still run on arm64 with the AI profile disabled.

## Storage and trust boundaries

Important named volumes include `NginxHosts`, `ApacheHosts`, `SSLKeys`, `SSLRootCA`, `FPMPools`, `FPMSocks`, `ComposerGlobal`, `GitConfig`, `ToolsState`, database/admin stores, `EmailStore`, and `LLMModels`.

Generated Nginx/Apache vhosts are Docker-managed state. `lds domain ls`, support tracing, and support bundles read the persisted vhost state through the control plane.

`server-tools` and `runner` intentionally receive `/var/run/docker.sock`. Docker socket access is equivalent to powerful host Docker control. Ordinary databases, admin clients, Nginx/Apache, generated runtimes, and `llm-sm` do not receive it unless a user explicitly opts into a separate ad-hoc runner `--sock` flow.

## Operations and support

```bash
lds up
lds down
lds restart
lds restart nginx
lds status
lds ps
lds logs nginx --follow
lds stack diff
```

A normal restart does not pull fresh images. Use `lds rebuild <service>` when you want to refresh/recreate a service.

The first `up` or `start` after upgrading from the historical fixed-network layout safely migrates proven LocalDevStack legacy networks to dynamic bridges while preserving named volumes.

Support tools:

```bash
lds doctor
lds support trace project.localhost
lds support bundle --redact
```

Redacted support bundles are the default. `--full` is intentionally raw and can contain credentials or other sensitive material.

Cleanup is scoped by default:

```bash
lds clean --yes
lds clean --yes --volumes
```

Host-wide Docker pruning is a separate explicit action:

```bash
lds clean --global --yes
```

That global mode can remove unrelated stopped containers, unused images/networks, build cache, and optionally volumes. `lds down --volumes --yes` is also destructive and should not be used for normal upgrades.

## Ad-hoc Dockerfile runner

From a directory containing a Dockerfile:

```bash
lds run
lds run shell
lds run logs
lds run stop
lds run rm
```

The current directory is mounted at `/workspace`.

```bash
lds run --publish 8080:8080
lds run --mount ./data:/data
```

`--sock` deliberately grants the ad-hoc container the host Docker socket and should be used only for trusted images/code.

## Notifications

```bash
lds notify watch
lds notify test "LocalDevStack" "Notifications work"
```

Linux/WSLg uses `notify-send` when available. Windows/Git Bash and compatible WSL environments use PowerShell toast support. Other hosts fall back to terminal output.

## Command reference

```bash
lds help
lds help --markdown
```

The complete reference is maintained in `docs/reference/cli.rst`.

## Documentation

- Full docs: https://docs.infocyph.com/projects/LocalDevStack
- Getting started: `docs/quickstart.rst`
- Architecture: `docs/concepts/architecture.rst`
- Profiles/env: `docs/concepts/profiles-and-env.rst`
- Storage: `docs/concepts/storage-layout.rst`
- Domain setup: `docs/guides/domain-setup.rst`
- Databases/clients: `docs/guides/databases-and-clients.rst`
- Local AI: `docs/guides/local-ai.rst`
- Operations/support: `docs/guides/operations-and-support.rst`
- Ad-hoc runner: `docs/guides/ad-hoc-runner.rst`
- CLI reference: `docs/reference/cli.rst`

## License

MIT
