# mesh-ca — istiod's signing CA, from cert-manager

**STATUS: live.** This directory is a component in
[`../appset-vendored.yaml`](../appset-vendored.yaml) (wave 1). istiod's own CA
server is off, and every workload certificate in the mesh — ztunnel's included
— is signed by [istio-csr](../appset.yaml) from the chain built here.

## The problem it solved

istiod self-signs its mesh CA by default. The root is held in the
`istio-ca-secret` Secret and, if that Secret is lost, **regenerated on the next
istiod start** — at which point every workload certificate in the mesh chains to
a root nothing else trusts, and mTLS across the mesh breaks until every pod has
rotated. There is no operator action that makes the old root come back.

For a payments platform that is an availability risk and an audit finding: the
mesh's root of trust had no lifecycle, no backup, and no rotation procedure.

## What runs now

`manifests.yaml` builds the chain; istio-csr signs from its bottom rung:

```
Issuer maal-mesh-selfsigned  (selfSigned)
   └─▶ Certificate maal-mesh-root          10y, ECDSA P-256, secret: maal-mesh-root
          └─▶ Issuer maal-mesh-ca          (ca: maal-mesh-root)
                 └─▶ Certificate maal-mesh-intermediate   1y, renewed 30d out
                        └─▶ Issuer maal-mesh-intermediate (ca: …)
                               └─▶ istio-csr signs every workload CSR
```

istio-csr runs in `istio-system`, not the chart's default `cert-manager`
namespace. That is deliberate and is what keeps this fully declarative: it must
read the issuer *and* mount the root certificate it serves as the trust bundle,
a Secret cannot be mounted across namespaces, and the upstream guide otherwise
resolves this with an imperative `kubectl create secret` copying the root into
the cert-manager namespace. Running it next to what it reads deletes that step.
The cost is two non-default values, both in
[`../../envs/dev-local/istio-csr.yaml`](../../envs/dev-local/istio-csr.yaml).

### Why Option A and not a plugged-in `cacerts`

The rejected alternative was handing istiod a `cacerts` Secret. cert-manager
writes `kubernetes.io/tls` Secrets — `tls.crt`, `tls.key`, `ca.crt` — while
istiod wants four differently-named PEM keys, and nothing renames them, so it
needs an imperative step *and* the failure mode is silent: istiod logs that it
is using a self-signed CA and carries on. istio-csr removes the key-name problem
entirely and gives workload certs cert-manager's lifecycle.

### Ambient's extra requirement

ztunnel holds one identity but requests certificates on behalf of every pod on
its node. istio-csr refuses that by default. `app.server.caTrustedNodeAccounts:
istio-system/ztunnel` permits it, and istio-csr verifies the pod really is on
that node before issuing — node authentication, added upstream for exactly this
case. Without it, istiod and ztunnel both come up healthy and **no ambient
workload ever gets a certificate**.

## Ordering

The chain is the dependency graph, so the waves follow it:

| Wave | Component | Needs |
|---|---|---|
| 0 | cert-manager | — |
| 1 | **mesh-ca** (here) | cert-manager's CRDs + webhook |
| 2 | istio-csr | the issuer above |
| 3 | istiod | istio-csr serving, or it boots self-signed |
| 4 | ztunnel | istiod |

`RollingSync` in [`../appset.yaml`](../appset.yaml) enforces waves 2–4. Wave 1
is annotation-only: this component lives in the *vendored* appset, which has no
RollingSync strategy, so on a cold cluster it may sync before cert-manager's
CRDs are served and fail with `no matches for kind Certificate`. Retry/backoff
converges it. Noisy on first boot, correct by the time anything depends on it.

## Verifying

`just verify` section 7 asserts all of this — both certificates Ready, istio-csr
serving, `ENABLE_CA_SERVER=false`, and that the published trust root is ours. By
hand:

```sh
# What every workload is handed. Must say maal-mesh-root, not a cluster.local O=.
kubectl -n istio-system get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' \
  | openssl x509 -noout -issuer -subject -dates

# The chain cert-manager actually issued.
kubectl -n istio-system get certificaterequests
```

To see the certificate a live workload is really using, read it from the ztunnel
on that pod's node. ztunnel binds its admin API to localhost, so neither
`port-forward` nor the node can reach it — an ephemeral container in the ztunnel
pod shares its network namespace and can:

```sh
zt=$(kubectl -n istio-system get pods -l app=ztunnel \
       -o jsonpath="{range .items[?(@.spec.nodeName=='<node>')]}{.metadata.name}{end}")
kubectl debug -n istio-system pod/$zt --image=curlimages/curl:8.11.1 -- sleep 300
kubectl -n istio-system exec $zt -c <debugger> -- curl -s localhost:15000/config_dump \
  | jq '.certificates[] | {identity, state}'
```

`.certChain` there is leaf-then-intermediate, base64 PEM; it must verify against
`.rootCerts` and show issuer `CN=maal-mesh-intermediate`. Note the endpoint is
`/config_dump` — ztunnel has no `/certs`.

## Taking this to cloud

The root is self-signed here because dev needs no more than that. In cloud,
replace the `maal-mesh-selfsigned` Issuer and the `maal-mesh-root` Certificate
with a Vault or AWS PCA issuer and keep the root offline. **Nothing else
changes** — istio-csr only ever names `maal-mesh-intermediate`, which is why the
issuer is split from the certificate rather than pointing istio-csr at the root.

One caveat carried from upstream: installing istio-csr *after* Istio is not a
supported path, because the mesh's root of trust changes under running
workloads. It was safe here — the mesh carried no traffic — but on a live
cluster treat it as a planned migration with a pod rollout behind it.
