# bootstrap/argocd

`install.yaml` (the pinned Argo CD manifests) is **vendored here on your first
`just up`** and applied server-side. Commit and push it afterwards:

- it makes the install reproducible and air-gap-ready, and
- the self-managing `argocd` Application (in `../../platform/argocd.yaml`) reads
  these manifests from the remote repo — until the file is committed, that app
  reads OutOfSync/Unknown, which is expected.

Bump the version by editing `ARGO_VERSION` in `../up.sh`, deleting this
`install.yaml`, and re-running `just up` to re-vendor.

## Persisting controller flags

Because Argo self-manages from this file, any imperative `kubectl patch` against
an Argo deployment gets reverted on the next sync. Flags you want to keep — for
example `--enable-progressive-syncs` on the applicationset controller, which
`just progressive` applies imperatively — must be edited into this file and
pushed.

That is the trade for self-management: the vendored manifest is the real config,
and a patch is only ever a temporary experiment.
