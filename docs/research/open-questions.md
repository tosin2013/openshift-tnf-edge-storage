# Open Questions (pre–Field Content scaffold)

Resolve these before implementing Helm/Showroom YAML.

## AgnosticD / Track A (AWS)

| # | Question | Why it matters | Suggested next step |
|---|----------|----------------|---------------------|
| A1 | Which AgnosticD config or RHDP catalog item provisions **OCP 4.22+** TNA or Compact on AWS? | Locked provisioner for Track A | Search AgnosticD configs / RHDP catalog; document GUID + variables |
| A2 | Does that config expose hooks for secondary EBS + `ocp4_workload_field_content`? | Field Content GitOps wiring | Confirm vars: `ocp4_workload_field_content_gitops_repo_url`, namespace |
| A3 | Minimum instance sizes enforced by AgnosticD for 4.22 TNA (primary vs arbiter)? | Cost and lab reliability | Align with sizing in deployment-tracks.md |
| A4 | Is OpenShift Virtualization included or a separate workload? | Module 2 prerequisites | Add Virt workload or document manual enablement |

## agent-install / Track B (IBM Cloud KVM)

| # | Question | Why it matters | Suggested next step |
|---|----------|----------------|---------------------|
| B1 | Does agent-install successfully generate/deploy **4.22** agent ISOs today? | Workshop version floor | Run `create-iso` against 4.22 release on this host |
| B2 | Is there an existing **2-node TNF + fencing** example, or only SNO/compact/HA? | Module 0/3 Track B | Audit `examples/`; prototype `tnf-4.22-kvm` config |
| B3 | Does sushy Redfish satisfy OpenShift **TNF fencing.credentials** format? | Module 3 fencing lab | Cross-check OCP TNF docs vs sushy URLs/auth |
| B4 | Does this IBM Cloud VM have enough CPU/RAM/disk for VyOS + 2 (or 3) OCP nodes? | Feasibility | Inventory host; set lab VM sizes |
| B5 | Should TNF examples live in this repo or upstream agent-install? | Maintenance | Prefer docs + thin example here; PR upstream if reusable |

## LINBIT Operator

| # | Question | Why it matters | Suggested next step |
|---|----------|----------------|---------------------|
| L1 | Which OperatorHub channel / LINBIT Operator version is certified on **OCP 4.22+**? | Freeze Subscription YAML | Check OperatorHub / LINBIT release notes |
| L2 | NFS RWX (Ganesha) vs Virt block RWX — both in MVP or Virt-only first? | Scope Modules 2 vs optional | Recommend Virt in MVP; NFS optional |
| L3 | Volume group snapshots support matrix on target Operator + 4.22 | Module 4 depth | Confirm CSI `VolumeGroupSnapshot` support |

## Field Content / RHDP

| # | Question | Why it matters | Suggested next step |
|---|----------|----------------|---------------------|
| F1 | Helm-only Field Content CI vs custom AgnosticD role changes? | Scaffold shape | Start from field-sourced-content-template Helm |
| F2 | One catalog item with track parameter vs two catalog items? | RHDP UX | Prefer two entries (AWS vs TNF) sharing one Git repo + value overlays |
| F3 | Showroom antora attributes from AgnosticD userinfo for both tracks? | Student login URLs | Define ConfigMap keys early |

## Product / messaging

| # | Question | Why it matters | Suggested next step |
|---|----------|----------------|---------------------|
| P1 | Confirm public positioning of TNF GA and TNA tooling names for 4.22 | Avoid outdated lab text | Review OCP 4.22 release notes before AsciiDoc |
| P2 | LINBIT licensing / evaluation keys for RHDP labs? | Legal/ops | Confirm with LINBIT/Red Hat workshop owners |

## Exit criteria to start Phase 2 scaffold

- [ ] A1 answered with a concrete AgnosticD/RHDP path for 4.22+  
- [ ] B1 proven or fallback compact ABI documented  
- [ ] L1 Operator channel chosen  
- [ ] F1/F2 decided (Helm overlays + catalog shape)  

Until then: keep publishing architecture/workshop research only (this phase).
