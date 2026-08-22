# infra — one entrypoint for all three layers.
#
# L0  the cluster        kind locally, EKS/GKE in cloud. Publishes a contract.
# L1  the platform       Argo CD, the mesh + its CA, the operators, the edge.
# L2  the product        Maal's services, their dependencies, their routes.
#
# There used to be a justfile per layer. Three sets of `up`/`down`/`verify`/
# `apps`/`status`/`why` meant `cd`-ing between directories to answer one
# question, two byte-identical copies of the 90-line `why` walk, and a `status`
# that could only ever show a third of the picture. The layer boundary is real
# and it is enforced by AppProjects, sync waves and the L0 contract — none of
# which needed a directory to stand in for them.
#
# Every recipe reads the kubeconfig out of the L0 contract, so there is no
# ambient `kubectl` context to get wrong.
#
#   just up          bring the whole stack up, in order, and verify it
#   just verify      does each layer deliver what it promises?
#   just status      one view of all three layers
#   just why <app>   why is this Argo Application unhealthy?

set shell := ["bash", "-uc"]

argocd_ns := "argocd"
cluster   := "maal-local"

# The environment triple. L0 provisions `l0_env`; L1 and L2 each install one
# {stage}-{provider} cell onto it.
l0_env := env_var_or_default("L0_ENV", "local")
l1_env := env_var_or_default("L1_ENV", "dev-local")
l2_env := env_var_or_default("L2_ENV", "dev-local")

contract := justfile_directory() / "L0" / l0_env / "contract.json"

# The AppProject that marks an Application as a layer's. It is the layer
# boundary, and it is what `verify` scopes on: Argo keeps every layer's
# Applications in one namespace, so an unfiltered query answers "is anything in
# this cluster broken", not "is L1 broken". A half-finished L2 must not make L1
# report itself as broken while all seven of its components are green — that is
# a lie in CI, and the kind that trains people to ignore the check.
#
# The project, not the platform.maal/stage label: that label is applied by the
# component appsets only, so it misses `argocd` and `platform-root` — the two
# whose failure matters most.
l1_project := "platform"
l2_project := "maal"

# Where the Go service repos live — siblings of the infra repo.
src := justfile_directory() / ".."

# The external Postgres, for dev-local only. Every database this platform uses
# is outside the cluster; locally that is a container on the laptop.
pg_container := "maal-pg"

_default:
    @just --list --unsorted

# Resolve the kubeconfig from the L0 contract; fail clearly if L0 is not up.
_kubeconfig:
    @test -f {{contract}} || { echo "!! L0 '{{l0_env}}' is not up — run: just up l0" >&2; exit 1; }
    @jq -er .kubeconfig {{contract}}

# ─── lifecycle ─────────────────────────────────────────────────────────────

# Bring up the stack: `just up` for all three layers, or `just up l1` for one
up layer="all":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"

    # Poll until every Application in a project is Synced+Healthy. This is what
    # makes an unattended `just up` mean something: without it the recipe
    # returns while Argo is still pulling charts, and the next layer's
    # bootstrap fails a CRD check that would have passed sixty seconds later.
    #
    # Bounded, and it prints what it is still waiting on rather than spinning
    # silently — a wait with no output is indistinguishable from a hang.
    wait_for(){
        local project="$1" timeout="${2:-900}" waited=0 bad
        export KUBECONFIG="$(just _kubeconfig)"
        echo ">> waiting for project '$project' to converge (timeout ${timeout}s)"
        while :; do
            bad="$(kubectl -n {{argocd_ns}} get applications \
                -o jsonpath="{range .items[?(@.spec.project==\"$project\")]}{.metadata.name}{\"\t\"}{.status.sync.status}{\"\t\"}{.status.health.status}{\"\n\"}{end}" 2>/dev/null \
                | awk '$2 != "Synced" || $3 != "Healthy"' || true)"
            # Zero Applications is NOT converged — an ApplicationSet whose
            # generator errored produces none, and none are all trivially
            # Synced+Healthy. Same fail-open trap `verify` is built around.
            if [ -n "$bad" ]; then
                :
            elif kubectl -n {{argocd_ns}} get applications \
                    -o jsonpath="{range .items[?(@.spec.project==\"$project\")]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | grep -q .; then
                echo ">> project '$project' converged"; return 0
            else
                bad="(no Applications generated yet)"
            fi
            if [ "$waited" -ge "$timeout" ]; then
                echo "!! '$project' did not converge in ${timeout}s. Still waiting on:" >&2
                echo "$bad" >&2
                echo "   just why <app>   for the detail" >&2
                return 1
            fi
            [ $(( waited % 60 )) -eq 0 ] && echo "   ${waited}s — still: $(echo "$bad" | head -3 | awk '{print $1}' | tr '\n' ' ')"
            sleep 10; waited=$(( waited + 10 ))
        done
    }

    case "{{layer}}" in
      l0)  ./L0/local/up.sh ;;
      l1)  ./L1/bootstrap/up.sh ;;
      l2)  ./L2/bootstrap/up.sh ;;
      all)
        echo "══ L0 ═══════════════════════════════════════════════"
        ./L0/local/up.sh

        echo
        echo "══ L1 ═══════════════════════════════════════════════"
        ./L1/bootstrap/up.sh
        wait_for "{{l1_project}}"

        # The one imperative step, and it must happen before L2's routes are
        # probed: istiod assigns the gateway's NodePort dynamically and the
        # Gateway API has no field to pin it. See the note on `edge-port`.
        just edge-port

        echo
        echo "══ L2 ═══════════════════════════════════════════════"
        # Images first. Without them every service lands in ImagePullBackOff,
        # and images do NOT survive a cluster teardown even though the external
        # database does.
        just images || echo "!! some images did not build — services will ImagePullBackOff until they do"
        ./L2/bootstrap/up.sh
        wait_for "{{l2_project}}"

        echo
        just verify
        ;;
      *) echo "!! unknown layer '{{layer}}' — use l0, l1, l2, or all" >&2; exit 1 ;;
    esac

# Tear down: `just down` deletes the cluster; `just down l1` keeps it
down layer="all":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    case "{{layer}}" in
      # Deleting the cluster deletes Argo, the mesh and the operators with it,
      # which is why there is no L1 teardown to run first. It is also faster
      # and leaves nothing behind.
      all|l0) ./L0/local/down.sh ;;
      l1)     ./L1/bootstrap/down.sh ;;
      l2)
        export KUBECONFIG=$(just _kubeconfig)
        read -rp "Remove all L2 apps and services from '$(kubectl config current-context)'? [y/N] " a
        [[ "$a" == "y" || "$a" == "Y" ]] || { echo "aborted"; exit 0; }
        kubectl delete -f L2/root/root-app.yaml --cascade=foreground --ignore-not-found --timeout=300s || true
        kubectl delete -f L2/root/project.yaml --ignore-not-found || true
        echo ">> L2 removed. Databases are external and untouched — this deletes no data."
        ;;
      *) echo "!! unknown layer '{{layer}}' — use l0, l1, l2, or all" >&2; exit 1 ;;
    esac

