#!/usr/bin/env bash
set -e
if [[ "$CONFIG_FILE" == "" ]] || [[ ! -e $CONFIG_FILE ]]; then
	echo "Please provide an environment variable CONFIG_FILE with the path of the config file"
	exit 1
fi
#set -x
vm_pub_ip=$(cat terraform/tmp/commerce_bastion_ip.txt)
echo VM public IP: $vm_pub_ip
## To avoid IP reuse with different keys
ssh_options="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

scp $ssh_options etc/client.properties ec2-user@$vm_pub_ip:~/
scp $ssh_options etc/sr.properties ec2-user@$vm_pub_ip:~/

ssh $ssh_options ec2-user@$vm_pub_ip docker run -d \
	--name compose_rag \
	-v \$PWD:\$PWD  \
	--workdir \$PWD \
       	-v /var/run/docker.sock:/var/run/docker.sock \
       	docker compose -f ps_sample_compose.yml -f compose_rag.yml up -d


echo Now you can visit the shop at http://$vm_pub_ip 
cd terraform
terraform output

