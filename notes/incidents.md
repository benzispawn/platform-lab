# Incidents

## 2026-11-14: Role can list the bucket but cannot read objects

| | |
| --- | --- |
| **Identity** | `assumed-role/platform-lab-s3-reader/lab-test` (assumed by `platform-lab-deployer`) |
| **Bucket** | `platform-lab-771983217432-sa-east-1-an` |
| **Policy** | `arn:aws:iam::771983217432:policy/platform-lab-read-list-bucket` (managed, attached to the role) |

- **Impact:** `platform-lab-s3-reader` could not download `hello.txt`, so the read-only role
  was not usable for its one job.

- **Evidence:**
  - `aws s3 ls s3://platform-lab-771983217432-sa-east-1-an` worked, so `s3:ListBucket` was allowed.
  - `aws s3 cp s3://platform-lab-771983217432-sa-east-1-an/hello.txt -` failed:

    ```text
    download failed: ... An error occurred (403) when calling the HeadObject operation: Forbidden
    ```

  - `aws sts get-caller-identity` confirmed the shell was running as the assumed role, not the user.
  - `list-role-policies` returned nothing, and `list-attached-role-policies` showed one managed
    policy: `platform-lab-read-list-bucket`.

- **Hypothesis:** the action was correct, but the resource was wrong.
  - `s3:ListBucket` is a **bucket-level** action and matches `arn:aws:s3:::<bucket>`.
  - `s3:GetObject` (which also authorizes `HeadObject`) is an **object-level** action and
    matches only `arn:aws:s3:::<bucket>/*`.
  - The policy listed only the bucket ARN, so `GetObject` matched no resource and was
    denied by default. Listing worked because its ARN was present.
  - The bucket policy was ruled out: its only statement is the HTTPS-only deny, and the
    CLI uses HTTPS. Encryption was ruled out too: SSE-S3 needs no KMS permissions.

- **Smallest fix:** add the object ARN to `Resource` and change nothing else, so there are
  no new actions and no wildcards on other buckets:

  ```json
  "Resource": [
    "arn:aws:s3:::platform-lab-771983217432-sa-east-1-an",
    "arn:aws:s3:::platform-lab-771983217432-sa-east-1-an/*"
  ]
  ```

  **Who applied it:** an **admin identity in the AWS Console**, not `platform-lab-deployer`.
  The deployer has no IAM write permissions (see D2 in `decisions.md`), so it *cannot*
  change this policy. That is intended: no privilege-escalation path.

  Console steps: IAM → Policies → `platform-lab-read-list-bucket` → Edit → JSON →
  paste `notes/policies/s3-read-policy.json` → Save. Saving creates a new **default
  version** of the managed policy, and the role picks it up without being reattached.

  CLI equivalent (only with an admin profile; the deployer will get `AccessDenied`):

  ```bash
  aws iam create-policy-version \
    --policy-arn arn:aws:iam::771983217432:policy/platform-lab-read-list-bucket \
    --policy-document file://notes/policies/s3-read-policy.json \
    --set-as-default --profile <admin-profile>
  ```

  Rollback if needed: Console → policy → Policy versions → set the previous version as default
  (CLI: `aws iam set-default-policy-version --version-id <previous> --profile <admin-profile>`).

- **Verification:** run as the assumed role, with no `--profile`:

  ```bash
  aws sts get-caller-identity                                                  # assumed-role/platform-lab-s3-reader
  aws s3 ls s3://platform-lab-771983217432-sa-east-1-an                        # works   (ListBucket)
  aws s3 cp s3://platform-lab-771983217432-sa-east-1-an/hello.txt -            # works   (GetObject)
  aws s3 cp hello.txt s3://platform-lab-771983217432-sa-east-1-an/x.txt        # AccessDenied (no PutObject) ✔
  ```

  The last check matters: the fix must give read access **without** giving write access.

