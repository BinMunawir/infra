{{/* Service name — the release name unless explicitly overridden. */}}
{{- define "go-service.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels on every object. */}}
{{- define "go-service.labels" -}}
app.kubernetes.io/name: {{ include "go-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: maal
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Selector labels for one workload. Takes a dict of (root, workloadName).
The workload name is part of the selector so `worker` and `server` pods —
same image, same service — are distinguishable to their own Deployments.
*/}}
{{- define "go-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "go-service.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .workloadName }}
{{- end -}}

{{- define "go-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "go-service.name" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Fully-qualified image reference. */}}
{{- define "go-service.image" -}}
{{- with .Values.image.registry }}{{ . }}/{{ end }}{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}

{{- define "go-service.configMapName" -}}
{{ include "go-service.name" . }}-config
{{- end -}}

{{- define "go-service.secretName" -}}
{{ include "go-service.name" . }}-secrets
{{- end -}}

{{/*
The env block shared by every workload, in the precedence the Go Service
Standard defines: ENV selects the config file, plain values next, then secrets,
then database credentials — each layer able to override the one before it,
because cleanenv reads env vars last and they win over YAML.
*/}}
{{- define "go-service.env" -}}
- name: ENV
  value: {{ .Values.config.env | quote }}
{{- range $k, $v := .Values.config.env_ }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- if .Values.secrets.enabled }}
{{- range $envName, $_ := .Values.secrets.data }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ include "go-service.secretName" $ }}
      key: {{ $envName }}
{{- end }}
{{- end }}
{{- if .Values.database.enabled }}
{{/*
An EXTERNAL database. The address is a fact about the environment and lives in
Git; the credentials are secrets and arrive the same way every other secret
does — through this service's ExternalSecret. Nothing here holds a password,
and rotating one in the backing store needs no commit and no redeploy.
*/}}
- name: DB__HOST
  value: {{ .Values.database.host | quote }}
- name: DB__PORT
  value: {{ .Values.database.port | quote }}
- name: DB__NAME
  value: {{ .Values.database.name | quote }}
- name: DB__SSLMODE
  value: {{ .Values.database.sslmode | quote }}
{{- range $envName, $_ := include "go-service.dbCredentialEnv" . | fromYaml }}
- name: {{ $envName }}
  valueFrom:
    secretKeyRef:
      name: {{ include "go-service.secretName" $ }}
      key: {{ $envName }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
The database credential env vars this service takes from its Secret, as a YAML
map of envVarName -> remote key in the store. One definition, consumed by both
the env block above and the ExternalSecret — so the two can never drift.

Renders empty when the database is off or no credential keys are set.
*/}}
{{- define "go-service.dbCredentialEnv" -}}
{{- if .Values.database.enabled -}}
{{- with .Values.database.credentials.userKey }}DB__USER: {{ . | quote }}
{{ end -}}
{{- with .Values.database.credentials.passwordKey }}DB__PASSWORD: {{ . | quote }}
{{ end -}}
{{- with .Values.database.credentials.dsnKey }}DB_DSN: {{ . | quote }}
{{ end -}}
{{- end -}}
{{- end -}}

{{/*
Guard: database credentials ride this service's ExternalSecret, so asking for
them without enabling secrets would render a workload whose DB__* env vars point
at a Secret nothing creates — pods stuck in CreateContainerConfigError with no
hint why. Fail at template time instead.
*/}}
{{- define "go-service.validate" -}}
{{- $creds := include "go-service.dbCredentialEnv" . | fromYaml -}}
{{- if and (gt (len $creds) 0) (not .Values.secrets.enabled) -}}
{{- fail "database.credentials is set but secrets.enabled is false — database credentials are delivered through this service's ExternalSecret, so it must be on" -}}
{{- end -}}
{{- if and .Values.database.enabled (not .Values.database.host) -}}
{{- fail "database.enabled is true but database.host is empty — the cluster runs no database, so a host is required" -}}
{{- end -}}
{{- end -}}
