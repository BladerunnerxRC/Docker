# `AdGuardHome.yaml` (DoH-only, production-sane)

![AdGuard Home](https://img.shields.io/badge/app-adguard%20home-68BC71?logo=adguard&logoColor=white)
![DNS](https://img.shields.io/badge/upstream-DoH%20only-0F766E)
![Network](https://img.shields.io/badge/network-macvlan-6D28D9)

Put this at `/my/own/confdir/AdGuardHome.yaml` (or wherever your volume maps). It assumes:

| Setting | Value |
| --- | --- |
| Admin UI | port **80** |
| DNS | port **53** (both TCP and UDP) |
| LAN | `192.168.200.0/24` |
| Example IoT VLAN | `10.100.50.0/24` |
| Container static IP | `192.168.200.202` |
