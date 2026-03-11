# deployscripts

The scripts in this folder are helpers to simplify rebuild of images and packaging, push and deployment of helm charts

# buildimages.sh
This script uses the details in each subcomponent README.md file to understand the current version and build context and builds and tags the images locally within the devcontainer, then tags them for a remote OCI registry using Azure Container Registry and pushes them to the registry

# package-helm-charts.sh
This script packages the helm chart in ./main including its dependencies, places a copy of the packaged .tgz file in the ./dist folder locally and then pushes the package to the remote OCI registry

# install-minikube.sh
This script uses the local helm package and the local images to install halon locally in minikube. It uses an environment-specific ovveride file ./environments/minikube.yaml to apply appropiate configuration for local run in minikube. This allows for a quick inner loop for developing and testing changes locally. Once you have made changes to your satisfaction locally and committed your changes, you should rerun buildimages and package-helm-charts as appropriate to ensure the changes you have tested against are pushed to the OCI registry. If you have made changes to the helm charts then the version should be bumped as per semantic versioning.

# install-aks.sh
This script uses the helm chart and images from the remote OCI registry to install the application in an AKS cluster. It uses an environment-specific ovveride file ./environments/aks-test.yaml to apply appropiate configuration for  run in the AKS test environment.

# TODO
As we move to the corporate environment most of the functions of these helper scripts will be moved to pipelines, so some of the logic will change and these scripts are likely to become unnecessary. 