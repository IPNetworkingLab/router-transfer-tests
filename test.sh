#!/bin/bash -e
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2025, Matthieu Baerts.

if [ "${DEBUG}" = 1 ]; then
	set -x
fi

: "${INPUT_TRACES:=$([[ "${1}" = "auto-"* ]] && echo 1)}"

export NS=rt
export HOSTS=(pho cli cpe cell net srv)

# TODO: make sure the following code is published
# TODO: don't include these env vars here
export H3SERVPATH="../h3server/run-server.sh"
export CURLPATH="../../curlh3/curl/src/curl"
export CONDAPATH="/home/pbertrandvan/miniconda3"
export AIOQUICPATH="/home/pbertrandvan/Documents/router_transfer/aioquic_transfer/modified-aioquic"

cleanup()
{
	local suffix
	for suffix in "${HOSTS[@]}"; do
		local ns="${NS}_${suffix}"
		ip netns pids "${ns}" | xargs -r kill
		ip netns del "${ns}" >/dev/null 2>&1
	done
}

trap cleanup EXIT

# $1: ns ; $2: dev ; $3: ip-pre ; $4: ip-suff
ip_addr_del()
{
	ip -n "${1}" addr del dev "${2}" "10.0.${3}.${4}/24"
	# ip -n "${1}" addr del dev "${2}" "dead:beef:${3}::${4}/64" ## removed when the iface is down
}

# $1: ns ; $2: dev ; $3: ip-pre ; $4: ip-suff
ip_addr_add()
{
	ip -n "${1}" addr add dev "${2}" "10.0.${3}.${4}/24"
	ip -n "${1}" addr add dev "${2}" "dead:beef:${3}::${4}/64" nodad
}

# $1: ns ; $2: dev ; $3: ip-pre ; $4: ip-suff ; $5: metric
ip_route_add_default()
{
	ip -n "${1}" route add dev "${2}" default via "10.0.${3}.${4}" metric "${5}"
	ip -n "${1}" route add dev "${2}" default via "dead:beef:${3}::${4}" metric "${5}"
}

# $1: ns ; $2: dev ; $3: ip-pre ; $4: ip-suff ; $5: ip-via-pre ; $6: ip-via-suff
ip_route_add_prefix()
{
	ip -n "${1}" route add dev "${2}" "10.0.${3}.${4}/24" via "10.0.${5}.${6}"
	ip -n "${1}" route add dev "${2}" "dead:beef:${3}::${4}/64" via "dead:beef:${5}::${6}"

}

# $1: ns ; $2: dev ; $3: ip-pre ; $4: ip-suff ; $5: id ; $6: flags
ip_mptcp_add()
{
	ip -n "${1}" mptcp endpoint add "10.0.${3}.${4}" dev "${2}" id "${5}" "${@:6}"
	ip -n "${1}" mptcp endpoint add "dead:beef:${3}::${4}" dev "${2}" id "$((${5} * 10))" "${@:6}"
}

# $1: ns ; $2: dev ; $3: id
ip_mptcp_del()
{
	ip -n "${1}" mptcp endpoint del id "${2}"
	ip -n "${1}" mptcp endpoint del id "$((${2} * 10))"
}

cpe_switch_off()
{
	ip -n "${NS}_cpe" link set dev "pho" down
	ip -n "${NS}_cpe" link set dev "cli" down
	ip -n "${NS}_pho" link set "cpe" down
	ip_addr_del "${NS}_pho" cpe 0 2
	ip_mptcp_del "${NS}_pho" 1
	ip -n "${NS}_cli" link set "cpe" down
	ip_addr_del "${NS}_cli" cpe 0 3
	ip_mptcp_del "${NS}_cli" 1

	ip -n "${NS}_pho" link set "cli" up
	ip_addr_add "${NS}_pho" cli 1 1

	ip -n "${NS}_cli" link set "pho" up
	ip_addr_add "${NS}_cli" pho 1 2
	ip_route_add_default "${NS}_cli" pho 1 1 200
	sleep .1 # making sure the route is ready
	ip_mptcp_add "${NS}_cli" pho 1 2 2 subflow
}

