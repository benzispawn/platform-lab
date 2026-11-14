# John Deere platform interview: hands-on practice plan

**November 13â€“20, 2026 Â· 20 hours total Â· working assumptions: 2 hours weekdays, 4 hours Saturday/Sunday.**

Goal: configure, validate, troubleshoot, and explain a small delivery platform with less dependence on generated code. This is preparation tailored to the platform discussion, not a claim about John Deere's actual assessment.

## One project for the week

Build a tiny Node.js service named `platform-lab`. Use your familiar TypeScript stack, but keep application work below 30 minutes. Provide `GET /health/live`, `GET /health/ready`, and `GET /version`; readiness should support a configurable simulated dependency failure. Include one automated HTTP test. Follow a red â†’ green cycle for that test.

Two related deployment tracks:

- Local Kubernetes: Docker image â†’ kind cluster â†’ Deployment â†’ Service, with configuration, health checks and rollout recovery.
- AWS: Terraform â†’ private S3 bucket, ECR repository, IAM roles and a small VPC exercise. GitHub Actions authenticates with OIDC and pushes an image to ECR.

These tracks meet at the container image. You do not need to run EKS to complete the core plan. A local cluster does not automatically authenticate to private ECR; use `kind load docker-image` for the core local exercise. Treat EKS networking, workload identity and image pulling as a separate architecture discussion.

Suggested repository layout:

```text
app/
k8s/base/
infra/bootstrap/
infra/lab/
.github/workflows/
notes/decisions.md
notes/incidents.md
```

## Working method

For a two-hour session: 10 min recall, 15 min official documentation, 60 min building, 20 min deliberate failure and recovery, 15 min explanation and notes. On weekend sessions add 90 min implementation and 30 min repeat-from-blank practice.

Start each configuration from memory for 15 minutes. Then consult documentation. If blocked for 10 minutes, ask AI for a hint or error explanation. Close the generated answer and rewrite the relevant configuration yourself. Record the error, evidence, fix and verification. Practice explaining in English; syntax recall is secondary to reasoning and verification.

## Schedule

| Date | Time | Focus | Evidence of completion |
|---|---:|---|---|
| Fri Nov 13 | 2h | Setup, baseline, small service | Image runs locally; test passes; AWS caller identity confirmed |
| Sat Nov 14 | 4h | AWS configuration and networking | Private bucket; ECR; least-privilege role; VPC and route explanation |
| Sun Nov 15 | 4h | Terraform foundations and state | Reproducible infrastructure; saved plan; clean second plan; drift recovered |
| Mon Nov 16 | 2h | Kubernetes workload configuration | Two ready replicas; Service responds; ConfigMap injected |
| Tue Nov 17 | 2h | Kubernetes troubleshooting | Broken selector, image and readiness diagnosed; failed rollout recovered |
| Wed Nov 18 | 2h | GitHub repository and Actions | Required CI check; PR validation; OIDC role; image pushed to ECR |
| Thu Nov 19 | 2h | Integration and platform incidents | Rehearsed release procedure; Terraform PR plan; three timed incidents |
| Fri Nov 20 | 2h | Mock pair programming and review | Timed configuration task; verbal design review; remaining gaps listed |

If the interview is early on November 20, finish the mock on November 19 and use the final morning only for a 20-minute review.

## November 13 â€” Setup and baseline

1. Prepare Git, Node.js, Docker, AWS CLI v2, Terraform, kubectl and kind. Use compatible stable versions; record them in your README instead of updating tools midweek.
2. Create the repository and tiny service. Write one failing health endpoint test, implement it, then build a container. Bind the HTTP server to `0.0.0.0`.
3. Configure a dedicated AWS sandbox profile using temporary credentials where available. Run `aws sts get-caller-identity --profile platform-lab` and verify the account before any changes.
4. Configure a budget alert and resource tags such as `Project=platform-lab` and `Owner=<your-name>`. Budget alerts notify; they are not a hard spending cap.
5. Baseline exercise: spend 15 minutes writing a Deployment and a Terraform S3 resource without AI. Keep the result for comparison on November 20.

