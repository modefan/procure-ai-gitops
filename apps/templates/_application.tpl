{{/*
One Argo CD Application.
  dict "root" $ "name" <Application name> "app" <its values block> "sources" <list of sources>
*/}}
{{- define "procure-apps.application" -}}
{{- $root := .root }}
{{- $app := .app }}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .name }}
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: {{ $app.wave | quote }}
    {{- with $app.waveGate }}
    # Read by the Application health check in argocd/values.yaml: Healthy for the wave order once synced (see values.yaml).
    procure-ai/wave-gate: {{ . | quote }}
    {{- end }}
  {{- if .finalizer }}
  # Deleting the Application deletes what it deployed (PVCs of StatefulSets are not Argo's and stay).
  finalizers:
    - resources-finalizer.argocd.argoproj.io
  {{- end }}
  labels:
    app.kubernetes.io/part-of: procure-ai
    app.kubernetes.io/managed-by: procure-apps
spec:
  project: {{ $root.Values.project }}
  destination:
    server: {{ $root.Values.destination.server }}
    namespace: {{ $app.namespace }}
  sources:
    {{- toYaml .sources | nindent 4 }}
  {{- with $root.Values.ignoreDifferences }}
  ignoreDifferences:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  syncPolicy:
    {{- toYaml $root.Values.syncPolicy | nindent 4 }}
{{- end }}

{{/*
The two sources of an Application whose chart lives in the procure-ai repo (plan 07 ruling 4): the chart at appRevision, with the
environment's values file from this repo ($values) and the image tag = appRevision; and this repo as the `values` ref.
  dict "root" $ "app" <values block> "valuesFile" <file name under envs/<env>/>
*/}}
{{- define "procure-apps.appRepoSources" -}}
{{- $root := .root }}
{{- $revision := required "appRevision is required (envs/<env>/release.yaml)" $root.Values.appRevision }}
- repoURL: {{ $root.Values.repos.app }}
  targetRevision: {{ $revision }}
  path: {{ .app.path }}
  helm:
    releaseName: {{ .app.releaseName }}
    valueFiles:
      - $values/envs/{{ $root.Values.env }}/{{ .valuesFile }}
    valuesObject:
      global:
        imageTag: {{ $revision }}
- repoURL: {{ $root.Values.repos.gitops }}
  targetRevision: {{ $root.Values.repos.gitopsRevision }}
  ref: values
{{- end }}
