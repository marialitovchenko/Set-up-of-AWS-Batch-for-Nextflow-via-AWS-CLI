# Set up of AWS Batch to be used with Nextflow via AWS CLI

There are multiple tutorial describing the process of setting up AWS Batch to
be used with [Nextflow](https://www.nextflow.io/). For example, 
[one by Kelsey Florek](https://staphb.org/resources/2020-04-29-nextflow_batch.html#step-1-setting-up-a-nextflow-user-with-iam)
or [one by Tobias Neumann](https://t-neumann.github.io/pipelines/AWS-pipeline/).
While they do go rather thoroughly though the process, they only demonstrate 
the set up based on AWS console (i.e. button clicking) which is not scalable 
shall you wish to deploy multiple pipeline or the same pipeline with multiple
configuration. This is why I converted the steps of the tutorial into commands
of AWS command line interface (CLI) and arranged them into scripts. 

This README is not a comprehensive tutorial for the set up and does not provide
detailed description and reasoning behind all the commands in the scripts. This
is why it is rather beneficial to first read though the tutorials mentioned
above. Also, the scripts do not replicate tutorials one to one as some of the 
parameters were initialized very far from their use place therefore introducing
confusion. 

The scripts operate under assumption that you already have VPC, subnetworks and 
users with privileges to create users, user groups, security groups, ec2 
instances, computing environments and job queues. 
