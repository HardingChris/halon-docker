# Dockerfile
FROM mcr.microsoft.com/devcontainers/base:bullseye

# Install dependencies needed by Azure CLI
RUN apt-get update && \
    apt-get install -y ca-certificates curl apt-transport-https lsb-release gnupg && \
    rm -rf /var/lib/apt/lists/*

# Install Azure CLI (Microsoft official method)
# Reference: https://aka.ms/InstallAzureCLIDeb
RUN curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Install AKS CLI tools: kubectl + kubelogin
# Documented under Azure kubelogin installation methods
RUN az aks install-cli

# Verify tools were installed
RUN kubectl version --client && kubelogin --version && az version