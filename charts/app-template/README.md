# app-template

Compose-style chart: describe workloads, their services, routes, storage, datastores and
network policy in values; the chart renders the Kubernetes objects. Layout follows
[bjw-s app-template](https://github.com/bjw-s-labs/helm-charts); `values.yaml` documents
every field and `values.schema.json` rejects typos.

```yaml
# kustomization.yaml
helmCharts:
  - name: app-template
    repo: oci://ghcr.io/nulcell/charts
    version: 0.1.0
    releaseName: web
    namespace: web
    valuesFile: values.yaml
```

```yaml
# values.yaml
workloads:
  web:
    replicas: 2
    containers:
      web:
        image: {repository: nginxinc/nginx-unprivileged, tag: "1.29"}
        ports: {http: 8080}
        resources: {requests: {cpu: 10m, memory: 32Mi}, limits: {memory: 64Mi}}
    services:
      web:
        ports: {http: 80}
    networkPolicy:
      ingress: [gateway]
      egress: [{datastore: db}]
routes:
  web:
    parentRefs: [{name: internal, namespace: gateway}]
    hostnames: [web.example.com]
    rules:
      - backends: [{workload: web, service: web, port: http}]
datastores:
  db: {engine: postgres, type: cnpg}
```

## Behaviour worth knowing

- **Names**: `<release>-<key>`; a key equal to the release name renders as just `<release>`.
  A service keyed like its workload takes the workload's name. Pods are selected by
  `app.kubernetes.io/{name,instance,component}`, where `component` is the workload key.
- **Defaults**: `defaults.workload` / `defaults.container` / `defaults.persistence` are
  deep-merged under each entry. An entry's value wins (including `false`); lists replace.
  Containers default to a restricted-PSS security context and uid 65532.
- **Network policy**: every workload is default-deny both ways with only DNS egress open.
  Everything else is listed by name (`gateway`, `workload`, `datastore`, `namespace`, `fqdn`,
  `cidr`, `world`, `prometheus`). Listing a datastore in egress also opens that datastore's
  ingress. `type: kubernetes` cannot express `fqdn`, and needs `gatewayPeers` for `gateway`.
- **Datastores**: any mix of engines and instances. `cnpg`/`standalone`/`operator` are
  chart-managed; `external` takes any `engine` (mysql, mongodb, ...) with `host` or `hosts`.
  Egress peers derive per host - IP to `/32`, bare name to this namespace, `x.ns.svc` to
  namespace `ns`, else FQDN - or set `peers` explicitly. In-cluster hosts never use FQDN
  rules: Cilium's socket LB rewrites Service traffic to pod IPs. A shared in-cluster DB's
  own policy must still admit this app. Nothing injects connection env. Reference the documented names from env
  values, which are tpl-rendered: `"{{ .Release.Name }}-db-rw"`, secret `"{{ .Release.Name }}-db-app"`.
- **Rollouts**: pods carry a checksum of every chart-owned ConfigMap/Secret they reference.
  ExternalSecret-backed secrets live in the cluster, so changes there need a manual restart.
- **Templating**: every string under `workloads` and `datastores` is tpl-rendered, so values
  can use the release, `.Values.global` and helpers (`name: "{{ .Release.Name }}-migrate"`).
  Results stay strings; write a literal `{{` as `{{ "{{" }}`.
- **Init containers** run in key order - prefix keys (`01-migrate`) when order matters.
- **Escape hatches**: `spec` (controller), `job`, `pod` and unknown container fields pass
  through verbatim; `networkPolicy.raw`, route `backendRefs`, datastore `cluster` likewise.

## Development

```bash
helm lint charts/app-template --strict
helm unittest charts/app-template
for f in charts/app-template/ci/*.yaml; do helm template t charts/app-template -f "$f" >/dev/null; done
```
