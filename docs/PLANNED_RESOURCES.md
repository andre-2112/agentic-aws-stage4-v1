# Stage4-v1 Planned AWS Resources

## 📋 Complete Resource Inventory

### **🌐 VPC & Networking (16 resources)**
- **VPC**: `agentic-aws-stage4-v1-vpc` (10.4.0.0/16)
- **Subnets (6)**:
  - Public: `10.4.1.0/24`, `10.4.2.0/24` (us-east-1a, us-east-1b)
  - Private: `10.4.3.0/24`, `10.4.4.0/24` (us-east-1a, us-east-1b)
  - Database: `10.4.5.0/24`, `10.4.6.0/24` (us-east-1a, us-east-1b)
- **Internet Gateway**: `agentic-aws-stage4-v1-igw`
- **NAT Gateway**: `agentic-aws-stage4-v1-nat` + Elastic IP
- **Route Tables (3)**:
  - Public RT: `agentic-aws-stage4-v1-public-rt`
  - Private RT: `agentic-aws-stage4-v1-private-rt` (with NAT route)
  - Database RT: `agentic-aws-stage4-v1-db-rt`
- **Route Table Associations (6)**: Each subnet associated with appropriate RT

### **🔒 Security Groups (4 resources)**
- **Public ALB SG**: `ag-s4v1-pub-alb-sg` (80/443 inbound from 0.0.0.0/0)
- **EKS Node SG**: `ag-s4v1-eks-node-sg` (container ports from ALB)
- **Database SG**: `ag-s4v1-db-sg` (5432 from EKS nodes only)
- **EKS Cluster SG**: `ag-s4v1-eks-cluster-sg` (K8s API access)

### **🐳 Container Repositories (2 resources)**
- **FastAPI ECR**: `agentic-aws-stage4-v1-fastapi`
- **Node.js ECR**: `agentic-aws-stage4-v1-nodejs`

### **☸️ EKS Infrastructure (8 resources)**
- **EKS Cluster**: `agentic-aws-stage4-v1-cluster`
  - Version: 1.28
  - Compute: Fargate-only (no EC2 nodes)
  - VPC Config: Private subnets + public endpoint
- **Fargate Profile**: `ag-s4v1-fargate-profile`
  - Selectors: default namespace
  - Subnets: Private subnets only
  - Execution Role: Fargate execution permissions
- **EKS Service Role**: IAM role for cluster operations
- **Fargate Execution Role**: IAM role for pod execution
- **Node Group IAM Role**: For future EC2 compatibility (optional)
- **OIDC Identity Provider**: For service account IAM integration
- **AWS Load Balancer Controller**: Deployed via Helm/manifest
- **VPC CNI Plugin**: (default, managed by AWS)

### **🗄️ Database Infrastructure (4 resources)**
- **RDS Primary**: `ag-s4v1-primary` (PostgreSQL 15.13, db.t3.micro)
- **RDS Read Replica**: `ag-s4v1-replica`
- **DB Subnet Group**: `ag-s4v1-db-subnet-group`
- **DB Parameter Group**: `ag-s4v1-db-parameter-group`

### **🔐 Secrets Management (1 resource)**
- **Database Secret**: `agentic-aws/stage4-v1/database/master`
  - Managed by RDS (username/password only)
  - Integrated with Kubernetes secrets

### **⚖️ Load Balancing (3 resources)**
- **Public ALB**: `ag-s4v1-pub-alb` (managed by AWS Load Balancer Controller)
- **Target Groups**: Auto-created by Ingress controller
- **Listeners**: Auto-configured (HTTP redirect + HTTPS)

### **🌍 DNS & SSL (2 resources)**
- **SSL Certificate**: `stage4-v1.a-g-e-n-t-i-c.com` (ACM with DNS validation)
- **Route53 A Record**: Points to ALB (managed by external-dns or manual)

### **📊 Monitoring & Logging (3 resources)**
- **CloudWatch Log Group**: `/aws/eks/agentic-aws-stage4-v1-cluster/cluster`
- **EKS Container Insights**: Enabled for cluster monitoring
- **VPC Flow Logs**: Optional for network debugging

## ☸️ Kubernetes Resources (Deployed after infrastructure)

