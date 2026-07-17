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
| [docs/research/open-questions.md](docs/research/open-questions.md) | Items to validate before Helm/Showroom scaffold |

## Status

Research and architecture phase. Next steps:

- Scaffold Helm chart from [field-sourced-content-template](https://github.com/rhpds/field-sourced-content-template)
- Write Showroom AsciiDoc modules
- Identify AgnosticD config for OCP 4.22+ TNA/Compact on AWS
- Confirm LINBIT Operator channel for 4.22+
