#!/bin/bash -ex
# SPDX-License-Identifier: GPL-2.0
# Copyright (c) 2025, Matthieu Baerts.

NS=rt
HOSTS=(pho cli swi cpe cell net srv)

cleanup()
{
	local suffix
	for suffix in "${HOSTS[@]}"; do
		local ns="${NS}_${suffix}"
		ip netns del "${ns}" >/dev/null 2>&1
	done
}

trap cleanup EXIT

setup()
{
	local suffix
	for suffix in "${HOSTS[@]}"; do
		local ns="${NS}_${suffix}"
		ip netns add "${ns}"
		ip -n "${ns}" link set lo up
	done

	#        .2.2
	#     pho ---------------------- .2.1
	#        \ .0.2   .0.1           \
	# .0.254  swi ------- cpe ------- net ------- srv
	#        / .0.3        .1.2   .1.1  .3.1   .3.2
	#     cli

	ip link add "pho" netns "${NS}_swi" type veth peer name "swi" netns "${NS}_pho"
	ip link add "cli" netns "${NS}_swi" type veth peer name "swi" netns "${NS}_cli"
	ip link add "cpe" netns "${NS}_swi" type veth peer name "swi" netns "${NS}_cpe"

	ip link add "pho" netns "${NS}_net" type veth peer name "net" netns "${NS}_pho"
	ip link add "cpe" netns "${NS}_net" type veth peer name "net" netns "${NS}_cpe"
	ip link add "srv" netns "${NS}_net" type veth peer name "net" netns "${NS}_srv"

	ip -n "${NS}_swi" link add name "br" type bridge
	ip -n "${NS}_swi" addr add dev "br" 10.0.0.254/24
	ip -n "${NS}_swi" link set dev "br" up
	ip -n "${NS}_swi" link set dev "pho" master "br"
	ip -n "${NS}_swi" link set dev "cli" master "br"
	ip -n "${NS}_swi" link set dev "cpe" master "br"
	ip -n "${NS}_swi" link set dev "pho" up
	ip -n "${NS}_swi" link set dev "cli" up
	ip -n "${NS}_swi" link set dev "cpe" up

	ip -n "${NS}_pho" link set "swi" up
	ip -n "${NS}_pho" addr add dev "swi" 10.0.0.2/24
	ip -n "${NS}_pho" route add default via 10.0.0.1 dev "swi" metric 100
	ip -n "${NS}_pho" link set "net" up
	ip -n "${NS}_pho" addr add dev "net" 10.0.2.2/24
	ip -n "${NS}_pho" route add default via 10.0.2.1 dev "net" metric 200

	ip -n "${NS}_cli" link set "swi" up
	ip -n "${NS}_cli" addr add dev "swi" 10.0.0.3/24
	ip -n "${NS}_cli" route add default via 10.0.0.1 dev "swi" metric 100

	ip -n "${NS}_cpe" link set "swi" up
	ip -n "${NS}_cpe" addr add dev "swi" 10.0.0.1/24
	ip -n "${NS}_cpe" link set "net" up
	ip -n "${NS}_cpe" addr add dev "net" 10.0.1.2/24
	ip -n "${NS}_cpe" route add default via 10.0.1.1 dev "net" metric 100

	ip -n "${NS}_net" link set "pho" up
	ip -n "${NS}_net" addr add dev "pho" 10.0.2.1/24
	ip -n "${NS}_net" link set "cpe" up
	ip -n "${NS}_net" addr add dev "cpe" 10.0.1.1/24
	ip -n "${NS}_net" link set "srv" up
	ip -n "${NS}_net" addr add dev "srv" 10.0.3.1/24
	ip -n "${NS}_net" route add default via 10.0.3.2 dev "srv" metric 100
	ip -n "${NS}_net" route add 10.0.0.0/24 via 10.0.1.2 dev "cpe"

	ip -n "${NS}_srv" link set "net" up
	ip -n "${NS}_srv" addr add dev "net" 10.0.3.2/24
	ip -n "${NS}_srv" route add default via 10.0.3.1 dev "net" metric 100
}

setup
bash
