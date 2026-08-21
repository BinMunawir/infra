# mesh-ca — istiod's signing CA, from cert-manager

**STATUS: written, ready to enable, NOT in the catalog.** The root app syncs
`L1/platform` with `recurse: false`, so nothing in this directory is applied.
That is deliberate — read "Why this is parked" before turning it on.

## The problem it solves

istiod self-signs its mesh CA by default. The root is held in the
`istio-ca-secret` Secret and, if that Secret is lost, **regenerated on the next
istiod start** — at which point every workload certificate in the mesh chains to
a root nothing else trusts, and mTLS across the mesh breaks until every pod has
rotated. There is no operator action that makes the old root come back.

For a payments platform that is a availability risk and an audit finding: the
mesh's root of trust has no lifecycle, no backup, and no rotation procedure.

## Why this is parked rather than enabled

istiod loads a plugged-in CA from a Secret named `cacerts` in `istio-system`,
and the documented layout is four PEM keys:

```
ca-cert.pem  ca-key.pem  root-cert.pem  cert-chain.pem
```

cert-manager writes `kubernetes.io/tls` Secrets — `tls.crt`, `tls.key`,
`ca.crt` — and has no way to rename them. So a cert-manager `Certificate` with
`secretName: cacerts` produces a Secret istiod may or may not read depending on
version, and the failure mode is silent: istiod logs that it is using a
self-signed CA and carries on. Shipping that into the mesh unverified is exactly
the class of change `prune: false` exists to protect against.

The two honest ways forward, in order of preference:

### Option A — cert-manager istio-csr (recommended)

`jetstack/cert-manager-istio-csr` replaces istiod's CA server entirely: istiod
is started with `ENABLE_CA_SERVER=false` and `caAddress` pointed at istio-csr,
which signs workload CSRs from a cert-manager `Issuer`. No `cacerts` Secret and
no key-name problem, and workload certs get cert-manager's lifecycle.

This is a new L1 catalog component plus two values in `envs/*/istiod.yaml`. It
is the right answer for cloud; it needs a session with a live cluster.

### Option B — a plugged-in `cacerts`, generated once

Keep `istiod.yaml` as it is and create the Secret by hand from a CA you hold
outside the cluster (Vault, KMS, an offline root). `manifests.yaml` here builds
the chain with cert-manager and gets you the material; converting to the
four-key layout is one `kubectl create secret generic` away:

```sh
kubectl -n istio-system create secret generic cacerts \
  --from-file=ca-cert.pem=tls.crt \
  --from-file=ca-key.pem=tls.key \
  --from-file=root-cert.pem=ca.crt \
  --from-file=cert-chain.pem=tls.crt
```

That is imperative, which is why it is not the recommendation — but it is
verifiable in five minutes, and it is a large improvement over a root that
disappears on restart.

## Verifying either option

```sh
# What is istiod actually signing with?
kubectl -n istio-system logs deploy/istiod | grep -iE 'self-signed|plugged|cacerts'

# The root every workload trusts:
kubectl -n istio-system get cm istio-ca-root-cert -o jsonpath='{.data.root-cert\.pem}' \
  | openssl x509 -noout -issuer -subject -dates
```

If istiod came up before `cacerts` existed it will already have self-signed;
restart it (`kubectl -n istio-system rollout restart deploy/istiod`) and let
workloads rotate.

## Ordering, when this is enabled

cert-manager (wave 0) must be running before its CRDs and webhook can admit
these objects, and the CA must exist before istiod (wave 1) starts. So this
belongs at a wave between them — add it to `../appset-vendored.yaml` with
`wave: "1"` and move `istiod` to `wave: "2"`, `ztunnel` to `wave: "3"`, and
extend the `RollingSync` steps in `../appset.yaml` to match.
