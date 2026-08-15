#!/usr/bin/env bash
# Zweck: apt-Update/Upgrade, Grundpakete, Zeitzone, NTP, qemu-guest-agent.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars TIMEZONE

# Grundausstattung. Bewusst knapp gehalten — die VM ist eine Minimalinstallation
# und soll das bleiben. Erweiterung über EXTRA_PACKAGES in config.env.
BASE_PACKAGES=(
	ca-certificates
	curl
	git
	gnupg
	xz-utils
	sudo
)

# ---------------------------------------------------------------------------
# 1 · Hostname nur prüfen
# ---------------------------------------------------------------------------

module_header "10-base · Hostname"

CURRENT_HOSTNAME="$(hostname)"
if [[ -n "${AGENT_HOSTNAME:-}" && "$CURRENT_HOSTNAME" != "$AGENT_HOSTNAME" ]]; then
	warn "Hostname ist '${CURRENT_HOSTNAME}', erwartet war '${AGENT_HOSTNAME}'."
	hint "Das Modul ändert den Hostnamen absichtlich nicht — ein Wechsel im
laufenden Betrieb kann sudo (Namensauflösung), Tailscale-Node-Namen und
Zertifikate durcheinanderbringen.

Falls gewollt, von Hand und mit anschliessendem Reboot:
  hostnamectl set-hostname ${AGENT_HOSTNAME}
  \$EDITOR /etc/hosts   # 127.0.1.1-Zeile mitziehen"
else
	ok "Hostname: ${CURRENT_HOSTNAME}"
fi

# ---------------------------------------------------------------------------
# 2 · Paketquellen und Upgrade
# ---------------------------------------------------------------------------

module_header "10-base · Pakete"

apt_update_once

# Bewusst 'upgrade', nicht 'dist-upgrade'/'full-upgrade': letzteres darf Pakete
# entfernen, um Abhängigkeiten aufzulösen. Auf einer Kiste, die per SSH bedient
# wird, ist das ein unnötiges Risiko.
run_cmd env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

ensure_packages "${BASE_PACKAGES[@]}"

if [[ -n "${EXTRA_PACKAGES:-}" ]]; then
	# shellcheck disable=SC2086
	# Wortsplitting ist hier gewollt: EXTRA_PACKAGES ist eine Liste.
	ensure_packages ${EXTRA_PACKAGES}
else
	skip "EXTRA_PACKAGES ist leer."
fi

# ---------------------------------------------------------------------------
# 3 · unattended-upgrades
# ---------------------------------------------------------------------------

module_header "10-base · unattended-upgrades"

if is_true "${INSTALL_UNATTENDED_UPGRADES:-true}"; then
	ensure_packages unattended-upgrades

	# Die Aktivierungsdatei wird aus der vom Paket mitgelieferten Vorlage
	# kopiert, statt ihren Inhalt zu erfinden (VERIFIKATION.md 4.1).
	TEMPLATE="/usr/share/unattended-upgrades/20auto-upgrades"
	TARGET="/etc/apt/apt.conf.d/20auto-upgrades"

	if [[ -f "$TARGET" ]]; then
		skip "${TARGET} existiert bereits — unverändert gelassen."
	elif [[ -f "$TEMPLATE" ]]; then
		run_cmd install -m 0644 -o root -g root -- "$TEMPLATE" "$TARGET"
		ok "Aktivierung aus Paketvorlage übernommen: ${TARGET}"
	elif is_dry_run; then
		dry "würde ${TEMPLATE} nach ${TARGET} kopieren (Vorlage im Dry-Run nicht prüfbar)"
	else
		warn "Vorlage ${TEMPLATE} nicht gefunden — Aktivierung übersprungen."
		hint "Von Hand aktivieren mit:
  dpkg-reconfigure -plow unattended-upgrades"
	fi

	# Automatische Reboots werden bewusst nicht eingeschaltet. Eine Agent-VM
	# soll nicht mitten in einem Lauf neu starten.
	if grep -rqs '^[^/]*Unattended-Upgrade::Automatic-Reboot[[:space:]]*"true"' /etc/apt/apt.conf.d/; then
		warn "Automatic-Reboot ist in /etc/apt/apt.conf.d/ auf true gesetzt."
		hint "Diese Scripts schalten das nicht ein. Wenn die VM nicht ungefragt