### **📦 Application Workloads**
```yaml
# FastAPI Deployment
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
      serviceAccountName: fastapi-service-account
      containers:
      - name: fastapi
        image: {ECR-URI}/fastapi:latest
        ports:
        - containerPort: 8000
        resources:
          requests:
            memory: "256Mi"
            cpu: "256m"
          limits:
            memory: "512Mi"
            cpu: "512m"
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5

---
# Node.js Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-deployment
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nodejs
  template:
    spec:
      serviceAccountName: nodejs-service-account
      containers:
      - name: nodejs
        image: {ECR-URI}/nodejs:latest
        ports:
        - containerPort: 3000
        env:
        - name: FASTAPI_URL
          value: "http://fastapi-service:8000"
        resources:
          requests:
            memory: "256Mi"
            cpu: "256m"
          limits:
            memory: "512Mi"
            cpu: "512m"
```

### **🔗 Service Discovery**
```yaml
# FastAPI Service
apiVersion: v1
kind: Service
metadata:
  name: fastapi-service
spec:
  selector:
    app: fastapi
  ports:
  - port: 8000
    targetPort: 8000
  type: ClusterIP

---
# Node.js Service
apiVersion: v1
kind: Service
metadata:
  name: nodejs-service
spec:
  selector:
    app: nodejs
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
```

### **🚪 Ingress Configuration**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentic-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/certificate-arn: {SSL-CERT-ARN}
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
  - host: stage4-v1.a-g-e-n-t-i-c.com
    http:
      paths:
      - path: /api/fastapi
        pathType: Prefix
        backend:
          service:
            name: fastapi-service
            port:
              number: 8000
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nodejs-service
            port:
              number: 3000
```

### **⚙️ Configuration Management**
```yaml
# ConfigMap for shared configuration
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DATABASE_HOST: "{RDS-ENDPOINT}"
  DATABASE_NAME: "stage4v1db"
  DATABASE_PORT: "5432"
  ENVIRONMENT: "stage4-v1"
  LOG_LEVEL: "INFO"

---
# Secret for database credentials (from AWS Secrets Manager)
apiVersion: v1
kind: Secret
metadata:
  name: database-secret
type: Opaque
data:
  DATABASE_URL: "{BASE64-ENCODED-SECRETS-MANAGER-JSON}"
```

### **🔐 RBAC Configuration**
```yaml
# Service Account for FastAPI
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fastapi-service-account
  annotations:
    eks.amazonaws.com/role-arn: {FASTAPI-IAM-ROLE-ARN}

---
# Service Account for Node.js
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nodejs-service-account
  annotations:
    eks.amazonaws.com/role-arn: {NODEJS-IAM-ROLE-ARN}
```

## 📊 Resource Summary

| Category | Count | AWS Cost Impact |
|----------|-------|-----------------|
| **Networking** | 16 | ~$45/month (NAT Gateway) |
| **EKS Cluster** | 1 | ~$72/month (control plane) |
| **Fargate Pods** | 4 | ~$40-80/month (dynamic) |
| **RDS Database** | 2 | ~$85/month (primary + replica) |
| **Load Balancer** | 1 | ~$22/month (ALB) |
| **ECR** | 2 | ~$2/month (storage) |
| **Secrets Manager** | 1 | ~$0.40/month |
| **SSL Certificate** | 1 | Free |
| **Route53** | 1 | ~$0.50/month |
| **CloudWatch** | 3 | ~$20/month |
| **Total** | ~31 | **~$287-352/month** |

## 🎯 Key Design Decisions

### **EKS-Specific Choices**:
1. **Fargate-only compute**: No EC2 node groups for serverless experience
2. **Private subnet pods**: Enhanced security, ALB handles public traffic
3. **AWS Load Balancer Controller**: Native K8s to ALB integration
4. **IRSA (IAM Roles for Service Accounts)**: Secure AWS resource access
5. **Container Insights**: Native EKS monitoring

### **Future Portability**:
1. **Standard Kubernetes manifests**: Compatible with on-premises "kind"
2. **Minimal AWS-specific annotations**: Only in Ingress controller
3. **Service-to-service communication**: Using Kubernetes DNS
4. **ConfigMap/Secret patterns**: Standard across all K8s distributions

### **Security Enhancements**:
1. **Pod security contexts**: Non-root containers with dropped capabilities
2. **Resource limits**: Prevent resource exhaustion
3. **Network policies**: Optional pod-to-pod traffic control
4. **RBAC**: Principle of least privilege

This architecture provides identical functionality to Stage3-v4 while enabling future Kubernetes portability and cloud-native scaling patterns.