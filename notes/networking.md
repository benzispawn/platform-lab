# Networking (Nov 14)

Goal: VPC + public subnet + IGW + route table, a private subnet, and the ability to explain why each piece exists.

## Lab layout

Built with the console "VPC and more" wizard: 2 AZs, 2 public + 2 private subnets, no NAT gateway,
and an S3 gateway endpoint. Checked with `describe-*` on 2026-11-14.

```text
VPC 10.0.0.0/16  (sa-east-1)                      igw attached to the VPC
├── public1   10.0.0.0/20    sa-east-1a ─┐
├── public2   10.0.16.0/20   sa-east-1b ─┴→ public RT:    local, 0.0.0.0/0 → igw
├── private1  10.0.128.0/20  sa-east-1a ──→ private1 RT:  local, S3 prefix list → vpce (S3 gateway)
├── private2  10.0.144.0/20  sa-east-1b ──→ private2 RT:  local, S3 prefix list → vpce (S3 gateway)
└── main RT (no subnets associated):        local only
```

| Resource | ID | Notes |
|---|---|---|
| VPC | `vpc-0f5f4dd032b0eadcb` | `10.0.0.0/16`, tagged |
| Internet gateway | `igw-08e394c3c3d07a6b6` | attached, `available` |
| public1 (sa-east-1a) | `subnet-08d3e094d4d0ad685` | `10.0.0.0/20`, auto-assign public IP **off** |
| public2 (sa-east-1b) | `subnet-0ee1a3fb426aa66cf` | `10.0.16.0/20`, auto-assign public IP **off** |
| private1 (sa-east-1a) | `subnet-0699c12cb7c05443d` | `10.0.128.0/20` |
| private2 (sa-east-1b) | `subnet-007e0a1303746b3a8` | `10.0.144.0/20` |
| Public RT | `rtb-0f92492e322597833` | public1 + public2, `0.0.0.0/0 → igw` |
| private1 RT | `rtb-0d5bbfbe4f8dfc03f` | local + S3 endpoint |
| private2 RT | `rtb-01f4502201ea8e307` | local + S3 endpoint |
| Main RT | `rtb-08ce799c3b7e18384` | local only, no explicit associations |
| S3 gateway endpoint | `vpce-0d789be1c686a1b6b` | `com.amazonaws.sa-east-1.s3`, prefix list `pl-6aa54003` |

All resources are tagged `Project=platform-lab`, `Owner=benzi`. The deployer's
[network policy](policies/network-policy.json) refuses to create anything without the `Project` tag.

---

## Step questions

### 5.1 VPC: which CIDR, and how many IPs does a /16 have?

- **CIDR:** `10.0.0.0/16`, a private range (RFC 1918), so it is never routed on the public internet.
- **Size:** 32 − 16 = 16 host bits → 2¹⁶ = **65,536 addresses**.
- A VPC CIDR must be between /16 (largest) and /28 (smallest).
- Pick a range that won't overlap with other networks you may connect later (peering, VPN, other VPCs).

### 5.2 Public subnet: which /24 and AZ, and why only one AZ?

- **Subnet:** the wizard created `/20`s, not `/24`s: `10.0.0.0/20` in `sa-east-1a` → 2¹² = 4,096 addresses,
  **4,091 usable**. (A `/24` would be 256 addresses, 251 usable.) AWS reserves 5 in every subnet:
  the network address, base +1 (VPC router), base +2 (DNS), base +3 (reserved for future use), and the last address (broadcast).
- **One AZ:** a subnet is built on the physical network of a single Availability Zone, and an AZ is AWS's
  unit of failure isolation. If a subnet spanned AZs, an AZ outage would only partly break it, and you
  couldn't reason about where an instance actually runs.
- **Consequence:** for high availability you create **one subnet per AZ** (for example, public-a and public-b) and spread
  instances across them. EKS, ALBs and RDS all require subnets in at least 2 AZs.

### 5.3 Internet gateway: is it attached to a subnet or to the VPC?

- **To the VPC.** There is at most one IGW per VPC.
- Attaching it changes nothing on its own. A subnet becomes "public" only when **its route table** sends
  `0.0.0.0/0` to the IGW. "Public" describes a subnet's routing, not where the IGW is attached.
- The IGW also does the 1:1 translation between an instance's private IP and its public IP.
  The instance's OS only ever sees its private IP.

### 5.4 Route table: what does the existing `local` route do?

- `10.0.0.0/16 → local` is created automatically and **cannot be deleted**. It lets every subnet in the VPC
  reach every other subnet in the VPC. That's why the public instance can ping the private one without any extra route.
- **Routes are chosen by longest prefix match.** Traffic to `10.0.2.15` matches both `10.0.0.0/16` and `0.0.0.0/0`.
  The /16 is more specific, so it stays inside the VPC. Everything else goes to the IGW.

### 5.5 Private subnet: which route table does it use when you associate none?

- The VPC's **main route table**, through an implicit association. In this lab, the main table only has the `local` route,
  so the subnet has no path to the internet. That is what makes it private.
- **Gotcha:** if someone adds `0.0.0.0/0 → igw` to the main table, *every* subnet without an explicit
  association becomes public at once. Best practice: keep the main table private and associate
  every subnet with a route table explicitly.
- Check it:
  `aws ec2 describe-route-tables --filters Name=vpc-id,Values=$VPC_ID Name=association.main,Values=true`
