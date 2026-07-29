# EC2 Volume Swap: Agent-Based OpenShift Install on AWS

## The Problem

The OpenShift agent-based installer generates a bootable ISO containing an embedded assisted-service. On bare-metal or VMware, you boot from the ISO, the installer writes RHCOS to the local disk, and the node reboots into RHCOS. Simple.

On AWS EC2, this breaks. EC2 always boots from `/dev/sda1`. The agent ISO occupies `/dev/sda1`, and `coreos-installer` writes RHCOS to the secondary EBS volume at `/dev/xvdb`. When the node reboots, it boots back into the ISO — not RHCOS. There is no EC2 API to change boot device order.

This approach is novel. As of July 2026, no known prior art exists for running the agent-based OpenShift installer on EC2 with an automated boot-order workaround.

## The Solution

After `coreos-installer` writes RHCOS to `/dev/xvdb`, we swap the EBS volumes:

1. **Stop** the EC2 instance
2. **Detach** the ISO volume from `/dev/sda1`
3. **Detach** the RHCOS volume from `/dev/xvdb`
4. **Attach** the RHCOS volume as `/dev/sda1`
5. **Delete** the old ISO volume
6. **Start** the instance — it now boots RHCOS

But the swap cannot happen all at once. The rendezvous host (cp-0) runs the Machine Config Server (MCS) on port 22623 during bootstrap. Other nodes need MCS to fetch their ignition configs. If you swap all nodes simultaneously, MCS goes down before cp-1 and arbiter-0 have their configs.

## Why Two Phases

```
Timeline
========

Phase 1: Swap cp-1 + arbiter-0                Phase 2: Swap cp-0
(cp-0 stays on ISO, runs MCS)                  (MCS now on cp-1)

  cp-0 [===== ISO (MCS + bootstrap) =====]--[stop]--[swap]--[start → RHCOS]
  cp-1 [stop]--[swap]--[start → RHCOS =========================>]
  arb  [stop]--[swap]--[start → RHCOS =========================>]
                |                         |           |
                |   bootstrap gate:       |           |
                |   2 etcd members        |           |
                |   2 nodes registered    |           |
                |   cp-1 API healthy      |           |
                |   cp-1 MCS healthy      |           |
                v                         v           v
          cp-1 + arb boot RHCOS,    gate passes,    cp-0 boots RHCOS,
          fetch ignition from       swap cp-0       joins as 3rd etcd
          cp-0's MCS                                member
```

### Phase 1: Swap cp-1 and arbiter-0

cp-0 stays on the ISO. Its MCS continues serving ignition configs on port 22623.

1. Stop cp-1 and arbiter-0
2. Swap their EBS volumes (ISO → RHCOS)
3. Start them — they boot RHCOS and fetch ignition from cp-0's MCS via the NLB
4. Wait for:
   - cp-1's kube-apiserver to pass the NLB health check (port 6443)
   - cp-1's MCS to pass the NLB health check (port 22623)
   - **2 etcd members** available (cp-1 + arbiter-0)
   - **2 nodes** registered (cp-1 + arbiter-0)

The bootstrap gate waits for **2**, not 3. cp-0 is still on the ISO — it does NOT register as a cluster node or etcd member until Phase 2.

### Phase 2: Swap cp-0

Now that MCS is running on cp-1 (via the MCO, not the bootstrap ISO), cp-0 can be safely swapped.

1. Stop cp-0
2. Swap its EBS volume
3. Start cp-0 — it boots RHCOS and fetches ignition from cp-1's MCS
4. cp-0 joins as the 3rd etcd member and 3rd cluster node

After Phase 2, the automation:
- Fetches `lb-ext.kubeconfig` from cp-1 (the ISO build kubeconfig has a different CA — see below)
- Resets the kubeadmin password (the agent-based installer regenerates it during bootstrap)

## Key Discoveries

These were found through six deploy iterations (E4-E9). Each represents a silent failure that blocked automation until identified.

### 1. The rendezvous host is invisible to the cluster during bootstrap

While running on the ISO, cp-0 hosts the assisted-service and MCS but does NOT register itself as a Kubernetes node or etcd member. This means:
- The bootstrap gate must check for **2** members/nodes, not 3
- If you wait for 3, the gate times out — cp-0 only joins after being swapped to RHCOS

### 2. The ISO build kubeconfig does not work post-bootstrap

`openshift-install agent create image` generates a kubeconfig with a self-signed CA. During bootstrap, the kube-apiserver generates a different CA (`kube-apiserver-lb-signer`). The ISO build kubeconfig returns TLS errors after bootstrap.

**Solution:** SSH to cp-1 and fetch the real kubeconfig:
```
/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig
```

### 3. The kubeadmin password is regenerated during bootstrap

The agent-based installer generates a kubeadmin password when building the ISO. During bootstrap, this password is replaced. The ISO build copy is stale and returns 401 Unauthorized.

