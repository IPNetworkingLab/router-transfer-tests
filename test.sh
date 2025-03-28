#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2025, Matthieu Baerts.

export NS=rt
export HOSTS=(pho cli cpe cell net srv)

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

cpe_switch_off()
{
	ip -n "${NS}_cpe" link set dev "pho" down
	ip -n "${NS}_cpe" link set dev "cli" down
	ip -n "${NS}_pho" link set "cpe" down
	ip -n "${NS}_pho" addr del dev "cpe" 10.0.0.2/24
	ip -n "${NS}_pho" mptcp endpoint del id 1
	ip -n "${NS}_cli" link set "cpe" down
	ip -n "${NS}_cli" addr del dev "cpe" 10.0.0.3/24
	ip -n "${NS}_cli" mptcp endpoint del id 1

	ip -n "${NS}_pho" link set "cli" up
	ip -n "${NS}_pho" addr add dev "cli" 10.0.1.1/24

	ip -n "${NS}_cli" link set "pho" up
	ip -n "${NS}_cli" addr add dev "pho" 10.0.1.2/24
	ip -n "${NS}_cli" route add default via 10.0.1.1 dev "pho" metric 200
	sleep .1 # making sure the route is ready
	ip -n "${NS}_cli" mptcp endpoint add 10.0.1.2 dev "pho" id 2 subflow
}

cpe_switch_on()
{
	ip -n "${NS}_pho" link set "cli" down
	ip -n "${NS}_pho" addr del dev "cli" 10.0.1.1/24
	ip -n "${NS}_cli" link set "pho" down
	ip -n "${NS}_cli" addr del dev "pho" 10.0.1.2/24
	ip -n "${NS}_cli" mptcp endpoint del id 2

	ip -n "${NS}_cpe" link set dev "pho" up
	ip -n "${NS}_cpe" link set dev "cli" up

	ip -n "${NS}_pho" link set "cpe" up
	ip -n "${NS}_pho" addr add dev "cpe" 10.0.0.2/24
	ip -n "${NS}_pho" route add default via 10.0.0.1 dev "cpe" metric 100
	sleep .1 # making sure the route is ready
	ip -n "${NS}_pho" mptcp endpoint add 10.0.0.2 dev "cpe" id 1 subflow

	ip -n "${NS}_cli" link set "cpe" up
	ip -n "${NS}_cli" addr add dev "cpe" 10.0.0.3/24
	ip -n "${NS}_cli" route add default via 10.0.0.1 dev "cpe" metric 100
	sleep .1 # making sure the route is ready
	ip -n "${NS}_cli" mptcp endpoint add 10.0.0.3 dev "cpe" id 1 subflow
}

iperf_test()
{
	ip netns exec rt_srv mptcpize run iperf3 -s -D
	sleep .1 # making sure the daemon is launched
	ip netns exec rt_cli mptcpize run iperf3 -c 10.0.4.2 -t 999 -i 0 &
	ip netns exec rt_cli ifstat -b -i cpe,pho &
	for _ in $(seq 4); do
		sleep 5
		cpe_switch_off
		sleep 5
		cpe_switch_on
	done
	killall iperf3 ifstat
	bash
}

setup()
{
	local suffix
	for suffix in "${HOSTS[@]}"; do
		local ns="${NS}_${suffix}"
		ip netns add "${ns}"
		ip -n "${ns}" link set lo up
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
	ip -n "${NS}_pho" addr add dev "cpe" 10.0.0.2/24
	ip -n "${NS}_pho" route add default via 10.0.0.1 dev "cpe" metric 100
	ip -n "${NS}_pho" mptcp endpoint add 10.0.0.2 dev "cpe" id 1 subflow
	ip -n "${NS}_pho" link set "net" up
	ip -n "${NS}_pho" addr add dev "net" 10.0.3.2/24
	ip -n "${NS}_pho" route add default via 10.0.3.1 dev "net" metric 200
	ip -n "${NS}_pho" mptcp endpoint add 10.0.3.2 dev "net" id 2 subflow backup
	tc -n "${NS}_pho" qdisc add dev "net" root netem rate 20mbit delay 10ms

	ip -n "${NS}_cli" link set "cpe" up
	ip -n "${NS}_cli" addr add dev "cpe" 10.0.0.3/24
	ip -n "${NS}_cli" route add default via 10.0.0.1 dev "cpe" metric 100
	ip -n "${NS}_cli" mptcp endpoint add 10.0.0.3 dev "cpe" id 1 subflow

	ip -n "${NS}_cpe" link add name "br" type bridge
	ip -n "${NS}_cpe" addr add dev "br" 10.0.0.1/24
	ip -n "${NS}_cpe" link set dev "br" up
	ip -n "${NS}_cpe" link set dev "pho" master "br"
	ip -n "${NS}_cpe" link set dev "cli" master "br"
	ip -n "${NS}_cpe" link set dev "pho" up
	ip -n "${NS}_cpe" link set dev "cli" up
	ip -n "${NS}_cpe" link set "net" up
	ip -n "${NS}_cpe" addr add dev "net" 10.0.2.2/24
	ip -n "${NS}_cpe" route add default via 10.0.2.1 dev "net" metric 100
	tc -n "${NS}_cpe" qdisc add dev "net" root netem rate 40mbit delay 5ms

	ip -n "${NS}_net" link set "pho" up
	ip -n "${NS}_net" addr add dev "pho" 10.0.3.1/24
	tc -n "${NS}_net" qdisc add dev "pho" root netem rate 20mbit delay 10ms
	ip -n "${NS}_net" link set "cpe" up
	ip -n "${NS}_net" addr add dev "cpe" 10.0.2.1/24
	tc -n "${NS}_net" qdisc add dev "cpe" root netem rate 40mbit delay 5ms
	ip -n "${NS}_net" link set "srv" up
	ip -n "${NS}_net" addr add dev "srv" 10.0.4.1/24
	ip -n "${NS}_net" route add default via 10.0.4.2 dev "srv" metric 100
	# not to have to deal with NATs
	ip -n "${NS}_net" route add 10.0.0.0/24 via 10.0.2.2 dev "cpe"
	ip -n "${NS}_net" route add 10.0.1.0/24 via 10.0.3.2 dev "pho"

	ip -n "${NS}_srv" link set "net" up
	ip -n "${NS}_srv" addr add dev "net" 10.0.4.2/24
	ip -n "${NS}_srv" route add default via 10.0.4.1 dev "net" metric 100
	ip -n "${NS}_srv" mptcp limits set subflows 8
}

setup

case "${1}" in
	"auto")
		iperf_test
		;;
	*)
		export -f cpe_switch_on cpe_switch_off iperf_test
		echo "Use 'ip netns' to list the netns."
		echo "Then use 'ip netns exec <NETNS> <CMD>' to execute a command in the netns."
		bash
		;;
esac
