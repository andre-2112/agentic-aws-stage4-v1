import * as pulumi from "@pulumi/pulumi";
import * as aws from "@pulumi/aws";
import * as awsx from "@pulumi/awsx";
import * as eks from "@pulumi/eks";

// Get configuration
const config = new pulumi.Config();
const projectName = config.require("project-name");
const environment = config.require("environment");
const vpcCidr = config.require("vpc-cidr");
const availabilityZones = config.requireObject<string[]>("availability-zones");
const domainName = config.require("domain-name");
const subdomain = config.require("subdomain");
const dbInstanceClass = config.require("db-instance-class");
const dbAllocatedStorage = config.requireNumber("db-allocated-storage");
const dbName = config.require("db-name");
const dbBackupRetention = config.requireNumber("db-backup-retention");
const podCpu = config.require("pod-cpu");
const podMemory = config.require("pod-memory");
const desiredCount = config.requireNumber("desired-count");
const minCapacity = config.requireNumber("min-capacity");
const maxCapacity = config.requireNumber("max-capacity");
const logRetentionDays = config.requireNumber("log-retention-days");

// Resource naming function with length limits
function createResourceName(resourceType: string, uniqueSuffix?: string, maxLength?: number): string {
    const suffix = uniqueSuffix || "";
    const baseName = `${projectName}-${resourceType}${suffix ? `-${suffix}` : ""}`;

    // Apply length limit if specified
    if (maxLength && baseName.length > maxLength) {
        // For ALBs and other length-limited resources, use abbreviated naming
        const shortProject = "ag-s4v1"; // Abbreviated version of agentic-aws-stage4-v1
        const shortName = `${shortProject}-${resourceType}${suffix ? `-${suffix}` : ""}`;

        if (shortName.length > maxLength) {
            // Further abbreviate if still too long
            const veryShortName = `${shortProject}-${resourceType.substr(0, 6)}${suffix ? `-${suffix}` : ""}`;
            return veryShortName.substr(0, maxLength);
        }
        return shortName;
    }

    return baseName;
}

// =============================
// VPC AND NETWORKING
// =============================

// Create VPC
const vpc = new aws.ec2.Vpc(createResourceName("vpc"), {
    cidrBlock: vpcCidr,
    enableDnsHostnames: true,
    enableDnsSupport: true,
    tags: {
        Name: createResourceName("vpc"),
        Project: projectName,
        Environment: environment,
        "kubernetes.io/role/elb": "1", // Required for EKS load balancers
    },
});

// Create Internet Gateway
const internetGateway = new aws.ec2.InternetGateway(createResourceName("igw"), {
    vpcId: vpc.id,
    tags: {
        Name: createResourceName("igw"),
        Project: projectName,
        Environment: environment,
    },
});

// Create subnets with proper EKS tags
const publicSubnet1 = new aws.ec2.Subnet(createResourceName("public-subnet", "1"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.1.0/24",
    availabilityZone: availabilityZones[0],
    mapPublicIpOnLaunch: true,
    tags: {
        Name: createResourceName("public-subnet", "1"),
        Project: projectName,
        Environment: environment,
        Type: "Public",
        "kubernetes.io/role/elb": "1", // Required for public load balancers
        "kubernetes.io/cluster/agentic-aws-stage4-v1-cluster": "shared",
    },
});

const publicSubnet2 = new aws.ec2.Subnet(createResourceName("public-subnet", "2"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.2.0/24",
    availabilityZone: availabilityZones[1],
    mapPublicIpOnLaunch: true,
    tags: {
        Name: createResourceName("public-subnet", "2"),
        Project: projectName,
        Environment: environment,
        Type: "Public",
        "kubernetes.io/role/elb": "1", // Required for public load balancers
        "kubernetes.io/cluster/agentic-aws-stage4-v1-cluster": "shared",
    },
});

