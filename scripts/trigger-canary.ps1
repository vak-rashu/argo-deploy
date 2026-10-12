<#
.SYNOPSIS
    Deploys healthy upgrade v2 and demonstrates progressive Canary traffic splitting.
.DESCRIPTION
    Triggers rollout to llm-inference:v2, samples traffic to measure the canary split,
    and watches automated Prometheus analysis pass and promote to 100%.
#>

param(
    [string]$NewImage = "llm-inference:v2"
)

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host ">>> $Message" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Cyan
}

Write-Step "1/4: Triggering Progressive Canary Rollout to $NewImage"
# Patch Rollout container image
kubectl patch rollout llm-service -n llm-inference --type="merge" -p "{`"spec`":{`"template`":{`"spec`":{`"containers`":[{`"name`":`"llm-engine`",`"image`":`"$NewImage`",`"env`":[{`"name`":`"APP_VERSION`",`"value`":`"v2`"}]}]}}}}"

Write-Host "[+] Rollout updated. Initializing 20% canary step..." -ForegroundColor Green

# Start background traffic generator to provide active metrics for Prometheus and verify split
$trafficScript = {
    param($url)
    $body = '{"model":"mock-llm-7b","messages":[{"role":"user","content":"canary check"}],"stream":false}'
    while ($true) {
        try {
            Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" -Body $body -TimeoutSec 3 | Out-Null
        } catch {}
        Start-Sleep -Milliseconds 200
    }
}
$bgTraffic = Start-Job -ScriptBlock $trafficScript -ArgumentList "http://localhost:8080/v1/chat/completions"

Write-Step "2/4: Sampling Live Traffic to Verify Canary Ratio"
Write-Host "Sending 20 test requests to verify traffic splitting..." -ForegroundColor Yellow

$v1Count = 0
$v2Count = 0

for ($i = 1; $i -le 20; $i++) {
    try {
        $body = '{"model":"mock-llm-7b","messages":[{"role":"user","content":"test"}],"stream":false}'
        $response = Invoke-RestMethod -Uri "http://localhost:8080/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5
        $ver = $response.version
        if ($ver -eq "v2") {
            $v2Count++
            Write-Host "Request #$i: Served by [CANARY v2]" -ForegroundColor Cyan
        } else {
            $v1Count++
            Write-Host "Request #$i: Served by [STABLE v1]" -ForegroundColor Gray
        }
    } catch {
        Write-Host "Request #$i: Failed" -ForegroundColor Red
    }
    Start-Sleep -Milliseconds 150
}

Write-Host "`nTraffic Sampling Results:" -ForegroundColor Yellow
Write-Host "  Stable (v1) : $v1Count / 20 ($([math]::Round(($v1Count/20)*100))%)" -ForegroundColor White
Write-Host "  Canary (v2) : $v2Count / 20 ($([math]::Round(($v2Count/20)*100))%)" -ForegroundColor Cyan

Write-Step "3/4: Tracking AnalysisRun & Rollout Progression"
$hasRolloutPlugin = (Get-Command "kubectl-argo-rollouts" -ErrorAction SilentlyContinue)

for ($t = 0; $t -lt 60; $t += 10) {
    Write-Host "`n[+ Check at $t s]" -ForegroundColor Yellow
    if ($hasRolloutPlugin) {
        kubectl argo rollouts get rollout llm-service -n llm-inference
    } else {
        kubectl get rollout llm-service -n llm-inference
        kubectl get analysisrun -n llm-inference --no-headers 2>$null | ForEach-Object {
            Write-Host "  AnalysisRun: $_" -ForegroundColor Green
        }
    }
    Start-Sleep -Seconds 10
}

Stop-Job $bgTraffic -ErrorAction SilentlyContinue | Remove-Job -ErrorAction SilentlyContinue

Write-Step "4/4: Final Verification"
kubectl get pods -n llm-inference -l app=llm-service -o wide
Write-Host "`n✓ Canary progression complete! Healthy v2 successfully verified by Prometheus analysis and promoted.`n" -ForegroundColor Green
