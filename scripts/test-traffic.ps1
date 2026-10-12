<#
.SYNOPSIS
    Demonstrates KEDA queue-driven autoscaling for the LLM Inference Service.
.DESCRIPTION
    Generates concurrent streaming requests to push llm_active_request_queue > 5,
    queries Prometheus in real time, and watches pods scale up dynamically.
#>

param(
    [int]$Concurrency = 15,
    [int]$DurationSeconds = 45,
    [string]$Endpoint = "http://localhost:8080/v1/chat/completions"
)

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ">>> KEDA Event-Driven Autoscaling Load Test" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "Target Endpoint    : $Endpoint" -ForegroundColor White
Write-Host "Concurrent Clients : $Concurrency" -ForegroundColor White
Write-Host "Test Duration      : $DurationSeconds seconds" -ForegroundColor White
Write-Host "Scaling Threshold  : > 5 in-flight queue depth" -ForegroundColor Yellow
Write-Host "========================================================`n" -ForegroundColor Cyan

# Check initial pod count
Write-Host "[-] Current pod count before load:" -ForegroundColor Yellow
kubectl get pods -n llm-inference -l app=llm-service

$scriptBlock = {
    param($url, $endTime)
    $body = @{
        model = "mock-llm-7b"
        messages = @(@{ role = "user"; content = "Generate high throughput responses" })
        stream = $false
    } | ConvertTo-Json

    while ((Get-Date) -lt $endTime) {
        try {
            Invoke-RestMethod -Uri "$url?simulate_latency_ms=400" -Method Post -ContentType "application/json" -Body $body -TimeoutSec 10 | Out-Null
        } catch {
            # Catch transient failures
        }
        Start-Sleep -Milliseconds 50
    }
}

$endTime = (Get-Date).AddSeconds($DurationSeconds)
$jobs = @()

Write-Host "`n[+] Spawning $Concurrency concurrent traffic generator background jobs..." -ForegroundColor Green
for ($i = 1; $i -le $Concurrency; $i++) {
    $jobs += Start-Job -ScriptBlock $scriptBlock -ArgumentList $Endpoint, $endTime
}

Write-Host "[+] Traffic generation active. Monitoring Prometheus queue depth and KEDA pod scaling...`n" -ForegroundColor Green

$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
while ($stopWatch.Elapsed.TotalSeconds -lt $DurationSeconds) {
    # Query Prometheus metric for queue depth
    $queueDepth = "N/A"
    try {
        $promResponse = Invoke-RestMethod -Uri "http://localhost:9091/api/v1/query?query=sum(llm_active_request_queue{app='llm-service'})" -Method Get -TimeoutSec 3
        if ($promResponse.data.result.Count -gt 0) {
            $queueDepth = $promResponse.data.result[0].value[1]
        }
    } catch {
        $queueDepth = "Metric query pending..."
    }

    $elapsed = [int]$stopWatch.Elapsed.TotalSeconds
    $remaining = $DurationSeconds - $elapsed
    Write-Host "[$elapsed s] Prometheus Queue Depth: $queueDepth | Remaining: $remaining s" -ForegroundColor Cyan

    # Show pod status
    kubectl get pods -n llm-inference -l app=llm-service --no-headers | ForEach-Object {
        Write-Host "   $_" -ForegroundColor Gray
    }

    Start-Sleep -Seconds 4
}

Write-Host "`n[-] Load generation period completed. Cleaning up background jobs..." -ForegroundColor Yellow
$jobs | Stop-Job -ErrorAction SilentlyContinue | Remove-Job -ErrorAction SilentlyContinue

Write-Host "`n[+] Current status after load spike:" -ForegroundColor Green
kubectl get pods -n llm-inference -l app=llm-service
Write-Host "`n[+] KEDA ScaledObject status:" -ForegroundColor Green
kubectl get scaledobject llm-queue-scaler -n llm-inference
Write-Host "`n✓ Autoscaling demonstration finished! Cooldown period will downscale idle replicas.`n" -ForegroundColor Green
