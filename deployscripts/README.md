# deployscripts

The scripts in this folder are helpers to simplify rebuild of images and packaging, push and deployment of helm charts

# buildimages.sh
This script uses the details in each subcomponent README.md file to understand the current version and build context and builds and tags the images locally within the devcontainer, then tags them for a remote OCI registry using Azure Container Registry and pushes them to the registry

# package-helm-charts.sh
This script packages the helm chart in ./main including its dependencies, places a copy of the packaged .tgz file in the ./dist folder locally and then pushes the package to the remote OCI registry

# install-minikube.sh
This script uses the local helm package and the local images to install halon locally in minikube. It uses an environment-specific ovveride file ./environments/minikube.yaml to apply appropiate configuration for local run in minikube. This allows for a quick inner loop for developing and testing changes locally. Once you have made changes to your satisfaction locally and committed your changes, you should rerun buildimages and package-helm-charts as appropriate to ensure the changes you have tested against are pushed to the OCI registry. If you have made changes to the helm charts then the version should be bumped as per semantic versioning.

By default this script installs or upgrades Elasticsearch (ECK operator + eck-stack) in the same cluster before installing the Halon chart. Set INSTALL_ELASTICSEARCH=false to skip this step.

# install-aks.sh
This script uses the helm chart and images from the remote OCI registry to install the application in an AKS cluster. It uses an environment-specific ovveride file ./environments/aks-test.yaml to apply appropiate configuration for  run in the AKS test environment.

By default this script enables the AKS Istio service mesh add-on (see install-istio.sh) and installs or upgrades Elasticsearch (ECK operator + eck-stack) in the same cluster before installing the Halon chart. Set INSTALL_ISTIO=false or INSTALL_ELASTICSEARCH=false to skip those steps.

# SMTP Capacity Tests

The independent `loadtest/` chart installs Postfix `smtp-source` and `smtp-sink`
in namespace `halon-loadtest`. Installation starts two discard sinks and **zero
generators**. All SMTP traffic uses private cluster Services. Halon changes are
opt-in through `main/environments/aks-loadtest.yaml`, layered after `aks-test.yaml`.
Your existing DLP rules and hooks are retained. No TLS or Azure load-balancer
capacity is measured by this baseline.

## Prerequisites and Safety

- Use a lab-only Halon release with no real traffic or pre-existing real mail in
	its queues: the overlay redirects **all** delivery, including DSNs, to a sink.
- By default, an enforced Azure, Calico or Cilium NetworkPolicy engine is required.
	Scripts check the AKS network profile but cannot prove enforcement. Verify it before load.
- Alternatively, set `ISOLATION_MODE=subnet-nsg` for Azure CNI Overlay. Before
	installation and each run, scripts verify that every node pool subnet has an
	NSG with a priority-100 outbound deny for Internet TCP25 from all sources.
	This blocks public SMTP without changing the cluster data plane. It does not
	enforce pod-to-pod policies, block private SMTP destinations, or block SMTP
	on other ports. Use the fixed sink route and `.invalid` recipients as well.
	NSG rules are stateful: existing connections must be closed before testing.
- Review existing policies selecting smtpd: Kubernetes policies are additive;
	an existing allow-all egress policy defeats the test policy. The opt-in policy
	permits SMTP only to the selected sink pods, while retaining DNS, HTTPS,
	in-release service connections, Elasticsearch and AKS Istio control traffic.
	Review its fixed ports/namespaces if the lab differs from the defaults.
- Check Istio permits plaintext inbound SMTP (for example PERMISSIVE mTLS).
	Harness pods disable sidecar injection. smtpd retains its production sidecar
	and port-25 outbound exclusion.
- The smtpd image must contain `halon-extras-dlp`. Confirm DLP scans at runtime;
	chart rendering alone does not prove that hooks execute successfully.
- Existing spool PVCs and storage classes are unchanged. Do not change a live
	StatefulSet's volume claim template to experiment with disk sizes/classes.
