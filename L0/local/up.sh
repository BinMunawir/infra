#!/usr/bin/env bash
# L0/local/up.sh — provision the local kind cluster and publish the L0 contract.
#
# Contract outputs (see ../contract.md):
#   kubeconfig   -> ./kubeconfig
#   storageClass -> standard          (kind's local-path-provisioner)
#   lbEndpoint   -> 127.0.0.1:8080    (extraPortMapping -> NodePort 30080)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CLUSTER="maal-local"
KUBECONFIG_OUT="${HERE}/kubeconfig"
CONTRACT_OUT="${HERE}/contract.json"
STORAGE_CLASS="standard"
LB_ENDPOINT="127.0.0.1:8080"

log(){ printf '>> %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
command -v kind    >/dev/null || die "kind not found — brew install kind"
command -v kubectl >/dev/null || die "kubectl not found — brew install kubectl"
command -v jq      >/dev/null || die "jq not found — brew install jq"
docker info >/dev/null 2>&1   || die "docker daemon unreachable — start Docker Desktop or 'colima start'"

# L1 wants roughly 6 CPU / 12 GiB to hold Argo + Istio + cert-manager + ESO.
CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
MEM_GIB=$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1073741824 ))
if (( CPUS < 6 || MEM_GIB < 12 )); then
  log "WARNING: docker has ${CPUS} CPU / ${MEM_GIB} GiB. L1 wants >= 6 CPU / 12 GiB."
  log "         colima: colima stop && colima start --cpu 6 --memory 12"
fi

# --- create (idempotent) ---------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "cluster '${CLUSTER}' already exists — reusing it"
else
  log "creating kind cluster '${CLUSTER}'"
  kind create cluster --name "${CLUSTER}" --config "${HERE}/kind.yaml" --wait 120s
fi

# --- kubeconfig ------------------------------------------------------------
log "exporting kubeconfig -> ${KUBECONFIG_OUT#"${HERE}/"}"
kind export kubeconfig --name "${CLUSTER}" --kubeconfig "${KUBECONFIG_OUT}"
chmod 600 "${KUBECONFIG_OUT}"

# Also register the context in the caller's default kubeconfig, so a bare
# `kubectl` works. L1's up.sh reads `kubectl config current-context`.
kind export kubeconfig --name "${CLUSTER}"

export KUBECONFIG="${KUBECONFIG_OUT}"

# --- verify the contract before publishing it ------------------------------
log "waiting for nodes to be Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null

kubectl get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1 \
  || die "StorageClass '${STORAGE_CLASS}' missing — kind's local-path-provisioner did not come up"

BINDING="$(kubectl get storageclass "${STORAGE_CLASS}" -o jsonpath='{.volumeBindingMode}')"
[[ "${BINDING}" == "WaitForFirstConsumer" ]] \
  || die "StorageClass '${STORAGE_CLASS}' has volumeBindingMode=${BINDING}, contract requires WaitForFirstConsumer"

# --- publish ---------------------------------------------------------------
jq -n \
  --arg provider     "local" \
  --arg cluster      "${CLUSTER}" \
  --arg kubeconfig   "${KUBECONFIG_OUT}" \
  --arg storageClass "${STORAGE_CLASS}" \
  --arg lbEndpoint   "${LB_ENDPOINT}" \
  '{provider:$provider, cluster:$cluster, kubeconfig:$kubeconfig, storageClass:$storageClass, lbEndpoint:$lbEndpoint}' \
  > "${CONTRACT_OUT}"

log "L0 up. Contract published -> ${CONTRACT_OUT#"${HERE}/"}"
jq . "${CONTRACT_OUT}"
echo
log "next: cd ../../L1 && just up"
