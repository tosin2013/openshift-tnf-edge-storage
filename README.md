# openshift-tnf-edge-storage

Workshop and field-sourced content for high-performance persistent storage with **LINBIT SDS (LINSTOR + DRBD)** on **OpenShift 4.22+**, focused on edge and minimal-footprint topologies.

## Platform requirement

**OpenShift 4.22 and newer only.** Older 4.x minors are out of scope.

## Dual deployment tracks

| Track | Topology | Cluster bootstrap | Storage notes |
|-------|----------|-------------------|---------------|
| **A — AWS** | Two-Node with Arbiter (TNA) preferred, or Compact 3-node | **AgnosticD**, then Field Content GitOps | EBS pools + LINBIT diskless tiebreaker on arbiter |
| **B — KVM / bare metal** | Two-Node with Fencing (TNF) | **[openshift-agent-install](https://github.com/tosin2013/openshift-agent-install)** (Agent-Based Installer) | Local/virtio disks + Redfish STONITH (sushy on KVM, real BMC on metal) |

TNF is **not** supported on AWS EC2 (no tenant BMC/Redfish). Use Track A topologies in the cloud.

## Documentation (research phase)

| Document | Description |
|----------|-------------|
| [docs/architecture/deployment-tracks.md](docs/architecture/deployment-tracks.md) | AWS vs TNF track matrix and sizing |
| [docs/architecture/linbit-integration.md](docs/architecture/linbit-integration.md) | LINSTOR/DRBD integration patterns |
| [docs/workshop/module-outline.md](docs/workshop/module-outline.md) | Workshop module progression |
| [docs/research/openshift-agent-install.md](docs/research/openshift-agent-install.md) | Track B ABI / KVM research notes |
| [docs/research/open-questions.md](docs/research/open-questions.md) | Items to validate before Helm/Showroom scaffold |

## Next (not in this research pass)

- Scaffold from [field-sourced-content-template](https://github.com/rhpds/field-sourced-content-template) (Helm + Showroom)
- AgnosticD config for Track A on OCP 4.22+
- agent-install examples for TNF on this IBM Cloud KVM host

## License / status

Work in progress — research and bootstrap only.
