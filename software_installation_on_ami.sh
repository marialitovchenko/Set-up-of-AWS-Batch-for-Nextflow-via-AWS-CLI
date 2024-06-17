#!/bin/bash
#
# DESCRIPTION: Bash script used to automatically install all the software 
# needed for the Nextflow on EC2 instance to be used under AWS batch afterwards
#
# USAGE: Run in command line in Linux-like system
# OPTIONS: No command line arguments are taken
# REQUIREMENTS: 
# BUGS: --
# NOTES:
# AUTHOR:  Maria Litovchenko
# VERSION:  1
# CREATED:  13.06.2024
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

# configure docker
cd "$HOME" || exit
sudo service docker start
sudo usermod -a -G docker ec2-user

# install aws cli
sudo yum install -y bzip2 wget
wget https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -f -p "$HOME"/miniconda
"$HOME"/miniconda/bin/conda install -c conda-forge -y awscli
rm Miniconda3-latest-Linux-x86_64.sh

# install ecs
sudo yum install ecs-init
sudo systemctl start ecs

# install git
sudo yum install git-all -y

# install java
sudo yum install zip unzip -y
curl -s "https://get.sdkman.io" | bash
source "/home/ec2-user/.sdkman/bin/sdkman-init.sh"
sdk install java 21.0.3-tem
source ~/.bashrc

# install nextflow
curl -s https://get.nextflow.io | bash
chmod +x nextflow
sudo mv nextflow /usr/local/bin
