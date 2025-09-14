# Kubernetes Manifests for Stage4-v1

This directory contains the Kubernetes manifests for deploying the Stage4-v1 applications on EKS.

## Structure

```
kubernetes/
├── manifests/
│   ├── fastapi-deployment.yaml       # FastAPI backend deployment and service
│   ├── nodejs-deployment.yaml        # Node.js frontend deployment and service
│   ├── ingress.yaml                  # ALB Ingress configuration
│   └── aws-load-balancer-controller.yaml # Load Balancer Controller RBAC
└── helm/                             # Future Helm charts (if needed)
```

## Deployment Order

The manifests are applied in the following order by the deployment script:

1. **Database Secret**: Created from AWS Secrets Manager
2. **AWS Load Balancer Controller**: Installed via Helm
3. **FastAPI Deployment & Service**: Backend application
4. **Node.js Deployment & Service**: Frontend application
5. **Ingress**: ALB configuration for external access

## Key Features

### Security
- **Non-root containers**: All containers run as user 1000
- **Dropped capabilities**: All Linux capabilities dropped
- **Resource limits**: CPU and memory limits enforced
- **Security contexts**: Privilege escalation disabled

### Health Checks
- **Liveness probes**: Detect unresponsive containers
- **Readiness probes**: Control traffic routing to healthy pods
- **Proper timeouts**: Configured for Fargate startup times

### Networking
- **Service discovery**: Internal communication via Kubernetes DNS
- **Load balancing**: Automatic via Kubernetes Services
- **External access**: AWS ALB via Ingress Controller

### Observability
- **Labels**: Consistent labeling for monitoring and selection
- **Resource requests/limits**: Enable proper resource management
- **Health endpoints**: Both apps expose `/health` endpoints

## Variable Substitution

During deployment, the following variables are replaced:
- `${FASTAPI_ECR_URI}` → Actual ECR repository URL for FastAPI
- `${NODEJS_ECR_URI}` → Actual ECR repository URL for Node.js
- `${DATABASE_HOST}` → RDS endpoint hostname (parsed to remove :port)
- `${SSL_CERTIFICATE_ARN}` → ACM certificate ARN from Pulumi

## Manual Application (if needed)

```bash
# Apply in order
kubectl apply -f fastapi-deployment.yaml
kubectl apply -f nodejs-deployment.yaml
kubectl apply -f ingress.yaml

# Check status
kubectl get pods
kubectl get services
kubectl get ingress
```

## Future Portability

These manifests are designed for future migration to on-premises Kubernetes:
- **Standard Kubernetes resources** (no EKS-specific dependencies in app layer)
- **Ingress annotations** can be swapped for nginx-ingress
- **Service discovery** uses standard Kubernetes DNS
- **ConfigMap/Secret patterns** work on any Kubernetes distribution