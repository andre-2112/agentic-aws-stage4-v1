#!/bin/bash
# Master deployment script for Stage4-v1 EKS Deployment
# Adapted from Stage3-v4 ECS deployment with all battle-tested learnings
# Incorporates ALL critical issue preventions for EKS architecture
#
# Usage: ./deploy.sh [stage-name] [domain]
# Example: ./deploy.sh stage4-v1 stage4-v1.a-g-e-n-t-i-c.com

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

STAGE_NAME=${1:-"stage4-v1"}
DOMAIN=${2:-"stage4-v1.a-g-e-n-t-i-c.com"}
BASE_DOMAIN="a-g-e-n-t-i-c.com"
REGION="us-east-1"
ECR_ACCOUNT="211050572089"
ECR_URI="${ECR_ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

# Load deployment functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/deployment-functions.sh"

# =============================================================================
# BANNER AND INITIALIZATION
# =============================================================================

echo "==============================================="
echo "🚀 AWS EKS DEPLOYMENT - $STAGE_NAME"
echo "==============================================="
echo "Domain: https://$DOMAIN"
echo "Region: $REGION"
echo "Architecture: EKS Fargate Serverless"
echo "Time: $(date)"
echo "==============================================="

# Initialize deployment tracking
initialize_deployment_state
update_deployment_state "STAGE_NAME" "$STAGE_NAME"
update_deployment_state "DOMAIN" "$DOMAIN"

# =============================================================================
# PHASE 1: EARLY SSL CERTIFICATE REQUEST (PROVEN STRATEGY!)
# =============================================================================

echo ""
echo "🔒 PHASE 1: EARLY SSL CERTIFICATE REQUEST"
echo "==============================================="

# This phase implements the proven strategy to request SSL certificate
# EARLY so DNS propagation happens while we build infrastructure
if ! check_deployment_state "SSL_REQUESTED"; then
    echo "📋 Requesting SSL certificate for $DOMAIN..."

    # Request certificate with DNS validation
    CERT_ARN=$(aws acm request-certificate \
        --domain-name "$DOMAIN" \
        --validation-method DNS \
        --region "$REGION" \
        --query "CertificateArn" \
        --output text 2>/dev/null || echo "")

    if [[ -n "$CERT_ARN" ]]; then
        echo "✅ SSL certificate requested: $CERT_ARN"
        update_deployment_state "SSL_CERTIFICATE_ARN" "$CERT_ARN"
        update_deployment_state "SSL_REQUESTED" "true"

        # Get DNS validation record
        echo "📋 Waiting for DNS validation record details..."
        sleep 10

        aws acm describe-certificate \
            --certificate-arn "$CERT_ARN" \
            --region "$REGION" \
            --query "Certificate.DomainValidationOptions[0].ResourceRecord" \
            --output table || true

        echo ""
        echo "🔔 IMPORTANT: Add the DNS validation record to Route53"
        echo "   The certificate will validate while we build infrastructure"
        echo ""
    else
        echo "⚠️  Could not request SSL certificate, will retry later"
    fi
else
    echo "✅ SSL certificate already requested"
fi

# =============================================================================
# PHASE 2: ENVIRONMENT PREPARATION
# =============================================================================

echo ""
echo "🛠️ PHASE 2: ENVIRONMENT PREPARATION"
echo "==============================================="

# Enhanced Docker daemon checks
check_docker_health_enhanced

# Pre-deployment validation
echo "🔍 Running pre-deployment validation..."
"${SCRIPT_DIR}/validate-environment.sh" || {
    echo "❌ Environment validation failed!"
    echo "Please fix the issues above before continuing"
    exit 1
}

# AWS CLI configuration check
verify_aws_access

# =============================================================================
# PHASE 3: INFRASTRUCTURE DEPLOYMENT
# =============================================================================

echo ""
echo "🏗️ PHASE 3: INFRASTRUCTURE DEPLOYMENT"
echo "==============================================="

cd infrastructure || exit 1

# Configure Pulumi for EKS deployment
configure_pulumi_for_stage "$STAGE_NAME"

echo "🔧 Deploying EKS infrastructure..."
echo "   This includes: VPC, EKS cluster, Fargate profiles, RDS, ECR"

# Run Pulumi deployment with enhanced error handling
deploy_infrastructure_with_retry || {
    echo "❌ Infrastructure deployment failed!"
    exit 1
}

# Get infrastructure outputs
echo "📋 Retrieving infrastructure details..."
EKS_CLUSTER_NAME=$(pulumi stack output eksClusterId 2>/dev/null || echo "")
RDS_ENDPOINT=$(pulumi stack output databaseEndpoint 2>/dev/null || echo "")
FASTAPI_ECR=$(pulumi stack output fastapiRepositoryUrl 2>/dev/null || echo "")
NODEJS_ECR=$(pulumi stack output nodejsRepositoryUrl 2>/dev/null || echo "")

