#!/bin/bash

dec2ip () {
    local ip dec=$@
    unset delim
    for e in {3..0}
    do
        ((octet = dec / (256 ** e) ))
        ((dec -= octet * 256 ** e))
        ip+=$delim$octet
        delim=.
    done
    MYd2i=$(printf '%s\n' "$ip")
    return 0
}

ip2dec () {
    local a b c d ip=$@
    IFS=. read -r a b c d <<< "$ip"
    MYi2d=$(printf '%d\n' "$((a * 256 ** 3 + b * 256 ** 2 + c * 256 + d))")
    return 0
}


create() {
	echo -n "client name: "
	read client

	echo -n "client public key: "
	read pk

	echo -n "Generating config..."

	if [ -r ${WGDIR}/client-cfgs/${client}.conf ]
	then
		echo -e "failed.\n ${client} configuration already exists."
		ls -alF ${WGDIR}/client-cfgs/${client}.conf
		exit 1
	fi

	IP4SNb=${WANv4##*/}			# subnet bits
	IP4SNs=$(( 2 ** ( 32 - IP4SNb) ))	# Max addresses

	SERIAL=$(grep '\.4wan' ${WGDIR}/clients.conf | wc -l)
	SERIAL=$((SERIAL + 2))    # get the next sequence, add an additional one to the offset for zero's based counting.
	if [ ${SERIAL} -gt ${IP4SNs} ];
	then
		echo "failed:  out of IP4 pool space"
		exit 1
	fi

	# word-based math is easy!
	IP4SN=${WANv4//*\//}
	ip2dec "${WANv4%/*}"
	IP4d=${MYi2d}
	IP4d=$(( $IP4d + $SERIAL ))
	dec2ip "${IP4d}"
	IP4="${MYd2i}/${IP4SNb}"

	SNv6=${WANv6%::*}
	SNv6=${SNv6##*:}
	SNv6D=$((16#${SNv6}))
	SNv6D=$((SNv6D + ${SERIAL}))	# use the IPv4 serial as the IPv6 serial, for reservations
	nSNv6=$(printf "%x" ${SNv6D})
	WANv6=${WANv6//:$SNv6::/:$nSNv6::}

	###

	# half-word based math is harder.  :-(
	# for /56's out of a /40?  yea.....
	#  1234:5678:9abc:def0:: ..
	#             ^ ^  ^
	#         40-/  |  \-56
	#              48
	# so:
	# LANv6=1234:5678:9aXX:XXhh::/40
	# the 16bits of [XX:XX] are what we can change
	# the previous bits are network, and the hh::...  are all downstream
	#  This isn't really pretty, but it works.  Ish.
	SNv6=${LANv6%::*}	# 1234:5678:9aXX:XXhh
	SNv6a=${SNv6%??:*}	# 1234:5678:9a
	SNv6b=${SNv6#*:*:??}	# XX:XXhh
	SNv6b=${SNv6b%??}	# XX:XX
	SNv6b=${SNv6b//:/}	# XXXX
	SNv6D=$((16#${SNv6b}))
	SNv6D=$((SNv6D + ${SERIAL}))	# use the IPv4 serial as the IPv6 serial, for reservations
	nSNv6=$(printf "%04x" ${SNv6D})
	nSNv62=${nSNv6#??}
	nSNv61=${nSNv6%??}
	LANv6="${SNv6a}${nSNv61}:${nSNv62}00::/56"

	DEV=$(awk 'BEGIN { IGNORECASE=1 } /^[a-z0-9]+[ \t]+00000000/ { print $1 }' /proc/net/route 2>/dev/null)
	MyIntIPv4=$(ip -4 addr show dev ${DEV} scope global)
	MyIntIPv4=${MyIntIPv4##*inet }
	MyIntIPv4=${MyIntIPv4%%brd*}
	MyIntIPv4=${MyIntIPv4%%/*}

	echo "${client}.4wan = ${IP4}" >> ${WGDIR}/clients.conf
	echo "${client}.6wan = ${WANv6%/*}/64" >> ${WGDIR}/clients.conf
	echo "${client}.6lan = ${LANv6%/*}/56" >> ${WGDIR}/clients.conf
	echo ""  >> ${WGDIR}/clients.conf

	mkdir -p ${WGDIR}/client-cfgs/

	echo "[Interface]
PrivateKey = [pending]
Address = ${IP4}/${IP4SN}
ListenPort = 51820
PostUp = ip -4 route replace default dev sixbroker
PostUp = ip -4 route add 10.10.10.1 via 192.168.1.1
PostUp = ip -6 addr dev sixbroker add ${W6IP}::1/64
PostDown = ip -4 route replace default via 192.168.1.1
PostDown = ip -4 route del 10.10.10.1 via 192.168.1.1
PostDown = ip -6 addr dev sixbroker del ${W6IP}::1/64

[Peer]
PublicKey = ${SK}
Endpoint = ${MyIntIPv4}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
" >${WGDIR}/client-cfgs/${client}.conf

	echo "${pk}" > ${WGDIR}/clients/${client}.publickey

	echo "...done"
}
### end of create()

remove() {
	ERR=0

	echo -n "remove which client? "
	read client

	if [ -n "${client}" -a -r "${WGDIR}/client-cfgs/${client}.conf" ]
	then
		ls -alF ${WGDIR}/client-cfgs/${client}.conf
	else
		echo "Can't find config file for ${client:-(null)}"
		ERR=$((${ERR} + 1))
	fi

	if [ -n "${client}" -a -r "${WGDIR}/clients/${client}.publickey" ]
	then
		ls -alF "${WGDIR}/clients/${client}.publickey"
	else
		echo "Can't find public keyfile for ${client:-(null)}"
		ERR=$((${ERR} + 1))
	fi

	if [ -n "${client}" -a -n "$(grep -iE """${client}\.[46][lw]an""" ${WGDIR}/clients.conf)" ]
	then
		grep -iE "${client}\.[46][lw]an" ${WGDIR}/clients.conf
	else
		echo "Can't find network config for ${client:-(null)}"
		ERR=$((${ERR} + 1))
	fi

	if [ ${ERR} -gt 0 ]
	then
		echo "one or more errors occured.  Please clean up manually"
		exit 1
	fi
	
	echo -en "\nReally remove client ${client}? "
	read remove
	
	remove=${remove,,}
	remove=${remove%??}

	if [ "${remove:-n}" = "y" ]
	then
		sed -i "/${client}.[46][lw]an/ { d; }" ${WGDIR}/clients.conf
		rm -f "${WGDIR}/clients/${client}.publickey" "${WGDIR}/client-cfgs/${client}.conf"
		
		echo "client ${client} has been removed"
	else
		echo "client not removed"
		
	fi
	exit 0
}

###  MAIN ###

[[ -r /etc/default/wgserver ]] && . /etc/default/wgserver
if [ -z "${WGDIR}" -o ! -d "${WGDIR}" ];
then
	echo "Missing global config file '/etc/default/wgserver'"
	echo "Can't continue"
	exit 1
fi

case $1 in
	create) create
		;;
	remove) remove
		;;
	*)	echo "Usage: ${0} [create|remove]"
		;;
esac

exit 0
