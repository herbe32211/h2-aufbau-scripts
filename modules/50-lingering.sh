#!/usr/bin/env bash
# Zweck: systemd-Lingering für den Agent-User aktivieren.
#
# Ohne Lingering baut systemd den User-Manager beim Logout ab und nimmt
# laufende User-Units mit. Der Agent soll aber laufen, ohne dass jemand
# eingeloggt ist.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars AGENT_USER

module_header "50-lingering"

if ! id -u "$AGENT_USER" >/dev/null 2>&1; then
	if is_dry_run; then
		dry "Benutzer '${AGENT_USER}' existiert noch nicht — im echten Lauf legt ihn Modul 20 an"
		exit 0
	fi
	die "Benutzer '${AGENT_USER}' existiert nicht. Erst Modul 20-user-ssh laufen lassen."
fi

# Der Zustand wird primär über die Marker-Datei geprüft. `loginctl show-user
# --property=Linger` ist in der Debian-Manpage nicht als Property dokumentiert
# (VERIFIKATION.md 6.5), die Datei dagegen ist der Mechanismus selbst.
# [UNVERIFIZIERT-ONBOX] TODO on-box gegenprüfen:
#   loginctl show-user "$AGENT_USER" --property=Linger
LINGER_MARKER="/var/lib/systemd/linger/${AGENT_USER}"

if [[ -e "$LINGER_MARKER" ]]; then
	skip "Lingering ist für '${AGENT_USER}' bereits aktiv (${LINGER_MARKER})."
else
	run_cmd loginctl enable-linger "$AGENT_USER"
	if is_dry_run; then
		dry "würde Ergebnis über ${LINGER_MARKER} gegenprüfen"
	elif [[ -e "$LINGER_MARKER" ]]; then
		ok "Lingering für '${AGENT_USER}' aktiviert."
	else
		die "loginctl meldete keinen Fehler, aber ${LINGER_MARKER} fehlt weiterhin.
        Zustand von Hand prüfen:  loginctl show-user ${AGENT_USER}"
	fi
fi

# Zusätzliche Anzeige, falls die Property doch existiert. Fehlschlag ist hier
# kein Fehler.
if ! is_dry_run; then
	LINGER_PROP="$(loginctl show-user "$AGENT_USER" --property=Linger --value 2>/dev/null || true)"
	if [[ -n "$LINGER_PROP" ]]; then
		log "loginctl show-user meldet Linger=${LINGER_PROP}"
	else
		log "loginctl liefert keine Linger-Property — Marker-Datei bleibt massgeblich."
	fi
fi

hint "Was das ermöglicht: '${AGENT_USER}' kann jetzt User-Units betreiben, die
über Logouts hinweg und ab Boot laufen:
  systemctl --user enable --now <unit>
Das ist die Grundlage für den späteren Hermes-Dienst. Diese Scripts legen
selbst keine User-Unit an."

ok "Modul 50-lingering abgeschlossen."
