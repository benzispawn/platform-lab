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
