#!/bin/bash
# Pre-deployment environment validation script
# Validates all prerequisites before starting deployment
# Prevents deployment failures by catching issues early

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Validation results
VALIDATION_ERRORS=0
VALIDATION_WARNINGS=0

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

print_header() {
    echo -e "${BLUE}===============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}===============================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
}

print_warning() {
    echo -e "${YELLOW}⚠️ $1${NC}"
    VALIDATION_WARNINGS=$((VALIDATION_WARNINGS + 1))
}

print_info() {
    echo -e "${BLUE}ℹ️ $1${NC}"
}

# =============================================================================
# SYSTEM REQUIREMENTS VALIDATION
# =============================================================================

validate_system_requirements() {
    print_header "SYSTEM REQUIREMENTS VALIDATION"
    
    # Check operating system
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        print_success "Operating System: Windows (Git Bash/MSYS detected)"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        print_success "Operating System: Linux"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        print_success "Operating System: macOS"
    else
        print_warning "Operating System: Unknown ($OSTYPE) - may cause issues"
    fi
    
    # Check required commands for EKS deployment
    local required_commands=("aws" "pulumi" "docker" "jq" "curl" "kubectl" "helm")

    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$(${cmd} --version 2>/dev/null | head -n1 || echo "Unknown version")
            print_success "$cmd: Available ($version)"
        else
            print_error "$cmd: Not found - required for EKS deployment"
        fi
    done
    
    # Check optional but recommended commands
    local optional_commands=("git" "npm" "python" "node")
    
    for cmd in "${optional_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            local version=$(${cmd} --version 2>/dev/null | head -n1 || echo "Unknown version")
            print_success "$cmd: Available ($version)"
        else
            print_warning "$cmd: Not found - may be needed for application builds"
        fi
    done
}

# =============================================================================
# AWS CONFIGURATION VALIDATION
# =============================================================================

validate_aws_configuration() {
    print_header "AWS CONFIGURATION VALIDATION"
    
    # Check AWS CLI configuration
    if aws sts get-caller-identity >/dev/null 2>&1; then
        local account_id=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "Unknown")
        local user_arn=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "Unknown")
        print_success "AWS Credentials: Valid"
        print_info "Account ID: $account_id"
        print_info "User/Role: $user_arn"
    else
        print_error "AWS Credentials: Invalid or not configured"
        print_info "Run: aws configure"
        return 1
    fi
    
    # Check AWS region
    local aws_region=$(aws configure get region 2>/dev/null || echo "")
    if [[ -n "$aws_region" ]]; then
        print_success "AWS Region: $aws_region"
    else
        print_warning "AWS Region: Not set - will default to us-east-1"
        print_info "Consider running: aws configure set region us-east-1"
    fi
    
    # Test basic AWS permissions
    print_info "Testing AWS permissions..."
    
    # Test EC2 permissions
    if aws ec2 describe-vpcs --max-items 1 >/dev/null 2>&1; then
        print_success "EC2 Permissions: Valid"
    else
        print_error "EC2 Permissions: Insufficient"
    fi
    
    # Test EKS permissions
    if aws eks list-clusters --max-items 1 >/dev/null 2>&1; then
        print_success "EKS Permissions: Valid"
    else
        print_error "EKS Permissions: Insufficient"
    fi
    
    # Test RDS permissions
    if aws rds describe-db-instances --max-items 1 >/dev/null 2>&1; then
        print_success "RDS Permissions: Valid"
    else
        print_error "RDS Permissions: Insufficient"
    fi
    
    # Test Route53 permissions
    if aws route53 list-hosted-zones --max-items 1 >/dev/null 2>&1; then
        print_success "Route53 Permissions: Valid"
    else
        print_warning "Route53 Permissions: May be insufficient for DNS management"
    fi
}

# =============================================================================
# DOCKER VALIDATION
# =============================================================================

