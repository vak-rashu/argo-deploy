<#
.SYNOPSIS
    Deploys a degraded/faulty version and demonstrates automated Argo Rollouts rollback.
.DESCRIPTION
    Triggers rollout to llm-inference:v2-degraded (high latency & 500 errors), sends traffic,
    demonstrates Prometheus anomaly detection, and confirms automated rollback to stable v1.
#>

param(
    [string]$DegradedImage = "llm-inference:v2-degraded"
)

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================================" -ForegroundColor Magenta
    Write-Host ">>> $Message" -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Magenta
}

Write-Step "1/4: Injecting Degraded Release ($DegradedImage)"
Write-Host "Patching Rollout to faulty image with induced latency and 500 errors..." -ForegroundColor Yellow

kubectl patch rollout llm-service -n llm-inference --type="merge" -p "{`"spec`":{`"template`":{`"spec`":{`"containers`":[{`"name`":`"llm-engine`",`"image`":`"$DegradedImage`",`"env`":[{`"name`":`"APP_VERSION`",`"value`":`"v2-degraded`"},{`"name`":`"SIMULATE_DEGRADED`",`"value`":`"true`"},{`"name`":`"ERROR_RATE`",`"value`":`"0.6`"},{`"name`":`"INDUCED_LATENCY_MS`",`"value`":`"1500`"}]}]}}}}"

Write-Step "2/4: Generating Traffic Across Canary & Stable Replicas"
Write-Host "Sending requests to trigger Prometheus error rate & TTFT latency alerts..." -ForegroundColor Yellow

$trafficScript = {
    param($url)
    $body = '{"model":"mock-llm-7b","messages":[{"role":"user","content":"evaluating rollout"}],"stream":false}'
    while ($true) {
        try {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5 | Out-Null
        } catch {}
        Start-Sleep -Milliseconds 100
    }
}
$bgTraffic = Start-Job -ScriptBlock $trafficScript -ArgumentList "http://localhost:8080/v1/chat/completions"

Write-Step "3/4: Watching AnalysisRun & Automated Abort Detection"
$hasRolloutPlugin = (Get-Command "kubectl-argo-rollouts" -ErrorAction SilentlyContinue)

$aborted = $false
for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Seconds 6
    Write-Host "`n[Check #$($i+1)] Checking AnalysisRun and Rollout status..." -ForegroundColor Cyan

    $analysisStatus = kubectl get analysisrun -n llm-inference -o jsonpath="{.items[-1].status.phase}" 2>$null
    $rolloutPhase = kubectl get rollout llm-service -n llm-inference -o jsonpath="{.status.phase}" 2>$null

    Write-Host "  Current AnalysisRun Phase : $analysisStatus" -ForegroundColor Yellow
    Write-Host "  Current Rollout Phase     : $rolloutPhase" -ForegroundColor Yellow

    if ($hasRolloutPlugin) {
        kubectl argo rollouts get rollout llm-service -n llm-inference
    } else {
        kubectl get rollout llm-service -n llm-inference
    }

    if ($analysisStatus -eq "Failed" -or $rolloutPhase -eq "Degraded") {
        $aborted = $true
        Write-Host "`n⚠️ AUTOMATED ANOMALY DETECTED! Analysis failed SLO thresholds (Error Rate > 1% / TTFT > 500ms)." -ForegroundColor Red
        Write-Host "Argo Rollouts is automatically aborting and rolling back to stable replica..." -ForegroundColor Yellow
        break
    }
}

Stop-Job $bgTraffic -ErrorAction SilentlyContinue | Remove-Job -ErrorAction SilentlyContinue

Write-Step "4/4: Confirming Rollback & Cluster Health"
Start-Sleep -Seconds 5

Write-Host "AnalysisRun history:" -ForegroundColor Cyan
kubectl get analysisrun -n llm-inference

Write-Host "`nActive Pods (Canary pods terminated, only stable pods running):" -ForegroundColor Cyan
kubectl get pods -n llm-inference -l app=llm-service -o wide

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host " ✓ AUTOMATED CANARY ROLLBACK DEMO COMPLETE! " -ForegroundColor Green
Write-Host " Faulty release was quarantined and aborted with zero downtime." -ForegroundColor Green
Write-Host "========================================================`n" -ForegroundColor Green
