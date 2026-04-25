#!/usr/bin/env bash
# Shared bash helpers for Kubernetes modules
# Source this file after exporting KUBECTL, JQ, HELM, OPENSSL, IP, DOMAIN, SUBDOMAIN, CERT_SECRET

# ============================================
# MARKER FILE FUNCTIONS
# ============================================

# Simple marker check (no config hash, for infrastructure services that rarely change)
check_marker() {
  local marker_file="$1"
  if [ -f "$marker_file" ]; then
    echo "Service already installed (marker: $marker_file)"
    exit 0
  fi
}

# Hash-aware marker check: re-runs if config changed
# The marker stores a hash. If the expected hash differs, the service is re-installed.
check_marker_hash() {
  local marker_file="$1"
  local expected_hash="$2"
  if [ -f "$marker_file" ]; then
    local stored_hash
    stored_hash=$(cat "$marker_file" 2>/dev/null || echo "")
    if [ "$stored_hash" = "$expected_hash" ]; then
      echo "Service up to date (marker: $marker_file)"
      exit 0
    else
      echo "Configuration changed (stored: ${stored_hash:0:12}..., expected: ${expected_hash:0:12}...), upgrading..."
    fi
  fi
}

create_marker() {
  local marker_file="$1"
  local hash="${2:-}"
  if [ -n "$hash" ]; then
    echo "$hash" > "$marker_file"
  else
    touch "$marker_file"
  fi
  echo "Setup completed"
}

setup_preamble() {
  local marker_file="$1"
  local service_name="$2"
  set -e
  # KUBECONFIG is set by libShSource from lib.nix (engine-aware)
  check_marker "$marker_file"
  echo "Installing $service_name..."
}

# Like setup_preamble but with config hash detection
setup_preamble_hash() {
  local marker_file="$1"
  local service_name="$2"
  local config_hash="$3"
  set -e
  check_marker_hash "$marker_file" "$config_hash"
  echo "Installing $service_name..."
}

# ============================================
# WAIT FUNCTIONS
# ============================================

wait_for_k3s() {
  echo "Waiting for K3s..."
  local attempt=0
  local max_attempts=20
  local base_delay=3
  local max_delay=30

  while [ $attempt -lt $max_attempts ]; do
    if $KUBECTL get nodes &>/dev/null; then
      echo "K3s is ready"
      break
    fi

    local delay=$((base_delay * (2 ** (attempt / 3))))
    [ $delay -gt $max_delay ] && delay=$max_delay

    local jitter=$((RANDOM % (delay / 3 + 1)))
    local total_delay=$((delay + jitter))

    echo "Waiting for K3s... (attempt $((attempt + 1))/$max_attempts, delay: ${total_delay}s)"
    sleep $total_delay
    attempt=$((attempt + 1))
  done

  if ! $KUBECTL get nodes &>/dev/null 2>&1; then
    echo "ERROR: K3s not available after $max_attempts attempts"
    exit 1
  fi

  # Skip the Ready wait for CNI bootstrap: the CNI installer (e.g. Calico
  # via tigera-operator) runs inside a *-setup.service that itself calls
  # wait_for_k3s. The node cannot become Ready without a CNI, so waiting
  # here would deadlock the first boot. Callers that need a Ready node
  # should use wait_for_deployment/wait_for_pod for their own workload.
  if [ "${SKIP_NODE_READY:-}" = "1" ]; then
    echo "SKIP_NODE_READY=1 set, not waiting for node Ready"
  else
    echo "Waiting for node to become Ready..."
    if ! $KUBECTL wait --for=condition=Ready node --all --timeout=300s; then
      echo "ERROR: Node did not reach Ready state within 5 minutes"
      exit 1
    fi
    echo "Node is Ready (CNI initialized)"
  fi

  if [ "${K8S_CNI:-flannel}" = "flannel" ]; then
    echo "Waiting for Flannel subnet.env..."
    for i in $(seq 1 60); do
      if [ -f /run/flannel/subnet.env ]; then
        echo "Flannel subnet.env available"
        break
      fi
      echo "Waiting for Flannel subnet.env... ($i/60)"
      sleep 5
    done
    if [ ! -f /run/flannel/subnet.env ]; then
      echo "ERROR: Flannel subnet.env not found after 5 minutes"
      exit 1
    fi

    echo "Waiting for cni0 bridge to come UP..."
    for i in $(seq 1 60); do
      if $IP link show cni0 2>/dev/null | grep -q "state UP"; then
        echo "cni0 bridge is UP"
        return 0
      fi
      echo "Waiting for cni0 bridge... ($i/60)"
      sleep 5
    done
    echo "WARN: cni0 bridge not UP after 5 minutes, continuing anyway"
  else
    echo "Using ${K8S_CNI} CNI, skipping Flannel-specific checks"
  fi
}

