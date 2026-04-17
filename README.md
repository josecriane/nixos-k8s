# NixOS K8s

Declarative multi-node Kubernetes cluster on NixOS. Everything defined in Nix, deployed idempotently via systemd.

## What's included

- **Two Kubernetes engines**: K3s (lightweight) or kubeadm (standard, NixOS native)
- **Two CNI options**: Flannel (simple) or Calico (network policies, BGP)
- **Multi-node** with server/agent roles and optional HA
- **MetalLB** for L2 LoadBalancer IPs on your LAN
- **Traefik** as ingress controller with HTTPS
- **TLS certificates**: manual (via agenix) or automatic (cert-manager + Cloudflare)
- **NFS or local storage** with shared PV/PVC
- **Optional LUKS disk encryption** with SSH or TPM2 unlock
- **Hardened base** with SSH key-only auth, fail2ban, kernel hardening, and systemd sandboxing

Services boot in order through 5 systemd tiers on the bootstrap server. Agent nodes join the cluster automatically.

## Usage modes

### Standalone

Clone this repo, add your configuration, and deploy directly. Everything lives in one repo.

```bash
# 1. Clone and enter dev shell
git clone <repo-url> && cd nixos-k8s
nix develop

# 2. Generate config.nix interactively
make setup

# 3. Add secrets (see Secrets section)

# 4. Install the bootstrap server
make install NODE=server1

# 5. After reboot, add more nodes
make install NODE=agent1

# 6. Verify
make status
```

Your `config.nix`, `secrets/`, and `hosts/` are tracked in your repo. The flake detects `config.nix` automatically and builds your cluster.

### Separate private repo (flake input)

Use this repo as a flake input from your own private repo. This keeps the framework public and your deployment config private.

In your private repo, create a `flake.nix`:

```nix
{
  description = "My K8s cluster deployment";

  inputs = {
    nixos-k8s.url = "github:your-user/nixos-k8s";
  };

  outputs = { self, nixos-k8s, ... }: {
    nixosConfigurations = nixos-k8s.lib.mkCluster {
      clusterConfig = import ./config.nix;
      hostsPath = ./hosts;
      secretsPath = ./secrets;
    };

    devShells = nixos-k8s.devShells;
  };
}
```

Your private repo structure:

```
my-cluster/
  flake.nix              Imports nixos-k8s
  config.nix             Your cluster configuration
  hosts/
    server1/             Per-node hardware config
  secrets/
    secrets.nix          Agenix public keys
    k3s-token.age        Cluster join token
    tls-cert.age         TLS certificate (encrypted)
    tls-key.age          TLS private key (encrypted)
  Makefile               Copy from nixos-k8s
  scripts/               Copy from nixos-k8s
```

Copy the `Makefile` and `scripts/` from this repo into your private repo. Update the framework with `nix flake update`.

## Prerequisites

