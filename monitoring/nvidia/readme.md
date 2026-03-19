helm repo add nvidia https://nvidia.github.io/dcgm-exporter/helm-charts
helm repo update

helm install dcgm-exporter nvidia/dcgm-exporter \
  -f gpu-monitoring-values.yaml \
  -n monitoring