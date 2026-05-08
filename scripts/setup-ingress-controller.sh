#!/usr/bin/env bash
# scripts/setup-ingress-controller.sh
#
# Installs and verifies the nginx Ingress Controller in a kind cluster.
#
# Usage:
#   chmod +x scripts/setup-ingress-controller.sh
#   ./scripts/setup-ingress-controller.sh
#
# After this script completes, apply the Ingress resource:
#   kubectl apply -f k8s/basics/nginx-ingress-local.yaml
#
# Then access the application at:
#   http://localhost/       → frontend
#   http://localhost/api/   → backend API

set -e  # Exit on any error

echo ""
echo "=================================================================="
echo " AeroStore — nginx Ingress Controller Setup"
echo "=================================================================="
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 1: Verify cluster is running
# ─────────────────────────────────────────────────────────────────────────
echo "[1/5] Verifying kind cluster is running..."
kubectl cluster-info --request-timeout=5s
echo "      ✓ Cluster is reachable"
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 2: Install the nginx Ingress Controller (kind-specific manifest)
#
# The kind-specific deploy.yaml configures the controller to use
# hostNetwork mode, which allows it to bind directly to the host's
# port 80 (mapped via kind extraPortMappings in kind-cluster-config.yaml).
# ─────────────────────────────────────────────────────────────────────────
echo "[2/5] Installing nginx Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
echo "      Resources applied. Waiting for controller Pod to start..."
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 3: Wait for the controller to be ready
# ─────────────────────────────────────────────────────────────────────────
echo "[3/5] Waiting for Ingress Controller to be ready (up to 120s)..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
echo "      ✓ Ingress Controller Pod is Running"
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 4: Apply the local Ingress resource
# ─────────────────────────────────────────────────────────────────────────
echo "[4/5] Applying AeroStore Ingress resource..."
kubectl apply -f k8s/basics/nginx-ingress-local.yaml
echo "      ✓ Ingress resource applied"
echo ""

# ─────────────────────────────────────────────────────────────────────────
# Step 5: Show current state and access instructions
# ─────────────────────────────────────────────────────────────────────────
echo "[5/5] Verification..."
echo ""
echo "Ingress Controller Pods:"
kubectl get pods -n ingress-nginx
echo ""
echo "Ingress Resource:"
kubectl get ingress aerostore-local-ingress
echo ""
echo "Services:"
kubectl get svc | grep -E "aerostore|NAME"
echo ""
echo "=================================================================="
echo " ✓ Setup complete!"
echo ""
echo " Access the application:"
echo "   Frontend:  http://localhost/"
echo "   Backend:   http://localhost/api/"
echo ""
echo " Debug commands:"
echo "   kubectl describe ingress aerostore-local-ingress"
echo "   kubectl logs -n ingress-nginx deploy/ingress-nginx-controller"
echo "   kubectl get ingress -A"
echo "=================================================================="
