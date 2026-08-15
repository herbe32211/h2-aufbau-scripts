#!/usr/bin/env bash
# lib/common.sh — gemeinsame Funktionen für run.sh und alle Module.
#
# Wird gesourct, nicht ausgeführt. `set -euo pipefail` setzt das aufrufende
# Script, nicht diese Datei — sonst wäre das Verhalten beim Sourcen
# überraschend.
#
# Konventionen für alle Aufrufer:
#   * Funktionen geben Rückgabewerte über globale Variablen zurück, wo ein
#     Exit-Code != 0 unter `set -e` das Script abbrechen würde (z. B.
#     write_if_changed → WIC_CHANGED).
#   * Prüf-Funktionen (pkg_installed, unit_active, …) sind bewusst als
#     Prädikate gebaut und dürfen nur in Bedingungen verwendet werden.

# Mehrfaches Sourcen ist harmlos.
if [[ -n "${_H2_COMMON_LOADED:-}" ]]; then
	return 0
fi
_H2_COMMON_LOADED=1

# Repo-Wurzel unabhängig vom Arbeitsverzeichnis bestimmen.
_H2_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${_H2_LIB_DIR}/.." && pwd)"
export REPO_ROOT

# Von run.sh gesetzt, sonst 0.
DRY_RUN="${DRY_RUN:-0}"

# ---------------------------------------------------------------------------
# Ausgabe
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
	_C_RESET=$'\033[0m'
	_C_INFO=$'\033[0;36m'
	_C_OK=$'\033[0;32m'
	_C_SKIP=$'\033[0;90m'
	_C_WARN=$'\033[0;33m'
	_C_FAIL=$'\033[0;31m'
	_C_DRY=$'\033[0;35m'
else
	_C_RESET=''
	_C_INFO=''
	_C_OK=''
	_C_SKIP=''
	_C_WARN=''
	_C_FAIL=''
	_C_DRY=''
fi

# Zeitstempel bewusst in UTC — Logzeilen sollen unabhängig von TIMEZONE
# vergleichbar bleiben (Konvention aus dem Betriebsplan).
_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log() { printf '%s %s[ INFO ]%s %s\n' "$(_ts)" "$_C_INFO" "$_C_RESET" "$*"; }
ok() { printf '%s %s[  OK  ]%s %s\n' "$(_ts)" "$_C_OK" "$_C_RESET" "$*"; }
skip() { printf '%s %s[ SKIP ]%s %s\n' "$(_ts)" "$_C_SKIP" "$_C_RESET" "$*"; }
warn() { printf '%s %s[ WARN ]%s %s\n' "$(_ts)" "$_C_WARN" "$_C_RESET" "$*" >&2; }
err() { printf '%s %s[ FAIL ]%s %s\n' "$(_ts)" "$_C_FAIL" "$_C_RESET" "$*" >&2; }
dry() { printf '%s %s[ DRY  ]%s %s\n' "$(_ts)" "$_C_DRY" "$_C_RESET" "$*"; }

die() {
	err "$*"
	exit 1
}

# Mehrzeiliger, eingerückter Hinweisblock für Handlungsempfehlungen an den
# Menschen. Hebt sich optisch von den Statuszeilen ab.
hint() {
	local line
	printf '\n'
	while IFS= read -r line; do
		printf '        %s\n' "$line"
	done <<<"$*"
	printf '\n'
}

module_header() {
	printf '\n%s=== %s %s\n' "$_C_INFO" "$*" "$_C_RESET"
}

# ---------------------------------------------------------------------------
# Vorbedingungen
# ---------------------------------------------------------------------------

is_dry_run() { [[ "$DRY_RUN" == "1" ]]; }

require_root() {
	if [[ "$(id -u)" -eq 0 ]]; then
		return 0
	fi
	if is_dry_run; then
		warn "Nicht root — im Dry-Run ist das in Ordnung, echte Läufe brauchen sudo."
		return 0
	fi
	die "Dieses Modul braucht root-Rechte. Aufruf: sudo $0"
}