**Pass:** container health endpoint responds, automated test passes, and you can explain the Docker build context, container port and AWS identity.

**English prompt:** â€œBefore changing infrastructure, I verify the account, region, execution identity, and expected impact.â€

## November 14 â€” AWS configuration

Use the console to inspect configurations and CLI commands to verify them. Terraform will reproduce the resources on Sunday; create resources in Terraform from the start or remove manually created equivalents before Terraform creates its own. Do not accidentally manage the same resource twice.

### Core lab

- S3: create a uniquely named bucket; enable Block Public Access, encryption and versioning. Upload and retrieve one harmless text object.
- IAM: write a policy scoped to that bucket. Distinguish bucket-level `s3:ListBucket` permissions from object-level `s3:GetObject` permissions. Distinguish role trust from permissions to act after assuming the role.
- ECR: create a repository, enable image scanning as appropriate, configure a lifecycle policy, push an image tagged with its Git commit SHA. Explain tag versus digest.
- Networking: configure a VPC, public subnet, internet gateway and route table association. Sketch a private subnet and explain its egress options. A route alone does not give an EC2 instance public connectivity; address assignment and security controls also matter.
- Observability: inspect a CloudWatch log group, retention settings and an alarm configuration. Explain CloudWatch operational telemetry versus CloudTrail API auditing.

### Break and repair

Remove object-read permission from a lab role. Attempt the read using that identity, identify the denied action/resource, and restore the narrow permission. Do not solve it with AdministratorAccess.

**Pass:** explain how you verified bucket privacy, which identity pushed the image, and why a private subnet is different from a security group.

**Stretch only:** configure Lambda execution-role logging and invoke a tiny function. Avoid spending the session building another application.

## November 15 â€” Terraform

### Build

1. Write `versions.tf`, `providers.tf`, `variables.tf`, `main.tf` and `outputs.tf` yourself. Configure the AWS profile locally; do not embed credentials.
2. Manage the lab bucket settings, ECR repository and networking exercise. Use variables for project and region, common tags, and outputs for repository URL and bucket name.
3. Run `terraform fmt -check`, `terraform init`, `terraform validate`, `terraform plan -out=lab.tfplan`, inspect it, then `terraform apply lab.tfplan` in the sandbox.
4. Run a second plan and expect no changes. Commit `.terraform.lock.hcl`; ignore `.terraform/`, state files, credential files and saved plans. State and plan files may contain sensitive values.
5. Create a separate bootstrap configuration for a private, encrypted, versioned S3 state bucket. Configure the lab backend with a distinct key and `use_lockfile = true`, then migrate state using `terraform init -migrate-state`. The backend bucket must exist before backend initialization. Configure the required state-object and lock-file permissions.
6. Explain variables, outputs, data sources, implicit dependencies and when explicit `depends_on` is justified. Extract one small module only after the root configuration works.

### Break and repair

Change an ECR lifecycle setting outside Terraform, inspect the drift in `plan`, and restore the declared configuration. In the sandbox, try concurrent state-changing operations to observe locking. Never force-unlock an active operation.

**Pass:** rebuild the small resource set, explain the plan before applying, get a clean second plan, and describe how state differs from source code.

**Recall:** `init` initializes providers/backend; `validate` checks configuration; `plan` proposes changes against state and refreshed resources; `apply` executes changes. Validation alone does not prove permissions or runtime correctness.

## November 16 â€” Kubernetes configuration

1. Create a disposable cluster with `kind create cluster --name platform-lab`.
2. Build an explicitly versioned local image and load it with `kind load docker-image platform-lab:dev --name platform-lab`. Use an image pull policy compatible with local loading.
3. Write a Namespace, Deployment with two replicas, ClusterIP Service and ConfigMap. Match Service selectors to Pod labels and match `targetPort` to the actual listening port.
4. Add CPU/memory requests and limits, readiness and liveness probes; consider a startup probe if startup is slow. Readiness controls traffic eligibility; liveness can restart a container; startup probes gate the other probes during startup.
5. Add a non-root security context where the image supports it. Explain that Kubernetes Secret data encoded in base64 is not encryption. Use dummy data only.
6. Apply the manifests, inspect rollout status, and test using port forwarding. If configuration is injected as environment variables, change it and trigger a new rollout to observe the updated value.