- Freeze smtpd node count/autoscaling during measurements. Account for API and
	Istio sidecars as well as smtpd resources. DLP runs on the untainted general
	pool; check capacity there, including Elasticsearch and system workloads.

## Install and Smoke Test

Run from the repository root. These commands create chargeable resources only
when their explicit creation flags are set. Review quota, VM SKU, subnet free
addresses and the estimated cost before running them.

```bash
CREATE_MONITORING_RESOURCES=true bash deployscripts/setup-aks-monitoring.sh
CREATE_NODEPOOL=true bash deployscripts/install-loadtest.sh
sh deployscripts/package-helm-charts.sh
EXTRA_VALUES_FILES="$PWD/main/environments/aks-loadtest.yaml" sh deployscripts/install-aks.sh
```

`setup-aks-monitoring.sh` uses existing `halon-lab-metrics` and
`halon-lab-grafana` resources by default; the creation flag creates missing ones.
Override `MONITOR_RESOURCE_GROUP`, `MONITOR_WORKSPACE_NAME`, `GRAFANA_NAME`, or
supply `AZURE_MONITOR_WORKSPACE_ID` and `GRAFANA_RESOURCE_ID` to reuse resources.
The `amg` CLI extension is needed. Linking requires permission to assign the
Grafana managed identity Monitoring Reader access. Grafana uses its managed
identity; no API keys are created. Managed monitoring endpoints are not placed
in the lab VNet by this script; Private Link is a separate configuration.

`install-loadtest.sh` defaults to three fixed `Standard_D8s_v5` nodes, tainted
`dedicated=loadtest:NoSchedule`, in `loadtestpool`. This is a starting allocation,
not a demonstrated capacity recommendation. `NODE_COUNT`, `NODE_VM_SIZE`,
`NODEPOOL_NAME`, `VNET_SUBNET_ID` and `POD_SUBNET_ID` are configurable. Subnets are
otherwise inherited from the system pool. Existing pools are never resized.
The script builds/pushes `halon/loadtest:0.1.0` to `ACR_NAME`; `BUILD_IMAGE=false`
reuses a previously pushed image. AKS must already have ACR pull permission.
Use `VALUES_FILE` for harness sizing/scenario overrides.

The current lab already has `BlockOutboundSMTP` at priority 100 on
`AppRelayPOCPermimeter-nsg`, attached to both AKS subnets. Managed Prometheus
and its PodMonitor CRD also already exist, so monitoring setup and Grafana
creation can be deferred for the first smoke test. To deploy only the idle
harness on one smaller, chargeable test node when ready:

```bash
export ISOLATION_MODE=subnet-nsg
CREATE_NODEPOOL=true NODE_COUNT=1 NODE_VM_SIZE=Standard_D4s_v5 \
	bash deployscripts/install-loadtest.sh
```

Keep `ISOLATION_MODE=subnet-nsg` set for subsequent helper commands. This
single-node layout is for functional verification, not capacity conclusions.
The command does not apply the Halon overlay or send mail; use the separate
packaging, overlay installation and smoke-test steps above only after confirming
the lab contains no real mail. Do not remove the existing NSG rule at teardown.

`install-aks.sh` accepts **newline-separated** `EXTRA_VALUES_FILES`, including
paths with spaces. Files are layered in order after `aks-test.yaml`. Main chart
version `0.1.5` must be packaged/pushed before installation. Confirm rollout of
both smtpd and dlpd before testing. Never remove this overlay with test mail in
active, deferred or held queues.

After verifying egress enforcement and reviewing other policies, send one clean
message from a sink pod (its egress policy allows the Halon Service):

```bash
kubectl --context AppRelayPOC-aks -n halon-loadtest exec deployment/halon-loadtest-sink -- \
	smtp-source -4 -m 1 -f sender@loadtest.invalid -t recipient@loadtest.invalid \
	-S 'Halon smoke test' -l 10240 halon-smtpd.default.svc.cluster.local:25
```

