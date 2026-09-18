# The main MTA process

## Build

Below are the linux distributions we currently have instructions for.

| Distribution   | Description                          |
| -------------- | -----------------------------------  |
| `ubuntu-24.04` | Ubuntu 24.04.1 (Noble Numbat)        |
| `ubuntu-22.04` | Ubuntu 22.04.1 LTS (Jammy Jellyfish) |
| `rocky-9`      | Rocky Linux 9                        |
| `rocky-8`      | Rocky Linux 8                        |
| `azure-3`      | Azure Linux 3                        |

To build a container image, simply clone the repository to your machine and from inside the `halon-docker/smtpd` directory run the below command, substituting `ubuntu-24.04` with any of the distributions above and the example credentials with those provided by us.

```
HALON_REPO_USER=exampleuser
HALON_REPO_PASS=examplepass
docker build -t halon/smtpd:6.10.3 -f images/ubuntu-24.04/Dockerfile \
             --build-arg HALON_REPO_USER=${HALON_REPO_USER} \
             --build-arg HALON_REPO_PASS=${HALON_REPO_PASS} \
             --platform=linux/amd64 \
             images/ubuntu-24.04
```

## Istio service mesh

The `istio` values block controls how smtpd participates in the mesh:

| Value | Description |
| ----- | ----------- |
| `istio.enabled` | Adds the sidecar injection label and traffic-capture annotations to the smtpd pods. |
| `istio.revision` | Control plane revision to inject from (AKS add-on revisions look like `asm-1-24`). Sets `istio.io/rev` on the pods so smtpd can be meshed without labelling the whole namespace. Leave empty to fall back to `sidecar.istio.io/inject: "true"` plus a namespace label. |
| `istio.excludeOutboundPorts` | Outbound ports the sidecar must not capture. Defaults to `25` so SMTP delivery leaves the pod directly through the node subnet and its NAT gateway rather than through the mesh and Istio egress gateways. |
| `istio.excludeInboundPorts` | Inbound ports the sidecar must not capture. Set to `25` if Istio protocol sniffing interferes with inbound SMTP. |
| `istio.excludeOutboundIPRanges` | CIDRs excluded from outbound capture. |
| `istio.podAnnotations` | Extra sidecar annotations, e.g. `proxy.istio.io/config` overrides. |

Excluded ports are removed from the sidecar's iptables redirect rules, so the traffic keeps the pod's own source path out of the node NIC and therefore the fixed NAT gateway address, which is what SMTP receivers expect for reputation.