validate_docker() {
    print_header "DOCKER VALIDATION"
    
    # Check if Docker daemon is running
    if docker ps >/dev/null 2>&1; then
        print_success "Docker Daemon: Running"
        
        # Get Docker info
        local docker_version=$(docker --version | cut -d' ' -f3 | cut -d',' -f1)
        print_info "Docker Version: $docker_version"
        
        # Check Docker system info
        local containers_running=$(docker ps -q | wc -l)
        local images_count=$(docker images -q | wc -l)
        print_info "Running Containers: $containers_running"
        print_info "Available Images: $images_count"
        
    else
        print_error "Docker Daemon: Not running or not accessible"
        print_info "Windows: Start Docker Desktop"
        print_info "Linux: sudo systemctl start docker"
        print_info "macOS: Start Docker Desktop"
        return 1
    fi
    
    # Test Docker functionality
    print_info "Testing Docker functionality..."
    
    if docker run --rm hello-world >/dev/null 2>&1; then
        print_success "Docker Test: Hello World container ran successfully"
    else
        print_error "Docker Test: Failed to run test container"
    fi
    
    # Check Docker disk space
    local docker_space=$(df $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '/var/lib/docker') | tail -n1 | awk '{print $4}' 2>/dev/null || echo "0")
    if [[ $docker_space -gt 5000000 ]]; then  # 5GB in KB
        print_success "Docker Disk Space: Sufficient ($(echo $docker_space | awk '{print int($1/1024/1024)"GB"}'))"
    else
        print_warning "Docker Disk Space: Limited ($(echo $docker_space | awk '{print int($1/1024/1024)"GB"}')), may need cleanup"
    fi
}

# =============================================================================
# PULUMI VALIDATION
# =============================================================================

validate_pulumi() {
    print_header "PULUMI VALIDATION"
    
    # Check Pulumi version
    if command -v pulumi >/dev/null 2>&1; then
        local pulumi_version=$(pulumi version --json 2>/dev/null | jq -r '.version' || echo "Unknown")
        print_success "Pulumi Version: $pulumi_version"
    else
        print_error "Pulumi: Not installed"
        return 1
    fi
    
    # Check Pulumi login status
    if pulumi whoami >/dev/null 2>&1; then
        local pulumi_user=$(pulumi whoami 2>/dev/null || echo "Unknown")
        print_success "Pulumi Login: Authenticated as $pulumi_user"
    else
        print_error "Pulumi Login: Not authenticated"
        print_info "Run: pulumi login"
        return 1
    fi
    
    # List existing stacks (if any)
    local stacks=$(pulumi stack ls --json 2>/dev/null | jq -r '.[].name' 2>/dev/null || echo "")
    if [[ -n "$stacks" ]]; then
        print_info "Existing Pulumi stacks:"
        echo "$stacks" | while read -r stack; do
            print_info "  - $stack"
        done
    else
        print_info "No existing Pulumi stacks found"
    fi
}

# =============================================================================
# NETWORK AND CONNECTIVITY VALIDATION
# =============================================================================

validate_network_connectivity() {
    print_header "NETWORK CONNECTIVITY VALIDATION"
    
    # Test internet connectivity
    if curl -s --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
        print_success "Internet Connectivity: Available"
    else
        print_error "Internet Connectivity: Failed"
        return 1
    fi
    
    # Test AWS endpoints
    local aws_endpoints=(
        "https://ec2.amazonaws.com"
        "https://ecs.amazonaws.com"
        "https://rds.amazonaws.com"
        "https://route53.amazonaws.com"
    )
    
    for endpoint in "${aws_endpoints[@]}"; do
        if curl -s --connect-timeout 5 "$endpoint" >/dev/null 2>&1; then
            print_success "AWS Endpoint: $endpoint reachable"
        else
            print_warning "AWS Endpoint: $endpoint may not be reachable"
        fi
    done
    
    # Test Docker Hub connectivity (for image pulls)
    if curl -s --connect-timeout 5 https://hub.docker.com >/dev/null 2>&1; then
        print_success "Docker Hub: Reachable"
    else
        print_warning "Docker Hub: May not be reachable - could affect image builds"
    fi
    
    # Test ECR login capability
    local ecr_region=${AWS_DEFAULT_REGION:-"us-east-1"}
    if aws ecr get-login-password --region "$ecr_region" >/dev/null 2>&1; then
        print_success "ECR Login: Credentials available"
    else
        print_warning "ECR Login: May have issues with authentication"
    fi
}

# =============================================================================
# RESOURCE AVAILABILITY VALIDATION
# =============================================================================

