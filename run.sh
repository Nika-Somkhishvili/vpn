#!/bin/bash

# helper functions for visuals
message(){
    echo -e "\e[92m ==== $1 \e[0m"
}
warning(){
    echo -e "\e[33m ==== $1 \e[0m"
}
error(){
    echo -e "\e[91;1m ==== $1 \e[0m"
}
highlight(){
    echo -e "\e[93m$1\e[0m"
}
loading_bar() {
    local time_left=$1
    while [ 0 -lt $time_left ]; do
        sleep 1
        ((time_left -= 1))
        echo -ne "$(highlight " ==== Expected time: $time_left seconds\033[0K\r")"
    done
    echo -ne "\n"
}

# check if environment variable is set
if [ -z "$LINODE_API_TOKEN" ]; then
    error "set LINODE_API_TOKEN environment variable before running the script!"
    exit 1
fi

# read the first argument
if [ "$1" = "delete" ]; then
    message "Deleting and disconnecting"
    wg-quick down wg0 > /dev/null 2>&1
    message "disconnected!"
    del_response=$(curl -s -H "Authorization: Bearer $LINODE_API_TOKEN" -X DELETE https://api.linode.com/v4/linode/instances/$(cat vpn_files/server_id.txt))

    if [ "$del_response" = "{}" ]; then
        message "server deleted!"
    else
        error "server couldn't delete"
        echo "$del_response"
    fi
    exit 1
elif [ "$1" = "create" ]; then
    message "let's go!"
elif [ "$1" = "disconnect" ]; then
    message "disconnecting"
    wg-quick down wg0 
    exit 1
elif [ "$1" = "connect" ]; then
    message "connecting"
    wg-quick up wg0 
    exit 1
else
    error "invalid argument"
    echo ""
    echo " - - - - HOW TO USE - - - - "
    echo ""
    echo "create new linode server and connect to it (this will also generate QR code for mobile): $(highlight "create") $(highlight "<SERVER LIFETIME IN MINUTES>")"
    echo "disconnect from the server and delete it: $(highlight "delete")"
    echo "disconnect from the server: $(highlight "disconnect")"
    echo "connect to the server: $(highlight "connect")"
    echo ""
    echo " - - - - HOW TO USE - - - - "
    exit 1
fi

SERVER_LIFETIME=60 # in minutes (default)
# read the second argument to set server lifetime
if [[ $2 =~ ^[0-9]+$ ]]; then
    SERVER_LIFETIME=$2
elif [ -z "$2"]; then
    message "using defaule lifetime for the server"
else
  error "'$2' is't valid time. Enter integer"
  exit 1
fi
message "Server lifetime set to $SERVER_LIFETIME minutes"

#start showing loading bar
loading_bar 105 &

# generate ssh keys
message "Generating ssh keys"
SSH_PUB_KEY_PATH="vpn_files/id_rsa.pub"
SSH_PRIV_KEY_PATH="vpn_files/id_rsa"
mkdir vpn_files > /dev/null 2>&1
yes y | ssh-keygen -t rsa -b 4096 -N "" -f vpn_files/id_rsa > /dev/null 2>&1
SSH_PUB_KEY=$(cat "$SSH_PUB_KEY_PATH")

# Create Linode instance and capture the response
message "Creating a new linode server"
response=$(curl -s -H "Content-Type: application/json" \
    -H "Authorization: Bearer $LINODE_API_TOKEN" \
    -X POST -d '{
      "image": "linode/ubuntu22.04",
      "root_pass": "thispasswordisusless",
      "authorized_keys": [
        "'"$SSH_PUB_KEY"'"
      ],
      "type": "g6-nanode-1",
      "region": "eu-west",
      "label": "comeinmisterpresident74598237958",
      "backups_enabled": false,
      "booted": true
    }' \
    https://api.linode.com/v4/linode/instances)

# Extract the IPv4 address and id from the response
server_ip_address=$(echo "$response" | grep -oP '"ipv4": \[\K"[^"]+"' | sed 's/"//g')
server_id=$(echo "$response" | grep -oP '"id": \K\d+')

# check if the response is valid
if [ -z "$server_ip_address" ]; then
    error "Couldn't create Linode server"
    echo "$response"
    exit 1
fi

# print ip and id
message "Server IP Address: $server_ip_address"
message "Server ID: $server_id"
message "Server is starting..."

# save the server id for deleting the server later
echo "$server_id" > vpn_files/server_id.txt

# install necessary programs on the client if not already installed. wireguard, openresolv, and qrencode
if hash wg 2>/dev/null; then
    message "Wireguard is already installed on the client :)"
else
    message "Wireguard is not installed on the client. Downloading..."
    sudo apt-get update > /dev/null 2>&1
    sudo apt-get install -y wireguard > /dev/null 2>&1
fi

if hash resolvconf 2>/dev/null; then
    message "openresolv is already installed on the client :)"
else
    message "openresolv is not installed on the client. Downloading..."
    sudo apt-get install -y openresolv > /dev/null 2>&1
fi

if hash qrencode 2>/dev/null; then
    message "qrencode is already installed on the client :)"
else
    message "qrencode is not installed on the client. Downloading..."
    sudo apt-get install -y qrencode > /dev/null 2>&1
fi

# Generate client keys
wg genkey | tee vpn_files/client_privatekey | wg pubkey > vpn_files/client_publickey
# Generate client keys for mobile phone
wg genkey | tee vpn_files/mobile_client_privatekey | wg pubkey > vpn_files/mobile_client_publickey

# prepare variables 
CLIENT_PUB_KEY=$(cat vpn_files/client_publickey)
MOBILE_CLIENT_PUB_KEY=$(cat vpn_files/mobile_client_publickey)

# Wait for SSH availability
message "Waiting for the server to start..."
ssh_attempts=0
ssh_max_attempts=200

while [ "$ssh_attempts" -lt "$ssh_max_attempts" ]; do
    if ssh -o "ConnectTimeout=3" -o "StrictHostKeyChecking=no" -i "$SSH_PRIV_KEY_PATH" "root@$server_ip_address" exit >/dev/null 2>&1; then
        message "Server is running. Logging in"
        break
    else
        # echo "checking..."
        sleep 1
        ((ssh_attempts++))
    fi
done

if [ "$ssh_attempts" -ge "$ssh_max_attempts" ]; then
    message "SSH did not become available after $ssh_max_attempts attempts. Exiting."
    exit 1
fi

# prepare remote commands to execute on the server
message "Installing and configuring WireGuard on the server" 
remote_commands=$(cat <<EOF    
# Update apt repository on the server
sudo apt-get update

# Download WireGuard on the server
sudo apt-get install -y wireguard > /dev/null 2>&1

# Create server keys
wg genkey | tee server_privatekey | wg pubkey > server_publickey

# Create WireGuard configuration file
echo "[Interface]
Address = 10.0.0.1/8
Address = fd86:ea04:1115::1/64
SaveConfig = true
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE;
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE;
ListenPort = 51820
PrivateKey = \$(cat server_privatekey)

[Peer]
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = 10.0.0.2/32

[Peer]
#mobile
PublicKey = $MOBILE_CLIENT_PUB_KEY
AllowedIPs = 10.0.0.3/32, fd86:ea04:1115::2/128" | sudo tee /etc/wireguard/wg0.conf

#enable forwarding
sudo sysctl -w net.ipv4.ip_forward=1
sudo sysctl -w net.ipv6.conf.all.forwarding=1

# disable password login
sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' "/etc/ssh/sshd_config"
systemctl restart sshd

# delete this server after a certain amount of time (converted to seconds)
nohup sh -c '(sleep $(($SERVER_LIFETIME * 60)) && curl -s -H "Authorization: Bearer $LINODE_API_TOKEN" -X DELETE https://api.linode.com/v4/linode/instances/$server_id) > ./tmp.log 2>&1' &

# start the interface
wg-quick up wg0 > /dev/null 2>&1

# return server publick key for the client
cat server_publickey

# close ssh
pkill -e ssh > /dev/null 2>&1
EOF
)

# run ssh commands and capture output
ssh_output=$(ssh -o "StrictHostKeyChecking=no" -i "$SSH_PRIV_KEY_PATH" -t "root@$server_ip_address" "$remote_commands" 2>/dev/null)

# extract server public key form the output (it is on the last line)
server_publickey=$(echo "$ssh_output" | tail -n 1)

# create configuration for the client
message "Configuring wireguard on client"
cat << EOF > /etc/wireguard/wg0.conf
[Interface]
PrivateKey = $(cat vpn_files/client_privatekey)
Address = 10.0.0.2/8
SaveConfig = true
DNS = 8.8.8.8, 1.1.1.1
[Peer]
PublicKey = $server_publickey
AllowedIPs = 0.0.0.0/0
Endpoint = $server_ip_address:51820
PersistentKeepalive = 30
EOF

# start the interface
wg-quick up wg0 > /dev/null 2>&1

# create configuration for the mobile client
message "Creating a configuration for a mobile device"
cat << EOF > vpn_files/mobile.conf
[Interface]
PrivateKey = $(cat vpn_files/mobile_client_privatekey)
Address = 10.0.0.3/32, fd86:ea04:1115::2/128
DNS = 8.8.8.8, 1.1.1.1

[Peer]
PublicKey = $server_publickey
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $server_ip_address:51820
PersistentKeepalive = 30
EOF

# generate QR code from mobile configuration file
echo ""
qrencode -t ansiutf8 < vpn_files/mobile.conf

# print some info
echo ""
warning "Server ($server_ip_address) will be deleted in $SERVER_LIFETIME minutes"
message "All set up! Enjoy :D"

#kill loading bar process (if still exists)
kill $! > /dev/null 2>&1