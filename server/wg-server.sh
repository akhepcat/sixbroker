#!/bin/bash
#
#######################################
# Programmatically assigned, no touchie

IFACE=wg-hub	# I mean, you COULD change this one in the defaults config file, or even here, but there's really no reason to.

PROG="${0##*/}"
CONFIG=${PROG//wg-/}; CONFIG=${CONFIG//\.*/}.conf;
HN=$(hostname)
OUTSIDE=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route)  # one liner default IPv4 route interface grabber

# override defaults with local settings
if [ ! -r /etc/default/wgserver ]
then
	echo "Can't locate /etc/default/wgserver for base configuration."
	exit 1
fi
. /etc/default/wgserver

do_help() {
	echo "server help:"
	echo "start/up	- Starts the server using the current configuration."
	echo "stop/down - Stops the server and removes any routes from use."
	echo "start_nat - Adds IPtables rules to provide NAT functionality (automatic during 'start/up')"
	echo "stop_nat  - Removes the IPtables rules that provide NAT functionality (automatic during 'stop/down')"
	echo "clients   - Regenerates the client.conf and the client portion of the server configuration file."
	echo "server    - Regenerates the server.conf and keys, if needed"
	echo "status    - Shows the status of the wireguard VPN system"
	echo ""
}

do_keys() {
	server_keys
	client_keys
}

