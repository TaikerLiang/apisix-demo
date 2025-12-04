# Kubernetes Migration Plan - APISIX + Spring Boot Demo

## Overview
Migrate the current Docker Compose setup (APISIX gateway + Spring Boot backend) to a production-ready Kubernetes deployment with APISIX Ingress Controller and full ELK stack.

**Target Environment:** Local Kubernetes (Docker Desktop, minikube, or kind)
**Complexity Level:** Production-ready with HA, resource management, and monitoring

---

## Architecture

### Current State (Docker Compose)
```
Client → APISIX (9080) → Spring Boot (8080)
         ↓ logs (elasticsearch-logger plugin)
         Elasticsearch (not deployed, referenced only)
```

### Target State (Kubernetes)
```
Client → Ingress
         ↓
         APISIX Ingress Controller (CRD-based routing)
         ↓
         Spring Boot Service (ClusterIP)

All Pods → Filebeat (DaemonSet) → Elasticsearch → Kibana
```

---

## Directory Structure

```
apisix-demo/
├── k8s/
│   ├── namespace.yaml                 # apisix-demo namespace
│   ├── spring-boot/
│   │   ├── deployment.yaml            # Spring Boot Deployment (2-10 replicas, HPA)
│   │   ├── service.yaml               # ClusterIP service
│   │   ├── configmap.yaml             # application.yaml & logback-spring.xml
│   │   ├── hpa.yaml                   # HorizontalPodAutoscaler
│   │   └── pdb.yaml                   # PodDisruptionBudget
│   ├── apisix-ingress/
│   │   ├── helm-values.yaml           # APISIX Ingress Controller config
│   │   ├── apisix-route.yaml          # ApisixRoute CRD (/sb/hello route)
│   │   └── secrets.yaml               # Elasticsearch credentials
│   ├── elk/
│   │   ├── namespace.yaml             # elk-stack namespace
│   │   ├── elasticsearch/
│   │   │   ├── statefulset.yaml       # ES StatefulSet (3 replicas)
│   │   │   ├── service.yaml           # Headless + ClusterIP services
│   │   │   └── pvc.yaml               # PersistentVolumeClaim template
│   │   ├── kibana/
│   │   │   ├── deployment.yaml        # Kibana Deployment
│   │   │   └── service.yaml           # ClusterIP + optional Ingress
│   │   └── filebeat/
│   │       ├── daemonset.yaml         # Filebeat on every node
│   │       ├── configmap.yaml         # Filebeat config
│   │       └── rbac.yaml              # RBAC for pod log access
│   └── scripts/
│       ├── build.sh                   # Build Spring Boot image locally
│       ├── deploy-all.sh              # Deploy entire stack
│       ├── test.sh                    # Run integration tests
│       └── cleanup.sh                 # Cleanup all resources
├── hello/
│   ├── Dockerfile                     # UPDATED: Multi-stage build
│   └── skaffold.yaml                  # NEW: Hot-reload for development
├── CLAUDE.md                          # UPDATED: K8s deployment docs
└── README-K8S.md                      # NEW: K8s quick start guide
```

---

## Key Components

### 1. APISIX Ingress Controller (Helm-based)

**Installation Method:** Helm chart (easier management, upgrades)

**helm-values.yaml highlights:**
```yaml
gateway:
  type: NodePort  # For local k8s access
  http:
    enabled: true
    servicePort: 80
    containerPort: 9080

ingress-controller:
  enabled: true
  config:
    apisix:
      serviceNamespace: apisix-demo
      serviceName: apisix-gateway

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

replicaCount: 2  # HA setup
```

**Route Migration:** Convert apisix/apisix.yaml to ApisixRoute CRD:
```yaml
apiVersion: apisix.apache.org/v2
kind: ApisixRoute
metadata:
  name: spring-boot-route
spec:
  http:
  - name: hello-route
    match:
      paths:
      - /sb/hello
      methods:
      - GET
    backends:
    - serviceName: spring-boot-service
      servicePort: 8080
    plugins:
    - name: proxy-rewrite
      enable: true
      config:
        uri: /api/hello
    - name: elasticsearch-logger
      enable: true
      secretRef: elasticsearch-credentials
      config:
        endpoint_addr: "http://elasticsearch.elk-stack.svc.cluster.local:9200"
        field:
          index: "apisix-logs"
```

