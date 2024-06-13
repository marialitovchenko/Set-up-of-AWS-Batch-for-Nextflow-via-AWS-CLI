#!/bin/bash
AWS_PROFILE_NAME='ngs_workflows_dev'
AWS_REGION_NAME='eu-west-2'
INSTANCE_TYPE='t3.2xlarge'
EXECUTING_USER='ml'

EC2_NAME='nf-EC2-'$EXECUTING_USER
CUSTOM_AMI_NAME='ami-nf-aws-batch-'$EXECUTING_USER

BASE_AMI_IMAGE_NAME='/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended'
KEY_PAIR_NAME='custom_ami_creation_keypair'
EC2_DEFAULT_USER_NAME='ec2-user'

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Build a custom Amazon Machine Image which will contain all the
# software needed for execution of your Nextflow tasks. Usually, if the
# pipeline is properly containerized one would only need Docker & AWS CLI.
# AWS CLI is needed for communication between AWS batch and EC2 instance which
# runs the task.

# Step 1: get VPC ID and default subnet ID. In case your default subnet is
# private, you may need to use VPN to run this script. As everything done below
# is based on publicly accessible data and does not disclose any private data,
# use of public subnets is also fine.
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
    --protocol tcp \
    --port 22 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 22 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-ingress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 80 --cidr '0.0.0.0/0'
aws ec2 authorize-security-group-egress --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp \
    --port 80 --cidr '0.0.0.0/0'

# Step 2: Initialize EC2 base instance
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
# create an instance
read -r INSTANCE_ID <<<"$(aws ec2 run-instances --image-id $BASE_AMI_IMAGE_ID \
    --count 1 \
    --instance-type $INSTANCE_TYPE \
    --key-name $KEY_PAIR_NAME \
    --security-group-ids $SECURITY_GROUP_ID \
    --subnet-id $SUBNET_ID \
    --block-device-mappings '[
                                {
                                    'DeviceName': '/dev/xvda',
                                    'Ebs': {
                                        'VolumeSize': 100,
                                        'VolumeType': 'standard',
                                        'DeleteOnTermination': true
                                    }
                                }
                            ]' \
    --output text \
    --query 'Instances[*].[InstanceId]')"
# wait for the instance to be running
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID"
# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<"$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[].Instances[].PublicDnsName' \
    --output text)"

# Step 3: Install needed software on EC2
# login into EC2
ssh -i $KEY_PAIR_NAME'.pem' $EC2_DEFAULT_USER_NAME'@'"$PUBLIC_DNS_NAME"

cd "$HOME" || exit
sudo service docker start
sudo usermod -a -G docker ec2-user
sudo yum install -y bzip2 wget
wget https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -f -p "$HOME"/miniconda
"$HOME"/miniconda/bin/conda install -c conda-forge -y awscli
rm Miniconda3-latest-Linux-x86_64.sh
sudo yum install ecs-init
sudo systemctl start ecs

# exit from EC2
exit

# Step 4: Create custom AMI
read -r CUSTOM_AMI_ID <<<"$(aws ec2 create-image --instance-id $INSTANCE_ID \
    --name $CUSTOM_AMI_NAME \
    --no-reboot \
    --output text)"

# Step 5: clean up
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID
aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME
rm -rf $KEY_PAIR_NAME'.pem'