wait_for_traefik() {
  echo "Waiting for Traefik..."
  local attempt=0
  local max_attempts=15
  local base_delay=5
  local max_delay=20

  while [ $attempt -lt $max_attempts ]; do
    if $KUBECTL get svc -n traefik-system traefik &>/dev/null; then
      echo "Traefik is ready"
      break
    fi
    local delay=$((base_delay + (attempt * 2)))
    [ $delay -gt $max_delay ] && delay=$max_delay
    local jitter=$((RANDOM % 3))
    echo "Waiting for Traefik... (attempt $((attempt + 1))/$max_attempts)"
    sleep $((delay + jitter))
    attempt=$((attempt + 1))
  done
  if ! $KUBECTL get svc -n traefik-system traefik &>/dev/null 2>&1; then
    echo "ERROR: Traefik not available"
    exit 1
  fi
}

wait_for_certificate() {
  echo "Waiting for wildcard certificate..."
  local attempt=0
  local max_attempts=15
  local base_delay=5
  local max_delay=20

  while [ $attempt -lt $max_attempts ]; do
    if $KUBECTL get secret "$CERT_SECRET" -n traefik-system &>/dev/null; then
      echo "Wildcard certificate available"
      break
    fi
    local delay=$((base_delay + (attempt * 2)))
    [ $delay -gt $max_delay ] && delay=$max_delay
    local jitter=$((RANDOM % 3))
    echo "Waiting for certificate... (attempt $((attempt + 1))/$max_attempts)"
    sleep $((delay + jitter))
    attempt=$((attempt + 1))
  done
  if ! $KUBECTL get secret "$CERT_SECRET" -n traefik-system &>/dev/null 2>&1; then
    echo "ERROR: Wildcard certificate not available"
    exit 1
  fi
}

wait_for_resource() {
  local resource="$1"
  local namespace="$2"
  local name="$3"
  local timeout="${4:-180}"
  echo "Waiting for $resource/$name in $namespace..."
  local iterations=$((timeout / 5))
  for i in $(seq 1 $iterations); do
    if $KUBECTL get "$resource" "$name" -n "$namespace" &>/dev/null; then
      echo "$resource/$name available"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: $resource/$name not available after ${timeout}s"
  return 1
}

wait_for_pod() {
  local namespace="$1"
  local selector="$2"
  local timeout="${3:-300}"
  echo "Waiting for pod with selector $selector..."
  $KUBECTL wait --namespace "$namespace" \
    --for=condition=ready pod \
    --selector="$selector" \
    --timeout="${timeout}s" || true
}

wait_for_deployment() {
  local namespace="$1"
  local name="$2"
  local timeout="${3:-300}"
  echo "Waiting for deployment $name..."
  $KUBECTL wait --namespace "$namespace" \
    --for=condition=available "deployment/$name" \
    --timeout="${timeout}s" || true
}

# ============================================
# NAMESPACE & CERTIFICATE FUNCTIONS
# ============================================

