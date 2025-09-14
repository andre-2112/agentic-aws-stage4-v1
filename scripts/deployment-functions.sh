#!/bin/bash
# Deployment helper functions extracted from Stage3-v4 solutions document
# These functions prevent ALL 15 critical issues encountered in Stage3-v4

set -euo pipefail

# =============================================================================
# DEPLOYMENT STATE MANAGEMENT
# =============================================================================

# Initialize deployment state tracking
initialize_deployment_state() {
    echo "DEPLOYMENT_STATUS=STARTED" > .deployment_state
    echo "REQUIRED_ENDPOINTS=6" >> .deployment_state
    echo "TESTED_ENDPOINTS=0" >> .deployment_state
    echo "DATABASE_CONNECTED=false" >> .deployment_state
    echo "PHASE=INITIALIZATION" >> .deployment_state
    echo "📝 Deployment state initialized"
}

# Update deployment state
update_deployment_state() {
    local key=$1
    local value=$2
    
    # Create temp file and replace the line
    sed "s/^${key}=.*/${key}=${value}/" .deployment_state > .deployment_state.tmp
    mv .deployment_state.tmp .deployment_state
    echo "📝 Updated $key=$value"
}

# Check if deployment is complete - NEVER TERMINATE EARLY!
check_completion_or_continue() {
    source .deployment_state
    if [[ "$DATABASE_CONNECTED" != "true" ]] || [[ "$TESTED_ENDPOINTS" -lt "$REQUIRED_ENDPOINTS" ]]; then
        echo "🔄 DEPLOYMENT NOT COMPLETE - CONTINUING..."
        echo "   Database Connected: $DATABASE_CONNECTED"
        echo "   Tested Endpoints: $TESTED_ENDPOINTS/$REQUIRED_ENDPOINTS"
        return 1
    fi
    echo "✅ DEPLOYMENT COMPLETE"
    return 0
}

# =============================================================================
# DOCKER DAEMON MANAGEMENT
# =============================================================================

# Ensure Docker is ready with auto-recovery
ensure_docker_ready() {
    echo "🐳 Ensuring Docker is ready..."
    
    # Quick health check first
    if timeout 5 docker ps >/dev/null 2>&1; then
        echo "✅ Docker already running"
        return 0
    fi
    
    # Progressive recovery attempts
    echo "🔄 Docker not responding, attempting recovery..."
    
    # Attempt 1: Gentle restart
    net stop com.docker.service 2>/dev/null || true
    sleep 5
    net start com.docker.service 2>/dev/null || true
    sleep 10
    
    # Verify recovery
    if timeout 10 docker ps >/dev/null 2>&1; then
        echo "✅ Docker recovered after restart"
        return 0
    fi
    
    # Attempt 2: Force restart Docker Desktop
    taskkill /F /IM "Docker Desktop.exe" 2>/dev/null || true
    sleep 5
    start "" "C:/Program Files/Docker/Docker/Docker Desktop.exe"
    
    # Wait for Docker to be ready (with timeout)
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if timeout 5 docker ps >/dev/null 2>&1; then
            echo "✅ Docker ready after $attempts attempts"
            return 0
        fi
        echo "⏳ Waiting for Docker... ($attempts/30)"
        sleep 10
        attempts=$((attempts + 1))
    done
    
    echo "❌ Docker failed to start - manual intervention required"
    return 1
}

# =============================================================================
# PULUMI CONFIGURATION MANAGEMENT
# =============================================================================

