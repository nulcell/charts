{{/*
Datastores as {key: {engine, type, name, host, port, selector, peers}}. Chart-managed ones
have a selector; external ones have peers, derived from their hosts unless given.
*/}}
{{/* A top-level values map with every string tpl-rendered. Usage: include "at.tplValues" (list $ "persistence") */}}
{{- define "at.tplValues" -}}
{{- tpl (toYaml (get (index . 0).Values (index . 1))) (index . 0) -}}
{{- end }}

{{- define "at.datastoreValues" -}}
{{- include "at.tplValues" (list . "datastores") -}}
{{- end }}

{{- define "at.datastores" -}}
{{- $ports := dict "postgres" 5432 "redis" 6379 "mariadb" 3306 "mysql" 3306 -}}
{{- $types := dict "postgres" (list "cnpg" "standalone" "external") "redis" (list "standalone" "external") "mariadb" (list "operator" "external") -}}
{{- $out := dict -}}
{{- range $key, $d := include "at.datastoreValues" . | fromYaml -}}
{{- if ne $d.enabled false -}}
{{- if ne $d.type "external" -}}
{{- if not (hasKey $types $d.engine) }}{{ fail (printf "datastores.%s.engine must be postgres, redis or mariadb unless type is external, got %q" $key $d.engine) }}{{ end -}}
{{- if not (has $d.type (get $types $d.engine)) }}{{ fail (printf "datastores.%s.type for %s must be one of %s, got %q" $key $d.engine (get $types $d.engine | join ", ") $d.type) }}{{ end -}}
{{- end -}}
{{- $name := $d.name | default (include "at.resourceName" (list $ $key)) -}}
{{- $v := dict "engine" $d.engine "type" $d.type "name" $name "port" (required (printf "datastores.%s.port is required for engine %q" $key $d.engine) ($d.port | default (get $ports $d.engine)) | int) "host" $name "selector" dict -}}
{{- if eq $d.type "cnpg" -}}
{{- $_ := set $v "host" (printf "%s-rw" $name) -}}
{{- $_ := set $v "selector" (dict "cnpg.io/cluster" $name) -}}
{{- else if eq $d.type "operator" -}}
{{- $_ := set $v "selector" (dict "app.kubernetes.io/name" "mariadb" "app.kubernetes.io/instance" $name) -}}
{{- else if eq $d.type "standalone" -}}
{{- $_ := set $v "selector" (include "at.selectorLabels" (dict "ctx" $ "component" $key) | fromYaml) -}}
{{- else -}}
{{- $hosts := $d.hosts | default (list $d.host | compact) -}}
{{- if not $hosts }}{{ fail (printf "datastores.%s: host or hosts is required for an external datastore" $key) }}{{ end -}}
{{- $_ := set $v "host" (join ", " $hosts) -}}
{{- $peers := $d.peers | default list -}}
{{- if not $peers -}}
{{- /* Cilium's socket LB rewrites in-cluster Service traffic to pod IPs, so toFQDNs can't match it. */ -}}
{{- range $hosts -}}
{{- if regexMatch "^[0-9.]+$" . }}{{ $peers = append $peers (dict "cidr" (printf "%s/32" .)) }}
{{- else if not (contains "." .) }}{{ $peers = append $peers (dict "namespace" $.Release.Namespace) }}
{{- else if regexMatch "^[^.]+\\.[^.]+\\.svc(\\.cluster\\.local)?$" . }}{{ $peers = append $peers (dict "namespace" (index (splitList "." .) 1)) }}
{{- else }}{{ $peers = append $peers (dict "fqdn" .) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- $_ := set $v "peers" $peers -}}
{{- end -}}
{{- $_ := set $out $key $v -}}
{{- end -}}
{{- end -}}
{{- toYaml $out -}}
{{- end }}

{{/* The single-replica StatefulSet + Service behind a standalone datastore. */}}
{{- define "at.standaloneDatastore" -}}
{{- $ctx := .ctx -}}
{{- $d := .d -}}
{{- $v := .v -}}
{{- $pg := eq $d.engine "postgres" -}}
{{- $image := mustMergeOverwrite (ternary (dict "repository" "postgres" "tag" "18") (dict "repository" "valkey/valkey" "tag" "8") $pg) ($d.image | default dict) -}}
{{- $storage := mustMergeOverwrite (deepCopy $ctx.Values.defaults.persistence) (dict "size" "5Gi") ($d.storage | default dict) -}}
{{- $selector := include "at.selectorLabels" (dict "ctx" $ctx "component" .key) -}}
{{- $secret := $d.existingSecret -}}
{{- if and $pg (not $secret) }}{{ fail (printf "datastores.%s.existingSecret is required for standalone postgres" .key) }}{{ end -}}
apiVersion: v1
kind: Service
{{ include "at.metadata" (dict "ctx" $ctx "name" $v.name "component" .key) }}
spec:
  selector:
    {{- $selector | nindent 4 }}
  ports:
    - name: {{ $d.engine }}
      port: {{ $v.port }}
      targetPort: {{ $d.engine }}
---
apiVersion: apps/v1
kind: StatefulSet
{{ include "at.metadata" (dict "ctx" $ctx "name" $v.name "component" .key) }}
spec:
  serviceName: {{ $v.name }}
  replicas: 1
  selector:
    matchLabels:
      {{- $selector | nindent 6 }}
  template:
    metadata:
      labels:
        {{- $selector | nindent 8 }}
    spec:
      enableServiceLinks: false
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {{ $d.engine }}
          image: {{ printf "%s:%v" $image.repository $image.tag }}
          {{- $args := $d.args | default (ternary list (list "valkey-server" "--save" "60 1") $pg) }}
          {{- if and $secret (not $pg) }}{{ $args = concat $args (list "--requirepass" "$(REDIS_PASSWORD)") }}{{ end }}
          {{- with $args }}
          args:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- if or $pg $secret }}
          env:
          {{- end }}
            {{- if $pg }}
            - name: POSTGRES_DB
              value: {{ $d.database | default (include "at.fullname" $ctx) | quote }}
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: {name: {{ $secret }}, key: {{ $d.usernameKey | default "username" }}}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: {name: {{ $secret }}, key: {{ $d.passwordKey | default "password" }}}
            {{- else if $secret }}
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef: {name: {{ $secret }}, key: {{ $d.passwordKey | default "password" }}}
            {{- end }}
          ports:
            - name: {{ $d.engine }}
              containerPort: {{ $v.port }}
          {{- $probe := ternary (dict "exec" (dict "command" (list "sh" "-c" "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\""))) (dict "tcpSocket" (dict "port" $d.engine)) $pg }}
          readinessProbe:
            {{- toYaml (merge (dict "periodSeconds" 10) $probe) | nindent 12 }}
          livenessProbe:
            {{- toYaml (merge (dict "periodSeconds" 20 "initialDelaySeconds" 30) $probe) | nindent 12 }}
          {{- with $d.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: [ALL]
          volumeMounts:
            - name: data
              mountPath: {{ ternary "/var/lib/postgresql" "/data" $pg }}
            - name: tmp
              mountPath: /tmp
            {{- if $pg }}
            - name: run
              mountPath: /var/run/postgresql
            {{- end }}
            {{- with $d.volumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: tmp
          emptyDir: {}
        {{- if $pg }}
        - name: run
          emptyDir: {}
        {{- end }}
        {{- with $d.volumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [{{ $storage.accessMode }}]
        {{- with $storage.storageClass }}
        storageClassName: {{ . }}
        {{- end }}
        resources:
          requests:
            storage: {{ $storage.size }}
{{- end }}