# Bricht ab, wenn das System nicht das ist, wofür die Module gebaut wurden.
# Bewusst nur eine Warnung bei abweichender Minor-Version, ein harter Abbruch
# nur bei komplett anderem Betriebssystem.
#
# OS_RELEASE_FILE ist ausschliesslich eine Testnaht: sie erlaubt, die Prüfung
# beim Entwickeln gegen eine nachgebaute os-release laufen zu lassen. Sie hebelt
# die Prüfung nicht aus — es wird weiterhin fail-closed geprüft, nur eben gegen
# die angegebene Datei. Auf der VM nie setzen.
require_debian_13() {
	local id="" version_id=""
	local osr="${OS_RELEASE_FILE:-/etc/os-release}"
	if [[ ! -r "$osr" ]]; then
		die "${osr} nicht lesbar — Zielsystem nicht identifizierbar."
	fi
	if [[ "$osr" != "/etc/os-release" ]]; then
		warn "OS_RELEASE_FILE ist gesetzt (${osr}) — das ist eine Testnaht, kein Produktivpfad."
	fi
	# shellcheck disable=SC1090
	id="$(. "$osr" && printf '%s' "${ID:-}")"
	# shellcheck disable=SC1090
	version_id="$(. "$osr" && printf '%s' "${VERSION_ID:-}")"
	if [[ "$id" != "debian" ]]; then
		die "Erwartet Debian, gefunden: ID=${id:-unbekannt}. Abbruch (fail-closed)."
	fi
	if [[ "${version_id%%.*}" != "13" ]]; then
		warn "Erwartet Debian 13 (trixie), gefunden VERSION_ID=${version_id:-unbekannt}."
		warn "Die Module sind gegen trixie verifiziert. Weiter auf eigenes Risiko."
	fi
}

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------

CONFIG_FILE=""

load_config() {
	local cfg="${HERMES_CONFIG:-${REPO_ROOT}/config.env}"
	if [[ ! -f "$cfg" ]]; then
		die "config.env fehlt: ${cfg}
        Anlegen mit:  cp ${REPO_ROOT}/config.env.example ${cfg}
        Danach ausfüllen und erneut starten."
	fi
	set -a
	# shellcheck source=/dev/null
	source "$cfg"
	set +a
	CONFIG_FILE="$cfg"
	log "Konfiguration geladen: ${CONFIG_FILE}"
}

