# `AdGuardHome.yaml` (DoH-only, production-sane)

Put this at `/my/own/confdir/AdGuardHome.yaml` (or wherever your volume maps). It assumes:

-   Admin UI on port **80**    
-   DNS on **53** (both TCP and UDP)    
-   LAN `192.168.200.0/24` and example IoT VLAN  10.100.50.0/24`
    
-   Container static IP `192.168.200.202`