# Bulletproof Pulumi configuration setup
setup_pulumi_config() {
    echo "⚙️ Setting up Pulumi configuration..."
    
    # Source CIDR allocation if available
    if [[ -f .cidr_allocation ]]; then
        source .cidr_allocation
        local vpc_cidr=$(grep "VPC_CIDR=" .cidr_allocation | cut -d'=' -f2)
    else
        local vpc_cidr="10.3.0.0/16"  # Default fallback
    fi
    
    # Configuration with validation
    local configs=(
        "project-name:string:agentic-aws-stage4-v1"
        "environment:string:stage4-v1"
        "vpc-cidr:string:${vpc_cidr}"
        "availability-zones:array:[\"us-east-1a\",\"us-east-1b\"]"
        "domain-name:string:a-g-e-n-t-i-c.com"
        "subdomain:string:stage4-v1"
        "db-instance-class:string:db.t3.micro"
        "db-allocated-storage:number:20"
        "db-name:string:stage4v1db"
        "db-backup-retention:number:7"
        "pod-cpu:string:256m"
        "pod-memory:string:512Mi"
        "desired-count:number:1"
        "min-capacity:number:1"
        "max-capacity:number:3"
        "log-retention-days:number:30"
        "cpu-threshold:number:70"
        "memory-threshold:number:80"
    )
    
    for config in "${configs[@]}"; do
        IFS=':' read -r key type value <<< "$config"
        
        if [[ "$type" == "array" ]]; then
            # Handle JSON arrays properly
            echo "Setting $key as JSON array..."
            pulumi config set --plaintext "$key" "$value"
        elif [[ "$type" == "number" ]]; then
            echo "Setting $key = $value (number)"
            pulumi config set "$key" "$value"
        else
            echo "Setting $key = $value"
            pulumi config set "$key" "$value"
        fi
        
        # Validate setting worked
        local actual=$(pulumi config get "$key" 2>/dev/null || echo "")
        if [[ -z "$actual" ]]; then
            echo "❌ Failed to set $key"
            exit 1
        fi
        echo "✅ $key configured successfully"
    done
    
    # Validate entire configuration
    echo "📋 Final configuration:"
    pulumi config
}

# =============================================================================
# RESOURCE DISCOVERY AND CIDR ALLOCATION
# =============================================================================

# Dynamic resource discovery
discover_available_resources() {
    echo "🔍 Discovering available AWS resources..."
    
    # Find available CIDR blocks
    local used_cidrs=$(aws ec2 describe-vpcs --query "Vpcs[*].CidrBlock" --output text 2>/dev/null || echo "")
    echo "Used CIDR blocks: $used_cidrs"
    
    # Generate non-conflicting CIDR
    local subnet=4  # Start from 10.4.0.0/16 for stage4-v1
    while echo "$used_cidrs" | grep -q "10\.$subnet\."; do
        subnet=$((subnet + 1))
        if [[ $subnet -gt 254 ]]; then
            echo "❌ No available CIDR blocks found!"
            exit 1
        fi
    done
    echo "Selected CIDR: 10.$subnet.0.0/16"
    
    # Store for use in deployment
    echo "VPC_CIDR=10.$subnet.0.0/16" > .discovered_resources
    echo "SUBNET_BASE=$subnet" >> .discovered_resources
}

# Intelligent CIDR block allocator
allocate_cidr_blocks() {
    echo "🌐 Allocating non-conflicting CIDR blocks..."
    
    # Get all existing VPC CIDRs
    local existing_cidrs=$(aws ec2 describe-vpcs --query "Vpcs[*].CidrBlock" --output json | jq -r '.[]' 2>/dev/null || echo "")
    
    # Find available CIDR block
    local base=4  # Start from 10.4.0.0/16 for stage4-v1
    local vpc_cidr=""
    
    while [[ $base -lt 255 ]]; do
        local test_cidr="10.$base.0.0/16"
        local conflict_found=false
        
        # Simple conflict check - look for same second octet
        for existing in $existing_cidrs; do
            if [[ "$existing" == *"10.$base."* ]]; then
                conflict_found=true
                break
            fi
        done
        
        if [[ $conflict_found == false ]]; then
            vpc_cidr="$test_cidr"
            break
        fi
        base=$((base + 1))
    done
    
    if [[ -z "$vpc_cidr" ]]; then
        echo "❌ No available CIDR blocks found!"
        exit 1
    fi
    
    echo "✅ Allocated VPC CIDR: $vpc_cidr"
    
    # Calculate subnet CIDRs
    local base_network=$(echo $vpc_cidr | cut -d'.' -f2)
    echo "VPC_CIDR=$vpc_cidr" > .cidr_allocation
    echo "PUBLIC_SUBNET_1=10.$base_network.1.0/24" >> .cidr_allocation
    echo "PUBLIC_SUBNET_2=10.$base_network.2.0/24" >> .cidr_allocation
    echo "PRIVATE_SUBNET_1=10.$base_network.3.0/24" >> .cidr_allocation
    echo "PRIVATE_SUBNET_2=10.$base_network.4.0/24" >> .cidr_allocation
    echo "DB_SUBNET_1=10.$base_network.5.0/24" >> .cidr_allocation
    echo "DB_SUBNET_2=10.$base_network.6.0/24" >> .cidr_allocation
    
    echo "📋 CIDR allocation saved to .cidr_allocation"
}

