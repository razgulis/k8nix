{ config, lib, pkgs, ... }:

{
  # Keep External Secrets Operator under infra-managed k3s manifests.
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/server/manifests 0755 root root - -"
    "L+ /var/lib/rancher/k3s/server/manifests/external-secrets.yaml - - - - /etc/k3s/external-secrets.yaml"
  ];

  environment.etc."k3s/external-secrets.yaml".text = ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: external-secrets
      namespace: kube-system
    spec:
      repo: https://charts.external-secrets.io
      chart: external-secrets
      targetNamespace: external-secrets
      createNamespace: true
      valuesContent: |-
        installCRDs: true
  '';
}
