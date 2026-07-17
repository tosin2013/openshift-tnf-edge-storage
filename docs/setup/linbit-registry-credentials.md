# LINBIT registry credentials (OpenShift workshop)

This workshop installs **LINBIT SDS on OpenShift** via the LINSTOR Operator and container images from `drbd.io`. Credentials are your **[LINBIT Customer Portal](https://my.linbit.com/)** email and password — used to create the in-cluster pull secret `drbdiocred`.

They are **not** a separate API key, and you do **not** run `linbit-manage-node.py` on OpenShift nodes for this workshop.

## How LINBIT is installed on OpenShift (this repo)

1. AgnosticD provisions the OpenShift cluster.
2. Workloads install OpenShift GitOps, then Field Content points ArgoCD at this repo’s Helm chart.
3. ArgoCD syncs `helm/components/linstor-operator/`:
   - OLM `Subscription` for `linstor-operator` (OperatorHub / `certified-operators`)
   - Docker registry secret `drbdiocred` (from `linbit_registry_*`)
   - `LinstorCluster` and `LinstorSatelliteConfiguration` CRs
4. The operator pulls images from `drbd.io` and runs controller, satellites, and CSI.
5. StorageClasses are applied from the same chart.

Wiring:

- Helm: `helm/components/linstor-operator/`
- Student vars: `agnosticd/vars/student/linbit-student.yaml` (passes portal creds into Field Content Helm values)
- App-of-apps: `helm/templates/applications.yaml`

## What you need

| Item | Value |
|------|--------|
| Portal | [https://my.linbit.com/](https://my.linbit.com/) |
| Username | Portal **email** |
| Password | Portal password (create or reset on my.linbit.com if needed) |

### Get or set your portal password

1. Open [https://my.linbit.com/](https://my.linbit.com/).
2. Log in with the email LINBIT associated with your account.
3. If you do not have a password yet, use **Reset password?** / create a password on the portal (LINBIT’s onboarding mail describes this).

If you have **no** Customer Portal account at all, contact LINBIT for evaluation access ([contact](https://linbit.com/contact-us/) / sales). That is only needed when you are not already set up in their system.

## Wire credentials into this workshop

### Recommended: `make setup`

Interactive onboarding prompts for your my.linbit.com email and password and writes them into AgnosticD `secrets.yml` as `linbit_registry_username` / `linbit_registry_password` (never into `agnosticd/config.yml`).

```bash
make setup
# or: ./bootstrap.sh
```

If credentials are already set, setup offers to keep or update them. Non-interactive runs (`--non-interactive`) do not prompt; edit the file manually or re-run setup interactively.

### Manual edit

Default path:

`$AGNOSTICD_ROOT/../agnosticd-v2-secrets/secrets.yml`

```yaml
linbit_registry_username: you@example.com
linbit_registry_password: your-portal-password
```

Replace any `<Your LINBIT ...>` placeholders. Do not commit real passwords to git.

Confirm readiness:

```bash
make check
```

`make deploy` / `./agnosticd/deploy.sh` **hard-fail** if these values are missing or still look like placeholders. See `onboard.yml` validation and the preflight in `agnosticd/deploy.sh`.

### Verify against the registry (recommended)

Use the same email and password:

```bash
podman login drbd.io
# or: docker login drbd.io
```

Optional smoke pull (if your account allows):

```bash
podman pull drbd.io/drbd-utils
```

Official guidance: registry login uses Customer Portal credentials — see the [DRBD User Guide](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/) and [LINSTOR User Guide](https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/) sections on LINBIT Docker images / `drbd.io`.

## If LINBIT emailed you about `linbit-manage-node.py`

LINBIT’s default mail (also on [packages.linbit.com](https://packages.linbit.com/)) often says:

```bash
cd /tmp && curl -O https://my.linbit.com/linbit-manage-node.py && chmod u+x linbit-manage-node.py
./linbit-manage-node.py
```

That script registers a **Linux host** and configures **yum/apt** package repositories (RHEL/SLES/Debian bare metal or VMs). It is **not** how this OpenShift workshop installs SDS. You can ignore that path for AgnosticD / OCP deploy.

Same portal email and password apply if you later use manage-node elsewhere. For non-interactive host registration, the upstream script accepts `LB_USERNAME`, `LB_PASSWORD`, and either `LB_CLUSTER_ID` or `LB_REPOS` (see the script header / env handling). This repository does **not** run that on OpenShift nodes.

## After you fill in credentials

- New deploys pick up `linbit_registry_*` via Field Content Helm values.
- Clusters already deployed with empty/placeholder secrets may need a student workload re-apply or a manual refresh of `drbdiocred` before LINSTOR image pulls succeed.

## References

- [LINBIT Customer Portal](https://my.linbit.com/)
- [LINBIT package repository instructions](https://packages.linbit.com/) (manage-node context)
- [DRBD User Guide — customer repos and Docker registry](https://linbit.com/drbd-user-guide/drbd-guide-9_0-en/)
- [LINSTOR User Guide — containers / drbd.io](https://linbit.com/drbd-user-guide/linstor-guide-1_0-en/)
- [Air-gapped K8s + drbd.io credentials](https://linbit.com/blog/deploying-linbit-sds-in-an-air-gapped-kubernetes-cluster/)
