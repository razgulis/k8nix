let
  # Your laptop key (lets you edit/rekey secrets locally)
  laptop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8xWUfi/PtattP6DK+kQ74ynKikXPWx+OPkPN73ROG sergei.razgulin@gmail.com";

  # Paste each node’s /etc/ssh/ssh_host_ed25519_key.pub here:
  hosts = {
    "pi-master-1" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMy5MgoFs0BgZAwJWbUlOpkFrzlvZAzVOZMl8gan5JJh root@pi-master-1";
    "pi-worker-1" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM6ujLebyeMT2iipj/PysxQrR5uxCrLwLptsW5fkX491 root@pi-worker-1";
    "pi-worker-2" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDdp/ByOrM644lD1gxncjAFczEkR5KE150bdT+okq/si root@pi-worker-2";
    "pi-worker-3" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXgMzm999HbggNNHOXYhmki8sAnTnIptRQnv67hOF6K root@pi-worker-3";
    "pi-worker-4" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILRk5gK9+6Z30wlnYSBZbZwPK+goPkvyI5gK49H4/6We root@pi-worker-4";
    "r630-storage" = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMiY9RtgVBVwjWIBknwGDxK38Vd5E15D/xSsyML36biO root@r630-storage";
  };

  k3sNodes = [
    laptop
    hosts."pi-master-1"
    hosts."pi-worker-1"
    hosts."pi-worker-2"
    hosts."pi-worker-3"
    hosts."pi-worker-4"
    hosts."r630-storage"
  ];
in
{
  "k3s-token.age".publicKeys = k3sNodes;
  "kubeconfig-ro.age".publicKeys = k3sNodes;
}
