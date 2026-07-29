# openshift-tnf-edge-storage

Showroom-based hands-on workshop for high-performance persistent storage with **LINBIT SDS (LINSTOR + DRBD)** on **OpenShift 4.22+**, focused on edge and minimal-footprint topologies.

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
- See [Developer Guide](ansible/DEVELOPER-GUIDE.md) for full prerequisites

### Deploy with LINSTOR

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

### Deploy without LINSTOR (bare TNA cluster)

Omit LINBIT credentials from your secrets file — Phase 7 auto-skips.

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

### Teardown

```bash
make teardown-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

## Status

**Automated TNA deploy on AWS EC2 is repeatable.** Two consecutive clean end-to-end deploys verified (July 2026) — zero manual intervention, all 8 phases pass (161 ok / 0 failed).

The agent-based install uses a novel two-phase EBS volume swap to work around EC2's fixed boot order. See [EC2 Volume Swap Architecture](docs/architecture/ec2-volume-swap.md) for the full technical explanation.
