#!/usr/bin/env bash
# Zweck: Docker-apt-Repo und Engine installieren, Agent-User in Gruppe docker.
#
# Folgt der offiziellen Anleitung unter
# https://docs.docker.com/engine/install/debian/ (Abruf 15.08.2026).
# Bewusst NICHT das convenience-Script (get.docker.com) — das ist laut Docker
# nur für Testumgebungen gedacht und nicht idempotent nachvollziehbar.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars AGENT_USER

KEYRING="/etc/apt/keyrings/docker.asc"
SOURCES="/etc/apt/sources.list.d/docker.sources"
GPG_URL="https://download.docker.com/linux/debian/gpg"

DOCKER_PACKAGES=(
	docker-ce
	docker-ce-cli
	containerd.io
	docker-buildx-plugin
	docker-compose-plugin
)

# ---------------------------------------------------------------------------
# 1 · Konflikte melden
# ---------------------------------------------------------------------------

module_header "30-docker · Vorprüfung"

# Debians eigene docker.io-Pakete kollidieren mit docker-ce.
for p in docker.io docker-doc docker-compose podman-docker containerd runc; do
	if pkg_installed "$p"; then
		warn "Konfliktpaket installiert: ${p}"
		hint "Die Docker-Anleitung verlangt, dass die Distributionspakete vorher
weg sind. Das Modul deinstalliert nichts von selbst — auf einer Kiste, auf
der schon etwas laufen könnte, ist das nichts für ein Script.

Von Hand, nachdem geprüft ist, dass nichts davon gebraucht wird:
  apt-get remove ${p}

Danach dieses Modul erneut starten."
		die "Abbruch wegen Paketkonflikt (fail-closed)."
	fi
done
ok "Keine kollidierenden Distributionspakete gefunden."

ensure_packages ca-certificates curl

# ---------------------------------------------------------------------------
# 2 · GPG-Key
# ---------------------------------------------------------------------------

module_header "30-docker · Repository"

if [[ -s "$KEYRING" ]]; then
	skip "GPG-Key liegt bereits: ${KEYRING}"
else
	run_cmd install -m 0755 -d /etc/apt/keyrings
	# Der Key wird als ASCII abgelegt, nicht dearmored — so steht es in der
	# offiziellen Anleitung, und die Signed-By-Zeile unten verweist darauf.
	if is_dry_run; then
		dry "würde ${GPG_URL} nach ${KEYRING} laden"
	else
		curl -fsSL "$GPG_URL" -o "$KEYRING" ||
			die "Download des Docker-GPG-Keys fehlgeschlagen: ${GPG_URL}
        Netz und DNS prüfen (Modul 05-network)."
		chmod a+r "$KEYRING"
		ok "GPG-Key geladen: ${KEYRING}"
	fi
fi

# ---------------------------------------------------------------------------
# 3 · Repo im deb822-Format
# ---------------------------------------------------------------------------

CODENAME="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
[[ -n "$CODENAME" ]] || die "VERSION_CODENAME nicht aus /etc/os-release ermittelbar."
ARCH="$(dpkg --print-architecture)"
log "Suite: ${CODENAME} · Architektur: ${ARCH}"

# Falls ein früherer Versuch die alte Ein-Zeilen-Form hinterlassen hat, würde
# das Repo doppelt eingebunden. Melden, nicht heimlich löschen.
if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
	warn "Es existiert noch /etc/apt/sources.list.d/docker.list (alte Ein-Zeilen-Form)."
	hint "Zusammen mit docker.sources wäre das Repo doppelt eingebunden.
Nach Prüfung entfernen:  rm /etc/apt/sources.list.d/docker.list"
fi

write_if_changed "$SOURCES" 0644 <<EOF
# Von modules/30-docker.sh erzeugt, nach
# https://docs.docker.com/engine/install/debian/
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: ${KEYRING}
EOF

if ((WIC_CHANGED == 1)); then
	apt_update_force
else
	apt_update_once
fi

# ---------------------------------------------------------------------------
# 4 · Engine
# ---------------------------------------------------------------------------

module_header "30-docker · Engine"

ensure_packages "${DOCKER_PACKAGES[@]}"

if is_dry_run; then
	dry "würde Status von docker.service prüfen"
elif unit_active docker.service; then
	ok "docker.service läuft."
else
	warn "docker.service läuft nicht — wird gestartet und aktiviert."
	run_cmd systemctl enable --now docker.service
fi

# ---------------------------------------------------------------------------
# 5 · Gruppenmitgliedschaft
# ---------------------------------------------------------------------------

module_header "30-docker · Gruppe"

if ! getent group docker >/dev/null 2>&1; then
	if is_dry_run; then
		dry "Gruppe 'docker' existiert noch nicht (wird vom Paket angelegt)"
	else
		die "Gruppe 'docker' existiert nicht, obwohl die Pakete installiert sind."
	fi
elif id -nG "$AGENT_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
	skip "'${AGENT_USER}' ist bereits in der Gruppe docker."
else
	run_cmd usermod -aG docker "$AGENT_USER"
	ok "'${AGENT_USER}' zur Gruppe docker hinzugefügt."
	hint "Die Gruppenmitgliedschaft greift erst in einer NEUEN Sitzung.
In der aktuellen Shell von '${AGENT_USER}' liefert 'docker ps' bis dahin
noch 'permission denied'. Kein Fehler.

Modul 90-verify umgeht das mit 'runuser', das die Gruppen frisch auflöst.

Sicherheitshinweis: Mitgliedschaft in der Gruppe docker ist praktisch
gleichwertig zu root — der Docker-Daemon läuft als root und kann das
Wurzeldateisystem einhängen. Das ist hier Absicht (der Agent braucht die
Sandbox), sollte aber bewusst so bleiben und nicht auf weitere Konten
ausgeweitet werden."
fi

# ---------------------------------------------------------------------------

if [[ -n "${SANDBOX_IMAGE:-}" ]]; then
	log "Sandbox-Image laut config.env: ${SANDBOX_IMAGE}:${SANDBOX_IMAGE_TAG:-<kein Tag>}"
	log "Das Image wird von diesen Scripts bewusst NICHT gezogen — das gehört zum Hermes-Setup."
fi

ok "Modul 30-docker abgeschlossen."
