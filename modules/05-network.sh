#!/usr/bin/env bash
# Zweck: Statische IP, externe Resolver, IPv6 aus, DHCP-Reste melden.
#
# Läuft bewusst VOR 10-base: sobald die Proxmox-Firewall aktiv ist (OUT ins LAN
# verboten), stirbt apt am DNS-Henne-Ei-Problem, solange der Router als
# Resolver eingetragen ist.
#
# SICHERHEITSREGEL DIESES MODULS
# Das Modul fasst NIEMALS das Interface an, über das die laufende Sitzung geht.
# Kein ifdown, kein ifup, kein Neustart von networking.service. Änderungen
# werden auf die Platte geschrieben und der Mensch rebootet, wenn er soweit ist.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars NET_INTERFACE NET_ADDRESS NET_PREFIX NET_GATEWAY DNS_SERVERS

IFACE_CONF="/etc/network/interfaces.d/${NET_INTERFACE}"
SYSCTL_IPV6="/etc/sysctl.d/99-h2-disable-ipv6.conf"
NEEDS_REBOOT=0

# ---------------------------------------------------------------------------
# 1 · Werte prüfen, bevor irgendetwas geschrieben wird
# ---------------------------------------------------------------------------

valid_ipv4 "$NET_ADDRESS" || die "NET_ADDRESS ist keine gültige IPv4-Adresse: ${NET_ADDRESS}"
valid_ipv4 "$NET_GATEWAY" || die "NET_GATEWAY ist keine gültige IPv4-Adresse: ${NET_GATEWAY}"

if ! [[ "$NET_PREFIX" =~ ^[0-9]{1,2}$ ]] || ((NET_PREFIX < 1 || NET_PREFIX > 32)); then
	die "NET_PREFIX muss zwischen 1 und 32 liegen, ist aber: ${NET_PREFIX}"
fi

for s in $DNS_SERVERS; do
	valid_ipv4 "$s" || die "DNS_SERVERS enthält keine gültige IPv4-Adresse: ${s}"
done

if ! ip link show "$NET_INTERFACE" >/dev/null 2>&1; then
	die "Interface ${NET_INTERFACE} existiert nicht. Vorhanden: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 2 · Netz-Stack erkennen — fail-closed
# ---------------------------------------------------------------------------

STACK="$(detect_net_stack)"
log "Erkannter Netz-Stack: ${STACK}"

if [[ "$STACK" != "ifupdown" ]]; then
	die "Nur der verifizierte ifupdown-Fall wird automatisch konfiguriert.
        Gefunden wurde: ${STACK}
        Abbruch statt in eine Konfiguration zu schreiben, die niemand liest.
        Netz bitte von Hand einrichten oder dieses Modul anpassen."
fi

# ---------------------------------------------------------------------------
# 3 · Statische IP
# ---------------------------------------------------------------------------

module_header "05-network · statische IP"

# Bewusst eine eigene Datei unter interfaces.d/ statt Herumpatchen in der
# Haupt-interfaces: idempotent vergleichbar und beim Umzug in einem Rutsch
# ersetzbar.
if ! grep -qE '^[[:space:]]*source[[:space:]]+/etc/network/interfaces\.d/\*' /etc/network/interfaces 2>/dev/null; then
	warn "/etc/network/interfaces enthält keine Zeile 'source /etc/network/interfaces.d/*'."
	warn "Ohne sie wird ${IFACE_CONF} beim Booten ignoriert."
	hint "Bitte prüfen und ggf. ergänzen:
  echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
Das Modul fasst die Hauptdatei absichtlich nicht an."
fi

# Existierende Definition desselben Interface in der Hauptdatei ist ein
# Konflikt, den wir nicht still überschreiben.
if grep -qE "^[[:space:]]*iface[[:space:]]+${NET_INTERFACE}[[:space:]]" /etc/network/interfaces 2>/dev/null; then
	warn "${NET_INTERFACE} ist bereits direkt in /etc/network/interfaces definiert."
	hint "Zwei Definitionen desselben Interface (Hauptdatei + interfaces.d) sind
ein Konflikt. Bitte die Definition aus /etc/network/interfaces entfernen,
nachdem ${IFACE_CONF} steht — und zwar bevor rebootet wird."
fi

write_if_changed "$IFACE_CONF" 0644 <<EOF
# Von modules/05-network.sh erzeugt. Alle Werte stammen aus config.env.
# Manuelle Änderungen gehen beim nächsten Lauf verloren.
auto ${NET_INTERFACE}
iface ${NET_INTERFACE} inet static
    address ${NET_ADDRESS}/${NET_PREFIX}
    gateway ${NET_GATEWAY}
EOF

