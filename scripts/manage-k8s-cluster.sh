#!/bin/bash

# A simple helper script to manage the local kind Kubernetes cluster
# Usage: ./manage-k8s-cluster.sh [start|stop|status]

CLUSTER_NAME="aerostore-dev"
CONFIG_FILE="../k8s/kind-cluster-config.yaml"

cd "$(dirname "$0")" || exit

case "$1" in
  start)
    echo "Starting local Kubernetes cluster ($CLUSTER_NAME)..."
    kind create cluster --name $CLUSTER_NAME --config $CONFIG_FILE
    echo "Done. Run 'kubectl get nodes' to verify."
    ;;
  stop)
    echo "Deleting local Kubernetes cluster ($CLUSTER_NAME)..."
    kind delete cluster --name $CLUSTER_NAME
    echo "Cluster deleted."
    ;;
  status)
    echo "Checking cluster status..."
    kind get clusters | grep -q $CLUSTER_NAME
    if [ $? -eq 0 ]; then
      echo "Cluster '$CLUSTER_NAME' is running."
      kubectl get nodes
    else
      echo "Cluster '$CLUSTER_NAME' is NOT running."
    fi
    ;;
  *)
    echo "Usage: $0 {start|stop|status}"
    exit 1
esac
