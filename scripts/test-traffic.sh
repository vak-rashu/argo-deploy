#!/usr/bin/env bash
set -euo pipefail

CONCURRENCY=${1:-15}
DURATION_SECONDS=${2:-45}
ENDPOINT="http://localhost:8080/v1/chat/completions"

echo -e "\033[0;36m========================================================\033[0m"
echo -e "\033[0;32m>>> KEDA Event-Driven Autoscaling Load Test\033[0m"
echo -e "\033[0;36m========================================================\033[0m"
echo "Target Endpoint    : $ENDPOINT"
echo "Concurrent Clients : $CONCURRENCY"
echo "Test Duration      : $DURATION_SECONDS seconds"
echo "Scaling Threshold  : > 5 in-flight queue depth"
echo -e "\033[0;36m========================================================\033[0m\n"

echo -e "\033[1;33m[-] Current pod count before load:\033[0m"
kubectl get pods -n llm-inference -l app=llm-service

run_worker() {
    local end_time=$1
    local payload='{"model":"mock-llm-7b","messages":[{"role":"user","content":"load"}],"stream":false}'
    while [ $(date +%s) -lt $end_time ]; do
        curl -s -X POST "${ENDPOINT}?simulate_latency_ms=400" \
             -H "Content-Type: application/json" \
             -d "$payload" > /dev/null || true
        sleep 0.05
    done
}

END_TIME=$(($(date +%s) + DURATION_SECONDS))
PIDS=()

echo -e "\n\033[0;32m[+] Spawning $CONCURRENCY background worker processes...\033[0m"
for i in $(seq 1 "$CONCURRENCY"); do
    run_worker "$END_TIME" &
    PIDS+=($!)
done

cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

echo -e "\033[0;32m[+] Load generation active. Monitoring Prometheus queue depth and KEDA scaling...\033[0m\n"

START=$(date +%s)
while [ $(date +%s) -lt $END_TIME ]; do
    ELAPSED=$(($(date +%s) - START))
    REMAINING=$((DURATION_SECONDS - ELAPSED))

    QUEUE_DEPTH=$(curl -s "http://localhost:9091/api/v1/query?query=sum(llm_active_request_queue%7Bapp%3D'llm-service'%7D)" | grep -o '"value":\[[^]]*\]' | cut -d'"' -f4 || echo "N/A")

    echo -e "\033[0;36m[${ELAPSED}s] Prometheus Queue Depth: ${QUEUE_DEPTH} | Remaining: ${REMAINING}s\033[0m"
    kubectl get pods -n llm-inference -l app=llm-service --no-headers || true
    sleep 4
done

echo -e "\n\033[1;33m[-] Load generation period completed.\033[0m"
cleanup

echo -e "\n\033[0;32m[+] Current status after load spike:\033[0m"
kubectl get pods -n llm-inference -l app=llm-service
echo -e "\n\033[0;32m[+] KEDA ScaledObject status:\033[0m"
kubectl get scaledobject llm-queue-scaler -n llm-inference
echo -e "\n\033[0;32m✓ Autoscaling demonstration finished!\033[0m\n"
