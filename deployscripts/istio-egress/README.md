# Managed Istio HTTPS Egress Test

This opt-in PoC routes `api.ipify.org:443` from `default` namespace workloads
labelled `app.kubernetes.io/instance=halon` and `app.kubernetes.io/name=smtpd`
through the AKS-managed Istio egress gateway. TLS passes through unchanged;
the application verifies the destination certificate. TCP25 sidecar exclusions,
SMTP subnet NAT/UDR settings, DLP traffic and other HTTPS destinations are not
changed. These resources are applied separately from the Halon Helm release.

The path is:

```text
SMTP application -> sidecar -> ipify-egress ClusterIP -> Envoy gateway
  -> private Static Egress Gateway -> secure hub firewall -> api.ipify.org
```

## Infrastructure and Cost

- Static Egress Gateway private-IP mode is preview and requires Kubernetes 1.34+.
- `egresspool` uses two `Standard_D2as_v5` nodes (2 vCPU, 8 GiB each) with
  32-GiB managed OS disks in `EgressGatewaySubnet` (`10.10.5.0/24`).
- Azure rejected a one-node pool: the enforced minimum is two nodes. A `/31`
  gateway prefix-size parameter permits two nodes; `provisionPublicIps: false`
  selects private egress addresses rather than public IP prefixes.
- Linux UK South retail compute was USD 0.10/node/hour when checked on
  2026-10-16: about USD 146/month for two nodes at 730 hours, excluding disks,
  network charges and existing firewall costs. Actual billing can differ.
- Managed Envoy replicas run on the existing system pool. Their private network
  exit is the gateway pool, not the subnet hosting the Envoy pod.
- The gateway subnet must retain a working path through the secure hub firewall.
  Do not attach the SMTP subnet's direct-Internet override to this subnet.

## Provision

Run from the repository root. These commands create billed infrastructure and
are initial setup commands; inspect existing resources before rerunning them.
They assume the existing hub Internet routing intent and firewall allow rule
permit gateway-subnet HTTPS egress. No firewall or subnet routes are changed.

```bash
export SUBSCRIPTION_ID=cc1ccb8d-18a1-4dca-aa5a-54607876c990
export RESOURCE_GROUP=AppRelayPOC
export AKS_CLUSTER_NAME=AppRelayPOC-aks
export TARGET_CONTEXT=AppRelayPOC-aks
export GATEWAY_SUBNET_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Network/virtualNetworks/AppRelayPOCVNet/subnets/EgressGatewaySubnet"

az aks update --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" --enable-static-egress-gateway

az aks nodepool add --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -n egresspool \
  --mode Gateway --node-count 2 --vm-set-type VirtualMachines \
  --node-vm-size Standard_D2as_v5 --gateway-prefix-size 31 \
  --node-osdisk-size 32 --node-osdisk-type Managed \
  --vnet-subnet-id "$GATEWAY_SUBNET_ID"

kubectl --context "$TARGET_CONTEXT" create namespace aks-istio-egress \
  --dry-run=client -o yaml | kubectl --context "$TARGET_CONTEXT" apply -f -
kubectl --context "$TARGET_CONTEXT" apply --dry-run=server \
  -f deployscripts/istio-egress/static-gateway.yaml
kubectl --context "$TARGET_CONTEXT" apply \
  -f deployscripts/istio-egress/static-gateway.yaml
kubectl --context "$TARGET_CONTEXT" -n aks-istio-egress \
  wait staticgatewayconfiguration/ipify-private-egress \
  --for=jsonpath='{.status.egressIpPrefix}' --timeout=600s

az aks mesh enable-egress-gateway --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" \
  --istio-egressgateway-name ipify-egress \
  --istio-egressgateway-namespace aks-istio-egress \
  --gateway-configuration-name ipify-private-egress

kubectl --context "$TARGET_CONTEXT" -n aks-istio-egress \
  rollout status deployment/ipify-egress-asm-1-29 --timeout=300s
kubectl --context "$TARGET_CONTEXT" apply --dry-run=server \
  -f deployscripts/istio-egress/ipify.yaml
kubectl --context "$TARGET_CONTEXT" apply -f deployscripts/istio-egress/ipify.yaml
```

The gateway selector `istio=ipify-egress` was verified against the managed
deployment. Recheck its selector and the rollout deployment name after renaming
the gateway or upgrading the Istio revision. No mesh-wide `REGISTRY_ONLY`
setting is introduced. The gateway DestinationRule disables additional Istio
mTLS on this passthrough leg; application-to-destination TLS remains intact.

## Verify

Run a fresh request without environment-configured HTTP proxies:

```bash
kubectl --context AppRelayPOC-aks -n default exec halon-smtpd-0 -c smtpd -- \
  python3 -c 'import urllib.request; opener=urllib.request.build_opener(urllib.request.ProxyHandler({})); print(opener.open("https://api.ipify.org",timeout=20).read().decode())'

kubectl --context AppRelayPOC-aks -n aks-istio-egress \
  logs -l istio=ipify-egress -c istio-proxy --since=5m --prefix=true
```

Successful validation on 2026-10-16 returned firewall public IP
`51.142.255.102` and a gateway access log containing the SMTP pod's address,
`api.ipify.org`, and the external upstream. The assigned private egress
addresses were `10.10.5.6,10.10.5.7`; inspect the StaticGatewayConfiguration
status rather than assuming these addresses will remain after recreation.

As a control, use `https://api4.ipify.org` in the same Python command. This
different hostname is not routed through the gateway and returned NAT public
IP `4.159.40.144`. A TCP connection to `halon-dlpd:3000` and local SMTP NOOP
also passed; this does not re-test content scanning or external SMTP delivery.
Both targets depend on a third-party public service and DNS availability.

This PoC is routing configuration, not network enforcement. Direct egress is
still possible under the existing subnet UDR. Sidecar port/IP exclusions,
non-injected workloads and other destinations are not forced through this
gateway. TLS without the configured SNI hostname is not covered.

## Rollback and Teardown

First remove the hostname route to restore normal sidecar egress. This does
not touch SMTP delivery, queued messages, PVCs or the SMTP subnet routes.

```bash
kubectl --context AppRelayPOC-aks delete -f deployscripts/istio-egress/ipify.yaml
```

To remove the billed gateway infrastructure too, disable the managed gateway
and wait for its pods to be removed before deleting its static configuration:

```bash
az aks mesh disable-egress-gateway --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" -n "$AKS_CLUSTER_NAME" \
  --istio-egressgateway-name ipify-egress \
  --istio-egressgateway-namespace aks-istio-egress
kubectl --context AppRelayPOC-aks -n aks-istio-egress \
  wait --for=delete pod -l istio=ipify-egress --timeout=300s
kubectl --context AppRelayPOC-aks -n aks-istio-egress \
  delete staticgatewayconfiguration ipify-private-egress --timeout=300s
az aks nodepool delete --subscription "$SUBSCRIPTION_ID" \
  -g "$RESOURCE_GROUP" --cluster-name "$AKS_CLUSTER_NAME" -n egresspool
```

Only disable the cluster Static Egress Gateway feature when no other gateway
configurations or pools use it. Do not delete the namespace through the
multi-document static manifest: it may contain other resources.