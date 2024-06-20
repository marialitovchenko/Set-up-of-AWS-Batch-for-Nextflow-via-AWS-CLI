aws ec2 terminate-instances --instance-ids $INSTANCE_ID
sleep 30
aws ec2 delete-security-group --group-id $SECURITY_GROUP_ID

aws iam detach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole \
                           --role-name $IAM_ROLE_NAME
aws iam delete-role --role-name $IAM_ROLE_NAME

aws iam remove-user-from-group --user-name $IAM_USER_NAME \
                              --group-name $IAM_GROUP_NAME
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam detach-group-policy --group-name $IAM_GROUP_NAME \
                            --policy-arn arn:aws:iam::aws:policy/AWSBatchFullAccess 
aws iam delete-group --group-name $IAM_GROUP_NAME

aws ec2 delete-key-pair --key-name $KEY_PAIR_NAME
aws iam delete-access-key --access-key-id $ACCESS_KEY_ID --user-name $IAM_USER_NAME
aws iam delete-user  --user-name $IAM_USER_NAME

aws ec2 deregister-image --image-id $CUSTOM_AMI_ID

aws batch update-job-queue --job-queue $BATCH_JOB_QUEUE_NAME \
                           --state DISABLED 
sleep 30
aws batch delete-job-queue --job-queue $BATCH_JOB_QUEUE_NAME

aws batch update-compute-environment --compute-environment $BATCH_COMPUTE_ENV_NAME \
                                     --state DISABLED
sleep 30
aws batch delete-compute-environment --compute-environment $BATCH_COMPUTE_ENV_NAME