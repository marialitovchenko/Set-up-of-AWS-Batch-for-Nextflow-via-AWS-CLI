#!/bin/bash
#
# DESCRIPTION: Bash script which creates AWS Batch for the Nextflow execution.
# It also creates S3 bucket which will store the results of Nextflow pipeline
# execution. Custom AMI created by create_custom_ami.sh is required.
#
# USAGE: Run in command line in Linux-like system
# OPTIONS: Run ./configure_aws_batch.sh -h
#          to see the full list of options and their descriptions.
# REQUIREMENTS: AWS CLI & AWS profile profile with permissions to create users,
# user groups, security groups and ec2 instances. Custom AMI to be used under
# Nextlow.
#
# BUGS: --
# NOTES:
# AUTHOR:  Maria Litovchenko
# VERSION:  1
# CREATED:  15.06.2024
# REVISION: 15.06.2024
#
#  Copyright (C) 2024, 2024 Maria Litovchenko m.litovchenko@gmail.com
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License as published by the
#  Free Software Foundation; either version 2 of the License, or (at your
#   option) any later version.
#
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
#  more details.

# Help function ---------------------------------------------------------------
Help() {
    # Display Help
    echo "Bash script which creates AWS Batch and S3 bucket for the Nextflow "
    echo "execution. Please check that AWS CLI is installed and configured "
    echo "prior to run."
    echo
    echo "Syntax: configure_aws_batch.sh [-p|r|u|a|i|g|e|c|j|h]"
    echo "Arguments:"
    echo "p     [REQUIRED] AWS profile name. That profile should have"
    echo "      permissions to create users, user groups, security groups and"
    echo "      ec2 instances."
    echo "r     [REQUIRED] AWS region, i.e. eu-west-2. Put it in double "
    echo "      quotes."
    echo "u     [REQUIRED] User name of the person executing this script."
    echo "b     [REQUIRED] A name for S3 bucket to store files in."
    echo "a     [optional] Name of custom AMI with installed at least Docker,"
    echo "      ecs and AWS CLI. Default: ami-nf-aws-batch- plus value of -u"
    echo "      argument."
    echo "i     [optional] User name to be given to the new user under which"
    echo "      Nextflow will assess AWS batch. Default: nf-program-access-"
    echo "      plus value of -u argument."
    echo "g     [optional] User group name to be given to the new user group"
    echo "      under which Nextflow will assess AWS batch. Default:"
    echo "      nf-group- plus value of -u argument."
    echo "e     [optional] Name of an EC2 instance. Default: nf-EC2- plus"
    echo "      value of -u argument."
    echo "c     [optional] Name of the new AWS Batch compute environment under"
    echo "      which Nextflow will run jobs. Default: nf-aws-batch- plus"
    echo "      value of -u argument."
    echo "j     [optional] Name of the new AWS Batch job queue under which"
    echo "      Nextflow will run jobs. Default: nf-queue- plus value of -u"
    echo "      argument."
    echo "h     Print this help."
    echo
}

# Reading command line arguments ----------------------------------------------
while getopts ":p:r:u:a:i:g:e:c:j:b:h" opt; do
    case $opt in
    p) AWS_PROFILE_NAME="$OPTARG" ;;
    r) AWS_REGION_NAME="$OPTARG" ;;
    u) EXECUTING_USER="$OPTARG" ;;
    b) S3_BUCKET_NAME="$OPTARG" ;;
    a) CUSTOM_AMI_NAME="$OPTARG" ;;
    i) IAM_USER_NAME="$OPTARG" ;;
    g) IAM_GROUP_NAME="$OPTARG" ;;
    e) EC2_NAME="$OPTARG" ;;
    c) BATCH_COMPUTE_ENV_NAME="$OPTARG" ;;
    j) BATCH_JOB_QUEUE_NAME="$OPTARG" ;;
    h)
        Help
        exit
        ;;
    \?)
        echo "Invalid option -$OPTARG" >&2
        Help
        exit 1
        ;;
    esac
done

shift "$((OPTIND - 1))"

: "${AWS_PROFILE_NAME:?Missing -p}"
: "${AWS_REGION_NAME:?Missing -r}"
: "${EXECUTING_USER:?Missing -u}"
: "${S3_BUCKET_NAME:?Missing -b}"

if [ -z "${CUSTOM_AMI_NAME}" ]; then
    CUSTOM_AMI_NAME="ami-nf-aws-batch-"$EXECUTING_USER
fi
if [ -z "${IAM_USER_NAME}" ]; then
    IAM_USER_NAME=nf-program-access-$EXECUTING_USER
fi
if [ -z "${IAM_GROUP_NAME}" ]; then
    IAM_GROUP_NAME=nf-group-$EXECUTING_USER
fi
if [ -z "${EC2_NAME}" ]; then
    EC2_NAME="nf-EC2-"$EXECUTING_USER
