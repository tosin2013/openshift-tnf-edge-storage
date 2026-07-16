# Workshop Module Outline

**Deliverable:** Showroom-based hands-on lab on a pre-provisioned OpenShift 4.22+ cluster.
**Audience:** Solutions Architects / platform engineers.
**Format:** Students follow guided Showroom AsciiDoc modules. The Helm chart pre-deploys all lab infrastructure via ArgoCD so students focus on exercises, not installation.

## Deployment layers

Cluster provisioning is **outside** this repository. This repo is a field-sourced-content Helm chart that ArgoCD applies **after** the cluster exists.

```mermaid
flowchart TB
  subgraph outside [Outside This Repo]
    AgnosticD["AgnosticD (default: AWS TNA/Compact)"]
    AgentInstall["agent-install (optional advanced: KVM TNF)"]
  end
  subgraph inside [This Repo: Field Content Helm Chart]
    ArgoCD[ArgoCD Application]
    subgraph helm [Helm Components]
      LinstorOp[components/linstor-operator/]
      SC[components/storageclasses/]
      SampleDB[components/sample-database/]
      SampleVM[components/sample-vm/]
      MinIOComp[components/minio/]
      ShowroomDeploy[components/showroom/]
    end
  end
  subgraph showroom [Showroom Lab Modules]
    M1[Module 1: Storage Foundations]
    M2[Module 2: Database Performance]
    M3[Module 3: VM Live Migration]
    M4[Module 4: Resilience Drill]
    M5[Module 5: Disaster Recovery]
  end
  AgnosticD --> ArgoCD
  AgentInstall -.->|optional| ArgoCD
  ArgoCD --> helm
  ShowroomDeploy --> showroom
```

| Layer | Responsibility | Where |
|-------|---------------|-------|
| Cluster provisioning | AWS EC2 + OCP 4.22+ install, EBS volumes, networking | AgnosticD (default) or agent-install (advanced) |
| Lab infrastructure | LINSTOR Operator, StorageClasses, sample workloads, Showroom | This Helm chart via ArgoCD |
| Student experience | Guided hands-on exercises | Showroom AsciiDoc pages |

**Default path:** RHDP catalog orders AgnosticD AWS (TNA or Compact). AgnosticD calls `ocp4_workload_field_content` with `ocp4_workload_field_content_gitops_repo_url` pointing at this repo. ArgoCD deploys the chart. Student opens Showroom and starts Module 1.

