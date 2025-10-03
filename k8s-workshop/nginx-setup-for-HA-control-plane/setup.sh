#!/bin/bash
for i in k8s-cp{1..3}.${dnsbinder_domain};do sudo dnsbinder -c $i;done
sudo dnsbinder -cc k8s-cp.${dnsbinder_domain} ${dnsbinder_server_fqdn}
if ! grep 'stream.d' /etc/nginx/nginx.conf; then
	echo 'include /etc/nginx/stream.d/*.conf;' | sudo tee -a /etc/nginx/nginx.conf  
fi
sudo mkdir /etc/nginx/stream.d
sudo cp -p k8s-cp.conf /etc/nginx/stream.d/ 
sudo sed -i "s/get_dnsbinder_domain/${dnsbinder_domain}/g" /etc/nginx/stream.d/k8s-cp.conf
sudo systemctl reload nginx
