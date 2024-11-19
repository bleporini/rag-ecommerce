#!/usr/bin/env bash
set -e
cd terraform
terraform destroy -auto-approve
rm terraform.tfvars
