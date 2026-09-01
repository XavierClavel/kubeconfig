# kubeconfig

Cluster-wide configuration for my k3s cluster: the pieces that are shared
between projects. Individual applications (Deployments, Services, Ingresses,
their Certificates and PVCs) live in their own repositories and are deployed
from there.

Everything here is applied by [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml)
on every push to `master`.

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
.github/
  workflows/deploy.yml          validate -> diff (PR) / apply (master)
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
```

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
