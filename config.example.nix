{
  # --- Cluster-wide settings ---
  gateway = "192.168.1.1";
  nameservers = [
    "1.1.1.1"
    "8.8.8.8"
  ];
  useWifi = false;
  wifiSSID = "";
  domain = "example.com";
  subdomain = "k8s";
  adminUser = "admin";
  adminSSHKeys = [
    # "ssh-ed25519 AAAA..."
  ];
  agenixIdentity = "~/.ssh/my-agenix-key";
  puid = 1000;
  pgid = 1000;
  acmeEmail = "you@example.com";
  metallbPoolStart = "192.168.1.200";
  metallbPoolEnd = "192.168.1.254";
  traefikIP = "192.168.1.200";
  timezone = "UTC";

  kubernetes = {
    engine = "k3s"; # "k3s" (lightweight, batteries included) or "kubeadm" (standard, NixOS native)
    cni = "flannel"; # "flannel" (simple overlay) or "calico" (network policies, BGP capable)
    podCidr = "10.42.0.0/16"; # internal pod network
    serviceCidr = "10.43.0.0/16"; # internal service network
  };

  services = {
    docker-registry = false;
    docker-mirror = false;
    github-runners = false;
  };

  # GitHub Actions runners config (only if github-runners = true)
  # Auth via GitHub App (recommended): requires secrets/github-app-key.age (private key .pem)
  # Alternative: set a fine-grained PAT via secrets/github-pat.age (omit githubApp block)
  # github-runners = {
  #   configUrl = "https://github.com/your-org";
  #   maxRunners = 5;
  #   runnerName = "self-hosted-linux";
  #   githubApp = {
  #     appId = 1234567;
  #     installationId = 87654321;
  #   };
  # };

  # NAS integration
  nas = {
    # nas1 = {
    #   enabled = true;
    #   ip = "192.168.1.50";
    #   hostname = "nas1";
    #   role = "media";
    #   nfsExports = {
    #     nfsPath = "/";
    #     data = "/mnt/storage";
    #   };
    # };
  };

  storage = {
    useNFS = false;
  };

  certificates = {
    # "acme" = automatic via cert-manager + Cloudflare DNS-01 (requires cloudflare-api-token.age)
    # "manual" = provide your own cert in certs/tls.crt and certs/tls.key
    provider = "manual";
    restoreFromBackup = false; # only for acme: restore cert backup to avoid rate limits
  };

  # --- Nodes ---
  # Each key maps to a hosts/<key>/ directory with hardware-configuration.nix and disk-config.nix
  nodes = {
    server1 = {
      ip = "192.168.1.100";
      role = "server"; # "server" or "agent"
      bootstrap = true; # true only on the first server
      # encryption = {
      #   enable = true;
      #   unlock = "ssh";  # "ssh" (remote passphrase) or "tpm" (automatic, hardware-bound)
      #   sshPort = 2222;  # port for initrd SSH (only for unlock = "ssh")
      # };
    };
    # server2 = {
    #   ip = "192.168.1.101";
    #   role = "server";
    #   bootstrap = false;
    #   encryption = { enable = true; unlock = "tpm"; };
    # };
    # agent1 = {
    #   ip = "192.168.1.102";
    #   role = "agent";
    #   bootstrap = false;
    # };
  };
}