neu starten soll, den Wert auf \"false\" setzen."
	else
		ok "Automatische Reboots sind nicht aktiviert."
	fi
else
	skip "INSTALL_UNATTENDED_UPGRADES ist nicht true."
fi

# ---------------------------------------------------------------------------
# 4 · Zeitzone und NTP
# ---------------------------------------------------------------------------

module_header "10-base · Zeit"

if [[ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]]; then
	die "Unbekannte Zeitzone: ${TIMEZONE} (keine Datei /usr/share/zoneinfo/${TIMEZONE})"
fi

CURRENT_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
if [[ "$CURRENT_TZ" == "$TIMEZONE" ]]; then
	skip "Zeitzone steht bereits auf ${TIMEZONE}."
else
	log "Zeitzone: ${CURRENT_TZ:-unbekannt} -> ${TIMEZONE}"
	run_cmd timedatectl set-timezone "$TIMEZONE"
fi

# Die RTC bleibt in UTC. Alles andere handelt sich beim Dual-Boot und bei
# Zeitumstellungen Ärger ein — und diese VM bootet ohnehin nur Linux.
if [[ "$(timedatectl show --property=LocalRTC --value 2>/dev/null || echo no)" == "yes" ]]; then
	warn "Die Hardware-Uhr läuft in Lokalzeit statt UTC."
	hint "Umstellen mit:  timedatectl set-local-rtc 0"
else
	ok "RTC läuft in UTC."
fi

NTP_ENABLED="$(timedatectl show --property=NTP --value 2>/dev/null || echo no)"
NTP_SYNCED="$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo no)"
if [[ "$NTP_ENABLED" == "yes" ]]; then
	ok "NTP ist aktiviert (synchronisiert: ${NTP_SYNCED})."
	if [[ "$NTP_SYNCED" != "yes" ]]; then
		warn "NTP läuft, ist aber noch nicht synchron. Bei frischem Boot normal — sonst Netz prüfen."
	fi
else
	warn "NTP ist nicht aktiviert."
	run_cmd timedatectl set-ntp true
fi

# ---------------------------------------------------------------------------
# 5 · qemu-guest-agent
# ---------------------------------------------------------------------------

module_header "10-base · qemu-guest-agent"

ensure_packages qemu-guest-agent

# WICHTIG: kein `systemctl enable`. Die Unit hat unter Debian keinen
# [Install]-Abschnitt, ist static und wird per udev-Regel aktiviert, sobald das
# virtio-Gerät da ist. `systemctl enable` würde fehlschlagen.
# Siehe VERIFIKATION.md, Abschnitt 5.
if is_dry_run; then
	dry "würde Status von qemu-guest-agent.service prüfen (kein enable — Unit ist static)"
elif unit_active qemu-guest-agent.service; then
	ok "qemu-guest-agent läuft."
else
	warn "qemu-guest-agent ist installiert, die Unit läuft aber nicht."
	hint "Die Unit ist static und wird per udev aktiviert, sobald das virtio-Gerät
vorhanden ist. Läuft sie nicht, fehlt mit hoher Wahrscheinlichkeit die Option
'QEMU Guest Agent' in der VM-Konfiguration auf dem Proxmox-Host.

Auf dem Host prüfen und ggf. setzen (VM 100):
  qm config 100 | grep -i agent
  qm set 100 --agent enabled=1
Danach die VM einmal ausschalten und neu starten — ein Reboot von innen
fügt kein neues virtuelles Gerät hinzu.

Kein 'systemctl enable qemu-guest-agent' versuchen: die Unit hat keinen
[Install]-Abschnitt, das schlägt fehl."
fi

ok "Modul 10-base abgeschlossen."
