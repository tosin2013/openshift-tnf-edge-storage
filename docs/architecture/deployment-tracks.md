# Deployment Tracks: AWS (AgnosticD) vs TNF (Agent Install)

**OpenShift target:** 4.22 and newer only.

This workshop ships **shared** LINBIT SDS + Showroom content on two different cluster footprints.

## Summary matrix

| Concern | Track A — AWS | Track B — KVM / bare metal |
|---------|---------------|----------------------------|
| OpenShift version | 4.22+ | 4.22+ |
| Topology | **TNA** (2 primary + arbiter) preferred; Compact 3-node alternative | **TNF** (exactly 2 nodes + fencing) |
| Quorum (control plane) | etcd majority via lightweight arbiter | Pacemaker / STONITH via Redfish BMC |
| Quorum (storage) | LINBIT diskless tiebreaker on arbiter (or third compact node) | Two-way DRBD + fencing (no third data replica required) |
| Storage backing | Secondary EBS (gp3/io2) → LVMThin pools | Local NVMe or virtio disks → LVMThin |
| Why not TNF here | EC2 has no tenant BMC/Redfish (including metal via Nitro) | Native or emulated BMC available |
| Cluster bootstrap | **AgnosticD** | **[openshift-agent-install](https://github.com/tosin2013/openshift-agent-install)** (ABI) |
| Workload / lab deploy | Field Content CI / ArgoCD (Helm) | Same Helm chart after cluster is up |
| Dev host | RHDP / AgnosticD runners | This **IBM Cloud** machine (KVM path) |

## Track A — AWS via AgnosticD

### Topology choices

1. **Two-Node with Arbiter (TNA)** — preferred minimal cloud footprint  
   - Two full control+compute primaries  
   - One small arbiter for etcd only (no general workloads)  
   - Maps cleanly to LINBIT diskless tiebreakers on the arbiter  

2. **Compact three-node** — three identical schedulable masters  
   - Standard etcd quorum  
   - Slightly higher cost; simpler mental model and Operator compatibility  

### Why TNA (not TNF) on AWS

TNF depends on out-of-band **Redfish** power control. AWS EC2 does not expose BMCs to the guest OS. Without fencing, a two-node partition risks split-brain. TNA restores Raft majority with a cheap third vote.

### Suggested AWS sizing (starting point)

| Role | Example instance | Notes |
|------|------------------|-------|
| TNA primary | `m5.4xlarge` (16 vCPU / 64 GiB) | Control plane + workloads + LINSTOR satellites |
| TNA arbiter | `t3.small` (or ≥ 2 vCPU / 8 GiB if required by platform docs) | etcd + optional diskless LINSTOR satellite; no EBS data pool |
| Compact node | `m5.2xlarge` minimum; `m5.4xlarge` recommended | Combined master/worker |

Attach unformatted secondary EBS volumes for LINSTOR storage pools. Prefer multi-AZ placement for diskful replicas and use LINSTOR AuxProps / `xReplicasOnDifferent` with `topology.kubernetes.io/zone` so replicas do not land in one AZ.

### Provisioning flow

```text
AgnosticD (AWS TNA or Compact, OCP 4.22+)
    → Field Content / ArgoCD
        → LINSTOR Operator + StorageClasses + Showroom
```

Document `ocp4_workload_field_content_gitops_repo_url` pointing at this repository once the Helm chart is scaffolded.

### Replication protocol notes (AWS)

| Protocol | Use when |
|----------|----------|
| Protocol C (sync) | Single-AZ or strict RPO 0 databases |
| Protocol A (async) | Multi-AZ stretched clusters where RTT (~1–2.5 ms) hurts sync DB throughput |

## Track B — TNF via openshift-agent-install (IBM Cloud KVM → bare metal)

### Topology

- `controlPlane.replicas: 2`  
- `compute.replicas: 0` (masters run workloads)  
- `fencing.credentials` for both nodes (BMC hostname, user, password; cert verification as appropriate)  

### Bootstrap tooling

Use [tosin2013/openshift-agent-install](https://github.com/tosin2013/openshift-agent-install):

| Path | Networking | BMC | ISO delivery |
|------|------------|-----|--------------|
| KVM development | VyOS + libvirt VLANs, dnsmasq | **sushy** Redfish emulator | `./hack/deploy-on-kvm.sh` |
| Bare metal production | Physical VLANs, corporate DNS | iDRAC / iLO / IPMI | `./hack/deploy-iso-baremetal.sh --method redfish\|ipmi` |

Common ABI flow: `create-iso` → deliver ISO → `openshift-install agent wait-for bootstrap/install-complete`.

Primary workflow in that project: **KVM development → fork & adapt → bare metal production**. This IBM Cloud host is the intended KVM validation environment.

### Storage on TNF

- Two diskful DRBD replicas on the two nodes  
- Hardware fencing replaces a third etcd/storage voter for control-plane HA  
- Keep LINBIT footprint small (controller/satellites ~700 MiB class) so edge RAM stays available for apps  

### Provisioning flow

```text
openshift-agent-install (ABI ISO on KVM or metal, OCP 4.22+)
    → kubeconfig
        → same Field Content Helm chart (LINSTOR + Showroom)
```

## Shared post-cluster content

Independent of track:

- Red Hat certified **LINSTOR Operator** from OperatorHub  
- StorageClasses for RWO locality, Virt block RWX, optional NFS RWX  
- Showroom modules for databases, OpenShift Virtualization migration, resilience drill, S3 snapshot shipping  

See [linbit-integration.md](linbit-integration.md) and [../workshop/module-outline.md](../workshop/module-outline.md).

## Decision guide

| If you have… | Choose |
|--------------|--------|
| AWS + AgnosticD / RHDP | Track A (TNA or Compact) |
| This IBM Cloud host + libvirt, or physical BMC servers | Track B (TNF via agent-install) |
| Need “true two-node edge story” for SSAs | Track B Module 3 (fencing demo) |
| Need cloud cost-efficient HA for catalog | Track A Module 3 (arbiter + tiebreaker drill) |