Confirm acceptance, DLP invocation, successful Halon delivery and a corresponding
increment in the sink counter. Separately test rejection, quarantine and logging
with representative messages using your normal SMTP test client. Inspect the
loaded Halon config, not just Helm values. Do not use the default public targets
in `verify-smtpd-egress.sh` for these isolated tests. Verify public SMTP is blocked
using policy diagnostics or an authorized controlled endpoint, never real mail
recipients. Then set `ISOLATION_VERIFIED=true` when starting a run.

## Run and Measure

```bash
CONFIRM_LOADTEST=true ISOLATION_VERIFIED=true \
	STAGES="1 4 16 64" STAGE_SECONDS=300 GENERATOR_REPLICAS=1 \
	bash deployscripts/run-loadtest.sh
```

Stages specify concurrent sessions **per generator**, not messages/second.
`smtp-source` opens a connection per message by default. `reuseConnection=true`
reuses sessions within each finite batch; it does not enforce an exact number
of messages per connection. `messagesPerBatch` is the total across sessions.
`payloadBytes` excludes generated headers. `recipientsPerMessage` controls fanout;
compare recipients as well as messages when using it. `delaySeconds` adds an
integer-second wait per session between messages. This is closed-loop load,
not a precise open-loop rate generator or SMTP latency-histogram tool.

Domains must end in `.invalid`; `generator.domains` rotates domains between
batches. One domain exercises one queue grouping and can hit the existing
per-group delivery concurrency policy before CPU saturates. Use a representative
domain mix, payload sizes and connection reuse before drawing sizing conclusions.
The generated payload is synthetic plain text, not a representative MIME corpus.
Neither Postfix tool supports STARTTLS, so production TLS cost needs a later test.

The runner records UTC stage windows, harness values, cluster/node-pool settings,
smtpd resources, logs and pod status under ignored `dist/loadtest/`. It stops the
generator after each stage and on exit/failure, retaining sinks for queue drain.
An in-pod deadline additionally stops sending after `generator.runSeconds`;
the runner sets this to stage duration plus five minutes for rollout overhead.
The pod stays idle after the deadline. A restarted pod gets a new deadline;
any restart invalidates a stage. A hard-killed runner cannot run its cleanup trap.

Managed Prometheus scrapes smtpd on 8080 and the harness on 9090. Verify healthy
scrape targets before load, then use Grafana Explore with, for example:

```promql
sum by (role) (rate(loadtest_messages_total{namespace="halon-loadtest"}[1m]))
sum by (role) (increase(loadtest_process_failures_total{namespace="halon-loadtest"}[5m]))
sum by (pod, container) (rate(container_cpu_usage_seconds_total{namespace=~"default|halon-loadtest",container!=""}[1m]))
```

Also graph Halon's queue depth by state, accepted/delivered/deferred rates and
queue age from its exposed `/metrics`, memory, CPU throttling, disk latency/IOPS,
and node/network usage. Do not count intended DLP rejects or holds as capacity
failures. Counters are process-local and reset on restart. A failed source batch
may have partial progress; discard failed stages. Monitor exporter CPU because
Postfix counter parsing adds overhead. Prove spare harness capacity by increasing
generator and sink resources/replicas independently and confirming the measured
Halon ceiling is unchanged; CPU below 50% alone does not prove headroom.

Start at a fixed smtpd replica count and size, step load until sustained queue
growth, unacceptable queue age, errors or a throughput plateau, then repeat at
other pod counts/sizes. Change smtpd replicas through Helm so clusterd's
`startup.hosts` stays aligned. Drain between independent trials. Finish with peak
bursts and an average-rate soak, leaving measured operational headroom and
node-failure allowance. DLP-off comparisons need a compatible hook change first:
the current EOD hook unconditionally imports and calls DLP.

## Switch Halon Configuration