- **Prevention:**
  - For every action, check its **resource type** in the
    [S3 service authorization reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazons3.html):
    bucket actions go on `bucket`, and object actions go on `bucket/*`.
  - Use `Resource` for **what is accessed**, never for who accesses it. The role is
    implied by where the policy is attached.
  - Before applying, run `aws accessanalyzer validate-policy --policy-type IDENTITY_POLICY --policy-document file://...`,
    and test with `aws iam simulate-principal-policy --policy-source-arn <role-arn> --action-names s3:GetObject --resource-arns arn:aws:s3:::<bucket>/hello.txt`.
    Both need permissions the deployer doesn't have, so run them as the admin identity
    (or use the Console's IAM policy editor, which validates JSON, and its Policy Simulator).
  - In Terraform, split it into two statements (bucket actions / object actions) so the mapping
    is explicit and easy to review.
  - Keep a negative test (upload must fail) next to the positive one.

- **Lesson:** a 403 with **some** actions working usually means the action is right but the
  **resource ARN is the wrong type**. Compare what works with what fails, and look at the
  resource type of the failing action.

## Incident #2 (escalation) — 2026-11-14: Deployer policy allowed a path to admin

| | |
| --- | --- |
| **Identity** | `platform-lab-deployer` (IAM user) |
| **Policy** | Deployer's EKS/eksctl permission policy, statement `IAMRolesForClusterAndNodes` |
| **Found by** | Policy review before running eksctl. **Not exploited.** |

- **Impact (potential):** the deployer could make itself an account administrator. That
  breaks D2 in `decisions.md`: the deployer must not create roles, because that leads to
  privilege escalation.

### 1. Found the escalation path

- **Evidence:** the policy granted, on `arn:aws:iam::*:role/platform-lab-*` and `eksctl-*`:
  - `iam:CreateRole` with **no condition**, so the deployer chooses the trust policy.
  - `iam:PutRolePolicy` with **no condition**, so the deployer chooses the inline permissions.
  - `iam:PassRole` to `ec2.amazonaws.com`, and `eks:CreateNodegroup` / `eks:AccessKubernetesApi`.

  The `AttachOnlyEKSManagedPolicies` condition (`iam:PolicyARN` limited to EKS policies) looked
  like a guard, but it only covers **managed** policies. `PutRolePolicy` writes an **inline**
  policy and goes around it.

- **Escalation path:**
  1. `iam:CreateRole` → `platform-lab-pwn`, with a trust policy naming the deployer user
     (the same shape as `notes/policies/trust.json`).
  2. `iam:PutRolePolicy` → inline policy `{"Action": "*", "Resource": "*"}`.
  3. `sts:AssumeRole` into `platform-lab-pwn` → full admin. In the same account, a trust policy
     that names the user directly is enough; the user needs no `sts:AssumeRole` of its own.

  Second path: give a `platform-lab-*` node role admin permissions, create a nodegroup with it,
  then run a pod on the node and read the role's credentials from instance metadata.

- **Root cause:** eksctl needs to create cluster and node roles, so IAM write actions were added
  to the deployer, against D2. Scoping them by **role name** (`platform-lab-*`) limits *which
  roles* can be written, not *what those roles can do*. An identity that can both create a role
  and write its permissions can grant itself anything.

### 2. First fix: a permissions boundary

- Created `platform-lab-boundary` (`notes/policies/platform-lab-boundary.json`) as admin. It
  allowed `eks:*`, `ec2:*`, `ecr:*`, `elasticloadbalancing:*`, `ssm:*`, `logs:*` and similar,
  and denied `iam:*`, `sts:AssumeRole`, `organizations:*`, `account:*`.
- Changed the deployer policy so `CreateRole` / `PutRolePolicy` / `AttachRolePolicy` were allowed
  **only** with `iam:PermissionsBoundary` = that ARN, plus an explicit Deny on removing or editing
  the boundary.
- This stopped the path to **IAM admin**: a created role's effective permissions are
  `inline policy ∩ boundary`, and the boundary has no IAM.

### 3. Review: the boundary was too broad

- A boundary limits **what the role can do**. It does **not** limit **who can assume the role**.
  The `sts:AssumeRole` deny in the boundary only stops the role's own sessions from assuming
  *other* roles. The deployer could still:
  1. create `platform-lab-x` with the boundary and a trust policy naming itself,
  2. put an inline `*:*` policy on it,
  3. assume it, and get everything inside the boundary: `ec2:*`, `ecr:*`, `ssm:*`, ...
- That is far more than the deployer has itself (six `ec2:Describe*` actions, one ECR
  repository). With `ec2:*` and `ssm:*` on the whole account, it could terminate instances, open
  security groups, or run commands on any SSM-managed host, **including prod**.
- So the boundary turned "path to admin" into "path to almost everything except IAM". Still an
  escalation.

### 4. Final fix: removed role creation from the deployer

- Removed `iam:CreateRole` and `iam:PutRolePolicy` from the deployer policy entirely. The
  deployer can no longer create a role or write its permissions, so there is no role it can
  make stronger than itself.
- This matches **D2** as written: roles are created by an admin identity, not by the deployer.
- `platform-lab-boundary` is **kept but unused**. If eksctl later needs to create roles, the
  boundary approach comes back, and the boundary must first be tightened to the actions in the
  AWS-managed EKS policies, not service wildcards.

- **Status:** applied in AWS.

### 5. Verification

```bash
aws iam create-role --role-name platform-lab-esc-test \
  --assume-role-policy-document file://notes/policies/trust.json \
  --profile platform-lab-deployer                                   # AccessDenied ✔

aws iam create-role --role-name platform-lab-esc-test \
  --assume-role-policy-document file://notes/policies/trust.json \
  --permissions-boundary arn:aws:iam::771983217432:policy/platform-lab-boundary \
  --profile platform-lab-deployer                                   # AccessDenied ✔ (boundary no longer opens a door)
```

Both must fail. If the second one works, `CreateRole` is still granted somewhere.

### Prevention

- Treat `iam:CreateRole` + `iam:PutRolePolicy` (or `AttachRolePolicy`, `PassRole`) together as
  an escalation signal in every policy review.
- Name scoping (`platform-lab-*`) is not a security limit on its own.
- When reviewing a boundary, ask two questions: *what can a role inside it do?* and *who can
  assume that role?* The boundary answers only the first.
- When a decision (D2) has to change to unblock a tool, update the decision instead of quietly
  adding permissions.

### Lesson

A permissions boundary grants nothing; it is a ceiling (`identity policies ∩ boundary`). It stops
a created role from reaching IAM, but if the creator can also write the role's trust policy and
assume it, the creator gets **everything up to the ceiling**. The simplest safe fix is to not let
the deployer create roles at all.

## Incident #3 (drift) — 2026-11-15: Terraform state pointed at deleted resources

| | |
| --- | --- |
| **Stack** | `infra/lab` (local state: `infra/lab/terraform.tfstate`) |
| **Resources** | The lab network in `network.tf` (VPC, subnets and related resources) |
| **Cause** | Managed resources deleted by hand in the AWS Console, **twice** |

- **Impact:** `terraform plan` wanted to recreate 12 resources, and the state listed IDs
  that no longer existed in AWS. State and reality no longer matched.

- **Evidence:** the provider returned `InvalidVpcID.NotFound` for the VPC ID stored in state.
  The resource was gone, but Terraform still tracked it.

- **Root cause:** I deleted Terraform-managed resources in the Console, twice. Terraform
  does not see Console changes; it only finds out on the next refresh, so the state kept
  the old IDs.

- **Fix:**
  1. `terraform apply -refresh-only`: reconcile the state with what actually exists, so the
     deleted resources are removed from state. It changes no infrastructure.
  2. `terraform plan` then `terraform apply`: re-create the resources from code.

- **Verification:** `terraform plan` right after the apply shows `No changes`.

- **Prevention:**
  - Change managed resources **only through code**. If something must be removed, remove
    it from the `.tf` files (or `terraform destroy -target=...`), not in the Console.
  - In a team: restrict Console write access for Terraform-managed resources, and run a
    scheduled `terraform plan -detailed-exitcode` to detect drift (exit code `2` = drift).

- **Lesson:** Terraform state is a record, not a live view. Any change made outside
  Terraform turns into drift, and `-refresh-only` is the safe way to see and accept it
  before applying code again.

## Incident #4 (stale lock) — 2026-11-16: State lock not released after a backend permission error

| | |
| --- | --- |
| **Stack** | `infra/lab` (S3 backend: `platform-lab-tfstate-771983217432-sa-east-1-an`, key `lab/terraform.tfstate`) |
| **Locking** | S3 native lockfile (`use_lockfile = true`), lock object `lab/terraform.tfstate.tflock` |
| **Identity** | `platform-lab-deployer` (backend `profile`) |
| **Cause** | Deployer missing an S3 permission on the state bucket, created in `infra/bootstrap` |

- **Impact:** every `plan` / `apply` on `infra/lab` failed with `Error acquiring the state lock`.
  The stack was blocked until the lock was removed by hand. No infrastructure was changed.

- **Evidence:**
  - The run that set up the new backend failed with an `AccessDenied` from S3, and Terraform
    then printed `Error releasing the state lock`.
  - The next run failed with `Error acquiring the state lock` and showed lock info with
    **my own** `Who` (user@host), the `Operation` I had just run, and a `Created` time matching
    that failed run.
  - No other Terraform process was running: no second terminal, no CI pipeline yet (GitHub
    Actions is planned, see D4).

- **Root cause:**
  - With `use_lockfile = true`, Terraform takes the lock by **writing** a `.tflock` object next
    to the state (`s3:PutObject`) and releases it by **deleting** it (`s3:DeleteObject`).
  - The deployer was allowed to create the lock object but not to delete it, so the lock was
    taken, the run failed, and the release also failed. The `.tflock` object stayed in the
    bucket with nothing to remove it. (If `PutObject` had been missing instead, the lock would
    never have been created and nothing would have stayed locked.)
  - The bootstrap created the bucket, but the deployer's S3 permissions were not reviewed
    against what the backend needs.

- **Fix:**
  1. Give the deployer the permissions the S3 backend needs, scoped to this bucket and key:

     ```json
     {
       "Version": "2012-10-17",
       "Statement": [
         {
           "Sid": "TfStateList",
           "Effect": "Allow",
           "Action": "s3:ListBucket",
           "Resource": "arn:aws:s3:::platform-lab-tfstate-771983217432-sa-east-1-an",
           "Condition": { "StringLike": { "s3:prefix": "lab/*" } }
         },
         {
           "Sid": "TfStateReadWrite",
           "Effect": "Allow",
           "Action": ["s3:GetObject", "s3:PutObject"],
           "Resource": "arn:aws:s3:::platform-lab-tfstate-771983217432-sa-east-1-an/lab/terraform.tfstate"
         },
         {
           "Sid": "TfStateLockfile",
           "Effect": "Allow",
           "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
           "Resource": "arn:aws:s3:::platform-lab-tfstate-771983217432-sa-east-1-an/lab/terraform.tfstate.tflock"
         }
       ]
     }
     ```

     `DeleteObject` is only needed on the **lock** object, not on the state itself. The bucket
     is versioned, so state history is kept anyway.

     The permission had to be fixed **first**: `force-unlock` releases the lock the same way
     (by deleting `.tflock`), so without `DeleteObject` it fails with the same `AccessDenied`.

  2. Confirm the lock is mine and no run is active (see the checklist below), then remove it
     with the lock ID from the error message:

     ```bash
     cd infra/lab
     terraform force-unlock <LOCK_ID>
     ```

- **Verification:**

  ```bash
  terraform plan          # runs without a lock error
  aws s3 ls s3://platform-lab-tfstate-771983217432-sa-east-1-an/lab/ \
    --profile platform-lab-deployer   # only terraform.tfstate, no .tflock left after the run
  ```

### When `force-unlock` is safe vs dangerous

`force-unlock` does **not** stop anything. It only deletes the lock record. If a Terraform
process is still running, it keeps running and can now write the state at the same time as
someone else.

**Safe** (all must be true):

- The lock info `Who` is **me** on **this machine**, and `Operation` / `Created` match a run
  that I know failed or was killed.
- That process has really exited: the terminal returned, `ps aux | grep terraform` shows nothing.
- Nothing else can run on this state: no other terminal, teammate, or CI job.
- The cause of the stuck lock is fixed first (here: the missing `DeleteObject`), or the next
  run will leave a new stale lock.

**Dangerous** (do not unlock):

- The lock belongs to **another** person, machine, or CI job. Ask them or check the pipeline
  first. "It has been locked a long time" is not proof it is dead: a big `apply` (EKS, RDS)
  can take 20+ minutes.
- Unlocking just to get past `Error acquiring the state lock` without reading the lock info.
- A lock ID that does not match the error message.
- The original run died **in the middle of an apply**. Unlocking is still the way forward, but
  the state may be out of date: run `terraform plan` (or `apply -refresh-only`) and review it
  before applying anything.

If two runs write the state at the same time, the last write wins. Resources created by the
other run can drop out of state and become orphaned, which is the same kind of problem as
Incident #3, but harder to see.

- **Prevention:**
  - Treat backend permissions as part of the bootstrap: when the state bucket is created, the
    policy for the identity that uses it (deployer now, GitHub OIDC role later) must include
    `ListBucket`, `GetObject` / `PutObject` on the state key, and `DeleteObject` on the `.tflock`.
  - Test a new backend with a harmless command first (`terraform init` then `terraform plan`).
    A permission gap shows up there, before an `apply` holds the lock.
  - Prefer fixing permissions over `-lock=false`. Running without a lock hides this kind of
    problem and removes the protection the lock gives.
  - In CI: one concurrency group per state, so two jobs never run on the same stack together.

- **Lesson:** a lock that cannot be released is almost always a **permissions** problem on the
  lock object, not a Terraform bug. Read the lock info, prove nothing is running, fix the
  cause, and only then `force-unlock`.

## Incident #5 (rollout) — 2026-11-16: `dev` ran 1.0.0, `/version` said 1.3.1, and the new rollout stalled

| | |
| --- | --- |
| **Cluster** | kind `platform-lab`, namespace `dev` |
| **Workload** | Deployment `platform-lab` (2 replicas, RollingUpdate, `maxSurge` / `maxUnavailable` 25%) |
| **Config** | ConfigMap `platform-lab-config` (`k8s/dev/configmap.yaml`) |
| **Cause** | Stale image tag in `k8s/deployment.yaml`, version taken from config instead of the build, and `SIMULATE_READINESS: "0"` on the new rollout |

- **Impact:**
  - `dev` served **1.0.0 code** while the config and `/version` said it was **1.3.1**. Any
    check based on `/version` would have passed for the wrong build.
  - The rollout to the real 1.3.1 image stalled at `1 out of 2 new replicas`. There was **no
    outage**: the two old pods stayed ready and kept serving.

- **Evidence:**
  - `kubectl get rs -n dev` (image, desired, ready, revision):

    ```text
    platform-lab-555c47d8b8   platform-lab:1.0.0   2   2   rev 3   <- serving
    platform-lab-6f84ff588b   platform-lab:1.3.1   1   0   rev 6   <- new, never ready
    ```

  - `kubectl rollout history -n dev deploy/platform-lab --revision=3` → `Image: platform-lab:1.0.0`.
    The committed `k8s/deployment.yaml` (`c678e81`) still had `image: platform-lab:1.0.0`, while
    the ConfigMap had already been changed to `VERSION: "1.3.1"`.
  - A **1.0.0** pod answered `/version` with `{"version":"1.3.1"}`. `src/app.ts` reads
    `process.env.VERSION`, and that env var comes from the ConfigMap, so it reports the config,
    not the code. `package.json` still says `1.0.0`, and the Dockerfile sets no version.
  - New pod events: `Readiness probe failed: HTTP probe failed with statuscode: 503` (x25).
    `/health/ready` returns 503 when `SIMULATE_READINESS` is `"0"`.
  - An old 1.0.0 pod has `SIMULATE_READINESS=0` in its env but still returns `200` on
    `/health/ready`. That image predates the readiness switch, so it ignores the flag.
  - `kubectl rollout status` timed out. Deployment conditions: `Available=True`
    (`MinimumReplicasAvailable`), `Progressing=True` (`ReplicaSetUpdated`).

- **Hypothesis:** three separate faults that hid each other.
  1. **Stale tag.** The image tag in the manifest was not bumped with the release, so
     `kubectl apply` kept deploying 1.0.0. With `IfNotPresent` and a fixed tag, Kubernetes
     does exactly what the manifest says. Nothing pulled a newer image.
  2. **`/version` was not true.** The version came from deploy-time config, not from the
     artifact. Any image paired with that ConfigMap would report `1.3.1`.
  3. **The readiness gate did its job.** The new 1.3.1 pods were not ready (503), so they
     received no Service traffic. With 2 replicas, `maxUnavailable: 25%` rounds **down** to 0
     and `maxSurge: 25%` rounds **up** to 1. The Deployment may add one extra pod but may not
     remove a ready one until a new pod is ready. So the old pods stayed, and the rollout waited.

- **Smallest fix:**
  1. Set `image: platform-lab:1.3.1` in `k8s/deployment.yaml` (done in the working tree).
  2. Set `SIMULATE_READINESS: "1"` in the cluster and in `k8s/dev/configmap.yaml` (they
     must match), then restart, because pods read env values only when they start:

     ```bash
     kubectl apply -f k8s/dev/configmap.yaml
     kubectl rollout restart -n dev deploy/platform-lab
     ```

     Or, to just back out the bad rollout: `kubectl rollout undo -n dev deploy/platform-lab`.
  3. Make `/version` come from the build, not the ConfigMap: pass it at build time
     (`ARG VERSION` → `ENV VERSION=$VERSION` in the Dockerfile,
     `docker build --build-arg VERSION=1.3.1 -t platform-lab:1.3.1 .`), and remove `VERSION`
     from the ConfigMaps so config cannot override it.

- **Verification:**

  ```bash
  kubectl rollout status -n dev deploy/platform-lab              # successfully rolled out
  kubectl get pods -n dev -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image,READY:.status.containerStatuses[0].ready
                                                                  # every pod 1.3.1, ready=true
  kubectl get rs -n dev                                           # old ReplicaSets at 0
  kubectl exec -n dev deploy/platform-lab -- \
    node -e "fetch('http://localhost:3001/version').then(r=>r.text()).then(console.log)"
                                                                  # matches the image tag
  ```

  The check that matters: the **image tag on the pod** and **`/version`** agree, and `/version`
  still tells the truth when the ConfigMap is changed.

- **Prevention:**
  - Never trust `/version` alone. Check what is actually running:
    `kubectl get pods -o jsonpath='{..image}'` (and the image digest in `status.containerStatuses`).
  - Report the version from the artifact: build arg, `package.json`, or the Git SHA. In CI, tag
    images with the commit SHA and set the manifest tag from the pipeline, so the tag cannot be
    forgotten.
  - Keep the readiness probe on every Deployment, and set `maxUnavailable: 0` explicitly so
    a bad release can never take away serving pods.
  - Wait on `kubectl rollout status --timeout=...` after every apply, and treat a timeout as a
    failed deploy (`rollout undo`). Lower `progressDeadlineSeconds` (now 600) so a stuck
    rollout is reported as `ProgressDeadlineExceeded` sooner.
  - Change config **in the file, then apply**. Do not `kubectl edit` live, or the cluster and
    the repo drift apart.

- **Lesson:** a successful `kubectl apply` only means the desired state was accepted. It does not
  mean the right code is running. Check the image the pod actually runs, make the app report a
  version that comes from the build, and rely on readiness plus a rolling update to keep a bad
  release from replacing good pods.
