# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-08-20

Stable release: AWS TNA workshop with dual instance profiles (standard + virt-enabled),
multi-student deployment, and full lifecycle management.

### Features

- **Dual instance profiles**: `standard` (m7a.4xlarge, ~$52/day) and `virt-enabled` (m5zn.metal, ~$190/day) with hardware KVM for live migration
- Multi-student deployment (`NUM_STUDENTS=N`) with per-cluster AMI caching
- Lifecycle commands: `make stop/start/status/teardown` with hub-vs-student granularity
- Race-condition-free start/stop (waits for EC2 state transitions before proceeding)
- Phase 6b LVM prep: auto-discovers correct NVMe device on metal instances
- Per-cluster AMI tagging prevents cross-contamination between student clusters
- Quota preflight (`make check-quota`) supports both profile vCPU calculations

### Fixes

- AMI cache shared across clusters causing wrong cluster name in ignition (added `cluster-name` tag)
- NVMe device naming inconsistency on m5zn.metal (added `phase6b_lvm_prep.yml` device discovery)
- `start.sh` race condition: instances still in "stopping" state when start attempted (added `aws ec2 wait instance-stopped`)
- Fixed 120s sleep replaced with `aws ec2 wait instance-running` + 60s stabilization

### Documentation

- README: instance profiles section with cost/KVM/Module 3 matrix
- README: updated Quick Start with full lifecycle commands
- `onboard.yml`: `student_instance_profile` choice with cost explanation
- Developer Guide: Phase 6b LVM prep documented

### Breaking Changes

- None (backwards-compatible with v0.9.0 standard-profile deployments)

## [0.9.0] - 2026-08-19

First release: AWS standard-profile TNA workshop (2 CP + 1 arbiter, agent-based
installer, Helm-managed LINBIT SDS via ArgoCD).

### Features

- AgnosticD hub-student deployment (`make deploy` / `make teardown`)
- TNA student cluster Ansible role with agent-based OpenShift 4.22 installer
- Two-phase EC2 volume swap for RHCOS boot device promotion
- Helm App-of-Apps: LINSTOR operator, StorageClasses, sample-database, sample-vm, userinfo
- OpenShift GitOps (ArgoCD) and OpenShift Virtualization (CNV/HCO) integration
- Per-student Showroom with terminal on the hub cluster
- Field-sourced-content workload for RHDP catalog readiness
- Bootstrap wizard (`make setup` / `bootstrap.sh`) with quota checks
- Blog series documenting agent-based TNA deploy lessons learned

### Fixes

- Prevent NLB ENI from stealing static node IPs (CFN DependsOn)
- Remove api-int from CFN ownership; add pre-create DNS cleanup and teardown parity
- Grant ArgoCD cluster-admin; tolerate arbiter node taint
- Disable CNV common boot image imports (prevents filling LINSTOR pools)
- Valid LINSTOR `auto-quorum` values on StorageClasses (`io-error` not `majority`)
- Wait for HyperConverged CRD before applying HCO CR
- Module 4 satellite-delete instead of drain on compact control-plane nodes
- Treat Halted sample-vm as healthy in Field Content ArgoCD wait
- Complete IPI teardown sweep (ELBs, VPC endpoints, SG cross-refs)
- Align Showroom Antora attributes with AgnosticD user_data keys

### Workshop Content

- Module 1: Cluster exploration and LINBIT SDS verification
- Module 2: Stateful PostgreSQL workload with DRBD-replicated storage
- Module 3: Live VM migration with OpenShift Virtualization (skip on standard)
- Module 4: Simulated node failure and DRBD quorum recovery
- Module 5: Disaster recovery with LINSTOR snapshots and pgbench validation

### Known Limitations

- Module 3 (live migration) requires `virt-enabled` profile (`m5zn.metal`) — skipped on standard
- Single-student (`num_students: 1`) validated; N=2 parallel is post-0.9.0
- TNF/KVM bare-metal track not yet implemented (v1.0.0 scope)

[0.9.0]: https://github.com/tosin2013/openshift-tnf-edge-storage/releases/tag/v0.9.0
[1.0.0]: https://github.com/tosin2013/openshift-tnf-edge-storage/releases/tag/v1.0.0
