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

## CLI help (built-in “man”)

```bash
lds help
lds help <command>
lds help setup
lds help certificate
```

---

## Documentation

This README stays intentionally short.

* Full documentation: https://docs.infocyph.com/projects/LocalDevStack
* Quick reference: `lds help ...`

---

## License

MIT
