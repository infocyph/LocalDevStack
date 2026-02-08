# LocalDevStack

LocalDevStack provides an easy-to-use Docker-based development environment for your projects.
All modules are **selective** and can be enabled via environment settings (Compose profiles).
Supports **multiple domains** and local TLS.

> 1) Local development only.  
> 2) Your domain(s) must be resolvable on your host:
>    - add entries to your hosts file: `<your_ip> <your_domain>`, **or**
>    - use a DNS that resolves to your machine, **or**
>    - use `*.localhost` (no hosts entry required in many setups)

## Prerequisites (Docker)

Install docker on your system first. If you already have docker installed, you can skip this step. 
- It is recommended to use [Docker Engine](https://docs.docker.com/engine/install/).
- If Docker Engine not supported in your OS, use [Docker Desktop](https://docs.docker.com/desktop/) (although you can also install this on linux as well).

## Supported Project Languages

- PHP
- NodeJs

---

## Quickstart

### 0) Default Layout

```
project-root/
├─ application/
│  ├─ site1/
│  ├─ site2/
│  └─ ...
└─ LocalDevStack/        (this repository)
```

This layout is flexible. If you want a different projects folder, set `PROJECT_DIR` in your env.

```bash
# supports relative/absolute path (recommended to use absolute path for less confusion)
PROJECT_DIR=/path/to/your/projects 
```

### 1) Clone
```bash
git clone https://github.com/infocyph/LocalDevStack.git
cd LocalDevStack
````

### 2) Setup global shortcut and Permissions

On Linux/Mac,
```bash
chmod +x ./lds 2>/dev/null || true
sudo ./lds setup permissions
```
On Windows,
```cmd
./lds setup permissions
```

Once ran, it will add a globally available shortcut (lds). And necessary permissions(linux/mac) will be assigned as well.

### 3) Start the stack

```bash
lds start
```

### 4) Add a domain (vhost wizard)

```bash
lds setup domain
```

### 5) Optional: trust HTTPS locally (Root CA)

```bash
sudo lds certificate install
```


## Command hints (quick reference)


```bash
lds help
```

### Core stack

```bash
lds up            # start stack
lds start         # alias of up
lds stop          # stop stack (down)
lds down          # alias of stop
lds restart       # stop + up + HTTP reload
lds reload        # recreate + HTTP reload
lds rebuild all   # rebuild/pull images
lds config        # show resolved docker compose config
lds http reload   # reload the HTTP load balancer (nginx/apache)
lds tools         # shell into SERVER_TOOLS container
lds doctor        # host diagnostics
```

### Setup

```bash
lds setup init
lds setup permissions
lds setup profile      # (or: lds setup profiles) choose which services to configure
lds setup domain
```

### Certificates

```bash
lds certificate install
lds certificate uninstall
lds certificate uninstall --all
```

### Run (ad-hoc Dockerfile runner)

```bash
lds run
lds run --publish 8025:8025
lds run ps
lds run logs
lds run stop
lds run rm
lds run open 8025
```

### Shortcuts

```bash
# Run your hosts file using container
lds php -v
lds composer install
lds node -v
lds npm i
lds npx <pkg>

# Login into the service containers
lds my --login
lds maria --login
lds pg --login
lds redis --login

# if You are not getting access to certain IP that is used via vpn
lds vpn-fix
```

> Tip: If you forget anything, `lds help` is the source of truth.

## CLI help (built-in “man”)

```bash
lds help
```

---

## Documentation

This README stays intentionally short.

* Full documentation: https://docs.infocyph.com/projects/LocalDevStack
* Quick reference: `lds help ...`

---

## License

MIT
