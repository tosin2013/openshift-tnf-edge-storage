# LINBIT SDS Integration on OpenShift 4.22+

Synthesized guidance for workshop design. Local research notes remain untracked; this document is the publishable architecture summary.

## Why LINBIT SDS for this workshop

LINBIT SDS pairs:

- **Control plane — LINSTOR:** controller + satellite DaemonSet, CSI driver, HA controller  
- **Data plane — DRBD 9:** in-kernel block replication (Protocol C for RPO 0 in-cluster)  

Strict separation means management-plane disruption does not interrupt mounted volumes. Resource footprint stays small relative to Ceph/ODF (~700 MiB class for controller/satellites; roughly 32 MiB RAM per TiB replicated), which fits **TNF** and **TNA** minimal nodes.

Delivered via the **Red Hat certified LINSTOR Operator** (OperatorHub), including SCC automation and RHEL-based CSI sidecars.

## Control plane components

| Component | OpenShift form | Role |
|-----------|----------------|------|
| Controller | Deployment | Desired state, API/CSI orchestration |
| Satellite | DaemonSet | LVM/LVMThin/ZFS pools, DRBD links |
| CSI driver | Sidecars | Provision / attach / snapshot |
| HA controller | DaemonSet | Faster reschedule on node failure |

Customize with `LinstorCluster` and `LinstorSatelliteConfiguration` CRDs (device paths, placement, kernel modules).

## Storage pools by track

| Track | Raw devices | Pool type | Quorum helper |
|-------|-------------|-----------|---------------|
| A — AWS | Secondary EBS (gp3/io2), unformatted | LVMThin recommended (COW snapshots) | Diskless tiebreaker on **arbiter** (or third compact node) |
| B — TNF | Local NVMe or virtio disks | LVMThin recommended | Two diskful peers + **hardware fencing** for node HA |

Enable `DrbdOptions/auto-add-quorum-tiebreaker` (default) so LINSTOR can place diskless witnesses when ≥3 satellites exist (Track A).

Multi-AZ Track A: annotate nodes with zone topology; use AuxProps / `xReplicasOnDifferent` so two diskful replicas do not share an AZ.

## Workshop capability patterns

### 1. Database locality (RWO)

- StorageClass with `volumeBindingMode: WaitForFirstConsumer`  
- Primary DRBD replica lands on the scheduled node → local NVMe/EBS reads  
- Offer classes such as 2-way vs 3-way replica (`autoPlace` / placementCount)  
- Lab proof: PostgreSQL/MySQL + `fio` or `pgbench`  

### 2. OpenShift Virtualization live migration (block RWX)

- StorageClass with `DrbdOptions/Net/allow-two-primaries: "yes"`  
- CSI checks `vm.kubevirt.io/name` before concurrent block access  
- Dual-primary only during migration; demote source after cutover  
- Lab proof: Linux (or Windows) VM live migrate between nodes  

### 3. Shared file RWX (optional module)

- LINSTOR Operator v2+ NFS-Ganesha path via `linstor-csi-nfs-server` + DRBD Reactor  
- Failover looks like a short NFS blip to clients  
- Useful for CMS/CI shared directories; distinct from Virt block RWX  

### 4. Edge resilience

| Track | Demo |
|-------|------|
| B — TNF | Induce partition; Pacemaker/STONITH via Redfish (sushy or BMC) fences peer; survivor continues |
| A — TNA | Lose one primary; etcd + diskless tiebreaker keep quorum; show volume stays quorate |

### 5. Geographic DR — S3 snapshot shipping

- Crash-consistent LVMThin/ZFS snapshots  
- Initial full ship, then **incremental block deltas** to S3 (AWS S3 on Track A; MinIO/compatible on Track B)  
- Needs LINSTOR encryption passphrase secret, S3 remote definition, VolumeSnapshotClass + snapshot CRDs  
- OpenShift 4.22 also unlocks **VolumeGroupSnapshot** style multi-PVC consistency where CSI supports it  

### 6. Federated migration (stretch)

- Expose Cluster A LINSTOR controller; Cluster B uses `spec.externalController.url`  
- Add DRBD replica on B, export/import PV/PVC metadata, cut over apps, sever federation  
- Advanced Module 5 only  

## Competitive talking points (SSA)

| Criteria | LINBIT SDS | ODF (Ceph) | Typical user-space SDS |
|----------|------------|------------|-------------------------|
| Latency | Local reads; in-kernel | CRUSH striping overhead | Context-switch cost |
| Footprint | Low | Heavy OSDs | Moderate–high |
| Edge 2-node | Fits TNF story | Usually 3–5 node quorum | Varies |
| Escape hatch | Full copies on LVM/ZFS; mount without K8s | Hard without cluster | Varies / lock-in |

## Field Content / GitOps placement

After cluster exists (AgnosticD or agent-install):

1. Install LINSTOR Operator (OLM Subscription)  
2. Apply `LinstorCluster` / satellite configs for track-specific disks  
3. Apply StorageClasses for modules 1–2 (and optional NFS)  
4. Deploy Showroom + sample apps  
5. Label apps with `demo.redhat.com/application` and userinfo ConfigMaps as needed  

Prefer Helm toggles: `linstor.enabled`, `showroom.enabled`, overlays `values-aws-tna.yaml` / `values-tnf.yaml`.

### Registry credentials

Operator and SDS pods pull images from the private `drbd.io` registry. Maintainers supply **[my.linbit.com](https://my.linbit.com/)** Customer Portal email and password as `linbit_registry_username` / `linbit_registry_password` in AgnosticD `secrets.yml`; Field Content Helm creates the in-cluster `drbdiocred` pull secret. This is not the bare-metal `linbit-manage-node.py` package path.

See [docs/setup/linbit-registry-credentials.md](../setup/linbit-registry-credentials.md).

## Operator / version notes

- Target clusters: **OpenShift 4.22+**  
- Confirm OperatorHub channel and LINBIT Operator version for 4.22 before freezing workshop YAML  
- Prefer OVN-Kubernetes (required on modern 4.x)  