**Advanced path (optional):** User brings up OCP 4.22+ TNF cluster on KVM/bare metal via [openshift-agent-install](https://github.com/tosin2013/openshift-agent-install), then applies this chart manually or via ArgoCD. Same Showroom modules, different cluster topology.

## Helm components

One chart with toggleable components. Two values overlays: `values.yaml` (AWS defaults) and `values-tnf.yaml` (KVM/TNF overrides).

| Component | Path | Purpose | `values.yaml` (AWS) | `values-tnf.yaml` |
|-----------|------|---------|----------------------|---------------------|
| linstor-operator | `components/linstor-operator/` | OLM Subscription, `LinstorCluster` CR, `LinstorSatelliteConfiguration` for EBS or local disks | enabled | enabled |
| storageclasses | `components/storageclasses/` | RWO locality class (`WaitForFirstConsumer`), Virt block-RWX class (`allow-two-primaries`) | enabled | enabled |
| sample-database | `components/sample-database/` | PostgreSQL StatefulSet on LINSTOR RWO class for Module 2 benchmarks | enabled | enabled |
| sample-vm | `components/sample-vm/` | VM disk PVC (block mode) for Module 3 live migration | enabled | enabled |
| minio | `components/minio/` | S3-compatible endpoint for DR snapshots when AWS S3 is unavailable | disabled | enabled |
| showroom | `components/showroom/` | Showroom Deployment + AsciiDoc lab content | enabled | enabled |

### RHDP integration labels

```yaml
# On the ArgoCD Application -- health monitoring
metadata:
  labels:
    demo.redhat.com/application: "linbit-edge-storage"

# On a ConfigMap -- data passback to RHDP catalog
metadata:
  labels:
    demo.redhat.com/userinfo: ""
data:
  showroom_url: "https://showroom.apps.{{ .Values.cluster_domain }}"
  sample_db_connection: "postgresql://demo:demo@sample-db.linbit-workshop.svc:5432/workshop"
  msg: "LINBIT Edge Storage Workshop ready"
```

AgnosticD Pipeline A provides core cluster data (API URL, ingress domain, admin credentials). Pipeline B (the ConfigMap above) provides workload-specific data that only exists after ArgoCD deploys the chart.

## Showroom lab modules

Students work on an already-deployed cluster. Helm has pre-installed LINSTOR, StorageClasses, sample workloads, and Showroom. Each module is a Showroom AsciiDoc page with concrete terminal commands and verification steps.

### Module 1 -- Storage Foundations (30 min)

**What students learn:** How LINSTOR/DRBD control and data planes are structured; what a storage pool, diskful replica, and diskless tiebreaker look like on a running cluster.

**Hands-on steps:**

1. Verify LINSTOR pods are running: `oc get pods -n linbit-sds`
2. Inspect satellites and storage pools: `linstor node list`, `linstor storage-pool list`
3. Examine the pre-created StorageClasses: `oc get sc` -- identify RWO locality and Virt RWX classes
4. Create a test PVC; observe LINSTOR provision a DRBD resource: `linstor resource list`
5. Identify diskful vs diskless resources (on AWS: diskless tiebreaker on arbiter; on TNF: two diskful peers)
6. Delete the test PVC; confirm cleanup

**Exit criteria:** Student can describe control/data plane separation and point to where replicas live.

### Module 2 -- Database Locality and Performance (45 min)

**What students learn:** How `WaitForFirstConsumer` guarantees data locality; how in-kernel DRBD delivers near-bare-metal read IOPS.

**Hands-on steps:**

1. Examine the pre-deployed PostgreSQL StatefulSet and its PVC
2. Confirm PVC is bound to the same node as the pod: `oc get pvc -o wide`, `linstor resource list`
3. Run `pgbench` inside the database pod to generate I/O load
4. Observe read latency (local NVMe/EBS) vs write latency (network round-trip to replica)
5. Create a second StorageClass with 3-way replication (`placementCount: 3`); deploy a second database instance
6. Compare benchmark results between 2-way and 3-way replication

**Exit criteria:** Student has empirical latency numbers showing local-read advantage and can explain the `WaitForFirstConsumer` mechanism.

### Module 3 -- VMware Exit: VM Live Migration (45 min)

**What students learn:** How block-level RWX via `allow-two-primaries` enables zero-downtime VM migration without NFS.

**Hands-on steps:**

1. Confirm OpenShift Virtualization Operator is running
2. Examine the pre-created VM disk PVC (block mode, Virt RWX StorageClass)
3. Start the VM from the OpenShift console; verify it boots and is accessible
4. Trigger live migration from the console (or `virtctl migrate`)
5. Observe DRBD dual-primary window: both source and destination nodes hold the volume open
6. Verify the `vm.kubevirt.io/name` label gate prevented non-VM pods from using block RWX
7. Confirm VM is running on the destination node with no downtime

**Exit criteria:** Student has performed a live migration and can explain the dual-primary safety model.

### Module 4 -- Resilience Under Failure (30 min)

**What students learn:** How DRBD quorum + cluster HA prevent data loss during node failure.

**Hands-on steps (AWS default):**

1. Identify the diskless tiebreaker resource on the arbiter node: `linstor resource list`
2. Cordon or drain one primary node: `oc adm cordon <node>`
3. Observe: etcd quorum holds (arbiter votes), DRBD volume stays quorate (diskful + diskless = 2/3 majority)
4. Verify workloads reschedule to the surviving primary
5. Uncordon the node; watch DRBD resync
6. Discuss: this is the TNA model -- arbiter provides quorum cheaply without a third full data copy

**Hands-on steps (TNF advanced -- optional Showroom page):**

1. Review fencing credentials in the cluster (sushy URLs on KVM, BMC endpoints on bare metal)
2. Block network between the two nodes (or use sushy API to power off one node)
3. Observe Pacemaker trigger STONITH via Redfish
4. Confirm the surviving node resumes all workloads and DRBD volumes
5. Restore the fenced node; watch cluster reconverge

**Exit criteria:** Student has seen a node failure and verified storage + workload continuity.

### Module 5 -- Geographic Disaster Recovery (45 min)

**What students learn:** How LINSTOR ships crash-consistent snapshots to S3 with incremental block deltas.

**Hands-on steps:**

1. Create a LINSTOR encryption passphrase: `linstor encryption create-passphrase`
2. Define an S3 remote target (AWS S3 bucket on default track; pre-deployed MinIO on TNF)
3. Create a `VolumeSnapshotClass` referencing the LINSTOR S3 remote
4. Take a snapshot of the database PVC
5. Write new data to the database; take a second snapshot
6. Verify the second snapshot shipped only incremental deltas (discuss block-level efficiency)
7. Discussion: restoring from S3 into a second cluster for full DR

**Exit criteria:** Student has taken incremental snapshots and understands the delta-only shipping model.

## Advanced / optional content (not in core lab)

| Content | Format | Notes |
|---------|--------|-------|
| TNF cluster bring-up | Separate linked guide | Points to [openshift-agent-install](https://github.com/tosin2013/openshift-agent-install); for users who want to run the lab on KVM/bare metal |
| NFS RWX (Ganesha) | Optional Showroom page | LINSTOR Operator v2+ NFS server failover; not in core five modules |
| Federated migration | Architecture doc only | `externalController` cross-cluster; stretch for day-2 workshop |

## RHDP catalog and data flow

```mermaid
flowchart LR
  Catalog[RHDP Catalog] -->|orders| AgnosticD
  AgnosticD -->|provisions OCP 4.22+ AWS| Cluster
  AgnosticD -->|"ocp4_workload_field_content"| ArgoCD
  ArgoCD -->|deploys this Helm chart| HelmChart[Helm Components]
  HelmChart -->|"demo.redhat.com/application"| HealthCheck[RHDP Health Monitoring]
  HelmChart -->|"demo.redhat.com/userinfo ConfigMap"| DataPassback[RHDP Catalog Display]
  DataPassback --> Student[Student sees: Showroom URL + credentials]
```

- **Catalog item:** "LINBIT Edge Storage Workshop" -- single entry, AWS TNA/Compact default
- **Health tracking:** ArgoCD Application labeled `demo.redhat.com/application: "linbit-edge-storage"`
- **Data passback:** ConfigMap labeled `demo.redhat.com/userinfo: ""` carries Showroom URL, API URL, sample-db connection string to RHDP catalog for student display
- **Student access:** Showroom terminal + OpenShift web console via RHDP-provided credentials
- **Showroom attributes:** `cluster_domain`, `api_url`, `admin_password` injected into Antora from AgnosticD userinfo (Pipeline A)

## Learning outcomes (summary)

By completing this lab, students will be able to:

1. Describe LINSTOR/DRBD architecture and why it outperforms Ceph/ODF at the edge
2. Configure and benchmark topology-aware StorageClasses for database locality
3. Perform zero-downtime VM live migration using block-level RWX
4. Demonstrate cluster resilience under node failure with DRBD quorum
5. Execute incremental S3 snapshot shipping for geographic disaster recovery