const privateSubnet1 = new aws.ec2.Subnet(createResourceName("private-subnet", "1"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.3.0/24",
    availabilityZone: availabilityZones[0],
    tags: {
        Name: createResourceName("private-subnet", "1"),
        Project: projectName,
        Environment: environment,
        Type: "Private",
        "kubernetes.io/role/internal-elb": "1", // Required for internal load balancers
        "kubernetes.io/cluster/agentic-aws-stage4-v1-cluster": "owned",
    },
});

const privateSubnet2 = new aws.ec2.Subnet(createResourceName("private-subnet", "2"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.4.0/24",
    availabilityZone: availabilityZones[1],
    tags: {
        Name: createResourceName("private-subnet", "2"),
        Project: projectName,
        Environment: environment,
        Type: "Private",
        "kubernetes.io/role/internal-elb": "1", // Required for internal load balancers
        "kubernetes.io/cluster/agentic-aws-stage4-v1-cluster": "owned",
    },
});

const dbSubnet1 = new aws.ec2.Subnet(createResourceName("db-subnet", "1"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.5.0/24",
    availabilityZone: availabilityZones[0],
    tags: {
        Name: createResourceName("db-subnet", "1"),
        Project: projectName,
        Environment: environment,
        Type: "Database",
    },
});

const dbSubnet2 = new aws.ec2.Subnet(createResourceName("db-subnet", "2"), {
    vpcId: vpc.id,
    cidrBlock: "10.4.6.0/24",
    availabilityZone: availabilityZones[1],
    tags: {
        Name: createResourceName("db-subnet", "2"),
        Project: projectName,
        Environment: environment,
        Type: "Database",
    },
});

// Create Elastic IP for NAT Gateway
const natEip = new aws.ec2.Eip(createResourceName("nat-eip"), {
    domain: "vpc",
    tags: {
        Name: createResourceName("nat-eip"),
        Project: projectName,
        Environment: environment,
    },
});

// Create NAT Gateway
const natGateway = new aws.ec2.NatGateway(createResourceName("nat"), {
    allocationId: natEip.id,
    subnetId: publicSubnet1.id,
    tags: {
        Name: createResourceName("nat"),
        Project: projectName,
        Environment: environment,
    },
});

// Create route tables
const publicRouteTable = new aws.ec2.RouteTable(createResourceName("public-rt"), {
    vpcId: vpc.id,
    routes: [{
        cidrBlock: "0.0.0.0/0",
        gatewayId: internetGateway.id,
    }],
    tags: {
        Name: createResourceName("public-rt"),
        Project: projectName,
        Environment: environment,
    },
});

const privateRouteTable = new aws.ec2.RouteTable(createResourceName("private-rt"), {
    vpcId: vpc.id,
    routes: [{
        cidrBlock: "0.0.0.0/0",
        natGatewayId: natGateway.id,
    }],
    tags: {
        Name: createResourceName("private-rt"),
        Project: projectName,
        Environment: environment,
    },
});

const dbRouteTable = new aws.ec2.RouteTable(createResourceName("db-rt"), {
    vpcId: vpc.id,
    tags: {
        Name: createResourceName("db-rt"),
        Project: projectName,
        Environment: environment,
    },
});

// Route table associations
new aws.ec2.RouteTableAssociation("public-subnet-1-rt-assoc", {
    subnetId: publicSubnet1.id,
    routeTableId: publicRouteTable.id,
});

new aws.ec2.RouteTableAssociation("public-subnet-2-rt-assoc", {
    subnetId: publicSubnet2.id,
    routeTableId: publicRouteTable.id,
});

new aws.ec2.RouteTableAssociation("private-subnet-1-rt-assoc", {
    subnetId: privateSubnet1.id,
    routeTableId: privateRouteTable.id,
});

new aws.ec2.RouteTableAssociation("private-subnet-2-rt-assoc", {
    subnetId: privateSubnet2.id,
    routeTableId: privateRouteTable.id,
});

new aws.ec2.RouteTableAssociation("db-subnet-1-rt-assoc", {
    subnetId: dbSubnet1.id,
    routeTableId: dbRouteTable.id,
});

