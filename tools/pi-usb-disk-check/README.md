# pi-usb-disk-check

Werkzeug zur intensiven Prüfung von per USB/SATA angeschlossenen HDDs/SSDs auf einem Raspberry Pi bzw. Linux-System.

## Script

```text
/opt/server-tools/tools/pi-usb-disk-check/pi-usb-disk-check.sh
```

Das Tool führt SMART- und Oberflächentests aus und kann je nach Modus destruktiv arbeiten. Vor einem destruktiven Lauf muss sichergestellt sein, dass keine benötigten Daten auf dem Datenträger liegen.

MQTT-Credentials werden nicht im Repository gespeichert.