# ─── verification ──────────────────────────────────────────────────────────
#
# The question this answers is "does each layer deliver what it promises", not
# "is every Application green". The second is necessary, not sufficient, and it
# FAILS OPEN: an ApplicationSet whose generator errored produces zero
# Applications, and zero Applications are all trivially Synced+Healthy. A
# green-Applications check reports success on an empty cluster.
#
# There is no separate `drift` recipe any more. It asked only the weaker
# question, its answer is a strict subset of section 5 of each layer below, and
# two commands where one would do is how a check stops being run.

# Does each layer deliver what it promises? `just verify [l0|l1|l2]`. CI-usable
verify layer="all":
    #!/usr/bin/env bash
    set -uo pipefail
    export KUBECONFIG="$(just _kubeconfig)"
    fail=0
    ok(){   printf '  ok    %s\n' "$*"; }
    no(){   printf '  FAIL  %s\n' "$*"; fail=1; }
    note(){ printf '  --    %s\n' "$*"; }

    # NOT `$(curl ... || echo 000)`. curl PRINTS the write-out format even when
    # the transfer fails — "000" — and then exits non-zero, so the `||` appends
    # a second "000" and the variable holds "000\n000". That never equals
    # "000", so every unreachable case fell through to the success branch and
    # reported ok. A probe that passes when the thing is down is worse than no
    # probe. Let curl's own output stand, and default only if it printed
    # nothing.
    probe(){ curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }

    crd(){ kubectl get crd "$1" >/dev/null 2>&1 && ok "$2" || no "$2 — CRD $1 absent"; }

    want_port="$(jq -r '.lbEndpoint | split(":")[1]' {{contract}} 2>/dev/null)"

    # ═══ L0 — the cluster ═══════════════════════════════════════════════════
    if [[ "{{layer}}" == "all" || "{{layer}}" == "l0" ]]; then
    echo "══ L0 ═══════════════════════════════════════════════"
    echo "── 1. the contract ───────────────────────────────"
    sc_actual="$(jq -r .storageClass {{contract}} 2>/dev/null || echo '')"
    kubectl get nodes >/dev/null 2>&1 && ok "cluster reachable" || no "cluster unreachable"
    if [ -z "$sc_actual" ]; then
        no "no contract published — just up l0"
    else
        kubectl get storageclass "$sc_actual" >/dev/null 2>&1 \
            && ok "storageClass $sc_actual" || no "storageClass $sc_actual in contract but not in cluster"
        # The contract promises WaitForFirstConsumer. A class that binds
        # immediately schedules the volume before the pod, which on a
        # multi-node cluster puts them on different nodes.
        b="$(kubectl get storageclass "$sc_actual" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"
        [ "$b" = "WaitForFirstConsumer" ] && ok "volumeBindingMode WaitForFirstConsumer" \
            || no "storageClass $sc_actual has volumeBindingMode=${b:-<unset>}, contract requires WaitForFirstConsumer"
    fi
    fi

    # ═══ L1 — the platform ══════════════════════════════════════════════════
    #
    # In dependency order:
    #   1. the L0 contract still holds       L1 is written against exactly it
    #   2. Argo's own workloads are ready    nothing below means anything otherwise
    #   3. the generators produced params    where a template error hides
    #   4. the expected component matrix     the fail-open case above
    #   5. every Application Synced+Healthy
    #   6. the capabilities L2 demands       so a missing one surfaces here, not
    #                                        as "no matches for kind" one layer up
    #   7. the mesh CA is ours               istiod quietly self-signing is
    #                                        invisible from Application status
    #   8. the edge admits traffic           THE CONTRACT'S THIRD OUTPUT: without
    #                                        this, `lbEndpoint` names an address
    #                                        nothing answers at
    if [[ "{{layer}}" == "all" || "{{layer}}" == "l1" ]]; then
    echo
    echo "══ L1 ═══════════════════════════════════════════════"
    echo "── 1. contract mirror ────────────────────────────"
    # Argo only ever reads Git, so envs/<env>.yaml carries a COPY of the
    # contract. If the copy and the live cluster disagree, Git is lying.
    sc_actual="$(jq -r .storageClass {{contract}} 2>/dev/null || echo '')"
    sc_env="$(awk '/^contract:/{f=1;next} f&&/storageClass:/{print $2;exit}' \
        "{{justfile_directory()}}/L1/envs/{{l1_env}}.yaml" 2>/dev/null | tr -d '"')"
    if [ "$sc_actual" = "$sc_env" ] && [ -n "$sc_actual" ]; then
        ok "storageClass $sc_actual matches L1/envs/{{l1_env}}.yaml"
    else
        no "contract drift: L1/envs/{{l1_env}}.yaml says '${sc_env:-<none>}', L0 published '${sc_actual:-<none>}'"
    fi

    echo "── 2. Argo CD ────────────────────────────────────"
    for d in argocd-server argocd-repo-server argocd-applicationset-controller; do
        r="$(kubectl -n {{argocd_ns}} get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
        [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "$d" || no "$d not ready"
    done
    r="$(kubectl -n {{argocd_ns}} get statefulset argocd-application-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "argocd-application-controller" || no "argocd-application-controller not ready"

    # Progressive syncs, verified rather than patched: they are configured in
    # Git (L1/bootstrap/argocd/kustomization.yaml), so if this reads OFF the
    # RollingSync block in L1/platform/appset.yaml is being ignored and
    # ordering has silently fallen back to retry-with-backoff.
    k="$(kubectl -n {{argocd_ns}} get cm argocd-cmd-params-cm \
        -o jsonpath='{.data.applicationsetcontroller\.enable\.progressive\.syncs}' 2>/dev/null)"
    [ "${k:-}" = "true" ] && ok "progressive syncs ON — RollingSync is live" \
        || no "progressive syncs OFF (${k:-<unset>}) — wave ordering is not being enforced; is the argocd app synced?"

    echo "── 3. generators ─────────────────────────────────"
    # Project-scoped like sections 4 and 5. An ApplicationSet carries the
    # project on its template, not on itself, which is why this path is a level
    # deeper than the one below.
    sets="$(kubectl -n {{argocd_ns}} get applicationsets -o jsonpath='{range .items[?(@.spec.template.spec.project=="{{l1_project}}")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$sets" ]; then
        no "no ApplicationSets — is the root app applied?"
    else
        for s in $sets; do
            err="$(kubectl -n {{argocd_ns}} get applicationset "$s" -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].status}' 2>/dev/null)"
            if [ "$err" = "True" ]; then
                msg="$(kubectl -n {{argocd_ns}} get applicationset "$s" -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].message}' 2>/dev/null)"
                no "appset $s: $msg"
            else
                ok "appset $s generating"
            fi
        done
    fi

    echo "── 4. expected components ────────────────────────"
    # The catalog is the source of truth: every `- component:` in EITHER appset
    # must have produced an Application named <env>-<component>.
    comps="$(grep -hoE '^[[:space:]]+- component: [^[:space:]]+' \
        "{{justfile_directory()}}/L1/platform/appset.yaml" \
        "{{justfile_directory()}}/L1/platform/appset-vendored.yaml" | awk '{print $3}' | sort -u)"
    for c in $comps; do
        kubectl -n {{argocd_ns}} get application "{{l1_env}}-$c" >/dev/null 2>&1 \
            && ok "application {{l1_env}}-$c" \
            || no "application {{l1_env}}-$c MISSING — the generator never produced it"
    done
    # The two singleton appsets — edge and secret-store — carry no
    # `- component:` catalog, so the grep above cannot see them.
    for c in edge secret-store; do
        kubectl -n {{argocd_ns}} get application "{{l1_env}}-$c" >/dev/null 2>&1 \
            && ok "application {{l1_env}}-$c" || no "application {{l1_env}}-$c MISSING"
    done

    echo "── 5. convergence ────────────────────────────────"
    rows="$(kubectl -n {{argocd_ns}} get applications \
        -o jsonpath='{range .items[?(@.spec.project=="{{l1_project}}")]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$rows" ]; then
        no "no Applications exist at all"
    else
        while IFS=$'\t' read -r n s h; do
            [ -z "$n" ] && continue
            if [ "$s" = "Synced" ] && [ "$h" = "Healthy" ]; then ok "$n"
            else no "$n  ${s:-?}/${h:-?}  — just why $n"; fi
        done <<<"$rows"
    fi

    echo "── 6. capabilities L2 depends on ─────────────────"
    # A superset of L2/bootstrap/up.sh's CRD checks — a capability that is
    # missing should fail here, not one layer up as "no matches for kind".
    crd externalsecrets.external-secrets.io     "External Secrets (ExternalSecret)"
    crd authorizationpolicies.security.istio.io "Istio (AuthorizationPolicy)"
    crd gateways.gateway.networking.k8s.io      "Gateway API (Gateway)"
    crd certificates.cert-manager.io            "cert-manager (Certificate)"

    # The store, not just its CRD. Every ExternalSecret in L2 names it, so if
    # it is not Ready nothing in that layer can resolve a credential — and the
    # symptom one layer up is a workload stuck without a Secret, which reads as
    # an application problem.
    r="$(kubectl get clustersecretstore maal-secret-store \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [ "$r" = "True" ] && ok "clustersecretstore maal-secret-store" \
        || no "clustersecretstore maal-secret-store not Ready — is {{l1_env}}-secret-store synced?"

    echo "── 7. mesh CA ────────────────────────────────────"
    # istiod's DEFAULT is to self-sign a mesh root and regenerate it whenever
    # `istio-ca-secret` goes missing, which silently breaks mesh mTLS until
    # every pod rotates. That failure is invisible from Application status:
    # every component reads Synced+Healthy either way.
    for c in maal-mesh-root maal-mesh-intermediate; do
        r="$(kubectl -n istio-system get certificate "$c" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        [ "$r" = "True" ] && ok "certificate $c" || no "certificate $c not Ready — is {{l1_env}}-mesh-ca synced?"
    done
    r="$(kubectl -n istio-system get deploy cert-manager-istio-csr -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${r:-0}" -ge 1 ] 2>/dev/null && ok "istio-csr serving" || no "istio-csr not ready — the mesh has no CA to ask"

    # The half that is easy to get wrong: istiod happily keeps its own CA
    # server running if this env var is missing, and nothing else complains.
    e="$(kubectl -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ENABLE_CA_SERVER")].value}' 2>/dev/null)"
    [ "$e" = "false" ] && ok "istiod CA server disabled" \
        || no "istiod is still its own CA (ENABLE_CA_SERVER=${e:-<unset>}) — check L1/envs/{{l1_env}}/istiod.yaml"

    # What every workload is actually handed. istiod's self-signed root does
    # not carry our CN, so this distinguishes the two without parsing dates.
    if command -v openssl >/dev/null 2>&1; then
        s="$(kubectl -n istio-system get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null \
             | openssl x509 -noout -subject 2>/dev/null)"
        case "$s" in
            *maal-mesh-root*) ok "mesh trust root is the cert-manager root" ;;
            "")               no "no istio-ca-root-cert published — is istio-csr running?" ;;
            *)                no "mesh trust root is NOT ours: ${s} — istiod may have self-signed" ;;
        esac
    else
        note "mesh trust root unverified (no openssl)"
    fi

    echo "── 8. the edge ───────────────────────────────────"
    # L0's contract promises an address. This is the layer that has to make
    # something answer there — with no routes yet (those are L2's), a healthy
    # edge returns 404, and that is a pass.
    r="$(kubectl -n maal-edge get certificate maal-edge-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
    [ "$r" = "True" ] && ok "certificate maal-edge-tls" || no "certificate maal-edge-tls not Ready — is {{l1_env}}-edge synced?"

    r="$(kubectl -n maal-edge get gateway maal-edge -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)"
    [ "$r" = "True" ] && ok "gateway maal-edge programmed" || no "gateway maal-edge not Programmed — is istiod's GatewayClass there?"

    # The HTTPS port BY NAME — see the note on `edge-port`. Reading ports[0]
    # here would report the status port and call a broken edge healthy.
    got_port="$(kubectl -n maal-edge get svc -l gateway.networking.k8s.io/gateway-name=maal-edge \
        -o jsonpath='{.items[0].spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null)"
    if [ -z "$got_port" ]; then
        no "no gateway Service with an https port — istiod has not provisioned one"
    elif [ "$got_port" = "30080" ]; then
        ok "gateway https nodePort 30080 — reachable at 127.0.0.1:${want_port:-8080}"
    else
        note "gateway https nodePort is $got_port, not 30080 — run 'just edge-port' to reach it from the laptop"
    fi

    # The only check that leaves the cluster and comes back. Everything above
    # can pass while the edge answers nothing, because "Programmed" means
    # istiod accepted the config, not that a request survives the trip through
    # the kind port mapping, the NodePort and the TLS listener.
    #
    # Any name under the wildcard will do — this deliberately does NOT use a
    # route's hostname, because routes are L2's and L1 must verify without
    # them. A 404 is the correct answer from an edge with an empty routing
    # table.
    if command -v curl >/dev/null 2>&1; then
        url="https://edge-probe.127.0.0.1.nip.io:${want_port:-8080}/"
        code="$(probe "$url")"; code="${code:-000}"
        if [ "$code" = "000" ]; then
            # Tell "this machine has no DNS" apart from "the edge is down".
            # nip.io is public, so an offline laptop cannot resolve it even
            # though the gateway is perfectly healthy — and reporting that as a
            # broken edge is the false alarm that teaches people to stop
            # trusting this check.
            alt="$(probe --resolve "edge-probe.127.0.0.1.nip.io:${want_port:-8080}:127.0.0.1" "$url")"
            case "${alt:-000}" in
                000) no   "edge unreachable at $url — 'just edge-port', then check the gateway pod" ;;
                *)   note "edge answers only with the lookup bypassed — the edge is fine, this machine cannot resolve nip.io (offline?)" ;;
            esac
        else
            ok "edge terminates TLS and answers ($code — 404 means no route yet, which is L2's half)"
        fi
    else
        note "edge not probed (no curl)"
    fi
    fi

    # ═══ L2 — the product ═══════════════════════════════════════════════════
    #
    # This layer's two hardest failure modes are both invisible at the
    # "is every Application green" level:
    #
    #   - Every database is EXTERNAL. A missing database or role does not make
    #     an Application red; it makes a schema job retry behind a green one.
    #   - A workload parked at `replicas: 0` is legitimately green with no
    #     pods, so "no pods running" cannot be read as failure — nor as success.
    if [[ "{{layer}}" == "all" || "{{layer}}" == "l2" ]]; then
    echo
    echo "══ L2 ═══════════════════════════════════════════════"
    echo "── 1. contract mirror ────────────────────────────"
    sc_actual="$(jq -r .storageClass {{contract}} 2>/dev/null || echo '')"
    sc_env="$(awk '/^contract:/{f=1;next} f&&/storageClass:/{print $2;exit}' \
        "{{justfile_directory()}}/L2/envs/{{l2_env}}.yaml" 2>/dev/null | tr -d '"')"
    if [ "$sc_actual" = "$sc_env" ] && [ -n "$sc_actual" ]; then
        ok "storageClass $sc_actual matches L2/envs/{{l2_env}}.yaml"
    else
        no "contract drift: L2/envs/{{l2_env}}.yaml says '${sc_env:-<none>}', L0 published '${sc_actual:-<none>}'"
    fi

    echo "── 2. L1 capabilities ────────────────────────────"
    crd externalsecrets.external-secrets.io     "External Secrets (ExternalSecret)"
    crd authorizationpolicies.security.istio.io "Istio (AuthorizationPolicy)"
    crd httproutes.gateway.networking.k8s.io    "Gateway API (HTTPRoute)"
    kubectl -n {{argocd_ns}} get appproject {{l1_project}} >/dev/null 2>&1 \
        && ok "AppProject {{l1_project}}" || no "AppProject {{l1_project}} missing — run L1's bootstrap first"
    # The two L1 INSTANCES this layer binds to by name, not just the CRDs. Both
    # fail one layer up in ways that read as an application bug: an
    # ExternalSecret whose store is missing sits Pending forever, and an
    # HTTPRoute whose Gateway is missing reports Accepted=False with no hint
    # that the Gateway is another layer's.
    kubectl get clustersecretstore maal-secret-store >/dev/null 2>&1 \
        && ok "ClusterSecretStore maal-secret-store (L1)" || no "ClusterSecretStore maal-secret-store absent — just verify l1"
    kubectl -n maal-edge get gateway maal-edge >/dev/null 2>&1 \
        && ok "Gateway maal-edge (L1)" || no "Gateway maal-edge absent — just verify l1"

    echo "── 3. generators ─────────────────────────────────"
    sets="$(kubectl -n {{argocd_ns}} get applicationsets \
        -o jsonpath='{range .items[?(@.spec.template.spec.project=="{{l2_project}}")]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$sets" ]; then
        no "no ApplicationSets in project {{l2_project}} — is maal-root synced?"
    else
        for s in $sets; do
            err="$(kubectl -n {{argocd_ns}} get applicationset "$s" \
                -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].status}' 2>/dev/null)"
            if [ "$err" = "True" ]; then
                msg="$(kubectl -n {{argocd_ns}} get applicationset "$s" \
                    -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].message}' 2>/dev/null)"
                no "appset $s: $msg"
            else
                ok "appset $s generating"
            fi
        done
    fi

    echo "── 4. expected applications ──────────────────────"
    apps="$(grep -hoE '^[[:space:]]+- (app|service): [^[:space:]]+' \
        "{{justfile_directory()}}/L2/apps/deps-appset.yaml" \
        "{{justfile_directory()}}/L2/apps/services-appset.yaml" | awk '{print $3}' | sort -u)"
    for a in $apps; do
        kubectl -n {{argocd_ns}} get application "{{l2_env}}-$a" >/dev/null 2>&1 \
            && ok "application {{l2_env}}-$a" \
            || no "application {{l2_env}}-$a MISSING — the generator never produced it"
    done
    for a in app-secrets routes; do
        kubectl -n {{argocd_ns}} get application "{{l2_env}}-$a" >/dev/null 2>&1 \
            && ok "application {{l2_env}}-$a" || no "application {{l2_env}}-$a MISSING"
    done
    kubectl -n {{argocd_ns}} get application maal-root >/dev/null 2>&1 \
        && ok "application maal-root" || no "application maal-root MISSING — run just up l2"

    echo "── 5. convergence ────────────────────────────────"
    rows="$(kubectl -n {{argocd_ns}} get applications \
        -o jsonpath='{range .items[?(@.spec.project=="{{l2_project}}")]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$rows" ]; then
        no "no Applications exist at all"
    else
        while IFS=$'\t' read -r n s h; do
            [ -z "$n" ] && continue
            if [ "$s" = "Synced" ] && [ "$h" = "Healthy" ]; then ok "$n"
            else no "$n  ${s:-?}/${h:-?}  — just why $n"; fi
        done <<<"$rows"
    fi

    echo "── 6. secrets ────────────────────────────────────"
    # The store itself is L1's and was checked in section 2 — here we only care
    # that this layer's own ExternalSecrets actually resolved against it.
    es="$(kubectl get externalsecrets -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$es" ]; then
        no "no ExternalSecrets at all — did the services and secret store sync?"
    else
        while IFS=$'\t' read -r name ready; do
            [ -z "$name" ] && continue
            [ "$ready" = "True" ] && ok "externalsecret $name" \
                || no "externalsecret $name not Ready (${ready:-<no status>}) — is its key in the store?"
        done <<<"$es"
    fi

    echo "── 7. workloads ──────────────────────────────────"
    # spec.replicas vs ready, NOT "are there pods". A service parked at
    # replicas: 0 is supposed to have none, and reading that as a failure is
    # what would make this check untrustworthy on a correct cluster.
    for ns in maal-temporal maal-keycloak maal-business maal-stream-ph; do
        rows="$(kubectl -n "$ns" get deploy,statefulset \
            -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null)"
        if [ -z "$rows" ]; then
            no "namespace $ns has no workloads at all"
            continue
        fi
        while IFS=$'\t' read -r name want got; do
            [ -z "$name" ] && continue
            got="${got:-0}"
            if [ "${want:-0}" -eq 0 ] 2>/dev/null; then
                note "$ns/$name parked at 0 replicas"
            elif [ "$got" -ge "$want" ] 2>/dev/null; then
                ok "$ns/$name $got/$want"
            else
                no "$ns/$name $got/$want ready"
            fi
        done <<<"$rows"
    done

    echo "── 8. the routes ─────────────────────────────────"
    # A route can be Accepted and still point at nothing, so both conditions
    # matter: ResolvedRefs=False means "the backend Service does not exist",
    # which is the common failure after renaming a chart release. Accepted=False
    # usually means the hostname fell outside the wildcard L1's listener bounds.
    routes="$(kubectl get httproute -A \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\t"}{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}' 2>/dev/null)"
    if [ -z "$routes" ]; then
        no "no HTTPRoutes — has {{l2_env}}-routes synced?"
    else
        while IFS=$'\t' read -r name acc res; do
            [ -z "$name" ] && continue
            if [ "$acc" = "True" ] && [ "$res" = "True" ]; then ok "httproute $name"
            elif [ "$acc" != "True" ]; then
                no "httproute $name accepted=${acc:-?} — hostname outside L1's listener wildcard?"
            else
                no "httproute $name resolvedRefs=${res:-?} — backend Service missing?"
            fi
        done <<<"$routes"
    fi

    # Hostnames come from the live routes rather than a hardcoded list: this
    # file should not carry a second copy of the routing table that can drift
    # from the one in Git.
    #
    # No --resolve on the first attempt: the hostnames are nip.io names that
    # resolve to 127.0.0.1 through PUBLIC DNS, so this tests exactly what a
    # browser does — lookup included. Faking the lookup would pass on a machine
    # where the browser fails.
    hosts="$(kubectl get httproute -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' 2>/dev/null | sort -u)"
    if [ -z "$hosts" ]; then
        note "no route hostnames to probe"
    elif command -v curl >/dev/null 2>&1; then
        for h in $hosts; do
            url="https://$h:${want_port:-8080}/"
            code="$(probe "$url")"; code="${code:-000}"
            if [ "$code" = "000" ]; then
                alt="$(probe --resolve "$h:${want_port:-8080}:127.0.0.1" "$url")"
                case "${alt:-000}" in
                    2*|3*) note "$url answers only with the lookup bypassed — the edge is fine, this machine cannot resolve nip.io (offline?)" ;;
                    *)     no   "$url unreachable — just edge-port, then check the gateway pod" ;;
                esac
                continue
            fi
            case "$code" in
                2*|3*) ok "$url -> $code" ;;
                *)     no "$url -> $code" ;;
            esac
        done
    else
        note "routes not probed (no curl)"
    fi
    fi

    echo
    if [ "$fail" -eq 0 ]; then
        echo ">> verified — {{layer}} delivers what it promises"
    else
        echo "!! NOT ready. Fix the FAIL lines above, then re-run."
        exit 1
    fi

