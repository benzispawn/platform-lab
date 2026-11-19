0. Set up variables

REGION=sa-east-1
REPO=platform-lab-repository
ACCT=$(aws sts get-caller-identity --profile <deployer> --query Account --output text)
REGISTRY=$ACCT.dkr.ecr.$REGION.amazonaws.com
kubectl config current-context        # must be kind-<your-cluster>, not something else
1. Pick the release

gh run list --workflow release.yml --status success --limit 1 --json headSha,displayTitle
FULL_SHA=1027ed1...      # paste the full 40-character SHA
SHORT_SHA=${FULL_SHA:0:7}
❓ How do you prove the image is in ECR, and what is its digest? Ask ECR directly, not the workflow log:


aws ecr describe-images --repository-name $REPO --region $REGION --profile <deployer> \
  --image-ids imageTag=$FULL_SHA \
  --query 'imageDetails[0].{digest:imageDigest,pushed:imagePushedAt,tags:imageTags}'
If it returns a digest, the image exists. Write the sha256:... value into the runbook. It is the image's real identity; a tag is only a label that can be moved.

2. Bring the image to the cluster

aws ecr get-login-password --region $REGION --profile <deployer> \
  | docker login --username AWS --password-stdin $REGISTRY
docker pull $REGISTRY/$REPO:$FULL_SHA
docker inspect --format '{{index .RepoDigests 0}}' $REGISTRY/$REPO:$FULL_SHA   # must match the digest from step 1
docker tag $REGISTRY/$REPO:$FULL_SHA platform-lab:$SHORT_SHA
kind load docker-image platform-lab:$SHORT_SHA --name <cluster>
❓ Why pull the exact ECR image instead of rebuilding the commit locally? A rebuild is a different artifact:

node:24-alpine and apk upgrade may pick up newer packages.
Your local build doesn't get VERSION=<sha>.
The digest will differ.
The image you pulled is the one CI tested and pushed, so what you verify is what you ship. That is the "build once, deploy many" principle.

3. Deploy to dev

kubectl -n dev set image deployment/platform-lab platform-lab=platform-lab:$SHORT_SHA
kubectl -n dev annotate deployment/platform-lab kubernetes.io/change-cause="release $SHORT_SHA" --overwrite
kubectl -n dev rollout status deployment/platform-lab --timeout=90s
4. Verify

kubectl -n dev get deploy platform-lab                 # READY 2/2
kubectl -n dev port-forward svc/platform-lab 8080:80 &
curl -i localhost:8080/health/ready                    # HTTP/1.1 200
curl -s localhost:8080/version                         # {"version":"1027ed1..."}
kubectl -n dev rollout history deployment/platform-lab # your change-cause is listed
❓ What if /version says 1.0.0? That is the fallback in src/app.ts:7, which the app uses when VERSION is empty. It means the running image was not built by CI with the build-arg, probably a locally built image or a stale platform-lab:<tag> already in kind. Treat it as a failed verification:

Check which image the pods actually run: kubectl -n dev get pods -o jsonpath='{..imageID}'.
Compare it with the ECR digest.
Re-run step 2.
5. Bad release, then roll back
The simplest breakage is an image that doesn't exist:


kubectl -n dev set image deployment/platform-lab platform-lab=platform-lab:broken
kubectl -n dev annotate deployment/platform-lab kubernetes.io/change-cause="bad release (test)" --overwrite
kubectl -n dev rollout status deployment/platform-lab --timeout=90s   # times out
kubectl -n dev get pods            # new pod stuck in ErrImagePull/ImagePullBackOff, old pods still Running
Note in the runbook why the old pods kept serving: with 2 replicas, maxUnavailable 25% rounds down to 0, so Kubernetes never removes a healthy pod until its replacement is Ready.


kubectl -n dev rollout undo deployment/platform-lab
kubectl -n dev rollout status deployment/platform-lab --timeout=90s
Then repeat all of step 4: 2/2 Ready, 200 from the Service, and /version back to the good SHA.

For a harder alternative, break the readiness probe instead. The pod then starts but never becomes Ready, which is a more realistic failure.

6. Make git match the cluster
In k8s/deployment.yaml, the image is still platform-lab:1.3.2. Change it to platform-lab:<short-sha>, then:


kubectl -n dev apply -f k8s/deployment.yaml --dry-run=server   # should show no image change
git commit -am "Pin deployment to release <short-sha>"
Otherwise the next kubectl apply quietly rolls you back to 1.3.2.

The deliverable is notes/RELEASE.md: these commands, plus the actual outputs you got (the digest, the /version response, and the history before and after the undo) as evidence for the pass criterion.