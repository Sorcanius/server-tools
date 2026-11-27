# pihole-dns2mqtt

Überträgt ausgewählte Pi-hole-DNS-Ereignisse als JSON an MQTT.

## Script

```text
/opt/server-tools/services/pihole-dns2mqtt/pihole-dns2mqtt.sh
```

## Credentials

```text
/etc/server-tools/credentials/mqtt.env
```

Die Credential-Datei wird mit `/opt/server-tools/bootstrap/setup-mqtt-env.sh` angelegt.

## MQTT

Basis-Topic wird in der Komponente definiert. Für Pi-hole wird `home/device/pihole` verwendet; aktuell ist insbesondere `RequestsToUnbound` vorgesehen.

Lokale Credentials oder Laufzeitdaten gehören nicht in diesen Ordner.
