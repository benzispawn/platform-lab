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
  breaks D2 in `decisions.md`, which says the deployer must not be able to create roles,
  because that leads to privilege escalation.

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

- **Root cause:** eksctl needs to create the cluster and node roles, so IAM write actions were
  added to the deployer. Scoping them by **role name** (`platform-lab-*`) limits *which roles*
  can be written, not *what those roles can do*. Any identity that can both create a role and
  write its permissions can grant itself anything.

- **Fix:** a **permissions boundary**.
  - New managed policy `platform-lab-boundary` (`notes/policies/platform-lab-boundary.json`),
    created by an **admin identity**. It is a ceiling: it allows only the services EKS clusters
    and nodes use, and **denies** `iam:*`, `sts:AssumeRole`, `organizations:*` and `account:*`.
  - Deployer policy (`notes/policies/deployer-policy.json`):
    - `CreateRole`, `PutRolePolicy`, `DeleteRolePolicy`, `DetachRolePolicy` are allowed **only if**
      `iam:PermissionsBoundary` equals the `platform-lab-boundary` ARN.
    - `AttachRolePolicy` needs **both** the boundary and the EKS-only `iam:PolicyARN` list, in
      one statement (two separate Allows would be OR-ed and lose the EKS-only rule).
    - Explicit **Deny** on `DeleteRolePermissionsBoundary`, `PutRolePermissionsBoundary`,
      `UpdateAssumeRolePolicy`, `CreatePolicyVersion`, `SetDefaultPolicyVersion`, `DeletePolicy`,
      so the boundary cannot be removed or edited.
    - Account wildcards `arn:aws:iam::*:` replaced by `771983217432`.
  - eksctl config sets `iam.serviceRolePermissionsBoundary` and
    `managedNodeGroups[].iam.instanceRolePermissionsBoundary`, so the roles CloudFormation
    creates carry the boundary.

  Result: the deployer can still create `platform-lab-pwn` with `*:*`, but the role's effective
  permissions are `inline policy ∩ boundary`, so no IAM and no role assumption.

- **Status:** fix written, **not yet applied**. Apply order: an admin creates the boundary first,
  then updates the deployer policy.

- **Verification** (after applying):

  ```bash
  # 1. Without the boundary → must fail
  aws iam create-role --role-name platform-lab-esc-test \
    --assume-role-policy-document file://notes/policies/trust.json \
    --profile platform-lab-deployer                                   # AccessDenied ✔

  # 2. With the boundary → allowed
  aws iam create-role --role-name platform-lab-esc-test \
    --assume-role-policy-document file://notes/policies/trust.json \
    --permissions-boundary arn:aws:iam::771983217432:policy/platform-lab-boundary \
    --profile platform-lab-deployer                                   # works

  # 3. Removing the boundary → must fail
  aws iam delete-role-permissions-boundary --role-name platform-lab-esc-test \
    --profile platform-lab-deployer                                   # AccessDenied ✔

  # 4. Even with *:* inline, IAM is blocked (run as admin)
  aws iam simulate-principal-policy \
    --policy-source-arn arn:aws:iam::771983217432:role/platform-lab-esc-test \
    --action-names iam:CreateUser iam:AttachUserPolicy --profile <admin-profile>  # implicitDeny/explicitDeny ✔

  # Clean up
  aws iam delete-role --role-name platform-lab-esc-test --profile platform-lab-deployer
  ```

- **Follow-up:** the boundary still allows `ec2:*`, `ssm:*` and similar. A role the deployer
  creates can reach everything inside it, which is more than the deployer itself has. Tighten the
  boundary to the actions in the AWS-managed EKS policies.

- **Prevention:**
  - Treat `iam:CreateRole` + `iam:PutRolePolicy` (or `AttachRolePolicy`, `PassRole`) together as
    an escalation signal in every policy review.
  - Name scoping (`platform-lab-*`) is not a security limit on its own. Add a **boundary condition**
    whenever an identity can create or change other identities.
  - When a decision (D2) has to change to unblock a tool, update the decision instead of quietly
    adding permissions.

- **Lesson:** a permissions boundary grants nothing. It is a ceiling: effective permissions are
  `identity policies ∩ boundary`. It is the safe way to let a deployer create roles: whatever it
  creates can never be stronger than the boundary.
