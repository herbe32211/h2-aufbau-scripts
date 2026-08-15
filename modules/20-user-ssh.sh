#!/usr/bin/env bash
# Zweck: Agent-User + sudo, authorized_keys, sshd-Härtung mit Aussperr-Schutz.
#
# AUSSPERR-SCHUTZ — die drei Stufen
#   1. Gehärtet wird nur, wenn AGENT_SSH_PUBKEY gesetzt ist UND danach eine
#      nicht-leere, von ssh-keygen akzeptierte authorized_keys auf der Platte
#      liegt.
#   2. Nach dem Schreiben des Drop-ins läuft `sshd -t`. Schlägt der Test fehl,
#      wird das Drop-in wieder entfernt und abgebrochen, ohne sshd anzufassen.
#   3. Aktiviert wird per `reload`, nie per `restart` — bestehende Sitzungen
#      überleben einen Reload.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars AGENT_USER

SSHD_DROPIN="/etc/ssh/sshd_config.d/99-h2-hardening.conf"

# ---------------------------------------------------------------------------
# 1 · User
# ---------------------------------------------------------------------------

module_header "20-user-ssh · Benutzer"

if id -u "$AGENT_USER" >/dev/null 2>&1; then
	skip "Benutzer '${AGENT_USER}' existiert bereits (UID $(id -u "$AGENT_USER"))."
else
	log "Benutzer '${AGENT_USER}' wird angelegt (ohne Passwort — Login per Key)."
	run_cmd useradd --create-home --shell /bin/bash "$AGENT_USER"
fi

if is_dry_run && ! id -u "$AGENT_USER" >/dev/null 2>&1; then
	dry "weitere Schritte für '${AGENT_USER}' im Dry-Run nicht prüfbar (User existiert noch nicht)"
	ok "Modul 20-user-ssh abgeschlossen (Dry-Run, verkürzt)."
	exit 0
fi

if id -nG "$AGENT_USER" | tr ' ' '\n' | grep -qx sudo; then
	skip "'${AGENT_USER}' ist bereits in der Gruppe sudo."
else
	run_cmd usermod -aG sudo "$AGENT_USER"
	ok "'${AGENT_USER}' zur Gruppe sudo hinzugefügt."
fi

# ---------------------------------------------------------------------------
# 2 · authorized_keys
# ---------------------------------------------------------------------------

module_header "20-user-ssh · SSH-Key"

USER_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" ]] || die "Home-Verzeichnis von '${AGENT_USER}' nicht ermittelbar."
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

KEY_OK=0

if [[ -z "${AGENT_SSH_PUBKEY:-}" ]]; then
	warn "AGENT_SSH_PUBKEY ist leer — kein Key wird eingetragen."
	hint "Ohne hinterlegten Public Key wird die sshd-Härtung übersprungen.
Das ist Absicht: sie würde dich sonst aussperren.

Key erzeugen (auf dem Admin-Rechner, NICHT auf der VM):
  ssh-keygen -t ed25519 -C 'h2-admin'
Danach den Inhalt von ~/.ssh/id_ed25519.pub in config.env eintragen und
dieses Modul erneut laufen lassen. Der Private Key bleibt beim Admin."
else
	# Format prüfen, bevor irgendetwas geschrieben wird.
	KEY_TMP="$(mktemp)"
	printf '%s\n' "$AGENT_SSH_PUBKEY" >"$KEY_TMP"

	if ! ssh-keygen -l -f "$KEY_TMP" >/dev/null 2>&1; then
		rm -f -- "$KEY_TMP"
		die "AGENT_SSH_PUBKEY ist kein gültiger SSH-Public-Key (ssh-keygen -l lehnt ihn ab).
        Erwartet wird eine Zeile der Form:  ssh-ed25519 AAAAC3Nza… kommentar"
	fi

	# Ein Private Key würde hier durchrutschen können, wenn jemand die falsche
	# Datei kopiert. Das ist ein Konfigurationsfehler mit echtem Schadenspotenzial.
	if grep -q 'PRIVATE KEY' "$KEY_TMP"; then
		rm -f -- "$KEY_TMP"
		die "AGENT_SSH_PUBKEY enthält einen PRIVATE KEY. Abbruch.
        In config.env gehört ausschliesslich der öffentliche Schlüssel (.pub)."
	fi

	log "Key akzeptiert: $(ssh-keygen -l -f "$KEY_TMP" 2>/dev/null)"
	rm -f -- "$KEY_TMP"

	if ! is_dry_run; then
		install -d -m 0700 -o "$AGENT_USER" -g "$AGENT_USER" -- "$SSH_DIR"
	else
		dry "würde ${SSH_DIR} anlegen (0700, ${AGENT_USER})"
	fi

	# Bestehende Keys bleiben erhalten — die VM ist von Hand vorkonfiguriert,
	# ein Überschreiben könnte einen funktionierenden Zugang wegnehmen.
	if [[ -f "$AUTH_KEYS" ]] && grep -qxF "$AGENT_SSH_PUBKEY" "$AUTH_KEYS"; then
		skip "Key steht bereits in ${AUTH_KEYS}."
		KEY_OK=1
	else
		{
			if [[ -f "$AUTH_KEYS" ]]; then
				cat -- "$AUTH_KEYS"
			fi
			printf '%s\n' "$AGENT_SSH_PUBKEY"
		} | write_if_changed "$AUTH_KEYS" 0600 "${AGENT_USER}:${AGENT_USER}"
		KEY_OK=1
	fi

	# Rechte auch dann korrigieren, wenn der Key schon drinstand — sshd
	# verweigert sonst stillschweigend die Key-Auth.
	if ! is_dry_run; then
		chown "${AGENT_USER}:${AGENT_USER}" -- "$SSH_DIR" "$AUTH_KEYS"
		chmod 0700 -- "$SSH_DIR"
		chmod 0600 -- "$AUTH_KEYS"
		ok "Rechte gesetzt: ${SSH_DIR} 0700, ${AUTH_KEYS} 0600, Owner ${AGENT_USER}."
	fi
