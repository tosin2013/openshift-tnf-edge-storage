# Open Questions (pre–Field Content scaffold)

Resolve these before implementing Helm/Showroom YAML.

## AgnosticD / Track A (AWS)

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| A1 | Which AgnosticD config or RHDP catalog item provisions **OCP 4.22+** TNA or Compact on AWS? | Locked provisioner for Track A | **RESOLVED** |
| A2 | Does that config expose hooks for secondary EBS + `ocp4_workload_field_content`? | Field Content GitOps wiring | **RESOLVED** |
| A3 | Minimum instance sizes enforced by AgnosticD for 4.22 TNA (primary vs arbiter)? | Cost and lab reliability | **RESOLVED** |
| A4 | Is OpenShift Virtualization included or a separate workload? | Module 2 prerequisites | **RESOLVED** (gap identified) |

### A1 — RESOLVED (2026-07-27)

AgnosticD config is `openshift-cluster` from AgnosticD v2 (`tosin2013/agnosticd-v2`). The hub cluster always uses IPI via this config. Student clusters default to the **agent-based TNA method** (bypassing AgnosticD for provisioning), with IPI as a fallback. The `ocp4_workload_field_content` variable is already wired in the IPI path (`ocp4_workload_field_content_gitops_repo_url` points to this repo, path `helm`).

### A2 — RESOLVED (2026-07-27)

Yes, both hooks exist in the IPI fallback path (`agnosticd/vars/student/linbit-student.yaml`):
- `ocp4_workload_field_content` is in the workloads array with `gitops_repo_url` and `helm_values` configured
- Secondary EBS is configured via `student_cp_data_volume_size: 100`

However, these only apply when `STUDENT_DEPLOY_METHOD=ipi`. The default agent-based path handles both via CloudFormation (EBS) and Phase 7 (LINSTOR), bypassing AgnosticD's workload system entirely.

### A3 — RESOLVED (2026-07-27)

Instance types are consistent across code and docs:
- **CP nodes (x2):** `m7a.4xlarge` (16 vCPU, 64 GiB RAM)
- **Arbiter (x1):** `m7a.xlarge` (4 vCPU, 16 GiB RAM)
- Per-student cost: ~$2.16/hr / ~$52/day (per `deployment-tracks.md`)

Note: Minor EBS volume size discrepancy between `defaults/main.yml` (200 GB root, 50 GB LINSTOR, 120 GB arbiter) and `linbit-student.yaml` (100 GB root, 50 GB arbiter). The Ansible role defaults are authoritative for the agent-based path.

### A4 — RESOLVED (2026-07-27, gap identified)

OpenShift Virtualization IS included as a workload, but only in the **IPI path** (`ocp4_workload_openshift_virtualization` in `linbit-student.yaml`). The agent-based TNA path does NOT install it in any phase. However, the Helm chart's `sampleVm` component (`sampleVm.enabled: true`) expects it to exist.

**Gap:** If using agent-based TNA, OpenShift Virtualization needs to be installed separately (e.g., a new Ansible phase or manual enablement).

---

## agent-install / Track B (IBM Cloud KVM)

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| B1 | Does agent-install successfully generate/deploy **4.22** agent ISOs today? | Workshop version floor | **RESOLVED** |
| B2 | Is there an existing **2-node TNF + fencing** example, or only SNO/compact/HA? | Module 0/3 Track B | **RESOLVED** |
| B3 | Does sushy Redfish satisfy OpenShift **TNF fencing.credentials** format? | Module 3 fencing lab | **RESOLVED** |
| B4 | Does this IBM Cloud VM have enough CPU/RAM/disk for VyOS + 2 (or 3) OCP nodes? | Feasibility | **RESOLVED** |
| B5 | Should TNF examples live in this repo or upstream agent-install? | Maintenance | **RESOLVED** |

### B1 — RESOLVED (2026-07-27)

Yes. The codebase is fully wired for `openshift-install agent create image` with OCP 4.22. The version is set in `defaults/main.yml` (`tna_ocp_version: "4.22"`), `deploy-tna.sh`, and `linbit-student.yaml`. Phases 1-4 of the Ansible role have completed successfully with 4.22 ISOs on the current host.