Run `switch-halon-config.sh` from the repository root to switch the existing
Halon release between the standard AKS configuration and the load-test overlay:

```bash
bash deployscripts/switch-halon-config.sh normal
bash deployscripts/switch-halon-config.sh loadtest
```

**Lab use only: both commands delete ALL queued mail from every smtpd pod in
the selected release, including held and deferred messages, without generating
bounces.** Stop other SMTP senders first. The script displays the context,
namespace, release and target mode, then requires you to type `DELETE`.
Any other answer, including empty input, cancels before making changes.

The wrapper defaults to `ISOLATION_MODE=subnet-nsg`; no environment prefix is
needed. It verifies the cluster identity and the public TCP25 block on every
node subnet. It stops the load-test generator when the harness is installed,
checks that all expected smtpd replicas are Ready, clears their queues, and
verifies that they are empty before applying the new configuration. Unreadable
queues or cleanup timeout prevent the configuration switch.

`normal` runs `install-aks.sh` without extra values files. `loadtest` applies
`main/environments/aks-loadtest.yaml` and requires the idle harness and ready
sinks. Both modes wait for smtpd and enabled dlpd rollouts, verify the effective
routing settings, and check the SMTP banner from a sink pod when the harness
exists. Both normal and load-test modes exclude inbound TCP25 from Istio capture
through the shared `main/environments/aks-test.yaml` settings.
Post-upgrade verification failures do not automatically roll back the release.

The script keeps the sinks, load-test namespace, node pool, monitoring resources
and NSG rules. It does not start a load test. Keep the NSG safeguard until you
have verified normal routing and SMTP connectivity; remove it manually only
when ready. Re-establish the safeguard before switching back to load-test mode.
If no harness exists, normal mode skips the banner check and asks you to verify
connectivity from your own client.

Optional overrides include `TARGET_CONTEXT`, `HALON_RELEASE`, `HALON_NAMESPACE`,
`CLEAR_TIMEOUT_SECONDS` (default `120`) and `ROLLOUT_TIMEOUT` (default `600s`).
The standard load-test overlay expects release and namespace `halon-loadtest`.
Switching uses the current published chart, not a rollback to an older version;
DLP remains enabled and clusterd remains disabled under the shared defaults.

## Stop and Remove

Emergency stop (also works if the runner terminal is lost):

```bash
kubectl --context AppRelayPOC-aks -n halon-loadtest scale deployment/halon-loadtest-generator --replicas=0
```

Reconcile Helm's stored replica setting to zero before a subsequent run. Drain
or explicitly delete **all test mail**, including deferred and held messages,
while the sink and routing overlay still exist. Then:

```bash
CONFIRM_QUEUES_DRAINED=true bash deployscripts/uninstall-loadtest.sh
EXTRA_VALUES_FILES= sh deployscripts/install-aks.sh
```

`DELETE_NODEPOOL=true` additionally deletes only a User pool tagged
`purpose=halon-loadtest`. The uninstaller never edits Halon, deletes its queues,
deletes the namespace, or removes shared monitoring resources. Delete the empty
test namespace and unused monitoring resources separately after retaining results.
If names/namespaces differ from the defaults, update both the harness settings
and the Halon relay host/policy selectors together.