validate_aws_resource_availability() {
    print_header "AWS RESOURCE AVAILABILITY VALIDATION"
    
    # Check existing VPCs and CIDR blocks
    local existing_vpcs=$(aws ec2 describe-vpcs --query "Vpcs[*].{Id:VpcId,CIDR:CidrBlock}" --output table 2>/dev/null || echo "Error getting VPCs")
    if [[ "$existing_vpcs" != "Error getting VPCs" ]]; then
        print_success "VPC Query: Successful"
        print_info "Existing VPCs:"
        echo "$existing_vpcs"
    else
        print_error "VPC Query: Failed"
    fi
    
    # Check EKS clusters
    local eks_clusters=$(aws eks list-clusters --query "clusters" --output table 2>/dev/null || echo "Error getting EKS clusters")
    if [[ "$eks_clusters" != "Error getting EKS clusters" ]]; then
        print_success "EKS Query: Successful"
        local cluster_count=$(aws eks list-clusters --query "length(clusters)" --output text 2>/dev/null || echo "0")
        print_info "Existing EKS clusters: $cluster_count"
    else
        print_error "EKS Query: Failed"
    fi
    
    # Check RDS instances
    local rds_instances=$(aws rds describe-db-instances --query "length(DBInstances)" --output text 2>/dev/null || echo "Error")
    if [[ "$rds_instances" != "Error" ]]; then
        print_success "RDS Query: Successful"
        print_info "Existing RDS instances: $rds_instances"
    else
        print_error "RDS Query: Failed"
    fi
    
    # Check Route53 hosted zones
    local hosted_zones=$(aws route53 list-hosted-zones --query "HostedZones[*].Name" --output table 2>/dev/null || echo "Error getting hosted zones")
    if [[ "$hosted_zones" != "Error getting hosted zones" ]]; then
        print_success "Route53 Query: Successful"
        print_info "Hosted zones found"
    else
        print_warning "Route53 Query: May have limited access"
    fi
}

# =============================================================================
# APPLICATION PREREQUISITES VALIDATION
# =============================================================================

validate_application_prerequisites() {
    print_header "APPLICATION PREREQUISITES VALIDATION"
    
    # Check if docker-images directory exists
    if [[ -d "docker-images" ]]; then
        print_success "Docker Images Directory: Found"
        
        # Check FastAPI application
        if [[ -d "docker-images/fastapi" ]]; then
            print_success "FastAPI Directory: Found"
            
            if [[ -f "docker-images/fastapi/main.py" ]]; then
                print_success "FastAPI main.py: Found"
            else
                print_error "FastAPI main.py: Missing"
            fi
            
            if [[ -f "docker-images/fastapi/requirements.txt" ]]; then
                print_success "FastAPI requirements.txt: Found"
            else
                print_error "FastAPI requirements.txt: Missing"
            fi
            
            if [[ -f "docker-images/fastapi/Dockerfile" ]]; then
                print_success "FastAPI Dockerfile: Found"
            else
                print_error "FastAPI Dockerfile: Missing"
            fi
        else
            print_error "FastAPI Directory: Missing"
        fi
        
        # Check Node.js application
        if [[ -d "docker-images/nodejs" ]]; then
            print_success "Node.js Directory: Found"
            
            if [[ -f "docker-images/nodejs/server.js" ]]; then
                print_success "Node.js server.js: Found"
            else
                print_error "Node.js server.js: Missing"
            fi
            
            if [[ -f "docker-images/nodejs/package.json" ]]; then
                print_success "Node.js package.json: Found"
            else
                print_error "Node.js package.json: Missing"
            fi
            
            if [[ -f "docker-images/nodejs/Dockerfile" ]]; then
                print_success "Node.js Dockerfile: Found"
            else
                print_error "Node.js Dockerfile: Missing"
            fi
            
            # Check for package-lock.json (critical for consistent builds)
            if [[ -f "docker-images/nodejs/package-lock.json" ]]; then
                print_success "Node.js package-lock.json: Found"
            else
                print_warning "Node.js package-lock.json: Missing - will be generated during build"
            fi
        else
            print_error "Node.js Directory: Missing"
        fi
    else
        print_error "Docker Images Directory: Missing"
    fi
    
    # Check infrastructure directory
    if [[ -d "infrastructure" ]]; then
        print_success "Infrastructure Directory: Found"
        
        if [[ -f "infrastructure/index.ts" ]]; then
            print_success "Pulumi index.ts: Found"
        else
            print_error "Pulumi index.ts: Missing"
        fi
        
        if [[ -f "infrastructure/package.json" ]]; then
            print_success "Pulumi package.json: Found"
        else
            print_error "Pulumi package.json: Missing"
        fi
    else
        print_error "Infrastructure Directory: Missing"
    fi
}