fi

# ---------------------------------------------------------------------------
# 3 · sshd-Härtung
# ---------------------------------------------------------------------------

module_header "20-user-ssh · sshd-Härtung"

harden_precondition_ok() {
	if ! is_true "${SSH_HARDEN:-true}"; then
		skip "SSH_HARDEN ist nicht true — Härtung übersprungen."
		return 1
	fi
	if ((KEY_OK != 1)); then
		warn "Härtung übersprungen: kein gültiger Public Key hinterlegt."
		return 1
	fi
	if is_dry_run; then
		dry "würde ${SSHD_DROPIN} schreiben, mit sshd -t prüfen und ssh reloaden"
		return 1
	fi
	# Stufe 1: die Datei muss danach wirklich da und nicht leer sein.
	if [[ ! -s "$AUTH_KEYS" ]]; then
		warn "Härtung übersprungen: ${AUTH_KEYS} fehlt oder ist leer."
		return 1
	fi
	if ! ssh-keygen -l -f "$AUTH_KEYS" >/dev/null 2>&1; then
		warn "Härtung übersprungen: ${AUTH_KEYS} enthält keinen von ssh-keygen akzeptierten Key."
		return 1
	fi
	return 0
}

if harden_precondition_ok; then
	# Konfig-Drop-in. Der sshd von Debian liest sshd_config.d/*.conf, sofern
	# die Include-Zeile in sshd_config steht — das prüfen wir.
	if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
		die "In /etc/ssh/sshd_config fehlt die Zeile
            Include /etc/ssh/sshd_config.d/*.conf
        Ohne sie würde das Drop-in wirkungslos bleiben — und wir würden
        fälschlich melden, die Härtung sei aktiv. Abbruch (fail-closed)."
	fi

	HAD_DROPIN=0
	[[ -f "$SSHD_DROPIN" ]] && HAD_DROPIN=1

	write_if_changed "$SSHD_DROPIN" 0644 <<EOF
# Von modules/20-user-ssh.sh erzeugt.
# Wirkt nur, weil /etc/ssh/sshd_config die Zeile
#   Include /etc/ssh/sshd_config.d/*.conf
# enthält. Effektive Konfiguration prüfen mit: sshd -T | grep -Ei 'passwordauth|permitroot'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
EOF

	# Stufe 2: Syntax- und Konsistenzprüfung MIT Rollback.
	if sshd -t 2>/dev/null; then
		ok "sshd -t: Konfiguration ist gültig."
	else
		err "sshd -t hat die neue Konfiguration abgelehnt:"
		sshd -t 2>&1 | sed 's/^/          /' || true
		if ((HAD_DROPIN == 0)); then
			rm -f -- "$SSHD_DROPIN"
			warn "Rollback: ${SSHD_DROPIN} wieder entfernt. sshd wurde nicht angefasst."
		else
			warn "Ein Backup der Vorgängerversion liegt als ${SSHD_DROPIN}.bak-* daneben."
		fi
		die "Abbruch ohne Änderung am laufenden sshd."
	fi

	# Stufe 3: aktivieren, ohne bestehende Sitzungen zu töten.
	# Debian 13 kann sshd über ssh.service ODER über Socket-Aktivierung
	# (ssh.socket) betreiben; welches gilt, hängt vom Installationsweg ab.
	# [UNVERIFIZIERT-ONBOX] Welcher Modus auf dieser VM aktiv ist, steht nicht
	# fest — deshalb wird er erkannt statt angenommen.
	# TODO on-box: systemctl is-active ssh.service ssh.socket
	if unit_active ssh.service; then
		run_cmd systemctl reload ssh.service
		ok "ssh.service reloadet (kein restart — bestehende Sitzungen bleiben)."
	elif unit_active ssh.socket; then
		ok "sshd läuft über Socket-Aktivierung (ssh.socket)."
		log "Kein Reload nötig: jede neue Verbindung startet einen sshd, der die Config frisch liest."
	else
		warn "Weder ssh.service noch ssh.socket ist aktiv — sshd wurde nicht neu geladen."
		hint "Die Konfiguration liegt auf der Platte und greift spätestens nach
einem Neustart des Dienstes. Zustand prüfen mit:
  systemctl status ssh.service ssh.socket"
	fi

	# Gegenprüfung an der EFFEKTIVEN Konfiguration, nicht an der Datei.
	EFF="$(sshd -T 2>/dev/null || true)"
	for setting in "passwordauthentication no" "permitrootlogin no"; do
		if grep -qix -- "$setting" <<<"$EFF"; then
			ok "effektiv: ${setting}"
		else
			warn "effektiv NICHT gesetzt: ${setting}"
			warn "  sshd -T meldet: $(grep -i "^${setting%% *} " <<<"$EFF" || echo '<nichts>')"
		fi
	done

	hint "Negativtest von aussen, von einem anderen Rechner aus ausführen —
solange diese Sitzung noch offen ist:

  ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \\
      ${AGENT_USER}@${NET_ADDRESS:-<ip>}

Das MUSS scheitern ('Permission denied (publickey)'). Klappt es doch,
greift die Härtung nicht — dann nicht ausloggen, sondern nachsehen."
fi

ok "Modul 20-user-ssh abgeschlossen."
