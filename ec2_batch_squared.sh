#!/bin/bash
AWS_PROFILE_NAME="ngs_workflows_dev"
AWS_REGION_NAME="eu-west-2"
AMI_IMAGE_ID="ami-06373f703eb245f45" # Amazon Linux 2023 AMI
INSTANCE_TYPE="t3.2xlarge"
EXECUTING_USER="mlitovchenko"

IAM_USER_NAME=nextflow-programmatic-access-$EXECUTING_USER
IAM_GROUP_NAME=nextflow-group-$EXECUTING_USER
EC2_NAME="nextflow-EC2-"-$EXECUTING_USER

IAM_ROLE_NAME=AmazonEC2SpotFleetRole
KEY_PAIR_NAME=$EC2_NAME"-KeyPair"
EC2_DEFAULT_USER_NAME="ec2-user"

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1 Setting up a Nextflow user with IAM
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_cliwpsapi
# create a programmatic user
aws iam create-user --user-name $IAM_USER_NAME

# give the user programmatic access 
aws iam create-access-key --user-name $IAM_USER_NAME

# create a user group
aws iam create-group      --group-name $IAM_GROUP_NAME
aws iam add-user-to-group --user-name  $IAM_USER_NAME \
                          --group-name $IAM_GROUP_NAME

# attach access policies to user group
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess \
                            --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
                            --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess 

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
                                }
                            ]
                            }'
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole \
                           --role-name $IAM_ROLE_NAME

# Step 2 Build a custom Amazon Machine Image

# get VPC ID and PUBLIC(!) subnet ID. If subnet is not public and doesn't allow
# map of public ip on launch, we won't be able to ssh to it.
read -r SUBNET_ID VPC_ID <<<$(aws ec2 describe-subnets --filters "Name=map-public-ip-on-launch,Values=true" \
                                                       --query "Subnets[*].[SubnetId, VpcId]" \
                                                       --output text | head -1)

# create a security group
read -r SECURITY_GROUP_ID <<<$(aws ec2 create-security-group --group-name $EC2_NAME \
                                                             --description $EC2_NAME" security group" \
                                                             --vpc-id $VPC_ID \
                                                             --output text)
# add rules to security group: allow inbound traffic on TCP port 22 to support SSH connections
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
                                         --protocol tcp \
                                         --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
                                         --protocol tcp \
                                         --port 80 --cidr "0.0.0.0/0"

# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
                        --query 'KeyMaterial' \
                        --output text > $KEY_PAIR_NAME".pem"
chmod 400 $KEY_PAIR_NAME".pem"

# create an instance
read -r INSTANCE_ID <<<$(aws ec2 run-instances --image-id $AMI_IMAGE_ID \
                                               --count 1 \
                                               --instance-type $INSTANCE_TYPE \
                                               --key-name $KEY_PAIR_NAME \
                                               --security-group-ids $SECURITY_GROUP_ID \
                                               --subnet-id $SUBNET_ID \
                                               --output text \
                                               --query "Instances[*].[InstanceId]")
# rename instance
aws ec2 create-tags --resources $INSTANCE_ID \
                    --tags Key=Name,Value=$EC2_NAME
# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
                                                        --query 'Reservations[].Instances[].PublicDnsName' \
                                                        --output text)

ssh -i $KEY_PAIR_NAME".pem" $EC2_DEFAULT_USER_NAME"@"$PUBLIC_DNS_NAME

aws ec2 terminate-instances --instance-ids $INSTANCE_ID
sleep 30s
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID

aws iam delete-user  --user-name $IAM_USER_NAME

aws iam remove-user-from-group --user-name  $IAM_USER_NAME \
                              --group-name $IAM_GROUP_NAME
aws iam delete-group --group-name $IAM_GROUP_NAME

aws iam detach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole \
                           --role-name $IAM_ROLE_NAME
aws iam delete-role --role-name $IAM_ROLE_NAME