# ─── inspection ────────────────────────────────────────────────────────────

# One view of all three layers: contract, Applications, workloads, edge, routes
status:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "══ L0 — the contract ════════════════════════════════"
    if [ -f {{contract}} ]; then jq . {{contract}}; else echo "  not provisioned — just up l0"; exit 0; fi
    export KUBECONFIG=$(just _kubeconfig)

    echo
    echo "══ Applications ═════════════════════════════════════"
    # Every layer at once, with the project column that says which is which —
    # the thing three separate `apps` recipes could never show.
    kubectl -n {{argocd_ns}} get applications \
        -o custom-columns=NAME:.metadata.name,PROJECT:.spec.project,SYNC:.status.sync.status,HEALTH:.status.health.status \
        2>/dev/null || echo "  (Argo not installed)"

    echo
    echo "══ generators ═══════════════════════════════════════"
    kubectl -n {{argocd_ns}} get applicationsets -o wide 2>/dev/null || echo "  (none)"

    echo
    echo "══ L1 — platform workloads ══════════════════════════"
    for ns in istio-system cert-manager external-secrets maal-edge; do
        printf -- '--- %s ---\n' "$ns"
        kubectl -n "$ns" get pods 2>/dev/null || echo "  (namespace not created yet)"
    done

    echo
    echo "══ L2 — product workloads ═══════════════════════════"
    for ns in maal-temporal maal-keycloak maal-business maal-stream-ph; do
        printf -- '--- %s ---\n' "$ns"
        kubectl -n "$ns" get pods 2>/dev/null || echo "  (namespace not created yet)"
    done

    echo
    echo "══ the edge ═════════════════════════════════════════"
    echo "--- gateway + certificate (L1 owns these) ---"
    kubectl -n maal-edge get gateway,certificate 2>/dev/null || echo "  (maal-edge not created yet)"
    kubectl -n maal-edge get svc -l gateway.networking.k8s.io/gateway-name=maal-edge 2>/dev/null || true
    echo "--- routes (L2 owns these) ---"
    kubectl get httproute -A 2>/dev/null || echo "  (none)"

    echo
    echo "══ secrets ══════════════════════════════════════════"
    kubectl get clustersecretstores 2>/dev/null || echo "  (external-secrets CRDs not present)"
    kubectl get externalsecrets -A 2>/dev/null || true

