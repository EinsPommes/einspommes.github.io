#!/bin/bash

# Your network interface
IF_NAME=ens2

# The IP address assigned to your network interface. Use `ip a` to get this.
# It will either be your public IP or a private one, depending on your hosting provider's configuration.
IF_IP=1.2.3.4

# The name of your Wireguard interface.
WG_IF_NAME=wg-mailcow

# The private subnet your Wireguard network uses. The last number is ommitted on purpose.
WG_SUBNET=10.41.67

A=-A
I=-I
if [[ "$1" == "down" ]]; then
  A=-D
  I=-D
fi

# -d or --destination needs to be the IP assigned to the server's interface.
# Without it iptables redirects all traffic on those ports back to the client.
# This took me longer to figure out than I'd like to admit.

# Forward port 25
iptables -t nat $I PREROUTING -p tcp --dport 25 -d $IF_IP -j DNAT --to $WG_SUBNET.2:25

# Forward port 465
iptables -t nat $I PREROUTING -p tcp --dport 465 -d $IF_IP -j DNAT --to $WG_SUBNET.2:465

# Forward port 587
iptables -t nat $I PREROUTING -p tcp --dport 587 -d $IF_IP -j DNAT --to $WG_SUBNET.2:587

# Makes all of this work somehow
iptables $I FORWARD -o $WG_IF_NAME -d $WG_SUBNET.2 -j ACCEPT
iptables -t nat $A POSTROUTING -s $WG_SUBNET.0/24 -j MASQUERADE
iptables $A FORWARD -o $WG_IF_NAME -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables $A FORWARD -i $WG_IF_NAME -o $IF_NAME -j ACCEPT