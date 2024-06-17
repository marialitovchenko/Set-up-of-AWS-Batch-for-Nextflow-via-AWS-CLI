#!/bin/bash
#
# DESCRIPTION:
#
# USAGE: Run in command line in Linux-like system
# OPTIONS: Run ./create_nextflow_launcher_ec2.sh.sh -h
#          to see the full list of options and their descriptions.
# REQUIREMENTS: AWS CLI & AWS profile profile with permissions to create users,
# user groups, security groups and ec2 instances.
# BUGS: --
# NOTES:
# AUTHOR:  Maria Litovchenko
# VERSION:  1
# CREATED:  16.06.2024
# REVISION: 16.06.2024
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
    echo "Bash script which creates EC2 instance to act as Nextflow launcher"
    echo "in the future."
    echo "Please check that AWS CLI is installed and configured prior to run."
    echo
    echo "Syntax: create_custom_ami.sh [-p|r|i|u|h]"
    echo "Arguments:"
    echo "p     [REQUIRED] AWS profile name. That profile should have"
    echo "      permissions to create users, user groups, security groups and"
    echo "      ec2 instances."
    echo "r     [REQUIRED] AWS region, i.e. eu-west-2. Put it in double "
    echo "      quotes."
    echo "t     [REQUIRED] AWS instance type, i.e. t3.2xlarge"
    echo "u     [REQUIRED] User name of the person executing this script."
    echo "i     [optional] User name to be given to a user under which "
    echo "       Nextflow will assess AWS batch. Default: nf-program-access-"
    echo "       plus value of -u argument."
    echo "e     [optional] Name of an EC2 instance to be created. Default: "
    echo "      nf-EC2- plus value of -u argument."
    echo "a     [optional] Name of the custom AMI to be used. Default:"
    echo "      ami-nf-aws-batch- plus value of -u argument"
    echo "h     Print this help."
    echo
}

# Reading command line arguments ----------------------------------------------
while getopts ":p:r:t:i:u:e:a:h" opt; do
    case $opt in
    p) AWS_PROFILE_NAME="$OPTARG" ;;
    r) AWS_REGION_NAME="$OPTARG" ;;
    t) INSTANCE_TYPE="$OPTARG" ;;
    u) EXECUTING_USER="$OPTARG" ;;
    i) IAM_USER_NAME="$OPTARG" ;;
    e) EC2_NAME="$OPTARG" ;;
    a) CUSTOM_AMI_NAME="$OPTARG" ;;
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
: "${INSTANCE_TYPE:?Missing -t}"
: "${EXECUTING_USER:?Missing -u}"
if [ -z "${EC2_NAME}" ]; then
    EC2_NAME="nf-EC2-"$EXECUTING_USER
fi
if [ -z "${IAM_USER_NAME}" ]; then
    IAM_USER_NAME=nf-program-access-$EXECUTING_USER
fi
if [ -z "${CUSTOM_AMI_NAME}" ]; then
    CUSTOM_AMI_NAME='ami-nf-aws-batch-'$EXECUTING_USER
fi

timestamp=$(date -I)
echo "[""$timestamp""] Input arguments:"
echo "               -p (AWS profile name): "$AWS_PROFILE_NAME
echo "               -r (AWS region): "$AWS_REGION_NAME
echo "               -t (EC2 insctance type): "$INSTANCE_TYPE
echo "               -i (IAM user name): "$IAM_USER_NAME
echo "               -u (Executing user ID): "$EXECUTING_USER
echo "               -e (Name to be given to EC2 instance): "$EC2_NAME
echo "               -a (Name of custom AMI to be used): "$CUSTOM_AMI_NAME

# Main script -----------------------------------------------------------------
# default values
KEY_PAIR_NAME=$EC2_NAME"-keypair"
EC2_DEFAULT_USER_NAME='ec2-user'

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1: get VPC ID, default subnet ID & security group ID -------------------
# In case your default subnet is private, you may need to use VPN to run this
# script. As everything done below is based on publicly accessible data and
# does not disclose any private data, use of public subnets is also fine.
read -r SUBNET_ID <<<"$(aws ec2 describe-subnets \
    --filters 'Name=default-for-az,Values=true' \
    --query 'Subnets[*].[SubnetId]' --output text | head -1)"

# get ID of a security group
read -r SECURITY_GROUP_ID <<<"$(aws ec2 describe-security-groups \
    --group-name $EC2_NAME --query "SecurityGroups[*].[GroupId]" \
    --output text)"

# Step 2: find out AMI ID -----------------------------------------------------
read -r CUSTOM_AMI_ID <<<"$(aws ec2 describe-images --owners self \
    --filters 'Name=name,Values='$CUSTOM_AMI_NAME --output text | cut -f8)"
timestamp=$(date -I)
echo "[""$timestamp""] Found ID for custom AMI "$CUSTOM_AMI_ID

# Step 3: Initialize EC2 instance which will serve as Nextflow launcher -------
read -r INSTANCE_ID <<<"$(aws ec2 run-instances --image-id $CUSTOM_AMI_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
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
aws ec2 create-tags --resources $INSTANCE_ID --tags Key=Name,Value=$EC2_NAME
# wait for the instance to be running
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

timestamp=$(date -I)
echo "[""$timestamp""] Created EC2 instance to hold Nextflow launcher from "$CUSTOM_AMI_ID

# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<"$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].PublicDnsName' \
    --output text)"

# get access & security key 
read -r ACCESS_KEY_ID ACCESS_KEY_SECRET <<<"$(aws iam create-access-key \
    --user-name $IAM_USER_NAME --output text | cut -f2,4)"

# transfer access & security key to the launcher instance
echo "[default]" > credentials
echo "aws_access_key_id = "$ACCESS_KEY_ID >> credentials
echo "aws_secret_access_key = "$ACCESS_KEY_SECRET >> credentials

echo "[default]" > config
echo "region = "$AWS_REGION_NAME >> config

scp -i $KEY_PAIR_NAME'.pem' credentials config \
  $EC2_DEFAULT_USER_NAME'@'$PUBLIC_DNS_NAME":/home/"$EC2_DEFAULT_USER_NAME"/.aws/"
rm credentials config

timestamp=$(date -I)
echo "[""$timestamp""] The Nextflow launcher EC2 instance is ready. You may "
echo "assess it via ssh:"
echo ssh -i $KEY_PAIR_NAME'.pem' $EC2_DEFAULT_USER_NAME'@'"$PUBLIC_DNS_NAME"
