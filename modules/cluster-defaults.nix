{
  timezone = "UTC";
  puid = 1000;
  pgid = 1000;
  useWifi = false;

  kubernetes = {
    engine = "k3s";
    cni = "flannel";
    loadBalancer = "metallb";
    podCidr = "10.42.0.0/16";
    serviceCidr = "10.43.0.0/16";
  };

  certificates = {
    provider = "manual";
    restoreFromBackup = true;
  };

  storage = {
    useNFS = false;
    longhorn.enable = false;
  };

  services = {
    monitoring = false;
    traefikDashboard = false;
  };

  gc.enable = false;
}
