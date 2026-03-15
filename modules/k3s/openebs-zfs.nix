{ config, lib, pkgs, ... }:

{
  # Keep OpenEBS and StorageClass declarations under k3s manifests so they are
  # reconciled automatically by the server.
  systemd.tmpfiles.rules = [
    "d /var/lib/rancher/k3s/server/manifests 0755 root root - -"
    "L+ /var/lib/rancher/k3s/server/manifests/openebs-zfs.yaml - - - - /etc/k3s/openebs-zfs.yaml"
  ];

  environment.etc."k3s/openebs-zfs.yaml".text = ''
    apiVersion: helm.cattle.io/v1
    kind: HelmChart
    metadata:
      name: openebs
      namespace: kube-system
    spec:
      repo: https://openebs.github.io/openebs
      chart: openebs
      targetNamespace: openebs
      createNamespace: true
      valuesContent: |-
        engines:
          local:
            hostpath:
              enabled: false
            lvm:
              enabled: false
            zfs:
              enabled: true
          replicated:
            mayastor:
              enabled: false
        # Keep only the storage engine components; disable bundled logging stack.
        loki:
          enabled: false
        alloy:
          enabled: false
        zfs-localpv:
          zfs:
            # On NixOS, zfs is provided via /run/current-system/sw/bin.
            # Without this, the chart falls back to `zfs` in PATH inside a
            # chroot, which fails and reports zero storage capacity.
            bin: /run/current-system/sw/bin/zfs
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: zfs-reliable
    provisioner: zfs.csi.openebs.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      poolname: "r630-main"
      fstype: "zfs"
    allowedTopologies:
    - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
        - r630-storage
    ---
    # Dedicated class for PostgreSQL/TimescaleDB/pgvector data.
    # Keeps naming explicit while remaining backed by the reliable pool.
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: zfs-ai-postgres
    provisioner: zfs.csi.openebs.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      poolname: "r630-main"
      fstype: "zfs"
    allowedTopologies:
    - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
        - r630-storage
    ---
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: zfs-bulk
    provisioner: zfs.csi.openebs.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      poolname: "r630-bulk"
      fstype: "zfs"
    allowedTopologies:
    - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
        - r630-storage
    ---
    # Dedicated class for object/document storage (MinIO) on the bulk pool.
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: zfs-ai-minio
    provisioner: zfs.csi.openebs.io
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      poolname: "r630-bulk"
      fstype: "zfs"
    allowedTopologies:
    - matchLabelExpressions:
      - key: kubernetes.io/hostname
        values:
        - r630-storage
  '';
}
