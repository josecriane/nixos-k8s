let
  # Server public keys (add after first boot of each node)
  server1 = "ssh-ed25519 AAAA... root@server1";
  # server2 = "ssh-ed25519 AAAA... root@server2";
  # agent1  = "ssh-ed25519 AAAA... root@agent1";

  # Your public key for encrypting/decrypting
  admin = "ssh-rsa AAAA... user@host";

  allHosts = [ server1 ]; # Add all host keys here
  allKeys = [ admin ] ++ allHosts;
in
{
  # K3s cluster token (all nodes need to read it)
  "k3s-token.age".publicKeys = allKeys;

  # Cloudflare API token (only servers that run cert-manager)
  "cloudflare-api-token.age".publicKeys = [
    admin
    server1
  ];

  # GitHub PAT (only bootstrap server, only if github-runners enabled)
  # "github-pat.age".publicKeys = [ admin server1 ];

  # Optional
  "wifi-password.age".publicKeys = allKeys;
  "admin-password-hash.age".publicKeys = allKeys;
}
