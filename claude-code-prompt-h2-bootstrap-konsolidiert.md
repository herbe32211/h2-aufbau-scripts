# Prompt für Claude Code — H2 Agent-VM Bootstrap-Scripts (konsolidiert, Stand 14.08.2026)

> Konsolidiert Prompt 1 (Basis) und Prompt 2 (Härtung) vom 11.08. zu **einem** Durchgang
> für einen **leeren Ordner**. Enthält zusätzlich die On-Box-Funde vom 13./14.08.
>
> **Vorher:** leeren Ordner anlegen — Empfehlung `h2-aufbau-scripts` (ohne Leerzeichen,
> spart jedes Quoting-Risiko), `cd` hinein, dann alles unterhalb der Linie pasten.
>
> **Nach dem Lauf:** Repo sofort in ein Remote pushen (privates GitHub-Repo oder Bare-Repo
> auf dem N150). Der Vorgänger dieses Repos ging verloren, weil er nur lokal existierte.

---

Du arbeitest im aktuellen (leeren) Ordner. Ziel: ein modulares Bootstrap-Script-Set
für eine Debian-13-Minimal-VM (Agent-VM auf einem Proxmox-Host). Die VM wird später
einen KI-Agenten (Hermes, Version 0.20.x) mit Docker-Sandbox betreiben — die Scripts
hier bereiten NUR das Fundament vor, sie installieren den Agenten selbst NICHT.

## Arbeitsweise (verbindlich)

1. **Erst Plan, dann Ausführung.** Zeig mir zuerst die geplante Struktur und deine
   offenen Fragen. Warte auf mein OK, bevor du Dateien schreibst.
2. **Rate nicht.** Jede Tatsachenbehauptung (Paketname, Repo-URL, Kommando-Syntax)
   verifizierst du per Websuche gegen offizielle Quellen. Was du nicht verifizieren
   kannst, markierst du als `[UNVERIFIZIERT-ONBOX]` und baust einen TODO-Kommentar
   ins Script — statt einen plausiblen Wert zu erfinden. Wenn du eine offizielle
   Quelle nicht eindeutig identifizieren kannst (z. B. mehrere gleichnamige Repos),
   frag mich.
3. **Keine Secrets.** Kein Script enthält oder erzeugt API-Keys, Tokens oder
   Passwörter. SSH-Public-Key kommt als Variable rein, niemals ein Private Key.

## Ausgangslage der Ziel-VM (bereits verifiziert, nicht neu erraten)

Die VM existiert schon und ist teilweise von Hand vorkonfiguriert. Die Scripts müssen
über diesen Zustand **idempotent** laufen (bestehende Konfiguration erkennen → No-op
melden, nicht doppelt schreiben, nicht überschreiben ohne Not).

- Debian 13.6 (trixie), Kernel 6.12.101, Minimalinstallation (nur SSH-Server +
  Standard-Systemwerkzeuge), Hostname `worker`
- Netz-Stack: **ifupdown** (`/etc/network/interfaces`), Interface **`ens18`**,
  statische IP von Hand gesetzt — die Frage „ifupdown vs. systemd-networkd" ist
  damit beantwortet, Erkennungslogik trotzdem defensiv bauen (fail-closed bei
  unbekanntem Stack: melden und abbrechen, statt ins Leere schreiben)
- **Fund 14.08.:** Debian 13 nutzt **dhcpcd** als DHCP-Client (nicht dhclient).
  Beim Herunterfahren räumt dhcpcd seine Einträge aus `/etc/resolv.conf` —
  eine von Hand gesetzte `nameserver`-Zeile war nach dem Reboot verschwunden.
  Robuster Weg: zusätzlich `/etc/resolv.conf.head` schreiben (wird von dhcpcd bei
  jedem Rewrite vorangestellt). Verifiziere diesen Mechanismus gegen die
  dhcpcd-/Debian-Doku und dokumentiere ihn in VERIFIKATION.md.
- Netz-Phase: Die VM hängt derzeit hinter einem NAT-Gateway (10.42.0.0/24,
  Gateway 10.42.0.1, VM 10.42.0.20) und zieht später ins Zielnetz
  (192.168.178.0/24 hinter einer FritzBox). **Alle Netzwerte gehören deshalb
  ausnahmslos in config.env** — kein hartcodiertes Subnetz in irgendeinem Script.
  Das Netz-Modul muss beim Umzug erneut laufen können und die Umstellung sauber
  vollziehen.
- qemu-guest-agent ist bereits installiert. Zeitzone steht aktuell auf
  `Europe/Berlin`, NTP aktiv.
  **Frag mich**, ob `TIMEZONE` auf UTC gesetzt werden soll oder Europe/Berlin
  bleibt (Konvention aus dem Betriebsplan: Logs in UTC, Anzeige lokal — daraus
  folgt nicht zwingend eine UTC-Systemzeitzone). Nicht selbst entscheiden.

