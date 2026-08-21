#!/usr/bin/env bash
# L1/bootstrap/up.sh — the single imperative seam.
#
# Reads the L0 contract, verifies the cluster matches what Git says it is,
# installs a pinned Argo CD, gives Argo a deploy key for this repo, then applies
# the app-of-apps root. Everything past that line — the mesh, the operators, and
# Argo's own config — reconciles from Git.
set -euo pipefail

ARGO_VERSION="v3.3.14"     # PIN: latest GA patch on 3.3 — https://endoflife.date/argo-cd
ARGOCD_NS="argocd"
REPO_URL="git@github.com:BinMunawir/infra.git"

# Which L0 environment to sit on, and which L1 env file describes it.
L0_ENV="${L0_ENV:-local}"
L1_ENV="${L1_ENV:-dev-local}"

# SSH key with read access to REPO_URL. Never inside the repo.
#
# The private key is copied into a Secret in etcd, so on a cloud cluster this
# must be a dedicated read-only deploy key: a personal key there would put
# write access to every repo the operator owns one `kubectl get secret` away.
#
# Locally the trade is different — the cluster is a disposable kind node on the
# operator's own laptop, and etcd is a file in a container only they can reach
# — so `local` falls back to the personal key rather than making everyone mint
# a deploy key to run a throwaway cluster. Cloud envs get no such fallback and
# still fail closed below.
if [[ -n "${ARGOCD_SSH_KEY:-}" ]]; then
  SSH_KEY="${ARGOCD_SSH_KEY}"
elif [[ -f "${HOME}/.ssh/maal_argocd_deploy" ]]; then
  SSH_KEY="${HOME}/.ssh/maal_argocd_deploy"
elif [[ "${L0_ENV}" == "local" && -f "${HOME}/.ssh/id_ed25519" ]]; then
  SSH_KEY="${HOME}/.ssh/id_ed25519"
else
  SSH_KEY="${HOME}/.ssh/maal_argocd_deploy"   # absent — the check below explains
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
L1="$(cd "${HERE}/.." && pwd)"
L0="$(cd "${L1}/../L0" && pwd)"
VENDORED="${HERE}/argocd/install.yaml"
ENV_FILE="${L1}/envs/${L1_ENV}.yaml"

log(){ printf '>> %s\n' "$*"; }
die(){ printf '!! %s\n' "$*" >&2; exit 1; }

# --- preflight -------------------------------------------------------------
for c in kubectl jq ssh-keygen; do command -v "$c" >/dev/null || die "$c not found"; done
[[ -f "${ENV_FILE}" ]] || die "no L1 env file: ${ENV_FILE#"${L1}/"} (set L1_ENV)"

CONTRACT="${L0}/${L0_ENV}/contract.json"
[[ -f "${CONTRACT}" ]] || die "L0 '${L0_ENV}' has published no contract — run: cd ${L0} && just ${L0_ENV}-up"

KUBECONFIG_PATH="$(jq -er .kubeconfig   "${CONTRACT}")" || die "contract has no .kubeconfig"
SC_ACTUAL="$(jq -er .storageClass       "${CONTRACT}")" || die "contract has no .storageClass"
LB_ACTUAL="$(jq -er .lbEndpoint         "${CONTRACT}")" || die "contract has no .lbEndpoint"
[[ -f "${KUBECONFIG_PATH}" ]] || die "contract points at a missing kubeconfig: ${KUBECONFIG_PATH}"

export KUBECONFIG="${KUBECONFIG_PATH}"
kubectl get nodes >/dev/null 2>&1 || die "cluster unreachable via ${KUBECONFIG_PATH} — is L0 up?"
log "L0 '${L0_ENV}' -> $(jq -r .cluster "${CONTRACT}")  (kubeconfig from contract)"

# --- the contract check ----------------------------------------------------
# Argo only ever reads Git, so envs/<env>.yaml carries a COPY of the contract.
# If the copy and the live cluster disagree, Git is lying and every PVC L2
# creates would name a StorageClass that may not exist. Fail here, loudly.
sc_expected="$(awk '/^contract:/{f=1;next} f&&/storageClass:/{print $2;exit}' "${ENV_FILE}" | tr -d '"')"
lb_expected="$(awk '/^contract:/{f=1;next} f&&/lbEndpoint:/{print $2;exit}'   "${ENV_FILE}" | tr -d '"')"

