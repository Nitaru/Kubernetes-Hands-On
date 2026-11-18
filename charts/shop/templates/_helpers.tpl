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

{{/* The pod template shared by the Deployment and the Rollout. */}}
{{- define "shop.api.podTemplate" -}}
metadata:
  labels: {{- include "shop.api.selector" . | nindent 4 }}
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "{{ .Values.api.port }}"
spec:
  serviceAccountName: shop
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 30
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000      # the "node" user in the image; numeric so the kubelet can verify it
    runAsGroup: 1000
    seccompProfile: { type: RuntimeDefault }
  # Spread replicas over nodes so one node failure does not take the service down.
  topologySpreadConstraints:
    - maxSkew: 1
      topologyKey: kubernetes.io/hostname
      whenUnsatisfiable: ScheduleAnyway
      labelSelector:
        matchLabels: {{- include "shop.api.selector" . | nindent 10 }}
  containers:
    - name: api
      image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - { name: http, containerPort: {{ .Values.api.port }} }
      env:
        - { name: PORT, value: "{{ .Values.api.port }}" }
        - { name: PAYMENT_FAILURE_RATE, value: {{ .Values.api.paymentFailureRate | quote }} }
        - name: REDIS_PASSWORD
          valueFrom: { secretKeyRef: { name: shop-redis, key: password } }
        - name: REDIS_URL        # $(VAR) is expanded by Kubernetes from the env entry above
          value: "redis://:$(REDIS_PASSWORD)@shop-redis:6379"
      # Startup absorbs a slow boot; liveness only restarts a hung process; readiness gates traffic.
      startupProbe:
        httpGet: { path: /health, port: http }
        periodSeconds: 2
        failureThreshold: 30
      readinessProbe:
        httpGet: { path: /ready, port: http }
        periodSeconds: 5
        failureThreshold: 2
      livenessProbe:
        httpGet: { path: /health, port: http }
        periodSeconds: 10
        failureThreshold: 3
      lifecycle:
        # Give the endpoints controller time to remove the pod from the Service before SIGTERM.
        preStop:
          exec: { command: ["sleep", "5"] }
      resources: {{- toYaml .Values.api.resources | nindent 8 }}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
      volumeMounts:
        - { name: tmp, mountPath: /tmp }
  volumes:
    - name: tmp
      emptyDir: {}
{{- end }}