# =============================================================================
# EKS-SPECIFIC VALIDATION
# =============================================================================

validate_eks_prerequisites() {
    print_header "EKS PREREQUISITES VALIDATION"

    # Check kubectl configuration
    if kubectl version --client >/dev/null 2>&1; then
        local kubectl_version=$(kubectl version --client --short 2>/dev/null | head -n1 || echo "Unknown")
        print_success "kubectl: $kubectl_version"
    else
        print_error "kubectl: Not working properly"
    fi

    # Check Helm
    if helm version >/dev/null 2>&1; then
        local helm_version=$(helm version --short 2>/dev/null || echo "Unknown")
        print_success "Helm: $helm_version"
    else
        print_error "Helm: Not working properly"
    fi

    # Check if any existing kubeconfig might interfere
    if [[ -f ~/.kube/config ]]; then
        print_info "Existing kubectl config found - will be updated for EKS"

        # Try to get current context (non-fatal)
        local current_context=$(kubectl config current-context 2>/dev/null || echo "none")
        if [[ "$current_context" != "none" ]]; then
            print_info "Current kubectl context: $current_context"
        fi
    else
        print_info "No existing kubectl config - will be created for EKS"
    fi

    # Check Kubernetes cluster compatibility
    print_info "EKS deployment will use Fargate serverless compute"
    print_info "No worker nodes required - pods run on AWS Fargate"
}

# =============================================================================
# DEPLOYMENT READINESS SUMMARY
# =============================================================================

generate_readiness_summary() {
    print_header "DEPLOYMENT READINESS SUMMARY"
    
    echo -e "${BLUE}Validation Results:${NC}"
    echo -e "  ${GREEN}✅ Successful validations${NC}"
    echo -e "  ${RED}❌ Errors: $VALIDATION_ERRORS${NC}"
    echo -e "  ${YELLOW}⚠️ Warnings: $VALIDATION_WARNINGS${NC}"
    echo ""
    
    if [[ $VALIDATION_ERRORS -eq 0 ]]; then
        print_success "DEPLOYMENT READY: All critical validations passed!"
        echo ""
        print_info "You can proceed with deployment using:"
        print_info "  ./deploy.sh [stage-name] [domain]"
        print_info "  Example: ./deploy.sh stage4-v1 stage4-v1.a-g-e-n-t-i-c.com"
        
        if [[ $VALIDATION_WARNINGS -gt 0 ]]; then
            echo ""
            print_warning "Note: There are $VALIDATION_WARNINGS warnings above."
            print_warning "Review them before proceeding with deployment."
        fi
        
        return 0
    else
        print_error "DEPLOYMENT BLOCKED: $VALIDATION_ERRORS critical errors must be resolved first"
        echo ""
        print_info "Common fixes:"
        print_info "  - Install missing tools (aws, pulumi, docker, jq, kubectl, helm)"
        print_info "  - Configure AWS credentials: aws configure"
        print_info "  - Start Docker Desktop"
        print_info "  - Login to Pulumi: pulumi login"
        print_info "  - Install kubectl: AWS EKS requires kubectl for cluster management"
        print_info "  - Install Helm: Required for AWS Load Balancer Controller"
        
        return 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo -e "${BLUE}🔍 AWS EKS Deployment Environment Validation${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo ""

    # Run all validations
    validate_system_requirements
    echo ""

    validate_aws_configuration
    echo ""

    validate_docker
    echo ""

    validate_pulumi
    echo ""

    validate_eks_prerequisites
    echo ""

    validate_network_connectivity
    echo ""

    validate_aws_resource_availability
    echo ""

    validate_application_prerequisites
    echo ""
    
    # Generate summary and exit with appropriate code
    generate_readiness_summary
    exit $?
}

# Run main function
main "$@"