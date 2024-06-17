#!/bin/bash
#
# DESCRIPTION: Bash script which deletes AWS Batch set up used for the Nextflow
# execution. This script does not delete custom AMI created for Nextflow use.
#
# USAGE: Run in command line in Linux-like system
# OPTIONS: Run ./clean_up_aws_batch.sh -h
#          to see the full list of options and their descriptions.
# REQUIREMENTS: AWS CLI & AWS profile profile with permissions to delete users,
# user groups, security groups and ec2 instances. 
#
# BUGS: --
# NOTES:
# AUTHOR:  Maria Litovchenko
# VERSION:  1
# CREATED:  17.06.2024
# REVISION: 17.06.2024
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
    echo "Bash script which deletes AWS Batch set up used for the Nextflow "
    echo "execution. Please check that AWS CLI is installed and configured "
    echo "prior to run."
    echo
    echo "Syntax: clean_up_aws_batch.sh [-p|r|u|a|i|g|e|c|j|h]"
    echo "Arguments:"
    echo "p     [REQUIRED] AWS profile name. That profile should have"
    echo "      permissions to delete users, user groups, security groups and"
    echo "      ec2 instances."
    echo "r     [REQUIRED] AWS region, i.e. eu-west-2. Put it in double "
    echo "      quotes."
    echo "u     [REQUIRED] User name of the person executing this script."
    echo "i     [optional] User name of a user under which Nextflow assessed" 
    echo "      AWS batch. Default: nf-program-access- plus value of -u"
    echo "      argument."
    echo "g     [optional] User group name to which user under which Nextflow"
    echo "      assessed AWS batch was assigned to. Default: nf-group- plus"
    echo "      value of -u argument."
    echo "e     [optional] Name of an EC2 instance on which Nextflow launcher"
    echo "      was set. Default: nf-EC2- plus value of -u argument."
    echo "c     [optional] Name of the AWS Batch compute environment under"
    echo "      which Nextflow had run jobs. Default: nf-aws-batch- plus"
    echo "      value of -u argument."
    echo "j     [optional] Name of the AWS Batch job queue under which"
    echo "      Nextflow had run jobs. Default: nf-queue- plus value of -u"
    echo "      argument."
    echo "h     Print this help."
}

# Reading command line arguments ----------------------------------------------
while getopts ":p:r:u:i:g:e:c:j:h" opt; do
    case $opt in
    p) AWS_PROFILE_NAME="$OPTARG" ;;
    r) AWS_REGION_NAME="$OPTARG" ;;
    u) EXECUTING_USER="$OPTARG" ;;
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

if [ -z "${EC2_NAME}" ]; then
    EC2_NAME="nf-EC2-"$EXECUTING_USER
fi
if [ -z "${IAM_USER_NAME}" ]; then
    IAM_USER_NAME=nf-program-access-$EXECUTING_USER
fi
if [ -z "${IAM_GROUP_NAME}" ]; then
    IAM_GROUP_NAME=nf-group-$EXECUTING_USER
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
echo "               -i (User name under which Nextflow accessed"
echo "                   AWS Batch): "$IAM_USER_NAME
echo "               -g (User group name of user group under which"
echo "                   Nextflow accessed AWS Batch): "$IAM_GROUP_NAME
echo "               -e (EC2 instance name holding Nextflow launcher): "$EC2_NAME
echo "               -c (Name of AWS Batch compute environment): "
echo "                   "$BATCH_COMPUTE_ENV_NAME
echo "               -j (Name of AWS Batch job queue): "$BATCH_JOB_QUEUE_NAME

# Main script -----------------------------------------------------------------
# default values
KEY_PAIR_NAME=$EC2_NAME"-keypair"
IAM_ROLE_NAME=AmazonEC2SpotFleetRole

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Terminate EC2 holding Nextflow launcher -------------------------------------
# get instance ID by name
read -r INSTANCE_ID <<<"$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values="$EC2_NAME \
  --query 'Reservations[*].Instances[*].{Instance:InstanceId}' \
  --output text)"
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
sleep 60
timestamp=$(date -I)
echo "[""$timestamp""] Terminated EC2 instance holding Nextflow launcher: "$INSTANCE_ID

# Terminate AWS batch queue and compute environment ---------------------------
aws batch update-job-queue --job-queue $BATCH_JOB_QUEUE_NAME --state DISABLED
sleep 30
aws batch delete-job-queue --job-queue $BATCH_JOB_QUEUE_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted AWS batch job-queue: "$BATCH_JOB_QUEUE_NAME

aws batch update-compute-environment \
  --compute-environment $BATCH_COMPUTE_ENV_NAME \
  --state DISABLED
sleep 90
aws batch delete-compute-environment \
  --compute-environment $BATCH_COMPUTE_ENV_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted AWS batch compute environment : "$BATCH_COMPUTE_ENV_NAME

# Delete security group -------------------------------------------------------
read -r SECURITY_GROUP_ID <<<"$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values="$EC2_NAME \
  --query 'SecurityGroups[*].[GroupId]' --output text)"
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID
timestamp=$(date -I)
echo "[""$timestamp""] Deleted security group : "$SECURITY_GROUP_ID

# Delete role for spot fleet --------------------------------------------------
aws iam detach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole
aws iam detach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role
aws iam detach-role-policy --role-name $IAM_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam delete-role --role-name $IAM_ROLE_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted role : "$IAM_ROLE_NAME

# Delete user group -----------------------------------------------------------
aws iam remove-user-from-group --user-name $IAM_USER_NAME \
    --group-name $IAM_GROUP_NAME
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly
aws iam delete-group --group-name $IAM_GROUP_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted role : "$IAM_ROLE_NAME

# Delete user -----------------------------------------------------------------
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME
rm -rf $KEY_PAIR_NAME".pem"
timestamp=$(date -I)
echo "[""$timestamp""] Deleted key pair : "$KEY_PAIR_NAME

read -r ACCESS_KEY_ID <<<"$(aws iam list-access-keys --user $IAM_USER_NAME \
  --query 'AccessKeyMetadata[*].[AccessKeyId]' --output text)"
aws iam delete-access-key --access-key-id $ACCESS_KEY_ID \
    --user-name $IAM_USER_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted access key : "$KEY_PAIR_NAME

aws iam delete-user --user-name $IAM_USER_NAME
timestamp=$(date -I)
echo "[""$timestamp""] Deleted user : "$IAM_USER_NAME

timestamp=$(date -I)
echo "[""$timestamp""] ATTENTION: the script does not delete created custom"
echo "AMI or S3 bucket."
echo "[""$timestamp""] Finished!"
