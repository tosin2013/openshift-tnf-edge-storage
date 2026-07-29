## Persistent storage options for a minimal-footprint OpenShift cluster on AWS

Not every Red Hat OpenShift deployment needs a full rack of servers. Edge sites, remote offices, and cost-conscious labs all demand clusters with the smallest viable footprint that still deliver real persistent storage. I recently deployed a Two-Node with Arbiter (TNA) cluster on AWS using the agent-based installer, and I faced a question that comes up in every minimal deployment: which storage backend actually fits a cluster this small?

## What a two-node with arbiter cluster looks like

A TNA cluster runs on just three nodes. Two control-plane nodes handle both the OpenShift control plane and application workloads. A lightweight arbiter node serves as a tiebreaker for quorum.

| Node | vCPU | RAM | Root disk | Storage disk | Role |
|------|------|-----|-----------|--------------|------|
| cp-0 | 16 | 64 GB | 200 GB | 50 GB | Control plane + workloads |
| cp-1 | 16 | 64 GB | 200 GB | 50 GB | Control plane + workloads |
| arbiter-0 | 4 | 16 GB | 120 GB | None | Quorum tiebreaker (diskless) |

The Scheduler is patched with mastersSchedulable set to true so pods land on the control-plane nodes. The arbiter carries a NoSchedule taint to keep application workloads off its modest 4 vCPU, 16 GB footprint.

Total resource budget: 36 vCPU and 144 GB of RAM across three instances. Compare that to a standard 3 control-plane plus 3 worker topology or even a compact 3-node cluster where every node needs full compute capacity. The TNA layout keeps cost low while maintaining high-availability quorum.

## Why the arbiter matters for storage

The arbiter is a diskless quorum voter. It does not store data, but it does participate in consensus decisions that prevent split-brain failures.

When one of the two control-plane nodes goes down, the surviving node and the arbiter still form a majority. Storage systems that understand this pattern can keep volumes accessible on the surviving node without risking data corruption. Without the arbiter, a two-node cluster has no way to determine which node should continue serving data after a network partition.

The result is two-replica storage with quorum safety, the sweet spot for minimal deployments.

## Storage options for a TNA cluster

I evaluated five storage backends. Each has real strengths, and each has trade-offs you should understand before committing.

### LINSTOR with Distributed Replicated Block Device (DRBD)

LINSTOR pairs an orchestration control plane with DRBD 9, an in-kernel block replication layer. On a TNA cluster, the two control-plane nodes run diskful replicas with synchronous replication (Protocol C, which means zero data loss on failover). The arbiter runs a diskless tiebreaker satellite that votes in quorum decisions without storing data.

The resource footprint is small, roughly 700 MiB for the controller and satellites combined, with about 32 MiB of RAM per TiB of replicated data. Reads happen locally from the node where the pod runs, which keeps latency low.

The trade-off: LINSTOR requires commercial credentials from LINBIT. The operator is Red Hat certified on OperatorHub, but you need a my.linbit.com account to pull images from the drbd.io registry. If your organization does not have a LINBIT entitlement, this option is off the table.

### OpenShift Data Foundation (ODF)

ODF is the native Red Hat storage platform, built on Ceph and Rook. It provides block, file, and object storage through a single operator. If you already have ODF entitlement, you get full Red Hat support and tight integration with OpenShift features like monitoring and upgrades.

The trade-off: ODF was designed for larger clusters. Running Ceph Object Storage Daemons (OSDs) on a 2+1 topology is a tight fit. The memory and CPU overhead is meaningful on nodes that are already running both the control plane and application workloads. ODF works best when resource headroom is not a concern.

### AWS Elastic Block Store (EBS) Container Storage Interface (CSI) driver

The EBS CSI driver is the simplest option. There is nothing to install beyond the driver itself, and AWS manages the underlying block storage. No replication layer runs inside the cluster.

The trade-off: EBS volumes attach to a single node. If that node fails, the volume is unavailable until the node recovers. There is no cross-node replication. This works for development environments or stateless workloads, but it leaves you exposed to single-node failure for anything stateful.

### Longhorn

Longhorn is a Cloud Native Computing Foundation (CNCF) graduated project that provides lightweight, user-space block replication across nodes with a moderate resource footprint.

The trade-off: Longhorn has less mature support on OpenShift compared to Kubernetes distributions where it originated. If your team already runs Longhorn and understands its operational model, it works on a TNA cluster. Starting fresh on OpenShift means more integration effort.

### Portworx

Portworx (Pure Storage) delivers an enterprise feature set including encryption, backup, and migration built into the storage layer.

The trade-off: Portworx is a heavier platform that may be overkill for a 2+1 cluster. If your organization has already standardized on Portworx, extending it to a TNA deployment makes sense. Adopting it specifically for a minimal cluster is harder to justify.

## Decision matrix

| Criteria | LINSTOR + DRBD | ODF | EBS CSI | Longhorn | Portworx |
|----------|---------------|-----|---------|----------|----------|
| Cross-node replication | Yes (in-kernel) | Yes (Ceph) | No | Yes (user-space) | Yes |
| Min nodes for storage | 2 + arbiter | 3 (tight on 2+1) | 1 | 2 | 3 |
| Object storage | No | Yes | No | No | Yes |
| Resource overhead | Low | High | Minimal | Moderate | High |
| Red Hat support included | No (LINBIT) | Yes | Partial | No | No (Pure Storage) |
| TNA fit | Strong | Tight | Dev/test | Good | Heavy |

Here is my practical guidance based on deploying this topology:

- If you have ODF entitlement and need object storage, use ODF and budget extra resources on the control-plane nodes.
- If you want the smallest replication footprint, evaluate LINSTOR (if you have LINBIT credentials) or Longhorn.
- If your workloads are stateless or you accept single-node risk, the EBS CSI driver keeps things simple.
- If your organization has already standardized on Portworx, it works on TNA, but watch the resource budget on a 2+1 cluster.

## How the automation stays storage-agnostic

The deployment automation for this TNA cluster is modular by design. Phases 0 through 6 build a fully functional TNA OpenShift cluster with no storage operator installed. LINSTOR installation happens in Phase 7, and Phase 7 automatically skips when LINBIT registry credentials are not provided.

The arbiter node labels and NoSchedule taint are applied in Phase 6 regardless of storage backend. This means any storage system that recognizes the arbiter role can use those labels for placement decisions. You get a clean cluster ready for whatever Container Storage Interface (CSI) driver you choose to install.

## Choosing the right storage for your minimal cluster

A minimal footprint does not mean minimal storage options. The TNA arbiter topology gives you quorum safety with just three nodes, and every storage backend I evaluated can run on this layout, with different trade-offs in resource overhead, replication guarantees, and commercial requirements. The right choice depends on your entitlements, your team's operational expertise, and whether your workloads need cross-node replication or can tolerate single-node risk.

Explore the [TNA deployment automation on GitHub](https://github.com/tosin2013/openshift-tnf-edge-storage) to see the full phase architecture, including the [EC2 volume swap pattern](https://github.com/tosin2013/openshift-tnf-edge-storage/blob/main/docs/architecture/ec2-volume-swap.md) that makes agent-based installs work on AWS. For more on Red Hat's native storage offering, see the [OpenShift Data Foundation documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation). To learn about TNA and Two-Node with Fence (TNF) topologies, visit the [OpenShift edge documentation](https://docs.openshift.com/container-platform/latest/edge_computing/overview-edge.html).