Useful commands to recall:

```bash
kubectl config current-context
kubectl -n platform-lab get deploy,pods,svc
kubectl -n platform-lab describe pod <pod-name>
kubectl -n platform-lab logs <pod-name>
kubectl -n platform-lab get events --sort-by=.metadata.creationTimestamp
kubectl -n platform-lab rollout status deployment/platform-lab
kubectl -n platform-lab port-forward svc/platform-lab 8080:80
```

**Pass:** two ready replicas, successful HTTP response and an explanation of requests versus limits, Deployment versus Pod, and Service versus Ingress. Ingress requires a controller; it is optional for this lab.

## November 17 â€” Kubernetes failure drills

Spend approximately 15 minutes on each drill, including recovery:

| Injected failure | Evidence to inspect | Successful recovery |
|---|---|---|
| Service selector differs from Pod labels | Service selectors, Pod labels, EndpointSlices | Ready endpoints appear and requests succeed |
| Deployment references a nonexistent image | Pod events, image reference, registry access | Correct image starts |
| Readiness path returns 404 | Probe configuration, events, application routes | Pod becomes ready |
| Application exits at startup | Container logs and `logs --previous`, exit reason | Stable running container |
| Requests exceed available cluster resources | Pending Pod events and node capacity | Scheduler places Pod after correction |

Then deploy a deliberately bad version, inspect rollout status and use `kubectl rollout undo deployment/platform-lab -n platform-lab`. Confirm health after rollback and update the declarative manifest to the intended version so the next apply does not restore the bad image.

Explain why a downstream outage often belongs in readiness rather than liveness: restarting every application replica may worsen an external failure. Review Namespace-scoped Role/RoleBinding, ServiceAccount, `kubectl auth can-i`, HPA prerequisites and NetworkPolicy enforcement requirements. Implement RBAC if time remains; leave HPA and NetworkPolicy as explanation exercises.

**Pass:** diagnose three failures within 10 minutes each, using evidence before changing configuration.

## November 18 â€” GitHub configuration and CI/CD

### Repository settings

- Protect `main` using an available branch protection rule or ruleset: PRs, required CI status check, no force pushes. Some controls depend on repository visibility and GitHub plan; document unavailable controls.
- Add CODEOWNERS for infrastructure and workflows. Distinguish code ownership from enforced owner review.
- Use repository/environment variables for non-sensitive settings and secrets only where needed. Do not commit AWS access keys.

### Workflow to write

1. On pull request: checkout, set up Node, `npm ci`, test, container build, Terraform format and validation. Use `terraform init -backend=false` for validation that should not access remote state.
2. On trusted main-branch push: run tests again, authenticate to AWS with GitHub OIDC, log into ECR, build and push the image tagged with the commit SHA.
3. Set `contents: read` and grant `id-token: write` only to the AWS-authentication job. Restrict IAM trust to the intended repository and branch or environment, plus audience `sts.amazonaws.com`. Environment-based subjects differ from branch-based subjects.
4. Scope role permissions to required ECR operations. Some authentication operations require `Resource: "*"`; keep repository operations scoped appropriately.
5. Configure concurrency and a timeout. Pin external actions to reviewed full commit SHAs when hardening the workflow.

**Break and repair:** use a mismatched OIDC subject, inspect the assumption failure, fix trust, then verify the assumed identity. Separately remove ECR push permission to distinguish authentication success from authorization failure.

**Pass:** a failing test blocks CI, a correct main push produces a SHA-tagged ECR image, and you can explain event â†’ job â†’ step â†’ runner â†’ role assumption.

## November 19 â€” Integration and incidents

Core outcome: document and rehearse CI â†’ ECR image â†’ controlled deployment â†’ health verification â†’ rollback. For the local deployment, build/load the matching image locally; a GitHub-hosted runner cannot directly reach your laptop's kind cluster.