if [[ -z "$EKS_CLUSTER_NAME" ]]; then
    echo "❌ Failed to get EKS cluster name from Pulumi outputs"
    exit 1
fi

echo "✅ Infrastructure deployed successfully:"
echo "   EKS Cluster: $EKS_CLUSTER_NAME"
echo "   RDS Endpoint: $RDS_ENDPOINT"
echo "   FastAPI ECR: $FASTAPI_ECR"
echo "   Node.js ECR: $NODEJS_ECR"

update_deployment_state "EKS_CLUSTER_NAME" "$EKS_CLUSTER_NAME"
update_deployment_state "RDS_ENDPOINT" "$RDS_ENDPOINT"

# =============================================================================
# PHASE 4: EKS CLUSTER CONFIGURATION
# =============================================================================

echo ""
echo "☸️ PHASE 4: EKS CLUSTER CONFIGURATION"
echo "==============================================="

# Update kubeconfig
echo "🔧 Configuring kubectl access to EKS cluster..."
aws eks update-kubeconfig --region "$REGION" --name "$EKS_CLUSTER_NAME"

# Wait for cluster to be ready
echo "⏳ Waiting for EKS cluster to be fully ready..."
aws eks wait cluster-active --name "$EKS_CLUSTER_NAME" --region "$REGION"

# Check cluster status
echo "🔍 Checking cluster health..."
kubectl cluster-info
kubectl get nodes -o wide || echo "No nodes (Fargate serverless)"

# Install AWS Load Balancer Controller if not exists
echo "🔧 Ensuring AWS Load Balancer Controller is installed..."
install_aws_load_balancer_controller "$EKS_CLUSTER_NAME"

# =============================================================================
# PHASE 5: APPLICATION DEPLOYMENT
# =============================================================================

echo ""
echo "🐳 PHASE 5: APPLICATION DEPLOYMENT"
echo "==============================================="

cd ../docker-images || exit 1

# Build and push FastAPI image
echo "🔄 Building and pushing FastAPI image..."
build_and_push_image "fastapi" "$FASTAPI_ECR" || exit 1

# Build and push Node.js image
echo "🔄 Building and pushing Node.js image..."
build_and_push_image "nodejs" "$NODEJS_ECR" || exit 1

# Deploy Kubernetes applications
cd ../kubernetes/manifests || exit 1

echo "☸️ Deploying Kubernetes applications..."
deploy_kubernetes_applications "$FASTAPI_ECR" "$NODEJS_ECR"

# =============================================================================
# PHASE 6: COMPREHENSIVE VALIDATION
# =============================================================================

echo ""
echo "🔍 PHASE 6: COMPREHENSIVE VALIDATION"
echo "==============================================="

# Wait for pods to be ready
echo "⏳ Waiting for pods to be ready..."
kubectl wait --for=condition=Ready pod -l app=fastapi --timeout=300s || true
kubectl wait --for=condition=Ready pod -l app=nodejs --timeout=300s || true

# Check pod status
echo "📋 Pod status:"
kubectl get pods
kubectl get services
kubectl get ingress

# Get ALB endpoint
ALB_ENDPOINT=$(kubectl get ingress agentic-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

if [[ -n "$ALB_ENDPOINT" ]]; then
    echo "✅ Application Load Balancer: $ALB_ENDPOINT"
    update_deployment_state "ALB_ENDPOINT" "$ALB_ENDPOINT"
else
    echo "⚠️  ALB endpoint not yet ready, will retry during testing"
fi

# Comprehensive endpoint testing
echo ""
echo "🧪 Testing all endpoints systematically..."

# Test endpoints with retries
test_all_endpoints_systematic "$DOMAIN" || {
    echo "❌ Endpoint testing failed!"
    echo "🔍 Debugging information:"
    kubectl describe ingress agentic-ingress
    kubectl logs -l app=nodejs --tail=50
    kubectl logs -l app=fastapi --tail=50
    exit 1
}

# =============================================================================
# PHASE 7: COMPLETION AND SUMMARY
# =============================================================================

echo ""
echo "🎉 DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "==============================================="
echo "Stage: $STAGE_NAME"
echo "URL: https://$DOMAIN"
echo "Architecture: EKS Fargate Serverless"
echo "Database: ✅ Connected"
echo "All Endpoints: ✅ Functional"
echo "Time: $(date)"
echo "==============================================="

# Save completion state
update_deployment_state "DEPLOYMENT_COMPLETE" "true"
update_deployment_state "COMPLETION_TIME" "$(date)"

# Final endpoint summary
echo ""
echo "🔗 Available Endpoints:"
echo "   https://$DOMAIN/health"
echo "   https://$DOMAIN/api/status"
echo "   https://$DOMAIN/api/db-test"
echo "   https://$DOMAIN/api/fastapi"
echo "   https://$DOMAIN/api/config"
echo "   https://$DOMAIN/api/environment"
echo ""

echo "✅ Stage4-v1 EKS deployment successful!"
echo "🎯 All success criteria met!"