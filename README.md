# of-helm

Helm charts Argo CD deploys on the OF cluster. A deploy is a commit on `master`; nothing here is applied by hand.

| Chart | What it runs | Namespace | Argo CD Application |
|---|---|---|---|
| `charts/of-api` | the Flask API behind the edge ALB, with a `db-migrate` Job before every sync | `of-api` | `prod01-us-of-api` |
| `charts/of-load` | the stress API, its levels in a ConfigMap | `of-load` | `prod01-us-of-load` |

## How a deploy works

Each Application points at `master`, path `charts/<chart>`, and syncs automatically with prune and self-heal, so a change on `master` is live within Argo CD's poll interval (three minutes) or at once after a manual sync. The Application is created by the service's stack in the infrastructure repository (`app-services/of-api`, `app-services/of-load`), which also seeds the chart here on its first apply and leaves it alone afterwards. Replica counts are ignored by Argo CD because the HPA owns them.

What moves between deploys is one line per chart, `image.tag` in `charts/<chart>/values.yaml`. CI of each service pushes three tags per commit to the ECR repository named after the chart: `<sha>` (the multi-arch index), `<sha>-amd64` and `<sha>-arm64`.

## Deploy a new build

Developers use of-launch, the deployment dashboard at `https://launch.<zone domain>`: sign in, choose the environment, the service and the build, press Deploy. It commits the new `image.tag` to this repository on `master`, triggers the Argo CD sync, and records who deployed what; `/status` shows the sync and the pods, `/deployment-history` every deploy. No git, kubectl or AWS access is needed.

From a terminal, and until of-launch is up, the script does the same from the repository root with AWS credentials for the account:

```bash
./scripts/update-tags.sh                        # shows current -> newest for both charts, asks yes/no
./scripts/update-tags.sh --auto-approve --push  # writes, commits "deploy: <chart> -> <tag>" per chart, pushes master
./scripts/update-tags.sh --chart of-api         # one chart
./scripts/update-tags.sh --region us-west-2     # read the replicated repositories instead of us-east-1
```

The script takes the newest tag whose `-amd64` and `-arm64` images both exist, so a half-pushed build is never deployed. Without `--push` it only edits the file: review `git diff`, commit, push.

## Roll back

In of-launch, deploy an older build of the service. From a terminal:

```bash
./scripts/update-tags.sh --chart of-api --tag <older sha> --auto-approve --push
```

The tag must exist in ECR; the script refuses one that does not. `git revert` of the deploy commit, pushed, works as well.

## x86 or Graviton

Each chart has two architecture files, and the Application stacks `values.yaml` with one of them:

| File | Pins the pods to | How |
|---|---|---|
| `values-amd64.yaml` | x86 nodes | `nodeSelector: kubernetes.io/arch: amd64` |
| `values-arm64.yaml` | Graviton nodes | `nodeSelector: kubernetes.io/arch: arm64` plus the toleration for the `arch=arm64:NoSchedule` taint |

Which file a service uses is the `architecture` input of its stack in the infrastructure repository; change it there and apply, and Argo CD rolls the pods onto the other node pool. The same image tag serves both, which is why a tag counts only with both arch images. The pattern for any other workload is the same two lines; the infrastructure README shows it on a plain Deployment.

## Watch a deploy

of-launch shows it on `/status` and `/deployment-history`. With cluster access:

```bash
kubectl -n argocd get application prod01-us-of-api          # Synced / Healthy
kubectl -n of-api get pods -o wide                          # NODE shows which pool the pods landed on
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d   # admin password
```

The Argo CD UI is `https://argocd.<zone domain>`, user `admin`.

## What the Application sets

The region-specific values never sit in this repository. The Application passes `image.repository` (the region's ECR URL), `containerPort`, `targetGroupBinding.targetGroupARN`, `secrets.db.name` and `keda.awsRegion`, so both regions read this one chart.

## Settings and secrets

Settings come from Secrets Manager, never from values. The SecretProviderClass mounts one file per setting under `/mnt/secrets` through the Secrets Store CSI driver: the app secret named after the release (`<environment>-<application>`, written by the stack) and, for of-api, the database secret the aurora stack writes (`host`, `port`, `dbname`, `username`, `password` as `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`). The apps read the files themselves through `SECRETS_DIR`, so no value sits in a Kubernetes Secret or an environment variable. The pod's service account reads them by EKS Pod Identity, so no role ARN sits in a chart. `secrets.enabled: false` drops the mount and leaves the settings to `env`.

## What each chart renders

Deployment, Service, ServiceAccount, HPA (`autoscaling/v2`, 2 to 5 pods at 70% CPU), PDB (`maxUnavailable: 1`), zone and host spread, a TargetGroupBinding into the service's target group on the edge ALB, and the SecretProviderClass. of-api adds the `db-migrate` Job, an Argo CD PreSync hook running `flask --app app init-db` from the same image, so the API pods only roll once the schema step succeeded. It runs only in the regions in `dbMigrate.writerRegions` (matched against `keda.awsRegion`), the one holding the database writer; the read-only copy gets the schema by replication. Probes are on `/healthz`. KEDA scaling on ALB requests is in the chart, off by default (`keda.enabled`). Resources, replicas, probes, graceful shutdown (`preStopSleepSeconds`, `terminationGracePeriodSeconds`) and `stress.levels` for of-load are all in `values.yaml`.

## Render locally

```bash
helm template of-api charts/of-api -f charts/of-api/values-amd64.yaml \
  --set image.repository=<registry>/of-api,containerPort=8000,secrets.db.name=<db secret>,targetGroupBinding.targetGroupARN=<arn>
```

The same for of-load with `values-arm64.yaml`.

## CI

`.github/workflows/ci.yml` runs on every push and pull request to `master`: `helm lint` on every chart, a render of every values file validated with kubeconform (strict, Kubernetes 1.36, CRD schemas included), and Snyk IaC on the renders. It deploys nothing. The file is generated by Terraform, so an edit made here is overwritten.

## Add a service

A new chart needs three things outside this repository: an ECR repository of the same name (`system/ecr`), and an `app-services/<service>` stack that seeds the chart here and creates its Application, target group and secret. Once the repository has images, `scripts/update-tags.sh` picks the chart up by itself.
