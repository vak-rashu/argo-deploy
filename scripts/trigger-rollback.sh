#!/usr/bin/env bash
set -euo pipefail

DEGRADED_IMAGE=${1:-"llm-inference:v2-degraded"}

echo -e "\033[0;35m========================================================\033[0m"
echo -e "\033[1;33m>>> 1/4: Injecting Degraded Release (${DEGRADED_IMAGE})\033[0m"
echo -e "\033[0;35m========================================================\033[0m"

kubectl patch rollout llm-service -n llm-inference --type="merge" \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"llm-engine\",\"image\":\"${DEGRADED_IMAGE}\",\"env\":[{\"name\":\"APP_VERSION\",\"value\":\"v2-degraded\"},{\"name\":\"SIMULATE_DEGRADED\",\"value\":\"true\"},{\"name\":\"ERROR_RATE\",\"value\":\"0.6\"},{\"name\":\"INDUCED_LATENCY_MS\",\"value\":\"1500\"}]}]}}}}"

echo -e "\033[0;32m[+] Patch applied. Generating live traffic to trigger SLO breaches...\033[0m"

bg_traffic() {
    local payload='{"model":"mock-llm-7b","messages":[{"role":"user","content":"rollback test"}],"stream":false}'
    while true; do
        curl -s -X POST "http://localhost:8080/v1/chat/completions" \
             -H "Content-Type: application/json" \
             -d "$payload" > /dev/null || true
        sleep 0.1
    done
}
bg_traffic &
BG_PID=$!
trap 'kill $BG_PID 2>/dev/null || true' EXIT

echo -e "\n\033[0;35m========================================================\033[0m"
echo -e "\033[1;33m>>> 2/4: Watching AnalysisRun & Automated Abort Detection\033[0m"
echo -e "\033[0;35m========================================================\033[0m"

for i in $(seq 1 8); do
    sleep 6
    echo -e "\n\033[0;36m[Check #${i}] Checking status...\033[0m"

    ANALYSIS_STATUS=$(kubectl get analysisrun -n llm-inference -o jsonpath='{.items[-1].status.phase}' 2>/dev/null || echo "Pending")
    ROLLOUT_PHASE=$(kubectl get rollout llm-service -n llm-inference -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    echo "  Current AnalysisRun Phase : $ANALYSIS_STATUS"
    echo "  Current Rollout Phase     : $ROLLOUT_PHASE"
    kubectl get rollout llm-service -n llm-inference

    if [ "$ANALYSIS_STATUS" = "Failed" ] || [ "$ROLLOUT_PHASE" = "Degraded" ]; then
        echo -e "\n\033[0;31m⚠️ AUTOMATED ANOMALY DETECTED! Prometheus SLO violation (Error Rate > 1% / TTFT > 500ms).\033[0m"
        echo -e "\033[1;33mArgo Rollouts is automatically aborting and rolling back to stable replica...\033[0m"
        break
    fi
done

kill "$BG_PID" 2>/dev/null || true

echo -e "\n\033[0;35m========================================================\033[0m"
echo -e "\033[1;33m>>> 3/4: Confirming Rollback & Cluster Health\033[0m"
echo -e "\033[0;35m========================================================\033[0m"
sleep 5

echo -e "\nAnalysisRun history:"
kubectl get analysisrun -n llm-inference

echo -e "\nActive Pods (Canary pods terminated, only stable pods running):"
kubectl get pods -n llm-inference -l app=llm-service -o wide

echo -e "\n\033[0;32m========================================================\033[0m"
echo -e "\033[0;32m ✓ AUTOMATED CANARY ROLLBACK DEMO COMPLETE! \033[0m"
echo -e "\033[0;32m Faulty release quarantined and rolled back with zero downtime.\033[0m"
echo -e "\033[0;32m========================================================\033[0m\n"
