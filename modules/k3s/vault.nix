{ config, lib, pkgs, ... }:

{
  # Keep Vault under k3s server manifests so platform secrets infrastructure
  # is managed from the infra repository.
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/server/manifests 0755 root root - -"
    "L+ /var/lib/rancher/k3s/server/manifests/vault.yaml - - - - /etc/k3s/vault.yaml"
  ];

  environment.etc."k3s/vault.yaml".text = ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: vault
      namespace: kube-system
    spec:
      repo: https://helm.releases.hashicorp.com
      chart: vault
      targetNamespace: vault
      createNamespace: true
      valuesContent: |-
        global:
          authDelegator:
            enabled: true
        injector:
          enabled: false
        server:
          standalone:
            enabled: true
            config: |-
              ui = true
              listener "tcp" {
                tls_disable = 1
                address = "[::]:8200"
                cluster_address = "[::]:8201"
              }
              storage "raft" {
                path = "/vault/data"
              }
          dataStorage:
            enabled: true
            size: 10Gi
            storageClass: zfs-reliable
        ui:
          enabled: true
  '';
}
