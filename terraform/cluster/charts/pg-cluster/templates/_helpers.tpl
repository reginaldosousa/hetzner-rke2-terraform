{{- /* helm lint renders `required` as "", so it falls back to the release name there. */}}
{{- define "pg-cluster.name" -}}
{{- required "name is required" .Values.name | default .Release.Name -}}
{{- end -}}

{{- define "pg-cluster.plugin" -}}
barman-cloud.cloudnative-pg.io
{{- end -}}