## Zielbild Netz (bestimmt mehrere Entscheidungen)

Die VM bekommt auf dem Proxmox-Host eine Firewall-Regel: OUT ins LAN verboten,
OUT Internet erlaubt. Daraus folgt: Die VM darf für nichts auf den Router
angewiesen sein — kein LAN-DNS, kein DHCP. Und: IPv6 wird in der VM deaktiviert,
weil die LAN-Sperre IPv4-formuliert ist und IPv6 sonst der Umweg wäre.

## Schritt A — Faktenverifikation (vor dem Schreiben der Scripts)

Erzeuge `VERIFIKATION.md` mit einer Tabelle: Behauptung · Quelle (URL) ·
Abrufdatum · Konfidenz (hoch/mittel/on-box-nötig). Verifiziere online:

- Offizieller Docker-Engine-Installationsweg für **Debian 13 (trixie)** über das
  Docker-apt-Repo (nicht das convenience-Script) — exakte Repo-Zeile, GPG-Key-URL,
  Paketnamen.
- Offizieller Tailscale-Installationsweg für Debian 13 + aktuelle Syntax von
  `tailscale serve` (für spätere Dashboard-Freigabe, nur dokumentieren) sowie von
  `tailscale up` inkl. `--advertise-tags` und `--accept-dns`.
- Paketnamen unter Debian 13: qemu-guest-agent, sudo, curl, git, xz-utils,
  unattended-upgrades (falls empfohlen), syncthing.
- Aktueller Digest des Docker-Images `nikolaik/python-nodejs` in der Serie
  `python3.12-nodejs22` (der Vorgängerstand pinnte `@sha256:88c41488…`; prüfe, ob
  dieser Tag noch aktuell ist, und nenne den vollständigen, heute gültigen Digest).
- Korrekte Syntax für systemd-User-Lingering (`loginctl enable-linger`).
- sysctl-Keys für vollständige IPv6-Deaktivierung (all/default/lo) und deren
  Drop-in-Mechanik.
- dhcpcd-Verhalten bzgl. `/etc/resolv.conf` und `/etc/resolv.conf.head` unter Debian 13.
- Hermes: aktuelle Version und offizielle Installer-URL laut offiziellem
  GitHub-README. Erwartet wird `github.com/NousResearch/hermes-agent`. Die URL wird
  NUR in VERIFIKATION.md dokumentiert, **nicht in ein Script gegossen** (Installation
  erfolgt später manuell). Falls du das offizielle Repo nicht zweifelsfrei bestimmen
  kannst: fragen. Achtung, dokumentierte Gefahr: um den Installer existiert ein Ring
  ähnlich benannter Domains mit abweichenden `curl | bash`-Kommandos — akzeptiere als
  Quelle ausschließlich eine Datei im Repo selbst (README oder `website/docs/**`).

Nicht online klärbar (nur als Abschnitt „on-box offen" in VERIFIKATION.md listen,
nichts dazu scripten): Hermes-0.20-Config-Keys, Dashboard-Installationsweg,
RAM-Fußabdruck, Digest-Abgleich nach `docker pull`.

## Schritt B — Script-Struktur

```
h2-aufbau-scripts/
├── README.md          # Zweck, Reihenfolge, Nutzung, "Wie erweitere ich das"
├── VERIFIKATION.md    # aus Schritt A
├── config.env.example # versioniert; reales config.env per .gitignore ausgeschlossen
├── .gitattributes     # LF erzwingen
├── lib/
│   └── common.sh      # Logging (log/warn/die), require_root, load_config mit
│                      # Pflichtvariablen-Prüfung, Idempotenz-Helfer
│                      # (pkg_installed, file_has_line, write_if_changed, …)
├── modules/
│   ├── 05-network.sh  # statische IP, externe Resolver, IPv6 aus, DHCP-Reste prüfen
│   ├── 10-base.sh     # apt update/upgrade, Grundpakete, qemu-guest-agent, Zeitzone
│   ├── 20-user-ssh.sh # Non-Root-User + sudo, authorized_keys, sshd-Härtung
│   ├── 30-docker.sh   # Docker-Repo + Engine, User in docker-Gruppe
│   ├── 40-tailscale.sh# Install + Hinweis-Echo (up-Kommando manuell, interaktiv)
│   ├── 50-lingering.sh# enable-linger für den Agent-User
│   └── 90-verify.sh   # PASS/FAIL-Tabelle, siehe Schritt C
├── docs/
│   ├── tailscale-acl.md
│   ├── pve-firewall-zielbild.md
│   └── 60-syncthing-spezifikation.md
└── run.sh             # modules/ in numerischer Reihenfolge; Flags:
                       # --only 30 · --skip 40 · --list · --dry-run · --help
```

