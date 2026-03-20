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

By default this script installs or upgrades Elasticsearch (ECK operator + eck-stack) in the same cluster before installing the Halon chart. Set INSTALL_ELASTICSEARCH=false to skip this step.

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

# TODO
As we move to the corporate environment most of the functions of these helper scripts will be moved to pipelines, so some of the logic will change and these scripts are likely to become unnecessary. 