new aws.ec2.RouteTableAssociation("db-subnet-2-rt-assoc", {
    subnetId: dbSubnet2.id,
    routeTableId: dbRouteTable.id,
});

// =============================
// SECURITY GROUPS
// =============================

// EKS Cluster Security Group (additional rules)
const eksClusterSg = new aws.ec2.SecurityGroup(createResourceName("eks-cluster-sg"), {
    vpcId: vpc.id,
    description: "Additional security group for EKS cluster",
    egress: [{
        protocol: "-1",
        fromPort: 0,
        toPort: 0,
        cidrBlocks: ["0.0.0.0/0"],
    }],
    tags: {
        Name: createResourceName("eks-cluster-sg"),
        Project: projectName,
        Environment: environment,
    },
});

// Database Security Group
const dbSg = new aws.ec2.SecurityGroup(createResourceName("db-sg"), {
    vpcId: vpc.id,
    description: "Security group for PostgreSQL database",
    egress: [],
    tags: {
        Name: createResourceName("db-sg"),
        Project: projectName,
        Environment: environment,
    },
});

// Allow EKS pods to access database
new aws.ec2.SecurityGroupRule("db-sg-ingress-from-eks", {
    type: "ingress",
    fromPort: 5432,
    toPort: 5432,
    protocol: "tcp",
    sourceSecurityGroupId: eksClusterSg.id,
    securityGroupId: dbSg.id,
});

// =============================
// RDS DATABASE
// =============================

// Create DB subnet group
const dbSubnetGroup = new aws.rds.SubnetGroup(createResourceName("db-subnet-group"), {
    subnetIds: [dbSubnet1.id, dbSubnet2.id],
    tags: {
        Name: createResourceName("db-subnet-group"),
        Project: projectName,
        Environment: environment,
    },
});

