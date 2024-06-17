#!/bin/bash
AWS_PROFILE_NAME="ngs_workflows_dev"
AWS_REGION_NAME="eu-west-2"
LAUNCHER_INSTANCE_TYPE="t2.medium"
EXECUTING_USER="ml"
S3_BUCKET_NAME="nf-test"

IAM_USER_NAME=nf-program-access-$EXECUTING_USER
IAM_GROUP_NAME=nf-group-$EXECUTING_USER
EC2_NAME="nf-EC2-"$EXECUTING_USER

KEY_PAIR_NAME=$EC2_NAME"-keypair"
CUSTOM_AMI_NAME="ami-nf-aws-batch-"$EXECUTING_USER
BATCH_COMPUTE_ENV_NAME="nf-aws-batch-"$EXECUTING_USER
BATCH_JOB_QUEUE_NAME="nf-queue-"$EXECUTING_USER

IAM_ROLE_NAME=AmazonEC2SpotFleetRole
EC2_DEFAULT_USER_NAME="ec2-user"

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1 Setting up a Nextflow user with IAM
# create a user
aws iam create-user --user-name $IAM_USER_NAME

# create a user group
aws iam create-group --group-name $IAM_GROUP_NAME
aws iam add-user-to-group --user-name $IAM_USER_NAME \
    --group-name $IAM_GROUP_NAME
# attach access policies to user group
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# create permission roles for running AWS Batch
aws iam create-role --role-name $IAM_ROLE_NAME \
    --assume-role-policy-document '{
                                    "Version":"2012-10-17",
                                    "Statement":[
                                        {
                                            "Sid":"",
                                            "Effect":"Allow",
                                            "Principal": {
                                                "Service":"spotfleet.amazonaws.com"
                                            },
                                            "Action":"sts:AssumeRole"
                                        }]
                                    }'
aws iam attach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole
aws iam attach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
aws iam attach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

# Step 2: create security group
# get VPC ID and PUBLIC(!) subnet ID. If subnet is not public and doesn't allow
# map of public ip on launch, we won't be able to ssh to it.
read -r SUBNET_ID VPC_ID <<<"$(aws ec2 describe-subnets --filters 'Name=map-public-ip-on-launch,Values=true' \
    --query 'Subnets[*].[SubnetId, VpcId]' \
    --output text | head -1)"
# create a security group
read -r SECURITY_GROUP_ID <<<"$(aws ec2 create-security-group --group-name $EC2_NAME \
    --description $EC2_NAME" security group" \
    --vpc-id $VPC_ID \
    --output text)"
# add rules to security group: allow inbound traffic on TCP port 22 to support
# SSH connections
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 80 --cidr "0.0.0.0/0"

# Step 3: define & create AWS Batch compute environment
# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
    --query 'KeyMaterial' --output text >$KEY_PAIR_NAME".pem"
chmod 400 $KEY_PAIR_NAME".pem"
# find out AMI ID
read -r CUSTOM_AMI_ID <<<"$(aws ec2 describe-images --owners self \
    --filters 'Name=name,Values='$CUSTOM_AMI_NAME \
    --output text | cut -f8)"
batch_compute_config='{
                        "type": "SPOT",
                        "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
                        "minvCpus": 0,
                        "desiredvCpus": 0,
                        "maxvCpus": 1024,
                        "instanceTypes": ["optimal"],
                        "imageId": "'$CUSTOM_AMI_ID'",
                        "subnets": ["'$SUBNET_ID'"],
                        "securityGroupIds": ["'$SECURITY_GROUP_ID'"],
                        "ec2KeyPair": "'$KEY_PAIR_NAME'",
                        "instanceRole": "ecsInstanceRole",
                        "bidPercentage": 99,
                        "spotIamFleetRole": "AmazonEC2SpotFleetRole"
                     }'
# create the compute environment
aws batch create-compute-environment \
    --compute-environment-name $BATCH_COMPUTE_ENV_NAME \
    --state ENABLED --type MANAGED \
    --compute-resources "$batch_compute_config"
sleep 30

# Step 4: create an AWS Batch job queue
aws batch create-job-queue --job-queue-name $BATCH_JOB_QUEUE_NAME \
    --state ENABLED --priority 1 \
    --compute-environment-order '
                           [
                                {
                                    "order": 1,
                                    "computeEnvironment": "'$BATCH_COMPUTE_ENV_NAME'"
                                }
                            ]'

# Step 5: create up an S3 bucket for data storage
aws s3api create-bucket --bucket $EXECUTING_USER'-'$S3_BUCKET_NAME \
    --create-bucket-configuration LocationConstraint=$AWS_REGION_NAME

# Step 6: create EC2 which will hold nextflow launcher. We will use custom AMI
# created previously as base, and will install nextflow on it.
read -r INSTANCE_ID <<<"$(aws ec2 run-instances --image-id "$CUSTOM_AMI_ID" \
    --count 1 \
    --instance-type $LAUNCHER_INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --subnet-id "$SUBNET_ID" \
    --block-device-mappings '[
                                {
                                    "DeviceName": "/dev/xvda",
                                    "Ebs": {
                                        "VolumeSize": 100,
                                        "VolumeType": "standard",
                                        "DeleteOnTermination": true
                                    }
                                }
                            ]' \
    --output text \
    --query 'Instances[*].[InstanceId]')"
# rename instance
aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=$EC2_NAME
# wait for the instance to be running
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID
# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<"$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --query 'Reservations[].Instances[].PublicDnsName' \
    --output text)"

# Step 6: inform user about the next steps
echo "AWS BATCH for Nextflow is successfully set up."
echo "EC2 machine which will hold Nextflow launcher is successfully set up."
echo "Here are your next steps: "
echo "  Retrieve & record the access key and access key secret for ""$IAM_USER_NAME"" by running:"

# login to ec2
aws configure

sudo yum install git-all -y
sudo yum install zip unzip -y
 
nextflow pull rnaseq-nf
nextflow -C nextflow.config run rnaseq-nf \
    -profile batch \
    --output s3://ml-nf-test/rnaseq-nf/results/ \
    -resume

# NOT NEEDED
read -r IAM_USER_ID <<<"$(aws iam list-users --query 'Users[*].[UserName, UserId]' \
    --output text | grep $IAM_USER_NAME | cut -f2)"

# get access keys
read -r ACCESS_KEY_ID ACCESS_KEY_SECRET <<<"$(aws iam create-access-key \
    --user-name $IAM_USER_NAME \
    --output text |
    cut -f2,4)"