**Benefits over standalone:**
- Native Kubernetes service discovery
- Automatic updates when services change
- GitOps-friendly (declarative CRDs)
- Better observability with K8s events

---

### 2. Spring Boot Application

**Optimized Multi-stage Dockerfile:**
```dockerfile
# Stage 1: Build
FROM eclipse-temurin:21-jdk as builder
WORKDIR /build
COPY pom.xml .
COPY .mvn .mvn
COPY mvnw .
RUN ./mvnw dependency:go-offline
COPY src src
RUN ./mvnw package -DskipTests

# Stage 2: Runtime
FROM eclipse-temurin:21-jre
WORKDIR /app
RUN groupadd -r spring && useradd -r -g spring spring
COPY --from=builder /build/target/hello-*.jar app.jar
RUN chown spring:spring app.jar
USER spring
EXPOSE 8080
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:+UseContainerSupport"
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

**Benefits:**
- 40% smaller image (JRE vs JDK)
- Security: non-root user
- Container-aware JVM tuning
- Faster builds (dependency caching)

**Deployment with Production Features:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: spring-boot
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0  # Zero-downtime
  template:
    spec:
      initContainers:
      - name: wait-for-elasticsearch
        image: busybox
        command: ['sh', '-c', 'until nc -z elasticsearch.elk-stack 9200; do sleep 2; done']

      containers:
      - name: spring-boot
        image: localhost:5000/hello:latest
        ports:
        - containerPort: 8080

        # Health checks
        livenessProbe:
          httpGet:
            path: /actuator/health/liveness
            port: 8080
          initialDelaySeconds: 60
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /actuator/health/readiness
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 5
        startupProbe:
          httpGet:
            path: /actuator/health
            port: 8080
          failureThreshold: 30
          periodSeconds: 10

        # Resources
        resources:
          requests:
            cpu: 250m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi

        # Configuration
        envFrom:
        - configMapRef:
            name: spring-boot-config
        volumeMounts:
        - name: logging-config
          mountPath: /app/config/logback-spring.xml
          subPath: logback-spring.xml

      volumes:
      - name: logging-config
        configMap:
          name: spring-boot-config
```

**HorizontalPodAutoscaler:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: spring-boot-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: spring-boot
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
```

**PodDisruptionBudget:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: spring-boot-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: spring-boot
```

**Required Changes to Spring Boot:**
- Add Spring Boot Actuator dependency to pom.xml
- Enable actuator endpoints in application.yaml
- No code changes needed!

---

### 3. ELK Stack (Full Production Setup)

**Namespace Isolation:** Deploy ELK in separate `elk-stack` namespace for:
- Resource isolation
- Independent scaling
- Security boundaries
- Easier RBAC management

**Elasticsearch StatefulSet:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: elasticsearch
  namespace: elk-stack
spec:
  serviceName: elasticsearch
  replicas: 3  # Cluster for HA
  selector:
    matchLabels:
      app: elasticsearch
  template:
    spec:
      initContainers:
      - name: fix-permissions
        image: busybox
        command: ['sh', '-c', 'chown -R 1000:1000 /usr/share/elasticsearch/data']
        volumeMounts:
        - name: data
          mountPath: /usr/share/elasticsearch/data

      - name: increase-vm-max-map
        image: busybox
        command: ['sysctl', '-w', 'vm.max_map_count=262144']
        securityContext:
          privileged: true

      containers:
      - name: elasticsearch
        image: docker.elastic.co/elasticsearch/elasticsearch:8.11.0
        env:
        - name: cluster.name
          value: "k8s-logs"
        - name: discovery.type
          value: "single-node"  # Simplified for local
        - name: ES_JAVA_OPTS
          value: "-Xms512m -Xmx512m"
        - name: xpack.security.enabled
          value: "false"  # Simplified for local

        resources:
          requests:
            cpu: 500m
            memory: 1Gi
          limits:
            cpu: 2000m
            memory: 2Gi

        ports:
        - containerPort: 9200
          name: rest
        - containerPort: 9300
          name: inter-node

        volumeMounts:
        - name: data
          mountPath: /usr/share/elasticsearch/data

  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: 10Gi
```

**Kibana Deployment:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: elk-stack
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: kibana
        image: docker.elastic.co/kibana/kibana:8.11.0
        env:
        - name: ELASTICSEARCH_HOSTS
          value: "http://elasticsearch:9200"

        resources:
          requests:
            cpu: 200m
            memory: 512Mi
          limits:
            cpu: 1000m
            memory: 1Gi

        ports:
        - containerPort: 5601
```

