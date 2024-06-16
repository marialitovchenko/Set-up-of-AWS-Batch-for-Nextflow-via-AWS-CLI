#!/bin/bash
#
# DESCRIPTION: Bash script which creates custom Amazon Machine Image (AMI) with
# of AWS CLI for the future use with Nextflow and AWS batch. That custom AMI
# will contain all the software needed for execution of Nextflow tasks. Usually
# if the pipeline is properly containerized one would only need Docker,
# AWS CLI and esc (Amazon Elastic Container Service). AWS CLI is needed for
# communication between AWS batch and EC2 instance which runs the task and EC2
# instance which launches the Nextflow pipeline. Similarly, esc is needed for
# communication with container services. Once AMI is created, it can be reused
# in all Nextflow pipelines.
#
# USAGE: Run in command line in Linux-like system
# OPTIONS: Run ./create_custom_ami.sh -h
#          to see the full list of options and their descriptions.
# REQUIREMENTS: AWS CLI & AWS profile profile with permissions to create users,
# user groups, security groups and ec2 instances.
# BUGS: --
# NOTES:
# AUTHOR:  Maria Litovchenko
# VERSION:  1
# CREATED:  13.06.2024
# REVISION: 13.06.2024
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
    echo "Bash script which creates custom AWS AMI with use of AWS CLI."
    echo "Please check that AWS CLI is installed and configured prior to run."
    echo
    echo "Syntax: create_custom_ami.sh [-p|r|i|u|h]"
    echo "Arguments:"
    echo "p     [REQUIRED] AWS profile name. That profile should have"
    echo "      permissions to create users, user groups, security groups and"
    echo "      ec2 instances."
    echo "r     [REQUIRED] AWS region, i.e. eu-west-2. Put it in double "
    echo "      quotes."
    echo "i     [REQUIRED] AWS instance type, i.e. t3.2xlarge"
    echo "u     [REQUIRED] User name of the person executing this script."
    echo "e     [optional] Name of an EC2 instance. Default: nf-EC2- plus "
    echo "      value of -u argument"
    echo "a     [optional] Name under which custom AMI will be saved. Default:"
    echo "      ami-nf-aws-batch- plus value of -u argument"
    echo "b     [optional] Name of the base AMI. Default: "
    echo "      /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended"
    echo "h     Print this help."
    echo
}

# Reading command line arguments ----------------------------------------------
while getopts ":p:r:i:u:e:a:b:h" opt; do
    case $opt in
    p) AWS_PROFILE_NAME="$OPTARG" ;;
    r) AWS_REGION_NAME="$OPTARG" ;;
    i) INSTANCE_TYPE="$OPTARG" ;;
    u) EXECUTING_USER="$OPTARG" ;;
    e) EC2_NAME="$OPTARG" ;;
    a) CUSTOM_AMI_NAME="$OPTARG" ;;
    b) BASE_AMI_IMAGE_NAME="$OPTARG" ;;
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
: "${INSTANCE_TYPE:?Missing -i}"
: "${EXECUTING_USER:?Missing -u}"
if [ -z "${EC2_NAME}" ]; then
    EC2_NAME='nf-EC2-'$EXECUTING_USER
fi
if [ -z "${CUSTOM_AMI_NAME}" ]; then
    CUSTOM_AMI_NAME='ami-nf-aws-batch-'$EXECUTING_USER
fi
if [ -z "${BASE_AMI_IMAGE_NAME}" ]; then
    BASE_AMI_IMAGE_NAME='/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended'
fi

timestamp=$(date -I)
echo "[""$timestamp""] Input arguments:"
echo "               -p (AWS profile name): "$AWS_PROFILE_NAME
echo "               -r (AWS region): "$AWS_REGION_NAME
echo "               -i (EC2 insctance type): "$INSTANCE_TYPE
echo "               -u (Executing user ID): "$EXECUTING_USER
echo "               -e (Name to be given to EC2 instance): "$EC2_NAME
echo "               -a (Name to be given to custom AMI): "$CUSTOM_AMI_NAME
echo "               -b (Base AMI name): "$BASE_AMI_IMAGE_NAME

# Main script -----------------------------------------------------------------
# default values
KEY_PAIR_NAME='custom_ami_creation_keypair'
rm -rf $KEY_PAIR_NAME'.pem'
EC2_DEFAULT_USER_NAME='ec2-user'

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1: get VPC ID and default subnet ID ------------------------------------
# In case your default subnet is private, you may need to use VPN to run this 
# script. As everything done below is based on publicly accessible data and 
# does not disclose any private data, use of public subnets is also fine.
read -r SUBNET_ID VPC_ID <<<"$(aws ec2 describe-subnets --filters 'Name=default-for-az,Values=true' \
    --query 'Subnets[*].[SubnetId, VpcId]' \
    --output text | head -1)"
# create a security group
read -r SECURITY_GROUP_ID <<<"$(aws ec2 create-security-group --group-name $EC2_NAME \
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

# Step 2: Initialize EC2 base instance ----------------------------------------
# Amazon already have a base Linux AMI with the pre-installed Docker for this
# available optimised to use with AWS batch. Let's retrive the AMI ID of that
# image.
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/retrieve-ecs-optimized_AMI.html
read -r BASE_AMI_IMAGE_ID <<<$(aws ssm get-parameters --names $BASE_AMI_IMAGE_NAME \
    --query 'Parameters[*].[Value]' \
    --output text | sed 's/.*"ami/ami/g' |
    sed 's/".*//g')
# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
    --query 'KeyMaterial' \
    --output text >$KEY_PAIR_NAME'.pem'
chmod 400 $KEY_PAIR_NAME'.pem'
echo "[""$timestamp""] Created security key pair "$KEY_PAIR_NAME

# create an instance
read -r INSTANCE_ID <<<"$(aws ec2 run-instances --image-id $BASE_AMI_IMAGE_ID \
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
echo "[""$timestamp""] Created EC2 instance: "$INSTANCE_ID

# wait for the instance to be running
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"

timestamp=$(date -I)
echo "[""$timestamp""] Created template EC2 instance from "$BASE_AMI_IMAGE_ID

# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<"$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].PublicDnsName' \
    --output text)"

# Step 3: Install needed software on EC2 --------------------------------------
scp -i $KEY_PAIR_NAME'.pem' software_installation_on_ami.sh  \
  $EC2_DEFAULT_USER_NAME'@'"$PUBLIC_DNS_NAME":/home/$EC2_DEFAULT_USER_NAME

ssh -i $KEY_PAIR_NAME'.pem' \
  $EC2_DEFAULT_USER_NAME'@'"$PUBLIC_DNS_NAME" 'bash -s < /home/'$EC2_DEFAULT_USER_NAME'/software_installation_on_ami.sh'

timestamp=$(date -I)
echo "[""$timestamp""] Installed software on the template EC2"

# Step 4: Create custom AMI ---------------------------------------------------
read -r CUSTOM_AMI_ID <<<"$(aws ec2 create-image --instance-id $INSTANCE_ID \
    --name $CUSTOM_AMI_NAME \
    --no-reboot \
    --output text)"

timestamp=$(date -I)
echo "[""$timestamp""] Created custom AMI "$CUSTOM_AMI_ID

# Step 5: clean up ------------------------------------------------------------
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
sleep 120
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME
rm -rf $KEY_PAIR_NAME'.pem'

timestamp=$(date -I)
echo "[""$timestamp""] Cleaned up"
echo "[""$timestamp""] Success!"
