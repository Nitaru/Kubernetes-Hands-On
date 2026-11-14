{{- define "shop.labels" -}}
app.kubernetes.io/part-of: shop
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "shop.api.selector" -}}
app.kubernetes.io/name: shop-api
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "shop.redis.selector" -}}
app.kubernetes.io/name: shop-redis
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