References: [Postfix source](https://www.postfix.org/smtp-source.1.html),
[Postfix sink](https://www.postfix.org/smtp-sink.1.html),
[Halon transport configuration](https://docs.halon.io/manual/config_smtpd.html#transport-directives),
[Azure monitoring](https://learn.microsoft.com/azure/azure-monitor/containers/kubernetes-monitoring-enable),
[Managed Prometheus PodMonitor](https://learn.microsoft.com/azure/azure-monitor/containers/prometheus-metrics-scrape-crd).

# install-istio.sh
This script enables the managed Istio service mesh add-on on the AKS cluster (`az aks mesh enable`) and resolves the active control plane revision (for example `asm-1-24`). The revision is printed to stdout so install-aks.sh can pass it to Helm as `smtpd.istio.revision`, which adds the `istio.io/rev` label to the smtpd pods and therefore injects sidecars into smtpd only.

No Istio ingress or egress gateway is enabled. Outbound SMTP is deliberately kept out of the mesh: the smtpd pods carry `traffic.sidecar.istio.io/excludeOutboundPorts: "25"`, so TCP 25 skips the sidecar's iptables capture and leaves the pod straight through the smtpdpool node subnet and its NAT gateway. This preserves the proven, stable outbound IP for delivery reputation while all other smtpd traffic still benefits from the mesh.

Useful variables:
- RESOURCE_GROUP (default AppRelayPOC)
- AKS_CLUSTER_NAME (default AppRelayPOC-aks)
- TARGET_CONTEXT (default AppRelayPOC-aks)
- ISTIO_REVISION (default: discovered from the cluster)
- ISTIO_LABEL_NAMESPACES (space separated list of namespaces to label for sidecar injection; empty by default)

Example:

sh ./deployscripts/install-istio.sh

# verify-smtpd-egress.sh
This script checks that outbound TCP 25 from the smtpd pods really does bypass the Istio sidecar, while other outbound traffic is captured by it. Note that both currently leave the VNet via the same NAT gateway address, because Envoy's PassthroughCluster runs inside the pod network namespace; the script therefore verifies the proxy path rather than the source IP.

It performs three checks:
1. The `traffic.sidecar.istio.io/excludeOutboundPorts` annotation and the istio-init arguments contain port 25. Set CHECK_IPTABLES=true to also dump the `ISTIO_OUTPUT` nat rules from the pod network namespace (needs ephemeral containers and kubectl >= 1.30).
2. Envoy's `istio_tcp_connections_opened_total` counter for the `PassthroughCluster` destination is sampled around a probe to port 25 and a probe to port 443. The counter must stay flat for 25 and increment for 443. The probe runs `nc` in the smtpd container, or in an ephemeral netshoot container sharing the same network namespace if `nc` is unavailable. Istio's default stats config suppresses the raw `cluster.PassthroughCluster.*` Envoy counters, which is why the telemetry metric is used instead.
3. Optionally (ENABLE_ACCESS_LOGS=true) applies an Istio `Telemetry` resource scoped to smtpd, waits for the config push, re-runs the probes and asserts that the captured port appears in the sidecar access log while port 25 does not. The resource is left in place; delete it with `kubectl delete telemetry smtpd-access-logs`.

Useful variables:
- RELEASE_NAME (default halon)
- NAMESPACE (default default)
- TARGET_CONTEXT (default AppRelayPOC-aks)
- POD_NAME (default: first smtpd pod of the release)
- EXCLUDED_PORT (default 25) / CAPTURED_PORT (default 443)
- TEST_HOST (default smtp.gmail.com) - target for the excluded port probe
- CAPTURED_HOST (default www.google.com) - target for the captured port probe. Each host must actually listen on its port, otherwise the upstream connection times out and the access log reports UF,URX even though capture worked.
- STATS_SETTLE_SECONDS (default 20) / STATS_POLL_SECONDS (default 2) - how long to wait for the telemetry counter to flush after a probe
- TELEMETRY_SETTLE_SECONDS (default 10) - how long to wait for the access log config push to reach the sidecar
- CHECK_IPTABLES (default false)
- ENABLE_ACCESS_LOGS (default false)

Example:

ENABLE_ACCESS_LOGS=true sh ./deployscripts/verify-smtpd-egress.sh

# uninstall-minikube.sh
This script uninstalls the Halon release from a Minikube profile without requiring manual context switching. By default it also uninstalls Elasticsearch releases (eck-stack and eck-operator).

Useful variables:
- RELEASE_NAME (default halon)
- NAMESPACE (default default)
- MINIKUBE_PROFILE (default minikube)
- UNINSTALL_ELASTICSEARCH (default true)

# uninstall-aks.sh
This script uninstalls the Halon release from an AKS context without requiring manual context switching. By default it also uninstalls Elasticsearch releases (eck-stack and eck-operator).

Useful variables:
- RELEASE_NAME (default halon)
- NAMESPACE (default default)
- TARGET_CONTEXT (default AppRelayPOC-aks)
- UNINSTALL_ELASTICSEARCH (default true)

# install-elasticsearch.sh
This script installs or upgrades Elasticsearch by using the official Elastic Helm repository and deploys two Helm releases:
- eck-operator in ELASTIC_OPERATOR_NAMESPACE (default elastic-system)
- eck-stack in ELASTIC_STACK_NAMESPACE (default elastic-stack)

It is called automatically by install-minikube.sh and install-aks.sh by default, and can also be run directly with a kube context argument.

Examples:

sh ./deployscripts/install-elasticsearch.sh minikube
TARGET_CONTEXT=AppRelayPOC-aks sh ./deployscripts/install-elasticsearch.sh

Useful variables:
- ELASTIC_ENABLE_KIBANA (default false)
- WAIT_FOR_OPERATOR (default true)
- OPERATOR_READY_TIMEOUT (default 300s)

Elasticsearch auth password handling:
- Do not commit global.elasticsearch.auth.password in repo values files.
- install-minikube.sh and install-aks.sh will use ELASTICSEARCH_PASSWORD if set.
- If ELASTICSEARCH_PASSWORD is not set, scripts will try to read the password from the ECK secret:
	- namespace: ELASTIC_STACK_NAMESPACE (default elastic-stack)
	- secret name: ELASTICSEARCH_SECRET_NAME (default elasticsearch-es-elastic-user)
	- data key: ELASTICSEARCH_SECRET_KEY (default elastic)
- Username can be overridden with ELASTICSEARCH_USERNAME (default elastic).
- By default scripts wait for the ECK secret to appear before deploying Halon:
	- ELASTICSEARCH_WAIT_FOR_SECRET (default true)
	- ELASTICSEARCH_SECRET_TIMEOUT_SECONDS (default 300)
	- ELASTICSEARCH_SECRET_POLL_SECONDS (default 5)

# setup-aks-shutdown-runbook.sh
This script publishes the daily AKS shutdown runbook (./automation/Stop-AksCluster.ps1) into an existing Azure Automation Account and schedules it. It assumes the Automation Account, its managed identity and the Contributor (or Azure Kubernetes Service Contributor) role assignment on the AKS cluster already exist. The Automation Account also needs the Az.Accounts and Az.Aks modules imported.

The script creates or updates the runbook, publishes it, creates a daily schedule and links the schedule to the runbook with the cluster parameters.

Useful variables:
- RESOURCE_GROUP (default AppRelayPOC) - resource group of the Automation Account
- AUTOMATION_ACCOUNT (default aks-scheduler)
- AKS_RESOURCE_GROUP (defaults to RESOURCE_GROUP)
- AKS_CLUSTER_NAME (default AppRelayPOC-aks)
- RUNBOOK_NAME (default Stop-AksCluster)
- SCHEDULE_NAME (default daily-aks-shutdown)
- SCHEDULE_TIME (default 18:00)
- SCHEDULE_TIMEZONE (default Europe/London)
- SUBSCRIPTION_ID (defaults to the current az subscription)
- MANAGED_IDENTITY_CLIENT_ID (only needed when using a user-assigned identity)

Example:

AUTOMATION_ACCOUNT=my-automation SCHEDULE_TIME=19:30 sh ./deployscripts/setup-aks-shutdown-runbook.sh

Restart the cluster with: az aks start -g AppRelayPOC -n AppRelayPOC-aks

# TODO
As we move to the corporate environment most of the functions of these helper scripts will be moved to pipelines, so some of the logic will change and these scripts are likely to become unnecessary. 