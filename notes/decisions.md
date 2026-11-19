# Decisions

- **Budget Alert** is create with the name of `Platform Lab mOnthly Cost Budget`;
- I choose access key for simplicity but the safest is to use SSO

> Before changing infrastructure, I verify the account, region, execution identity, and expected impact.

## Lab environment (verified 2026-11-14)

| Item | Value | How verified |
|---|---|---|
| Account | `771983217432` | `aws sts get-caller-identity --profile platform-lab-deployer` |
| Region | `sa-east-1` | `aws configure get region --profile platform-lab-deployer` |
| CLI profile | `platform-lab-deployer` | — |
| Identity | `arn:aws:iam::771983217432:user/platform-lab-deployer` (IAM user) | `get-caller-identity` |
| Bucket | `platform-lab-771983217432-sa-east-1-an` | `get-bucket-location` → `sa-east-1` |
| Required tags | `Project=platform-lab`, `Owner=benzi` | `get-bucket-tagging` |
| Budget alert | TODO: confirm it exists (deployer user can't read Billing) | Console → Billing → Budgets |

## D1: IAM user with access keys for the lab CLI

- **Decision:** use the IAM user `platform-lab-deployer` with an access key for CLI work.
- **Trade-off:** long-lived keys don't expire. If leaked, they work until someone rotates
  or deletes them. Temporary credentials (SSO, or assuming a role) expire on their own.
- **Mitigations:** narrow permissions (the user can't even list IAM roles or buckets),
  the key is never committed (only `~/.aws/credentials`), and I delete the key at cleanup.
- **In CI:** no keys at all. GitHub Actions gets temporary credentials through OIDC (Nov 18).
- **TODO (my words):** why I didn't use the SSO session for this lab.

## D2: Who creates IAM roles

- **Decision:** the deployer user does **not** create IAM roles. An admin identity creates them.
- **Why:** an identity that can run `iam:CreateRole` + `iam:PutRolePolicy` can grant itself
  any permission (privilege escalation). The deployer should only use what it was given.
- Which identity **creates** the repository?
  - **Answer:** First step is to use platform-lab-deployer then we'll need a role for this one to be used inside the github actions
- Which identity **pushes** Images? Will it be the deployer user, a new role, or later a GithubOIDC role?
  - **Answer:** Yes, same here. First we use the platform-lab-deployer and than we create a role related to GithubOIDC.

## D3: Bucket policy denies non-HTTPS

- **Decision:** add a `DenyInsecureTransport` bucket policy (not required by the plan).
- **Why:** an explicit Deny beats any Allow, so no identity can access the bucket over plain HTTP.

## D4: Stablishing Terraform
- **Decision:** maintain bucket and file object and ECR. VPC was delete with all the subnets, IGW, etc
- For this moment we are using `platform-lab-deployer` but in near future for deployment in Github Actions we'll use Github OIDC
- I'm not going to use `map_public_ip_on_launch`because of the cost
- We'll keep **10.0.0.0/20** because we don't to much IPs for this lab

## Budgets are not a spending cap

A budget alert only **notifies** (email when the threshold is reached). It does not stop
resources or block spending. Cleanup and tags are what actually control cost.

## D7: Terraform apply

- **Separate workflow** `terraform-apply.yml`, triggered by `workflow_dispatch` or `push` to main.
- **Environment `infra`** with a required reviewer. The OIDC sub becomes
  `repo:benzispawn/platform-lab:environment:infra`, and only a separate apply role trusts it.
  The plan role cannot apply.
- **concurrency:** `group: tfstate-lab`, `cancel-in-progress: false`. A cancelled apply can
  leave a held lock or partially applied infra.
- **Flow:** checkout the triggering SHA → plan -out=tfplan (with lock) → reviewer approves
  → apply that tfplan in the same run. Never a plan file from another run or commit.
- **Why not reuse an old plan:** <your answer>
