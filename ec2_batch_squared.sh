AWS_PROFILE="ngs_workflows_dev"
REGION="eu-west-2"
IAM_USER_NAME=nextflow-programmatic-access
IAM_GROUP_NAME=nextflow-group
IAM_ROLE_NAME=AmazonEC2SpotFleetRole

# Step 1 Setting up a Nextflow user with IAM
# https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_cliwpsapi
# Step 1.1 Adding a programmatic user
aws iam create-user --user-name $IAM_USER_NAME \
                    --region $REGION \
                    --profile $AWS_PROFILE

# give the user programmatic access 
aws iam create-access-key --user-name $IAM_USER_NAME \
                          --region $REGION \
                          --profile $AWS_PROFILE

# Step 1.2 Create a user group
aws iam create-group --group-name $IAM_GROUP_NAME \
                     --region $REGION \
                     --profile $AWS_PROFILE
aws iam add-user-to-group --user-name $IAM_USER_NAME \
                          --group-name $IAM_GROUP_NAME \
                          --region $REGION \
                          --profile $AWS_PROFILE

# Step 1.5 Attach access policies to user group
aws iam attach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess \
                            --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess \
                            --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess \
                            --region $REGION \
                            --profile $AWS_PROFILE

# Step 1.6 Create permission roles for running AWS Batch
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
                    }' \
                    --region $REGION \
                    --profile $AWS_PROFILE


aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole \
                           --role-name $IAM_ROLE_NAME \
                           --region $REGION \
                           --profile $AWS_PROFILE

# Step 2.1 Startup the base ECS image in a virtual machine
# SOMETHING FISHY HAPPENS to security group
EC2_NAME="nextflow_EC2"
INSTANCE_TYPE="t3.2xlarge"
KEY_PAIR_NAME=$EC2_NAME"KeyPair"
AMI_IMAGE_ID="ami-06373f703eb245f45" # Amazon Linux 2023 AMI

# create a key pair
aws ec2 create-key-pair --key-name $KEY_PAIR_NAME \
                        --query 'KeyMaterial' \
                        --profile $AWS_PROFILE \
                        --region $REGION \
                        --output text > $KEY_PAIR_NAME".pem"
chmod 400 $KEY_PAIR_NAME".pem"

# create a security group
aws ec2 create-security-group --group-name $EC2_NAME \
                              --description $EC2_NAME" security group" \
			                  --profile $AWS_PROFILE \
                              --vpc-id $VPC_ID \
                              --region $REGION \
                              --output text > security-group_id.txt
SECURITY_GROUP_ID=`head -1 security-group_id.txt` 
rm security-group_id.txt

# add rules to security group: allow inbound traffic on TCP port 22 to support SSH connections
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
                                         --protocol tcp \
                                         --port 22 --cidr "0.0.0.0/0" \
			     		                 --profile $AWS_PROFILE \
                                         --region $REGION
aws ec2 authorize-security-group-ingress --group-id $SECURITY_GROUP_ID \
                                         --protocol tcp \
                                         --port 80 --cidr "0.0.0.0/0" \
			     		                 --profile $AWS_PROFILE \
                                         --region $REGION

aws ec2 run-instances --image-id $AMI_IMAGE_ID \
                      --count 1 \
                      --instance-type $INSTANCE_TYPE \
                      --key-name $KEY_PAIR_NAME \
	                  --security-group-ids $SECURITY_GROUP_ID \
                      --subnet-id $SUBNET_ID \
                      --profile $AWS_PROFILE \
                      --region $REGION > instance_details

aws ec2 create-tags --resources $INSTANCE_ID \
                    --tags Key=Name,Value=$EC2_NAME \
                    --profile $AWS_PROFILE \
                    --region $REGION 
aws ec2 describe-instances --instance-ids $INSTANCE_ID \
                           --query 'Reservations[].Instances[].PublicDnsName' \
                           --profile $AWS_PROFILE

AMI_USER="ec2-user"
ssh -i $KEY_PAIR_NAME".pem" $AMI_USER"@"$PRIVATE_DNS_NAME


aws ec2 terminate-instances --instance-ids $INSTANCE_ID --profile $AWS_PROFILE
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID --profile $AWS_PROFILE
