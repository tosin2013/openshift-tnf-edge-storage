# Research: openshift-agent-install (Track B)

**Source:** [tosin2013/openshift-agent-install](https://github.com/tosin2013/openshift-agent-install.git)  
**Docs site:** https://tosin2013.github.io/openshift-agent-install/  
**Relevance:** Cluster bootstrap for Track B (TNF on KVM / bare metal) from this IBM Cloud host.  
**Workshop OCP target:** 4.22+ (stricter than upstream’s “4.15+ / tested 4.20–4.21” matrix — we must validate 4.22 explicitly).

## What the project is

Automated helpers for the **OpenShift Agent-Based Installer (ABI)** on:

- Bare metal  
- vSphere  
- Nutanix AHV  
- `platform=none`  

Topologies commonly documented: **SNO**, **3-node compact**, **HA**. Primary product narrative: **KVM development → fork & adapt → bare metal production**.

## Two deployment contexts

| | KVM development | Bare metal production |
|--|-----------------|------------------------|
| Purpose | Learn / validate configs | Production clusters |
| Networking | VyOS router + libvirt VLANs | Physical switch VLANs |
| DNS | dnsmasq (`192.168.122.1`) | Corporate DNS (BIND / Infoblox / AD) |
| BMC | **sushy** Redfish emulator | Real iDRAC / iLO / IPMI |
| ISO delivery | `./hack/deploy-on-kvm.sh` | `./hack/deploy-iso-baremetal.sh` |
| Env check | `./e2e-tests/validate_env.sh` | `./hack/validate-baremetal-env.sh` |
| Config dir | `examples/` | `site-config/` |

## Common ABI flow (identical after env setup)

```bash
./hack/create-iso.sh <cluster-name>
# ISO → ~/generated_assets/<cluster-name>/agent.x86_64.iso

# KVM:
./hack/deploy-on-kvm.sh examples/<cluster-name>/nodes.yml

# Bare metal Redfish virtual media:
./hack/deploy-iso-baremetal.sh site-config/<cluster-name>/nodes.yml \
  --method redfish \
  --iso ~/generated_assets/<cluster-name>/agent.x86_64.iso

./bin/openshift-install agent wait-for bootstrap-complete \
  --dir ~/generated_assets/<cluster-name>/ --log-level=info
./bin/openshift-install agent wait-for install-complete \
  --dir ~/generated_assets/<cluster-name>/ --log-level=info

export KUBECONFIG=~/generated_assets/<cluster-name>/auth/kubeconfig
```

## Prerequisites (deployment host)

- RHEL 9.x  
- OpenShift CLI tools (`./download-openshift-cli.sh`)  
- NMState CLI, Ansible Core + collections from `execution-environment/collections/requirements.yml`  
- Pull secret at `~/pull-secret.json`  

KVM extras: VyOS (manual Cockpit console step), dnsmasq, libvirt/qemu-kvm.

## Why this matters for TNF + LINBIT workshop

| Capability | Workshop use |
|------------|----------------|
| sushy Redfish on KVM | Simulate **STONITH / fencing** labs without physical BMC (Module 3 Track B) |
| Real BMC Redfish/IPMI | Production / customer edge story |
| `deploy-on-kvm.sh` on IBM Cloud host | Safe iteration before metal |
| Declarative `cluster.yml` / `nodes.yml` | Capture TNF fencing credentials + 2-node layout as reusable examples |
| Disconnected / ImageDigestMirrorSet notes | Optional air-gapped edge variants later |

## Gap analysis vs workshop TNF needs

Upstream examples emphasize **SNO, compact (3), HA** — not a first-class “TNF 2-node with fencing” example in the README matrix.

| Need for this workshop | Status in agent-install (from public README) |
|------------------------|-----------------------------------------------|
| OCP **4.22+** ISO generation | Supports 4.15+; validated examples cite 4.20/4.21 — **must add/verify 4.22** |
| Exactly 2 control-plane nodes + fencing | **Not documented as a standard example** — research/adapt install-config + agent config |
| sushy for fencing demos | **Available** on KVM path — good fit |
| Compact 3-node fallback | **Well supported** if TNF ABI example is delayed |
| LINBIT / LINSTOR | **Out of scope** for agent-install (apply via Field Content Helm after install) |

**Implication:** Track B research should fork or add an `examples/tnf-4.22-kvm/` style config (in this repo or a PR to agent-install) with:

- Two masters, zero workers  
- Fencing / BMC blocks pointed at sushy (KVM) or real BMC (metal)  
- Extra disks for LVMThin pools  
- OVN-Kubernetes (required post-4.20)  

Until that exists, Module 0 Track B can use **compact ABI** for LINBIT labs and treat true TNF fencing as a Module 3 stretch once configs land.

## Version boundaries to respect (from upstream)

- **4.19 → 4.20:** disconnected: migrate `imageDigestSources` → `ImageDigestMirrorSet`  
- **4.20 → 4.21:** `OpenShiftSDN` removed; use `OVNKubernetes`  
- Workshop baseline **4.22+** inherits both rules  

## Mapping to Field Content

Do **not** vendor the entire agent-install tree into this repo. Document:

1. Clone agent-install on the IBM Cloud host  
2. Generate/deploy cluster  
3. Point Field Content / Helm (`ocp4_workload_field_content` or manual ArgoCD) at **this** GitHub repo for LINBIT + Showroom  

Optional later: submodule or docs link to a shared `examples/tnf-4.22-*` directory.

## Recommended next validation steps

1. Clone agent-install on this host; run `./e2e-tests/validate_env.sh`  
2. Confirm host capacity for 2× (or 3×) OCP VMs + VyOS  
3. Prove `create-iso` for **4.22** release image  
4. Prototype TNF vs compact `cluster.yml` / `nodes.yml`  
5. Confirm sushy endpoints work with OpenShift fencing credentials format  
