# Argo Rollouts Infrastructure

Argo Rollouts provides advanced progressive delivery capabilities (Canary, Blue/Green, AnalysisRuns) to Kubernetes clusters.

## Installation
The controller and CRDs are installed into the `argo-rollouts` namespace:

```powershell
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

## kubectl Rollouts Plugin (Optional CLI visualization)
For visual tracking of canary releases in real-time:
```powershell
# On Windows via Scoop / Chocolatey / direct curl:
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-windows-amd64.exe
Move-Item kubectl-argo-rollouts-windows-amd64.exe (Get-Command kubectl).Path.Replace("kubectl.exe", "kubectl-argo-rollouts.exe")

# Dashboard UI (runs on http://localhost:3100):
kubectl argo rollouts dashboard
```