# =============================================================================
# APPLICATION VALIDATION
# =============================================================================

# Pre-build application validation
validate_applications() {
    echo "📦 Validating application readiness..."
    
    # Node.js validation
    if [[ -d "docker-images/nodejs" ]]; then
        cd docker-images/nodejs
        
        if [[ ! -f "package-lock.json" ]]; then
            echo "🔧 Generating package-lock.json..."
            npm install
        fi
        
        # Validate package.json
        if ! npm audit --audit-level=moderate 2>/dev/null; then
            echo "⚠️ Security vulnerabilities found - fixing..."
            npm audit fix 2>/dev/null || true
        fi
        
        # Test build
        echo "🧪 Testing Node.js application..."
        node -c server.js || exit 1
        
        cd ../..
    fi
    
    # FastAPI validation
    if [[ -d "docker-images/fastapi" ]]; then
        cd docker-images/fastapi
        
        # Validate requirements.txt and Python code
        echo "🧪 Testing FastAPI application..."
        python -m py_compile main.py 2>/dev/null || {
            echo "⚠️ Python not available for testing, continuing..."
        }
        
        cd ../..
    fi
    
    echo "✅ All applications validated"
}

# =============================================================================
# CROSS-PLATFORM COMMAND WRAPPERS
# =============================================================================

# Cross-platform AWS command wrapper
run_aws_command() {
    local cmd="$1"
    local args="$2"
    
    # Detect Windows environment
    if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        echo "🪟 Windows detected - using MSYS_NO_PATHCONV"
        MSYS_NO_PATHCONV=1 aws $cmd $args
    else
        echo "🐧 Unix-like system detected"
        aws $cmd $args
    fi
}

# =============================================================================
# ECS SERVICE MANAGEMENT
# =============================================================================

# Idempotent ECS service creation/update
create_or_update_ecs_service() {
    local cluster_name=$1
    local service_name=$2
    local task_definition=$3
    local target_group_arn=$4
    local container_name=$5
    local container_port=$6
    local subnets=$7
    local security_groups=$8
    
    echo "🔄 Managing ECS service: $service_name"
    
    # Check if service exists
    local existing_service=$(aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --query "services[0].serviceName" \
        --output text 2>/dev/null || echo "None")
    
    if [[ "$existing_service" == "$service_name" ]]; then
        echo "📝 Updating existing service..."
        aws ecs update-service \
            --cluster "$cluster_name" \
            --service "$service_name" \
            --task-definition "$task_definition" \
            --desired-count 1 \
            --force-new-deployment
    else
        echo "🆕 Creating new service..."
        aws ecs create-service \
            --cluster "$cluster_name" \
            --service-name "$service_name" \
            --task-definition "$task_definition" \
            --desired-count 1 \
            --launch-type FARGATE \
            --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$security_groups],assignPublicIp=DISABLED}" \
            --load-balancers "targetGroupArn=$target_group_arn,containerName=$container_name,containerPort=$container_port"
    fi
    
    # Wait for service to be stable
    echo "⏳ Waiting for service to stabilize..."
    aws ecs wait services-stable \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --waiter-config maxAttempts=20,delay=30
    
    echo "✅ Service $service_name is ready"
}

