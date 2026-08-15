#!/usr/bin/env bash
# Zweck: PASS/FAIL/SKIP-Tabelle über alle DoD-Kriterien, inkl. Negativtests.
#
# Dieses Modul verändert nichts. Es liest, prüft und berichtet.
# Exit-Code: 0 wenn kein FAIL, sonst 1.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config

HAVE_ROOT=0
[[ "$(id -u)" -eq 0 ]] && HAVE_ROOT=1

N_PASS=0
N_FAIL=0
N_SKIP=0
N_INFO=0
ROWS=()

_row() {
	local status="$1" name="$2" detail="${3:-}"
	ROWS+=("${status}|${name}|${detail}")
	case "$status" in
	PASS)
		N_PASS=$((N_PASS + 1))
		ok "${name}${detail:+ — ${detail}}"
		;;
	FAIL)
		N_FAIL=$((N_FAIL + 1))
		err "${name}${detail:+ — ${detail}}"
		;;
	SKIP)
		N_SKIP=$((N_SKIP + 1))
		skip "${name}${detail:+ — ${detail}}"
		;;
	INFO)
		N_INFO=$((N_INFO + 1))
		log "${name}${detail:+ — ${detail}}"
		;;
	esac
}

t_pass() { _row PASS "$1" "${2:-}"; }
t_fail() { _row FAIL "$1" "${2:-}"; }
t_skip() { _row SKIP "$1" "${2:-}"; }
t_info() { _row INFO "$1" "${2:-}"; }

