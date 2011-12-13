# Copyright (c) 2007-2008 Roy Marples <roy@marples.name>
# Released under the 2-clause BSD license.

_ip()
{
	if [ -x /bin/ip ]; then
		echo /bin/ip
	else
		echo /sbin/ip
	fi
}

iproute2_depend()
{
	program $(_ip)
	provide interface
	after ifconfig
}

_up()
{
	ip link set "${IFACE}" up
}

_down()
{
	ip link set "${IFACE}" down
}

_exists()
{
	grep -Eq "^[[:space:]]*${IFACE}:" /proc/net/dev
}

_ifindex()
{
	local line= i=-2
	while read line; do
		: $(( i += 1 ))
		[ ${i} -lt 1 ] && continue
		case "${line}" in
			"${IFACE}:"*) echo "${i}"; return 0;;
		esac
	done < /proc/net/dev

	# Return the next available index
	: $(( i += 1 ))
	echo "${i}"
	return 1
}

_is_wireless()
{
	# Support new sysfs layout
	[ -d /sys/class/net/"${IFACE}"/wireless -o \
		-d /sys/class/net/"${IFACE}"/phy80211 ] && return 0

	[ ! -e /proc/net/wireless ] && return 1
	grep -Eq "^[[:space:]]*${IFACE}:" /proc/net/wireless
}

_set_flag()
{
	local flag=$1 opt="on"
	if [ "${flag#-}" != "${flag}" ]; then
		flag=${flag#-}
		opt="off"
	fi
	ip link set "${IFACE}" "${flag}" "${opt}"
}

_get_mac_address()
{
	local mac=$(LC_ALL=C ip link show "${IFACE}" | sed -n \
		-e 'y/abcdef/ABCDEF/' \
		-e '/link\// s/^.*\<\(..:..:..:..:..:..\)\>.*/\1/p')

	case "${mac}" in
		00:00:00:00:00:00);;
		44:44:44:44:44:44);;
		FF:FF:FF:FF:FF:FF);;
		"");;
		*) echo "${mac}"; return 0;;
	esac

	return 1
}

_set_mac_address()
{
	ip link set "${IFACE}" address "$1"
}

_get_inet_addresses()
{
	LC_ALL=C ip -family inet addr show "${IFACE}" | \
	sed -n -e 's/.*inet \([^ ]*\).*/\1/p'
}

_get_inet_address()
{
	set -- $(_get_inet_addresses)
	[ $# = "0" ] && return 1
	echo "$1"
}

_add_address()
{
	if [ "$1" = "127.0.0.1/8" -a "${IFACE}" = "lo" ]; then
		ip addr add "$@" dev "${IFACE}" 2>/dev/null
		return 0
	fi

	local address netmask broadcast peer anycast label scope
	local valid_lft preferred_lft home nodad
	address="$1" ; shift
	while [ -n "$*" ]; do
		case "$1" in
			netmask)
				netmask="/$(_netmask2cidr "$2")" ; shift ; shift ;;
			broadcast|brd)
				broadcast="broadcast $2" ; shift ; shift ;;
			pointopoint|pointtopoint|peer)
				peer="peer $2" ; shift ; shift ;;
			anycast|label|scope|valid_lft|preferred_lft)
				eval "$1=$2" ; shift ; shift ;;
			home|nodad)
				eval "$1=$1" ; shift ;;
		esac
	done

	# Always scope lo addresses as host unless specified otherwise
	if [ "${IFACE}" = "lo" ]; then
		[ -z "$scope" ] && scope="scope host"
	fi

	# figure out the broadcast address if it is not specified
	[ -z "$broadcast" ] && broadcast="broadcast +"

	set -- "${address}${netmask}" $peer $broadcast $anycast $label $scope dev "${IFACE}" $valid_lft $preferred_lft $home $nodad
	veinfo ip addr add "$@"
	ip addr add "$@"
}

_add_route()
{
	local family=

	if [ "$1" = "-A" -o "$1" = "-f" -o "$1" = "-family" ]; then
		family="-f $2"
		shift; shift
	fi

	if [ $# -eq 3 ]; then
		set -- "$1" "$2" via "$3"
	elif [ "$3" = "gw" ]; then
		local one=$1 two=$2
		shift; shift; shift
		set -- "${one}" "${two}" via "$@"
	fi

	local cmd= have_metric=false
	while [ -n "$1" ]; do
		case "$1" in
			metric) cmd="${cmd} $1"; have_metric=true;;
			netmask) cmd="${cmd}/$(_netmask2cidr "$2")"; shift;;
			-host|-net);;
			*) cmd="${cmd} $1";;
		esac
		shift
	done

	# We cannot use a metric if we're using a nexthop
	if ! ${have_metric} && \
		[ -n "${metric}" -a \
			"${cmd##* nexthop }" = "$cmd" ]
	then
		cmd="${cmd} metric ${metric}"
	fi

	veinfo ip ${family} route append ${cmd} dev "${IFACE}"
	ip ${family} route append ${cmd} dev "${IFACE}"
	eend $?
}

