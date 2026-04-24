# CLAUDE.md - Project Context

## Summary

NixOS multi-node K3s cluster. Fully declarative and idempotent. One repo deploys all nodes.

Use the nixos-devops-expert agent.

## Conventions

### Interaction Language
- Always respond to the user in Spanish. All conversation, explanations, and questions must be in Spanish.

### Code Language
- All user-facing strings in code (echo, comments, descriptions, notes) MUST be in English.
- No Spanish strings in code. If you find one, translate it.

### No Personal Data in Tracked Files
- Never hardcode IPs, domains, usernames, passwords, API keys, or tokens in `.nix` or `.sh` files.
- All environment-specific values come from `config.nix` (gitignored) or agenix secrets.
- Use generic placeholder IPs in `config.example.nix` (e.g. `192.168.1.x`).

### Module Organization
- New K8s services go in subdirectories under `modules/kubernetes/`
- Never put new `.nix` modules directly in `modules/kubernetes/`. Always use a subdirectory.
- Add new modules to `modules/kubernetes/default.nix` inside `lib.optionals isBootstrap`.

### Multi-Node Architecture
- `serverConfig`: cluster-wide settings (domain, MetalLB pool, etc.)
- `nodeConfig`: per-node settings (ip, role, bootstrap, bootstrapIP, name)
- `clusterNodes`: list of all nodes (for /etc/hosts, firewall rules)
- Each node has its own `hosts/<name>/` directory with hardware-specific config.
- The flake generates one `nixosConfiguration` per node from `config.nix` nodes attrset.

### Kubernetes Engine
- `serverConfig.kubernetes.engine`: `"k3s"` (default) or `"kubeadm"` (NixOS services.kubernetes)
- `serverConfig.kubernetes.cni`: `"flannel"` (default) or `"calico"` (Tigera operator)
- K3s bundles Flannel. With Calico on K3s, built-in Flannel is disabled (`--flannel-backend=none`).
- kubeadm always needs a CNI module installed separately.
- KUBECONFIG path is set dynamically in `lib.nix` based on engine.

### Node Roles
- **bootstrap server**: first server, runs all infra setup services
- **server**: additional server nodes, joins existing cluster, no infra setup
- **agent**: worker nodes, agent role only

### Systemd Services
- Every service uses a marker file (`/var/lib/<service>-setup-done`) for idempotency.
- Use `wantedBy/before = [ "k3s-<tier>.target" ]` for boot ordering.
- Tier order: infrastructure -> storage -> core -> apps -> extras.
- Only the bootstrap server has targets beyond `k3s-infrastructure`.
- Use `lib.sh` bash functions via `${k8s.libShSource}`.

