## How to deploy a two-node with arbiter OpenShift cluster on AWS EC2

Running Red Hat OpenShift at the edge or in resource-constrained environments usually forces a tradeoff: you either get high availability or a minimal footprint, but not both. The Two-Node with Arbiter (TNA) topology eliminates that tradeoff. You get two full control-plane nodes for workloads and a lightweight arbiter for quorum -- three nodes total, production-grade availability, and a fraction of the cost of a standard cluster.

I built an open source automation that deploys a complete TNA cluster on Amazon Web Services (AWS) Elastic Compute Cloud (EC2) with a single command. The entire process takes 60 to 75 minutes and requires zero manual intervention. What makes this interesting is that the OpenShift agent-based installer was designed for bare-metal and VMware environments, not cloud instances. Getting it to work on EC2 required solving a boot-order problem that, as of July 2026, has no known prior art. I will walk you through the full deployment in this post.

## What is a two-node with arbiter cluster?

A TNA cluster consists of three nodes with distinct roles. Two control-plane nodes run the Kubernetes API server, etcd, and your workloads. The third node is an arbiter -- a lightweight tiebreaker that participates in etcd quorum but does not run user workloads. If one control-plane node goes down, the arbiter ensures the remaining node maintains quorum and keeps the cluster operational.

Here is the node layout this automation deploys:

| Node | Instance type | vCPU | Memory | Storage |
|------|--------------|------|--------|---------|
| cp-0 (rendezvous) | m7a.4xlarge | 16 | 64 GB | 200 GB root + 50 GB storage |
| cp-1 | m7a.4xlarge | 16 | 64 GB | 200 GB root + 50 GB storage |
| arbiter-0 | m7a.xlarge | 4 | 16 GB | 120 GB root |

This is different from a compact 3-node cluster, where all three nodes are identical and carry equal workload. In a TNA cluster, the arbiter is intentionally small. It is tainted with NoSchedule so workloads only run on the two larger control-plane nodes. Compare this also to a Two-Node with Fencing (TNF) topology, which uses hardware-level fencing (STONITH) instead of a third node for quorum. TNF requires BMC/Redfish access, which is not available on EC2 -- so TNA is the right fit for cloud deployments.

## Prerequisites

Before you start, make sure you have the following:

**AWS account and DNS**

- An AWS account with credentials exported as environment variables (AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)
- A Route53-managed base domain (for example, example.com)
- Sufficient quota in your target region for 3 EC2 instances, 1 Network Load Balancer (NLB), 5 Elastic Block Store (EBS) volumes, and 1 Virtual Private Cloud (VPC)

**Command-line interface (CLI) tools**

- openshift-install 4.22 or later
- oc (OpenShift client)
- aws (AWS CLI v2)
- jq
- ansible-playbook 2.16 or later

**Python packages**

- boto3, botocore, kubernetes, jmespath, bcrypt (install with pip3)

**Local files**

- pull-secret.json in your home directory (download from console.redhat.com)
- SSH keypair at ~/.ssh/id_ed25519 and ~/.ssh/id_ed25519.pub

**Optional**

- LINBIT registry credentials for LINSTOR/DRBD storage. Without these, you still get a fully functional TNA cluster -- the storage phase simply skips.

## Fork the repository and configure

Clone the repository and install the dependencies:

    git clone https://github.com/tosin2013/openshift-tnf-edge-storage.git
    cd openshift-tnf-edge-storage
    ansible-galaxy collection install -r ansible/requirements.yml
    pip3 install boto3 botocore kubernetes jmespath bcrypt

Export your AWS credentials if you have not already:

    export AWS_ACCESS_KEY_ID=your-key-id
    export AWS_SECRET_ACCESS_KEY=your-secret-key

That is it. The defaults work out of the box. You do not need to edit any configuration files for a standard deployment.

## Deploy the cluster

Run one command:

    make deploy-student GUID=my-cluster BASE_DOMAIN=example.com

