# EKS Migration Guide: Stage3-v4 (ECS) → Stage4-v1 (EKS)

## 🔄 Migration Overview

This document outlines the architectural migration from **ECS Fargate** (Stage3-v4) to **EKS Fargate** (Stage4-v1).

## 📊 Component Mapping

### **Removed from ECS Architecture**:
- ❌ ECS Cluster
- ❌ ECS Services
- ❌ ECS Task Definitions
- ❌ ECS Auto-Scaling Targets and Policies
- ❌ Direct ALB Target Groups for containers

### **Added for EKS Architecture**:
- ✅ EKS Cluster with Fargate compute
- ✅ Fargate Profiles for pod scheduling
- ✅ AWS Load Balancer Controller (replaces manual ALB management)
- ✅ Kubernetes Deployments (replace ECS Services)
- ✅ Kubernetes Services (replace Target Groups)
- ✅ Kubernetes Ingress (manages ALB automatically)
- ✅ ConfigMaps and Secrets (replace environment variables)
- ✅ ServiceAccounts and RBAC

### **Retained from ECS Architecture**:
- ✅ VPC and networking (same design, different CIDR)
- ✅ RDS PostgreSQL with managed secrets
- ✅ ECR container repositories
- ✅ SSL certificate and Route53 DNS
- ✅ Same application containers (FastAPI + Node.js)
- ✅ Security group network segmentation

## 🏗️ Architectural Comparison

### **Stage3-v4 (ECS) Flow**:
```
Internet → Public ALB → ECS Service (Node.js) → Internal ALB → ECS Service (FastAPI) → RDS
```

### **Stage4-v1 (EKS) Flow**:
```
Internet → AWS LB Controller → Ingress → K8s Service → Pod (Node.js) → K8s Service → Pod (FastAPI) → RDS
```

## 🔧 Technical Implementation Changes

### **Container Orchestration**:

**ECS (Stage3-v4)**:
```json
{
  "taskDefinition": {
    "family": "fastapi-task",
    "containerDefinitions": [{
      "name": "fastapi",
      "image": "ecr-uri:latest",
      "portMappings": [{"containerPort": 8000}],
      "environment": [...],
      "secrets": [...]
    }]
  }
}
```

**EKS (Stage4-v1)**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fastapi
  template:
    spec:
      containers:
      - name: fastapi
        image: ecr-uri:latest
        ports:
        - containerPort: 8000
        envFrom:
        - configMapRef:
            name: fastapi-config
        - secretRef:
            name: database-secret
```

### **Load Balancing**:

**ECS (Stage3-v4)**:
- Manual ALB creation in Pulumi
- Direct target group management
- Manual listener rules

**EKS (Stage4-v1)**:
- AWS Load Balancer Controller manages ALBs
- Kubernetes Ingress declarative configuration
- Automatic target group creation and management

### **Service Discovery**:

**ECS (Stage3-v4)**:
- Service discovery via internal ALB DNS
- Environment variables for service endpoints

**EKS (Stage4-v1)**:
- Kubernetes native service discovery
- DNS-based service resolution (service.namespace.svc.cluster.local)

### **Configuration Management**:

**ECS (Stage3-v4)**:
```typescript
environment: [
  { name: "DATABASE_HOST", value: dbInstance.endpoint },
  { name: "FASTAPI_URL", value: internalAlb.dnsName }
]
```

**EKS (Stage4-v1)**:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DATABASE_HOST: "rds-endpoint"
  FASTAPI_URL: "http://fastapi-service"
```

## 🔐 Security Considerations

### **Network Security**:
- **Same VPC design** with proper subnet segmentation
- **Pod Security Contexts** replace container-level security
- **Network Policies** (optional) for additional pod-to-pod restrictions
- **RBAC** for Kubernetes API access control

### **Secrets Management**:
- **AWS Secrets Manager** integration remains the same
- **Kubernetes Secrets** created from AWS Secrets Manager
- **ServiceAccounts** with IAM roles for AWS resource access

### **Pod Security**:
```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 2000
  capabilities:
    drop:
    - ALL
```

## 🚀 Deployment Process Changes

### **ECS Deployment (Stage3-v4)**:
1. Deploy infrastructure with Pulumi
2. Build and push Docker images
3. Update ECS services manually or via CLI
4. Wait for service stabilization

### **EKS Deployment (Stage4-v1)**:
1. Deploy infrastructure with Pulumi (including EKS cluster)
2. Install AWS Load Balancer Controller
3. Build and push Docker images
4. Apply Kubernetes manifests
5. Verify pod and ingress status

## 🔍 Monitoring and Observability

### **Logging**:
- **ECS**: CloudWatch logs via awslogs driver
- **EKS**: CloudWatch logs via AWS for FluentBit or similar

### **Metrics**:
- **ECS**: Container Insights for ECS
- **EKS**: Container Insights for EKS + Kubernetes metrics

### **Health Checks**:
- **ECS**: ALB health checks + container health checks
- **EKS**: Kubernetes liveness/readiness probes + ingress health checks

## 🔮 Future Migration Benefits

### **On-Premises Readiness**:
The EKS implementation prepares for future migration to on-premises "kind" clusters:

- **Standard Kubernetes manifests** (no EKS-specific dependencies in app layer)
- **Portable ingress configuration** (can switch from ALB to nginx-ingress)
- **Service mesh ready** (Istio, Linkerd compatibility)
- **GitOps ready** (ArgoCD, Flux compatibility)

### **Scaling and Management**:
- **Horizontal Pod Autoscaler (HPA)** replaces ECS auto-scaling
- **Vertical Pod Autoscaler (VPA)** for resource optimization
- **Cluster Autoscaler** (though not needed with Fargate)
- **Pod Disruption Budgets** for controlled updates

## 🎯 Migration Validation

### **Functional Equivalence Check**:
Both architectures must provide:
- ✅ Same 6 API endpoints
- ✅ Same database connectivity
- ✅ Same SSL/TLS termination
- ✅ Same response times and availability
- ✅ Same security posture

### **EKS-Specific Validation**:
```bash
# Cluster health
kubectl cluster-info
kubectl get nodes

# Pod health
kubectl get pods
kubectl describe pod <pod-name>

# Service connectivity
kubectl get services
kubectl get ingress

# AWS Load Balancer Controller
kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

## 📈 Performance Comparison

| Metric | ECS (Stage3-v4) | EKS (Stage4-v1) | Notes |
|--------|-----------------|-----------------|--------|
| Cold Start | ~2-3 min | ~5-7 min | EKS cluster initialization |
| Response Time | <200ms | <200ms | Same application performance |
| Scaling | ECS Auto-scaling | HPA | Similar capabilities |
| Resource Usage | Task-level | Pod-level | Slightly higher K8s overhead |

## 🛠️ Troubleshooting Guide

### **Common EKS Issues**:
1. **Fargate profile misconfiguration**
   - Check subnet and namespace selectors
   - Verify execution role permissions

2. **AWS Load Balancer Controller issues**
   - Check service account annotations
   - Verify IAM role permissions
   - Check ingress annotations

3. **Pod networking issues**
   - Verify security group configurations
   - Check VPC CNI plugin status

4. **DNS resolution problems**
   - Check CoreDNS pod status
   - Verify service endpoints

This migration maintains functional equivalence while providing better Kubernetes-native orchestration and future portability.