Designregeln:

- **Jedes Modul idempotent und einzeln lauffähig** (zweiter Lauf = No-op mit klarer
  Meldung, kein Fehler). Das gilt ausdrücklich auch gegen die oben beschriebene,
  teilweise von Hand vorkonfigurierte VM.
- Bash, `set -euo pipefail`, shellcheck-sauber, jede Aktion geloggt.
- **Nummernlücken sind Absicht**: spätere Module (60-syncthing, 70-…) werden einfach
  dazugelegt, run.sh nimmt sie automatisch auf. Entfernen = Datei löschen. Genau
  diese Erweiterbarkeit im README dokumentieren.
- Variablennamen `AGENT_USER` / `AGENT_HOSTNAME` statt `USERNAME` / `HOSTNAME`
  (letztere kollidieren mit vordefinierten Shell-Variablen) — im config.env.example
  dokumentieren.
- Pfade konsequent quoten.
- Kein Modul fasst an: Proxmox-Host-Konfiguration (qm, Firewall), Hermes-Installation,
  Provider-Keys, Discord. Das passiert bewusst manuell.

### Modul 05-network (bewusst VOR 10-base)

Begründung, die du im README festhalten sollst: Sobald die Host-Firewall aktiv ist,
stirbt `apt` am DNS-Henne-Ei-Problem, wenn der Router als Resolver konfiguriert
bleibt. Netz muss vor Paketen stehen.

- **DNS:** Pflichtvariable `DNS_SERVERS` in config.env.example (zwei etablierte
  öffentliche Resolver als Default, Wahl kurz begründen und verifizieren). Schreibweg
  gegen den erkannten Netz-Stack; zusätzlich `/etc/resolv.conf.head` gegen die
  dhcpcd-Aufräumaktion (s. Ausgangslage).
- **Statische IP:** aus config.env (Adresse, Präfix, Gateway, Interface). Bestehende
  korrekte Konfiguration erkennen → No-op. Beim Wechsel des Subnetzes (Umzug) sauber
  umstellen. **Warnhinweis ausgeben, wenn die Änderung die laufende SSH-Sitzung
  betrifft**, und den Reboot dem Menschen überlassen — nie selbst `ifdown` auf dem
  Interface, über das die Sitzung läuft.
- **IPv6:** `DISABLE_IPV6=true` (Default true, im config.env.example mit einem Satz
  begründet). Idempotent via sysctl-Drop-in, sofort wirksam + reboot-fest.
- **DHCP:** aktive DHCP-Clients (dhcpcd!) bei statischer IP nur **melden**, nie
  automatisch beenden oder deinstallieren — Schutz der laufenden Remote-Sitzung.
  Handlungsempfehlung ausgeben.
- Fail-closed bei unbekanntem Netz-Stack: nur der verifizierte ifupdown-Fall wird
  automatisch angefasst.

### Modul 20-user-ssh

- Pubkey-Format vor dem Schreiben validieren.
- sshd-Härtung als Drop-in (`PasswordAuthentication no`, `PermitRootLogin no`);
  nach dem Schreiben `sshd -t` mit **Rollback bei Fehler**, bevor Passwort-Login
  effektiv deaktiviert wird — Aussperr-Schutz.
- Der Agent-User existiert auf der Ziel-VM bereits (mit sudo, Passwort-Login aktiv).
  Modul muss das erkennen und nur ergänzen.

### Modul 10-base / qemu-guest-agent

Unter Debian ist die Unit static/udev-aktiviert und hat keinen `[Install]`-Abschnitt
— `systemctl enable` würde fehlschlagen. Korrekt behandeln und warnen, falls die
Proxmox-Option „QEMU Guest Agent" in der VM-Konfiguration fehlt.

### Modul 40-tailscale

- Installation scripten, `tailscale up` **nicht** (interaktiver Auth-Flow).
- Das auszugebende manuelle Kommando enthält zwingend **beide** Flags:
  `--advertise-tags=tag:h2-agent` **und `--accept-dns=false`**.
  Begründung fürs README: Bei aktivem MagicDNS überschreibt `tailscale up` die
  resolv.conf mit 100.100.100.100 und hebelt damit die externen Resolver aus
  05-network still aus.
