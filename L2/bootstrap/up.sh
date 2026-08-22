#!/usr/bin/env bash
# L2/bootstrap/up.sh — hand the product layer to Argo.
#
# Much smaller than L1's bootstrap, and deliberately so: Argo already exists,
# already has a repo key, and already knows how to reconcile. All this does is
# verify the contract still holds and apply two objects.
set -euo pipefail

ARGOCD_NS="argocd"
L0_ENV="${L0_ENV:-local}"
L2_ENV="${L2_ENV:-dev-local}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L2="$(cd "${HERE}/.." && pwd)"
L0="$(cd "${L2}/../L0" && pwd)"
ENV_FILE="${L2}/envs/${L2_ENV}.yaml"

log(){ printf '>> %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }

for c in kubectl jq; do command -v "$c" >/dev/null || die "$c not found"; done
[[ -f "${ENV_FILE}" ]] || die "no L2 env file: ${ENV_FILE#"${L2}/"} (set L2_ENV)"

CONTRACT="${L0}/${L0_ENV}/contract.json"
[[ -f "${CONTRACT}" ]] || die "L0 '${L0_ENV}' has published no contract — run: cd ${L0} && just ${L0_ENV}-up"

KUBECONFIG_PATH="$(jq -er .kubeconfig "${CONTRACT}")"
SC_ACTUAL="$(jq -er .storageClass     "${CONTRACT}")"
export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl get nodes >/dev/null 2>&1 || die "cluster unreachable — is L0 up?"

# --- the contract check ----------------------------------------------------
# Same drift guard as L1. NOTE: L2 declares no PVC at all any more — every
# database is external — so storageClass currently has no consumer here. The
# check stays because the contract itself has not changed, and the first
# workload that does want a volume should not be what discovers the drift.
sc_expected="$(awk '/^contract:/{f=1;next} f&&/storageClass:/{print $2;exit}' "${ENV_FILE}" | tr -d '"')"
[[ "${sc_expected}" == "${SC_ACTUAL}" ]] \
  || die "contract drift: envs/${L2_ENV}.yaml says storageClass '${sc_expected}', L0 published '${SC_ACTUAL}'"

# Any values file that still pins a storageClass must agree with the contract.
while IFS= read -r f; do
  v="$(awk '/storageClass:/{print $2;exit}' "$f" | tr -d '"')"
  [[ -z "$v" || "$v" == "${SC_ACTUAL}" ]] \
    || die "contract drift: ${f#"${L2}/"} pins storageClass '${v}', L0 published '${SC_ACTUAL}'"
done < <(grep -rl 'storageClass:' "${L2}/envs/${L2_ENV}" 2>/dev/null || true)

log "contract verified: storageClass=${SC_ACTUAL}"

# --- L1 must be there first ------------------------------------------------
# L2 declares ExternalSecret, AuthorizationPolicy and HTTPRoute resources. If
# the operators that own those kinds are missing, every Application fails with
# an unhelpful "no matches for kind" — so check plainly and say which is absent.
missing=()
kubectl get crd externalsecrets.external-secrets.io      >/dev/null 2>&1 || missing+=("External Secrets (ExternalSecret)")
kubectl get crd authorizationpolicies.security.istio.io  >/dev/null 2>&1 || missing+=("Istio (AuthorizationPolicy)")
kubectl get crd httproutes.gateway.networking.k8s.io     >/dev/null 2>&1 || missing+=("Gateway API (HTTPRoute)")
if (( ${#missing[@]} )); then
  die "L1 is not converged — missing CRDs: ${missing[*]}
    check: just status"
fi
kubectl -n "${ARGOCD_NS}" get appproject platform >/dev/null 2>&1 \
  || die "the L1 'platform' AppProject is missing — run L1's bootstrap first"

# The two L1 INSTANCES this layer binds to BY NAME. Checking only the CRDs used
# to be enough when L2 created its own Gateway and secret store; now that both
# are platform-scoped, their absence is the difference between "L1 installed
# the operators" and "L1 is actually finished". Neither failure is loud one
# layer up: an ExternalSecret with no store sits Pending forever, and an
# HTTPRoute with no Gateway reports Accepted=False and nothing else.
kubectl get clustersecretstore maal-secret-store >/dev/null 2>&1 \
  || die "the L1 ClusterSecretStore 'maal-secret-store' is missing — every ExternalSecret here would sit Pending
    check: just verify l1"
kubectl -n maal-edge get gateway maal-edge >/dev/null 2>&1 \
  || die "the L1 Gateway 'maal-edge' is missing — every HTTPRoute here would have no parent to attach to
    check: just verify l1"

log "L1 capabilities and edge present"

# --- hand off to GitOps ----------------------------------------------------
kubectl apply -f "${L2}/root/project.yaml"
kubectl apply -f "${L2}/root/root-app.yaml"

log "L2 bootstrapped. Argo reconciles the product layer from Git."
log "watch:  just status"
log ""
log "NOTE: every database here is EXTERNAL — this cluster creates none, and a"
log "      missing one shows up as a schema job retrying forever behind a green"
log "      Application, not as an error anyone reads. Create them:"
log "      just db-init"
log ""
log "NOTE: images are not in the cluster yet. Build and load them first:"
log "      just images"
log ""
log "NOTE: the edge Gateway is L1's. If a route is reachable in the cluster but"
log "      not from this laptop, its NodePort needs pinning:  just edge-port"
