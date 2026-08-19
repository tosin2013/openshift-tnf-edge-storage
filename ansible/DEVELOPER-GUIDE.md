# TNA Student Cluster Ansible Role — Developer Guide

## Overview

This Ansible role deploys a **Two-Node with Arbiter (TNA)** OpenShift 4.22+ cluster on AWS using the **agent-based installer**, then optionally installs **LINBIT SDS (LINSTOR/DRBD)** for replicated storage.

The agent-based installer is officially supported on bare-metal and VMware. Running it on AWS EC2 requires a two-phase EBS volume swap to work around EC2's fixed boot order. See [EC2 Volume Swap Architecture](../docs/architecture/ec2-volume-swap.md) for the full technical explanation.

**Cluster topology:**

| Node | Instance Type | EBS Volumes | Role |
|------|--------------|-------------|------|
| cp-0 (rendezvous) | m7a.4xlarge (16 vCPU, 64 GB) | 200 GB root + 50 GB LINSTOR | Control plane + DRBD primary |
| cp-1 | m7a.4xlarge | 200 GB root + 50 GB LINSTOR | Control plane + DRBD primary |
| arbiter-0 | m7a.xlarge (4 vCPU, 16 GB) | 120 GB root | Arbiter / tiebreaker (diskless) |

The deployment runs entirely from `localhost` (no remote inventory). All AWS interaction uses the `amazon.aws` collection modules or SSH to the rendezvous host.

**Deployment status:** Repeatable end-to-end deploy verified — two consecutive clean runs (E8, E9), 161 ok / 0 failed, zero manual intervention (July 2026).

---

## Prerequisites

### AWS

- Credentials exported as `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (or configured in `~/.aws/credentials`)
- A Route53-managed base domain (e.g. `sandbox3493.opentlc.com`)
- Sufficient quota in `us-east-2` for: 3 EC2 instances (2x m7a.4xlarge + 1x m7a.xlarge), 1 NLB, 5 EBS volumes, 1 VPC

### Local files

| File | Description |
|------|-------------|
| `~/pull-secret.json` | Red Hat pull secret from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret) |
| `~/.ssh/id_ed25519` + `.pub` | SSH keypair (injected into CoreOS via install-config) |
| `~/Development/agnosticd-v2-secrets/secrets.yml` | LINBIT registry credentials (`linbit_registry_username` / `linbit_registry_password`). Without these, LINSTOR install (Phase 7) is skipped — you get a bare TNA cluster. |

### CLI tools on PATH

- `openshift-install` 4.22+ (`openshift-install version`)
- `oc` (OpenShift client)
- `aws` (AWS CLI v2)
- `jq`
- `ansible-playbook` 2.16+ (`ansible --version`)

### Python packages (in the Python that Ansible uses)

```
pip3 install boto3 botocore kubernetes jmespath bcrypt
```

### Ansible collections

```
ansible-galaxy collection install -r ansible/requirements.yml
```

Installs: `amazon.aws >=9.0.0`, `kubernetes.core >=5.0.0`, `community.general >=10.0.0`.

---

## Quick Start

### Full deploy (with LINSTOR)

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

Or directly:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook \
  ansible/playbooks/deploy-tna-student.yml \
  -e tna_guid=linbit-s1 \
  -e tna_base_domain=sandbox3493.opentlc.com \
  -v
```

### Deploy without LINSTOR (bare TNA cluster)

Omit LINBIT credentials from your secrets file. Phase 7 auto-skips when `tna_linbit_registry_username` is empty.

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

You get a 3-node TNA cluster (2 CP + 1 arbiter) with `mastersSchedulable: true` and no storage operator. Install any CSI driver you want (ODF, Portworx, Longhorn, EBS CSI, etc.).

### Resume from a specific phase after failure

```bash
make deploy-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com TAGS=preflight,phase2,phase5b,phase6,phase7,phase7b,phase8
```

**Important:** When resuming, always include `preflight` and `phase2` tags. Preflight loads secrets and SSH keys; Phase 2 detects the existing CloudFormation stack and re-extracts outputs (instance IDs, IPs) into facts. Without these, later phases fail on undefined variables.

### Tear down

```bash
make teardown-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

### Via ansible-navigator (containerized)

```bash
ansible-navigator run ansible/playbooks/deploy-tna-student.yml \
  -e tna_guid=linbit-s1 \
  -e tna_base_domain=sandbox3493.opentlc.com \
  --mode stdout
