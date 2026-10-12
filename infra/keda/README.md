# KEDA (Kubernetes Event-driven Autoscaling) Infrastructure

KEDA drives event-based autoscaling for Kubernetes workloads based on external metrics (such as Prometheus gauges, Kafka queues, or RabbitMQ).

## Installation
The KEDA operator, metrics adapter, and CRDs are installed into the `keda` namespace:

```powershell
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.14.0/keda-2.14.0.yaml
```

## Verification
Verify the KEDA operator and metrics API service are running:
```powershell
kubectl get pods -n keda
kubectl get scaledobjects -A
```