- **In my lab:** the wizard associated each private subnet with its **own** route table, so the main table
  (`rtb-08ce799c3b7e18384`) has no subnets. If I removed private1's association, it would fall back to the
  main table and lose its S3 endpoint route.
- The private RTs have an extra route: S3 prefix list `pl-6aa54003` → `vpce-…`. That's a **gateway endpoint**,
  so private instances can reach S3 but nothing else on the internet (see pass question 2).

---

## Pass questions

### 1. Is a route to the IGW enough to give an EC2 instance public connectivity?

No. The route is only the path. All of these must be true:

1. **Route:** the subnet's route table has `0.0.0.0/0 → igw-…`.
2. **Public address:** the instance has a public IPv4 or an Elastic IP (`--associate-public-ip-address`, or
   `modify-subnet-attribute --map-public-ip-on-launch`). Without one, the IGW has nothing to translate the private IP to.
3. **Security group:** it allows the inbound port (for example, 22 from my IP). Outbound is allowed by default.
4. **Network ACL:** it allows the traffic in both directions. The default NACL allows everything.
5. **Instance:** something is listening on the port, and the OS firewall isn't blocking it.

When debugging, check them in this order. Reachability Analyzer reports which of them is blocking.

### 2. What are the egress options for a private subnet?

| Option | How | When / trade-off |
|---|---|---|
| **NAT gateway** | Lives in a *public* subnet; private RT gets `0.0.0.0/0 → nat-…` | Managed and highly available within one AZ. Costs per hour plus per GB. Use one per AZ for HA. Outbound only: the internet can't start connections in. |
| **NAT instance** | An EC2 instance doing NAT (source/dest check disabled) | Cheaper, but you patch it, scale it, and it's a single point of failure. Mostly legacy. |
| **Gateway VPC endpoint** | Route-table entry to the service | **S3 and DynamoDB only. Free.** Traffic stays on the AWS network. |
| **Interface VPC endpoint** (PrivateLink) | An ENI with a private IP in your subnet | Any supported AWS service (ECR, STS, SSM, CloudWatch Logs…). Costs per hour per AZ. No internet path needed. |
| **Egress-only IGW** | Route `::/0 → eigw-…` | IPv6 only. The IPv6 equivalent of NAT for outbound-only traffic. |
| **No egress** | Nothing | Fully isolated workloads. Safest, but no package installs or image pulls. |

Example: private EKS nodes pulling from ECR need either a NAT gateway or endpoints for `ecr.api`, `ecr.dkr`,
S3 (gateway, because image layers are stored in S3), `sts` and `logs`.

### 3. Why is a private subnet different from a security group?

They answer different questions:

- **Private subnet = routing.** *Is there a path?* It applies to the whole subnet. With no route to an IGW,
  the internet cannot reach anything in it, whatever the firewall rules say.
- **Security group = firewall on the instance's network interface (ENI).** *Is the door open?* It applies per instance and filters by
  protocol, port and source, including traffic from inside the VPC.

Examples:
- An instance in a private subnet with an SG open to `0.0.0.0/0` is **still unreachable** from the internet. There is no path.
- An instance in a public subnet with a public IP but an SG with no inbound rules has a path, but **the door is closed**.

You use both (defense in depth). The subnet decides what *can* be exposed; the SG decides what *is* allowed,
including between instances inside the VPC, which subnet routing never restricts.

### 4. What is the difference between stateful and stateless?

| | Security group | Network ACL |
|---|---|---|
| Applies to | ENI (instance) | Subnet |
| State | **Stateful**: return traffic is allowed automatically | **Stateless**: each direction is evaluated separately |
| Rules | Allow only | Allow **and** Deny |
| Evaluation | All rules together | In number order, first match wins |
| Default | Inbound denied, outbound allowed | Default NACL allows everything |

- **Stateful:** the SG remembers the connection. If inbound 22 is allowed, the SSH replies go out even
  with no matching outbound rule.
- **Stateless:** the NACL doesn't track connections. To allow inbound SSH you also need an **outbound** rule for the
  client's ephemeral ports (`1024–65535`), or the replies are dropped.
- NACLs are useful for a coarse subnet-wide **deny**, such as blocking a bad CIDR. SGs can't deny.

---

## Verification

Planned checks: (✅/❌ = expected result)

- [x] `describe-internet-gateways`: IGW is attached to the VPC
- [x] `describe-route-tables`: the public RT has `local` + `0.0.0.0/0 → igw` and is associated with public1 + public2
- [x] Private subnets use their own RTs (local + S3 endpoint), so there is no `0.0.0.0/0` route
- [ ] Note: public subnets have auto-assign public IP **off**, so launch with `--associate-public-ip-address` (pass question 1 in practice)
- [ ] ✅ Private instance → `aws s3 ls` works with no internet route (S3 gateway endpoint; needs an instance role with S3 permissions)
- [ ] ✅ SSH from my laptop → public instance
- [ ] ✅ Public instance → `curl https://example.com`
- [ ] ✅ Public instance → ping the private instance (local route)
- [ ] ✅ SSH to the private instance through the public one (`ssh -J`)
- [ ] ❌ Private instance → `curl https://example.com` times out (no egress, which is correct)
- [ ] Cleanup: instances → SG / key pair → subnets → route table → detach + delete IGW → VPC

## Issues hit

- `UnauthorizedOperation` on `ec2:DescribeInternetGateways`: the deployer policy had no VPC permissions.
  It was also near the 6,144-character managed-policy limit, so I added a separate tag-scoped policy
  ([network-policy.json](policies/network-policy.json)) and attached it with the admin identity.
