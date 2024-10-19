# Tunneling a Mailcow server through Wireguard

Mailcow is a easy to set up Mailserver running in Docker.

Unfortunately, most ISPs block port 25. In addition to that, residential IP addresses are generally blacklisted, making it impossible to self-host a mailserver at home.
Mailcow by itself requires at least 6GB of RAM, which makes hosting it on a VPS rather expensive.

The solution: Running Mailcow at home and tunneling it's traffic through a cheap VPS.

The final setup will look like this:

```
<------[ SMTP out ]-----\
-------[ SMTP in ]---> [ VPS ] <----[IMAP/POP3]----
                        ^   |
                        |   \--------[ FRP proxy ]--------\      /---[ :80, :443 ]---
                        V                                 |      |
             [ Wireguard Container ] <-> [ Postfix ]      |   [ Reverse Proxy ]
                                            |   ^         |      |
                                            V   |         V      V
                                        [ Rest of the Mailcow Stack ]
```

We will use Wireguard to tunnel SMTP traffic to and from the Postfix container, and optionally [FRP](https://github.com/fatedier/frp) to proxy IMAP and POP3.

You'll need a basic understanding of networking, DNS and Docker to follow along, plus access to a VPS which is able to send and receive mail.
Most hosting providers block port 25, 465 and 587 by default in order to prevent spam. You should also [make sure the server's IP is not on any blacklist](https://mxtoolbox.com/blacklists.aspx) - Otherwise other servers will refuse to exchange mail with you.

With that out of the way - **Let's get started!**

## DNS setup and Reverse DNS
Traditional DNS allows you to point a domain name to an IP address.
rDNS is, as the name suggests, a way to have an IP address point to a domain name instead.
To find out which domain name your VPS's IP points to, run `host <youripaddress>`.

Example output:
```
$ host 1.1.1.1
1.1.1.1.in-addr.arpa domain name pointer one.one.one.one.
```
Indicating that `1.1.1.1` points to `one.one.one.one.`.

Your VPS provider likely offers you a way to point your IP to a different domain. If you choose to do this, make sure to create an A record one the new domain name which points to your IP.

In any case, the domain name your rDNS points to will be your Mailcow hostname (and FQDN) - Take note of it, you will need it in the next step.

---

With that out of the way, [follow Mailcow's minimal DNS configuration guide](https://mailcow.github.io/mailcow-dockerized-docs/prerequisite/prerequisite-dns/), most importantly the `A`, `MX` and SPF/DMARC `TXT` records. Do not touch DKIM yet, as Mailcow hasn't yet generated a key. Also ignore `autoconfig` and `autodiscover` for now.
TL;DR:
```
# Name              Type       Value
mail                IN A       YOUR_VPS_IP
@                   IN MX 10   mail.example.org.
@                   IN TXT     "v=spf1 mx a -all"
_dmarc              IN TXT     "v=DMARC1; p=reject; rua=mailto:your_contact_email@example.org"
```

## Setting up Mailcow

**Follow this part on your local server, not the VPS!**

Clone the repository: `git clone https://github.com/mailcow/mailcow-dockerized.git` and run `generate_config.sh`.
It will ask you for the FQDN you set up in the previous step.

Now you should have a `mailcow.conf` file. Edit this file to your liking.
If you use a reverse proxy, you should change `HTTP_PORT` and `HTTPS_PORT` and set `HTTPS_BIND` to `127.0.0.1`.
Also set `SKIP_LETS_ENCRYPT` to `y`, since this would most likely fail with our Wireguard setup.
If you already run other containers on your server, you should also change `IPV4_NETWORK`. I set it to `10.117.241`, but you can use whatever you want.

Now you will need to modify `docker-compose.yml` and add a Wireguard container:

Locate the `postfix-mailcow` service and add the following below it:

```yml
    wg:
      container_name: mailcow-wg
      image: cmulk/wireguard-docker:buster
      cap_add:
        - NET_BIND_SERVICE
        - NET_ADMIN
        - SYS_MODULE
      sysctls:
        - net.ipv4.conf.all.src_valid_mark=1
        - net.ipv6.conf.all.disable_ipv6=1
        - net.ipv6.conf.default.disable_ipv6=1
        - net.ipv6.conf.lo.disable_ipv6=1
      privileged: true
      devices:
        - /dev/net/tun:/dev/net/tun
      volumes:
        - /lib/modules:/lib/modules
        - ./wg.conf:/etc/wireguard/wg.conf:ro
      restart: always
```

Now remove the `sysctls` section from `postfix-mailcow` and move the `ports`, `dns` and `networks` from `postfix-mailcow` to `wg`.
Finally, add `network_mode: "service:wg"` to `postfix-mailcow` and add `wg` to the `depends_on` array.
On the `wg` config, add `postfix-mailcow` to `networks.aliases`.

`network_mode: "service:wg"` tells the postfix container to use the `wg` container's network stack instead of creating it's own. This means that all of it's traffic will be forced to go through Wireguard.
This also means that we can't forward ports to our postfix container directly - This is why we move all networking related configuration to the `wg` container.

<details>
  <summary>If you're unsure what to do, the final configuration should look like this.</summary>
  
  ```yml
    postfix-mailcow:
      image: mailcow/postfix:1.66
      depends_on:
        - mysql-mailcow
        - wg
      volumes:
        - ./data/hooks/postfix:/hooks:Z
        - ./data/conf/postfix:/opt/postfix/conf:z
        - ./data/assets/ssl:/etc/ssl/mail/:ro,z
        - postfix-vol-1:/var/spool/postfix:z
        - crypt-vol-1:/var/lib/zeyple:z
        - rspamd-vol-1:/var/lib/rspamd:z
        - mysql-socket-vol-1:/var/run/mysqld/:z
      environment:
        - LOG_LINES=${LOG_LINES:-9999}
        - TZ=${TZ}
        - DBNAME=${DBNAME}
        - DBUSER=${DBUSER}
        - DBPASS=${DBPASS}
        - REDIS_SLAVEOF_IP=${REDIS_SLAVEOF_IP:-}
        - REDIS_SLAVEOF_PORT=${REDIS_SLAVEOF_PORT:-}
        - MAILCOW_HOSTNAME=${MAILCOW_HOSTNAME}
      network_mode: "service:wg"

    wg:
      container_name: mailcow-wg
      image: cmulk/wireguard-docker:buster
      cap_add:
        - NET_BIND_SERVICE
        - NET_ADMIN
        - SYS_MODULE
      sysctls:
        - net.ipv4.conf.all.src_valid_mark=1
        - net.ipv6.conf.all.disable_ipv6=1
        - net.ipv6.conf.default.disable_ipv6=1
        - net.ipv6.conf.lo.disable_ipv6=1
      privileged: true
      devices:
        - /dev/net/tun:/dev/net/tun
      volumes:
        - /lib/modules:/lib/modules
        - ./wg.conf:/etc/wireguard/wg.conf:ro
      ports:
        - "${SMTP_PORT:-25}:25"
        - "${SMTPS_PORT:-465}:465"
        - "${SUBMISSION_PORT:-587}:587"
      restart: always
      dns:
        - ${IPV4_NETWORK:-172.22.1}.254
      networks:
        mailcow-network:
          ipv4_address: ${IPV4_NETWORK:-172.22.1}.253
          aliases:
            - postfix
            - postfix-mailcow
  ```
</details>

## Configuring Wireguard

Wireguard utilizes public and private keypairs for authentication. This means that you will need to generate two keypairs, one for your VPS and one for your local Wireguard container.

Even though Wireguard runs in Docker, you need to install it on both your VPS and on your local server. On Debian, you just run `apt install wireguard wireguard-tools` as root.
Keep in mind that you will need to have the appropriate kernel headers installed - *Check this before installing Wireguard* to save yourself the headache. On Debian: `apt install linux-headers-$(uname -r)`

To generate your keypairs, run the following *on both machines*:
```bash
cd /tmp
wg genkey > privkey 2>/dev/null
wg pubkey < privkey > pubkey
```
This will create two files, `privkey` and `pubkey`. The pubkey is safe to expose, but *never* share the privkey with anyone else!
These keys will be referred to as `LOCAL_PRIVKEY`, `LOCAL_PUBKEY`, `VPS_PRIVKEY` and `VPS_PUBKEY`.

Our Wireguard network is going to use the 10.41.67.0/24 subnet. If you want to use a different IP range, adapt your configuration. The VPS will be `10.41.67.1` while your local server will be `10.41.67.2`.
We will use public port `45371` for our Wireguard server, but you can pick any port you like.

Create a `wg.conf` file in your Mailcow directory with the following content:
```ini
[Interface]
Address = 10.41.67.2
PrivateKey = LOCAL_PRIVKEY
DNS = 127.0.0.11 # Makes sure Postfix can resolve our other containers
MTU = 1280

[Peer]
PublicKey = VPS_PUBKEY
AllowedIPs = 0.0.0.0/0
Endpoint = VPS_IP:45371
PersistentKeepalive = 25
```

On your VPS, create the file `/etc/wireguard/wg-mailcow.conf` (as root).
Note that the interface's name is defined by this config file's name, in this case it will be `wg-mailcow`. Change this if you want.

Put the following configuration:
```ini
[Interface]
Address = 10.41.67.1
PrivateKey = VPS_PRIVKEY
ListenPort = 45371
MTU = 1280

# Run the script that sets up port forwarding
PostUp = /etc/wireguard/scripts/smtp-iptables.sh
PostDown = /etc/wireguard/scripts/smtp-iptables.sh down

# This makes sure that outgoing packets get forwarded properly.
# Make sure to replace INTERFACE_NAME!
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o INTERFACE_NAME -j MASQUERADE; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o INTERFACE_NAME -j MASQUERADE; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
PublicKey = LOCAL_PUBKEY
AllowedIPs = 10.41.67.2/32
PersistentKeepalive = 15
```

**Make sure to replace INTERFACE_NAME with the name of your network interface!** You can get this using `ip a`.
You might notice that we execute `/etc/wireguard/scripts/smtp-iptables.sh` as PostUp and PostDown script. You will need to create this file first.

Put the following into `/etc/wireguard/scripts/smtp-iptables.sh` and make sure to adapt the variables at the top:
```bash
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
```

Finally, make the script executable: `chmod +x /etc/wireguard/scripts/smtp-iptables.sh`.

You can now start the Wireguard server: `systemctl enable --now wg-quick@wg-mailcow`. Replace `wg-mailcow` with the name of your Wireguard interface.

## Starting the Mailcow server

Back on your local server, we are now ready to start the Mailcow server.
In the Mailcow directory, simply run `docker-compose up -d && docker-compose logs -f`.
If all went well, you should be able to access the Mailcow web interface on port 80 (Unless you changed this in mailcow.conf). The default credentials are `admin`:`moohoo` - Change these after you log in.

Now let's add a domain to Mailcow. In the top navigation bar, head over to Configuration -> Mail Setup and click on Add Domain.
Fill out the fields and make sure to keep all Relay options disabled, then click "Add domain and restart SOGo".

After a few seconds, the popup should close and your domain should appear in the list. Click on the "DNS" button and create missing DNS records, most importantly DKIM.

Note that the autodiscover and autoconfig config is optional, but if you choose to set them up, make sure they point to your *local* public IP and not to the VPS (Unless you choose to proxy :80 and :443 separately). If you run a reverse proxy, point them to your Mailcow server HTTP port.

Under "Mailboxes" you can now create a new user. Assign the user to your domain, then click "Login". You should be sent to the web mail client.

You can now use [mail-tester.com](https://www.mail-tester.com/) to make sure your emails get delivered properly. If you get a low score, it will tell you why. If your email is never received, good luck finding the issue.

## Obtaining a SSL certificate
Thanks to the Wireguard setup, Mailcow won't be able to obtain SSL certificates automatically.
You will need to obtain an SSL certificate for your FQDN using certbot.

On your VPS, install certbot and then run: `sudo certbot certonly`.
If prompted, tell it to spin up a temporary web server. Then request a certificate for your FQDN.
Note that if you have another web server running, you will need to temporarily stop it.

Copy fullchain.pem and cert.pem from `/etc/letsencrypt/live/<YOUR_FQDN>` to your local server and rename fullchain.pem to key.pem.
Drop them into data/assets/ssl and replace the existing files.
Before restarting Mailcow, open conf/dovecot/dovecot.conf and locate the line with `ssl_dh = something` - Comment this line out or remove it.
You can now restart the Mailcow server (`docker-compose restart`).

## Proxying IMAP/POP3

If you want to use your mailbox from a different mail client, you will need to use IMAP or POP3. You can either forward the required ports in your router, or use your VPS and proxy them to your server using FRP.

[FRP](https://github.com/fatedier/frp) consists of two parts, FRPS (The server) and FRPC (The client). FRPC runs on your local machine while FRPS runs on the VPS.
It allows us to tunnel incoming traffic on specific ports from the VPS to our local server.

If you choose to use FRP, add this to your Mailcow docker-compose.yml:

```yml
    frpc:
      image: snowdreamtech/frpc
      network_mode: host
      restart: unless-stopped
      volumes:
        - ./frpc.ini:/etc/frp/frpc.ini:ro
```

Create a `frpc.ini` file with the following content:

```ini
[common]
server_addr = YOUR_VPS_IP
server_port = 34576
authentication_method = token
token = PUT_SOMETHING_SECURE_HERE

[pop3]
type = tcp
local_ip = 127.0.0.1
local_port = 110
remote_port = 110

[pop3s]
type = tcp
local_ip = 127.0.0.1
local_port = 995
remote_port = 995

[imap]
type = tcp
local_ip = 127.0.0.1
local_port = 143
remote_port = 143

[imaps]
type = tcp
local_ip = 127.0.0.1
local_port = 993
remote_port = 993
```

If you want to expose your Mailcow Web UI publicly and don't have a way to forward ports in your router, you can also add a section for HTTP (Port 80) and HTTPS (Port 443) to frpc.ini. This will not work if you already have a webserver running on your VPS.

The easiest way to run FRPS on your VPS is using Docker. Create a new directory with two files:

`docker-compose.yml`
```yml
version: "3.0"

services:
  frps:
    image: snowdreamtech/frps
    network_mode: host
    volumes:
      - ./frps.ini:/etc/frp/frps.ini:ro
    restart: always
```

`frps.ini`
```ini
[common]
bind_port = 34576
authentication_method = token
token = PUT_SOMETHING_SECURE_HERE
```

You can change port 34576 to whatever you want. Make sure to change the token!

Start the FRPS container using `docker-compose up -d`, and restart your Mailcow stack using `docker-compose down && docker-compose up -d`.

Check the logs on both sides - The FRPS container should say something like this:
```
[pop3] tcp proxy listen port [110]
new proxy [pop3] success
[pop3s] tcp proxy listen port [995]
new proxy [pop3s] success
[imap] tcp proxy listen port [143]
new proxy [imap] success
[imaps] tcp proxy listen port [993]
new proxy [imaps] success
```

## You're done!

Have fun configuring your new Mailserver! I can't cover everything in this guide, but I hope I included everything important. If you need help with anything, check out the [Mailcow Documentation](https://mailcow.github.io/mailcow-dockerized-docs/).
