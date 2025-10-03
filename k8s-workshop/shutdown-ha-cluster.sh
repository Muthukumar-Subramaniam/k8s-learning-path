#!/bin/bash
my_domain_name=${dnsbinder_domain}
for v_k8s_host in k8s-{w{1,2,3},cp{1,2,3}}.${dnsbinder_domain}
do
	if ! nc -vzw1 ${v_k8s_host} 22 &>/dev/null
	then
		echo -e "\nk8s host ${v_k8s_host} seems to be down already, Not Reachable! \n"
		continue
	else
		echo -e "\nShutting down k8s host ${v_k8s_host} . . .\n"
		ssh-keygen -R ${v_k8s_host} &>/dev/null
		ssh -o StrictHostKeyChecking=accept-new ${USER}@${v_k8s_host} "sudo shutdown -h now" &>/dev/null
	fi
done