_delete_addresses()
{
	ip addr flush dev "${IFACE}" scope global 2>/dev/null
	ip addr flush dev "${IFACE}" scope site 2>/dev/null
	if [ "${IFACE}" != "lo" ]; then
		ip addr flush dev "${IFACE}" scope host 2>/dev/null
	fi
	return 0
}

_has_carrier()
{
	return 0
}

_tunnel()
{
	ip tunnel "$@"
}

# This is just to trim whitespace, do not add any quoting!
_trim() {
	echo $*
}

# This is our interface to Routing Policy Database RPDB
# This allows for advanced routing tricks
_ip_rule_runner() {
	local cmd rules OIFS="${IFS}"
	cmd="$1"
	rules="$2"
	veindent
	local IFS="$__IFS"
	for ru in $rules ; do
		unset IFS
		ruN="$(_trim "${ru}")"
		[ -z "${ruN}" ] && continue
		vebegin "${cmd} ${ruN}"
		ip rule ${cmd} ${ru}
		veend $?
		local IFS="$__IFS"
	done
	IFS="${OIFS}"
	veoutdent
}

iproute2_pre_start()
{
	local tunnel=
	eval tunnel=\$iptunnel_${IFVAR}
	if [ -n "${tunnel}" ]; then
		# Set our base metric to 1000
		metric=1000
		# Bug#347657: If the mode is 'ipip6' or 'ip6ip6', the -6 must be passed
		# to iproute2 during tunnel creation.
		local ipproto=''
		[ "${tunnel##mode ipip6}" != "${tunnel}" ] && ipproto='-6'
		[ "${tunnel##mode ip6ip6}" != "${tunnel}" ] && ipproto='-6'

		ebegin "Creating tunnel ${IFVAR}"
		ip ${ipproto} tunnel add ${tunnel} name "${IFACE}"
		eend $? || return 1
		_up
	fi

	# MTU support
	local mtu=
	eval mtu=\$mtu_${IFVAR}
	[ -n "${mtu}" ] && ip link set "${IFACE}" mtu "${mtu}"

	# TX Queue Length support
	local len=
	eval len=\$txqueuelen_${IFVAR}
	[ -n "${len}" ] && ip link set "${IFACE}" txqueuelen "${len}"

	return 0
}

_iproute2_ipv6_tentative()
{
	# Only check tentative when we have a carrier.
	LC_ALL=C ip link show dev "${IFACE}" | grep -q "NO-CARRIER" && return 1
	LC_ALL=C ip addr show dev "${IFACE}" | \
		grep -q "^[[:space:]]*inet6 .* tentative"
}

iproute2_post_start()
{
	local n=5

	# Kernel may not have IP built in
	if [ -e /proc/net/route ]; then
		local rules="$(_get_array "rules_${IFVAR}")"
		if [ -n "${rules}" ]; then
			if ! ip rule list | grep -q "^"; then
				eerror "IP Policy Routing (CONFIG_IP_MULTIPLE_TABLES) needed for ip rule"
			else
				service_set_value "ip_rule" "${rules}"
				einfo "Adding RPDB rules"
				_ip_rule_runner add "${rules}"
			fi
		fi
		ip route flush table cache dev "${IFACE}"
	fi

	if _iproute2_ipv6_tentative; then
		ebegin "Waiting for IPv6 addresses"
		while [ $n -ge 0 ]; do
			_iproute2_ipv6_tentative || break
			sleep 1
			: $(( n -= 1 ))
		done
		[ $n -ge 0 ]
		eend $?
	fi

	return 0
}

iproute2_post_stop()
{
	# Kernel may not have IP built in
	if [ -e /proc/net/route ]; then
		local rules="$(service_get_value "ip_rule")"
		if [ -n "${rules}" ]; then
			einfo "Removing RPDB rules"
			_ip_rule_runner del "${rules}"
		fi

		# Only do something if the interface actually exist
		if _exists; then
			ip route flush table cache dev "${IFACE}"
		fi
	fi

	# Don't delete sit0 as it's a special tunnel
	if [ "${IFACE}" != "sit0" ]; then
		if [ -n "$(ip tunnel show "${IFACE}" 2>/dev/null)" ]; then
			ebegin "Destroying tunnel ${IFACE}"
			ip tunnel del "${IFACE}"
			eend $?
		fi
	fi
}

# Is the interface administratively/operationally up?
# The 'UP' status in ifconfig/iproute2 is the administrative status
# Operational state is available in iproute2 output as 'state UP', or the
# operstate sysfs variable.
# 0: up
# 1: down
# 2: invalid arguments
is_admin_up()
{
	local iface="$1"
	[ -z "$iface" ] && iface="$IFACE"
	ip link show dev $iface | \
	sed -n '1,1{ /[<,]UP[,>]/{ q 0 }}; q 1; '
}

is_oper_up()
{
	local iface="$1"
	[ -z "$iface" ] && iface="$IFACE"
	read state </sys/class/net/"${iface}"/operstate
	[ "x$state" = "up" ]
}