- `docs/tailscale-acl.md`: fertiges ACL-Policy-Snippet fürs Tailnet-Admin-Panel —
  Tag `tag:h2-agent` definieren; Admin-Geräte (Handy/Laptop als Platzhalter) dürfen
  den H2-Node erreichen, der H2-Node selbst darf **keine** anderen Tailnet-Geräte
  erreichen. Syntax gegen die offizielle Tailscale-ACL-Doku verifizieren. Hinweise
  aufnehmen: ACL muss VOR dem `tailscale up` mit Tag existieren, sonst schlägt das
  Tagging fehl; und ein Tailnet, das bisher ohne ACL lief, kippt beim ersten
  Policy-Eintrag von allow-all auf deny-unlisted — bestehende Geräte also mit
  aufnehmen.

## Schritt C — 90-verify.sh (DoD-Checks, inkl. Negativtests)

PASS/FAIL/SKIP-Tabelle. Prüft:

- qemu-guest-agent aktiv · Zeitzone wie konfiguriert · NTP synchronisiert
- `docker run hello-world` als Agent-User (per `runuser`, übernimmt die
  docker-Gruppe ohne Login-Umweg)
- sshd-Härtung gegen die **effektive** Konfiguration (`sshd -T`), nicht nur die Datei
- Lingering für den Agent-User aktiv
- DNS-Auflösung funktioniert gegen die konfigurierten Resolver, und die effektive
  Resolver-Konfiguration zeigt **keine LAN-IP** und **nicht 100.100.100.100**
- IPv6 deaktiviert (wenn `DISABLE_IPV6=true`): kein globales v6-Interface, sysctl greift
- Default-Route vorhanden, Internet erreichbar (ein Ziel ohne DNS per IP, eines mit DNS)
- INFO: Reboot-Pending — zweigleisig prüfen (`/var/run/reboot-required` ist
  Ubuntu-Mechanik, Konfidenz mittel; zusätzlich laufenden Kernel gegen installierten
  vergleichen). Nur melden, Reboot bleibt manuell.
- INFO: Tailscale-Status zeigt den erwarteten Tag; SKIP mit Meldung, wenn Tailscale
  noch nicht eingerichtet ist
- Echo des gepinnten Docker-Image-Digests aus config.env

## Schritt D — Doku

- `README.md`: Reihenfolge (config.env füllen → run.sh → verify), Erweiterungs-
  anleitung, Checkliste aller manuellen Folgeschritte (tailscale up mit beiden Flags,
  Hermes-Install, Proxmox-Firewall), **SSH-Negativtest von außen**
  (`ssh -o PreferredAuthentications=password …` muss scheitern),
  **Tailnet-Negativtest** (vom H2-Node aus darf ein Connect auf einen anderen
  Tailnet-Peer NICHT gelingen), sowie eine BIOS-Checkliste für die Box:
  VT-x/VT-d aktiv **und „Restore on AC Power Loss" aktiviert** (headless Box muss
  nach Stromausfall selbst wieder hochkommen).
- `docs/pve-firewall-zielbild.md`: Ziel-Regelset der VM-Firewall als dokumentierte
  Referenz (NICHT als Script) — OUT: Internet erlaubt, LAN-Subnetz verboten; IN: nur
  Tailnet-Interface; Hinweis, dass dank externer DNS + statischer IP **keine
  Router-Ausnahme** nötig ist; IPv6-Aspekt; Negativtests (LAN-Nachbargerät
  unerreichbar auf v4, v6 per Deaktivierung geschlossen).
- `docs/60-syncthing-spezifikation.md`: Anforderungs-Stub für das SPÄTERE Modul 60
  — **jetzt kein aktives Modul anlegen**, run.sh würde es sonst automatisch
  mitausführen. Inhalt: Bind nur auf die Tailscale-IP, Global Discovery AUS, Relays
  AUS, NAT-Traversal AUS, nur ein definierter Unterordner wird geteilt, File-
  Versioning (staggered) aktiv. Jede Option gegen die offizielle Syncthing-Doku
  verifizieren (exakte Config-Keys), damit das Modul später nur noch umgesetzt
  werden muss. Zusätzlich offen lassen und als Frage markieren: Pfad der config.xml,
  CLI-Konfigurierbarkeit, Name der User-Unit.

## Schritt E — Abschluss

- `git init`, `.gitignore` (reales `config.env` ausschließen), `.gitattributes` mit
  LF-Zwang (sonst baut Git beim Checkout unter Windows CRLF ein und die Scripts
  sterben auf der VM mit `\r: command not found`).
- `bash -n` über alle Scripts + shellcheck, Ziel: 0 Findings. Ergebnis nennen.
- run.sh-Flags lokal durchtesten (`--list`, `--dry-run`, `--only`, `--skip`, `--help`).
- Aussagekräftiger Commit.
- Zum Schluss: Liste aller `[UNVERIFIZIERT-ONBOX]`-Stellen als Sammelblock, plus eine
  kurze Liste der Stellen, an denen du von diesem Prompt abgewichen bist und warum.