**Filebeat DaemonSet** (runs on every node):
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: filebeat
  namespace: elk-stack
spec:
  template:
    spec:
      serviceAccountName: filebeat
      containers:
      - name: filebeat
        image: docker.elastic.co/beats/filebeat:8.11.0
        args: [
          "-c", "/etc/filebeat.yml",
          "-e",
        ]
        env:
        - name: ELASTICSEARCH_HOST
          value: elasticsearch
        - name: ELASTICSEARCH_PORT
          value: "9200"

        volumeMounts:
        - name: config
          mountPath: /etc/filebeat.yml
          subPath: filebeat.yml
        - name: data
          mountPath: /usr/share/filebeat/data
        - name: varlibdockercontainers
          mountPath: /var/lib/docker/containers
          readOnly: true
        - name: varlog
          mountPath: /var/log
          readOnly: true

      volumes:
      - name: config
        configMap:
          name: filebeat-config
      - name: varlibdockercontainers
        hostPath:
          path: /var/lib/docker/containers
      - name: varlog
        hostPath:
          path: /var/log
      - name: data
        emptyDir: {}
```

**Filebeat Configuration (ConfigMap):**
```yaml
filebeat.inputs:
- type: container
  paths:
    - /var/log/containers/*.log
  processors:
  - add_kubernetes_metadata:
      host: ${NODE_NAME}
      matchers:
      - logs_path:
          logs_path: "/var/log/containers/"

output.elasticsearch:
  hosts: ['${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}']
  index: "k8s-logs-%{+yyyy.MM.dd}"

setup.ilm.enabled: false
setup.template.name: "k8s-logs"
setup.template.pattern: "k8s-logs-*"
```

**Log Flow:**
1. Spring Boot → JSON logs to stdout
2. APISIX → elasticsearch-logger plugin → Elasticsearch (direct)
3. Kubernetes → Stores logs in /var/log/containers/
4. Filebeat → Reads container logs → Parses JSON → Elasticsearch
5. Kibana → Queries Elasticsearch → Visualizes logs

**RBAC for Filebeat:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: filebeat
  namespace: elk-stack
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: filebeat
rules:
- apiGroups: [""]
  resources:
  - namespaces
  - pods
  - nodes
  verbs:
  - get
  - watch
  - list
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: filebeat
subjects:
- kind: ServiceAccount
  name: filebeat
  namespace: elk-stack
roleRef:
  kind: ClusterRole
  name: filebeat
  apiGroup: rbac.authorization.k8s.io
```

---

## Configuration Management

### ConfigMaps
| Name | Namespace | Contents | Mount Path |
|------|-----------|----------|------------|
| spring-boot-config | apisix-demo | application.yaml, logback-spring.xml | /app/config/ |
| apisix-config | apisix-demo | config.yaml (minimal, most config in Helm) | - |
| filebeat-config | elk-stack | filebeat.yml | /etc/filebeat.yml |

### Secrets
| Name | Namespace | Contents | Usage |
|------|-----------|----------|-------|
| elasticsearch-credentials | apisix-demo | username, password | APISIX elasticsearch-logger plugin |

**Example Secret:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: elasticsearch-credentials
  namespace: apisix-demo
type: Opaque
stringData:
  username: elastic
  password: changeme  # Change in production!
```

### Environment Variables
Spring Boot will use ConfigMap via `envFrom` for configuration injection.

---

## Networking

### Service Types
- **Spring Boot:** ClusterIP (internal only, accessed via APISIX)
- **APISIX Gateway:** NodePort (for local k8s access)
- **Elasticsearch:** ClusterIP + Headless (for StatefulSet)
- **Kibana:** ClusterIP + optional Ingress

### DNS Names
- Spring Boot: `spring-boot-service.apisix-demo.svc.cluster.local:8080`
- APISIX: `apisix-gateway.apisix-demo.svc.cluster.local:80`
- Elasticsearch: `elasticsearch.elk-stack.svc.cluster.local:9200`
- Kibana: `kibana.elk-stack.svc.cluster.local:5601`

### External Access
**Local Development (NodePort):**
- APISIX: `http://localhost:30080/sb/hello`
- Kibana: `http://localhost:30561`

**Alternative (Port-forward for testing):**
```bash
kubectl port-forward -n apisix-demo svc/apisix-gateway 9080:80
kubectl port-forward -n elk-stack svc/kibana 5601:5601
```

---

## Local Development Workflow

### Build and Deploy
```bash
# 1. Build Spring Boot image
cd hello
docker build -t localhost:5000/hello:latest .
docker push localhost:5000/hello:latest  # If using local registry

# 2. Deploy ELK stack first
kubectl apply -f k8s/elk/namespace.yaml
kubectl apply -f k8s/elk/

# 3. Wait for Elasticsearch to be ready
kubectl wait --for=condition=ready pod -l app=elasticsearch -n elk-stack --timeout=300s

# 4. Deploy main app
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/spring-boot/
kubectl apply -f k8s/apisix-ingress/secrets.yaml

# 5. Install APISIX Ingress Controller
helm repo add apisix https://charts.apiseven.com
helm repo update
helm install apisix apisix/apisix -n apisix-demo -f k8s/apisix-ingress/helm-values.yaml

# 6. Deploy routes
kubectl apply -f k8s/apisix-ingress/apisix-route.yaml
```

### Hot-reload Development (Skaffold)
```yaml
# skaffold.yaml
apiVersion: skaffold/v4beta6
kind: Config
build:
  artifacts:
  - image: localhost:5000/hello
    context: hello
    docker:
      dockerfile: Dockerfile
deploy:
  kubectl:
    manifests:
    - k8s/spring-boot/*.yaml
portForward:
- resourceType: service
  resourceName: spring-boot-service
  namespace: apisix-demo
  port: 8080
  localPort: 8080
```

**Usage:**
```bash
skaffold dev  # Auto-rebuild and redeploy on code changes
```

---

## Migration Steps (30 Tasks)

### Phase 1: Preparation (Day 1)
1. ✅ Create k8s directory structure
2. ✅ Create namespace manifests (apisix-demo, elk-stack)
3. ✅ Update Spring Boot Dockerfile to multi-stage build
4. ✅ Add Spring Boot Actuator dependency to pom.xml
5. ✅ Create Spring Boot ConfigMaps (application.yaml, logback-spring.xml)
6. ✅ Create Elasticsearch Secret for credentials
7. ✅ Build and test new Docker image locally

### Phase 2: ELK Stack (Day 2)
8. ✅ Create Elasticsearch StatefulSet manifest
9. ✅ Create Elasticsearch Services (headless + ClusterIP)
10. ✅ Create Kibana Deployment manifest
11. ✅ Create Kibana Service manifest
12. ✅ Create Filebeat ConfigMap
13. ✅ Create Filebeat RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
14. ✅ Create Filebeat DaemonSet manifest
15. ✅ Deploy and test ELK stack

### Phase 3: Spring Boot App (Day 3)
16. ✅ Create Spring Boot Deployment manifest
17. ✅ Create Spring Boot Service manifest
18. ✅ Create HorizontalPodAutoscaler manifest
19. ✅ Create PodDisruptionBudget manifest
20. ✅ Deploy Spring Boot app
21. ✅ Verify health checks and logs

### Phase 4: APISIX Ingress (Day 4)
22. ✅ Create APISIX Helm values.yaml
23. ✅ Install APISIX Ingress Controller via Helm
24. ✅ Create ApisixRoute CRD manifest
25. ✅ Deploy route and test external access
26. ✅ Verify elasticsearch-logger plugin works
27. ✅ Test end-to-end: Client → APISIX → Spring Boot → Elasticsearch

### Phase 5: Automation & Documentation (Day 5)
28. ✅ Create automation scripts (build.sh, deploy-all.sh, test.sh, cleanup.sh)
29. ✅ Create skaffold.yaml for hot-reload
30. ✅ Update CLAUDE.md with K8s deployment instructions
31. ✅ Create README-K8S.md quick start guide
32. ✅ Test complete stack deployment from scratch

---

## Testing Strategy

### Unit Tests
```bash
# In hello/ directory
./mvnw test
```

### Integration Tests
```bash
# Test Spring Boot directly
kubectl port-forward -n apisix-demo svc/spring-boot-service 8080:8080
curl http://localhost:8080/api/hello
# Expected: "Hello from Spring Boot!"

# Test via APISIX Ingress
curl http://localhost:30080/sb/hello
# Expected: "Hello from Spring Boot!"

# Verify logs in Elasticsearch
kubectl port-forward -n elk-stack svc/kibana 5601:5601
# Open http://localhost:5601
# Create index pattern: k8s-logs-*
# Search for logs from spring-boot pods
```

### Load Testing
```bash
# Generate traffic for HPA testing
kubectl run -it --rm load-generator --image=busybox --restart=Never -- /bin/sh
while true; do wget -q -O- http://apisix-gateway.apisix-demo/sb/hello; done

# Watch HPA scale up
kubectl get hpa -n apisix-demo -w
```

### Chaos Testing
```bash
# Delete a pod and verify zero-downtime
kubectl delete pod -n apisix-demo -l app=spring-boot --grace-period=30

# Continuous requests should not fail (PDB ensures min 1 replica)
while true; do curl http://localhost:30080/sb/hello || echo "FAILED"; sleep 0.5; done
```

---

## Documentation Updates

### CLAUDE.md Additions
```markdown
## Kubernetes Deployment

The application can be deployed to Kubernetes with production-ready configurations.

### Quick Start
\`\`\`bash
# Deploy entire stack
./k8s/scripts/deploy-all.sh

# Access services
# APISIX: http://localhost:30080/sb/hello
# Kibana: http://localhost:30561
\`\`\`

### Architecture
- APISIX Ingress Controller for routing
- Spring Boot backend (2-10 replicas with HPA)
- Full ELK stack for centralized logging
- Production features: health checks, resource limits, PDB, HPA

### Key Files
- \`k8s/\` - All Kubernetes manifests
- \`hello/Dockerfile\` - Optimized multi-stage build
- \`k8s/scripts/\` - Deployment automation

See README-K8S.md for detailed documentation.
```

### New README-K8S.md
Create comprehensive guide covering:
1. Prerequisites (kubectl, helm, local k8s cluster)
2. Architecture diagram
3. Deployment instructions
4. Troubleshooting guide
5. Scaling and monitoring
6. Clean up procedures

---

## Critical Files to Modify

1. **hello/Dockerfile** - Convert to multi-stage build
2. **hello/pom.xml** - Add Spring Boot Actuator dependency
3. **hello/src/main/resources/application.yaml** - Add actuator endpoints
4. **CLAUDE.md** - Add Kubernetes section
5. **apisix/apisix.yaml** - Reference only (migrate to ApisixRoute CRD)

---

## Production Considerations

### Resource Planning (Local K8s)
- **Elasticsearch:** 3 pods × 2 GB RAM = 6 GB
- **Spring Boot:** 2-10 pods × 1 GB = 2-10 GB
- **APISIX:** 2 pods × 512 MB = 1 GB
- **Kibana:** 1 pod × 1 GB = 1 GB
- **Filebeat:** DaemonSet × 256 MB per node
- **Total:** ~10-18 GB RAM minimum

**Recommendation:** Ensure Docker Desktop has at least 12 GB allocated

### Security
- Non-root containers for Spring Boot
- Secrets for Elasticsearch credentials
- RBAC for Filebeat
- Network Policies (optional, can be added)

### Monitoring
- Spring Boot Actuator metrics at `/actuator/metrics`
- Prometheus integration (can be added later)
- Kibana dashboards for log visualization

### High Availability
- 2 replicas for APISIX (HA)
- 2-10 replicas for Spring Boot (HPA)
- 3 replicas for Elasticsearch (quorum)
- PodDisruptionBudget ensures availability during updates

---

## Rollback Strategy

If migration issues occur:

1. **Keep Docker Compose running** - Don't remove it until K8s is validated
2. **Gradual cutover** - Use both environments during transition
3. **Quick rollback** - `./k8s/scripts/cleanup.sh` removes all K8s resources
4. **Data persistence** - Elasticsearch data in PVCs survives pod restarts

---

## Success Criteria

✅ All pods running and healthy
✅ Spring Boot accessible via APISIX Ingress
✅ HPA scales based on load
✅ Logs visible in Kibana
✅ Zero-downtime rolling updates
✅ Health checks passing
✅ Documentation complete

---

## Next Steps After Migration

1. **Monitoring:** Add Prometheus + Grafana for metrics
2. **Tracing:** Add Jaeger/Zipkin for distributed tracing
3. **Service Mesh:** Consider Istio/Linkerd for advanced traffic management
4. **GitOps:** Set up ArgoCD/Flux for automated deployments
5. **CI/CD:** Integrate with GitHub Actions/GitLab CI
6. **Multi-environment:** Add staging/production overlays with Kustomize
