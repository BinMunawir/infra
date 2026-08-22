#!/usr/bin/env bash
# L1/bootstrap/down.sh — tear down L1, leaving the L0 cluster intact.
#
# For a clean slate you almost always want `just down` instead: deleting the
# cluster is faster and leaves nothing behind. This script is for the rarer case
# of rebuilding the platform on a cluster you want to keep — `just down l1`.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L1="$(cd "${HERE}/.." && pwd)"
L0="$(cd "${L1}/../L0" && pwd)"
ARGOCD_NS="argocd"
VENDORED="${HERE}/argocd/install.yaml"
L0_ENV="${L0_ENV:-local}"

CONTRACT="${L0}/${L0_ENV}/contract.json"
if [[ -f "${CONTRACT}" ]]; then
  KUBECONFIG_PATH="$(jq -er .kubeconfig "${CONTRACT}")"
  [[ -f "${KUBECONFIG_PATH}" ]] && export KUBECONFIG="${KUBECONFIG_PATH}"
fi

CTX="$(kubectl config current-context 2>/dev/null || echo unknown)"
read -rp "Remove the platform apps AND Argo CD from '${CTX}'? [y/N] " a
[[ "${a}" == "y" || "${a}" == "Y" ]] || { echo "aborted"; exit 0; }

# Root first — a foreground cascade takes the ApplicationSet, the generated
# Applications, and their resources with it.
kubectl delete -f "${L1}/root/root-app.yaml" --cascade=foreground --ignore-not-found --timeout=300s || true
kubectl delete -f "${L1}/root/project.yaml"  --ignore-not-found || true

# Then Argo itself, and the credential that was never in Git.
kubectl -n "${ARGOCD_NS}" delete secret maal-infra-repo --ignore-not-found || true
[[ -f "${VENDORED}" ]] && kubectl delete -n "${ARGOCD_NS}" -f "${VENDORED}" --ignore-not-found || true
kubectl delete namespace "${ARGOCD_NS}" --ignore-not-found || true

echo ">> L1 removed. Operator CRDs may linger — prune is disabled by design, so"
echo "   nothing auto-deleted the Istio/cert-manager/ESO CRDs or what depends on them."
echo ">> Clean slate: just down && just up"