client_keys() {
	VERBOSE=$1

	for client in $(cd ${WGDIR}/clients; ls *.publickey);
	do
		[[ -n "${VERBOSE}" ]] && echo "checking client: ${client//.publickey/}"

		key=$(head -1 ${WGDIR}/clients/${client})
		if [ -z "$(grep """${key}""" ${WGDIR}/${CONFIG})" ];
		then
			wg pubkey < ${WGDIR}/clients/${client} >/dev/null 2>&1
			if [ $? -eq 0 ]
			then
				ACL4=""; ACL6="";
				[[ -n "${VERBOSE}" ]] && echo "adding new config for ${client//.publickey/}"
				ACL4=$(grep -i "${client//.publickey/}.4wan" ${WGDIR}/clients.conf | sed 's/.*=//; s|/.*||g; s/ //g')
				ACL6=$(grep -i "${client//.publickey/}.6wan" ${WGDIR}/clients.conf | sed 's/.*=//; s|/.*||g; s/ //g')
				[[ -n "${ACL4}" ]] && ACL4="${ACL4}/32" || ACL4="0.0.0.0/0"
				[[ -n "${ACL6}" ]] && ACL6="${ACL6}2/128" || ACL6="::/0"
				echo "[Peer]" >> ${WGDIR}/${CONFIG}
				echo "PublicKey = ${key}" >> ${WGDIR}/${CONFIG}
				echo "AllowedIPs = ${ACL4}, ${ACL6}"  >> ${WGDIR}/${CONFIG}
				echo ""  >> ${WGDIR}/${CONFIG}
			else
				[[ -n "${VERBOSE}" ]] && echo "invalid public key for ${client//.publickey/}, skipping"
			fi
		fi
	done
}

server_conf() {
	# We need to fix-up the server listen-port.  That's it!

	if [ -r "${WGDIR}/${CONFIG}" ]
	then
		if [ -z "$(grep -iw """ListenPort.*${SPORT}""" ${WGDIR}/${CONFIG})" ]
		then
			sed -i "s/ListenPort.*/ListenPort = ${SPORT}/g" ${WGDIR}/${CONFIG}
		fi
	else
		# conf file doesn't exist, so create it
		echo "[Interface]" > ${WGDIR}/${CONFIG}
		echo "ListenPort = ${SPORT}" >> ${WGDIR}/${CONFIG}
		echo "PrivateKey = " $(cat ${WGDIR}/private/${HN}.privatekey) >> ${WGDIR}/${CONFIG}
		echo "" >> ${WGDIR}/${CONFIG}
	fi
}


server_keys() {
	VERBOSE=$1
	
	if [ ! -r ${WGDIR}/private/${HN}.privatekey ]; 
	then
		[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.privatekey not found"
		if [ ! -r ${WGDIR}/private/${HN}.publickey ];
		then
			[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.publickey not found, generating new keys"
			wg genkey | tee ${WGDIR}/private/${HN}.privatekey | wg pubkey > ${WGDIR}/private/${HN}.publickey
		else
			# public, but no private...
			echo "public key found, but no private. are we a client?"
			exit 1
		fi
	else
		# readable private key...
		if [ ! -r ${WGDIR}/private/${HN}.publickey ];
		then
			[[ -n "${VERBOSE}" ]] && echo "server: ${HN}.publickey not found, generating new public key from existing ${HN}.privatekey"
			wg genkey | tee ${WGDIR}/private/${HN}.privatekey | wg pubkey > ${WGDIR}/private/${HN}.publickey
		fi
	fi

	PK=$(head -1 ${WGDIR}/private/${HN}.privatekey)
	if [ ! -r "${WGDIR}/${CONFIG}" ];
	then
		server_conf
	fi
	if [ -z "$(grep ${PK} ${WGDIR}/${CONFIG})" ];
	then
		[[ -n "${VERBOSE}" ]] && echo "replacing server privatekey in config file"
		sed -i "s/PrivateKey.*/PrivateKey = ${PK}/g" ${WGDIR}/${CONFIG}
	fi
}

status() {
	ip link show ${IFACE} >/dev/null 2>&1
	if [ $? -eq 0 ]; then
		wg show ${IFACE}
		if [ $? -eq 0 ]; then
			echo -e "\nIPv4 hub:"
			ip -4 route show dev ${IFACE}

			echo -en "\niptables: IPv4 natting is "
			iptables -t nat -C POSTROUTING -s ${WANv4} -o ${OUTSIDE} -j MASQUERADE >/dev/null 2>&1
			if [ $? -ne 0 ]; then
				echo -n "not "
			fi
			echo "enabled"

			echo -en "\nIPv6 forwarding is "
			if [ 1 -eq $(cat /proc/sys/net/ipv6/conf/all/forwarding) ];
			then
				echo "enabled"
				echo -e "\nClient IPv6 tunneled routes:"
				ip -6 route show dev ${IFACE}
			else
				echo "disabled"
			fi
		fi
	else
		echo "not running"
	fi
}

start_nat() {
	iptables -A FORWARD -i ${IFACE} -o ${OUTSIDE} -m conntrack --ctstate NEW -j ACCEPT
	iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
	iptables -t nat -A POSTROUTING -s ${WANv4} -o ${OUTSIDE} -j MASQUERADE

	echo 1 >/proc/sys/net/ipv4/conf/all/forwarding
}

start() {
	server_conf

	[[ -z "$(lsmod|grep wireguard)" ]] && modprobe wireguard


	ip link show ${IFACE} >/dev/null 2>&1 || ip link add dev ${IFACE} type wireguard
	ip address add dev ${IFACE} ${WANv4//.0\//.1\/}
	for CLIENT in $(grep """\.6wan""" ${WGDIR}/clients.conf | cut -f 1 -d.)
	do
		WANv6=$(grep """${CLIENT}\.6wan""" ${WGDIR}/clients.conf | cut -f 2 -d=)
		LANv6=$(grep """${CLIENT}\.6lan""" ${WGDIR}/clients.conf | cut -f 2 -d=)

		ip -6 address add dev ${IFACE} ${WANv6//::/::1}
		[[ -n "${LANv6}" ]] && ip -6 route add dev ${IFACE} ${LANv6} via ${WANv6//::*/::2}
	done

	ip link set ${IFACE} up
	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	
	wg setconf ${IFACE}  ${WGDIR}/${CONFIG}

	wg show ${IFACE}

	iptables -I INPUT -p udp -m udp --dport ${SPORT} -j ACCEPT

	start_nat
}

stop_nat() {
	echo 0 >/proc/sys/net/ipv4/conf/all/forwarding

        iptables -D FORWARD -i ${IFACE} -o ${OUTSIDE} -m conntrack --ctstate NEW -j ACCEPT
        iptables -D FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -t nat -D POSTROUTING -s ${WANv4} -o ${OUTSIDE} -j MASQUERADE
}

stop() {
	echo -n "wg server is "
	if [ -n "$(wg show)" ]
	then
		iptables -D INPUT -p udp -m udp --dport ${SPORT} -j ACCEPT

		stop_nat

		ip link show ${IFACE} >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			ip link set ${IFACE} down
			ip link del dev ${IFACE}
		fi
	else
		echo -n "already "
	fi

	echo "stopped"
}


case ${1} in
	start|up) do_keys && start
		;;
	stop|down) stop
		;;
	start_nat) start_nat
		;;
	stop_nat) stop_nat
		;;
	clients) client_keys verbose
		;;
	server) server_keys verbose
		;;
	status) status
		;;
	help) do_help
		;;
	*) echo "${PROG} [start/up|stop/down|status|clients|server|help]"
		;;
esac
