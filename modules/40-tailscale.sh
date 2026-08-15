#!/usr/bin/env bash
# Zweck: Tailscale-Repo und Paket installieren. Kein tailscale up.
#
# `tailscale up` wird bewusst NICHT gescriptet: der Auth-Flow ist interaktiv
# (Browser-Login oder Auth-Key) und ein Auth-Key wäre ein Secret — und Secrets
# haben in diesem Repo nichts verloren. Das Modul gibt am Ende das exakte
# Kommando aus, das der Mensch ausführt.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars TAILSCALE_TAG

KEYRING="/usr/share/keyrings/tailscale-archive-keyring.gpg"
SOURCES="/etc/apt/sources.list.d/tailscale.list"

CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
[[ -n "$CODENAME" ]] || die "VERSION_CODENAME nicht aus /etc/os-release ermittelbar."

KEY_URL="https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg"
LIST_URL="https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list"

# ---------------------------------------------------------------------------
# 1 · Repo
# ---------------------------------------------------------------------------

module_header "40-tailscale · Repository"

if [[ -s "$KEYRING" ]]; then
	skip "Keyring liegt bereits: ${KEYRING}"
elif is_dry_run; then
	dry "würde ${KEY_URL} nach ${KEYRING} laden"
else
	install -m 0755 -d /usr/share/keyrings
	curl -fsSL "$KEY_URL" -o "$KEYRING" ||
		die "Download des Tailscale-Keys fehlgeschlagen: ${KEY_URL}
        Gibt es für '${CODENAME}' ein Tailscale-Repo? Prüfen unter
        https://pkgs.tailscale.com/stable/debian/"
	chmod 0644 "$KEYRING"
	ok "Keyring geladen: ${KEYRING}"
fi

# Die sources-Zeile wird von Tailscale als fertige Datei ausgeliefert. Sie wird
# heruntergeladen und mit dem Bestand verglichen, statt sie hier
# nachzuformulieren — so bleibt der Inhalt das, was Tailscale ausliefert.
# Verifizierter Inhalt für trixie (15.08.2026), siehe VERIFIKATION.md 2.1:
#   deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] \
#       https://pkgs.tailscale.com/stable/debian trixie main
if is_dry_run; then
	dry "würde ${LIST_URL} laden und nach ${SOURCES} schreiben"
else
	TS_TMP="$(mktemp)"
	if ! curl -fsSL "$LIST_URL" -o "$TS_TMP"; then
		rm -f -- "$TS_TMP"
		die "Download der Tailscale-Repo-Liste fehlgeschlagen: ${LIST_URL}"
	fi
	if ! grep -q '^deb ' "$TS_TMP"; then
		rm -f -- "$TS_TMP"
		die "Heruntergeladene Datei sieht nicht wie eine apt-sources-Liste aus. Abbruch."
	fi
	write_if_changed "$SOURCES" 0644 <"$TS_TMP"
	rm -f -- "$TS_TMP"

	if ((WIC_CHANGED == 1)); then
		apt_update_force
	else
		apt_update_once
	fi
fi

# ---------------------------------------------------------------------------
# 2 · Paket
# ---------------------------------------------------------------------------

module_header "40-tailscale · Installation"

ensure_packages tailscale

if is_dry_run; then
	dry "würde tailscaled-Status prüfen"
elif unit_active tailscaled.service; then
	ok "tailscaled läuft."
else
	run_cmd systemctl enable --now tailscaled.service
fi

# ---------------------------------------------------------------------------
# 3 · Manuelles Kommando ausgeben
# ---------------------------------------------------------------------------

module_header "40-tailscale · nächster Schritt (manuell)"

TS_STATE="nicht eingerichtet"
if command -v tailscale >/dev/null 2>&1 && ! is_dry_run; then
	TS_STATE="$(tailscale status --json 2>/dev/null | grep -o '"BackendState"[^,]*' | head -n1 || true)"
	TS_STATE="${TS_STATE:-unbekannt}"
fi
log "Aktueller Backend-Zustand: ${TS_STATE}"

hint "Vor dem Verbinden: das Policy-File im Tailnet-Admin-Panel muss den Tag
bereits kennen. Ohne Eintrag unter tagOwners scheitert das Tagging.
Fertiges Snippet: docs/tailscale-acl.md

Dann diesen Befehl auf der VM ausführen — beide Flags sind Pflicht:

  sudo tailscale up --advertise-tags=${TAILSCALE_TAG} --accept-dns=false

Warum --accept-dns=false zwingend ist:
  'tailscale up' akzeptiert die DNS-Einstellungen der Admin-Konsole per
  Default. Bei aktivem MagicDNS biegt es dabei die /etc/resolv.conf auf
  100.100.100.100 um — und hebelt damit die externen Resolver aus Modul
  05-network still aus. Genau die sind aber die Voraussetzung dafür, dass
  die VM ohne Router-Zugriff auflösen kann.

Warum --advertise-tags:
  Ohne Tag hängt der Node an einem Benutzerkonto und fällt nicht unter die
  Regeln aus docs/tailscale-acl.md. Ausserdem laufen getaggte Nodes nicht
  über die Key-Expiry ab.

Danach prüfen:
  tailscale status
  grep nameserver /etc/resolv.conf     # darf NICHT 100.100.100.100 zeigen

Und den Tailnet-Negativtest aus dem README nicht vergessen."

ok "Modul 40-tailscale abgeschlossen (Installation, ohne 'up')."
