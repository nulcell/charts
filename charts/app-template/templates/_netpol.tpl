{{/*
Network-policy entries resolved to peers: {selector, namespace, podLabels, entity, cidr,
fqdn, ports: [{port, protocol}]}. One shape, rendered for Cilium or Kubernetes below.
Usage: include "at.np.peers" (dict "ctx" $ "workloads" w "datastores" d "key" key "dir" "ingress|egress")
*/}}
{{- define "at.np.peers" -}}
{{- $ctx := .ctx -}}
{{- $self := get .workloads .key -}}
{{- $out := list -}}
{{- range $i, $e := get ($self.networkPolicy | default dict) $.dir | default list -}}
{{- $ref := printf "workloads.%s.networkPolicy.%s[%d]" $.key $.dir $i -}}
{{- $e = kindIs "string" $e | ternary (dict $e true) $e -}}
{{- $peer := dict "ports" list -}}
{{- $portOn := $self -}}
{{- if $e.gateway -}}
{{- $_ := set $peer "entity" "ingress" -}}
{{- range $svc := $self.services | default dict -}}
{{- range $name, $p := $svc.ports -}}
{{- $pm := kindIs "map" $p | ternary $p dict -}}
{{- $_ := set $peer "ports" (append $peer.ports (dict "port" (include "at.containerPort" (dict "w" $self "port" ($pm.targetPort | default $name) "ref" $ref) | int) "protocol" ($pm.protocol | default "TCP"))) -}}
{{- end -}}
{{- end -}}
{{- else if $e.world -}}
{{- $_ := set $peer "entity" "all" -}}
{{- else if $e.prometheus -}}
{{- $_ := set $peer "namespace" $ctx.Values.networkPolicy.prometheus.namespace -}}
{{- $_ := set $peer "podLabels" $ctx.Values.networkPolicy.prometheus.podLabels -}}
{{- else if $e.workload -}}
{{- $target := get $.workloads $e.workload -}}
{{- /* A disabled peer isn't running, so there is nothing to allow; only an unknown one is an error. */ -}}
{{- if not $target }}{{ if hasKey $ctx.Values.workloads $e.workload }}{{ continue }}{{ end }}{{ fail (printf "%s: unknown workload %q" $ref $e.workload) }}{{ end -}}
{{- $_ := set $peer "selector" (include "at.selectorLabels" (dict "ctx" $ctx "component" $e.workload) | fromYaml) -}}
{{- if eq $.dir "egress" }}{{ $portOn = $target }}{{ end -}}
{{- else if $e.datastore -}}
{{- $d := get $.datastores $e.datastore -}}
{{- if not $d }}{{ if hasKey $ctx.Values.datastores $e.datastore }}{{ continue }}{{ end }}{{ fail (printf "%s: unknown datastore %q" $ref $e.datastore) }}{{ end -}}
{{- $ports := list (dict "port" $d.port "protocol" "TCP") -}}
{{- if $d.selector -}}
{{- $_ := set $peer "selector" $d.selector -}}
{{- $_ := set $peer "ports" $ports -}}
{{- else -}}
{{- /* An external datastore can have several peers; all but the last are appended here. */ -}}
{{- $peers := $d.peers -}}
{{- range initial $peers }}{{ $out = append $out (merge (deepCopy .) (dict "ports" $ports)) }}{{ end -}}
{{- $peer = merge (deepCopy (last $peers)) (dict "ports" $ports) -}}
{{- end -}}
{{- else if $e.namespace -}}
{{- $_ := set $peer "namespace" $e.namespace -}}
{{- $_ := set $peer "podLabels" ($e.podLabels | default dict) -}}
{{- if eq $.dir "egress" }}{{ $portOn = dict }}{{ end -}}
{{- else if $e.cidr -}}
{{- $_ := set $peer "cidr" $e.cidr -}}
{{- if eq $.dir "egress" }}{{ $portOn = dict }}{{ end -}}
{{- else if $e.fqdn -}}
{{- $_ := set $peer "fqdn" $e.fqdn -}}
{{- if eq $.dir "egress" }}{{ $portOn = dict }}{{ end -}}
{{- else -}}
{{- fail (printf "%s: expected gateway, world, prometheus, workload, datastore, namespace, cidr or fqdn" $ref) -}}
{{- end -}}
{{- with $e.port -}}
{{- $port := . -}}
{{- if and (kindIs "string" $port) $portOn }}{{ $port = include "at.containerPort" (dict "w" $portOn "port" $port "ref" $ref) | int }}{{ end -}}
{{- $_ := set $peer "ports" (list (dict "port" $port "protocol" ($e.protocol | default "TCP"))) -}}
{{- end -}}
{{- $out = append $out $peer -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{- define "at.np.cilium" -}}
{{- $from := eq .dir "ingress" | ternary "from" "to" -}}
{{- range .peers }}
- {{- if .entity }}
  {{ $from }}Entities: [{{ .entity }}]
  {{- else if .cidr }}
  {{ $from }}CIDR: [{{ .cidr | quote }}]
  {{- else if .fqdn }}
  toFQDNs:
    - {{ contains "*" .fqdn | ternary "matchPattern" "matchName" }}: {{ .fqdn | quote }}
  {{- else if .namespace }}
  {{ $from }}Endpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: {{ .namespace }}
        {{- with .podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  {{- else }}
  {{ $from }}Endpoints:
    - matchLabels:
        {{- toYaml .selector | nindent 8 }}
  {{- end }}
  {{- with .ports }}
  toPorts:
    - ports:
        {{- range . }}
        - port: {{ .port | quote }}
          protocol: {{ .protocol }}
        {{- end }}
  {{- end }}
{{- end }}
{{- end }}

{{- define "at.np.kubernetes" -}}
{{- $ctx := .ctx -}}
{{- $from := eq .dir "ingress" | ternary "from" "to" -}}
{{- range .peers }}
{{- if .fqdn }}{{ fail (printf "networkPolicy.type kubernetes cannot express fqdn %q; use cidr or type cilium" .fqdn) }}{{ end }}
{{- $rule := dict }}
{{- if eq (.entity | default "") "ingress" }}
{{- $_ := set $rule $from (required "networkPolicy.gatewayPeers is required for `gateway` with type kubernetes" $ctx.Values.networkPolicy.gatewayPeers) }}
{{- else if .cidr }}
{{- $_ := set $rule $from (list (dict "ipBlock" (dict "cidr" .cidr))) }}
{{- else if .namespace }}
{{- $peer := dict "namespaceSelector" (dict "matchLabels" (dict "kubernetes.io/metadata.name" .namespace)) }}
{{- with .podLabels }}{{ $_ := set $peer "podSelector" (dict "matchLabels" .) }}{{ end }}
{{- $_ := set $rule $from (list $peer) }}
{{- else if .selector }}
{{- $_ := set $rule $from (list (dict "podSelector" (dict "matchLabels" .selector))) }}
{{- end }}
{{- with .ports }}{{ $_ := set $rule "ports" . }}{{ end }}
- {{ toJson $rule }}
{{- end }}
{{- end }}

{{/* Matches nothing: puts a Cilium direction into default-deny with no openings. */}}
{{- define "at.np.denyAll" -}}
- fromEndpoints:
    - matchExpressions:
        - key: k8s:io.kubernetes.pod.namespace
          operator: DoesNotExist
{{- end }}

{{/* Usage: include "at.np.policy" (dict "ctx" $ "name" n "component" c "selector" s "ingress" peers "egress" peers "raw" raw "apiserver" bool) */}}
{{- define "at.np.policy" -}}
{{- $ctx := .ctx -}}
{{- $np := $ctx.Values.networkPolicy -}}
{{- $raw := .raw | default dict -}}
{{- if has $np.type (list "cilium" "both") }}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
{{ include "at.metadata" (dict "ctx" $ctx "name" .name "component" .component) }}
spec:
  endpointSelector:
    matchLabels:
      {{- toYaml .selector | nindent 6 }}
  enableDefaultDeny:
    ingress: true
    egress: true
  ingress:
    {{- if or .ingress $raw.ingress }}
    {{- include "at.np.cilium" (dict "peers" .ingress "dir" "ingress") | nindent 4 }}
    {{- with $raw.ingress }}{{ toYaml . | nindent 4 }}{{ end }}
    {{- else }}
    {{- include "at.np.denyAll" . | nindent 4 }}
    {{- end }}
  egress:
    {{- /* DNS goes through Cilium's proxy so toFQDNs resolves. */}}
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: {{ $np.dns.namespace }}
            {{- toYaml $np.dns.podLabels | nindent 12 }}
      toPorts:
        - ports:
            - {port: "53", protocol: UDP}
            - {port: "53", protocol: TCP}
          rules:
            dns:
              - matchPattern: "*"
    {{- if .apiserver }}
    {{- /* Talos runs the API server on the host network, so it can classify as host/remote-node. */}}
    - toEntities: [kube-apiserver, host, remote-node]
    {{- end }}
    {{- include "at.np.cilium" (dict "peers" .egress "dir" "egress") | nindent 4 }}
    {{- with $raw.egress }}{{ toYaml . | nindent 4 }}{{ end }}
{{- end }}
{{- if has $np.type (list "kubernetes" "both") }}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
{{ include "at.metadata" (dict "ctx" $ctx "name" .name "component" .component) }}
spec:
  podSelector:
    matchLabels:
      {{- toYaml .selector | nindent 6 }}
  policyTypes: [Ingress, Egress]
  ingress:
    {{- include "at.np.kubernetes" (dict "ctx" $ctx "peers" .ingress "dir" "ingress") | nindent 4 }}
    {{- if eq $np.type "kubernetes" }}{{ with $raw.ingress }}{{ toYaml . | nindent 4 }}{{ end }}{{ end }}
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ $np.dns.namespace }}
          podSelector:
            matchLabels:
              {{- toYaml $np.dns.podLabels | nindent 14 }}
      ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
    {{- if .apiserver }}
    - ports:
        - {port: 443, protocol: TCP}
        - {port: 6443, protocol: TCP}
    {{- end }}
    {{- include "at.np.kubernetes" (dict "ctx" $ctx "peers" .egress "dir" "egress") | nindent 4 }}
    {{- if eq $np.type "kubernetes" }}{{ with $raw.egress }}{{ toYaml . | nindent 4 }}{{ end }}{{ end }}
{{- end }}
{{- end }}