### B2 — RESOLVED (2026-07-27)

No first-class 2-node TNF + fencing example exists in `tosin2013/openshift-agent-install` or `openshift-eng/two-node-toolbox` for the agent-based installer. The upstream repos cover SNO, 3-node compact, and HA only. However, the official OKD/OCP documentation provides template `install-config.yaml` and `agent-config.yaml` for TNF via agent-based installer, including the exact `fencing.credentials` schema. This is sufficient to prototype an `examples/tnf-4.22-kvm/` config as described in `docs/research/openshift-agent-install.md`.

### B3 — RESOLVED (2026-07-27)

Yes. The TNF `fencing.credentials` format expects `redfish+https://<bmc_ip>:<port>/redfish/v1/Systems/<system_id>` with username/password. Sushy-tools exposes endpoints at `http(s)://<host>:<port>/redfish/v1/Systems/<uuid>` which maps directly to the `redfish+https://` scheme. For KVM, the system ID is the libvirt VM UUID. Use `certificateVerification: Disabled` for sushy's self-signed certs. The key validation step is confirming Pacemaker's `fence_redfish` agent can power-cycle libvirt VMs through sushy at runtime.

### B4 — RESOLVED (2026-07-27)

Yes, comfortably for 2-node TNF. Host resources: 48 vCPU (24 cores, Intel Cascadelake), 188 GiB RAM (163 GiB free), 133 GiB disk free.

| Scenario | vCPU needed | RAM needed | Disk needed | Feasible? |
|----------|-------------|------------|-------------|-----------|
| 2-node TNF + VyOS | ~18-20 | ~36-40 GiB | ~140-200 GiB | Yes (use thin qcow2) |
| 3-node compact + VyOS | ~26-28 | ~52-56 GiB | ~200+ GiB | Tight on disk; needs thin provisioning or extra block volume |

**Constraint:** Disk is the bottleneck. Use thin-provisioned qcow2 images and consider adding a secondary block device for 3-node scenarios.

### B5 — RESOLVED (2026-07-27)

Already decided: thin examples here, PR upstream if reusable. Per `openshift-agent-install.md`: do not vendor the entire agent-install tree. Document the workflow (clone agent-install, generate/deploy, point Field Content at this repo) and keep a thin `examples/tnf-4.22-kvm/` directory with just `cluster.yml`, `nodes.yml`, and `install-config.yaml`.

---

## LINBIT Operator

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| L1 | Which OperatorHub channel / LINBIT Operator version is certified on **OCP 4.22+**? | Freeze Subscription YAML | **RESOLVED** |
| L2 | NFS RWX (Ganesha) vs Virt block RWX — both in MVP or Virt-only first? | Scope Modules 2 vs optional | **RESOLVED** |
| L3 | Volume group snapshots support matrix on target Operator + 4.22 | Module 4 depth | **RESOLVED** |

### L1 — RESOLVED (2026-07-27)

Channel is `stable-v2` from the `certified-operators` catalog in `openshift-marketplace`. Confirmed in four independent locations: `subscription.yml`, `defaults/main.yml` (`tna_linstor_operator_channel: stable-v2`), `deploy-tna.sh`, and `helm/values.yaml`.

### L2 — RESOLVED (2026-07-27)

**Virt block RWX only in MVP.** NFS/Ganesha RWX is not implemented anywhere in the codebase. The module outline explicitly lists NFS RWX under "Advanced / optional content (not in core lab)." The two StorageClasses in MVP are:
- `linbit-rwo-locality` — standard RWO with WaitForFirstConsumer (default)
- `linbit-rwx-virt` — block-level RWX using `allow-two-primaries: "yes"` for VM live migration

LINSTOR Operator v2.10.0+ does support NFS/Ganesha natively, but it adds complexity and has lower performance than block RWX. Can be added as optional Module 6 later.

### L3 — RESOLVED (2026-07-27)

Supported by LINSTOR Operator v2.10.0+, but requires manual feature gate enablement on OpenShift 4.22. The `CSIVolumeGroupSnapshot` feature gate is Beta in Kubernetes 1.35 (OCP 4.22) and disabled by default. Enabling it requires `FeatureGate` CRs or TechPreviewNoUpgrade feature sets, which carries support implications.