**Solution:** Generate a new bcrypt hash, patch the `kube-system/kubeadmin` secret, save the cleartext:
```bash
# Generate password + bcrypt hash
python3 -c "
import secrets, string, bcrypt
chars = string.ascii_letters + string.digits
pw = '-'.join(''.join(secrets.choice(chars) for _ in range(5)) for _ in range(4))
h = bcrypt.hashpw(pw.encode(), bcrypt.gensalt(rounds=10)).decode()
print(pw)
print(h)
"

# Patch the secret
oc patch secret kubeadmin -n kube-system --type=merge \
  -p '{"data":{"kubeadmin":"<base64-encoded-bcrypt-hash>"}}'
```

### 4. `platform: none` means no providerID

Agent-based installs use `platform: none: {}`. The `spec.providerID` field is never set on nodes. Any logic that identifies nodes by providerID (common in cloud-aware operators) must use labels instead.

### 5. Arbiter has the `arbiter` role but NOT `master`

In a TNA topology, the arbiter node gets `node-role.kubernetes.io/arbiter` but does NOT have the `master` role. If your queries filter by `node-role.kubernetes.io/master`, they will miss the arbiter. Query all nodes or include both roles.

### 6. The `api-int` DNS record is not stack-managed

The `api-int` A record is created by the automation outside CloudFormation. The teardown must look up the current record values from Route53 before deleting. The `amazon.aws.route53` Ansible module silently fails if you pass hardcoded values that don't match the actual record.

### 7. Failed CloudFormation stacks block re-deploy

Stacks in `ROLLBACK_COMPLETE`, `CREATE_FAILED`, or `DELETE_FAILED` can't be updated. They must be explicitly deleted before creating a new stack. The automation detects and auto-deletes these.

## Using Without LINSTOR

The automation is modular. **Phases 0-6 give you a fully functional TNA OpenShift cluster with no storage operator.** LINSTOR is installed in Phase 7 only — and Phase 7 auto-skips when LINBIT credentials are not provided.

### Deploy a bare TNA cluster

Use the same command — just omit LINBIT credentials from your secrets file:

```bash
# No linbit_registry_username / linbit_registry_password in secrets.yml
make deploy-student GUID=my-cluster BASE_DOMAIN=example.com
```

### What you get

- 3-node TNA cluster: 2 control-plane nodes + 1 arbiter
- `mastersSchedulable: true` (workloads run on CP nodes since there are no workers)
- Arbiter node labeled with `node-role.kubernetes.io/arbiter` and tainted with `NoSchedule`
- No CSI driver or storage operator — install whatever you need

### Installing a different storage backend

After deploy, install any CSI driver. Examples:

**OpenShift Data Foundation (ODF):**
```bash
# Install the ODF operator from OperatorHub, then create a StorageSystem
oc apply -f - <<EOF
apiVersion: odf.openshift.io/v1alpha1
kind: StorageSystem
metadata:
  name: ocs-storagecluster-storagesystem
  namespace: openshift-storage
spec:
  kind: storagecluster.ocs.openshift.io/v1
  name: ocs-storagecluster
  namespace: openshift-storage
EOF
```

**AWS EBS CSI Driver:**
```bash
# With platform: none, install the EBS CSI driver manually
# See: https://docs.openshift.com/container-platform/4.22/storage/container_storage_interface/persistent-storage-csi-ebs.html
```

### Adjusting arbiter labels

The automation applies `linbit.com/role=arbiter` and `linbit.com/storage-role=arbiter` labels, plus a `node-role.kubernetes.io/arbiter:NoSchedule` taint. If you're using a different storage backend:

- The `linbit.com/*` labels are harmless but unnecessary — remove them if you prefer:
  ```bash
  oc label node <arbiter-node> linbit.com/role- linbit.com/storage-role-
  ```
- The `node-role.kubernetes.io/arbiter:NoSchedule` taint keeps workloads off the arbiter (4 vCPU, 16 GB) — you probably want to keep this regardless of storage backend.
- Edit `roles/tna_student_cluster/tasks/_label_node.yml` to change the labels for your use case.

## Adapting to Other Cloud Providers

The two-phase volume swap pattern works anywhere the cloud:
1. Boots from a fixed device path (can't change boot order)
2. Lets you detach and reattach block volumes while the instance is stopped

The implementation is AWS-specific (EBS APIs, NLB health checks, CloudFormation), but the concept transfers.

### What's AWS-specific

| Component | AWS Implementation | Generic Equivalent |
|-----------|-------------------|-------------------|
| Volume swap | EBS detach/attach via `amazon.aws` modules | Cloud provider's block storage API |
| Boot device | `/dev/sda1` (EBS root) | Provider's root volume convention |
| Data device | `/dev/xvdb` (secondary EBS) | Secondary block device |
| Health gate | NLB target group health checks | Load balancer health or direct SSH probe |
| Infrastructure | CloudFormation stack | Terraform, Pulumi, or cloud-native IaC |
| DNS | Route53 | Cloud DNS or external DNS provider |

### What's generic

- The two-phase swap order (non-bootstrap nodes first, rendezvous node last)
- The bootstrap gate (2 etcd members + 2 nodes before swapping the rendezvous host)
- The `lb-ext.kubeconfig` fetch from a non-rendezvous CP node
- The kubeadmin password reset
- All phases after the volume swap (node config, LINSTOR, readiness)

To port this to another cloud, replace the volume swap helper (`_volume_swap_single.yml`) and the CloudFormation stack with your provider's equivalents. The rest of the automation is cloud-agnostic.