# require_vars VAR1 VAR2 …  — fail-closed bei fehlenden Pflichtwerten.
require_vars() {
	local missing=()
	local v
	for v in "$@"; do
		if [[ -z "${!v:-}" ]]; then
			missing+=("$v")
		fi
	done
	if ((${#missing[@]} > 0)); then
		die "Pflichtvariablen fehlen oder sind leer in ${CONFIG_FILE:-config.env}: ${missing[*]}"
	fi
}

# Toleranter Wahrheitswert-Test für Config-Schalter.
is_true() {
	case "${1,,}" in
	true | yes | y | 1 | on) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Ausführung
# ---------------------------------------------------------------------------

# run_cmd CMD ARGS…  — führt aus oder meldet im Dry-Run nur, was passieren würde.
run_cmd() {
	if is_dry_run; then
		dry "$*"
		return 0
	fi
	log "\$ $*"
	"$@"
}

# ---------------------------------------------------------------------------
# Dateien
# ---------------------------------------------------------------------------

backup_file() {
	local f="$1"
	local b
	b="${f}.bak-$(date -u '+%Y%m%dT%H%M%SZ')"
	if is_dry_run; then
		dry "würde sichern: ${f} -> ${b}"
		return 0
	fi
	cp -a -- "$f" "$b"
	log "Backup angelegt: ${b}"
}

# write_if_changed ZIEL [MODE] [OWNER:GROUP]  — Inhalt kommt über stdin.
#
# Setzt WIC_CHANGED=1, wenn geschrieben wurde (bzw. im Dry-Run geschrieben
# würde), sonst 0. Gibt immer 0 zurück, damit `set -e` nicht zuschlägt.
#
# Bewusst eine globale Variable statt eines Exit-Codes: unter `set -e` würde
# ein Rückgabewert != 0 für "unverändert" jedes aufrufende Modul abbrechen.
#
# shellcheck disable=SC2034  # wird von den Modulen gelesen, nicht hier
WIC_CHANGED=0
write_if_changed() {
	local target="$1"
	local mode="${2:-0644}"
	local owner="${3:-root:root}"
	local tmp
	tmp="$(mktemp)"
	cat >"$tmp"

	if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
		rm -f -- "$tmp"
		WIC_CHANGED=0
		skip "unverändert: ${target}"
		return 0
	fi

	# shellcheck disable=SC2034  # wird von den Modulen gelesen, nicht hier
	WIC_CHANGED=1
	if is_dry_run; then
		dry "würde schreiben: ${target} (mode ${mode}, owner ${owner})"
		if [[ -f "$target" ]]; then
			diff -u -- "$target" "$tmp" | sed 's/^/          /' || true
		else
			sed 's/^/          + /' <"$tmp"
		fi
		rm -f -- "$tmp"
		return 0
	fi

	if [[ -f "$target" ]]; then
		backup_file "$target"
	fi
	install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" -- "$tmp" "$target"
	rm -f -- "$tmp"
	ok "geschrieben: ${target}"
	return 0
}

# ---------------------------------------------------------------------------
# Pakete
# ---------------------------------------------------------------------------

pkg_installed() {
	dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null | grep -qx 'installed'
}

APT_UPDATED=0
apt_update_once() {
	if ((APT_UPDATED == 1)); then
		return 0
	fi
	run_cmd apt-get update
	APT_UPDATED=1
}

# apt_update_force — nach dem Hinzufügen einer neuen Paketquelle nötig.
apt_update_force() {
	run_cmd apt-get update
	APT_UPDATED=1
}

# ensure_packages PKG…  — installiert nur, was wirklich fehlt.
ensure_packages() {
	local missing=()
	local p
	for p in "$@"; do
		if ! pkg_installed "$p"; then
			missing+=("$p")
		fi
	done
	if ((${#missing[@]} == 0)); then
		skip "bereits installiert: $*"
		return 0
	fi
	log "Fehlende Pakete: ${missing[*]}"
	apt_update_once
	run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

unit_exists() { systemctl cat -- "$1" >/dev/null 2>&1; }
unit_active() { systemctl is-active --quiet -- "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet -- "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Netz-Hilfen
# ---------------------------------------------------------------------------

valid_ipv4() {
	local ip="$1"
	local -a oct
	local o
	[[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	IFS='.' read -r -a oct <<<"$ip"
	for o in "${oct[@]}"; do
		# Führende Nullen abschneiden, sonst interpretiert bash oktal.
		o="${o#"${o%%[!0]*}"}"
		((10#${o:-0} <= 255)) || return 1
	done
	return 0
}

# Ist die Adresse aus einem privaten RFC-1918-Bereich? Wird von 90-verify.sh
# gebraucht, um "Resolver zeigt auf eine LAN-IP" zu erkennen.
is_rfc1918() {
	local ip="$1"
	case "$ip" in
	10.*) return 0 ;;
	192.168.*) return 0 ;;
	172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
	*) return 1 ;;
	esac
}

# Erkennt den Netz-Stack. Gibt "ifupdown", "systemd-networkd",
# "NetworkManager" oder "unbekannt" aus.
#
# Absichtlich konservativ: nur ifupdown wird von 05-network.sh angefasst, alles
# andere führt dort zum Abbruch (fail-closed), statt in eine Konfiguration zu
# schreiben, die niemand liest.
detect_net_stack() {
	if unit_active NetworkManager.service; then
		printf 'NetworkManager'
		return 0
	fi
	if unit_active systemd-networkd.service; then
		printf 'systemd-networkd'
		return 0
	fi
	if unit_active networking.service || [[ -f /etc/network/interfaces ]]; then
		printf 'ifupdown'
		return 0
	fi
	printf 'unbekannt'
}

# Interface, über das die Default-Route läuft. Leer, wenn keine da ist.
default_route_iface() {
	ip -4 route show default 2>/dev/null | awk '/^default/ {for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

# Interface, über das die aktuelle SSH-Sitzung läuft — oder leer, wenn wir
# nicht über SSH arbeiten. Grundlage für den Aussperr-Schutz in 05-network.sh.
ssh_peer_iface() {
	local peer=""
	if [[ -n "${SSH_CONNECTION:-}" ]]; then
		peer="${SSH_CONNECTION%% *}"
	elif [[ -n "${SSH_CLIENT:-}" ]]; then
		peer="${SSH_CLIENT%% *}"
	fi
	if [[ -z "$peer" ]]; then
		return 0
	fi
	ip -4 route get "$peer" 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}