Add an authenticated Terraform plan job for a trusted same-repository PR or a manually dispatched sandbox workflow. Separate the apply job, serialize changes to the same state, and require explicit approval where the repository supports protected environments. Never run untrusted fork code with deployment credentials or use `pull_request_target` to execute untrusted PR code.

Do not blindly apply an old plan: establish which commit and state it targets. Secure saved plans and limit retention.

Timed incidents, 10 minutes each:

1. Pipeline can assume its role but ECR push is denied.
2. Deployment is available but Service requests fail.
3. Terraform cannot acquire a state lock while another run is active.

For each, say: impact â†’ evidence â†’ hypothesis â†’ smallest fix â†’ verification â†’ prevention. Finish by drawing EKS control plane, worker nodes, subnets, load balancer, workload IAM identity, logs and registry. Explain cluster access separately from AWS IAM role permissions. EKS deployment is optional and outside the core time budget.

**Pass:** explain the full delivery path in five minutes and demonstrate a verified rollback.

## November 20 â€” Mock pair programming

Use documentation, but disable AI during the timed mock. Ask the interviewer clarifying questions before coding.

- 0â€“10 min: clarify acceptance criteria, inspect repository and explain your plan.
- 10â€“35 min: write a Terraform private S3 configuration with tags and outputs. Run format and validation; explain the intended plan.
- 35â€“60 min: write a Kubernetes Deployment and Service with probes and resources; diagnose one broken selector.
- 60â€“80 min: write a GitHub workflow outline and explain AWS OIDC trust and permissions.
- 80â€“100 min: troubleshoot one IAM denial and one failed rollout aloud.
- 100â€“115 min: architecture questions: release safety, state locking, private networking, observability and rollback.
- 115â€“120 min: list your three remaining gaps and the evidence you would seek next.

### Self-scoring

Score each area 0â€“2: 0 = cannot complete; 1 = complete with substantial help; 2 = complete with documentation and explain why. Areas: AWS/IAM, networking, Terraform/state, Kubernetes, GitHub Actions, troubleshooting. Target 9/12 with no zero; this is a practice threshold, not an employer scoring system.

Useful phrases:

- â€œI have used CloudFormation more often; the Terraform workflow here is to inspect the plan and manage changes through versioned configuration and state.â€
- â€œI do not remember the exact field name. I will verify it in the documentation and validate the configuration.â€
- â€œAuthentication succeeded. I will now check which action and resource the role is authorized to access.â€
- â€œBefore rolling back, I will check rollout status, recent events, and the health of the previous version.â€

## If you fall behind

Prioritize IAM/trust versus permissions, a working Terraform plan/apply cycle, Deployment/Service/probes, one OIDC workflow and failure diagnosis. Defer EKS provisioning, Helm charts, service mesh, advanced modules and multi-account architecture. Keep the app tiny.

## Cleanup

Delete only resources created for this lab, after checking the account, region and Terraform plan. Destroy the lab stack before the backend bootstrap. Versioned S3 buckets may retain object versions/delete markers and ECR may retain images; inspect and remove only lab data if destruction is blocked. Preserve state until cleanup is verified. Delete the local kind cluster when finished. Review remaining resources and billing; do not assume `destroy` removed resources created outside Terraform. NAT gateways, load balancers, EKS and running compute can incur ongoing costs; they are not required by this core plan.

## Official references

- AWS IAM: https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- AWS VPC: https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html
- ECR push: https://docs.aws.amazon.com/AmazonECR/latest/userguide/docker-push-ecr-image.html
- Terraform S3 backend and native locking: https://developer.hashicorp.com/terraform/language/backend/s3
- Terraform CLI: https://developer.hashicorp.com/terraform/cli
- Kubernetes probes: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- Kubernetes Deployments: https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- kind local images: https://kind.sigs.k8s.io/docs/user/quick-start/#loading-an-image-into-your-cluster
- GitHub Actions AWS OIDC: https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws

Prepared November 13, 2026. This is a practice guide; no infrastructure was provisioned and the exercises have not been executed on your account.
