# openshift-tnf-edge-storage

Showroom-based hands-on workshop for high-performance persistent storage with **LINBIT SDS (LINSTOR + DRBD)** on **OpenShift 4.22+**, focused on edge and minimal-footprint topologies.

This project is licensed under the [Apache License 2.0](LICENSE).

## Platform requirement

**OpenShift 4.22 and newer only.** Older 4.x minors are out of scope.

## How it works

This repository is a **field-sourced-content** Helm chart deployed by ArgoCD onto an already-provisioned OpenShift cluster. The chart installs everything students need: LINSTOR Operator, StorageClasses, sample workloads, and Showroom lab guides.

**Default (AWS via AgnosticD):** Order from the RHDP catalog. AgnosticD provisions a TNA or Compact cluster on AWS, then deploys this chart via `ocp4_workload_field_content`. Students open Showroom and start the lab.

**Optional advanced (KVM / bare metal TNF):** Bring up OCP 4.22+ TNF on KVM or bare metal using [openshift-agent-install](https://github.com/tosin2013/openshift-agent-install), then apply this chart with `values-tnf.yaml`. Same Showroom modules, different cluster topology.

## Deployment tracks

| Track | Topology | Cluster bootstrap | Storage | Status |
|-------|----------|-------------------|---------|--------|
| **AWS (default)** | TNA (2 primary + arbiter) or Compact 3-node | AgnosticD + Field Content GitOps | EBS pools + LINBIT diskless tiebreaker | Default RHDP catalog path |
| **KVM / bare metal (optional)** | TNF (2 nodes + Redfish STONITH) | [openshift-agent-install](https://github.com/tosin2013/openshift-agent-install) ABI | Local/virtio disks + fencing | Advanced; documented but not primary |

TNF is **not** supported on AWS EC2 (no tenant BMC/Redfish).

Legacy 6-node AWS IPI is fallback only: `STUDENT_DEPLOY_METHOD=ipi make deploy`.

## Student instance profiles (AWS)

| Profile | CP Instance | vCPUs/student | Cost/student/day | `/dev/kvm` | Module 3 |
|---------|-------------|---------------|------------------|------------|----------|
| **standard** (default) | `m7a.4xlarge` | 36 | ~$52 | No — QEMU emulation | Skipped (too slow) |
| **virt-enabled** | `m5zn.metal` | 100 | ~$190 | Yes — hardware KVM | Full live migration |

Set the profile in `agnosticd/config.yml` (via `make setup`) or at deploy time:

```bash
STUDENT_INSTANCE_PROFILE=virt-enabled make deploy
```

The profile controls:
- **CP instance type** — `m7a.4xlarge` vs `m5zn.metal`
- **Nested KVM emulation** — `enabled_nested_kvm: true` (standard, QEMU fallback) vs `false` (virt-enabled, native)
- **Quota requirements** — virt-enabled needs ~100 vCPUs/student vs 36 for standard

Both profiles deploy the same LINSTOR + OpenShift Virtualization stack. The only difference is whether live migration runs at hardware speed (seconds) or emulated speed (minutes, impractical for labs).

## Workshop modules (Showroom)

| Module | Topic | Duration |
|--------|-------|----------|
| 1 | Storage Foundations -- LINSTOR/DRBD architecture, storage pools, diskful vs diskless | 30 min |
| 2 | Database Locality -- `WaitForFirstConsumer`, pgbench, local-read performance | 45 min |
| 3 | VM Live Migration -- block RWX, `allow-two-primaries`, zero-downtime migration | 45 min |
| 4 | Resilience Drill -- node failure, DRBD quorum, arbiter/tiebreaker (or TNF fencing) | 30 min |
| 5 | Disaster Recovery -- S3 snapshot shipping, incremental block deltas | 45 min |

See [docs/workshop/module-outline.md](docs/workshop/module-outline.md) for full details including Helm components, RHDP data flow, and hands-on steps.

## Documentation

| Document | Description |
|----------|-------------|
| [docs/workshop/module-outline.md](docs/workshop/module-outline.md) | Workshop structure, Helm components, Showroom modules, RHDP integration |
| [docs/architecture/deployment-tracks.md](docs/architecture/deployment-tracks.md) | AWS vs TNF track matrix and sizing |
| [docs/architecture/linbit-integration.md](docs/architecture/linbit-integration.md) | LINSTOR/DRBD integration patterns |
| [docs/setup/linbit-registry-credentials.md](docs/setup/linbit-registry-credentials.md) | How to get my.linbit.com credentials for the `drbd.io` pull secret |
| [docs/research/openshift-agent-install.md](docs/research/openshift-agent-install.md) | Track B agent-install research notes |
| [docs/architecture/ec2-volume-swap.md](docs/architecture/ec2-volume-swap.md) | Two-phase EBS volume swap: why and how (novel approach) |
| [ansible/DEVELOPER-GUIDE.md](ansible/DEVELOPER-GUIDE.md) | TNA student cluster Ansible role: phases, debugging, prerequisites |
| [docs/research/open-questions.md](docs/research/open-questions.md) | Items to validate before Helm/Showroom scaffold |

## Quick start (AWS TNA)

### Prerequisites

- AWS credentials, Route53-managed domain, `openshift-install` 4.22+, `oc`, `aws` CLI
- Sufficient quotas: run `make check-quota` (standard profile needs ~102 vCPUs for hub + 1 student)
- See [Developer Guide](ansible/DEVELOPER-GUIDE.md) for full prerequisites

### Deploy hub + students (catalog-shaped)

```bash
make setup          # interactive onboarding wizard
make check-quota    # verify AWS quotas
make deploy         # hub + N students (default: standard profile)
```

### Deploy single student (development)

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

### Lifecycle

```bash
make status         # cluster health
make credentials    # API URLs, kubeconfigs, passwords
make stop           # hibernate (saves AWS costs)
make start          # resume from hibernate
make teardown       # destroy everything
make dry-run        # preview teardown (no deletes)
```

## Status

**v1.0.0 — Stable.** AWS TNA workshop with dual instance profiles, multi-student deployment, and full lifecycle management. See [Release v1.0.0](https://github.com/tosin2013/openshift-tnf-edge-storage/releases/tag/v1.0.0).

| Track | Status |
|-------|--------|
| AWS standard (`m7a.4xlarge`) | **Stable** — Modules 1-2, 4-5. Module 3 skipped (no KVM). |
| AWS virt-enabled (`m5zn.metal`) | **Stable** — All 5 modules including live migration (2s). |
| KVM / bare-metal TNF | Documented, not yet implemented. See [TNF-ready milestone](https://github.com/tosin2013/openshift-tnf-edge-storage/milestone/5). |

The agent-based install uses a novel two-phase EBS volume swap to work around EC2's fixed boot order. See [EC2 Volume Swap Architecture](docs/architecture/ec2-volume-swap.md) for the full technical explanation.