cpe_switch_on()
{
	ip -n "${NS}_pho" link set "cli" down
	ip_addr_del "${NS}_pho" cli 1 1
	ip -n "${NS}_cli" link set "pho" down
	ip_addr_del "${NS}_cli" pho 1 2
	ip_mptcp_del "${NS}_cli" 2

	ip -n "${NS}_cpe" link set dev "pho" up
	ip -n "${NS}_cpe" link set dev "cli" up

	ip -n "${NS}_pho" link set "cpe" up
	ip_addr_add "${NS}_pho" cpe 0 2
	ip_route_add_default "${NS}_pho" cpe 0 1 100
	sleep .1 # making sure the route is ready
	ip_mptcp_add "${NS}_pho" cpe 0 2 1 subflow

	ip -n "${NS}_cli" link set "cpe" up
	ip_addr_add "${NS}_cli" cpe 0 3
	ip_route_add_default "${NS}_cli" cpe 0 1 100
	sleep .1 # making sure the route is ready
	ip_mptcp_add "${NS}_cli" cpe 0 3 1 subflow
}

# $1: IP server
iperf_test()
{
	ip netns exec "${NS}_srv" mptcpize run iperf3 -s -D
	sleep .1 # making sure the daemon is launched
	ip netns exec "${NS}_cli" mptcpize run iperf3 -c "${1}" -t 999 -i 0 &
	ip netns exec "${NS}_cli" ifstat -b -i cpe,pho &
	for _ in $(seq 4); do
		sleep 5
		cpe_switch_off
		sleep 5
		cpe_switch_on
	done
	killall iperf3 ifstat
}

# $1: IP server
aioquic_test()
{
	ip netns exec "${NS}_srv" $H3SERVPATH &
	sleep 5 # making sure the server is launched
	ip netns exec "${NS}_cli" $AIOQUICPATH/run_h3.sh "${1}" &
	ip netns exec "${NS}_cli" ifstat -b -i cpe,pho &
	for _ in $(seq 4); do
		sleep 5
		cpe_switch_off
		sleep 5
		cpe_switch_on
	done
	killall hypercorn http3_client ifstat
}

# $1: mode
start_capture()
{
	local out="traces/"
	mkdir -p "${out}"
	out+="$(date +%Y%m%d%H%M%S)_$(git describe --always --dirty)_${1}"

	# capture on the net router, having access to all paths
	local iface ifaces=(cpe pho srv)
	for iface in "${ifaces[@]}"; do
		ip netns exec "${NS}_net" \
			tcpdump -i "${iface}" -s 150 --immediate-mode --packet-buffered \
				-w "${out}_${iface}.pcap" &
	done

	# give some time to TCPDump to start
	for _ in $(seq 10); do
		local stop=1
		for iface in "${ifaces[@]}"; do
			[ ! -s "${iface}" ] && stop=0
		done
		[ "${stop}" = 1 ] && break
		sleep 0.1
	done
}