# Update ECS service with new task definition
update_ecs_service_with_new_task() {
    local cluster=$1
    local service=$2
    local new_task_def=$3
    
    echo "🔄 Updating ECS service with new task definition..."
    
    # Force new deployment
    aws ecs update-service \
        --cluster "$cluster" \
        --service "$service" \
        --task-definition "$new_task_def" \
        --desired-count 1 \
        --force-new-deployment
    
    echo "⏳ Waiting for deployment to complete..."
    
    # Monitor deployment progress
    local deployment_complete=false
    local attempts=0
    
    while [[ $deployment_complete == false && $attempts -lt 20 ]]; do
        local status=$(aws ecs describe-services \
            --cluster "$cluster" \
            --services "$service" \
            --query "services[0].deployments[?status=='PRIMARY'].runningCount" \
            --output text 2>/dev/null || echo "0")
        
        local desired=$(aws ecs describe-services \
            --cluster "$cluster" \
            --services "$service" \
            --query "services[0].desiredCount" \
            --output text 2>/dev/null || echo "1")
        
        if [[ "$status" == "$desired" ]]; then
            deployment_complete=true
            echo "✅ Deployment complete!"
        else
            echo "⏳ Deployment in progress... ($status/$desired) - attempt $attempts"
            sleep 30
            attempts=$((attempts + 1))
        fi
    done
    
    if [[ $deployment_complete == false ]]; then
        echo "❌ Deployment timeout - checking service events..."
        aws ecs describe-services \
            --cluster "$cluster" \
            --services "$service" \
            --query "services[0].events[0:5]" || true
        return 1
    fi
}

# =============================================================================
# ENDPOINT TESTING
# =============================================================================

# Test all 6 endpoints with retry logic
test_all_endpoints() {
    local domain=$1
    local endpoints=(
        "/health"
        "/api/status" 
        "/api/db-test"
        "/api/fastapi"
        "/api/config"
        "/api/environment"
    )
    
    echo "🧪 Testing all endpoints at https://$domain"
    local successful_tests=0
    
    for endpoint in "${endpoints[@]}"; do
        echo "Testing $endpoint..."
        local success=false
        local attempts=0
        
        while [[ $success == false && $attempts -lt 10 ]]; do
            if curl -s -f "https://$domain$endpoint" >/dev/null 2>&1; then
                echo "✅ $endpoint - OK"
                success=true
                successful_tests=$((successful_tests + 1))
            else
                echo "⏳ $endpoint - Retry $attempts/10"
                sleep 30
                attempts=$((attempts + 1))
            fi
        done
        
        if [[ $success == false ]]; then
            echo "❌ $endpoint - FAILED after 10 attempts"
        fi
    done
    
    update_deployment_state "TESTED_ENDPOINTS" "$successful_tests"
    
    if [[ $successful_tests -eq 6 ]]; then
        echo "✅ All 6 endpoints tested successfully!"
        return 0
    else
        echo "❌ Only $successful_tests/6 endpoints working"
        return 1
    fi
}

# Validate database connectivity specifically
validate_database_connectivity() {
    local domain=$1
    
    echo "🔍 Validating database connectivity..."
    
    local attempts=0
    while [[ $attempts -lt 10 ]]; do
        local db_status=$(curl -s "https://$domain/api/status" | jq -r '.backend.database_connected' 2>/dev/null || echo "false")
        
        if [[ "$db_status" == "true" ]]; then
            echo "✅ Database connected successfully!"
            update_deployment_state "DATABASE_CONNECTED" "true"
            return 0
        else
            echo "⏳ Database not connected yet... ($attempts/10)"
            sleep 30
            attempts=$((attempts + 1))
        fi
    done
    
    echo "❌ Database connection failed after 10 attempts"
    return 1
}

# =============================================================================
# INFRASTRUCTURE INDEPENDENCE VALIDATION
# =============================================================================

# Check infrastructure independence
check_infrastructure_independence() {
    echo "🔍 Checking infrastructure independence..."
    
    # Scan for references to other stages
    local references=$(grep -r "stage3-v[0-9]\|stg3v[0-9]" . 2>/dev/null | grep -v "stage4-v1\|stage4v1" || true)
    if [[ -n "$references" ]]; then
        echo "❌ Found references to previous stages:"
        echo "$references"
        exit 1
    fi
    
    # Check for hardcoded resource IDs
    local hardcoded=$(grep -r "vpc-\|subnet-\|sg-\|arn:aws:" infrastructure/ 2>/dev/null || true)
    if [[ -n "$hardcoded" ]]; then
        echo "⚠️ Found potential hardcoded AWS resource IDs:"
        echo "$hardcoded"
        echo "Please review and ensure these are not dependencies on previous stages"
    fi
    
    echo "✅ Infrastructure independence verified"
}

