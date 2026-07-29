## 7 things I learned deploying agent-based OpenShift on AWS EC2

The Red Hat OpenShift agent-based installer is supported on bare-metal and VMware. It is not supported on EC2. I decided to make it work anyway.

I was building a Two-Node with Arbiter (TNA) topology for an edge storage workshop. TNA gives you two full control-plane nodes plus a lightweight arbiter for etcd quorum, which is a sweet spot for edge sites where you want resilience without the cost of a third large node. The agent-based installer was the right fit because it runs a self-contained assisted-service on the ISO itself, with no external infrastructure required. The only problem: EC2 does not let you change the boot order.

It took six deploy iterations, from E4 through E9, to get a fully automated, repeatable deployment. Zero prior art existed for this as of July 2026. Every lesson below came from a silent failure that burned real hours. Here are the seven things I wish someone had told me before I started.

## 1. EC2 always boots from /dev/sda1, so you need a volume swap

The agent ISO boots from /dev/sda1. The coreos-installer inside it writes Red Hat Enterprise Linux CoreOS (RHCOS) to the secondary EBS volume at /dev/xvdb. When the instance reboots, it goes right back to the ISO. There is no EC2 API to change the boot device.

The fix is a volume swap. Stop the instance, detach the ISO volume from /dev/sda1, move the RHCOS volume from /dev/xvdb to /dev/sda1, delete the old ISO volume, and start the instance. It now boots RHCOS. This is straightforward once you know the trick, but I found no documentation or community post describing it anywhere. The entire deployment hangs on this one maneuver.

## 2. The rendezvous host is invisible during bootstrap, so wait for 2, not 3

This one stalled iterations E4 and E5 for hours. The rendezvous host, cp-0, runs the assisted-service and the Machine Config Server (MCS) on port 22623 while booted from the ISO. But it does not register itself as a Kubernetes node or an etcd member. It is invisible to the cluster.

That means the bootstrap gate must check for 2 etcd members and 2 registered nodes, not 3. If you wait for 3, the gate times out. cp-0 only joins the cluster after you swap it to RHCOS in Phase 2. I spent a long time staring at a timeout before I realized the node I was waiting for was the one running the bootstrap services.

## 3. The kubeconfig from the ISO build does not work after bootstrap

The openshift-install agent create image command generates a kubeconfig with a self-signed certificate authority (CA). During bootstrap, the kube-apiserver generates a completely different CA called kube-apiserver-lb-signer. The kubeconfig from the ISO build directory returns TLS errors the moment bootstrap completes.

The fix is to SSH to cp-1 and fetch lb-ext.kubeconfig from /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig. This file has the real CA that matches the running API server. I automated this as part of Phase 2 of the volume swap, right after cp-0 gets swapped.

## 4. The kubeadmin password is regenerated during bootstrap

The agent-based installer generates a kubeadmin password when it builds the ISO. During bootstrap, the cluster silently replaces that password with a new one. If you try to log in with the password from the ISO build directory, you get a 401 Unauthorized.

The fix is to generate a fresh bcrypt hash, patch the kube-system/kubeadmin secret, and save the cleartext to your output directory. This caught me off guard because nothing in the install logs mentions the password changing. It just quietly stops working.

## 5. You must swap nodes in two phases because MCS must stay up

This is the key insight of the whole approach. You cannot swap all three nodes at once. cp-0 runs MCS on port 22623 during bootstrap. The other nodes need MCS to fetch their ignition configs when they boot RHCOS for the first time.

Phase 1 swaps cp-1 and arbiter-0 while cp-0 stays on the ISO. They boot into RHCOS and pull ignition from cp-0's MCS through the Network Load Balancer (NLB). Once cp-1's API server and MCS are healthy, and the bootstrap gate sees 2 etcd members and 2 nodes, Phase 2 swaps cp-0. By then, the Machine Config Operator (MCO) on cp-1 has taken over MCS duties. cp-0 can safely boot RHCOS and fetch its ignition from cp-1. Getting this order wrong means MCS goes down before nodes have their configs, and the cluster never forms.

## 6. Platform none means providerID is never set

Agent-based installs use platform: none in the install-config. This means spec.providerID is empty on every node. Any logic that identifies nodes by providerID, which is common in cloud-aware operators and scripts, will not find anything.

Use node labels instead. But here is the TNA wrinkle: the arbiter node gets node-role.kubernetes.io/arbiter but does not get node-role.kubernetes.io/master. If your queries filter by master, they miss the arbiter entirely. I had to adjust every node lookup to query all nodes or explicitly include both roles.

## 7. Failed stacks and orphan DNS silently block re-deploy

After a failed deployment attempt, the CloudFormation stack sits in ROLLBACK_COMPLETE or CREATE_FAILED. You cannot update these stacks. You must delete them before creating a new one. The automation detects this and auto-deletes, but if you are doing anything manually, this will block you without a helpful error message.

The other trap is the api-int DNS A record. The automation creates this record outside CloudFormation as a workaround for NLB hairpin routing. That means the stack teardown does not clean it up. You have to look up the current record values from Route53 and delete them explicitly. The amazon.aws.route53 Ansible module silently fails if you pass hardcoded values that do not match. I learned this the hard way when a stale api-int record caused the next deploy to route traffic to instances that no longer existed.

## Where this goes from here

Six iterations took this from "EC2 cannot do that" to a fully automated 75-minute deploy: 161 tasks ok, 0 failed, zero manual intervention. The two-phase volume swap pattern is not AWS-specific in concept. It works anywhere the cloud boots from a fixed device path and lets you detach and reattach block volumes while the instance is stopped.

The automation is also modular. If you skip the LINBIT storage credentials, phases 0 through 6 give you a bare TNA OpenShift cluster with no storage operator. Install whatever CSI driver fits your use case.

If you are evaluating minimal OpenShift topologies for edge or resource-constrained sites, look at the [TNA and TNF documentation in the OpenShift docs](https://docs.openshift.com/container-platform/latest/installing/installing_with_agent_based_installer/installing-with-agent-based-installer.html). The code behind this post is in the [openshift-tnf-edge-storage repository on GitHub](https://github.com/tosin2013/openshift-tnf-edge-storage).