fi
if [ -z "${BATCH_COMPUTE_ENV_NAME}" ]; then
    BATCH_COMPUTE_ENV_NAME="nf-aws-batch-"$EXECUTING_USER
fi
if [ -z "${BATCH_JOB_QUEUE_NAME}" ]; then
    BATCH_JOB_QUEUE_NAME="nf-queue-"$EXECUTING_USER
fi

timestamp=$(date -I)
echo "[""$timestamp""] Input arguments:"
echo "               -p (AWS profile name): "$AWS_PROFILE_NAME
echo "               -r (AWS region): "$AWS_REGION_NAME
echo "               -u (Executing user ID): "$EXECUTING_USER
echo "               -b (S3 bucket name): "$S3_BUCKET_NAME
echo "               -a (Name of custom AMI): "$CUSTOM_AMI_NAME
echo "               -i (User name to be given to user under which Nextflow"
echo "                   will access AWS Batch): "$IAM_USER_NAME
echo "               -g (User group name to be given to user group under which"
echo "                    Nextflow will access AWS Batch): "$IAM_GROUP_NAME
echo "               -e (Name to be given to EC2 instance): "$EC2_NAME
echo "               -c (Name of the new AWS Batch compute environment): "
echo "                 "$BATCH_COMPUTE_ENV_NAME
echo "               -j (Name of the new AWS Batch job queue): "
echo "                 "$BATCH_JOB_QUEUE_NAME

# Main script -----------------------------------------------------------------
# default values
IAM_ROLE_NAME=AmazonEC2SpotFleetRole
KEY_PAIR_NAME=$EC2_NAME"-keypair"
rm -rf $KEY_PAIR_NAME'.pem'

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1: set up a Nextflow user with IAM -------------------------------------
# create a user
aws iam create-user --user-name $IAM_USER_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Created user "$IAM_USER_NAME

# create a user group
aws iam create-group --group-name $IAM_GROUP_NAME
# attach access policies to user group
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
timestamp=$(date -I)
echo "[""$timestamp""] Created user group "$IAM_GROUP_NAME
aws iam add-user-to-group --user-name $IAM_USER_NAME \
    --group-name $IAM_GROUP_NAME

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
timestamp=$(date -I)
echo "[""$timestamp""] Created role "$IAM_ROLE_NAME

# Step 2: get VPC ID and default subnet ID ------------------------------------
# In case your default subnet is private, you may need to use VPN to run this
# script. As everything done below is based on publicly accessible data and
# does not disclose any private data, use of public subnets is also fine.
read -r SUBNET_ID VPC_ID <<<"$(aws ec2 describe-subnets \
    --filters 'Name=default-for-az,Values=true' \
    --query 'Subnets[*].[SubnetId, VpcId]' \
    --output text | head -1)"
# create a security group
read -r SECURITY_GROUP_ID <<<"$(aws ec2 create-security-group \
    --group-name $EC2_NAME \
    --description $EC2_NAME' security group' \
    --vpc-id $VPC_ID \
    --output text)"
# add rules to security group: allow inbound traffic on TCP port 22 to support SSH connections
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 22 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 22 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 80 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 80 --cidr '0.0.0.0/0'
timestamp=$(date -I)
echo "[""$timestamp""] Created security group "$EC2_NAME

# Step 3: define & create AWS Batch compute environment -----------------------
# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
    --query 'KeyMaterial' --output text >$KEY_PAIR_NAME".pem"
chmod 400 $KEY_PAIR_NAME".pem"
timestamp=$(date -I)
echo "[""$timestamp""] Created key pair "$KEY_PAIR_NAME

# find out AMI ID
read -r CUSTOM_AMI_ID <<<"$(aws ec2 describe-images --owners self \
    --filters 'Name=name,Values='$CUSTOM_AMI_NAME \
    --output text | cut -f8)"
timestamp=$(date -I)
echo "[""$timestamp""] Found ID for custom AMI "$CUSTOM_AMI_ID

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
sleep 60
timestamp=$(date -I)
echo "[""$timestamp""] Created compute environment ""$BATCH_COMPUTE_ENV_NAME"

# Step 4: create an AWS Batch job queue ---------------------------------------
aws batch create-job-queue --job-queue-name $BATCH_JOB_QUEUE_NAME \
    --state ENABLED --priority 1 \
    --compute-environment-order '
                           [
                                {
                                    "order": 1,
                                    "computeEnvironment": "'$BATCH_COMPUTE_ENV_NAME'"
                                }
                            ]'
timestamp=$(date -I)
echo "[""$timestamp""] Created job queue ""$BATCH_JOB_QUEUE_NAME"

# Step 5: create up an S3 bucket for data storage -----------------------------
aws s3api create-bucket --bucket "$S3_BUCKET_NAME" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION_NAME"
timestamp=$(date -I)
echo "[""$timestamp""] Created S3 bucket: ""$BATCH_JOB_QUEUE_NAME"

timestamp=$(date -I)
echo "[""$timestamp""] Success!"