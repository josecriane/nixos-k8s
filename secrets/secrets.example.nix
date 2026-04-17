let
  # Server public keys (add after first boot of each node)
  server1 = "ssh-ed25519 AAAA... root@server1";
  # server2 = "ssh-ed25519 AAAA... root@server2";
  # agent1  = "ssh-ed25519 AAAA... root@agent1";

  # Your public key for encrypting/decrypting
  admin = "ssh-ed25519 AAAA... user@host";

  allHosts = [ server1 ]; # Add all host keys here
  allKeys = [ admin ] ++ allHosts;
in
{
  # K3s cluster token (all nodes need to read it)
  "k3s-token.age".publicKeys = allKeys;

  # Admin user password hash (required, all nodes)
  "admin-password-hash.age".publicKeys = allKeys;

  # TLS wildcard certificate (bootstrap server, certificates.provider = "manual")
  "tls-cert.age".publicKeys = [
    admin
    server1
  ];
  "tls-key.age".publicKeys = [
    admin
    server1
  ];

  # Cloudflare API token (bootstrap server, certificates.provider = "acme")
  # "cloudflare-api-token.age".publicKeys = [ admin server1 ];

  # Docker registry htpasswd (bootstrap server, services.docker-registry = true)
  # "registry-htpasswd.age".publicKeys = [ admin server1 ];

  # GitHub App private key for ARC (bootstrap, services.github-runners = true with githubApp)
  # "github-app-key.age".publicKeys = [ admin server1 ];

  # GitHub PAT fallback (only when githubApp is NOT configured)
  # "github-pat.age".publicKeys = [ admin server1 ];

  # Optional
  # "wifi-password.age".publicKeys = allKeys;
}
