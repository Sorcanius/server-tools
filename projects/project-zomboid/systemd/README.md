# systemd

Hier werden die Project-Zomboid-Unit-Dateien versioniert.

Ziel ist, die tatsächlich produktiv verwendeten `zomboid.service`- und `zomboid.socket`-Definitionen kontrolliert zu übernehmen und später reproduzierbar nach `/etc/systemd/system/` auszurollen.

Der Gameserver selbst soll weiterhin mit `User=steam` laufen. server-tools orchestriert systemd, ersetzt systemd aber nicht.
