#!/usr/bin/env bash
# L0/local/down.sh — delete the local kind cluster and withdraw the contract.
#
# This destroys the cluster and every PV on it. There is no L1 teardown to run
# first: deleting the cluster deletes Argo, the mesh, and the operators with it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER="maal-local"

log(){ printf '>> %s\n' "$*"; }

if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  log "cluster '${CLUSTER}' does not exist — nothing to do"
else
  if [[ "${FORCE:-}" != "1" ]]; then
    read -rp "Delete kind cluster '${CLUSTER}' and all its data? [y/N] " a
    [[ "${a}" == "y" || "${a}" == "Y" ]] || { echo "aborted"; exit 0; }
  fi
  log "deleting cluster '${CLUSTER}'"
  kind delete cluster --name "${CLUSTER}"
fi

# Stop the optional LB shim if it is running.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "cloud-provider-kind"; then
  log "stopping cloud-provider-kind"
  docker rm -f cloud-provider-kind >/dev/null
fi

# Withdraw the contract — a stale contract.json pointing at a dead cluster is
# worse than no contract at all.
rm -f "${HERE}/contract.json" "${HERE}/kubeconfig"

log "L0 down. Contract withdrawn."
