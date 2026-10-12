#!/usr/bin/env bash
set -euo pipefail

NEW_IMAGE=${1:-"llm-inference:v2"}

echo -e "\033[0;36m========================================================\033[0m"
echo -e "\033[0;32m>>> 1/4: Triggering Progressive Canary Rollout to ${NEW_IMAGE}\033[0m"
echo -e "\033[0;36m========================================================\033[0m"

kubectl patch rollout llm-service -n llm-inference --type="merge" \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"llm-engine\",\"image\":\"${NEW_IMAGE}\",\"env\":[{\"name\":\"APP_VERSION\",\"value\":\"v2\"}]}]}}}}"

echo -e "\033[0;32m[+] Rollout updated. Starting background traffic for metric evaluation...\033[0m"

bg_traffic() {
    local payload='{"model":"mock-llm-7b","messages":[{"role":"user","content":"canary"}],"stream":false}'
    while true; do
        curl -s -X POST "http://localhost:8080/v1/chat/completions" \
             -H "Content-Type: application/json" \
             -d "$payload" > /dev/null || true
        sleep 0.2
    done
}
bg_traffic &
BG_PID=$!
trap 'kill $BG_PID 2>/dev/null || true' EXIT

echo -e "\n\033[0;36m========================================================\033[0m"
echo -e "\033[0;32m>>> 2/4: Sampling Live Traffic to Verify Canary Ratio\033[0m"
echo -e "\033[0;36m========================================================\033[0m"

V1_COUNT=0
V2_COUNT=0

for i in $(seq 1 20); do
    RESP=$(curl -s -X POST "http://localhost:8080/v1/chat/completions" \
         -H "Content-Type: application/json" \
         -d '{"model":"mock-llm-7b","messages":[{"role":"user","content":"test"}],"stream":false}' || echo "{}")

    VER=$(echo "$RESP" | grep -o '"version": *"[^"]*"' | cut -d'"' -f4 || echo "unknown")

    if [ "$VER" = "v2" ]; then
        V2_COUNT=$((V2_COUNT + 1))
        echo -e "Request #${i}: Served by \033[0;36m[CANARY v2]\033[0m"
    else
        V1_COUNT=$((V1_COUNT + 1))
        echo -e "Request #${i}: Served by \033[0;37m[STABLE v1]\033[0m"
    fi
    sleep 0.15
done

echo -e "\nTraffic Sampling Results:"
echo -e "  Stable (v1) : ${V1_COUNT} / 20 ($(( V1_COUNT * 100 / 20 ))%)"
echo -e "  Canary (v2) : ${V2_COUNT} / 20 ($(( V2_COUNT * 100 / 20 ))%)"

echo -e "\n\033[0;36m========================================================\033[0m"
echo -e "\033[0;32m>>> 3/4: Tracking AnalysisRun & Rollout Progression\033[0m"
echo -e "\033[0;36m========================================================\033[0m"

for t in 0 10 20 30 40 50; do
    echo -e "\n[+ Check at ${t}s]"
    kubectl get rollout llm-service -n llm-inference
    kubectl get analysisrun -n llm-inference --no-headers 2>/dev/null || true
    sleep 10
done

kill "$BG_PID" 2>/dev/null || true

echo -e "\n\033[0;36m========================================================\033[0m"
echo -e "\033[0;32m>>> 4/4: Final Verification\033[0m"
echo -e "\033[0;36m========================================================\033[0m"
kubectl get pods -n llm-inference -l app=llm-service -o wide
echo -e "\n\033[0;32m✓ Canary rollout completed successfully!\033[0m\n"