```

Requires the Execution Environment image (`make build-ee`) or the one specified in `ansible/ansible-navigator.yml`.

---

## Phase Architecture

Each phase is a separate task file with its own tag, included from `roles/tna_student_cluster/tasks/main.yml`. Total deploy time is ~60-75 minutes.

### Preflight (tag: `preflight`)

**File:** `tasks/preflight.yml`
**Duration:** ~10s
**What it does:**
- Verifies CLI tools exist (`openshift-install`, `oc`, `aws`, `jq`)
- Reads `~/pull-secret.json` and `~/.ssh/id_ed25519.pub` into facts
- Resolves the Route53 hosted zone ID for the base domain
- Creates output directories under `~/Development/agnosticd-v2-output/<guid>/`
- Loads LINBIT registry credentials from secrets file (if present)

**If it fails:** Check that all CLI tools are installed, the pull secret file exists, and AWS credentials are working.

### Phase 1 — ISO and AMI (tag: `phase1`)

**File:** `tasks/phase1_iso_ami.yml`
**Duration:** ~90s (cached AMI reuse) or ~10 min (new AMI build)
**What it does:**
- Renders `install-config.yaml` and `agent-config.yaml` from Jinja2 templates
- Runs `openshift-install agent create image` to generate the agent ISO
- Checks for a cached AMI tagged `ocp-version=4.22`. If found, reuses it.
- If no cached AMI: uploads ISO to S3, imports as EBS snapshot, registers as AMI
- Stores the AMI ID in `tna_agent_ami_id` fact

**If it fails:** Check `openshift-install` version matches OCP 4.22+. Check S3 bucket access. Check the rendered `install-config.yaml` in `~/Development/agnosticd-v2-output/<guid>/agent-assets/iso-build/`.

### Phase 2 — CloudFormation (tag: `phase2`)

**File:** `tasks/phase2_cloudformation.yml`
**Duration:** ~5 min (new stack) or ~5s (existing stack)
**What it does:**
- Checks if stack `tna-<guid>` already exists. If so, extracts outputs without re-creating.
- Detects failed stacks (`ROLLBACK_COMPLETE`, `CREATE_FAILED`, `DELETE_FAILED`) and auto-deletes them before creating a new stack.
- If new: deploys `agnosticd/cloudformation/tna-student.yaml` (VPC, 3 EC2 instances, NLB, Route53 records)
- Extracts instance IDs, private IPs, API URL, console URL into facts
- Creates an `api-int` A record pointing to CP private IPs (NLB hairpin DNS workaround)

**If it fails:** Check CloudFormation events in the AWS console for the stack `tna-<guid>`. Common issues: AMI doesn't exist in the region, instance type not available in the AZ, quota limits. If the stack is in `ROLLBACK_COMPLETE`, the role will auto-delete and retry.

### Phase 3 — MAC Addresses (tag: `phase3`)

**File:** `tasks/phase3_mac_addresses.yml`
**Duration:** ~10s
**What it does:**
- Queries EC2 for instance details (MAC addresses, IPs)
- Saves metadata to `instance-macs.txt`
- Gets CP0 public IP for SSH access in later phases

**If it fails:** Instances may not be fully running yet. Check EC2 console.

### Phase 4 — Trigger Install (tag: `phase4`)

**File:** `tasks/phase4_trigger_install.yml`
**Duration:** ~15 min
**What it does:**
1. Waits for the assisted-service API on the rendezvous host (CP0) via SSH. Checks HTTP status code — both `200` and `401` mean the API is up.
2. Retrieves the auth token, infra-env ID, and cluster ID from the assisted-service.
3. Waits for all 3 hosts to register with status `known`.
4. Triggers cluster installation via POST to the assisted-service API.
5. Monitors `coreos-installer` progress — polls until all hosts reach "Rebooting" stage or finish writing to disk.

**If it fails:**
- SSH refused: instances may still be booting from the ISO (takes 5-10 min after CloudFormation completes).
- Hosts not registering: check that the AMI is correct and the ISO was generated for the right OCP version.
- coreos-installer errors: check the assisted-service logs via `ssh core@<cp0-public-ip> "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs/<id>/hosts | jq"`.

### Phase 5a — Two-Phase Volume Swap (tag: `phase5a`)

**File:** `tasks/phase5a_volume_swap.yml`
**Duration:** ~30-45 min (mostly waiting for bootstrap)

This is the critical phase that works around EC2's fixed boot order. See [EC2 Volume Swap Architecture](../docs/architecture/ec2-volume-swap.md) for the full explanation.

**What it does:**

**Phase 1 — Swap cp-1 and arbiter-0 (keep cp-0 on ISO for MCS):**
1. Waits for all hosts to finish writing RHCOS to disk.
2. Stops cp-1 and arbiter-0.
3. Swaps EBS volumes: detach ISO from `/dev/sda1`, move RHCOS from `/dev/xvdb` to `/dev/sda1`, delete old ISO volume.
4. Starts cp-1 and arbiter-0 — they boot into RHCOS, fetch ignition from cp-0's MCS (port 22623).
5. Waits for cp-1's kube-apiserver to pass NLB health check (up to 30 min).
6. Waits for MCS on cp-1 to become healthy.
7. **Bootstrap gate:** Waits for **2** etcd members and **2** registered nodes via cp-1. (cp-0 does NOT register as a node or etcd member while on the ISO — it only joins after Phase 2 swap.)

**Phase 2 — Swap cp-0 (rendezvous/bootstrap node):**
1. Stops cp-0.
2. Swaps EBS volumes (same procedure).
3. Starts cp-0 — it boots RHCOS and fetches ignition from MCS on cp-1.
4. Fetches `lb-ext.kubeconfig` from cp-1 (the ISO build kubeconfig has a different CA and does NOT work).
5. **Kubeadmin password reset:** The agent-based installer regenerates the kubeadmin password during bootstrap, so the ISO build copy is stale. Generates a new bcrypt hash, patches the `kube-system/kubeadmin` secret, saves cleartext to the output directory.

**If it fails:**
- Helper file `_volume_swap_single.yml` performs the per-instance swap. Check which instance failed.
- If the API never comes up after swap: reboot instances via `aws ec2 reboot-instances`, wait 5 min, retry.
- If bootstrap gate times out at fewer than 2 members: check etcd logs on cp-1 via SSH.

### Phase 5b — Wait for Install Completion (tag: `phase5b`)

**File:** `tasks/phase5b_wait_completion.yml`
**Duration:** ~5-10 min
**What it does:**
- Runs `openshift-install agent wait-for install-complete` to monitor final cluster convergence.
- Waits for all ClusterOperators to reach Available state.

### Phase 6 — Node Config (tag: `phase6`)

**File:** `tasks/phase6_node_config.yml`
**Duration:** ~1 min
**What it does:**
- Labels control-plane nodes with `linbit.com/role=primary`
- Labels arbiter node with `linbit.com/role=arbiter` and `node-role.kubernetes.io/arbiter=`
- Taints arbiter with `node-role.kubernetes.io/arbiter:NoSchedule`
- Patches Scheduler CR to allow workloads on master nodes (since there are no workers)

**Node detection note:** With `platform: none`, the `spec.providerID` field is never set on nodes. Arbiter detection uses the `node-role.kubernetes.io/arbiter` label instead.

**TNA topology note:** The arbiter node has the `arbiter` role but NOT `master`. Node queries must include all nodes (not just masters) to find the arbiter.

### Phase 7 — LINSTOR (tag: `phase7`)

**File:** `tasks/phase7_linstor.yml`
**Duration:** ~5-10 min
**What it does:**
- Creates `linbit-sds` namespace
- Applies OperatorGroup, Subscription, LinstorCluster CRs from `files/linstor-crds/`
- Creates docker-registry secret for `drbd.io`
- Waits for LINSTOR operator CSV to succeed (queries with `api_version: operators.coreos.com/v1alpha1`)
- Applies SatelliteConfiguration for primary and arbiter nodes
- Waits for LINSTOR satellites to come online
- Sets encryption passphrase
- Applies StorageClasses

**Skipped if** `tna_linbit_registry_username` is empty (no LINBIT credentials), **or** `tna_linstor_install_method=helm` (default `make deploy` path — Field Content / ArgoCD owns LINSTOR so this phase does not double-install). See [LINBIT registry credentials — Phase 7 skip](../docs/setup/linbit-registry-credentials.md#phase-7-missing-credential-skip-make-deploy-student).

The encryption passphrase is read from AgnosticD `secrets.yml` (`linstor_encryption_passphrase`). `bootstrap.sh` generates one if missing. It is not committed to git.

### Phase 7b — GitOps and Virtualization (tags: `phase7b`, `gitops`, `cnv`)

**File:** `tasks/phase7b_operators.yml`
**Duration:** ~5-15 min
**What it does:**
- Installs OpenShift GitOps (ArgoCD) via OLM Subscription and waits for the CSV + `openshift-gitops-server` Deployment
- Installs OpenShift Virtualization (CNV), waits for the CSV, applies `HyperConverged`
- Sets nested KVM via `kubevirt.kubevirt.io/jsonpatch` `useEmulation` from `tna_enabled_nested_kvm` (`true` on AWS `standard`, unset on `virt-enabled` / metal). HyperConverged `spec.kVMEmulation` was removed in CNV 4.22.

**If it fails:** Check OperatorHub (`redhat-operators`) and CSV status in `openshift-operators` / `openshift-cnv`. Re-run with `TAGS=preflight,phase2,phase7b`.

Idempotent: safe to re-run; Subscriptions and HyperConverged are `state: present`.

`make deploy` installs GitOps/CNV here and does **not** re-install them in `deploy_student_workloads` (that step is cert-manager + Field Content only).

### Phase 8 — Readiness (tag: `phase8`)

**File:** `tasks/phase8_readiness.yml`
**Duration:** ~10s
**What it does:**
- Gets node list and verifies all nodes are present
- Reads the kubeadmin password from the output directory
- Saves `deployment_info.txt` with API URL, console URL, kubeadmin credentials, instance IDs
- Displays access information:
  ```
  ========================================================
  TNA student cluster <name> deployed successfully.
  ========================================================
    Console:    https://console-openshift-console.apps.<guid>.<domain>
    API:        https://api.<guid>.<domain>:6443
    Username:   kubeadmin
    Password:   <generated-password>
    Kubeconfig: ~/Development/agnosticd-v2-output/<guid>/auth/kubeconfig
    Login:      oc login https://api.<guid>.<domain>:6443 -u kubeadmin -p <password>
  ========================================================
  ```

---

## Teardown

**File:** `playbooks/teardown-tna-student.yml`

```bash
make teardown-student GUID=linbit-s1 BASE_DOMAIN=sandbox3493.opentlc.com
```

**What it does:**
1. Deletes the CloudFormation stack (`tna-<guid>`) — this removes EC2 instances, NLB, VPC, and stack-managed DNS records.
2. Cleans up the `api-int` A record from Route53. This record is NOT managed by the stack, so the teardown looks up the current record values from Route53 and deletes them explicitly (the `amazon.aws.route53` module silently fails without exact values — we use the AWS CLI instead).
3. Removes local output files.

**If `api-int` record persists after teardown:** The next deploy will fail with a DNS collision. Check Route53 manually.

---

## Key Technical Details

These are hard-won lessons from deploy iterations E4 through E9.

### 1. Bootstrap host behavior on the ISO

The rendezvous host (cp-0) runs the assisted-service and MCS on the ISO during install. While on the ISO, cp-0 does **not** register as a cluster node or etcd member. Only cp-1 and arbiter-0 register during Phase 1. cp-0 joins as the 3rd member after Phase 2 swaps it to RHCOS.

### 2. Kubeconfig CA mismatch

The kubeconfig generated by `openshift-install agent create image` has a self-signed CA. During bootstrap, the kube-apiserver generates a different CA (`kube-apiserver-lb-signer`). The ISO build kubeconfig does NOT work post-bootstrap. Fetch `lb-ext.kubeconfig` from cp-1 at `/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig`.

### 3. Kubeadmin password regeneration

The agent-based installer regenerates the kubeadmin password during bootstrap. The password file in the ISO build directory is stale. The automation generates a new bcrypt hash, patches the `kube-system/kubeadmin` secret, and saves the cleartext to the output directory.

### 4. Platform: none implications

Agent-based installs use `platform: none: {}`. This means `spec.providerID` is never set on nodes. Any logic that relies on providerID for node identification must be replaced with label-based detection.

### 5. CloudFormation failed stack cleanup

If a previous deploy failed, the stack may be in `ROLLBACK_COMPLETE`, `CREATE_FAILED`, or `DELETE_FAILED`. These stacks can't be updated — they must be deleted before creating a new one. Phase 2 handles this automatically.

### 6. Route53 api-int record

The `api-int` A record is created outside the CloudFormation stack. It must be cleaned up separately during teardown. The teardown looks up current record values from Route53 before deleting, because the `amazon.aws.route53` module silently fails without exact values.

---

## File Map

| Path | Purpose |
|------|---------|
| `ansible.cfg` | Ansible config (roles path, SSH settings, result format) |
| `ansible-navigator.yml` | ansible-navigator config (EE image, volume mounts, env vars) |
| `requirements.yml` | Galaxy collection dependencies |
| `execution-environment.yml` | EE build definition for ansible-builder |
| `.ansible-lint` | Lint config (suppressed rules: `var-naming[no-role-prefix]`, `name[template]`) |
| `playbooks/deploy-tna-student.yml` | Deploy playbook (includes the role) |
| `playbooks/teardown-tna-student.yml` | Teardown playbook (deletes stack, DNS, local files) |
| `roles/tna_student_cluster/defaults/main.yml` | All default variables (instance types, sizes, paths, timeouts) |
| `roles/tna_student_cluster/tasks/main.yml` | Phase orchestrator with tag routing |
| `roles/tna_student_cluster/tasks/preflight.yml` | CLI checks, secret loading, directory setup |
| `roles/tna_student_cluster/tasks/phase1_iso_ami.yml` | ISO generation, AMI caching |
| `roles/tna_student_cluster/tasks/phase2_cloudformation.yml` | Stack deploy/detect, output extraction |
| `roles/tna_student_cluster/tasks/phase3_mac_addresses.yml` | Instance metadata collection |
| `roles/tna_student_cluster/tasks/phase4_trigger_install.yml` | Assisted-service interaction, install trigger |
| `roles/tna_student_cluster/tasks/phase5a_volume_swap.yml` | Two-phase volume swap + bootstrap gate |
| `roles/tna_student_cluster/tasks/_volume_swap_single.yml` | Per-instance volume swap helper |
| `roles/tna_student_cluster/tasks/phase5b_wait_completion.yml` | Wait for install-complete + ClusterOperators |
| `roles/tna_student_cluster/tasks/phase6_node_config.yml` | Labels, taints, scheduler patch |
| `roles/tna_student_cluster/tasks/_label_node.yml` | Per-node label/taint helper |
| `roles/tna_student_cluster/tasks/phase7_linstor.yml` | LINSTOR operator + satellite setup |
| `roles/tna_student_cluster/tasks/phase8_readiness.yml` | Final checks, save deployment info |
| `roles/tna_student_cluster/templates/install-config.yaml.j2` | OCP install-config template |
| `roles/tna_student_cluster/templates/agent-config.yaml.j2` | Agent-config template |
| `roles/tna_student_cluster/templates/satellite-config-primary.yml.j2` | LINSTOR SatelliteConfiguration for CP nodes |
| `roles/tna_student_cluster/files/linstor-crds/operator-group.yml` | LINSTOR OperatorGroup |
| `roles/tna_student_cluster/files/linstor-crds/subscription.yml` | LINSTOR operator Subscription |
| `roles/tna_student_cluster/files/linstor-crds/linstor-cluster.yml` | LinstorCluster CR |
| `roles/tna_student_cluster/files/linstor-crds/satellite-config-arbiter.yml` | Arbiter SatelliteConfiguration |
| `roles/tna_student_cluster/files/linstor-crds/storage-classes.yml` | LINSTOR StorageClasses |

---

## Debugging Tips

### Check assisted-service status from your workstation

```bash
CP0_IP=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=<guid>-cp-0" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 core@$CP0_IP \
  "curl -s http://10.0.1.10:8090/api/assisted-install/v2/clusters | jq '.[0] | {status, status_info, progress}'"