if ((WIC_CHANGED == 1)); then
	NEEDS_REBOOT=1

	CUR_ADDR="$(ip -4 -o addr show dev "$NET_INTERFACE" 2>/dev/null | awk '{print $4}' | head -n1)"
	SESSION_IFACE="$(ssh_peer_iface)"

	warn "Die IP-Konfiguration von ${NET_INTERFACE} hat sich geändert."
	log "  bisher aktiv: ${CUR_ADDR:-keine}"
	log "  neu auf Platte: ${NET_ADDRESS}/${NET_PREFIX} via ${NET_GATEWAY}"

	if [[ -n "$SESSION_IFACE" && "$SESSION_IFACE" == "$NET_INTERFACE" ]]; then
		warn "ACHTUNG: Deine aktuelle SSH-Sitzung läuft über genau dieses Interface."
		hint "Das Modul aktiviert die Änderung NICHT. Es wird kein ifdown/ifup
ausgeführt — das würde dich hier und jetzt aussperren.

Vorgehen:
  1. Zugang über die Proxmox-Konsole (noVNC) bereithalten. Sie funktioniert
     unabhängig vom Gastnetz.
  2. Reboot der VM auslösen.
  3. Danach per SSH auf ${NET_ADDRESS} verbinden.

Erst wenn das klappt, weitermachen."
	else
		hint "Die Änderung ist auf der Platte, aber noch nicht aktiv.
Aktivierung durch Reboot der VM (empfohlen) oder von Hand über die
Proxmox-Konsole. Das Modul rührt das laufende Interface nicht an."
	fi
fi

# ---------------------------------------------------------------------------
# 4 · DNS
# ---------------------------------------------------------------------------

module_header "05-network · DNS"

# resolvconf/openresolv hebeln den .head-Mechanismus aus (siehe
# VERIFIKATION.md, Abschnitt 3.5). Lieber abbrechen als still danebenschreiben.
for p in resolvconf openresolv; do
	if pkg_installed "$p"; then
		die "Paket '${p}' ist installiert.
        Dann verwaltet resolvconf die /etc/resolv.conf und der von diesem
        Modul genutzte Mechanismus /etc/resolv.conf.head greift NICHT
        (siehe VERIFIKATION.md, Abschnitt 3).
        Entweder ${p} entfernen oder die Resolver über resolvconf pflegen.
        Abbruch (fail-closed)."
	fi
done

# systemd-resolved würde ebenfalls eigene Wege gehen.
if unit_active systemd-resolved.service; then
	die "systemd-resolved läuft und verwaltet /etc/resolv.conf.
        Dieses Modul ist für den verifizierten Fall 'direkte resolv.conf ohne
        resolved' gebaut. Abbruch (fail-closed)."
fi

resolv_body() {
	printf '# Von modules/05-network.sh erzeugt. Quelle der Werte: config.env\n'
	if [[ -n "${DNS_SEARCH:-}" ]]; then
		printf 'search %s\n' "$DNS_SEARCH"
	fi
	for s in $DNS_SERVERS; do
		printf 'nameserver %s\n' "$s"
	done
	printf 'options timeout:2 attempts:2\n'
}

# resolv.conf.head wird von dhcpcds Hook 20-resolv.conf jedem Rewrite
# vorangestellt. Damit überleben unsere Resolver das Aufräumen beim Shutdown,
# das on-box beobachtet wurde.
# [UNVERIFIZIERT-ONBOX] Der Beleg dafür ist der Upstream-Hook-Quelltext, nicht
# die Debian-Manpage. TODO on-box gegenprüfen:
#   grep -n 'resolv.conf.head' /usr/lib/dhcpcd/dhcpcd-hooks/20-resolv.conf
resolv_body | write_if_changed /etc/resolv.conf.head 0644

if [[ -r /usr/lib/dhcpcd/dhcpcd-hooks/20-resolv.conf ]]; then
	if grep -q 'resolv\.conf\.head' /usr/lib/dhcpcd/dhcpcd-hooks/20-resolv.conf; then
		ok "dhcpcd-Hook kennt /etc/resolv.conf.head — Mechanismus on-box bestätigt."
	else
		warn "Der installierte dhcpcd-Hook erwähnt /etc/resolv.conf.head NICHT."
		hint "Der Schutz gegen das Leerräumen der resolv.conf greift auf dieser
Installation womöglich nicht. Bitte VERIFIKATION.md Abschnitt 3 lesen und
den dhcpcd auf ${NET_INTERFACE} stilllegen (siehe Abschnitt DHCP unten)."
	fi
else
	log "Kein dhcpcd-Hook unter /usr/lib/dhcpcd/dhcpcd-hooks/ gefunden — Prüfung entfällt."
fi

