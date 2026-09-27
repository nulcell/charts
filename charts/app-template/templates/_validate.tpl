{{/* Values that would otherwise render something silently wrong. */}}
{{- define "at.validate" -}}
{{- $types := list "deployment" "statefulset" "daemonset" "pod" "job" "cronjob" -}}
{{- range $key, $w := include "at.workloads" . | fromYaml -}}
{{- if not (has $w.type $types) }}{{ fail (printf "workloads.%s.type must be one of %s, got %q" $key (join ", " $types) $w.type) }}{{ end -}}
{{- $scalable := has $w.type (list "deployment" "statefulset") -}}
{{- if and (hasKey $w "replicas") (not $scalable) }}{{ fail (printf "workloads.%s.replicas only applies to deployment/statefulset" $key) }}{{ end -}}
{{- if and ($w.autoscaling | default dict).enabled (not $scalable) }}{{ fail (printf "workloads.%s.autoscaling only applies to deployment/statefulset" $key) }}{{ end -}}
{{- with $w.autoscaling }}{{ if not (has (.type | default "hpa") (list "hpa" "keda")) }}{{ fail (printf "workloads.%s.autoscaling.type must be hpa or keda" $key) }}{{ end }}{{ end -}}
{{- if and ($w.vpa | default dict).enabled (has $w.type (list "pod" "job" "cronjob")) }}{{ fail (printf "workloads.%s.vpa does not apply to %s" $key $w.type) }}{{ end -}}
{{- if and ($w.pdb | default dict).enabled (not $scalable) }}{{ fail (printf "workloads.%s.pdb only applies to deployment/statefulset" $key) }}{{ end -}}
{{- if and (eq $w.type "cronjob") (not $w.schedule) }}{{ fail (printf "workloads.%s.schedule is required for a cronjob" $key) }}{{ end -}}
{{- if hasKey $.Values.datastores $key }}{{ fail (printf "%q is both a workload and a datastore; their labels would collide" $key) }}{{ end -}}
{{- end -}}
{{- end }}
