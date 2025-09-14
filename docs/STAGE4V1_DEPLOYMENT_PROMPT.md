# Stage4-v1 EKS Deployment Prompt

## 🎯 Deployment Objective

Deploy a complete AWS EKS Fargate serverless infrastructure for **Stage4-v1** with the following specifications:

### **Target Domain**: `https://stage4-v1.a-g-e-n-t-i-c.com`

### **Critical Success Criteria**:
1. ✅ All 6 endpoints functional
2. ✅ Database connectivity: `database_connected: true`
3. ✅ SSL certificate valid and trusted
4. ✅ EKS cluster with Fargate-only compute
5. ✅ AWS Load Balancer Controller operational
6. ✅ Kubernetes pods running and healthy

## 🏗️ Architecture Requirements

### **Infrastructure Components**:
- **VPC**: 10.4.0.0/16 with 6 subnets (public, private, database)
- **EKS Cluster**: Fargate serverless compute only
- **Fargate Profiles**: For private subnet pod scheduling
- **RDS PostgreSQL**: Primary + read replica with managed secrets
- **ECR**: Container repositories for FastAPI + Node.js
- **ALB**: Public Application Load Balancer with SSL
- **Route53**: DNS record for stage4-v1 subdomain
- **Security Groups**: Proper network segmentation

### **Kubernetes Components**:
- **AWS Load Balancer Controller**: Manage ALBs via Ingress
- **Deployments**: FastAPI and Node.js applications
- **Services**: ClusterIP for internal, LoadBalancer for external
- **Ingress**: ALB integration with SSL termination
- **ConfigMaps**: Environment variables
- **Secrets**: Database credentials from AWS Secrets Manager
- **ServiceAccounts**: RBAC configuration

## 📋 Deployment Steps

### **Phase 1: Early SSL Certificate Request**
- Request SSL certificate for `stage4-v1.a-g-e-n-t-i-c.com` immediately
- Create DNS validation record
- Allow DNS propagation during infrastructure build

### **Phase 2: Network Infrastructure**
- Deploy VPC with CIDR 10.4.0.0/16
- Create 6 subnets across 2 AZs
- Configure NAT Gateway and route tables
- Set up security groups

### **Phase 3: Database Infrastructure**
- Deploy PostgreSQL RDS with managed secrets
- Create read replica
- Configure security group access

### **Phase 4: Container Infrastructure**
- Create ECR repositories
- Build and push Docker images
- Ensure images are ready for Kubernetes deployment

### **Phase 5: EKS Cluster**
- Create EKS cluster with Fargate-only compute
- Configure Fargate profiles for private subnets
- Install AWS Load Balancer Controller
- Set up RBAC and service accounts

### **Phase 6: Kubernetes Applications**
- Deploy ConfigMaps and Secrets
- Deploy FastAPI and Node.js applications
- Create Services and Ingress
- Configure health checks and probes

### **Phase 7: DNS and SSL Integration**
- Configure Route53 A record
- Verify SSL certificate attachment to ALB
- Test HTTPS connectivity

### **Phase 8: Comprehensive Testing**
- Test all 6 endpoints systematically
- Verify database connectivity returns `true`
- Validate pod health and scaling
- Confirm end-to-end functionality

## 🔧 Key Configuration Parameters

```bash
# Core Infrastructure
project-name: agentic-aws-stage4-v1
environment: stage4-v1
vpc-cidr: 10.4.0.0/16
availability-zones: ["us-east-1a", "us-east-1b"]

# Domain Configuration
domain-name: a-g-e-n-t-i-c.com
subdomain: stage4-v1

# Database Configuration
db-instance-class: db.t3.micro
db-allocated-storage: 20
db-name: stage4v1db
db-backup-retention: 7

# EKS Configuration
eks-version: "1.28"
fargate-only: true
private-subnets: true

# Application Configuration
fastapi-cpu: "256m"
fastapi-memory: "512Mi"
nodejs-cpu: "256m"
nodejs-memory: "512Mi"
replica-count: 2

# Monitoring
log-retention-days: 30
```

## 🚨 Critical Pre-corrections Applied

Based on Stage3-v4 learnings, the following issues are pre-corrected:

1. **SSL Certificate**: Early request to allow DNS propagation
2. **CIDR Conflicts**: Dynamic CIDR allocation (10.4.x.x)
3. **Resource Naming**: Length-optimized for AWS limits
4. **Secret Parsing**: Proper RDS managed secret structure
5. **Docker Daemon**: Health checks and recovery
6. **Network Routing**: Pre-configured NAT Gateway routing
7. **IAM Permissions**: EKS-specific service accounts and RBAC
8. **Load Balancer Controller**: Proper installation and configuration

## ⚡ EKS-Specific Considerations

### **Fargate Profiles**:
- Configure for private subnets only
- Proper selectors for application namespaces
- Security group and execution role configuration

### **AWS Load Balancer Controller**:
- Install via Helm or manifest
- Configure service account with proper IAM permissions
- Enable target type IP mode for Fargate

### **Kubernetes Manifests**:
- Use standard resources compatible with future "kind" migration
- Avoid AWS-specific annotations where possible
- Implement proper resource limits and requests

## 🔍 Testing Requirements

### **Mandatory Endpoint Tests**:
```bash
# All must return HTTP 200
curl https://stage4-v1.a-g-e-n-t-i-c.com/health
curl https://stage4-v1.a-g-e-n-t-i-c.com/api/status
curl https://stage4-v1.a-g-e-n-t-i-c.com/api/db-test
curl https://stage4-v1.a-g-e-n-t-i-c.com/api/fastapi
curl https://stage4-v1.a-g-e-n-t-i-c.com/api/config
curl https://stage4-v1.a-g-e-n-t-i-c.com/api/environment
```

### **Kubernetes Health Checks**:
```bash
# All pods must be Running
kubectl get pods
kubectl get services
kubectl get ingress
kubectl describe ingress agentic-ingress
```

### **Database Connectivity**:
```bash
# Must return: "database_connected": true
curl -s https://stage4-v1.a-g-e-n-t-i-c.com/api/status | jq '.backend.database_connected'
```

## 🎯 Success Metrics

**Deployment is NOT complete until**:
- ✅ EKS cluster status: ACTIVE
- ✅ Fargate profiles status: ACTIVE
- ✅ All pods status: Running
- ✅ Ingress status: LoadBalancer ready
- ✅ All 6 endpoints return HTTP 200
- ✅ Database connected: true
- ✅ SSL certificate valid
- ✅ DNS resolution working

**Estimated deployment time**: 10-15 minutes

**Never terminate early** - continue until all success metrics are met!