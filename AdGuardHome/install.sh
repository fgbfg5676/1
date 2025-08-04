#!/bin/sh
opkg update
if [ 0 -ne 0 ]; then
    echo "update failed。"
    exit 1
fi
# install AdGuardHome Core IPK
opkg install depends/*.ipk
# install luci-app-adguardhome IPK
opkg install *.ipk
# update latest AdGuardHome Core
cp AdGuardHome/AdGuardHome /usr/bin/AdGuardHome
chmod +x /usr/bin/AdGuardHome