GUID is a short identifier for your cluster. It becomes part of your DNS names (api.my-cluster.example.com) and AWS resource tags. BASE_DOMAIN is your Route53-managed domain.

Set your expectations: the deploy takes 60 to 75 minutes. You can watch the progress in your terminal, but you do not need to intervene. Go get some coffee.

## What the automation does

The deployment runs through 8 phases. Here is what happens in each one.

### Preflight (~10 seconds)

Verifies that all CLI tools are installed, loads your pull secret and SSH key, resolves your Route53 hosted zone, and creates output directories. If anything is missing, it fails fast with a clear error message.

### Phase 1: ISO and Amazon Machine Image (~90 seconds cached, ~10 minutes new)

Generates the agent-based installer ISO using openshift-install, then registers it as an Amazon Machine Image (AMI). The AMI is cached by OpenShift Container Platform (OCP) version -- if you have already built one for 4.22, this phase reuses it and finishes in about 90 seconds.

### Phase 2: CloudFormation stack (~5 minutes)

Deploys a CloudFormation stack that creates the VPC, 3 EC2 instances, an NLB, and Route53 DNS records. If a previous deploy left a failed stack behind (ROLLBACK_COMPLETE or CREATE_FAILED), the automation detects it, deletes it, and creates a fresh one automatically.

### Phase 3: Instance metadata (~10 seconds)

Collects MAC addresses, private IPs, and the public IP of the rendezvous host (cp-0) for use in later phases.

### Phase 4: Trigger install (~15 minutes)

Connects to the assisted-service running on cp-0 via SSH, waits for all 3 hosts to register, triggers the cluster installation, and monitors coreos-installer as it writes Red Hat Enterprise Linux CoreOS (RHCOS) to each node's secondary EBS volume.

### Phase 5a: Two-phase volume swap (~30-45 minutes)

This is the critical phase -- and the novel part. Here is the problem: EC2 always boots from /dev/sda1. The agent ISO occupies /dev/sda1, and coreos-installer writes RHCOS to the secondary volume at /dev/xvdb. When the instance reboots, it boots back into the ISO instead of RHCOS. There is no EC2 API to change the boot device order.

The solution is an EBS volume swap. After RHCOS is written, the automation stops the instance, detaches the ISO volume from /dev/sda1, moves the RHCOS volume from /dev/xvdb to /dev/sda1, deletes the old ISO volume, and starts the instance. It now boots RHCOS.

But you cannot swap all three nodes at once. cp-0 runs the Machine Config Server (MCS) during bootstrap. The other nodes need MCS to fetch their ignition configs. So the swap happens in two phases: first swap cp-1 and arbiter-0 (while cp-0 stays on the ISO running MCS), wait for the bootstrap gate to pass (2 etcd members, 2 nodes registered, MCS healthy on cp-1), then swap cp-0. After the second swap, cp-0 boots RHCOS and joins as the third cluster member.

### Phase 6: Node configuration (~1 minute)

Labels and taints the arbiter node with NoSchedule, labels the control-plane nodes for their storage roles, and patches the scheduler to allow workloads on control-plane nodes (since there are no dedicated workers).

### Phase 7: LINSTOR storage (~5-10 minutes)

Installs the LINSTOR operator, configures satellites on all three nodes (diskful on control-plane, diskless on arbiter), sets up storage classes, and verifies everything is online. This phase auto-skips if you did not provide LINBIT registry credentials.

### Phase 8: Readiness (~10 seconds)

Verifies all nodes are present, reads the kubeadmin credentials, and prints everything you need to access your cluster.