```

### Check per-host install progress

```bash
INFRA_ENV_ID=$(ssh core@$CP0_IP "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs | jq -r '.[0].id'")

ssh core@$CP0_IP \
  "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs/$INFRA_ENV_ID/hosts | \
   jq '[.[] | {hostname: .requested_hostname, status, stage: .progress.current_stage, info: .status_info[0:80]}]'"
```

### Check etcd member count (during bootstrap gate)

```bash
CP1_IP=$(aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=<guid>-cp-1" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

ssh -o StrictHostKeyChecking=no -i ~/.ssh/id_ed25519 core@$CP1_IP \
  "sudo oc --kubeconfig /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost.kubeconfig \
  get etcd -o jsonpath='{.items[0].status.conditions[?(@.type==\"EtcdMembersAvailable\")].message}'"
```

### Check NLB target health

```bash
aws elbv2 describe-target-health --region us-east-2 \
  --target-group-arn $(aws elbv2 describe-target-groups --region us-east-2 \
    --query 'TargetGroups[?TargetGroupName==`<guid>-api`].TargetGroupArn' --output text) \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output table
```

### View EC2 instance console output

```bash
aws ec2 get-console-output --region us-east-2 --instance-id <instance-id> \
  --query Output --output text | strings | tail -20
```

Note: m7a instances (Nitro/AMD) only show BIOS/GRUB in serial console output. Kernel messages go to a different console device.
