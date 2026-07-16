# Workshop Module Outline

**Audience:** Solutions Architects / platform engineers  
**Platform:** OpenShift **4.22+** with LINBIT SDS  
**Tracks:** A = AWS + AgnosticD (TNA/Compact); B = KVM/bare metal TNF via agent-install  

Shared LINBIT + Showroom content; Module 0 and Module 3 differ by track.

## Learning outcomes

Participants will be able to:

1. Explain LINSTOR/DRBD control vs data plane separation and when to choose LINBIT over ODF at the edge  
2. Deploy topology-appropriate OpenShift (TNA/Compact or TNF) and install the certified LINSTOR Operator  
3. Demonstrate database locality, Virt live migration, resilience under partition, and S3 incremental snapshot DR  

## Module map

| Module | Lab focus | Track A (AWS) | Track B (TNF) |
|--------|-----------|---------------|---------------|
| **0** | Cluster + LINBIT Operator | AgnosticD provision → Field Content Helm | agent-install ABI → same Helm |
| **1** | StorageClasses + DB locality | WaitForFirstConsumer + fio/pgbench on EBS-backed pools | Same labs on local/virtio pools |
| **2** | OpenShift Virtualization block RWX | Live migrate VM (`allow-two-primaries`) | Same |
| **3** | Edge / minimal resilience | Arbiter + diskless tiebreaker partition drill | **TNF fencing** via sushy/BMC STONITH |
| **4** | S3 snapshot shipping | AWS S3 remote + incremental deltas | MinIO or external S3 |
| **5** (stretch) | Federated `externalController` migration | Optional advanced | Optional advanced |

## Module 0 — Foundations

**Duration (guide):** 45–60 min  

### Objectives

- Stand up the track-specific cluster on OCP 4.22+  
- Install LINSTOR Operator; verify controller, satellites, CSI  
- Create baseline LVMThin storage pool(s)  

### Track A steps

1. Order / run AgnosticD config for TNA or Compact  
2. Confirm arbiter (if TNA) unschedulable for apps  
3. Deploy Field Content from this repo  
4. Attach EBS devices; apply satellite configuration  

### Track B steps

1. On IBM Cloud host: validate agent-install KVM env  
2. Generate 4.22 agent ISO; deploy via KVM (sushy) or bare metal  
3. Export kubeconfig; deploy same Field Content chart  
4. Configure local disks for LINSTOR pools  

### Exit criteria

- `oc get nodes` healthy; LINSTOR pods Running  
- At least one StorageClass can bind a test PVC  

## Module 1 — High-performance databases

**Duration:** 45 min  

- Create StorageClass with `WaitForFirstConsumer` and 2-way replication  
- Deploy sample database  
- Run fio/pgbench; discuss local-read architecture  
- Optional: compare r2 vs r3 classes  

**Applies to:** A + B  

## Module 2 — VMware exit / OpenShift Virtualization

**Duration:** 60 min  

- Enable Virt operators if not preinstalled by AgnosticD/content  
- StorageClass with `allow-two-primaries`  
- Create VM disk PVC (block mode)  
- Live-migrate; observe dual-primary window and label check  

**Applies to:** A + B (requires enough RAM/CPU on both nodes)  

## Module 3 — Resilience (track-specific)

**Duration:** 45–60 min  

### Track A — TNA / Compact

- Identify diskful vs diskless (tiebreaker) resources  
- Simulate primary failure or network isolation (safely)  
- Show etcd + DRBD quorum behavior with arbiter/tiebreaker  

### Track B — TNF fencing

- Review fencing credentials (sushy or BMC)  
- Induce communication loss  
- Observe STONITH / Redfish power action  
- Confirm survivor resumes workloads and storage  

## Module 4 — Geographic DR

**Duration:** 45 min  

- Create LINSTOR encryption passphrase secret  
- Define S3 remote  
- VolumeSnapshotClass → snapshot → verify incremental ship narrative  
- Discuss restore-to-second-cluster story (demo restore if time)  

**Track A:** AWS S3  
**Track B:** MinIO in-cluster or external S3-compatible endpoint  

## Module 5 — Federated migration (optional)

**Duration:** 60+ min  

- Expose controller on Cluster A  
- Join Cluster B satellites via `externalController`  
- Replicate, cut over PVC/workload, sever federation  

Reserve for advanced audiences or day-2 workshop.

## SSA elevator pitch (close)

- Near-bare-metal reads via in-kernel DRBD + WaitForFirstConsumer  
- Virt live migration with controlled dual-primary  
- Edge standard: TNF + fencing where BMC exists; TNA + tiebreaker on AWS  
- Tiny footprint vs Ceph at the edge  
- Certified Operator + LVM/ZFS escape hatch  

## Delivery packaging (later phase)

- Showroom AsciiDoc under Field Content `components/showroom/`  
- Helm values toggles per module dependencies (Virt, MinIO, sample DB)  
- RHDP labels for health and userinfo passback  
