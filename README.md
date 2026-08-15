# H2 Agent-VM — Bootstrap-Scripts

Modulare, idempotente Bootstrap-Scripts für die Agent-VM (VM 100, `worker`) auf
dem Proxmox-Host `pve-h2`. Die VM betreibt später einen KI-Agenten (Hermes
0.20.x) mit Docker-Sandbox.

**Diese Scripts bereiten nur das Fundament vor. Sie installieren den Agenten
nicht.** Was bewusst manuell bleibt, steht unter
[Manuelle Folgeschritte](#manuelle-folgeschritte).

---

## Schnellstart

```bash
git clone <dieses-repo> && cd hermes-scripts
cp config.env.example config.env
$EDITOR config.env          # mindestens AGENT_SSH_PUBKEY und die Netzwerte

./run.sh --list             # was würde laufen?
./run.sh --dry-run          # was würde es tun? (ohne root)
sudo ./run.sh               # echter Lauf
sudo ./modules/90-verify.sh # Abnahme
```

Danach die [manuellen Folgeschritte](#manuelle-folgeschritte) abarbeiten — ohne
sie ist die VM nicht fertig.

---

## Aufbau

```
.
├── run.sh                  Treiber: führt modules/ in numerischer Reihenfolge aus
├── config.env.example      Vorlage; das reale config.env ist per .gitignore ausgeschlossen
├── lib/common.sh           Logging, Idempotenz-Helfer, Konfigurations-Laden
├── modules/
│   ├── 05-network.sh       statische IP, externe Resolver, IPv6 aus, DHCP-Reste melden
│   ├── 10-base.sh          apt, Grundpakete, Zeitzone, NTP, qemu-guest-agent
│   ├── 20-user-ssh.sh      Agent-User, sudo, authorized_keys, sshd-Härtung
│   ├── 30-docker.sh        Docker-Repo + Engine, User in Gruppe docker
│   ├── 40-tailscale.sh     Tailscale installieren (kein `up`)
│   ├── 50-lingering.sh     systemd-Lingering für den Agent-User
│   └── 90-verify.sh        PASS/FAIL/SKIP-Tabelle über alle Abnahmekriterien
├── docs/
│   ├── tailscale-acl.md            fertiges Tailnet-Policy-Snippet + Negativtest
│   ├── pve-firewall-zielbild.md    Ziel-Regelset der VM-Firewall (Referenz, kein Script)
│   └── 60-syncthing-spezifikation.md  Anforderungen an ein späteres Modul 60
└── VERIFIKATION.md         jede Tatsachenbehauptung mit Quelle, Datum, Konfidenz
```

---

## Warum 05-network vor 10-base steht

Kein Zufall und kein Schönheitsfehler in der Nummerierung.

Sobald die Proxmox-Firewall aktiv ist (siehe `docs/pve-firewall-zielbild.md`),
darf die VM den Router nicht mehr erreichen. Ist der Router dann noch als
DNS-Resolver eingetragen, löst die VM keine Namen mehr auf — und `apt-get
update` hängt, bevor es überhaupt losgeht. Ein Henne-Ei-Problem, das man nur
löst, indem das Netz **vor** den Paketen steht.

Deshalb: erst externe Resolver setzen und die statische IP festschreiben, dann
alles andere.

---

## Bedienung von `run.sh`

| Flag | Wirkung |
|---|---|
| `--list` | Module auflisten. Ohne root. |
| `--dry-run` | Nichts verändern, nur zeigen, was passieren würde. Ohne root. |
| `--only NR` | Nur dieses Modul. Mehrfach angebbar: `--only 30 --only 40` |
| `--skip NR` | Dieses Modul überspringen. Mehrfach angebbar. |
| `--config PFAD` | Andere Konfigurationsdatei als `./config.env`. |
| `-h`, `--help` | Hilfe. |

Jedes Modul läuft auch einzeln:

```bash
sudo ./modules/30-docker.sh
```

Bricht ein Modul ab, stoppt `run.sh` und meldet, welche Module bereits gelaufen
sind. Nach dem Beheben mit `--only` gezielt weitermachen.

---

## Wie ich das erweitere

**Neues Modul hinzufügen:** Datei `modules/NN-name.sh` anlegen, ausführbar
machen, fertig. `run.sh` liest das Verzeichnis zur Laufzeit — es gibt keine
Liste, die gepflegt werden müsste.

Die Nummernlücken (60, 70, 80) sind Absicht: dort ist Platz für spätere Module,
ohne dass etwas umnummeriert werden muss. Der nächste Kandidat ist Modul 60
(Syncthing), Anforderungen stehen in `docs/60-syncthing-spezifikation.md`.

**Modul entfernen:** Datei löschen.

**Gerüst für ein neues Modul:**

```bash
#!/usr/bin/env bash
# Zweck: <eine Zeile — erscheint in ./run.sh --list>
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

load_config
require_debian_13
require_root
require_vars MEINE_PFLICHTVARIABLE

module_header "NN-name"

write_if_changed /etc/beispiel.conf 0644 <<EOF
inhalt
EOF
if ((WIC_CHANGED == 1)); then
    run_cmd systemctl reload beispiel.service
fi

ok "Modul NN-name abgeschlossen."
```

**Hausregeln, die dabei einzuhalten sind:**

* **Idempotent.** Zweiter Lauf = No-op mit klarer Meldung, kein Fehler. Die
  Module laufen ggf. über eine bereits teilkonfigurierte VM.
* **Jede Aktion loggen** — `log` / `ok` / `skip` / `warn` / `err` / `hint`.
* **`run_cmd` statt direktem Aufruf** für alles, was verändert. Nur so
  funktioniert `--dry-run`.
* **Fail-closed.** Bei unbekanntem Zustand abbrechen mit klarer Meldung, nicht
  in eine Konfiguration schreiben, die niemand liest.
* **Laufende Remote-Sessions nie gefährden.** Nichts, was Netz oder sshd
  abschneiden könnte, ohne Vorprüfung und Rollback.
* **Keine Secrets.** Kein Script enthält oder erzeugt Keys, Tokens, Passwörter.
* Pfade quoten. `shellcheck` muss sauber durchlaufen.

**Vor dem Commit:**

```bash
bash -n modules/NN-name.sh
shellcheck -x -s bash run.sh lib/common.sh modules/*.sh   # 0 Findings
./run.sh --dry-run --only NN
```

Und: jede neue Tatsachenbehauptung (Paketname, Repo-URL, Config-Key) mit
Quelle, Abrufdatum und Konfidenz in `VERIFIKATION.md` eintragen. Was sich nicht
belegen lässt, wird als `[UNVERIFIZIERT-ONBOX]` markiert und bekommt einen
TODO-Kommentar im Script — kein plausibel erfundener Wert.

---

## Manuelle Folgeschritte

Nach `run.sh` ist die VM **noch nicht fertig**. Diese Schritte bleiben bewusst
manuell und sind hier der Reihe nach abzuarbeiten.

### 1 · Reboot, falls 05-network etwas geändert hat

Das Modul meldet das ausdrücklich. Es aktiviert Netzänderungen nie selbst — das
würde die laufende SSH-Sitzung abschneiden.

Vorher die **Proxmox-Konsole (noVNC)** bereithalten. Sie funktioniert
unabhängig vom Gastnetz und ist die Rückfallebene, wenn nach dem Reboot nichts
mehr antwortet.

### 2 · Tailnet-Policy setzen — VOR `tailscale up`

Snippet und Erläuterung: `docs/tailscale-acl.md`.

Wichtig: `tailscale up --advertise-tags=…` scheitert, wenn der Tag im
Policy-File nicht unter `tagOwners` steht. Und ein Tailnet, das bisher ohne
eigene Policy lief, kippt beim ersten Eintrag von allow-all auf
deny-unlisted — bestehende Geräte also mit aufnehmen.

### 3 · `tailscale up` — beide Flags sind Pflicht

```bash
sudo tailscale up --advertise-tags=tag:h2-agent --accept-dns=false
```

`--accept-dns=false` ist nicht optional. `tailscale up` akzeptiert die
DNS-Einstellungen der Admin-Konsole per Default; bei aktivem MagicDNS biegt es
dabei `/etc/resolv.conf` auf `100.100.100.100` um und hebelt die externen
Resolver aus Modul 05-network still aus. „Still" ist das Problem: es fällt erst
auf, wenn die Firewall steht und nichts mehr auflöst.

Danach prüfen:

```bash
grep nameserver /etc/resolv.conf   # darf NICHT 100.100.100.100 zeigen
tailscale status --json | grep -i tag
```

### 4 · Proxmox-VM-Firewall aktivieren

Regelwerk und Negativtests: `docs/pve-firewall-zielbild.md`.

Erst nach Schritt 1–3, sonst schneidet man sich den Zugang ab.

### 5 · Hermes installieren

Bewusst nicht gescriptet. Repo und aktuelle Version sind in `VERIFIKATION.md`,
Abschnitt 8 dokumentiert.

**Vorsicht bei der Installer-URL.** Um den Hermes-Installer existiert ein Ring
ähnlich benannter Domains mit abweichenden `curl | bash`-Kommandos. Die
Installationsanweisung ausschliesslich aus einer Datei im offiziellen Repo
selbst nehmen (README oder `website/docs/**`) — nicht aus einem Suchergebnis,
nicht aus einem Blogpost, nicht aus einer Antwort eines Sprachmodells.

### 6 · Provider-Keys und Discord

Manuell. Gehört nicht in dieses Repo — hier stehen keine Secrets.

---

## Abnahme

```bash
sudo ./modules/90-verify.sh
```

Gibt eine PASS/FAIL/SKIP-Tabelle aus und beendet sich mit Exit-Code 1, sobald
ein FAIL dabei ist. INFO-Zeilen sind Hinweise, keine Fehler.

Zwei Tests kann das Script nicht selbst durchführen, weil sie von aussen kommen
müssen. Beide gehören zur Abnahme:

### SSH-Negativtest — von einem anderen Rechner

**Die aktuelle Sitzung offen lassen, solange dieser Test läuft.**

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    hermes@<vm-ip>
```

Das **muss** scheitern (`Permission denied (publickey)`). Klappt es doch,
greift die Härtung aus Modul 20 nicht — dann nicht ausloggen, sondern
nachsehen:

```bash
sudo sshd -T | grep -Ei 'passwordauth|permitrootlogin'
```

### Tailnet-Negativtest — von der Agent-VM aus

```bash
tailscale status                       # Tailscale-IPs der Peers ablesen
tailscale ping <peer-tailscale-ip>     # MUSS scheitern
nc -vz <peer-tailscale-ip> 22          # MUSS scheitern
```

Der H2-Node darf kein anderes Tailnet-Gerät erreichen. Details und
Fehlersuche: `docs/tailscale-acl.md`.

---

## BIOS-Checkliste für die Box

Die Kiste läuft headless. Zwei Einstellungen sind deshalb nicht optional:

| Einstellung | Wert | Warum |
|---|---|---|
| **VT-x / Intel Virtualization Technology** | aktiviert | Ohne sie läuft KVM nicht, und Proxmox fällt auf Emulation zurück (unbrauchbar langsam) oder startet die VM gar nicht. |
| **VT-d / Intel VT for Directed I/O** | aktiviert | Nötig für IOMMU/PCIe-Passthrough. Auch wenn heute nichts durchgereicht wird: die Einstellung nachträglich zu ändern heisst, physisch zur Box zu laufen. |
| **Restore on AC Power Loss** | **Power On** (nicht „Last State") | Nach einem Stromausfall muss die Box von selbst wieder hochkommen. Steht der Wert auf „Power Off" oder „Last State", bleibt sie aus — und niemand merkt es, bis der Agent gebraucht wird. |

Ergänzend prüfen: Secure Boot (kann Probleme mit Kernelmodulen machen),
Wake-on-LAN falls gewünscht, und dass die Box nicht auf einen Bildschirm am
Boot wartet („Halt on: All Errors" auf „No Errors" setzen, falls vorhanden).

---

## Grundsätze dieses Repos

* **Nicht raten.** Jede Tatsachenbehauptung ist in `VERIFIKATION.md` mit Quelle,
  Abrufdatum und Konfidenz belegt. Negativbefunde („die Doku sagt dazu nichts")
  stehen dort genauso drin wie Bestätigungen.
* **Keine Secrets.** Kein Script enthält oder erzeugt API-Keys, Tokens oder
  Passwörter. Der SSH-Public-Key kommt als Variable; ein Private Key gehört
  niemals hierher — Modul 20 bricht ausdrücklich ab, wenn es einen findet.
* **K2 — der Host bleibt agentenfrei.** Diese Scripts fassen die
  Proxmox-Host-Konfiguration nicht an. `docs/pve-firewall-zielbild.md` ist
  Referenz, kein Script.
* **Fail-closed.** Bei unbekanntem Zustand lieber abbrechen als raten.