// Create DB parameter group
const dbParameterGroup = new aws.rds.ParameterGroup(createResourceName("db-parameter-group"), {
    family: "postgres15",
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// Create primary RDS instance
const dbInstance = new aws.rds.Instance(createResourceName("primary"), {
    identifier: createResourceName("primary"),
    engine: "postgres",
    engineVersion: "15.13",
    instanceClass: dbInstanceClass,
    allocatedStorage: dbAllocatedStorage,
    storageType: "gp3",
    storageEncrypted: true,
    multiAz: true,
    dbName: dbName,
    username: "postgres",
    manageMasterUserPassword: true,
    masterUserSecretKmsKeyId: "alias/aws/secretsmanager",
    vpcSecurityGroupIds: [dbSg.id],
    dbSubnetGroupName: dbSubnetGroup.name,
    parameterGroupName: dbParameterGroup.name,
    backupRetentionPeriod: dbBackupRetention,
    backupWindow: "03:00-04:00",
    maintenanceWindow: "sun:04:00-sun:05:00",
    autoMinorVersionUpgrade: true,
    deletionProtection: false,
    skipFinalSnapshot: true,
    tags: {
        Name: createResourceName("primary"),
        Project: projectName,
        Environment: environment,
    },
});

// Note: PostgreSQL read replicas are not supported with AWS managed master passwords
// This is a known limitation of RDS PostgreSQL with managed passwords

// =============================
// ECR REPOSITORIES
// =============================

// FastAPI ECR repository
const fastapiRepo = new aws.ecr.Repository(createResourceName("fastapi"), {
    name: createResourceName("fastapi"),
    imageScanningConfiguration: {
        scanOnPush: true,
    },
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// Node.js ECR repository
const nodejsRepo = new aws.ecr.Repository(createResourceName("nodejs"), {
    name: createResourceName("nodejs"),
    imageScanningConfiguration: {
        scanOnPush: true,
    },
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// =============================
// EKS CLUSTER
// =============================

// Create IAM role for EKS cluster
const eksRole = new aws.iam.Role(createResourceName("eks-cluster-role"), {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Action: "sts:AssumeRole",
            Effect: "Allow",
            Principal: {
                Service: "eks.amazonaws.com",
            },
        }],
    }),
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// Attach required policies to EKS cluster role
new aws.iam.RolePolicyAttachment(createResourceName("eks-cluster-policy"), {
    role: eksRole.name,
    policyArn: "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
});

// Create EKS cluster
const cluster = new aws.eks.Cluster(createResourceName("cluster"), {
    name: createResourceName("cluster"),
    version: "1.28",
    roleArn: eksRole.arn,
    vpcConfig: {
        subnetIds: [
            publicSubnet1.id,
            publicSubnet2.id,
            privateSubnet1.id,
            privateSubnet2.id,
        ],
        securityGroupIds: [eksClusterSg.id],
        endpointPrivateAccess: true,
        endpointPublicAccess: true,
    },
    enabledClusterLogTypes: [
        "api",
        "audit",
        "authenticator",
        "controllerManager",
        "scheduler",
    ],
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// =============================
// EKS FARGATE PROFILE
// =============================

// Create IAM role for Fargate profile
const fargateRole = new aws.iam.Role(createResourceName("fargate-execution-role"), {
    assumeRolePolicy: JSON.stringify({
        Version: "2012-10-17",
        Statement: [{
            Action: "sts:AssumeRole",
            Effect: "Allow",
            Principal: {
                Service: "eks-fargate-pods.amazonaws.com",
            },
        }],
    }),
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// Attach required policy to Fargate execution role
new aws.iam.RolePolicyAttachment(createResourceName("fargate-pod-execution-policy"), {
    role: fargateRole.name,
    policyArn: "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy",
});

// Create Fargate profile
const fargateProfile = new aws.eks.FargateProfile(createResourceName("fargate-profile"), {
    clusterName: cluster.name,
    fargateProfileName: createResourceName("fargate-profile"),
    podExecutionRoleArn: fargateRole.arn,
    subnetIds: [privateSubnet1.id, privateSubnet2.id],
    selectors: [{
        namespace: "default",
    }, {
        namespace: "kube-system",
    }],
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// =============================
// SSL CERTIFICATE
// =============================

const certificate = new aws.acm.Certificate(createResourceName("ssl-cert"), {
    domainName: `${subdomain}.${domainName}`,
    validationMethod: "DNS",
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// =============================
// CLOUDWATCH LOG GROUPS
// =============================

const fastapiLogGroup = new aws.cloudwatch.LogGroup(createResourceName("fastapi-logs"), {
    name: createResourceName("fastapi-logs"),
    retentionInDays: logRetentionDays,
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

const nodejsLogGroup = new aws.cloudwatch.LogGroup(createResourceName("nodejs-logs"), {
    name: createResourceName("nodejs-logs"),
    retentionInDays: logRetentionDays,
    tags: {
        Project: projectName,
        Environment: environment,
    },
});

// =============================
// ROUTE 53 DNS
// =============================

// Get the hosted zone (assumes it exists)
const hostedZone = aws.route53.getZone({
    name: domainName,
    privateZone: false,
});

// =============================
// EXPORTS
// =============================

export const vpcId = vpc.id;
export const publicSubnetIds = [publicSubnet1.id, publicSubnet2.id];
export const privateSubnetIds = [privateSubnet1.id, privateSubnet2.id];
export const databaseSubnetIds = [dbSubnet1.id, dbSubnet2.id];
export const eksClusterId = cluster.name;
export const eksClusterEndpoint = cluster.endpoint;
export const eksClusterSecurityGroupId = eksClusterSg.id;
export const databaseEndpoint = dbInstance.endpoint;
// Replica endpoint removed - PostgreSQL replicas not supported with managed master passwords
export const fastapiRepositoryUrl = fastapiRepo.repositoryUrl;
export const nodejsRepositoryUrl = nodejsRepo.repositoryUrl;
export const applicationUrl = pulumi.interpolate`https://${subdomain}.${domainName}`;
export const databaseSecretArn = dbInstance.masterUserSecrets.apply((secrets: any) => secrets?.[0]?.secretArn || "");
export const sslCertificateArn = certificate.arn;