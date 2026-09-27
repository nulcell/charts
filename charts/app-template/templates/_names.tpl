{{- define "at.name" -}}
{{- .Values.nameOverride | default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "at.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* <fullname>-<key>, or <fullname> when they match. Usage: include "at.resourceName" (list $ key) */}}
{{- define "at.resourceName" -}}
{{- $full := include "at.fullname" (index . 0) -}}
{{- $key := index . 1 -}}
{{- if eq $key $full }}{{ $full }}{{ else }}{{ printf "%s-%s" $full $key | trunc 63 | trimSuffix "-" }}{{ end -}}
{{- end }}

{{/* A workload's `name`, else its resourceName. Usage: (list $ key) */}}
{{- define "at.workloadName" -}}
{{- (get ((index . 0).Values.workloads) (index . 1) | default dict).name | default (include "at.resourceName" .) -}}
{{- end }}

{{/* A service's `name`; else, keyed like its workload, the workload's name; else <workload>-<key>. Usage: (list $ workload service) */}}
{{- define "at.serviceName" -}}
{{- $ctx := index . 0 -}}
{{- $wl := include "at.workloadName" (list $ctx (index . 1)) -}}
{{- $svc := get ((get $ctx.Values.workloads (index . 1) | default dict).services | default dict) (index . 2) | default dict -}}
{{- if $svc.name }}{{ $svc.name }}
{{- else if eq (index . 1) (index . 2) }}{{ $wl }}
{{- else }}{{ printf "%s-%s" $wl (index . 2) | trunc 63 | trimSuffix "-" }}{{ end -}}
{{- end }}

{{/* Usage: include "at.selectorLabels" (dict "ctx" $ "component" key) */}}
{{- define "at.selectorLabels" -}}
app.kubernetes.io/name: {{ include "at.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- with .component }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end }}

{{- define "at.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{ include "at.selectorLabels" . }}
{{- with .ctx.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Object metadata. Annotations merge over commonAnnotations and are tpl-rendered.
Usage: include "at.metadata" (dict "ctx" $ "name" n "component" c "labels" l "annotations" a)
*/}}
{{- define "at.metadata" -}}
metadata:
  name: {{ .name }}
  namespace: {{ .ctx.Release.Namespace }}
  labels:
    {{- include "at.labels" . | nindent 4 }}
    {{- with .labels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with merge (deepCopy (.annotations | default dict)) .ctx.Values.commonAnnotations }}
  annotations:
    {{- tpl (toYaml .) $.ctx | nindent 4 }}
  {{- end }}
{{- end }}

{{/*
Enabled workloads with defaults merged in, as YAML. Every template reads workloads
through this so references resolve against the same view.
*/}}
{{- define "at.workloads" -}}
{{- $out := dict -}}
{{- range $key, $w := .Values.workloads -}}
{{- $w = mustMergeOverwrite (deepCopy $.Values.defaults.workload) (deepCopy $w) -}}
{{- if ne $w.enabled false -}}
{{- $_ := set $w "type" ($w.type | default "deployment") -}}
{{- range $field := list "containers" "initContainers" -}}
{{- $merged := dict -}}
{{- range $name, $c := (get $w $field | default dict) -}}
{{- $m := mustMergeOverwrite (deepCopy $.Values.defaults.container) (deepCopy $c) -}}
{{- /* A probe replaces its default whole: handlers are exclusive, and {} must disable it. */ -}}
{{- $probes := deepCopy ($.Values.defaults.container.probes | default dict) -}}
{{- range $kind, $p := ($c.probes | default dict) }}{{ $_ := set $probes $kind $p }}{{ end -}}
{{- $_ := set $m "probes" $probes -}}
{{- $_ := set $merged $name $m -}}
{{- end -}}
{{- $_ := set $w $field $merged -}}
{{- end -}}
{{- $_ := set $out $key $w -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/* A workload's service account name. Usage: (list $ key) */}}
{{- define "at.serviceAccountName" -}}
{{- $ctx := index . 0 -}}
{{- $key := index . 1 -}}
{{- $sa := get $ctx.Values.serviceAccounts $key -}}
{{- if not $sa -}}
{{ $key }}
{{- else if ne $sa.create false -}}
{{ $sa.name | default (ternary (include "at.fullname" $ctx) (include "at.resourceName" (list $ctx $key)) (eq $key "default")) }}
{{- else -}}
{{ $sa.name | default "default" }}
{{- end -}}
{{- end }}

{{/*
A configMaps/secrets/externalSecrets key resolves to the chart object; anything else is
taken as an existing object's name. Usage: (list $ "configMaps" name)
*/}}
{{- define "at.refName" -}}
{{- $ctx := index . 0 -}}
{{- $name := index . 2 -}}
{{- $maps := ternary (list "configMaps") (list "secrets" "externalSecrets") (eq (index . 1) "configMaps") -}}
{{- $owned := false -}}
{{- range $maps }}{{ if hasKey (get $ctx.Values .) $name }}{{ $owned = true }}{{ end }}{{ end -}}
{{- if $owned }}{{ include "at.resourceName" (list $ctx $name) }}{{ else }}{{ $name }}{{ end -}}
{{- end }}

{{/* A container port name or number on a workload, as a number. Usage: (dict "w" w "port" p "ref" "context for errors") */}}
{{- define "at.containerPort" -}}
{{- $port := .port -}}
{{- if kindIs "string" $port -}}
{{- $found := "" -}}
{{- range $c := concat (values (.w.containers | default dict)) (values (.w.initContainers | default dict)) -}}
{{- range $name, $p := ($c.ports | default dict) -}}
{{- if eq $name $port }}{{ $found = include "at.portNumber" $p }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if not $found }}{{ fail (printf "%s: no container port named %q" .ref $port) }}{{ end -}}
{{ int $found }}
{{- else -}}
{{ int $port }}
{{- end -}}
{{- end }}

{{/* A service port name or number, as a number. Usage: (dict "svc" svc "port" p "ref" "...") */}}
{{- define "at.servicePort" -}}
{{- $port := .port -}}
{{- if kindIs "string" $port -}}
{{- $p := get .svc.ports $port -}}
{{- if not $p }}{{ fail (printf "%s: no service port named %q" .ref $port) }}{{ end -}}
{{ include "at.portNumber" $p }}
{{- else -}}
{{ int $port }}
{{- end -}}
{{- end }}

{{/* Resolves {workload, service} to the service, failing on a dangling ref. Usage: (dict "ctx" $ "workloads" w "ref" r "from" "...") */}}
{{- define "at.lookupService" -}}
{{- $w := get .workloads .ref.workload -}}
{{- if not $w }}{{ fail (printf "%s: unknown workload %q" .from .ref.workload) }}{{ end -}}
{{- $svc := get ($w.services | default dict) .ref.service -}}
{{- if not $svc }}{{ fail (printf "%s: workload %q has no service %q" .from .ref.workload .ref.service) }}{{ end -}}
{{- toYaml $svc -}}
{{- end }}

{{/* A port given as a number or {port: n}. */}}
{{- define "at.portNumber" -}}
{{- if kindIs "map" . }}{{ int .port }}{{ else }}{{ int . }}{{ end -}}
{{- end }}