**Recommendation for workshop:** Keep VolumeGroupSnapshot out of the core lab. Module 5 (DR) uses individual VolumeSnapshot, which is fully GA. Mention VolumeGroupSnapshot as a "coming in OCP 4.23+" note where the feature goes GA.

---

## Field Content / RHDP

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| F1 | ~~Helm-only Field Content CI vs custom AgnosticD role changes?~~ | | **RESOLVED** |
| F2 | ~~One catalog item with track parameter vs two catalog items?~~ | | **RESOLVED** |
| F3 | Showroom antora attributes from AgnosticD userinfo for both tracks? | Student login URLs | **PARTIALLY RESOLVED** |

### F1 — RESOLVED (previously)

Helm-only from field-sourced-content-template. Chart deploys LINSTOR Operator, StorageClasses, sample workloads, Showroom. AgnosticD wires it via `ocp4_workload_field_content`. See module-outline.md.

### F2 — RESOLVED (previously)

Single RHDP catalog item "LINBIT Edge Storage Workshop" with AWS TNA/Compact as default. KVM/TNF is an optional advanced path using the same Helm chart with `values-tnf.yaml` overlay. See module-outline.md.

### F3 — PARTIALLY RESOLVED (2026-07-27)

Showroom is deployed on the hub cluster via `ocp4_workload_showroom`. The `deployment_info.txt` from Phase 8 captures the raw values: `api_url`, `console_url`, `kubeconfig`, instance IDs, etc. The Helm `values.yaml` has a `deployer` section with empty `domain` and `apiUrl` fields and a `userinfo` component.

**Gap:** The pipeline to inject these values as Antora attributes is not yet implemented. The `site.yml` has no `asciidoc.attributes` section. The ConfigMap keys (`cluster_domain`, `api_url`, `admin_password`, `showroom_url`, `sample_db_connection`) are not defined anywhere. This needs implementation when Showroom content is authored.

---

## Product / messaging

| # | Question | Why it matters | Status |
|---|----------|----------------|--------|
| P1 | Confirm public positioning of TNF GA and TNA tooling names for 4.22 | Avoid outdated lab text | **RESOLVED** |
| P2 | LINBIT licensing / evaluation keys for RHDP labs? | Legal/ops | **RESOLVED** (action needed) |

### P1 — RESOLVED (2026-07-27)

Both names are official Red Hat terminology:
- **TNA = "Two-Node with Arbiter"** — GA since OpenShift 4.20. Uses a lightweight third arbiter node for etcd consensus.
- **TNF = "Two-Node with Fencing"** — **GA in OpenShift 4.22** (was Technology Preview in 4.20). Uses BMC/Redfish fencing via Pacemaker; no third node.

LINBIT CEO Philipp Reisner confirmed the partnership: "Red Hat released OpenShift 4.22, making the Two-Node OpenShift with Fencing (TNF) feature generally available." Use "Two-Node with Arbiter (TNA)" and "Two-Node with Fencing (TNF)" as canonical terms in all lab content.

### P2 — RESOLVED (2026-07-27, action needed)

LINBIT requires a sales engagement for evaluation credentials — no self-service trial. The `drbd.io` container registry requires Customer Portal credentials. The current Helm values reference a `drbdiocred` secret with empty username/password, injected at deploy time via AgnosticD secrets.

**Action needed:** Contact LINBIT sales (`sales@linbit.com`) to negotiate evaluation/partner credentials for RHDP lab use. Reference the existing Red Hat ISV partnership and LINBIT's co-marketing of OCP 4.22 TNF support.

---

## Exit criteria to start Phase 2 scaffold

- [x] A1 answered: AgnosticD `openshift-cluster` v2 config; agent-based TNA as default, IPI as fallback
- [x] B1 proven: agent-install 4.22 ISO generation and deployment confirmed via Ansible role
- [x] L1 Operator channel chosen: `stable-v2` from `certified-operators`
- [x] F1 decided: Helm-only from field-sourced-content-template
- [x] F2 decided: single catalog item, AWS default, KVM/TNF optional via `values-tnf.yaml`

**All exit criteria met.** Phase 2 scaffold can proceed.