ensure_namespace() {
  local ns="$1"
  local pss_level="${2:-baseline}"
  $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f -

  # Pod Security Standard is widened-wins: if the namespace is already labelled
  # at a more permissive level (e.g. "privileged" set by another workload in
  # the same NS), keep it. Otherwise overwriting with "baseline" would evict
  # privileged pods like jellyfin (hostPath /dev/dri).
  local current
  current=$($KUBECTL get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
  _pss_rank() {
    case "$1" in
      privileged) echo 3 ;;
      baseline) echo 2 ;;
      restricted) echo 1 ;;
      *) echo 0 ;;
    esac
  }
  local final="$pss_level"
  if [ -n "$current" ] && [ "$(_pss_rank "$current")" -gt "$(_pss_rank "$pss_level")" ]; then
    final="$current"
  fi

  $KUBECTL label --overwrite namespace "$ns" \
    "pod-security.kubernetes.io/enforce=$final" \
    "pod-security.kubernetes.io/warn=$final" \
    "pod-security.kubernetes.io/audit=$final"
}

# ============================================
# INGRESS ROUTE FUNCTIONS
# ============================================

create_ingress_route() {
  local name="$1"
  local namespace="$2"
  local host="$3"
  local svc="$4"
  local port="$5"
  shift 5

  # Always attach the HSTS headers middleware (lives in traefik-system, see traefik.nix)
  local middleware_section="      middlewares:
        - name: hsts-headers
          namespace: traefik-system"
  for mw_spec in "$@"; do
    local mw_name="${mw_spec%%:*}"
    local mw_ns="${mw_spec##*:}"
    middleware_section="$middleware_section
        - name: $mw_name
          namespace: $mw_ns"
  done

  # TLS is handled by the default TLSStore in traefik-system (see tls-secret.nix).
  # IngressRoutes don't reference a per-namespace secret, avoiding wildcard key duplication.
  cat <<EOF | $KUBECTL apply --server-side --force-conflicts -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: $name
  namespace: $namespace
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`$host\`)
      kind: Rule
$middleware_section
      services:
        - name: $svc
          port: $port
  tls:
    store:
      name: default
      namespace: traefik-system
EOF
}

create_ingress_route_api_bypass() {
  local name="$1"
  local namespace="$2"
  local host="$3"
  local svc="$4"
  local port="$5"
  shift 5

  # Always attach the HSTS headers middleware
  local middleware_section="      middlewares:
        - name: hsts-headers
          namespace: traefik-system"
  for mw_spec in "$@"; do
    local mw_name="${mw_spec%%:*}"
    local mw_ns="${mw_spec##*:}"
    middleware_section="$middleware_section
        - name: $mw_name
          namespace: $mw_ns"
  done

  # TLS via default TLSStore (see tls-secret.nix)
  cat <<EOF | $KUBECTL apply --server-side --force-conflicts -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: $name
  namespace: $namespace
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`$host\`) && PathPrefix(\`/api\`)
      kind: Rule
      services:
        - name: $svc
          port: $port
    - match: Host(\`$host\`)
      kind: Rule
$middleware_section
      services:
        - name: $svc
          port: $port
  tls:
    store:
      name: default
      namespace: traefik-system
EOF
}

# ============================================
# PVC FUNCTIONS
# ============================================

create_pvc() {
  local name="$1"
  local namespace="$2"
  local size="$3"
  cat <<EOF | $KUBECTL apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $name
  namespace: $namespace
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: $size
EOF
}

wait_for_shared_data() {
  local namespace="$1"
  echo "Waiting for PVC shared-data..."
  for i in $(seq 1 60); do
    if $KUBECTL get pvc shared-data -n "$namespace" &>/dev/null; then
      local STATUS
      STATUS=$($KUBECTL get pvc shared-data -n "$namespace" -o jsonpath='{.status.phase}')
      if [ "$STATUS" = "Bound" ]; then
        echo "PVC shared-data available and Bound"
        break
      fi
    fi
    sleep 5
  done
}

# ============================================
# HELM FUNCTIONS
# ============================================

helm_repo_add() {
  local name="$1"
  local url="$2"
  $HELM repo add "$name" "$url" --force-update || true
}

helm_install() {
  local name="$1"
  local chart="$2"
  local namespace="$3"
  local timeout="$4"
  shift 4

  # Bash array preserves values with spaces (e.g. CIDR lists, comma-separated
  # config). A plain string would word-split during command expansion.
  local -a set_flags=()
  for kv in "$@"; do
    set_flags+=(--set "$kv")
  done

  if ! $HELM upgrade --install "$name" "$chart" \
    --namespace "$namespace" \
    --create-namespace \
    "${set_flags[@]}" \
    --wait \
    --timeout "$timeout" 2>&1; then
    echo "Helm upgrade failed, retrying with --force..."
    $HELM upgrade --install "$name" "$chart" \
      --namespace "$namespace" \
      --create-namespace \
      "${set_flags[@]}" \
      --wait \
      --force \
      --timeout "$timeout"
  fi
}

# ============================================
# UTILITY FUNCTIONS
# ============================================

get_secret_value() {
  local ns="$1" secret="$2" key="$3"
  $KUBECTL get secret "$secret" -n "$ns" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
}

store_credentials() {
  local ns="$1" secret_name="$2"
  shift 2
  # Array preserves values with spaces or shell metacharacters (e.g. OIDC
  # role-attribute expressions). A flat string would word-split.
  local -a literal_args=()
  for kv in "$@"; do
    literal_args+=("--from-literal=$kv")
  done
  $KUBECTL create secret generic "$secret_name" \
    --namespace "$ns" "${literal_args[@]}" \
    --dry-run=client -o yaml | $KUBECTL apply -f -
  $KUBECTL label secret "$secret_name" -n "$ns" k8s/credential=true --overwrite 2>/dev/null || true
}

generate_password() {
  local length="$1"
  $OPENSSL rand -base64 "$length" | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

generate_hex() {
  local length="$1"
  $OPENSSL rand -hex "$length"
}

hostname() {
  echo "$1.$SUBDOMAIN.$DOMAIN"
}

print_success() {
  local service_name="$1"
  shift
  echo ""
  echo "========================================="
  echo "$service_name installed successfully"
  echo ""
  for line in "$@"; do
    echo "$line"
  done
  echo "========================================="
  echo ""
}

# ============================================
# CLEANUP FUNCTIONS
# ============================================

cleanup_namespace() {
  local ns="$1"

  if ! $KUBECTL get namespace "$ns" &>/dev/null; then
    echo "Namespace $ns does not exist, skipping cleanup"
    return 0
  fi

  echo "Cleaning up namespace: $ns"

  # Uninstall all Helm releases first
  local releases
  releases=$($HELM list -n "$ns" -q 2>/dev/null || echo "")
  for release in $releases; do
    echo "  Uninstalling Helm release: $release"
    $HELM uninstall "$release" -n "$ns" --wait --timeout 5m || true
  done

  # Delete workload resources (NOT PVCs)
  for resource in deployments statefulsets daemonsets replicasets jobs cronjobs; do
    $KUBECTL delete "$resource" --all -n "$ns" --timeout=60s --ignore-not-found=true 2>/dev/null || true
  done

  # Delete network resources
  for resource in services ingresses; do
    $KUBECTL delete "$resource" --all -n "$ns" --ignore-not-found=true 2>/dev/null || true
  done

  # Delete Traefik CRDs
  $KUBECTL delete ingressroutes.traefik.io --all -n "$ns" --ignore-not-found=true 2>/dev/null || true
  $KUBECTL delete middlewares.traefik.io --all -n "$ns" --ignore-not-found=true 2>/dev/null || true

  # Delete config resources
  $KUBECTL delete configmaps --all -n "$ns" --ignore-not-found=true 2>/dev/null || true
  $KUBECTL delete secrets -n "$ns" -l 'k8s/credential!=true' --ignore-not-found=true 2>/dev/null || true

  echo "Cleanup completed for namespace $ns (PVCs preserved)"
}
