# AWS Commands

Placeholders: `<p>` = CLI profile, `<bucket>` = bucket name, `<region>` = AWS region.

---

## Identity

Check which identity and region the CLI is using **before** doing anything else.

```bash
aws sts get-caller-identity --profile <p>     # account, user/role ARN
aws configure get region --profile <p>        # default region for this profile
```

---

## S3 — Create and lock down the bucket

Region `sa-east-1` is not `us-east-1`, so `create-bucket` needs a `LocationConstraint`.
Each command below maps to one Terraform resource on Sunday.

```bash
# 1. Create the bucket                         -> aws_s3_bucket
aws s3api create-bucket --bucket <bucket> --region <region> \
  --create-bucket-configuration LocationConstraint=<region> --profile <p>

# 2. Block Public Access (all 4 flags)         -> aws_s3_bucket_public_access_block
aws s3api put-public-access-block --bucket <bucket> --profile <p> \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 3. Default encryption SSE-S3 + Bucket Key    -> aws_s3_bucket_server_side_encryption_configuration
aws s3api put-bucket-encryption --bucket <bucket> --profile <p> \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Versioning                                -> aws_s3_bucket_versioning
aws s3api put-bucket-versioning --bucket <bucket> --profile <p> \
  --versioning-configuration Status=Enabled

# 5. Tags                                      -> tags on aws_s3_bucket (or provider default_tags)
aws s3api put-bucket-tagging --bucket <bucket> --profile <p> \
  --tagging 'TagSet=[{Key=Project,Value=platform-lab},{Key=Owner,Value=benzi}]'

# 6. Deny non-HTTPS requests                   -> aws_s3_bucket_policy
aws s3api put-bucket-policy --bucket <bucket> --profile <p> \
  --policy file://notes/policies/deny-insecure-transport.json
```

**Why the policy is a Deny with `Principal: "*"`:** it applies to everyone, including
identities that have an Allow. An explicit Deny always beats an Allow, so plain-HTTP
requests are refused no matter what other policy says. It lists both the bucket ARN
(bucket-level actions such as `ListBucket`) and `bucket/*` (object-level actions such as
`GetObject`), so neither kind can be done over HTTP.

**Verify each setting** with the matching `get-*` command:
`get-bucket-location`, `get-public-access-block`, `get-bucket-encryption`,
`get-bucket-versioning`, `get-bucket-tagging`, `get-bucket-policy`.

---

## S3 — Upload, list, download, compare

```bash
aws s3 cp hello.txt s3://<bucket>/hello.txt --profile <p>        # upload
aws s3 ls s3://<bucket> --profile <p>                            # list
aws s3 cp s3://<bucket>/hello.txt downloaded.txt --profile <p>   # download

diff hello.txt downloaded.txt && echo "identical"                # compare
sha256sum hello.txt downloaded.txt                               # hashes should match
```

---

## S3 — Versioning

```bash
aws s3api get-bucket-versioning --bucket <bucket> --profile <p>  # Status: Enabled

aws s3 cp hello.txt s3://<bucket>/hello.txt --profile <p>        # upload again
aws s3api list-object-versions --bucket <bucket> --prefix hello.txt --profile <p>

# fetch a specific (older) version
aws s3api get-object --bucket <bucket> --key hello.txt \
  --version-id <version-id> old-hello.txt --profile <p>
```

**What changed after the second upload?**
The **key** (`hello.txt`) stayed the same. S3 gave the new upload a new **VersionId**
and kept the first upload as a non-current version (`IsLatest: false`).

**Why it matters:** with versioning on, an overwrite or delete doesn't destroy data.
A delete only adds a *delete marker*, so you can still get older versions back.
That's why Terraform state buckets must be versioned.

---

## S3 — Verifying the bucket is private

| # | Command | Expected (private) |
| --- | --- | --- |
| 1 | `aws s3api get-public-access-block --bucket <bucket> --profile <p>` | All four flags `true` |
| 2 | `aws s3 ls s3://<bucket> --no-sign-request` | `AccessDenied` |
| 3 | `curl -I https://<bucket>.s3.<region>.amazonaws.com/hello.txt` | `HTTP 403` |
| 4 | `aws s3api get-bucket-policy-status --bucket <bucket> --profile <p>` | `IsPublic: false` (or `NoSuchBucketPolicy`) |
| 5 | `aws s3api get-bucket-acl --bucket <bucket> --profile <p>` | Only the owner has grants |

**Pass answer:** #1 shows the setting is on, and #2/#3 show that an anonymous
request is actually refused.

**Contrast:** a presigned URL *does* work, so the only way in is signed,
authorized access:

```bash
aws s3 presign s3://<bucket>/hello.txt --expires-in 300 --profile <p>
```

> An access point is **not** needed for privacy. Access points are a separate
> feature for managing access at scale.

## S3 - Save credentials to console variables

```bash
eval "$(aws sts assume-role \
  --role-arn arn:aws:iam::771983217432:role/platform-lab-s3-reader \
  --role-session-name lab-test --profile platform-lab-deployer \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text \
  | awk '{print "export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3}')"
```

---

## IAM — Permissions needed for these commands

`list-object-versions` failed with `AccessDenied` until `s3:ListBucketVersions`
was added. Bucket-level actions go on the **bucket ARN**, and object-level actions
go on **`bucket/*`**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:ListBucketVersions"],
      "Resource": "arn:aws:s3:::<bucket>"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"],
      "Resource": "arn:aws:s3:::<bucket>/*"
    }
  ]
}
```

**Lesson (least privilege):** read the `AccessDenied` error, add only the action
it names, and attach it to the right resource ARN.

## ECR

```bash
aws ecr get-login-password --region sa-east-1 --profile platform-lab-deployer | docker login --username AWS --password-stdin 771983217432.dkr.ecr.sa-east-1.amazonaws.com
```

```bash
docker tag 46bad59e1f26 771983217432.dkr.ecr.sa-east-1.amazonaws.com/platform-lab-repository:adcd335
```

```bash
docker push 771983217432.dkr.ecr.sa-east-1.amazonaws.com/platform-lab-repository:adcd335
```