For the full technical deep dive on the volume swap, see the [EC2 Volume Swap Architecture](https://github.com/tosin2013/openshift-tnf-edge-storage/blob/main/docs/architecture/ec2-volume-swap.md) document.

## Verify your cluster

When Phase 8 completes, the automation prints your cluster access information:

    Console:    https://console-openshift-console.apps.my-cluster.example.com
    API:        https://api.my-cluster.example.com:6443
    Username:   kubeadmin
    Password:   (generated password)
    Login:      oc login https://api.my-cluster.example.com:6443 -u kubeadmin -p (password)

Log in and verify your nodes:

    oc get nodes

You should see 3 nodes: 2 with the master role and 1 with the arbiter role. All should be in Ready status.

## Deploy without LINSTOR storage

If you do not have LINBIT credentials, or if you want to use a different storage backend, the process is exactly the same. Just omit the LINBIT credentials from your secrets file and run the same command:

    make deploy-student GUID=my-cluster BASE_DOMAIN=example.com

Phase 7 auto-skips when credentials are not present. You get a fully functional TNA cluster with no Container Storage Interface (CSI) driver installed. From there, install whatever storage you need: OpenShift Data Foundation, Portworx, Longhorn, the AWS EBS CSI driver, or anything else.

## Clean up

When you are done, tear everything down:

    make teardown-student GUID=my-cluster BASE_DOMAIN=example.com

This deletes the CloudFormation stack (EC2 instances, NLB, VPC, stack-managed DNS records), cleans up the api-int DNS record from Route53, and removes local output files. Remember that AWS resources cost money -- tear down clusters you are not actively using.

## Troubleshooting common issues

**Failed CloudFormation stacks blocking redeploy.** If a previous deploy failed, the stack may be in ROLLBACK_COMPLETE. The automation detects this and auto-deletes the stuck stack before creating a new one. No manual cleanup needed.

**SSH connection refused during Phase 4.** The instances are still booting from the ISO. This takes 5 to 10 minutes after CloudFormation completes. The automation retries automatically -- just wait.

**API not responding after volume swap.** In rare cases, an instance may not boot cleanly after the swap. Reboot the affected instances from the AWS console or CLI and wait 5 minutes. The automation will pick up where it left off.

**Insufficient EC2 quota.** You need capacity for 2x m7a.4xlarge and 1x m7a.xlarge instances. Check your service quotas in the AWS console and request increases if needed.

**Stale api-int DNS record.** If a previous teardown did not fully clean up, the api-int record in Route53 can block the next deploy. Check Route53 manually and delete any orphaned records for your base domain.

## Customize for your environment

The automation is designed to be modified. Here are the most common customizations:

- **Change instance types.** Edit the defaults in roles/tna_student_cluster/defaults/main.yml. The arbiter can run on anything with 4 vCPU and 16 GB or more.
- **Change the AWS region.** Set the region variable in defaults or pass it as an extra variable.
- **Use a different domain.** Any Route53-managed domain works -- just change BASE_DOMAIN.
- **Add your own storage.** Deploy without LINSTOR and install any CSI driver after the cluster is up.
- **Port to another cloud.** The two-phase volume swap pattern works anywhere the cloud boots from a fixed device path and lets you reattach block volumes while an instance is stopped. Replace the AWS-specific pieces (CloudFormation, EBS APIs, NLB health checks) with your provider's equivalents. The rest of the automation is cloud-agnostic.

## Wrap-up

You now have a production-topology TNA OpenShift cluster running on AWS EC2, deployed with a single command. The entire process is open source, fully automated, and requires zero manual intervention. The two-phase EBS volume swap that makes this possible is, to my knowledge, the first published implementation of an agent-based OpenShift install on EC2. I hope this approach is useful to anyone building minimal-footprint OpenShift clusters in the cloud.

## Learn more

- Read about [TNA and TNF topologies in the OpenShift documentation](https://docs.openshift.com/container-platform/4.22/installing/installing-two-node-cluster.html)
- Fork the [openshift-tnf-edge-storage repository](https://github.com/tosin2013/openshift-tnf-edge-storage) and try the deployment yourself
- Read the [EC2 Volume Swap Architecture](https://github.com/tosin2013/openshift-tnf-edge-storage/blob/main/docs/architecture/ec2-volume-swap.md) deep dive for the full technical explanation of the two-phase swap