### Secrets and Passwords
- `k3s-token.age`: shared cluster join token (all nodes)
- `cloudflare-api-token.age`: cert-manager (bootstrap server only)
- `registry-htpasswd.age`: shared by docker-registry AND docker-mirror (BasicAuth)
- `docker-mirror-proxy.age`: Docker Hub upstream creds for the mirror (two lines: user, PAT)
- `kubernetes-ca.age` + `kubernetes-apitoken.age`: populated by `scripts/sync-bootstrap-secrets.sh` after bootstrap install; consumed by workers via `age.secrets` in `kubeadm.nix` (guarded by `builtins.pathExists` so setups without workers don't fail evaluation).
- Never generate random passwords unconditionally. Check if K8s secret exists first.

### Multi-node kubeadm bootstrap secrets
- `services.kubernetes` with `easyCerts = true` does not ship CA/token to workers on its own. `kubeadm.nix` guards the `age.secrets.kubernetes-{ca,apitoken}` block with `wantsBootstrapCerts = (!isBootstrap) && pathExists kubernetes-ca.age && pathExists kubernetes-apitoken.age`, so:
  - New projects that haven't run `sync-bootstrap-secrets` yet still evaluate.
  - Once the pair exists, every worker decrypts them to `/var/lib/kubernetes/secrets/ca.pem` and `apitoken.secret` on activation.
- `install.sh` handles the bootstrap host key automatically; the CA/token sync is an explicit second step.

### Script apps
- Registered in `flake.nix` apps.${system}: `install`, `unlock`, `enroll-tpm`, `setup`, `add-node`, `sync-bootstrap-secrets`.
- `scripts/enroll-tpm.sh` writes the LUKS passphrase to `/tmp/tpm-enroll-$$.key` on the target via the first ssh (stdin), then runs `ssh -t sudo systemd-cryptenroll ...` so sudo can prompt over tty. The tmp file is shredded on EXIT via trap.
- `scripts/install.sh` matches node keys with `^[[:space:]]*<node>[[:space:]]*=` (attribute keys in `config.nix` are unquoted). Greps tolerate empty output with `|| true` so `set -e` doesn't mask a clean nixos-anywhere run.
- `scripts/sync-bootstrap-secrets.sh` uses `nix eval --impure --json` to read booleans (`--raw` refuses to coerce bool to string).

### Code Style
- No inline comments explaining obvious code. Only comment non-obvious logic.
- Prefer `lib.sh` bash functions over duplicating kubectl/helm boilerplate.
- Helm: use `helm_repo_add` + `helm_install` from lib.sh.

## Module Structure

```
modules/core/
  nix.nix                  - Flakes, GC, store optimization
  users.nix                - Admin user, sudo, SSH keys
  ssh.nix                  - SSH hardening
  security.nix             - Firewall, fail2ban, kernel sysctls
  encryption.nix           - LUKS disk encryption (SSH/TPM unlock)
  smart.nix                - SMART monitoring (smartd + smartctl_exporter + periodic checks)
modules/kubernetes/
  default.nix              - Orchestrator with conditional imports by role
  lib.nix                  - Nix helpers (libShSource, hostname, createLinuxServerDeployment)
  lib.sh                   - Bash helpers (wait, deploy, ingress, PVC, helm, etc.)
  systemd-targets.nix      - Boot tier targets (bootstrap server only beyond infrastructure)
  infrastructure/
    k3s.nix                - K3s engine (all nodes if engine=k3s)
    kubeadm.nix            - kubeadm engine via services.kubernetes (all nodes if engine=kubeadm).
                             Opens firewall for 6443/10250/9100/8888 to cluster nodes + pod/service CIDRs.
                             Consumes kubernetes-ca.age + kubernetes-apitoken.age (when present) on worker nodes.
    cni-flannel.nix        - Flannel CNI for kubeadm (bootstrap only)
    calico/                - Calico CNI via Tigera operator (bootstrap only). Sets SKIP_NODE_READY=1 on
                             its setup service because the CNI installer itself makes the node Ready
                             (wait_for_k3s would otherwise deadlock on first boot).
    metallb/               - MetalLB (bootstrap only). L2Advertisement pinned to the bootstrap node via
                             nodeSelector kubernetes.io/hostname=<bootstrap> to avoid gratuitous-ARP
                             elections when workers join/leave.
    traefik.nix            - Traefik (bootstrap only)
    cert-manager.nix       - cert-manager (bootstrap only, acme provider)
    nfs-mounts.nix         - NFS mount declarations (all nodes)
    nfs-storage.nix        - PV/PVC creation (bootstrap only)
    longhorn/              - Longhorn storage (host prereqs on all nodes, helm on bootstrap)
    cleanup.nix            - Service cleanup (bootstrap only)
  apps/
    docker-registry/       - Private Docker registry + UI (bootstrap only). Anonymous pulls, BasicAuth
                             push (registry-htpasswd.age shared with docker-mirror).
    docker-mirror/         - Docker Hub pull-through cache (bootstrap only). External ingress at
                             mirror.<sub>.<domain> with BasicAuth (reuses registry-htpasswd.age) plus
                             internal svc URL for pods. Docker Hub upstream creds injected into the
                             chart-generated Secret post-install via extraScript + rollout restart
                             (the twuni chart has no existingSecret field for proxy creds).
    github-runners/        - ARC self-hosted runners (DinD, bootstrap only)
    monitoring/            - kube-prometheus-stack + Loki + Promtail (bootstrap only). Grafana
                             admin password is random, stored in the grafana-admin-credentials Secret
                             (namespace monitoring). smart/nas-smart/nas-node-exporter manifests use
                             hashString(manifestText) for configHash to avoid IFD on the writeText
                             derivation (which breaks nixos-anywhere's path-signing check).
```

## Boot Ordering (systemd tiers)

On bootstrap server:
1. **k3s-infrastructure** - K3s, MetalLB, Traefik, cert-manager
2. **k3s-storage** - PVCs, shared-data setup
3. **k3s-core** - Core services
4. **k3s-apps** - Application services
5. **k3s-extras** - Optional services

On other nodes: only `k3s-infrastructure` target (K3s join + CNI).

## Key Patterns

- `nodeConfig.role` and `nodeConfig.bootstrap` drive conditional module loading
- `lib.mkIf isBootstrap` guards infra setup services
- Marker files for idempotency
- `${k8s.libShSource}` at top of every script
- `k8s.hostname "x"` in Nix, `$(hostname x)` in bash
- `helm_install` handles retry with `--force`

## Commands

| Command | Description |
|---------|-------------|
| `make setup` | Run interactive setup wizard |
| `make install NODE=x` | Install NixOS on a node (FORMATS DISK) |
| `make deploy NODE=x` | Deploy config to a node |
| `make deploy-all` | Deploy to all nodes |
| `make bootstrap` | Initial cluster bootstrap (server first, then all) |
| `make ssh NODE=x` | SSH into a node |
| `make unlock NODE=x` | SSH-unlock LUKS disk via initrd |
| `make enroll-tpm NODE=x` | Enroll TPM2 for auto-unlock (once, after first boot) |
| `make sync-bootstrap-secrets NODE=x` | Copy CA+apitoken from a freshly installed bootstrap into agenix so workers can install declaratively |
| `make status` | Show cluster status |
| `make logs NODE=x` | Show K3s logs for a node |
| `make check` | Build all configs without deploying |
| `make shell` | Enter nix dev shell |
| `make fmt` | Format .nix files |

## Configuration

All settings in `config.nix` (see `config.example.nix`). Nodes defined in `nodes` attrset.

## Storage

- **NFS** (`storage.useNFS = true`): NFS PV type, mounts on all nodes, pods schedule anywhere
- **Local** (`storage.useNFS = false`): hostPath with nodeAffinity to bootstrap server
- **Longhorn** (`storage.longhorn.enable = true`): replicated block storage. Host prereqs (open-iscsi + iscsi_tcp/nfs/nfsv4/dm_crypt kernel modules, iscsiadm/mount.nfs tmpfiles symlinks at `/usr/local/*`) applied on every node; helm release from bootstrap only. `defaultStorageClass = true` unsets the default annotation on k3s local-path.
