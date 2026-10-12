<#
.SYNOPSIS
    Bootstrap script for Production-Grade GitOps LLM Inference Platform on Kind.
.DESCRIPTION
    Creates multi-node Kind cluster, installs Argo CD, Argo Rollouts, Prometheus,
    and KEDA, builds and loads LLM container images, and deploys the GitOps stack.
#>

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host ">>> $Message" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Cyan
}

function Write-Info {
    param([string]$Message)
    Write-Host "[-] $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Green
}

# 1. Check Prerequisites
Write-Step "1/6: Verifying Prerequisites"
$tools = @("docker", "kind", "kubectl")
foreach ($tool in $tools) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "Required tool '$tool' is not installed or not in PATH."
        exit 1
    }
    Write-Success "Found: $tool"
}

# 2. Kind Cluster Provisioning
Write-Step "2/6: Creating Kind Cluster (llm-gitops-cluster)"
$clusterName = "llm-gitops-cluster"
$existingClusters = kind get clusters
if ($existingClusters -contains $clusterName) {
    Write-Info "Cluster '$clusterName' already exists. Deleting to ensure clean state..."
    kind delete cluster --name $clusterName
}

Write-Info "Creating multi-node cluster using kind-config.yaml..."
kind create cluster --config kind-config.yaml

# 3. Build & Load Container Images
Write-Step "3/6: Building and Loading LLM Inference Images"
Write-Info "Building baseline healthy image: llm-inference:v1 ..."
docker build --build-arg APP_VERSION=v1 -t llm-inference:v1 app/

Write-Info "Building healthy canary upgrade image: llm-inference:v2 ..."
docker build --build-arg APP_VERSION=v2 -t llm-inference:v2 app/

Write-Info "Building degraded image: llm-inference:v2-degraded (fault injection) ..."
docker build --build-arg APP_VERSION=v2-degraded --build-arg SIMULATE_DEGRADED=true -t llm-inference:v2-degraded app/

Write-Info "Loading images into Kind cluster (no external registry required)..."
kind load docker-image llm-inference:v1 --name $clusterName
kind load docker-image llm-inference:v2 --name $clusterName
kind load docker-image llm-inference:v2-degraded --name $clusterName
Write-Success "All container images loaded into Kind nodes."

# 4. Install Infrastructure Platform Manifests
Write-Step "4/6: Installing Infrastructure Components"

# A. Prometheus
Write-Info "Deploying lightweight Prometheus instance..."
kubectl apply -f infra/prometheus/rbac.yaml
kubectl apply -f infra/prometheus/configmap.yaml
kubectl apply -f infra/prometheus/deployment.yaml

# B. Argo Rollouts
Write-Info "Installing Argo Rollouts Controller and CRDs..."
kubectl apply --server-side -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# C. KEDA Operator
Write-Info "Installing KEDA Event-driven Autoscaler..."
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.14.0/keda-2.14.0.yaml

# D. Argo CD
Write-Info "Installing Argo CD..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f infra/argocd/patch-nodeport.yaml

# 5. Wait for Platform Readiness
Write-Step "5/6: Waiting for Platform Controllers to be Ready"
Write-Info "Waiting for Prometheus deployment..."
kubectl wait --for=condition=Available deployment/prometheus -n monitoring --timeout=120s

Write-Info "Waiting for Argo Rollouts controller..."
kubectl wait --for=condition=Available deployment/argo-rollouts -n argo-rollouts --timeout=120s

Write-Info "Waiting for KEDA operator..."
kubectl wait --for=condition=Available deployment/keda-operator -n keda --timeout=180s

Write-Info "Waiting for Argo CD server..."
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s

# 6. Deploy Application Workload via GitOps
Write-Step "6/6: Deploying LLM Inference Service"
kubectl apply -f gitops/services.yaml
kubectl apply -f gitops/analysis-template.yaml
kubectl apply -f gitops/rollout.yaml
kubectl apply -f gitops/keda-scaledobject.yaml

try {
    kubectl wait --for=condition=Healthy rollout/llm-service -n llm-inference --timeout=120s 2>$null
} catch {
    Start-Sleep -Seconds 10
}

# Retrieve Argo CD Admin Password
$encodedPassword = kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>$null
$argoPassword = "admin"
if ($encodedPassword) {
    $argoPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedPassword))
}

Write-Host "`n========================================================" -ForegroundColor Magenta
Write-Host " 🎉 PLATFORM BOOTSTRAP COMPLETE! " -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Magenta
Write-Host "Services available on localhost:" -ForegroundColor Cyan
Write-Host "  • LLM Inference Gateway : http://localhost:8080/v1/chat/completions" -ForegroundColor White
Write-Host "  • Prometheus Dashboard  : http://localhost:9091" -ForegroundColor White
Write-Host "  • Argo CD Dashboard     : http://localhost:8081" -ForegroundColor White
Write-Host "    Username              : admin" -ForegroundColor Yellow
Write-Host "    Initial Password      : $argoPassword" -ForegroundColor Yellow
Write-Host "========================================================`n" -ForegroundColor Magenta
