let
  # Your laptop key (lets you edit/rekey secrets locally)
  laptop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOW8xWUfi/PtattP6DK+kQ74ynKikXPWx+OPkPN73ROG sergei.razgulin@gmail.com"

  # Paste each node’s /etc/ssh/ssh_host_ed25519_key.pub here:
  pi-master-1     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... master ...";
  pi-worker-1     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... w1 ...";
  pi-worker-2     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... w2 ...";
  pi-worker-3     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... w3 ...";
  pi-worker-4-hdd = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... w4 ...";

  k3sNodes = [
    laptop
    pi-master-1
    pi-worker-1
    pi-worker-2
    pi-worker-3
    pi-worker-4-hdd
  ];
in
{
  "k3s-token.age".publicKeys = k3sNodes;
}