setup()
{
	local suffix
	for suffix in "${HOSTS[@]}"; do
		local ns="${NS}_${suffix}"
		ip netns add "${ns}"
		ip -n "${ns}" link set lo up
		ip netns exec "${ns}" sysctl -wq net.ipv4.ip_forward=1
		ip netns exec "${ns}" sysctl -wq net.ipv6.conf.all.forwarding=1
	done

	#        .3.2
	#     pho ------------------- .3.1
	# .1.1 | \ .0.2              \
	#      |  === cpe ----------- net ------- srv
	# .1.2 | / .0.1  .2.2     .2.1  .4.1   .4.2
	#     cli .0.3

	ip link add "cli" netns "${NS}_pho" type veth peer name "pho" netns "${NS}_cli"

	ip link add "pho" netns "${NS}_cpe" type veth peer name "cpe" netns "${NS}_pho"
	ip link add "cli" netns "${NS}_cpe" type veth peer name "cpe" netns "${NS}_cli"

	ip link add "pho" netns "${NS}_net" type veth peer name "net" netns "${NS}_pho"
	ip link add "cpe" netns "${NS}_net" type veth peer name "net" netns "${NS}_cpe"
	ip link add "srv" netns "${NS}_net" type veth peer name "net" netns "${NS}_srv"

	ip -n "${NS}_pho" link set "cpe" up
	ip_addr_add "${NS}_pho" cpe 0 2
	ip_route_add_default "${NS}_pho" cpe 0 1 100
	ip_mptcp_add "${NS}_pho" cpe 0 2 1 subflow
	ip -n "${NS}_pho" link set "net" up
	ip_addr_add "${NS}_pho" net 3 2
	ip_route_add_default "${NS}_pho" net 3 1 200
	ip_mptcp_add "${NS}_pho" net 3 2 2 subflow backup
	tc -n "${NS}_pho" qdisc add dev "net" root netem rate 20mbit delay 10ms

	ip -n "${NS}_cli" link set "cpe" up
	ip_addr_add "${NS}_cli" cpe 0 3
	ip_route_add_default "${NS}_cli" cpe 0 1 100
	ip_mptcp_add "${NS}_cli" cpe 0 3 1 subflow

	ip -n "${NS}_cpe" link add name "br" type bridge
	ip_addr_add "${NS}_cpe" br 0 1
	ip -n "${NS}_cpe" link set dev "br" up
	ip -n "${NS}_cpe" link set dev "pho" master "br"
	ip -n "${NS}_cpe" link set dev "cli" master "br"
	ip -n "${NS}_cpe" link set dev "pho" up
	ip -n "${NS}_cpe" link set dev "cli" up
	ip -n "${NS}_cpe" link set "net" up
	ip_addr_add "${NS}_cpe" net 2 2
	ip_route_add_default "${NS}_cpe" net 2 1 100
	tc -n "${NS}_cpe" qdisc add dev "net" root netem rate 40mbit delay 5ms

	ip -n "${NS}_net" link set "pho" up
	ip_addr_add "${NS}_net" pho 3 1
	tc -n "${NS}_net" qdisc add dev "pho" root netem rate 20mbit delay 10ms
	ip -n "${NS}_net" link set "cpe" up
	ip_addr_add "${NS}_net" cpe 2 1
	tc -n "${NS}_net" qdisc add dev "cpe" root netem rate 40mbit delay 5ms
	ip -n "${NS}_net" link set "srv" up
	ip_addr_add "${NS}_net" srv 4 1
	ip_route_add_default "${NS}_net" srv 4 2 100
	# not to have to deal with NATs
	ip_route_add_prefix "${NS}_net" cpe 0 0 2 2
	ip_route_add_prefix "${NS}_net" pho 1 0 3 2

	ip -n "${NS}_srv" link set "net" up
	ip_addr_add "${NS}_srv" net 4 2
	ip_route_add_default "${NS}_srv" net 4 1 100
	ip -n "${NS}_srv" mptcp limits set subflows 8
}

setup

if [ "${INPUT_TRACES}" = 1 ]; then
	start_capture "${1}"
fi

case "${1}" in
	"auto-tcp-v4")
		iperf_test 10.0.4.2
		;;
	"auto-tcp-v6")
		iperf_test dead:beef:4::2
		;;
	"auto-quic-v4")
		aioquic_test 10.0.4.2
		;;
	"auto-quic-v6")
		aioquic_test dead:beef:4::2
		;;
	*)
		export -f cpe_switch_on cpe_switch_off iperf_test aioquic_test start_capture
		echo "Use 'ip netns' to list the netns."
		echo "Then use 'ip netns exec <NETNS> <CMD>' to execute a command in the netns."
		bash
		;;
esac