- One or more machines (x86_64, UEFI boot) to form the cluster
- [Nix](https://nixos.org/download/) with flakes enabled on your local machine
- SSH access to the target machines
- An agenix identity key for encrypting secrets

## Commands

```
make help             Show all available targets
make setup            Run interactive setup wizard
make install NODE=x   Install NixOS on a node (FORMATS DISK)
make deploy NODE=x    Deploy config to a node
make deploy-all       Deploy to all nodes (servers first)
make bootstrap        Initial cluster bootstrap
make ssh NODE=x       SSH into a node
make status           Show cluster nodes and pods
make logs NODE=x      Show K3s logs for a node
make reinstall SVC=x  Force reinstall a service (clears marker)
make check            Build all configs without deploying
make fmt              Format .nix files
make clean            Remove build artifacts
```

Services deployed with `createHelmRelease` detect config changes automatically. When you change a chart version, values, or ingress in a `.nix` file, `make deploy` will re-run only the affected services. No manual upgrade step needed.

## Configuration

All settings live in `config.nix`. See `config.example.nix` for the full template.

### Nodes

Define your cluster nodes in the `nodes` attrset. Each key maps to a `hosts/<key>/` directory:

```nix
{
  # Cluster-wide settings
  domain = "example.com";
  subdomain = "k8s";
  gateway = "192.168.1.1";
  # ...

  nodes = {
    server1 = {
      ip = "192.168.1.100";
      role = "server";    # "server" or "agent"
      bootstrap = true;   # true on the first server only
    };
    server2 = {
      ip = "192.168.1.101";
      role = "server";
      bootstrap = false;
    };
    agent1 = {
      ip = "192.168.1.102";
      role = "agent";
      bootstrap = false;
    };
  };
}
```

### Node roles

| Role | What it does |
|------|-------------|
| **server** (bootstrap=true) | First server. Initializes cluster, runs MetalLB/Traefik/cert-manager setup |
| **server** (bootstrap=false) | Additional server. Joins cluster, provides HA |
| **agent** | Worker node. Runs workloads only, no control plane |

### Kubernetes engine

```nix
kubernetes = {
  engine = "k3s";      # or "kubeadm"
  cni = "flannel";     # or "calico"
};
```

| Engine | Description |
|--------|-------------|
| **k3s** | Lightweight, single binary. Bundles Flannel, CoreDNS, local-path provisioner. Fast to deploy. |
| **kubeadm** | Standard Kubernetes via NixOS `services.kubernetes` module. Closer to upstream, automatic PKI. |

| CNI | Description |
|-----|-------------|
| **flannel** | Simple VXLAN overlay. Bundled with K3s, installed separately with kubeadm. |
| **calico** | Network policies, BGP support. Deployed via Tigera operator. Works with both engines. |

Both engines use the same infrastructure on top (MetalLB, Traefik, cert-manager, storage) and the same helpers (`lib.sh`, `lib.nix`). Switching engine only changes how the cluster is bootstrapped.

### TLS certificates

Two providers, controlled by `certificates.provider` in `config.nix`:

**Manual** (`provider = "manual"`): bring your own certificate. Encrypt it with agenix and it gets uploaded to the cluster automatically on deploy.

```bash
cd secrets

# Encrypt your wildcard certificate and key
agenix -e tls-cert.age < /path/to/wildcard.crt
agenix -e tls-key.age < /path/to/wildcard.key
```

Add them to `secrets/secrets.nix`:

```nix
"tls-cert.age".publicKeys = [ admin server1 ];
"tls-key.age".publicKeys = [ admin server1 ];
```

The certificate is uploaded to the cluster as a K8s TLS secret in the `traefik-system` namespace and a default `TLSStore` is created pointing to it. IngressRoutes don't reference per-namespace copies of the secret, so the private key lives in a single namespace only (less blast radius if an app namespace is compromised).

All HTTPS responses include an `HSTS` header (`max-age=31536000; includeSubDomains; preload`) and HTTP is redirected to HTTPS with a permanent 308.

**Renewing a manual certificate:**

Re-encrypt the `.age` files and redeploy. The service compares a hash of the encrypted cert against the marker file, so changes are applied automatically without `make reinstall`:

```bash
cd secrets
agenix -e tls-cert.age < /path/to/new-wildcard.crt
agenix -e tls-key.age < /path/to/new-wildcard.key
```

Then a regular `make deploy NODE=<name>` picks it up.

**ACME** (`provider = "acme"`): automatic via cert-manager + Cloudflare DNS-01. Requires the `cloudflare-api-token.age` secret. cert-manager handles issuance and renewal automatically.

```nix
certificates = {
  provider = "acme";            # or "manual"
  restoreFromBackup = false;    # only for acme
};
```

### Storage

Two modes controlled by `config.nix`:

- **NFS** (`storage.useNFS = true`): Kubernetes-native NFS PVs, pods can schedule on any node
- **Local** (`storage.useNFS = false`): hostPath PV with nodeAffinity to the bootstrap server

## Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix). Encrypted `.age` files are tracked in git.

### Setup

1. Generate an agenix identity key:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/my-agenix-key
   ```

2. Copy the template:
   ```bash
   cp secrets/secrets.example.nix secrets/secrets.nix
   ```

3. Add your public key and host keys to `secrets/secrets.nix`

4. Create secrets:
   ```bash
   cd secrets

   # Generate cluster join token (required)
   openssl rand -hex 32 | agenix -e k3s-token.age

   # TLS certificate (only if certificates.provider = "manual")
   agenix -e tls-cert.age < /path/to/wildcard.crt
   agenix -e tls-key.age < /path/to/wildcard.key

   # Cloudflare API token (only if certificates.provider = "acme")
   agenix -e cloudflare-api-token.age
   ```

Required secrets:

| Secret | Purpose | Who needs it |
|--------|---------|-------------|
| `k3s-token.age` | Cluster join token | All nodes |
| `admin-password-hash.age` | sha-512 hash of the admin user password (used for sudo) | All nodes |

Certificate secrets (one or the other):

| Secret | Purpose | When needed |
|--------|---------|-------------|
| `tls-cert.age` | Wildcard TLS certificate | `certificates.provider = "manual"` |
| `tls-key.age` | Wildcard TLS private key | `certificates.provider = "manual"` |
| `cloudflare-api-token.age` | DNS-01 certificates | `certificates.provider = "acme"` |

Service-specific secrets:

| Secret | Purpose | When needed |
|--------|---------|-------------|
| `registry-htpasswd.age` | htpasswd for Docker registry push auth | `services.docker-registry = true` |
| `github-app-key.age` | GitHub App private key (.pem) | `services.github-runners = true` + `githubApp` block |
| `github-pat.age` | GitHub PAT (fallback if no App configured) | `services.github-runners = true` without `githubApp` |

Optional:

| Secret | Purpose |
|--------|---------|
| `wifi-password.age` | WiFi PSK (if `useWifi = true`) |

### Generating the admin password hash

```bash
# mkpasswd appends a trailing newline that breaks PAM auth; strip it.
nix-shell -p mkpasswd --run 'mkpasswd -m sha-512' | tr -d '\n' > /tmp/pass-hash
agenix -e secrets/admin-password-hash.age < /tmp/pass-hash
rm /tmp/pass-hash
```

The admin user's sudo requires this password for any command outside the explicit NOPASSWD list (the Makefile-driven flow runs commands that are allowed without a password). `make deploy` prompts once for the password per deploy.

## Project structure

```
nixos-k8s/
  flake.nix                          Exports lib.mkCluster + standalone mode
  config.example.nix                 Configuration template
  Makefile                           All commands
  hosts/
    server1/                         Example host config
      default.nix                    Networking, DNS, hostname
      hardware-configuration.nix     Hardware-specific
      disk-config.nix                Disk partitioning
  modules/
    core/
      nix.nix                        Flakes, GC, store optimization
      users.nix                      Admin user, sudo, SSH keys
      ssh.nix                        SSH hardening
      security.nix                   Firewall, fail2ban, kernel sysctls
      encryption.nix                 LUKS disk encryption (SSH/TPM unlock)
    services/                        System services (add as needed)
    kubernetes/
      lib.nix                        Nix helpers + createHelmRelease
      lib.sh                         Bash helpers
      systemd-targets.nix            Boot tier ordering
      infrastructure/
        k3s.nix                      K3s engine (multi-node)
        kubeadm.nix                  kubeadm engine (NixOS services.kubernetes)
        cni-flannel.nix              Flannel CNI (for kubeadm)
        cni-calico.nix               Calico CNI via Tigera (both engines)
        metallb.nix                  L2 load balancer (bootstrap)
        traefik.nix                  Ingress controller (bootstrap)
        tls-secret.nix               TLS cert upload (manual provider)
        cert-manager.nix             Wildcard certs (bootstrap, acme only)
        local-path-provisioner.nix   Storage provisioner (kubeadm only)
        nfs-mounts.nix               NFS mount declarations (all nodes)
        nfs-storage.nix              PV/PVC creation (bootstrap)
        cleanup.nix                  Cleanup disabled services (bootstrap)
      apps/
        docker-registry.nix          Docker Registry + UI
        docker-mirror.nix            Docker Hub pull-through cache
        github-runners.nix           GitHub Actions self-hosted runners (DinD)
  scripts/
    setup.sh                         Interactive config wizard
    install.sh                       Node installation with nixos-anywhere
    generate-hardware-config.sh      Auto-detect hardware from target machine
  secrets/
    secrets.example.nix              Agenix key template
```

## Adding a node

1. Add the node to `config.nix`:
   ```nix
   nodes = {
     # ...existing nodes...
     agent2 = {
       ip = "192.168.1.103";
       role = "agent";
       bootstrap = false;
     };
   };
   ```

2. Create its host directory (copy from an existing one):
   ```bash
   cp -r hosts/server1 hosts/agent2
   # Edit hosts/agent2/hardware-configuration.nix for the new hardware
   # Edit hosts/agent2/disk-config.nix if the disk differs
   ```

3. Get the host's SSH public key and add it to `secrets/secrets.nix`, then re-encrypt:
   ```bash
   ssh-keyscan 192.168.1.103 | grep ed25519  # get the key
   # Add to secrets/secrets.nix, then:
   agenix -r  # re-encrypt all secrets for new recipients
   ```

4. Install:
   ```bash
   make install NODE=agent2
   make status  # verify it joined
   ```

The install script auto-detects hardware (CPU, disk, network driver) and generates `hardware-configuration.nix` if it doesn't exist.

## Included services

All services are optional, toggled in `config.nix`. They deploy as Helm charts automatically.

| Service | Toggle | URL | Notes |
|---------|--------|-----|-------|
| Docker Registry | `services.docker-registry = true` | `registry.<sub>.<domain>` | Private registry. Anonymous pulls, authenticated push (BasicAuth via `registry-htpasswd.age`). Web UI at `registry-ui.<sub>.<domain>` (auth required). |
| Docker Mirror | `services.docker-mirror = true` | cluster-internal | Pull-through cache for Docker Hub. Reachable only from cluster pods at `docker-mirror-docker-registry.container-mirror.svc.cluster.local:5000`. |
| GitHub Runners | `services.github-runners = true` | - | Self-hosted ARC runners with Docker-in-Docker. Egress restricted via NetworkPolicy (see security notes below). |

### Docker Registry config

Anonymous pulls, BasicAuth for push (and for the UI). Credentials live in `secrets/registry-htpasswd.age`.

Generate the htpasswd file and encrypt it:

```bash
nix-shell -p apacheHttpd --run 'htpasswd -Bc /tmp/htpasswd ci'
agenix -e secrets/registry-htpasswd.age < /tmp/htpasswd
rm /tmp/htpasswd
```

Add more users with `htpasswd -B /tmp/htpasswd <user>` (without `-c`) before encrypting.

From the CI:

```bash
docker login registry.<sub>.<domain> -u ci
docker push registry.<sub>.<domain>/myimage:tag
```

Rotate credentials: regenerate the htpasswd, re-encrypt, then `make reinstall SVC=docker-registry`.

### GitHub Actions runners config

**Recommended: GitHub App auth** (minimal scopes, short-lived tokens)

1. Create a GitHub App in your org (`https://github.com/organizations/<org>/settings/apps/new`) with permissions:
   - **Repository**: `Actions: Read`, `Metadata: Read`
   - **Organization**: `Self-hosted runners: Read and write`
2. Generate a private key (`.pem`), note the App ID, install the app on your org and note the Installation ID.
3. Configure:

```nix
services.github-runners = true;
github-runners = {
  configUrl = "https://github.com/your-org";
  maxRunners = 5;
  runnerName = "self-hosted-linux";
  githubApp = {
    appId = 1234567;
    installationId = 87654321;
  };
};
```

4. Encrypt the App private key:

```bash
agenix -e secrets/github-app-key.age < /path/to/app-private-key.pem
```

**Fallback: fine-grained PAT** (omit the `githubApp` block)

```bash
echo "ghp_xxxx" | agenix -e secrets/github-pat.age
```

Use a fine-grained PAT scoped to `Self-hosted runners: Read and write` on the target org/repo. Avoid classic PATs with broad scopes.

Runners include Docker-in-Docker support. When `docker-mirror` is enabled, DinD is configured to use the mirror automatically via cluster-internal DNS (no external exposure).

### Security considerations for runners

DinD runs as a **privileged** container, which is equivalent to giving the workflow root on the host node. The module mitigates this by applying a `NetworkPolicy` that restricts egress from the runner namespace:

| Allowed | Blocked |
|---------|---------|
| DNS (kube-system CoreDNS) | kube-apiserver |
| Docker mirror (cluster-internal) | kubelet on nodes |
| Traefik (for registry push) | Other namespaces (cert-manager, calico-system, ...) |
| Internet (public IPs only) | LAN and all RFC1918 private networks |

Remaining risk: a workflow that manages to escape DinD still has root on the node where the runner pod is scheduled. To minimize impact:

- **Use dedicated worker nodes for runners**: in multi-node clusters, taint the control-plane nodes so runner pods can only schedule on workers. A node compromise then only affects a worker, not the cluster control plane.
- **Limit who can trigger runs**: use branch protection rules, restrict `pull_request_target`, and avoid running untrusted PRs from external contributors.
- **Prefer rootless builders for image builds**: replace `docker build` with kaniko or buildah in workflow steps where possible. DinD is only strictly needed when workflows use `docker run`.

## Adding a service

Use `createHelmRelease` to add a new Helm chart. One function call generates the complete systemd service with marker file, helm install, ingress, and TLS.

1. Create a module in `modules/kubernetes/apps/`:

   ```nix
   # modules/kubernetes/apps/my-service.nix
   { config, lib, pkgs, serverConfig, ... }:
   let k8s = import ../lib.nix { inherit pkgs serverConfig; }; in
   k8s.createHelmRelease {
     name = "my-service";
     namespace = "my-service";
     repo = { name = "my-repo"; url = "https://charts.example.com"; };
     chart = "my-repo/my-service";
     version = "1.0.0";
     tier = "core";           # systemd tier: infrastructure, storage, core, apps, extras
     values = {               # Nix attrset, converted to YAML automatically
       replicaCount = 2;
       persistence.enabled = true;
     };
     ingress = {              # optional: creates Traefik IngressRoute with TLS
       host = "my-service";   # -> my-service.<subdomain>.<domain>
       service = "my-service";
       port = 8080;
     };
     waitFor = "my-service";  # optional: wait for deployment to be ready
     extraScript = "";        # optional: extra bash after helm install
   }
   ```

2. Add the toggle to `config.example.nix` and import in `modules/kubernetes/default.nix`:

   ```nix
   ++ lib.optionals (isBootstrap && (enabled "my-service")) [
     ./apps/my-service.nix
   ]
   ```

3. Enable and deploy:
   ```bash
   # In config.nix:
   services.my-service = true;

   make deploy NODE=server1
   ```

## Boot sequence

**Bootstrap server:**

1. Network up, static IP, dnsmasq starts
2. `k3s-network-check` verifies connectivity
3. K3s starts with `--cluster-init` (HA) or as single server
4. **Tier 1**: CNI, MetalLB, Traefik, TLS secret, local-path-provisioner (parallel)
5. **Tier 2**: NFS mounts, PV/PVC creation
6. **Tier 3-5**: Your services

**Other servers / agents:**

1. Network up, verify bootstrap server reachable
2. K3s joins cluster using shared token
3. CNI bridge fixer starts
4. Node appears in `kubectl get nodes`

## Disk encryption

Each node can optionally use LUKS encryption on its root partition. The EFI partition stays unencrypted (required for boot).

### Configuration

Add `encryption` to a node in `config.nix`:

```nix
nodes = {
  server1 = {
    ip = "192.168.1.100";
    role = "server";
    bootstrap = true;
    encryption = {
      enable = true;
      unlock = "ssh";    # or "tpm"
      sshPort = 2222;    # only used with unlock = "ssh"
    };
  };
};
```

### Unlock methods

**SSH unlock** (`unlock = "ssh"`): the node boots into a minimal initrd with an SSH server. You connect and type the passphrase to continue boot. Best for maximum security where you accept manual intervention after every reboot.

```bash
# After reboot, connect to the initrd SSH server:
ssh -p 2222 root@192.168.1.100

# Once connected, unlock the disk:
systemd-tty-ask-password-agent --query

# Type the LUKS passphrase when prompted. The node will continue booting
# and the SSH session will close automatically.
```

The initrd SSH server uses port 2222 by default (configurable via `sshPort`) and accepts the same admin SSH keys defined in `adminSSHKeys`. The node gets its static IP during initrd so it's reachable on the network before the root filesystem is unlocked. Make sure the network driver for your hardware is included in `boot.initrd.availableKernelModules` (the install script detects this automatically).

**TPM unlock** (`unlock = "tpm"`): automatic unlock using the machine's TPM2 chip. The encryption key is sealed to the hardware and firmware state. No manual intervention needed, nodes reboot unattended. If someone removes the disk and puts it in another machine, it can't be read.

After the first install, enroll the TPM key:

```bash
make ssh NODE=server1
sudo systemd-cryptenroll /dev/disk/by-partlabel/disk-main-root \
  --tpm2-device=auto \
  --tpm2-pcrs=0+7
```

The passphrase set during install remains as a fallback if TPM unlock fails (e.g. after a firmware update).

### Comparison

| | SSH unlock | TPM unlock |
|---|---|---|
| Manual intervention on reboot | Yes | No |
| Survives power outage unattended | No | Yes |
| Protects against disk theft | Yes | Yes |
| Protects against boot tampering | No (passphrase can be phished) | Yes (bound to firmware state) |
| Requires TPM2 hardware | No | Yes |

### Mixed setups

Different nodes can use different methods. For example, the bootstrap server with SSH unlock for maximum security, and agents with TPM for unattended restarts:

```nix
nodes = {
  server1 = {
    ip = "192.168.1.100";
    role = "server";
    bootstrap = true;
    encryption = { enable = true; unlock = "ssh"; };
  };
  agent1 = {
    ip = "192.168.1.102";
    role = "agent";
    bootstrap = false;
    encryption = { enable = true; unlock = "tpm"; };
  };
  agent2 = {
    ip = "192.168.1.103";
    role = "agent";
    bootstrap = false;
    # No encryption on this node
  };
};
```

## Security posture

The defaults aim for a reasonable security/ergonomics balance for a homelab / small team cluster. Highlights:

**User and sudo**
- Admin user is fully declarative (`users.mutableUsers = false`) with a password hash from `admin-password-hash.age`. Manual `passwd`/`usermod` changes are reset on every activation.
- `sudo` requires a password for interactive use. Only specific commands used by the Makefile are `NOPASSWD`: `systemctl status/start/stop/restart *-setup.service`, `journalctl`, `kubectl`, and `rm -f /var/lib/*-setup-done`.
- `make deploy` prompts once for the sudo password (passed to the remote via `--ask-sudo-password`).
- Root login disabled (`root.hashedPassword = "!"`).

**Kubernetes API access**
- The cluster-admin kubeconfig is NOT copied to the admin's home directory. Use `sudo kubectl` (kubectl is in the NOPASSWD list; `KUBECONFIG` is preserved via `env_keep`).

**Network**
- Kubelet's port 10250 is NOT open to all interfaces. It's restricted via nftables rules to cluster node IPs + pod/service CIDRs.
- SSH hardened (no passwords, no root, modern KEX/ciphers, fail2ban).
- Kernel sysctl hardening (rp_filter, no source routing, no redirects, etc.).

**TLS**
- Wildcard TLS secret lives in a single namespace (`traefik-system`). The default `TLSStore` makes it available to all IngressRoutes without copying the private key into every app namespace.
- HTTPS enforced: HTTP is redirected to HTTPS permanently (308) and `Strict-Transport-Security` is set on all HTTPS responses (1 year, includeSubDomains, preload).
- Certificate rotation is automatic: re-encrypt `tls-cert.age`/`tls-key.age` with agenix, deploy, and the upload service re-runs because a content-hash marker detects the change.

**Supply chain**
- External manifests (Flannel, local-path-provisioner) are fetched via `pkgs.fetchurl` with SHA-256 pinning, so the hash is verified at build time. Helm charts are pinned to exact versions.
- Docker registry accepts anonymous pulls but requires BasicAuth (htpasswd via agenix) for push and UI access.
- Docker mirror is cluster-internal only (no external ingress).
- GitHub runners authenticate to GitHub via a GitHub App (short-lived tokens) by default; a fine-grained PAT is accepted as fallback.
- Runner pods have a restrictive `NetworkPolicy` that blocks the Kubernetes API, kubelet, other namespaces, and the LAN. Outbound allowed only to DNS, the docker mirror/registry, and public internet.

**Agenix secret ordering**
- The NixOS users activation waits for agenix (`system.activationScripts.users.deps = [ "agenixInstall" ]`), so `hashedPasswordFile` sees the decrypted file at activation time instead of locking the account.

## DNS setup

For services to be reachable at `*.<subdomain>.<domain>` (e.g. `registry.k8s.example.com`), your local DNS must resolve the wildcard to the Traefik LoadBalancer IP (`traefikIP` in `config.nix`).

### pfSense (Unbound)

On pfSense with Unbound DNS Resolver:

1. Go to **Services > DNS Resolver**
2. Scroll to **Custom options** and add:

```
server:
local-data: "<subdomain>.<domain>. A <traefikIP>"
local-zone: "<subdomain>.<domain>." redirect
```

For example, with `subdomain = "k8s"`, `domain = "example.com"`, and `traefikIP = "192.168.1.200"`:

```
server:
local-data: "k8s.example.com. A 192.168.1.200"
local-zone: "k8s.example.com." redirect
```

This makes any `*.k8s.example.com` query resolve to the Traefik IP. Traefik then routes each subdomain to the correct service based on IngressRoute rules.

### Pi-hole

Pi-hole uses dnsmasq, which supports wildcard DNS natively.

1. SSH into your Pi-hole
2. Create a custom config file:

```bash
sudo nano /etc/dnsmasq.d/04-k8s-wildcard.conf
```

3. Add the wildcard entry:

```
address=/<subdomain>.<domain>/<traefikIP>
```

For example:

```
address=/k8s.example.com/192.168.1.200
```

4. Restart dnsmasq:

```bash
sudo pihole restartdns
```

This resolves `k8s.example.com` and all its subdomains to the Traefik IP. The config file persists across Pi-hole updates.

## Hardware

Edit `hosts/<node>/hardware-configuration.nix` per machine:

- **AMD**: `boot.kernelModules = [ "kvm-amd" ]` + `hardware.cpu.amd.updateMicrocode = true`
- **Intel**: `boot.kernelModules = [ "kvm-intel" ]` + `hardware.cpu.intel.updateMicrocode = true`
- **Disk**: set `disko.devices.disk.main.device` to your disk

The install script auto-detects these values when installing from a live USB.

## License

MIT