# TCP-Erreichbarkeit ohne zusätzliche Pakete (kein nc, kein curl nötig).
tcp_reachable() {
	local host="$1" port="$2" tmo="${3:-5}"
	timeout "$tmo" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

module_header "90-verify · Prüfungen"

if ((HAVE_ROOT == 0)); then
	warn "Läuft ohne root — Prüfungen, die root brauchen (sshd -T, docker via runuser), werden übersprungen."
fi

# ---------------------------------------------------------------------------
# qemu-guest-agent
# ---------------------------------------------------------------------------

if ! pkg_installed qemu-guest-agent; then
	t_fail "qemu-guest-agent installiert" "Paket fehlt"
elif unit_active qemu-guest-agent.service; then
	t_pass "qemu-guest-agent aktiv"
else
	t_fail "qemu-guest-agent aktiv" "Unit läuft nicht — Option 'QEMU Guest Agent' in der Proxmox-VM-Config prüfen"
fi

# ---------------------------------------------------------------------------
# Zeit
# ---------------------------------------------------------------------------

CUR_TZ="$(timedatectl show --property=Timezone --value 2>/dev/null || echo '')"
if [[ "$CUR_TZ" == "${TIMEZONE:-}" ]]; then
	t_pass "Zeitzone wie konfiguriert" "$CUR_TZ"
else
	t_fail "Zeitzone wie konfiguriert" "erwartet '${TIMEZONE:-<unset>}', ist '${CUR_TZ:-unbekannt}'"
fi

if [[ "$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo no)" == "yes" ]]; then
	t_pass "NTP synchronisiert"
else
	t_fail "NTP synchronisiert" "timedatectl meldet NTPSynchronized=no"
fi

# ---------------------------------------------------------------------------
# sshd — gegen die EFFEKTIVE Konfiguration, nicht gegen die Datei
# ---------------------------------------------------------------------------

if ! is_true "${SSH_HARDEN:-true}"; then
	t_skip "sshd-Härtung" "SSH_HARDEN ist nicht true"
elif ((HAVE_ROOT == 0)); then
	t_skip "sshd-Härtung" "braucht root für 'sshd -T'"
else
	SSHD_EFF="$(sshd -T 2>/dev/null || true)"
	if [[ -z "$SSHD_EFF" ]]; then
		t_fail "sshd-Härtung" "'sshd -T' lieferte keine Ausgabe"
	else
		for want in "passwordauthentication no" "permitrootlogin no" "kbdinteractiveauthentication no"; do
			if grep -qix -- "$want" <<<"$SSHD_EFF"; then
				t_pass "sshd effektiv: ${want}"
			else
				GOT="$(grep -i "^${want%% *} " <<<"$SSHD_EFF" || echo '<nicht gesetzt>')"
				t_fail "sshd effektiv: ${want}" "gefunden: ${GOT}"
			fi
		done
	fi
fi

# authorized_keys
if [[ -n "${AGENT_USER:-}" ]] && id -u "$AGENT_USER" >/dev/null 2>&1; then
	AK="$(getent passwd "$AGENT_USER" | cut -d: -f6)/.ssh/authorized_keys"
	if [[ -s "$AK" ]] && ssh-keygen -l -f "$AK" >/dev/null 2>&1; then
		t_pass "authorized_keys vorhanden und gültig" "$(wc -l <"$AK") Zeile(n)"
	else
		t_fail "authorized_keys vorhanden und gültig" "$AK"
	fi
else
	t_fail "Agent-User existiert" "${AGENT_USER:-<unset>}"
fi

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then
	t_fail "Docker installiert" "Kommando 'docker' nicht gefunden"
elif ((HAVE_ROOT == 0)); then
	t_skip "docker run hello-world als ${AGENT_USER:-Agent-User}" "braucht root für 'runuser'"
elif ! unit_active docker.service; then
	t_fail "docker.service aktiv"
else
	t_pass "docker.service aktiv"
	# runuser löst die Gruppen frisch auf und umgeht damit, dass eine frische
	# docker-Gruppenmitgliedschaft erst in einer neuen Login-Session greift.
	if runuser -u "$AGENT_USER" -- docker run --rm hello-world >/dev/null 2>&1; then
		t_pass "docker run hello-world als ${AGENT_USER}"
	else
		t_fail "docker run hello-world als ${AGENT_USER}" "Gruppe 'docker', Daemon oder Netz (Image-Pull) prüfen"
	fi
fi

# ---------------------------------------------------------------------------
# Lingering
# ---------------------------------------------------------------------------

if [[ -n "${AGENT_USER:-}" && -e "/var/lib/systemd/linger/${AGENT_USER}" ]]; then
	t_pass "Lingering aktiv für ${AGENT_USER}"
else
	t_fail "Lingering aktiv für ${AGENT_USER:-<unset>}" "Marker /var/lib/systemd/linger/${AGENT_USER:-} fehlt"
fi

# ---------------------------------------------------------------------------
# DNS — Konfiguration und Funktion
# ---------------------------------------------------------------------------

mapfile -t EFF_NS < <(awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' /etc/resolv.conf 2>/dev/null || true)

if ((${#EFF_NS[@]} == 0)); then
	t_fail "Resolver in /etc/resolv.conf" "keine nameserver-Zeile gefunden"
else
	t_info "Effektive Resolver" "${EFF_NS[*]}"

	# Negativtest 1: keine LAN-IP. Die VM darf nicht vom Router abhängen —
	# die Host-Firewall verbietet später OUT ins LAN.
	lan_ns=()
	for ns in "${EFF_NS[@]}"; do
		if is_rfc1918 "$ns"; then
			lan_ns+=("$ns")
		fi
	done
	if ((${#lan_ns[@]} == 0)); then
		t_pass "Negativtest: kein Resolver im privaten LAN-Bereich"
	else
		t_fail "Negativtest: kein Resolver im privaten LAN-Bereich" "gefunden: ${lan_ns[*]}"
	fi

	# Negativtest 2: nicht MagicDNS. Das wäre das Zeichen dafür, dass
	# 'tailscale up' ohne --accept-dns=false gelaufen ist.
	if printf '%s\n' "${EFF_NS[@]}" | grep -qx '100.100.100.100'; then
		t_fail "Negativtest: kein MagicDNS-Resolver (100.100.100.100)" \
			"'tailscale up' lief ohne --accept-dns=false — externe Resolver sind ausgehebelt"
	else
		t_pass "Negativtest: kein MagicDNS-Resolver (100.100.100.100)"
	fi

	# Stimmen die effektiven Resolver mit config.env überein?
	if [[ -n "${DNS_SERVERS:-}" ]]; then
		missing_ns=()
		for want in $DNS_SERVERS; do
			printf '%s\n' "${EFF_NS[@]}" | grep -qx "$want" || missing_ns+=("$want")
		done
		if ((${#missing_ns[@]} == 0)); then
			t_pass "Konfigurierte Resolver sind aktiv"
		else
			t_fail "Konfigurierte Resolver sind aktiv" "fehlen in resolv.conf: ${missing_ns[*]}"
		fi
	fi
fi

# resolv.conf.head — die Absicherung gegen dhcpcds Aufräumaktion
if [[ -s /etc/resolv.conf.head ]]; then
	t_pass "/etc/resolv.conf.head vorhanden"
else
	t_fail "/etc/resolv.conf.head vorhanden" "Schutz gegen das Leerräumen durch dhcpcd fehlt"
fi

# Erreichbarkeit jedes konfigurierten Resolvers auf Port 53 (ohne dig/nslookup,
# damit kein Zusatzpaket nötig ist).
if [[ -n "${DNS_SERVERS:-}" ]]; then
	for ns in $DNS_SERVERS; do
		if tcp_reachable "$ns" 53 5; then
			t_pass "Resolver erreichbar (TCP/53)" "$ns"
		else
			t_fail "Resolver erreichbar (TCP/53)" "$ns"
		fi
	done
fi

# Tatsächliche Namensauflösung über den Systemresolver.
if getent hosts deb.debian.org >/dev/null 2>&1; then
	t_pass "Namensauflösung funktioniert" "deb.debian.org"
else
	t_fail "Namensauflösung funktioniert" "getent hosts deb.debian.org schlug fehl"
fi

# ---------------------------------------------------------------------------
# IPv6
# ---------------------------------------------------------------------------

if is_true "${DISABLE_IPV6:-true}"; then
	v6_count="$(ip -6 -o addr show scope global 2>/dev/null | wc -l)"
	if ((v6_count == 0)); then
		t_pass "Keine globale IPv6-Adresse"
	else
		t_fail "Keine globale IPv6-Adresse" "${v6_count} gefunden: $(ip -6 -o addr show scope global | awk '{print $4}' | tr '\n' ' ')"
	fi

	all_v6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo '?')"
	def_v6="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo '?')"
	if [[ "$all_v6" == "1" && "$def_v6" == "1" ]]; then
		t_pass "sysctl disable_ipv6 greift" "all=1 default=1"
	else
		t_fail "sysctl disable_ipv6 greift" "all=${all_v6} default=${def_v6}"
	fi
else
	t_skip "IPv6-Prüfungen" "DISABLE_IPV6 ist nicht true"
fi

# ---------------------------------------------------------------------------
# Routing und Internet
# ---------------------------------------------------------------------------

DEF_IFACE="$(default_route_iface)"
if [[ -n "$DEF_IFACE" ]]; then
	t_pass "Default-Route vorhanden" "über ${DEF_IFACE}"
else
	t_fail "Default-Route vorhanden" "ip -4 route show default ist leer"
fi

# Ziel ohne DNS, rein über IP. Bewusst 1.1.1.1 und nicht einer der
# konfigurierten Resolver: so wird Routing/Internet getrennt von der
# DNS-Konfiguration geprüft.
if tcp_reachable 1.1.1.1 443 6; then
	t_pass "Internet per IP erreichbar" "1.1.1.1:443"
else
	t_fail "Internet per IP erreichbar" "1.1.1.1:443 nicht erreichbar — Routing/Gateway prüfen"
fi

# Ziel mit DNS.
if tcp_reachable deb.debian.org 443 8; then
	t_pass "Internet per Namen erreichbar" "deb.debian.org:443"
else
	t_fail "Internet per Namen erreichbar" "deb.debian.org:443 — Auflösung oder Routing prüfen"
fi

# ---------------------------------------------------------------------------
# INFO: Reboot ausstehend — zweigleisig
# ---------------------------------------------------------------------------

# /var/run/reboot-required ist Ubuntu-Mechanik (Paket update-notifier-common)
# und unter Debian meist NICHT vorhanden. Konfidenz mittel — deshalb zusätzlich
# der Kernelvergleich.
if [[ -f /var/run/reboot-required ]]; then
	t_info "Reboot ausstehend (Marker-Datei)" "/var/run/reboot-required existiert"
else
	t_info "Reboot-Marker" "keiner (unter Debian normal — Datei ist Ubuntu-Mechanik)"
fi

RUNNING_KERNEL="$(uname -r)"
NEWEST_KERNEL="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)"
if [[ -z "$NEWEST_KERNEL" ]]; then
	t_info "Kernelvergleich" "kein /boot/vmlinuz-* gefunden"
elif [[ "$RUNNING_KERNEL" == "$NEWEST_KERNEL" ]]; then
	t_info "Kernel aktuell" "läuft ${RUNNING_KERNEL}"
else
	t_info "Reboot empfohlen" "läuft ${RUNNING_KERNEL}, installiert ist ${NEWEST_KERNEL}"
fi

# ---------------------------------------------------------------------------
# INFO: Tailscale
# ---------------------------------------------------------------------------

if ! command -v tailscale >/dev/null 2>&1; then
	t_skip "Tailscale" "nicht installiert"
else
	TS_JSON="$(tailscale status --json 2>/dev/null || true)"
	if [[ -z "$TS_JSON" ]]; then
		t_skip "Tailscale" "tailscaled antwortet nicht — vermutlich noch kein 'tailscale up'"
	elif grep -q '"BackendState": *"Running"' <<<"$TS_JSON"; then
		if [[ -n "${TAILSCALE_TAG:-}" ]] && grep -q "\"${TAILSCALE_TAG}\"" <<<"$TS_JSON"; then
			t_info "Tailscale läuft mit erwartetem Tag" "$TAILSCALE_TAG"
		else
			t_info "Tailscale läuft OHNE erwarteten Tag" "erwartet ${TAILSCALE_TAG:-<unset>} — 'tailscale up --advertise-tags=…' erneut ausführen"
		fi
	else
		BS="$(grep -o '"BackendState": *"[^"]*"' <<<"$TS_JSON" | head -n1 || true)"
		t_skip "Tailscale" "noch nicht verbunden (${BS:-Zustand unbekannt})"
	fi
fi

# ---------------------------------------------------------------------------
# INFO: Sandbox-Image-Pin
# ---------------------------------------------------------------------------

if [[ -n "${SANDBOX_IMAGE:-}" && -n "${SANDBOX_IMAGE_DIGEST:-}" ]]; then
	t_info "Gepinntes Sandbox-Image" "${SANDBOX_IMAGE}:${SANDBOX_IMAGE_TAG:-}@${SANDBOX_IMAGE_DIGEST}"
	# [UNVERIFIZIERT-ONBOX] Der Abgleich gegen das real gezogene Image ist erst
	# nach einem 'docker pull' möglich und gehört nicht in dieses Fundament.
	# TODO on-box, nach dem Pull:
	#   docker image inspect --format '{{index .RepoDigests 0}}' "$SANDBOX_IMAGE:$SANDBOX_IMAGE_TAG"
	t_info "Digest-Abgleich" "nicht durchgeführt — erst nach 'docker pull' möglich (siehe VERIFIKATION.md O-8)"
else
	t_skip "Sandbox-Image-Pin" "SANDBOX_IMAGE/SANDBOX_IMAGE_DIGEST nicht gesetzt"
fi

# ---------------------------------------------------------------------------
# Tabelle
# ---------------------------------------------------------------------------

printf '\n'
module_header "90-verify · Ergebnis"
printf '\n'
# printf '%-52s' zählt Bytes, nicht Zeichen — bei Umlauten verrutscht die
# Spalte. ${#s} zählt in einer UTF-8-Locale Zeichen, deshalb wird hier von Hand
# aufgefüllt.
_pad() {
	local s="$1" w="$2" n
	n=$((w - ${#s}))
	if ((n < 0)); then n=0; fi
	printf '%s%*s' "$s" "$n" ''
}

printf '  %s %s %s\n' "$(_pad STATUS 6)" "$(_pad PRÜFUNG 52)" "DETAIL"
printf '  %s %s %s\n' "$(_pad ------ 6)" "$(_pad '' 52 | tr ' ' '-')" "------"
for row in "${ROWS[@]}"; do
	IFS='|' read -r st nm dt <<<"$row"
	printf '  %s %s %s\n' "$(_pad "$st" 6)" "$(_pad "$nm" 52)" "$dt"
done
printf '\n'
printf '  PASS %d · FAIL %d · SKIP %d · INFO %d\n\n' "$N_PASS" "$N_FAIL" "$N_SKIP" "$N_INFO"

if ((N_FAIL > 0)); then
	err "${N_FAIL} Prüfung(en) fehlgeschlagen."
	exit 1
fi

ok "Alle Prüfungen bestanden (INFO-Zeilen sind Hinweise, keine Fehler)."
hint "Zwei Negativtests kann dieses Script nicht selbst durchführen, weil sie
von aussen kommen müssen. Beide stehen im README:
  * SSH-Negativtest von einem anderen Rechner
  * Tailnet-Negativtest von dieser VM auf einen anderen Tailnet-Peer"
