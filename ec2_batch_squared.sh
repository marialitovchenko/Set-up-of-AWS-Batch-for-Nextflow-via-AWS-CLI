#!/bin/bash
AWS_PROFILE_NAME="ngs_workflows_dev"
AWS_REGION_NAME="eu-west-2"
BASE_AMI_IMAGE_ID="ami-06373f703eb245f45" # Amazon Linux 2023 AMI
INSTANCE_TYPE="t3.2xlarge"
EXECUTING_USER="mlitovchenko"
S3_BUCKET_NAME="s3-test"

IAM_USER_NAME=nextflow-programmatic-access-$EXECUTING_USER
IAM_GROUP_NAME=nextflow-group-$EXECUTING_USER
EC2_NAME="nextflow-EC2-"$EXECUTING_USER

IAM_ROLE_NAME=AmazonEC2SpotFleetRole
KEY_PAIR_NAME=$EC2_NAME"-KeyPair"
EC2_DEFAULT_USER_NAME="ec2-user"
CUSTOM_AMI_NAME="ami_nextflow_aws_batch_"$EXECUTING_USER
BATCH_COMPUTE_ENV_NAME="nextflow_aws_batch_"$EXECUTING_USER
BATCH_JOB_QUEUE_NAME="nextflow_queue_"$EXECUTING_USER

# set AWS profile to the one with suitable permissions
export AWS_PROFILE=$AWS_PROFILE_NAME
# set AWS region
export AWS_REGION=$AWS_REGION_NAME

# Step 1 Setting up a Nextflow user with IAM
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_cliwpsapi
# create a programmatic user
aws iam create-user --user-name $IAM_USER_NAME
read -r IAM_USER_ID <<<$(aws iam list-users --query "Users[*].[UserName, UserId]" \
                                            --output text | grep $IAM_USER_NAME | cut -f2)

# give the user programmatic access 
read -r ACCESS_KEY_ID ACCESS_KEY_SECRET <<<$(aws iam create-access-key \
                                                 --user-name $IAM_USER_NAME \
                                                 --output text | \
                                                 cut -f2,4)

# create a user group
aws iam create-group      --group-name $IAM_GROUP_NAME
aws iam add-user-to-group --user-name  $IAM_USER_NAME \
                          --group-name $IAM_GROUP_NAME

# attach access policies to user group
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
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

                            --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role


# Step 2 Build a custom Amazon Machine Image
aws ssm get-parameters --names /aws/service/ecs/optimized-ami/amazon-linux-2023/recommended

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
aws ec2 authorize-security-group-egress --group-id $SECURITY_GROUP_ID \
                                        --protocol tcp \
                                        --port 22 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
                                         --protocol tcp \
                                         --port 80 --cidr "0.0.0.0/0"
aws ec2 authorize-security-group-egress --group-id $SECURITY_GROUP_ID \
                                        --protocol tcp \
                                        --port 80 --cidr "0.0.0.0/0"

# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
                        --query 'KeyMaterial' \
                        --output text > $KEY_PAIR_NAME".pem"
chmod 400 $KEY_PAIR_NAME".pem"

# create an instance
read -r INSTANCE_ID <<<$(aws ec2 run-instances --image-id $BASE_AMI_IMAGE_ID \
                                               --count 1 \
                                               --instance-type $INSTANCE_TYPE \
                                               --key-name $KEY_PAIR_NAME \
                                               --security-group-ids $SECURITY_GROUP_ID \
                                               --subnet-id $SUBNET_ID \
                                               --block-device-mappings  '[
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
                                               --query "Instances[*].[InstanceId]")
# rename instance
aws ec2 create-tags --resources $INSTANCE_ID \
                    --tags Key=Name,Value=$EC2_NAME
# wait for the instance to be running
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_ID
# get public ID address of an instance
read -r PUBLIC_DNS_NAME <<<$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
                                                        --query 'Reservations[].Instances[].PublicDnsName' \
                                                        --output text)

# login into EC2
ssh -i $KEY_PAIR_NAME".pem" $EC2_DEFAULT_USER_NAME"@"$PUBLIC_DNS_NAME
# install docker on EC2
# add Docker's official GPG key:
sudo yum update -y
sudo yum install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
# add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo yum update -y
# install the Docker packages.
sudo yum install docker -y
sudo service docker start
sudo usermod -a -G docker ec2-user
# install aws cli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
exit

read -r CUSTOM_AMI_ID <<<$(aws ec2 create-image --instance-id $INSTANCE_ID \
                                                --name $CUSTOM_AMI_NAME \
                                                --no-reboot \
                                                --output text)

# Step 3 Define AWS Batch compute environment
batch_compute_config='{
                        "type": "SPOT",
                        "allocationStrategy": "SPOT_CAPACITY_OPTIMIZED",
                        "minvCpus": 0,
                        "desiredvCpus": 0,
                        "maxvCpus": 1024,
                        "instanceTypes": ["optimal"],
                        "imageId": "'$CUSTOM_AMI_ID'",
                        "subnets": ["'$SUBNET_ID'", "subnet-05534e5ba9e1491c1", "subnet-092cd8753dd23c57e"],
                        "securityGroupIds": ["'$SECURITY_GROUP_ID'"],
                        "ec2KeyPair": "'$KEY_PAIR_NAME'",
                        "instanceRole": "ecsInstanceRole",
                        "bidPercentage": 99,
                        "spotIamFleetRole": "AmazonEC2SpotFleetRole"
                     }'
# batch_compute_config='{
#                         "type": "EC2",
#                         "allocationStrategy": "BEST_FIT_PROGRESSIVE",
#                         "minvCpus": 0,
#                         "desiredvCpus": 0,
#                         "maxvCpus": 128,
#                         "instanceTypes": ["optimal"],
#                         "imageId": "ami-02bdc46746b0733da",
#                         "subnets": ["'$SUBNET_ID'", "subnet-05534e5ba9e1491c1", "subnet-092cd8753dd23c57e"],
#                         "securityGroupIds": ["'$SECURITY_GROUP_ID'"],
#                         "ec2KeyPair": "'$KEY_PAIR_NAME'",
#                         "instanceRole": "arn:aws:iam::352918899944:instance-profile/ecsInstanceRole"
#                      }'
# create the compute environment
aws batch create-compute-environment --compute-environment-name $BATCH_COMPUTE_ENV_NAME \
                                     --state ENABLED \
                                     --type MANAGED \
                                     --compute-resources $batch_compute_config
# Step 4 Create an AWS Batch Job queue
aws batch create-job-queue --job-queue-name $BATCH_JOB_QUEUE_NAME \
                           --state ENABLED \
                           --priority 1 \
                           --compute-environment-order '
                           [
                                {
                                    "order": 1,
                                    "computeEnvironment": "'$BATCH_COMPUTE_ENV_NAME'"
                                }
                            ]'

# Step 5 Set up an S3 Bucket for data access
aws s3api create-bucket --bucket $EXECUTING_USER'-'$S3_BUCKET_NAME \
                        --create-bucket-configuration LocationConstraint=$AWS_REGION_NAME

# login to ec2
aws configure