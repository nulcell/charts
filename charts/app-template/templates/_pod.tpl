{{/* Usage: include "at.pod" (dict "ctx" $ "key" key "w" workload) */}}
{{- define "at.pod" -}}
{{- $ctx := .ctx -}}
{{- $key := .key -}}
{{- $w := .w -}}
{{- $selector := include "at.selectorLabels" (dict "ctx" $ctx "component" $key) | fromYaml -}}
{{- $volumes := include "at.volumes" . | fromYamlArray -}}
{{- $annotations := deepCopy ($w.podAnnotations | default dict) -}}
{{- range $kind, $names := include "at.podRefs" . | fromYaml -}}
{{- range $names -}}
{{- $_ := set $annotations (printf "checksum/%s-%s" (lower $kind) .) (get (get $ctx.Values $kind) . | toYaml | sha256sum) -}}
{{- end -}}
{{- end -}}
metadata:
  labels:
    {{- toYaml $selector | nindent 4 }}
    {{- with $ctx.Values.commonLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
    {{- with $w.podLabels }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- with $annotations }}
  annotations:
    {{- tpl (toYaml .) $ctx | nindent 4 }}
  {{- end }}
spec:
  serviceAccountName: {{ include "at.serviceAccountName" (list $ctx $w.serviceAccount) }}
  automountServiceAccountToken: {{ (get $ctx.Values.serviceAccounts $w.serviceAccount | default dict).automount | default false }}
  enableServiceLinks: {{ $w.enableServiceLinks }}
  {{- with $w.imagePullSecrets }}
  imagePullSecrets:
    {{- range . }}
    - name: {{ if kindIs "map" . }}{{ .name }}{{ else }}{{ . }}{{ end }}
    {{- end }}
  {{- end }}
  {{- with $w.podSecurityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- range $field := list "nodeSelector" "tolerations" "affinity" "priorityClassName" }}
  {{- with get $w $field }}
  {{ $field }}:
    {{- if kindIs "string" . }} {{ . }}{{ else }}{{ toYaml . | nindent 4 }}{{ end }}
  {{- end }}
  {{- end }}
  {{- with $w.topologySpreadConstraints }}
  topologySpreadConstraints:
    {{- range . }}
    - {{- toYaml (merge (deepCopy .) (dict "labelSelector" (dict "matchLabels" $selector))) | nindent 6 }}
    {{- end }}
  {{- end }}
  {{- $pod := deepCopy ($w.pod | default dict) }}
  {{- if has $w.type (list "job" "cronjob") }}
  {{- $_ := set $pod "restartPolicy" ($pod.restartPolicy | default "OnFailure") }}
  {{- end }}
  {{- with $pod }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- with $w.initContainers }}
  initContainers:
    {{- range $name, $c := . }}
    {{- include "at.container" (dict "ctx" $ctx "key" $key "w" $w "name" $name "c" $c) | nindent 4 }}
    {{- end }}
  {{- end }}
  {{- if not $w.containers }}{{ fail (printf "workloads.%s: needs at least one container" $key) }}{{ end }}
  containers:
    {{- range $name, $c := $w.containers }}
    {{- include "at.container" (dict "ctx" $ctx "key" $key "w" $w "name" $name "c" $c) | nindent 4 }}
    {{- end }}
  {{- with $volumes }}
  volumes:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{- define "at.container" -}}
{{- $ctx := .ctx -}}
{{- $c := .c -}}
{{- $ref := printf "workloads.%s.containers.%s" .key .name -}}
{{- $image := $c.image | default dict -}}
- name: {{ .name }}
  {{- $img := required (printf "%s.image.repository is required" $ref) $image.repository }}
  {{- with $image.tag }}{{ $img = printf "%s:%v" $img . }}{{ end }}
  {{- with $image.digest }}{{ $img = printf "%s@%s" $img . }}{{ end }}
  image: {{ $img }}
  {{- with $image.pullPolicy }}
  imagePullPolicy: {{ . }}
  {{- end }}
  {{- with omit $c "image" "env" "envFrom" "ports" "probes" "resources" "securityContext" "volumeMounts" "enabled" }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- with $c.env }}
  env:
    {{- range $k := keys . | sortAlpha }}
    {{- $v := get $c.env $k }}
    {{- if not (kindIs "invalid" $v) }}
    - name: {{ $k }}
      {{- if kindIs "map" $v }}
      {{- tpl (toYaml $v) $ctx | nindent 6 }}
      {{- else }}
      value: {{ tpl (toString $v) $ctx | quote }}
      {{- end }}
    {{- end }}
    {{- end }}
  {{- end }}
  {{- with $c.envFrom }}
  envFrom:
    {{- range . }}
    {{- if .configMap }}
    - configMapRef:
        name: {{ include "at.refName" (list $ctx "configMaps" .configMap) }}
    {{- else if or .secret .externalSecret }}
    - secretRef:
        name: {{ include "at.refName" (list $ctx "secrets" (.secret | default .externalSecret)) }}
    {{- else }}
    - {{- toYaml (omit . "prefix") | nindent 6 }}
    {{- end }}
      {{- with .prefix }}
      prefix: {{ . }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- with $c.ports }}
  ports:
    {{- range $name, $p := . }}
    - name: {{ $name }}
      containerPort: {{ include "at.portNumber" $p }}
      protocol: {{ (kindIs "map" $p | ternary $p dict).protocol | default "TCP" }}
    {{- end }}
  {{- end }}
  {{- range $probe, $spec := $c.probes | default dict }}
  {{- with $spec }}
  {{ $probe }}Probe:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- end }}
  {{- with $c.resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $c.securityContext }}
  securityContext:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- $mounts := include "at.mounts" . | fromYamlArray }}
  {{- with concat $mounts ($c.volumeMounts | default list) }}
  volumeMounts:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}