# Argo buries a failure at four different depths, and the top two are routinely
# empty — a sync rejected by the AppProject shows up as a bare
# "OutOfSync / Missing" with no condition set. This walks all four:
#
#   1. .status.sync / .status.health          the summary `just status` prints
#   2. the parent ApplicationSet's            an app waiting on an earlier
#      RollingSync step                       wave looks IDENTICAL to a failure
#   3. .status.operationState                 phase + the retry counter
#   4. …syncResult.resources[].message        where the real error actually is
#
# (2) is what stops a false alarm: under RollingSync every app in a later wave
# sits at OutOfSync/Missing by design.
#
# Why is an app unhealthy? `just why dev-local-istiod`
why app:
    #!/usr/bin/env bash
    set -uo pipefail
    export KUBECONFIG="$(just _kubeconfig)"

    json="$(kubectl -n {{argocd_ns}} get application {{app}} -o json 2>/dev/null)" || {
        echo "!! no Application '{{app}}' in {{argocd_ns}} — 'just status' lists them" >&2; exit 1; }

    # Multi-source apps — every one the appsets generate — report a revision per
    # source in .revisions (chart version, then the sha of this repo). Their
    # scalar .revision is empty, so reading only that printed a bare "-".
    jq -r '
        "── \(.metadata.name) " + ("─" * 30),
        "PROJECT:  \(.spec.project // "-")",
        "SYNC:     \(.status.sync.status // "-")",
        "HEALTH:   \(.status.health.status // "-")"
            + (if (.status.health.message // "") != "" then "  — \(.status.health.message)" else "" end),
        "REVISION: " + (
            if (.status.sync.revision // "") != "" then .status.sync.revision[0:7]
            elif ((.status.sync.revisions // []) | length) > 0 then
                (.status.sync.revisions
                 | map(if test("^[0-9a-f]{40}$") then .[0:7] else . end)
                 | join("  +  "))
            else "-" end)
    ' <<<"$json"

    owner="$(jq -r '[.metadata.ownerReferences[]? | select(.kind=="ApplicationSet") | .name][0] // ""' <<<"$json")"
    if [ -n "$owner" ]; then
        kubectl -n {{argocd_ns}} get applicationset "$owner" -o json 2>/dev/null \
          | jq -r --arg app '{{app}}' --arg set "$owner" '
            ((.status.applicationStatus // [])[] | select(.application == $app)) // empty
            | "", "ROLLING SYNC  (applicationset \($set))",
              "  step \(.step)  ·  \(.status)",
              "  \(.message)",
              (if .status == "Waiting" then
                 "  NOTE: blocked behind an earlier wave — this is not a failure."
               else empty end)'
    fi

    jq -r '
        (.status.operationState // empty)
        | "", "OPERATION",
          "  \(.phase)\(if (.message // "") != "" then " — " + .message else "" end)",
          "  started \(.startedAt // "-")\(if .finishedAt then "   finished \(.finishedAt)" else "" end)"
    ' <<<"$json"

    jq -r '
        [ (.status.operationState.syncResult.resources // [])[]
          | select(.status != "Synced" and .status != "Running") ] as $bad
        | if ($bad | length) > 0
          then "", "FAILED RESOURCES", ($bad[] | "  \(.status)  \(.kind)/\(.name)\n      \(.message)")
          else empty end
    ' <<<"$json"

    jq -r '
        [ (.status.resources // [])[]
          | select((.health.status // "") | (. != "" and . != "Healthy")) ] as $bad
        | if ($bad | length) > 0
          then "", "UNHEALTHY RESOURCES",
               ($bad[] | "  \(.health.status)  \(.kind)/\(.name)"
                       + (if .health.message then "\n      \(.health.message)" else "" end))
          else empty end
    ' <<<"$json"

    jq -r '
        (.status.conditions // []) as $c
        | if ($c | length) > 0
          then "", "CONDITIONS", ($c[] | "  [\(.type)] \(.message)")
          else empty end
    ' <<<"$json"

# Where the edge answers from your laptop.
#
# Reads the live HTTPRoutes rather than hardcoding hostnames, and takes the port
# from the L0 contract rather than hardcoding 8080: both are facts about the
# current cluster, not about this file.
#
# Where the edge answers from your laptop
urls:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG=$(just _kubeconfig)
    port="$(jq -r '.lbEndpoint | split(":")[1]' {{contract}} 2>/dev/null || echo 8080)"
    hosts="$(kubectl get httproute -A -o jsonpath='{range .items[*]}{range .spec.hostnames[*]}{@}{"\n"}{end}{end}' 2>/dev/null | sort -u)"
    echo ""
    if [ -z "$hosts" ]; then
        echo "   No HTTPRoutes yet — the edge is up but nothing is behind it."
        echo "   Routes are L2's: just up l2"
    else
        for h in $hosts; do printf '   https://%s:%s/\n' "$h" "$port"; done
    fi
    echo ""
    echo "   Nothing to add to /etc/hosts — nip.io resolves these publicly."
    echo "   The certificate is signed by a local root, so a browser warns once"
    echo "   and curl needs -k; 'just edge-ca' prints the root to trust it."

# ─── the local dev loop ────────────────────────────────────────────────────

# Create the external databases and roles this env expects (dev-local Postgres)
#
# The one part of dev-local a cold rebuild does NOT reproduce: the cluster runs
# no database, so `just up` cannot recreate one. The container survives
# `just down` — L0/local/down.sh only deletes the kind cluster — so this is
# normally a once-per-machine step, not a once-per-rebuild one.
#
# Idempotent. See L2/db/<env>/bootstrap.sql for what it creates, and why those
# passwords match L1/secrets/<env>/cluster-secret-store.yaml.
#
# Create the external databases and roles this env expects
db-init:
    #!/usr/bin/env bash
    set -euo pipefail
    sql="{{justfile_directory()}}/L2/db/{{l2_env}}/bootstrap.sql"
    test -f "$sql" || { echo "!! no database bootstrap for '{{l2_env}}': ${sql}" >&2; exit 1; }

    # A docker --filter, NOT a --format Go template piped through grep.
    #
    # Two justfile traps meet in that one line. Four opening braces escape to a
    # literal pair, but four CLOSING braces are not an escape -- they are two
    # literal pairs -- so a .Names format string reaches docker malformed and
    # every line comes back with a stray brace pair appended. The grep then
    # never matches and this reports a running container as absent.
    #
    # Backticks are the second trap: just evaluates them as command
    # substitution inside a recipe body, comments included. Hence none here.
    if [ -z "$(docker ps -q --filter "name=^{{pg_container}}$")" ]; then
        echo "!! no '{{pg_container}}' container running." >&2
        echo "   Every database here is EXTERNAL — the cluster runs none. Start one:" >&2
        echo "     docker run -d --name {{pg_container}} -p 5432:5432 \\" >&2
        echo "       -e POSTGRES_PASSWORD=dev-placeholder-db-password postgres:16" >&2
        exit 1
    fi

    docker exec -i {{pg_container}} psql -v ON_ERROR_STOP=1 -U postgres < "$sql"
    echo ">> databases and roles are in place for {{l2_env}}"

# Build every service image and load it into kind (no registry needed locally)
images: (image "client" "maal/business") (image "ledger" "maal/ledger") (image "maalstream_ph" "maal/stream-ph")

# Build one service image and load it: `just image ledger maal/ledger`
image repo tag:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="{{src}}/{{repo}}"
    test -d "$dir" || { echo "!! no such service repo: $dir" >&2; exit 1; }
    if [ ! -f "$dir/Dockerfile" ]; then
        echo "!! {{repo}} has no Dockerfile." >&2
        echo "   Copy ledger/Dockerfile and change the ./cmd/<entrypoint> target." >&2
        echo "   The image must put binaries at /app/<name> with WORKDIR /app and" >&2
        echo "   USER 1001 — L2/charts/go-service assumes exactly that layout." >&2
        exit 1
    fi
    docker build -t "{{tag}}:dev" "$dir"
    kind load docker-image "{{tag}}:dev" --name {{cluster}}
    echo ">> loaded {{tag}}:dev into kind/{{cluster}}"
    echo ">> NOTE: the tag did not change, so the Deployment spec did not either."
    echo "   Argo will report Synced and keep the OLD pods. Roll them:"
    echo "     just restart <service>"

# Roll a service's pods onto a freshly loaded image: `just restart maal-business`
#
# Needed because `:dev` is a mutable tag — see the warning in
# L2/charts/go-service/values.yaml. Cloud envs use immutable tags and never need
# this: the values change is what triggers the rollout.
#
# Roll a service's pods onto a freshly loaded image: `just restart maal-business`
restart service:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG=$(just _kubeconfig)
    kubectl -n {{service}} rollout restart deployment -l app.kubernetes.io/name={{service}}
    kubectl -n {{service}} rollout status deployment -l app.kubernetes.io/name={{service}} --timeout=180s

# Force a re-read of Git without waiting for the poll interval.
#
# Argo reads git@github.com:BinMunawir/infra.git@main, never the working tree,
# so this only helps once the change is COMMITTED AND PUSHED. A local edit plus
# a refresh will not converge.
#
# Force Argo to re-read Git now, without waiting for the poll interval
refresh:
    @KUBECONFIG=$(just _kubeconfig) kubectl -n {{argocd_ns}} annotate application --all \
        argocd.argoproj.io/refresh=hard --overwrite

# Pin the gateway's NodePort to 30080, where the L0 contract says it answers.
#
# THE ONE IMPERATIVE STEP LEFT LOCALLY. istiod provisions the gateway Service
# and assigns its nodePort dynamically, and the Gateway API has no field to pin
# it. Istio's manual-deployment mode (pre-create the Deployment + Service with
# the gateway-name label) would make this declarative; that is a deliberate
# piece of work, not a values change, so it is written down rather than guessed.
#
# Safe to re-run. Nothing in the cluster depends on it — only reaching the
# cluster from your laptop does.
#
# Pin the gateway's NodePort to 30080, where the L0 contract says it answers
edge-port:
    #!/usr/bin/env bash
    set -euo pipefail
    export KUBECONFIG=$(just _kubeconfig)
    svc=$(kubectl -n maal-edge get svc -l gateway.networking.k8s.io/gateway-name=maal-edge \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    test -n "$svc" || { echo "!! no gateway Service yet — has {{l1_env}}-edge synced? (just status)" >&2; exit 1; }

    json=$(kubectl -n maal-edge get svc "$svc" -o json)

    # BY NAME, NOT BY INDEX. istiod puts `status-port` (15021) FIRST on the
    # Service it provisions, so /spec/ports/0 is the readiness port, not HTTPS.
    # Pinning that one leaves 30080 answering istio's status listener: the TCP
    # connection succeeds and every TLS handshake fails with a bare protocol
    # alert, which looks like a certificate problem and is not one.
    i=$(jq -r '[.spec.ports[].name] | index("https") // empty' <<<"$json")
    test -n "$i" || { echo "!! Service $svc has no port named 'https'" >&2; exit 1; }

    ops="[{\"op\":\"replace\",\"path\":\"/spec/ports/$i/nodePort\",\"value\":30080}]"

    # If another port on this Service is already sitting on 30080 — which is
    # exactly what the by-index version of this recipe used to do — free it in
    # the SAME patch. The API server refuses a duplicate allocation, so doing
    # this in two requests would fail on the first and leave the edge down.
    # Removing the field re-allocates it from the ephemeral range.
    squat=$(jq -r --argjson i "$i" \
        '[.spec.ports | to_entries[] | select(.value.nodePort == 30080 and .key != $i) | .key] | first // empty' <<<"$json")
    if [ -n "$squat" ]; then
        ops="[{\"op\":\"remove\",\"path\":\"/spec/ports/$squat/nodePort\"},{\"op\":\"replace\",\"path\":\"/spec/ports/$i/nodePort\",\"value\":30080}]"
        echo ">> port $squat was holding 30080 — reassigning it"
    fi

    kubectl -n maal-edge patch svc "$svc" --type=json -p "$ops"
    echo ">> $svc https nodePort pinned to 30080 — the platform is now at https://<host>:8080"
    just urls

# ─── access ────────────────────────────────────────────────────────────────

# Port-forward the Argo UI -> https://localhost:8080
ui:
    @echo ">> https://localhost:8080  (user: admin, password: just password)"
    @KUBECONFIG=$(just _kubeconfig) kubectl -n {{argocd_ns}} port-forward svc/argocd-server 8080:443

# Initial Argo admin password
password:
    @KUBECONFIG=$(just _kubeconfig) kubectl -n {{argocd_ns}} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# The local root certificate, so a browser can trust the edge without warnings
edge-ca:
    @KUBECONFIG=$(just _kubeconfig) kubectl -n maal-edge get secret maal-edge-ca \
        -o jsonpath='{.data.tls\.crt}' | base64 -d

# Point your shell at this env's cluster: `eval $(just env)`
env:
    @echo "export KUBECONFIG=$(just _kubeconfig)"

# ─── validation (no cluster needed) ────────────────────────────────────────
#
# This is what CI runs. Every Application in L1 and L2 syncs with `automated` +
# `selfHeal`, so a bad commit to main reaches the cluster with no human in the
# path — that is the right default for GitOps and it is only safe if something
# checks the commit first.
#
# One recipe with a selector rather than six: `just check` before you push,
# `just check charts` when you are iterating on one thing, and CI calls the
# pieces by name so a failure says which piece.

# Offline validation: `just check [all|yaml|charts|envs|tofu|shell]`
check what="all":
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{justfile_directory()}}"
    fail=0
    run(){ printf '\n── %s ──\n' "$1"; shift; "$@" || fail=1; }

    # Uses whichever YAML parser the machine has. macOS system python3 ships
    # without PyYAML and GitHub runners ship without a guaranteed ruby, so
    # picking one and hoping produces a lint that silently "fails" everything —
    # which is worse than no lint, because it looks like it ran.
    _yaml(){
        local check_one
        if python3 -c 'import yaml' 2>/dev/null; then
            check_one(){ python3 -c 'import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))' "$1"; }
        elif command -v ruby >/dev/null 2>&1; then
            check_one(){ ruby -ryaml -e 'YAML.load_stream(File.read(ARGV[0]))' "$1"; }
        else
            echo "!! no YAML parser — install PyYAML (pip install pyyaml) or ruby" >&2; return 1
        fi
        local bad=0
        while IFS= read -r f; do
            check_one "$f" 2>/dev/null || { echo "!! parse error: $f"; bad=1; }
        done < <(find L0 L1 L2 -name '*.yaml' \
                   -not -path 'L1/bootstrap/argocd/*' \
                   -not -path 'L1/vendor/*' \
                   -not -path 'L2/charts/*/templates/*')
        [ "$bad" -eq 0 ] && echo ">> all yaml parses"
        return "$bad"
    }

    # The local chart, rendered for every service that uses it. A values file
    # that no longer matches the chart's contract fails here rather than as a
    # red Application.
    _charts(){
        command -v helm >/dev/null || { echo "!! helm not installed" >&2; return 1; }
        helm lint L2/charts/go-service || return 1
        local bad=0
        for f in L2/envs/{{l2_env}}/maal-*.yaml; do
            s=$(basename "$f" .yaml)
            printf '   %-20s' "$s"
            if helm template "$s" L2/charts/go-service -f "$f" >/dev/null 2>&1; then
                echo "ok"
            else
                echo "FAILED"; helm template "$s" L2/charts/go-service -f "$f" >/dev/null; bad=1
            fi
        done
        return "$bad"
    }

    # THE UPSTREAM CHARTS, rendered against this repo's values files.
    #
    # These are the files nothing used to check. `check yaml` proves they
    # parse and `check envs` proves they exist; neither notices that a key was
    # renamed three chart versions ago. Rendering against the pinned chart is
    # what catches that — Temporal's own _deprecations.tpl, for one, turns a
    # stale `schema.setup` key into a hard failure, and this is where that
    # should surface.
    #
    # The catalog is read out of the appsets rather than duplicated here, so
    # adding a component to L1/platform/appset.yaml is still a one-line change.
    # Needs network (it pulls each chart); needs no cluster and no credentials.
    #
    # The catalog is parsed with awk rather than a YAML library: awk is not
    # whitespace-sensitive, and an embedded Python heredoc would be dedented by
    # `just` along with the rest of the recipe body and arrive at the
    # interpreter with its indentation shifted.
    #
    # A catalog entry is a list element (`- component:` / `- app:`) whose
    # chart, repoURL and version sit on sibling keys below it. The first-wins
    # guards matter: both appsets repeat `chart:` and `repoURL:` inside the
    # shared `template:` block further down the file, and without them the last
    # catalog entry would pick up `'{{{{.chart}}}}'` from there.
    _catalog(){
        awk '
            function flush() {
                if (name != "" && chart != "" && repo != "" && ver != "")
                    printf "%s\t%s\t%s\t%s\t%s\n", name, chart, repo, ver, envdir
                name=""; chart=""; repo=""; ver=""
            }
            /^[ \t]+- (component|app): / { flush(); name=$3; next }
            /^[ \t]+chart: /   { if (name != "" && chart == "") chart=$2; next }
            /^[ \t]+repoURL: / { if (name != "" && repo  == "") repo=$2;  next }
            /^[ \t]+version: / { if (name != "" && ver   == "") ver=$2;   next }
            END { flush() }
        ' envdir="$2" "$1"
    }
    _upstream(){
        command -v helm >/dev/null || { echo "!! helm not installed" >&2; return 1; }
        local bad=0 env values args name chart repo version envdir
        while IFS=$'\t' read -r name chart repo version envdir; do
            [ -z "$name" ] && continue
            case "$envdir" in L1/envs) env="{{l1_env}}" ;; *) env="{{l2_env}}" ;; esac
            values="$envdir/$env/$name.yaml"
            printf '   %-18s %-12s' "$name" "$version"
            args=(template "$name" "$chart" --repo "$repo" --version "$version")
            # ignoreMissingValueFiles is set on every appset, so a component
            # with no values file legitimately takes chart defaults.
            [ -f "$values" ] && args+=(-f "$values")
            if helm "${args[@]}" >/dev/null 2>/tmp/maal-helm-err; then
                echo "ok"
            else
                echo "FAILED"; sed 's/^/       /' /tmp/maal-helm-err; bad=1
            fi
        done < <(
            _catalog L1/platform/appset.yaml  L1/envs
            _catalog L2/apps/deps-appset.yaml L2/envs
        )
        return "$bad"
    }

    # Every catalog entry should have a values file in every env. Reports gaps
    # rather than failing: a component with nothing to override legitimately
    # has none. The point is that the gap is visible in the PR instead of
    # discovered in the cluster.
    #
    # Reads BOTH L1 catalogs. The old L1 recipe read only appset.yaml while its
    # `verify` read both, so gateway-api and mesh-ca were silently exempt.
    _envs(){
        local comps
        comps=$(grep -hoE '^\s+- component: \S+' L1/platform/appset.yaml L1/platform/appset-vendored.yaml | awk '{print $3}' | sort -u)
        for envfile in L1/envs/*.yaml; do
            local e; e=$(basename "$envfile" .yaml)
            for c in $comps; do
                test -f "L1/envs/$e/$c.yaml" || echo "   missing (chart defaults apply): L1/envs/$e/$c.yaml"
            done
        done
        local apps
        apps=$(grep -hoE '^\s+- (service|app): \S+' L2/apps/*.yaml | awk '{print $3}' | sort -u)
        for envfile in L2/envs/*.yaml; do
            local e; e=$(basename "$envfile" .yaml)
            for a in $apps; do
                test -f "L2/envs/$e/$a.yaml" || echo "   missing (chart defaults apply): L2/envs/$e/$a.yaml"
            done
        done
        echo ">> env/catalog matrix checked"
    }

    _tofu(){
        command -v tofu >/dev/null || { echo "!! tofu not installed" >&2; return 1; }
        tofu fmt -recursive -check -diff L0/aws L0/gcp || return 1
        local bad=0
        for e in L0/aws L0/gcp; do
            echo "   $e"
            # -backend=false: validation needs no bucket and no credentials,
            # which is the only reason the unapplied cloud skeletons can be
            # checked before anyone has an account to point them at.
            ( cd "$e" && tofu init -backend=false -upgrade >/dev/null && tofu validate ) || bad=1
        done
        return "$bad"
    }

    # The bootstrap scripts are the imperative seam. They run with
    # `set -euo pipefail` against a real cluster, and an unquoted expansion
    # there is a much worse afternoon than one in a values file.
    _shell(){
        command -v shellcheck >/dev/null || { echo "!! shellcheck not installed" >&2; return 1; }
        shellcheck L0/local/*.sh L1/bootstrap/*.sh L2/bootstrap/*.sh
    }

    # Each branch must record its own failure. `exit "$fail"` at the bottom is
    # the only exit path, so a branch that merely returns non-zero without
    # setting `fail` would make a broken `just check yaml` exit 0 — a check
    # that passes when the thing is broken is worse than no check.
    case "{{what}}" in
      yaml)     _yaml                      || fail=1 ;;
      charts)   { _charts && _upstream; }  || fail=1 ;;
      envs)     _envs                      || fail=1 ;;
      tofu)     _tofu                      || fail=1 ;;
      shell)    _shell                     || fail=1 ;;
      all)
        run "yaml"            _yaml
        run "go-service"      _charts
        run "upstream charts" _upstream
        run "env matrix"      _envs
        run "opentofu"        _tofu
        run "shellcheck"      _shell
        echo
        [ "$fail" -eq 0 ] && echo ">> all checks passed" || echo "!! checks failed"
        ;;
      *) echo "!! unknown check '{{what}}' — use all, yaml, charts, envs, tofu or shell" >&2; exit 1 ;;
    esac
    exit "$fail"

# ─── cloud (OpenTofu) ──────────────────────────────────────────────────────
#
# Skeletons: validated by `just check tofu`, never applied. One recipe rather
# than six near-identical ones — `just cloud plan aws`, `just cloud up gcp`.

# Drive a cloud L0: `just cloud <plan|up|down> <aws|gcp>`
cloud action provider:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}/L0/{{provider}}" 2>/dev/null \
        || { echo "!! no such provider '{{provider}}' — use aws or gcp" >&2; exit 1; }

    # Both cloud implementations declare a partial backend, so init needs the
    # bucket details. Fail with the fix rather than silently using local state.
    if [ ! -f backend.hcl ]; then
        echo "!! L0/{{provider}}/backend.hcl is missing — remote state is not configured." >&2
        echo "   cp backend.hcl.example backend.hcl   # then edit" >&2
        echo "   It explains which bucket to create first." >&2
        exit 1
    fi
    tofu init -upgrade -backend-config=backend.hcl

    case "{{action}}" in
      plan) tofu plan ;;
      up)
        # THE TWO-PHASE APPLY, automated.
        #
        # The `kubernetes` provider in versions.tf is configured from outputs of
        # the cluster this module creates, so on empty state OpenTofu cannot
        # plan the StorageClass — it has no endpoint to talk to yet. Phase 1
        # builds the cluster; phase 2 does everything else.
        #
        # Scripted rather than documented because a `-target` you have to
        # remember is a `-target` you forget at 2am. `-target` is otherwise a
        # smell: used here exactly once, for provider bootstrapping, and never
        # to work around a broken dependency graph.
        if ! tofu state list >/dev/null 2>&1 || [ -z "$(tofu state list 2>/dev/null)" ]; then
            echo ">> empty state — phase 1: the cluster only"
            case "{{provider}}" in
                aws) tofu apply -target=module.vpc -target=module.eks ;;
                gcp) tofu apply -target=google_container_cluster.this -target=google_container_node_pool.default ;;
            esac
            echo ">> phase 2: everything else"
        fi
        tofu apply
        # Publish the contract from tofu outputs — same keys as local.
        tofu output -json \
          | jq '{provider, cluster, kubeconfig, storageClass, lbEndpoint} | map_values(.value)' \
          > contract.json
        echo ">> {{provider}} contract published"
        jq . contract.json
        ;;
      down)
        tofu destroy
        rm -f contract.json kubeconfig
        echo ">> {{provider}} contract withdrawn"
        ;;
      *) echo "!! unknown action '{{action}}' — use plan, up or down" >&2; exit 1 ;;
    esac

# ─── maintenance ───────────────────────────────────────────────────────────

# Keep the tag in sync with the `version` field on the gateway-api element in
# L1/platform/appset-vendored.yaml.
#
# Re-vendor the Gateway API CRDs at <tag>
vendor-gateway-api tag="v1.6.1":
    @mkdir -p {{justfile_directory()}}/L1/vendor/gateway-api
    curl -fsSL "https://github.com/kubernetes-sigs/gateway-api/releases/download/{{tag}}/standard-install.yaml" \
        -o {{justfile_directory()}}/L1/vendor/gateway-api/standard-install.yaml
    @echo ">> vendored Gateway API {{tag}} — update appset-vendored.yaml, then commit"
