# Changelog

All notable changes to this project will be documented in this file.

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