# /etc/resolv.conf zusätzlich direkt setzen, damit die Auflösung sofort und
# unabhängig von einem dhcpcd-Rewrite funktioniert.
if [[ -L /etc/resolv.conf ]]; then
	warn "/etc/resolv.conf ist ein Symlink auf $(readlink -f /etc/resolv.conf)."
	hint "Das deutet auf eine Fremdverwaltung hin (resolvconf, systemd-resolved,
Container-Runtime). Das Modul schreibt die Datei deshalb nicht.
Bitte von Hand klären."
else
	resolv_body | write_if_changed /etc/resolv.conf 0644
fi

# ---------------------------------------------------------------------------
# 5 · IPv6
# ---------------------------------------------------------------------------

module_header "05-network · IPv6"

if is_true "${DISABLE_IPV6:-true}"; then
	# all/default/lo zusammen: 'all' fasst bestehende Interfaces, 'default'
	# greift für später erzeugte, 'lo' wird von beiden nicht zuverlässig erfasst.
	# [UNVERIFIZIERT-ONBOX] Die Kombination ist verbreitete Praxis, aber in
	# ip-sysctl.txt nicht wörtlich dokumentiert (VERIFIKATION.md 6.2).
	# TODO on-box: `ip -6 addr show scope global` muss danach leer sein.
	write_if_changed "$SYSCTL_IPV6" 0644 <<'EOF'
# Von modules/05-network.sh erzeugt (DISABLE_IPV6=true).
#
# Begründung: Die Firewall-Regel auf dem Proxmox-Host ist IPv4-formuliert
# ("OUT ins LAN verboten"). Aktives IPv6 wäre der offene Umweg um genau diese
# Sperre herum.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF

	if ((WIC_CHANGED == 1)); then
		run_cmd sysctl --system
	fi

	if ! is_dry_run; then
		v6_global="$(ip -6 -o addr show scope global 2>/dev/null | wc -l)"
		if ((v6_global == 0)); then
			ok "Keine globale IPv6-Adresse mehr vorhanden."
		else
			warn "Es existieren noch ${v6_global} globale IPv6-Adresse(n)."
			ip -6 -o addr show scope global | sed 's/^/          /'
			hint "sysctl hat nicht auf allen Interfaces gegriffen. Ein Reboot räumt
das in aller Regel auf. Falls nicht: pro Interface prüfen mit
  sysctl net.ipv6.conf.<iface>.disable_ipv6"
		fi
	fi
else
	skip "DISABLE_IPV6 ist nicht true — IPv6 bleibt unangetastet."
	if [[ -f "$SYSCTL_IPV6" ]]; then
		warn "Es existiert aber noch ${SYSCTL_IPV6} aus einem früheren Lauf."
		hint "Zum Rückgängigmachen von Hand:
  rm ${SYSCTL_IPV6} && sysctl --system
Das Modul löscht die Datei nicht selbsttätig."
	fi
fi

# ---------------------------------------------------------------------------
# 6 · DHCP-Clients — nur melden
# ---------------------------------------------------------------------------

module_header "05-network · DHCP-Reste"

dhcp_found=0
for unit in dhcpcd.service dhcpcd5.service isc-dhcp-client.service; do
	if unit_exists "$unit" && unit_active "$unit"; then
		dhcp_found=1
		warn "Aktiver DHCP-Client: ${unit}"
	fi
done

if pgrep -x dhcpcd >/dev/null 2>&1; then
	dhcp_found=1
	warn "Prozess 'dhcpcd' läuft: $(pgrep -x -a dhcpcd | tr '\n' ' ')"
fi

if ((dhcp_found == 1)); then
	hint "Bei statischer IP hat auf ${NET_INTERFACE} kein DHCP-Client etwas zu
suchen. dhcpcd räumt beim Shutdown seine Einträge aus der resolv.conf —
genau das hat die handgesetzte nameserver-Zeile gekostet.

Das Modul beendet und deinstalliert bewusst NICHTS: ein dhcpcd, der gerade
die Adresse deiner SSH-Sitzung hält, würde dich beim Stoppen aussperren.

Empfohlenes Vorgehen, mit Proxmox-Konsole als Rückfallebene:
  systemctl status dhcpcd            # was hält er, auf welchem Interface?
  systemctl disable --now dhcpcd     # erst wenn klar ist, dass er nichts hält
  # dauerhaft, falls kein Interface je DHCP braucht:
  apt-get purge dhcpcd-base

Danach prüfen: ip -4 addr show ${NET_INTERFACE}"
else
	ok "Kein aktiver DHCP-Client gefunden."
fi

# ---------------------------------------------------------------------------

if ((NEEDS_REBOOT == 1)); then
	module_header "05-network · offene Aktion"
	warn "Es liegt eine Netzänderung auf der Platte, die erst nach einem Reboot wirkt."
	warn "Reboot bleibt dem Menschen überlassen — mit Proxmox-Konsole als Rückfallebene."
fi

ok "Modul 05-network abgeschlossen."
