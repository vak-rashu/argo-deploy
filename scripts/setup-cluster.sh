#!/usr/bin/env bash
set -euo pipefail

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

write_step() {
    echo -e "\n${CYAN}========================================================${NC}"
    echo -e "${GREEN}>>> $1${NC}"
    echo -e "${CYAN}========================================================${NC}"
}

write_info() {
    echo -e "${YELLOW}[-] $1${NC}"
}

write_success() {
    echo -e "${GREEN}[+] $1${NC}"
}

# 1. Verify Prerequisites
write_step "1/6: Verifying Prerequisites"
for tool in docker kind kubectl; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: Required tool '$tool' is not installed or not in PATH."
        exit 1
    fi
    write_success "Found: $tool"
done

# 2. Kind Cluster Provisioning
write_step "2/6: Creating Kind Cluster (llm-gitops-cluster)"
CLUSTER_NAME="llm-gitops-cluster"
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    write_info "Cluster '${CLUSTER_NAME}' already exists. Recreating for clean state..."
    kind delete cluster --name "${CLUSTER_NAME}"
fi

write_info "Creating cluster with kind-config.yaml..."
kind create cluster --config kind-config.yaml

# 3. Build & Load Container Images
write_step "3/6: Building and Loading LLM Inference Images"
write_info "Building baseline image: llm-inference:v1 ..."
docker build --network=host --build-arg APP_VERSION=v1 -t llm-inference:v1 app/

write_info "Building canary upgrade image: llm-inference:v2 ..."
docker build --network=host --build-arg APP_VERSION=v2 -t llm-inference:v2 app/

write_info "Building degraded image: llm-inference:v2-degraded ..."
docker build --network=host --build-arg APP_VERSION=v2-degraded --build-arg SIMULATE_DEGRADED=true -t llm-inference:v2-degraded app/

write_info "Loading container images into Kind nodes..."
kind load docker-image llm-inference:v1 --name "${CLUSTER_NAME}"
kind load docker-image llm-inference:v2 --name "${CLUSTER_NAME}"
kind load docker-image llm-inference:v2-degraded --name "${CLUSTER_NAME}"
write_success "All images loaded into Kind nodes."

# 4. Install Infrastructure Platform Manifests
write_step "4/6: Installing Infrastructure Components"

# Prometheus
write_info "Deploying lightweight Prometheus instance..."
kubectl apply -f infra/prometheus/rbac.yaml
kubectl apply -f infra/prometheus/configmap.yaml
kubectl apply -f infra/prometheus/deployment.yaml

# Argo Rollouts
write_info "Installing Argo Rollouts Controller and CRDs..."
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# KEDA
write_info "Installing KEDA Autoscaler..."
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.14.0/keda-2.14.0.yaml

# Argo CD
write_info "Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f infra/argocd/patch-nodeport.yaml

# 5. Wait for Platform Readiness
write_step "5/6: Waiting for Platform Controllers to be Ready"
kubectl wait --for=condition=Available deployment/prometheus -n monitoring --timeout=120s
kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s
kubectl wait --for=condition=Available deployment/keda-operator -n keda --timeout=180s
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

# 6. Deploy Workload via GitOps
write_step "6/6: Deploying LLM Inference Service"
kubectl apply -f gitops/services.yaml
kubectl apply -f gitops/analysis-template.yaml
kubectl apply -f gitops/rollout.yaml
kubectl apply -f gitops/keda-scaledobject.yaml

sleep 10

ARGO_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 --decode || echo "admin")

echo -e "\n${MAGENTA}========================================================${NC}"
echo -e "${GREEN} 🎉 PLATFORM BOOTSTRAP COMPLETE! ${NC}"
echo -e "${MAGENTA}========================================================${NC}"
echo -e "${CYAN}Services available on localhost:${NC}"
echo -e "  • LLM Inference Gateway : http://localhost:8080/v1/chat/completions"
echo -e "  • Prometheus Dashboard  : http://localhost:9091"
echo -e "  • Argo CD Dashboard     : http://localhost:8081"
echo -e "    Username              : admin"
echo -e "    Initial Password      : ${YELLOW}${ARGO_PASSWORD}${NC}"
echo -e "${MAGENTA}========================================================${NC}\n"
