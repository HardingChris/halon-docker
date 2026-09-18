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