{{/* Mount entries for one container: persistence + volumeClaimTemplates, global then advanced. */}}
{{- define "at.mounts" -}}
{{- $out := list -}}
{{- $sources := list -}}
{{- range $vol, $p := include "at.tplValues" (list .ctx "persistence") | fromYaml -}}
{{- if ne $p.enabled false -}}
{{- $sources = append $sources (dict "vol" $vol "global" $p.globalMounts "advanced" (get (get ($p.advancedMounts | default dict) $.key | default dict) $.name)) -}}
{{- end -}}
{{- end -}}
{{- if eq .w.type "statefulset" -}}
{{- range $vol, $p := .w.volumeClaimTemplates -}}
{{- $sources = append $sources (dict "vol" $vol "global" $p.globalMounts "advanced" (get ($p.advancedMounts | default dict) $.name)) -}}
{{- end -}}
{{- end -}}
{{- range $sources -}}
{{- $vol := .vol -}}
{{- range concat (.global | default list) (.advanced | default list) -}}
{{- $m := dict "name" $vol "mountPath" (required (printf "persistence.%s: every mount needs a path" $vol) .path) -}}
{{- with .subPath }}{{ $_ := set $m "subPath" . }}{{ end -}}
{{- with .readOnly }}{{ $_ := set $m "readOnly" . }}{{ end -}}
{{- $out = append $out $m -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/* persistence entries mounted anywhere in this workload. */}}
{{- define "at.mountedPersistence" -}}
{{- $out := dict -}}
{{- range $vol, $p := include "at.tplValues" (list .ctx "persistence") | fromYaml -}}
{{- if and (ne $p.enabled false) (or $p.globalMounts (hasKey ($p.advancedMounts | default dict) $.key)) -}}
{{- $_ := set $out $vol $p -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{- define "at.volumes" -}}
{{- $ctx := .ctx -}}
{{- $out := list -}}
{{- range $vol, $p := include "at.mountedPersistence" . | fromYaml -}}
{{- $v := dict "name" $vol -}}
{{- $type := $p.type | default "pvc" -}}
{{- if eq $type "pvc" -}}
{{- $_ := set $v "persistentVolumeClaim" (dict "claimName" (include "at.resourceName" (list $ctx $vol))) -}}
{{- else if eq $type "existingClaim" -}}
{{- $_ := set $v "persistentVolumeClaim" (dict "claimName" (required (printf "persistence.%s.existingClaim is required" $vol) $p.existingClaim)) -}}
{{- else if eq $type "emptyDir" -}}
{{- $_ := set $v "emptyDir" (pick $p "medium" "sizeLimit") -}}
{{- else if eq $type "configMap" -}}
{{- $_ := set $v "configMap" (merge (dict "name" (include "at.refName" (list $ctx "configMaps" (required (printf "persistence.%s.name is required" $vol) $p.name)))) (pick $p "items" "defaultMode")) -}}
{{- else if eq $type "secret" -}}
{{- $_ := set $v "secret" (merge (dict "secretName" (include "at.refName" (list $ctx "secrets" (required (printf "persistence.%s.name is required" $vol) $p.name)))) (pick $p "items" "defaultMode")) -}}
{{- else if eq $type "hostPath" -}}
{{- $hp := dict "path" (required (printf "persistence.%s.path is required" $vol) $p.path) -}}
{{- with $p.hostPathType }}{{ $_ := set $hp "type" . }}{{ end -}}
{{- $_ := set $v "hostPath" $hp -}}
{{- else -}}
{{- fail (printf "persistence.%s.type must be pvc, existingClaim, emptyDir, configMap, secret or hostPath, got %q" $vol $type) -}}
{{- end -}}
{{- $out = append $out $v -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/* Chart-owned configMaps/secrets this pod reads, for checksum annotations. */}}
{{- define "at.podRefs" -}}
{{- $ctx := .ctx -}}
{{- $refs := dict "configMaps" list "secrets" list -}}
{{- range $c := concat (values (.w.containers | default dict)) (values (.w.initContainers | default dict)) -}}
{{- range $c.envFrom -}}
{{- if and .configMap (hasKey $ctx.Values.configMaps .configMap) }}{{ $_ := set $refs "configMaps" (append $refs.configMaps .configMap) }}{{ end -}}
{{- if and .secret (hasKey $ctx.Values.secrets .secret) }}{{ $_ := set $refs "secrets" (append $refs.secrets .secret) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- range $vol, $p := include "at.mountedPersistence" . | fromYaml -}}
{{- if and (eq ($p.type | default "pvc") "configMap") (hasKey $ctx.Values.configMaps $p.name) }}{{ $_ := set $refs "configMaps" (append $refs.configMaps $p.name) }}{{ end -}}
{{- if and (eq ($p.type | default "pvc") "secret") (hasKey $ctx.Values.secrets $p.name) }}{{ $_ := set $refs "secrets" (append $refs.secrets $p.name) }}{{ end -}}
{{- end -}}
{{- toYaml (dict "configMaps" (uniq $refs.configMaps) "secrets" (uniq $refs.secrets)) -}}
{{- end }}
