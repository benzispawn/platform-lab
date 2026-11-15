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
