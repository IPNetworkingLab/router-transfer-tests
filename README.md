## Router Transfer: test environment

This repository contains a virtual test environment used to peform experiments on the behaviour of QUIC and MPTCP in the context of an access point change.
Experiments can be launched by running ./script.sh auto-{tcp|quic}-v{4|6}
The Environment variable INPUT_SLEEP can be set to induce a delay in the time required for the client to connect to the other access point.

To perform the QUIC test, you need to install our [modified aioquic version](https://github.com/IPNetworkingLab/auto-migration-aioquic) and an implemantation of an HTTP3 server. 
