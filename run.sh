#!/usr/bin/env bash
#
# run.sh — führt die Module aus modules/ in numerischer Reihenfolge aus.
#
# Die Modulliste wird zur Laufzeit aus dem Verzeichnis gelesen. Ein neues Modul
# hinzufügen heisst: Datei modules/NN-name.sh anlegen, ausführbar machen, fertig.
# Ein Modul entfernen heisst: Datei löschen. Nummernlücken sind Absicht.
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODULE_DIR="${SCRIPT_DIR}/modules"

DRY_RUN="${DRY_RUN:-0}"
LIST_ONLY=0
ONLY=()
SKIP=()

usage() {
	cat <<'EOF'
run.sh — Bootstrap-Module für die H2 Agent-VM

VERWENDUNG
    sudo ./run.sh [OPTIONEN]

OPTIONEN
    --list              Module auflisten und beenden. Läuft ohne root.
    --dry-run           Nichts verändern, nur zeigen, was passieren würde.
                        Läuft ohne root.
    --only NR           Nur dieses Modul ausführen. Mehrfach angebbar.
                        Beispiel: --only 30 --only 40
    --skip NR           Dieses Modul überspringen. Mehrfach angebbar.
    --config PFAD       Andere Konfigurationsdatei als ./config.env verwenden.
    -h, --help          Diese Hilfe.

REIHENFOLGE
    Die Module laufen aufsteigend nach ihrer Nummer. 05-network steht bewusst
    vor 10-base: sobald die Proxmox-Firewall aktiv ist, stirbt apt am
    DNS-Henne-Ei-Problem, wenn der Router noch als Resolver eingetragen ist.
    Netz muss vor Paketen stehen.

EINZELN AUSFÜHREN
    Jedes Modul ist auch direkt lauffähig:
        sudo ./modules/30-docker.sh

VORHER
    cp config.env.example config.env && $EDITOR config.env
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--list)
		LIST_ONLY=1
		shift
		;;
	--dry-run)
		DRY_RUN=1
		shift
		;;
	--only)
		[[ $# -ge 2 ]] || die "--only braucht eine Modulnummer, z. B. --only 30"
		ONLY+=("$2")
		shift 2
		;;
	--only=*)
		ONLY+=("${1#*=}")
		shift
		;;
	--skip)
		[[ $# -ge 2 ]] || die "--skip braucht eine Modulnummer, z. B. --skip 40"
		SKIP+=("$2")
		shift 2
		;;
	--skip=*)
		SKIP+=("${1#*=}")
		shift
		;;
	--config)
		[[ $# -ge 2 ]] || die "--config braucht einen Pfad"
		HERMES_CONFIG="$2"
		shift 2
		;;
	--config=*)
		HERMES_CONFIG="${1#*=}"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		err "Unbekannte Option: $1"
		printf '\n'
		usage
		exit 2
		;;
	esac
done

export DRY_RUN
if [[ -n "${HERMES_CONFIG:-}" ]]; then
	export HERMES_CONFIG
fi

# --- Module einsammeln ------------------------------------------------------

modules=()
while IFS= read -r -d '' f; do
	modules+=("$f")
done < <(find "$MODULE_DIR" -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' -print0 2>/dev/null | sort -z)

if ((${#modules[@]} == 0)); then
	die "Keine Module in ${MODULE_DIR} gefunden."
fi

# Nummer aus dem Dateinamen: 30-docker.sh -> 30
module_number() {
	local base
	base="$(basename -- "$1")"
	printf '%s' "${base%%-*}"
}

# Kurzbeschreibung aus der "# Zweck:"-Zeile des Moduls.
module_purpose() {
	sed -n 's/^# Zweck: *//p' -- "$1" | head -n 1
}

# Zahlvergleich, damit --only 5 und --only 05 beide funktionieren.
in_list() {
	local needle="$1"
	shift
	local item
	for item in "$@"; do
		if ((10#${needle} == 10#${item})); then
			return 0
		fi
	done
	return 1
}

if ((LIST_ONLY == 1)); then
	printf '\nModule in %s:\n\n' "$MODULE_DIR"
	for m in "${modules[@]}"; do
		printf '  %-3s %-22s %s\n' "$(module_number "$m")" "$(basename -- "$m")" "$(module_purpose "$m")"
	done
	printf '\n'
	exit 0
fi

# --- Vorbedingungen ---------------------------------------------------------

if is_dry_run; then
	log "DRY-RUN — es wird nichts verändert."
elif [[ "$(id -u)" -ne 0 ]]; then
	die "run.sh braucht root. Aufruf: sudo ./run.sh   (oder --dry-run / --list ohne root)"
fi

# --- Ausführen --------------------------------------------------------------

ran=()
skipped=()
started="$(_ts)"

for m in "${modules[@]}"; do
	nr="$(module_number "$m")"

	if ((${#ONLY[@]} > 0)) && ! in_list "$nr" "${ONLY[@]}"; then
		skipped+=("${nr} (nicht in --only)")
		continue
	fi
	if ((${#SKIP[@]} > 0)) && in_list "$nr" "${SKIP[@]}"; then
		skipped+=("${nr} (--skip)")
		continue
	fi
	if [[ ! -x "$m" ]]; then
		warn "Modul nicht ausführbar, wird über bash gestartet: $(basename -- "$m")"
	fi

	module_header "MODUL ${nr} — $(basename -- "$m")"
	# Bewusst nicht `if ! bash "$m"`: bei negierter Bedingung wäre $? im
	# else-Zweig 0, und der echte Exit-Code des Moduls ginge verloren.
	if bash "$m"; then
		ran+=("$nr")
	else
		rc=$?
		((rc == 0)) && rc=1
		err "Modul $(basename -- "$m") ist mit Exit-Code ${rc} gescheitert."
		err "Abbruch. Bereits gelaufen: ${ran[*]:-keine}"
		exit "$rc"
	fi
done

# --- Zusammenfassung --------------------------------------------------------

printf '\n'
module_header "ZUSAMMENFASSUNG"
log "Start:       ${started}"
log "Ende:        $(_ts)"
log "Ausgeführt:  ${ran[*]:-keine}"
if ((${#skipped[@]} > 0)); then
	log "Übersprungen: ${skipped[*]}"
fi
if is_dry_run; then
	warn "Das war ein Dry-Run. Für den echten Lauf ohne --dry-run erneut starten."
fi
printf '\n'