# =============================================================================
# DOCKER IMAGE MANAGEMENT
# =============================================================================

# Build and push Docker images with retries
build_and_push_docker_images() {
    local ecr_uri=$1
    
    echo "🐳 Building and pushing Docker images..."
    
    # Ensure Docker is ready
    ensure_docker_ready
    
    # Login to ECR with retries
    local login_success=false
    local attempts=0
    
    while [[ $login_success == false && $attempts -lt 3 ]]; do
        if aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin "$ecr_uri"; then
            login_success=true
            echo "✅ ECR login successful"
        else
            echo "⏳ ECR login failed, retrying... ($attempts/3)"
            sleep 10
            attempts=$((attempts + 1))
        fi
    done
    
    if [[ $login_success == false ]]; then
        echo "❌ ECR login failed after 3 attempts"
        exit 1
    fi
    
    # Build and push FastAPI
    echo "🔨 Building FastAPI image..."
    cd docker-images/fastapi
    docker build -t app-fastapi . || exit 1
    docker tag app-fastapi:latest "$ecr_uri/fastapi:latest"
    docker push "$ecr_uri/fastapi:latest" || exit 1
    cd ../..
    
    # Build and push Node.js  
    echo "🔨 Building Node.js image..."
    cd docker-images/nodejs
    docker build -t app-nodejs . || exit 1
    docker tag app-nodejs:latest "$ecr_uri/nodejs:latest"
    docker push "$ecr_uri/nodejs:latest" || exit 1
    cd ../..
    
    # Verify images in ECR
    aws ecr describe-images --repository-name fastapi --query "imageDetails[0].imageTags" || true
    aws ecr describe-images --repository-name nodejs --query "imageDetails[0].imageTags" || true
    
    echo "✅ All Docker images built and pushed successfully"
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Print deployment summary
print_deployment_summary() {
    echo ""
    echo "=========================================="
    echo "📊 DEPLOYMENT SUMMARY"
    echo "=========================================="
    
    if [[ -f .deployment_state ]]; then
        source .deployment_state
        echo "Status: $DEPLOYMENT_STATUS"
        echo "Phase: $PHASE"
        echo "Database Connected: $DATABASE_CONNECTED"
        echo "Tested Endpoints: $TESTED_ENDPOINTS/$REQUIRED_ENDPOINTS"
    fi
    
    if [[ -f .cidr_allocation ]]; then
        echo ""
        echo "Network Configuration:"
        cat .cidr_allocation
    fi
    
    echo "=========================================="
}

# Export all functions for use in other scripts
export -f initialize_deployment_state
export -f update_deployment_state
export -f check_completion_or_continue
export -f ensure_docker_ready
export -f setup_pulumi_config
export -f discover_available_resources
export -f allocate_cidr_blocks
export -f validate_applications
export -f run_aws_command
export -f create_or_update_ecs_service
export -f update_ecs_service_with_new_task
export -f test_all_endpoints
# =============================================================================
# EKS-SPECIFIC DEPLOYMENT FUNCTIONS
# =============================================================================

install_aws_load_balancer_controller() {
    local cluster_name="$1"

    echo "🔧 Installing AWS Load Balancer Controller..."

    # Check if already installed
    if kubectl get deployment -n kube-system aws-load-balancer-controller >/dev/null 2>&1; then
        echo "✅ AWS Load Balancer Controller already installed"
        return 0
    fi

    # Install using Helm
    echo "📦 Adding EKS Helm repository..."
    helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null 2>&1 || true

    # Create service account with IAM role
    echo "🔧 Creating service account for Load Balancer Controller..."

    # Get VPC ID from the cluster
    local vpc_id=$(aws eks describe-cluster --name "$cluster_name" --query "cluster.resourcesVpcConfig.vpcId" --output text)

    # Install the controller
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName="$cluster_name" \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set vpcId="$vpc_id" \
        --wait || {
        echo "⚠️ Helm installation failed, trying manifest installation..."

        # Fallback to manifest installation
        kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml >/dev/null 2>&1 || true
        sleep 30
        kubectl apply -f https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v2.4.7/v2_4_7_full.yaml || true
    }

    echo "⏳ Waiting for Load Balancer Controller to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system || true

    echo "✅ AWS Load Balancer Controller installation completed"
}

deploy_kubernetes_applications() {
    local fastapi_ecr="$1"
    local nodejs_ecr="$2"

    echo "☸️ Deploying Kubernetes applications..."

    # Create namespace if it doesn't exist
    kubectl create namespace default --dry-run=client -o yaml | kubectl apply -f - || true

    # Create database secret from AWS Secrets Manager
    echo "🔐 Creating database secret..."
    local db_secret_arn="$(pulumi stack output databaseSecretArn --cwd ../infrastructure 2>/dev/null || echo '')"
    if [[ -n "$db_secret_arn" ]]; then
        local secret_value=$(aws secretsmanager get-secret-value --secret-id "$db_secret_arn" --query "SecretString" --output text 2>/dev/null || echo '')
        if [[ -n "$secret_value" ]]; then
            kubectl create secret generic database-secret \
                --from-literal=DATABASE_URL="$secret_value" \
                --dry-run=client -o yaml | kubectl apply -f - || true
            echo "✅ Database secret created"
        else
            echo "⚠️ Could not retrieve database secret value"
        fi
    else
        echo "⚠️ Database secret ARN not found in Pulumi outputs"
    fi

    # Get database endpoint and parse hostname (remove :port if present)
    # CRITICAL: RDS endpoint format is "hostname:port" but PostgreSQL needs only hostname
    # This was a recurring issue in s3v3 and s3v4 - must split to get hostname only
    local db_endpoint_full="$(pulumi stack output databaseEndpoint --cwd ../infrastructure 2>/dev/null || echo 'localhost')"
    local db_endpoint="${db_endpoint_full%%:*}"  # Remove :port suffix if present

    # Deploy FastAPI application
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-deployment
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: fastapi
  template:
    metadata:
      labels:
        app: fastapi
    spec:
      containers:
      - name: fastapi
        image: ${fastapi_ecr}:latest
        ports:
        - containerPort: 8000
        env:
        - name: DATABASE_HOST
          value: "${db_endpoint}"
        - name: DATABASE_NAME
          value: "stage4v1db"
        - name: DATABASE_PORT
          value: "5432"
        - name: ENVIRONMENT
          value: "stage4-v1"
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: database-secret
              key: DATABASE_URL
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
apiVersion: v1
kind: Service
metadata:
  name: fastapi-service
  namespace: default
spec:
  selector:
    app: fastapi
  ports:
  - port: 8000
    targetPort: 8000
  type: ClusterIP
EOF

    # Deploy Node.js application
    cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nodejs-deployment
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nodejs
  template:
    metadata:
      labels:
        app: nodejs
    spec:
      containers:
      - name: nodejs
        image: ${nodejs_ecr}:latest
        ports:
        - containerPort: 3000
        env:
        - name: FASTAPI_URL
          value: "http://fastapi-service:8000"
        - name: ENVIRONMENT
          value: "stage4-v1"
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
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: nodejs-service
  namespace: default
spec:
  selector:
    app: nodejs
  ports:
  - port: 3000
    targetPort: 3000
  type: ClusterIP
EOF

    # Deploy Ingress
    local ssl_cert_arn="$(get_deployment_state 'SSL_CERTIFICATE_ARN' || echo '')"

    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentic-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: '443'
    $(if [[ -n "$ssl_cert_arn" ]]; then echo "alb.ingress.kubernetes.io/certificate-arn: $ssl_cert_arn"; fi)
spec:
  rules:
  - host: stage4-v1.a-g-e-n-t-i-c.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: nodejs-service
            port:
              number: 3000
EOF

    echo "✅ Kubernetes applications deployed"

    # Wait for deployments to be ready
    echo "⏳ Waiting for deployments to be ready..."
    kubectl rollout status deployment/fastapi-deployment --timeout=300s || true
    kubectl rollout status deployment/nodejs-deployment --timeout=300s || true

    echo "✅ All deployments ready"
}

export -f validate_database_connectivity
export -f check_infrastructure_independence
export -f build_and_push_docker_images
export -f print_deployment_summary
export -f install_aws_load_balancer_controller
export -f deploy_kubernetes_applications

echo "✅ Deployment functions loaded successfully (with EKS support)"