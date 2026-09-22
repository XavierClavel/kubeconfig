# kubeconfig

Cluster-wide configuration for my k3s cluster: the pieces that are shared
between projects. Individual applications (Deployments, Services, Ingresses,
their Certificates and PVCs) live in their own repositories and are deployed
from there.

Everything here is applied by [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)
on every push to `master`. That workflow also **bootstraps** the applications
listed in [`apps/registry.conf`](apps/registry.conf) when they are not yet
running — see [Application bootstrap](#application-bootstrap). Their manifests
are not copied here; each entry points at the overlay in the project's own
repository.

## Layout

```
kustomization.yaml              root overlay -- the whole cluster config
infrastructure/
  namespaces/                   namespaces owned by this repo
  cert-manager/                 letsencrypt-prod / letsencrypt-staging ClusterIssuers
  traefik/                      HelmChartConfig customising the k3s-bundled Traefik
  kafka/                        Strimzi Kafka cluster + node pool
bootstrap/
  install.sh                    idempotent Helm install of the operators
  versions.env                  pinned chart versions
  values/                       Helm values per operator
apps/
  registry.conf                 which app repos to bootstrap, and from where
  sync.sh                       applies the ones not already running
.github/
  workflows/deploy.yml          validate -> diff (PR) / apply + sync (master)
  scripts/write-kubeconfig.sh   turns the KUBE_CONFIG secret into a kubeconfig
```

The split matters: **kustomize cannot install the operators**, because the CRDs
must exist before `kubectl apply -k .` can even parse a `Kafka` resource.
`bootstrap/` installs controllers and CRDs; `infrastructure/` contains the
custom resources that depend on them.

## Local usage

```bash
kubectl kustomize .        # render, no cluster needed
kubectl diff -k .          # preview against the live cluster
kubectl apply -k .         # apply
./bootstrap/install.sh     # (re)install the operators at their pinned versions
./apps/sync.sh --dry-run   # what application bootstrap would do
./apps/sync.sh             # bootstrap the applications that are missing
```

## Application bootstrap

Applications are owned by their own repositories, but a fresh cluster has to
get them running somehow. [`apps/registry.conf`](apps/registry.conf) is a table
of them:

```
# name            namespace   marker                       url
cooknco           cooknco     deployment/cooknco-backend   https://github.com/XavierClavel/Cooknco//k8s/overlays/prod?ref=master
```

[`apps/sync.sh`](apps/sync.sh) walks it and, for each entry, checks whether the
**marker** resource exists:

- **it exists** → the app is running, and the script leaves it completely alone.
- **it does not** → `kubectl apply -k <url>`, which fetches and renders the
  overlay straight from the project repository.

The manifests are never vendored here. The URL is a
[kustomize remote target](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/remoteBuild.md):
`//` separates the repository from the path inside it, and `?ref=` pins the
branch or tag.

### Why it only ever bootstraps

`apps/sync.sh` is deliberately **not** a reconciler, and the registry is
deliberately **not** part of the root `kustomization.yaml`. Once an app runs,
its own CI owns the running state — image tags are set with
`kustomize edit set image` at deploy time and are not committed to the project
repo. Re-applying from here would roll the running image back to whatever tag
happens to be in git, undoing the project's last deploy. Hence the marker
check, and hence `--force` requiring an explicit app name:

```bash
./apps/sync.sh                    # bootstrap whatever is missing
./apps/sync.sh --dry-run          # render every target, change nothing
./apps/sync.sh cooknco            # consider only these entries
./apps/sync.sh --force cooknco    # re-apply even though it is running
```

`--force` is the "reset this app to what its repo says" lever. It takes names
on purpose: a bare `--force` would re-apply every project at once.

### Adding an app

Append a line to `apps/registry.conf`. Three things to get right:

- **The marker** should be something the app cannot be running without — a
  Deployment is the usual choice — and it must sit in the namespace named in
  column 2. A marker that never matches means the app is re-applied on every
  run, which is exactly the rollback described above; a marker that always
  matches means it is never bootstrapped. Check it against the rendered
  overlay rather than guessing:

  ```bash
  kubectl kustomize '<url>' | grep -A3 '^kind: Deployment'
  ```

- **`ref=` is the branch that project actually deploys from**, not a
  convention. Most of these are `master`; `PetApp`'s default branch is
  `develop`.

- **`KafkaTopic` resources need their own entry.** Strimzi's topic operator
  only reconciles them in the Kafka cluster's namespace, so they cannot live
  under the app overlay — see the `cooknco-topics` line.

The `validate` job checks the file's shape on every PR. There is nothing to
register for an app whose repo has no `k8s/` overlay yet.

### Private repositories

`kubectl apply -k <github url>` shells out to `git`, which on a GitHub runner
is unauthenticated — public repos resolve, private ones fail with
`authentication required`. Add a PAT as `APPS_REPO_TOKEN` in the `k3s`
environment and the workflow rewrites it into the clone URL. Locally your own
git credentials already cover it.

It has to be a **classic** PAT with the `repo` scope. A fine-grained token can
only reach repositories owned by the token's own account, and `PetApp` belongs
to another user's account — a fine-grained token cannot be granted access to it
at all, however the permissions are set.

Without the secret, public apps still sync and the job logs a notice for the
private ones.

## Conventions

### TLS is cert-manager's job, and only cert-manager's

Certificates are issued by cert-manager through the `letsencrypt-prod`
ClusterIssuer and land in a per-namespace Secret. Traefik just serves whatever
Secret an Ingress points at.

Traefik's own ACME resolver is deliberately **not** configured. Having both was
the previous setup, and it meant two independent things racing to obtain a
certificate for the same hostname against the same Let's Encrypt rate limit.

A project Ingress should therefore look like this, with no
`traefik.ingress.kubernetes.io/router.tls.certresolver` annotation:

```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: ["example.fyi"]
      secretName: example-tls
  rules:
    - host: example.fyi
      # ...
```

Use `letsencrypt-staging` while wiring up a new domain -- production is rate
limited to 50 certificates per registered domain per week, and a misconfigured
DNS record burns through that fast.

### Kafka

One cluster, `kafka-kraft`, in the `kafka` namespace. Bootstrap address for
clients:

```
kafka-kraft-kafka-bootstrap.kafka.svc.cluster.local:9092
```

The Strimzi operator runs with `watchAnyNamespace: true`, so a project declares
its own topics next to its Deployment rather than here:

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: my-topic
  namespace: my-project
  labels:
    strimzi.io/cluster: kafka-kraft   # not "cooknco-kafka" -- that cluster is gone
spec:
  partitions: 3
  replicas: 1
```

### Nothing is pruned

The workflow only ever applies. Removing a file from this repo does **not**
delete the resource from the cluster -- delete it by hand:

```bash
kubectl delete -f infrastructure/<component>/<file>.yaml
```

This is intentional: `kubectl apply --prune` keys off label selectors and
deletes anything it does not recognise, which on a shared cluster reaches
resources owned by the project repositories.

## GitHub Actions setup

The workflow needs one secret, in an environment named **`k3s`**
(*Settings -> Environments -> New environment -> `k3s`*, then add the secret
there rather than at repository level, so a protection rule can gate deploys):

| Secret | Contents |
| --- | --- |
| `KUBE_CONFIG` | The full kubeconfig, raw YAML or base64. Both are accepted. |

On k3s the file to use is `/etc/rancher/k3s/k3s.yaml` from the server:

```bash
ssh vps 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://<vps-public-ip>:6443#' \
  | base64 -w0
```

Two things that bite:

- **The `server:` address must be the public one.** The file on the VPS says
  `127.0.0.1`, which on a runner resolves to the runner itself.
- **The API server must be reachable from GitHub-hosted runners.** k3s listens
  on `:6443`; if it is firewalled (it should be), either allow
  [GitHub's runner ranges](https://api.github.com/meta) or use a self-hosted
  runner / a Tailscale step in the workflow. `write-kubeconfig.sh` fails with an
  explicit message when it cannot reach the API server, so this shows up as a
  clear error rather than a timeout.

`/etc/rancher/k3s/k3s.yaml` grants `cluster-admin`. If you would rather not hand
that to CI, create a dedicated ServiceAccount and build a kubeconfig from its
token instead.

### What runs when

| Event | validate | diff | apply |
| --- | --- | --- | --- |
| Pull request | yes | yes | no |
| Push to `master` | yes | no | yes |
| Manual dispatch | yes | no | yes (optionally re-running bootstrap) |

`bootstrap/install.sh` re-runs automatically when anything under `bootstrap/`
changes, and on demand via the `run_bootstrap` input of a manual dispatch.

## Migrating to a new VPS

1. **Install k3s** on the new host. Match the old minor version first; upgrade
   afterwards, one thing at a time.

   ```bash
   curl -sfL https://get.k3s.io | sh -
   ```

2. **Bootstrap the operators.**

   ```bash
   KUBECONFIG=./new-vps.yaml ./bootstrap/install.sh
   ```

3. **Apply this repo.**

   ```bash
   KUBECONFIG=./new-vps.yaml kubectl apply -k .
   ```

4. **Move the stateful data.** None of it is in git, and this is the only part
   of the migration that cannot be replayed from a manifest:

   - **PersistentVolumeClaims.** k3s' default `local-path` provisioner stores
     volumes under `/var/lib/rancher/k3s/storage/<pvc-dir>` on the node. Stop the
     workload, `rsync` the directory across, then let the workload come back up.
     Kafka's volume is `data-kafka-kraft-kraft-nodes-0`; stop it by annotating
     the `Kafka` resource with `strimzi.io/pause-reconciliation: "true"` and then
     scaling the StatefulSet to 0, otherwise you copy a torn log segment.
   - **Application Secrets.** `cooknco-secrets`, `cooknco-config` and friends are
     not in git. Dump and re-apply them:

     ```bash
     kubectl --kubeconfig old.yaml get secret -n <ns> <name> -o yaml \
       | kubectl --kubeconfig new.yaml apply -f -
     ```

   - **The ACME account key** (`letsencrypt-prod` Secret in the `cert-manager`
     namespace). Copying it lets the new cluster reuse the existing Let's Encrypt
     account and its rate-limit allowance. If you skip it, cert-manager registers
     a fresh account -- fine, but it re-issues every certificate.
   - **Issued certificates.** Not worth copying. Once DNS points at the new host,
     cert-manager re-issues from the Certificate resources in the project repos.
     Do the DNS cutover *after* the new cluster is otherwise healthy, since
     HTTP-01 validation follows DNS.

5. **Cut DNS over**, watch `kubectl get certificate -A` go `READY=True`, then
   decommission the old host.

6. **Update the `KUBE_CONFIG` secret** to point at the new VPS, and re-run the
   workflow to confirm CI still reaches the cluster.

## Upgrading Strimzi

`bootstrap/versions.env` pins Strimzi to **1.0.1** on purpose: release 1.1.0
removed support for Kafka 4.1.x, which is the version
[`infrastructure/kafka/kafka-cluster.yaml`](infrastructure/kafka/kafka-cluster.yaml)
runs. Moving forward is a two-step dance:

1. While still on Strimzi 1.0.1, bump `spec.kafka.version` to a 4.2.x release
   and let the rolling update finish.
2. Then bump `STRIMZI_VERSION`.

Doing both at once leaves the operator unable to manage the running cluster.