[[ "${sc_expected}" == "${SC_ACTUAL}" ]] \
  || die "contract drift: envs/${L1_ENV}.yaml says storageClass '${sc_expected}', L0 published '${SC_ACTUAL}'"
[[ "${lb_expected}" == "${LB_ACTUAL}" ]] \
  || die "contract drift: envs/${L1_ENV}.yaml says lbEndpoint '${lb_expected}', L0 published '${LB_ACTUAL}'"

kubectl get storageclass "${SC_ACTUAL}" >/dev/null 2>&1 \
  || die "StorageClass '${SC_ACTUAL}' is in the contract but not in the cluster"
log "contract verified: storageClass=${SC_ACTUAL} lbEndpoint=${LB_ACTUAL}"

# --- deploy key ------------------------------------------------------------
[[ -f "${SSH_KEY}" ]] || die "$(cat <<EOF
no deploy key at ${SSH_KEY}

Argo needs read access to ${REPO_URL}. Create one:

  ssh-keygen -t ed25519 -N '' -C 'argocd@maal' -f ${SSH_KEY}
  pbcopy < ${SSH_KEY}.pub

then add it at:
  https://github.com/BinMunawir/infra/settings/keys   (read-only is enough)

Override the path with ARGOCD_SSH_KEY=/some/other/key.
On L0_ENV=local this also accepts ~/.ssh/id_ed25519; neither was found.
EOF
)"
ssh-keygen -y -f "${SSH_KEY}" >/dev/null 2>&1 || die "${SSH_KEY} is not a usable private key (passphrase-protected keys are not supported)"
log "repo key: ${SSH_KEY}"

# --- vendor Argo (pinned) on first run -------------------------------------
# install.yaml is kept byte-identical to the upstream release; our own changes
# live in the kustomization next to it, so a version bump is a clean re-vendor.
if [[ ! -f "${VENDORED}" ]]; then
  log "vendoring Argo ${ARGO_VERSION} -> ${VENDORED#"${L1}/"}  (commit + push this file)"
  mkdir -p "$(dirname "${VENDORED}")"
  curl -fsSL "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml" -o "${VENDORED}"
fi
[[ -f "${HERE}/argocd/kustomization.yaml" ]] \
  || die "bootstrap/argocd/kustomization.yaml is missing — it carries the controller flags"

# --- install Argo (server-side; the CRDs exceed client-side apply limits) ---
#
# Applied through kustomize, not straight from install.yaml, so the controller
# flags in bootstrap/argocd/kustomization.yaml are on from the first boot rather
# than only after the self-managing Application syncs.
#
# --field-manager=argocd-controller matters: Argo's application controller uses
# that manager for its own server-side applies. Bootstrapping under the default
# `kubectl` manager would hand every field to a manager Argo does not own, and
# the self-managing `argocd` Application would then park on apply conflicts.
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts \
  --field-manager=argocd-controller -k "${HERE}/argocd"

# --- give Argo the key -----------------------------------------------------
# Applied imperatively and never committed: this is the one secret that cannot
# come from Git, because it is what grants access to Git.
log "registering repo credentials for ${REPO_URL}"
kubectl -n "${ARGOCD_NS}" create secret generic maal-infra-repo \
  --from-literal=type=git \
  --from-literal=url="${REPO_URL}" \
  --from-file=sshPrivateKey="${SSH_KEY}" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f -

log "waiting for Argo to become ready..."
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-server                      --timeout=300s
kubectl -n "${ARGOCD_NS}" rollout status deploy/argocd-repo-server                 --timeout=300s
kubectl -n "${ARGOCD_NS}" rollout status statefulset/argocd-application-controller --timeout=300s

# --- hand off to GitOps ----------------------------------------------------
kubectl apply -f "${L1}/root/project.yaml"
kubectl apply -f "${L1}/root/root-app.yaml"

log "L1 bootstrapped. Argo now reconciles the platform from Git."
log "watch:    kubectl -n ${ARGOCD_NS} get applications -o wide -w"
log "apps:     just apps"
log "ui:       just ui        # then https://localhost:8080"
log ""
log "NOTE: nothing converges until this repo's committed state matches what you"
log "      have locally — Argo reads ${REPO_URL}@main, not your working tree."
