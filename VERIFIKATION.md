# VERIFIKATION.md

Jede Tatsachenbehauptung, die in diesem Repo in ein Script oder eine Anleitung
eingeflossen ist, mit Quelle, Abrufdatum und Konfidenz.

**Konfidenzstufen**

| Stufe | Bedeutung |
|---|---|
| `hoch` | Offizielle Primärquelle, Aussage dort wörtlich enthalten. |
| `mittel` | Beleg vorhanden, aber indirekt (Quelltext statt Doku, oder Doku deckt nur einen Teil ab). Vor Verlass darauf on-box gegenprüfen. |
| `on-box-nötig` | Online nicht klärbar. Muss auf der Ziel-VM geprüft werden. |

Alle Abrufe: **15.08.2026**, sofern nicht anders vermerkt.

---

## 1 · Docker Engine auf Debian 13 (trixie)

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 1.1 | Debian 13 (trixie) wird von Docker Engine offiziell als „stable" unterstützt | <https://docs.docker.com/engine/install/debian/> | 15.08.2026 | hoch |
| 1.2 | GPG-Key-URL ist `https://download.docker.com/linux/debian/gpg`, wird **als ASCII** nach `/etc/apt/keyrings/docker.asc` gelegt (kein `gpg --dearmor` mehr) | ebd. | 15.08.2026 | hoch |
| 1.3 | Das Repo wird heute im **deb822-Format** als `/etc/apt/sources.list.d/docker.sources` eingetragen, mit den Feldern `Types/URIs/Suites/Components/Architectures/Signed-By` | ebd. + <https://raw.githubusercontent.com/docker/docs/main/content/manuals/engine/install/debian.md> | 15.08.2026 | hoch |
| 1.4 | Paketnamen: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` | ebd. | 15.08.2026 | hoch |

Umgesetzt in `modules/30-docker.sh`.

> **Abweichung vom Auftragsprompt:** Der Prompt sprach von „der exakten
> Repo-Zeile". Eine einzelne `deb …`-Zeile ist nicht mehr der von Docker
> dokumentierte Weg — die offizielle Anleitung nutzt inzwischen deb822.
> Das Script folgt der offiziellen Anleitung, nicht der Prompt-Formulierung.

---

## 2 · Tailscale auf Debian 13

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 2.1 | Für trixie existiert ein Repo. Inhalt der Datei wörtlich: `deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main` | <https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list> (Datei live abgerufen) | 15.08.2026 | hoch |
| 2.2 | Passender Key: `https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg` → `/usr/share/keyrings/tailscale-archive-keyring.gpg` | <https://tailscale.com/docs/install/linux> | 15.08.2026 | hoch |
| 2.3 | Paketname ist `tailscale` | ebd. | 15.08.2026 | hoch |
| 2.4 | `tailscale up --advertise-tags=…` — „Give tagged permissions to this device. You must be listed in 'TagOwners' to be able to apply tags." | <https://tailscale.com/kb/1241/tailscale-up> | 15.08.2026 | hoch |
| 2.5 | `tailscale up --accept-dns=…` — „Accept DNS configuration from the admin console. **Defaults to accepting DNS settings.**" Daraus folgt: ohne `--accept-dns=false` biegt MagicDNS die `resolv.conf` auf 100.100.100.100 um | ebd. | 15.08.2026 | hoch |
| 2.6 | `tailscale serve` — Grundform `tailscale serve [flags] <target>`, Flags u. a. `--https=<port>`, `--http=<port>`, `--tcp=<port>`, `--bg`, `--set-path=<path>`; Beispiele `tailscale serve localhost:3000`, `tailscale serve status --json`, `tailscale serve reset` | <https://tailscale.com/kb/1242/tailscale-serve> | 15.08.2026 | hoch |
| 2.7 | Policy-File kennt `tagOwners` (`"tag:name": ["group:x"]`), klassische `acls` (`action`/`src`/`dst`) und die neueren `grants` (`src`/`dst`/`ip`). Beides wird weiter unterstützt; Tailscale empfiehlt `grants` für neue Policies | <https://tailscale.com/kb/1337/acl-syntax> | 15.08.2026 | hoch |
| 2.8 | Ein neues Tailnet startet mit einer **default allow-all**-Policy; sobald eine eigene Policy gesetzt wird, gilt deny-by-default für alles nicht Aufgeführte | <https://tailscale.com/kb/1018/acls> | 15.08.2026 | mittel |

Zu 2.8: Die Doku bestätigt „default allow all policy" und „deny-by-default"
getrennt; die Formulierung des Auftragsprompts („kippt beim ersten
Policy-Eintrag") ist inhaltlich richtig, steht aber nicht als ein Satz in der
Quelle. Deshalb `mittel`. Praktische Konsequenz ist unstrittig und in
`docs/tailscale-acl.md` als Warnung aufgenommen.

Umgesetzt in `modules/40-tailscale.sh` und `docs/tailscale-acl.md`.

---

## 3 · dhcpcd und `/etc/resolv.conf`

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 3.1 | Debian trixie liefert dhcpcd `1:10.1.0-11+deb13u3` | <https://manpages.debian.org/trixie/dhcpcd-base/dhcpcd.8.en.html> | 15.08.2026 | hoch |
| 3.2 | „dhcpcd then runs the configuration script which writes DNS information to resolvconf(8), if available, otherwise directly to /etc/resolv.conf." | ebd. | 15.08.2026 | hoch |
| 3.3 | **`dhcpcd(8)` erwähnt `/etc/resolv.conf.head` NICHT.** | ebd. | 15.08.2026 | hoch (Negativbefund) |
| 3.4 | Der Hook `20-resolv.conf` stellt in `build_resolv_conf()` den Inhalt von `/etc/resolv.conf.head` der generierten Datei voran (und `/etc/resolv.conf.tail` hinten an) | <https://raw.githubusercontent.com/NetworkConfiguration/dhcpcd/master/hooks/20-resolv.conf> | 15.08.2026 | mittel |
| 3.5 | Dieser Pfad greift **nur, wenn kein `resolvconf`/`openresolv` installiert ist** — sonst delegiert der Hook an resolvconf und `.head` bleibt wirkungslos | ebd. + 3.2 | 15.08.2026 | mittel |

### Warum nur `mittel` — und was daraus folgt

Der Auftragsprompt verlangte, den `.head`-Mechanismus „gegen die
dhcpcd-/Debian-Doku" zu verifizieren. **Das ist so nicht möglich:** die
Debian-Manpage kennt den Mechanismus nicht. Beleg ist ausschließlich der
Hook-Quelltext, und zwar der des **Upstream-`master`-Branch**, nicht exakt der
von Debian 13 ausgelieferte 10.1.0-Stand. Die on-box beobachtete Wirkung
(handgesetzte `nameserver`-Zeile nach Reboot verschwunden) passt zum
dokumentierten Verhalten, beweist aber `.head` nicht.

Konsequenz im Code (`modules/05-network.sh`):

- `/etc/resolv.conf.head` wird geschrieben — als Absicherung, nicht als
  alleiniger Mechanismus.
- Vorher wird geprüft, ob `resolvconf` oder `openresolv` installiert ist.
  Falls ja: **Abbruch mit Meldung**, weil der `.head`-Pfad dort nachweislich
  nicht greift (3.5). Kein stilles Weiterschreiben.
- Aktive DHCP-Clients werden gemeldet, nicht angefasst. Der eigentlich saubere
  Zustand ist: bei statischer IP läuft auf `ens18` gar kein dhcpcd.

`[UNVERIFIZIERT-ONBOX]` → siehe Abschnitt 9, Punkt O-1.

---

## 4 · Debian-13-Paketnamen

Geprüft durch Abruf von `https://packages.debian.org/trixie/<paket>` und
Auswertung des Seitentitels. Kontrolle des Verfahrens: ein erfundener
Paketname liefert „Debian -- Error", ein echter „Details of package … in trixie".
Der HTTP-Statuscode ist dafür **untauglich** (auch Fehlerseiten liefern 200).

| Paket | Ergebnis | Konfidenz |
|---|---|---|
| `qemu-guest-agent` | existiert | hoch |
| `sudo` | existiert | hoch |
| `curl` | existiert | hoch |
| `git` | existiert | hoch |
| `xz-utils` | existiert | hoch |
| `ca-certificates` | existiert | hoch |
| `gnupg` | existiert | hoch |
| `openssh-server` | existiert | hoch |
| `ifupdown` | existiert | hoch |
| `dhcpcd-base` | existiert | hoch |
| `resolvconf` | existiert | hoch |
| `openresolv` | existiert | hoch |
| `unattended-upgrades` | existiert | hoch |
| `syncthing` | existiert | hoch |

Quelle: <https://packages.debian.org/trixie/> · Abruf 15.08.2026

### unattended-upgrades — Aktivierung ohne erfundene Config

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 4.1 | Das Paket liefert die Vorlage `/usr/share/unattended-upgrades/20auto-upgrades` (sowie `20auto-upgrades-disabled` und `50unattended-upgrades`) mit | <https://packages.debian.org/trixie/all/unattended-upgrades/filelist> | 15.08.2026 | hoch |

Deshalb **kopiert** `modules/10-base.sh` diese Vorlage nach
`/etc/apt/apt.conf.d/20auto-upgrades`, statt den Inhalt der Datei zu erfinden.
Automatische Reboots werden bewusst **nicht** konfiguriert (eine Agent-VM soll
nicht ungefragt neu starten). Steuerbar über `INSTALL_UNATTENDED_UPGRADES`.

---

## 5 · qemu-guest-agent

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 5.1 | `qemu-guest-agent.service` hat unter Debian/Ubuntu **keinen `[Install]`-Abschnitt** (kein `WantedBy=`), ist damit `static` und wird per **udev-Regel** (`SYSTEMD_WANTS`) aktiviert. `systemctl enable` schlägt entsprechend fehl | <https://bugs.launchpad.net/bugs/1883009> · <https://pve.proxmox.com/wiki/Qemu-guest-agent> | 15.08.2026 | hoch |

Konsequenz: `modules/10-base.sh` ruft **nie** `systemctl enable
qemu-guest-agent`. Es prüft nur, ob die Unit läuft. Läuft sie nicht, obwohl das
Paket installiert ist, liegt das mit hoher Wahrscheinlichkeit daran, dass in der
Proxmox-VM-Konfiguration die Option „QEMU Guest Agent" nicht gesetzt ist — dann
fehlt das virtio-Gerät und die udev-Regel greift nicht. Das Modul gibt genau
diesen Hinweis aus.

---

## 6 · IPv6-Deaktivierung, Lingering, DNS-Resolver

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 6.1 | `net.ipv6.conf.<if>.disable_ipv6=1`: „when this value changes from 0 to 1, it will dynamically delete all addresses and routes on the given interface. From now on it will not possible to add addresses/routes to the selected interface." | <https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt> | 15.08.2026 | hoch |
| 6.2 | Die Varianten `net.ipv6.conf.all.disable_ipv6` und `net.ipv6.conf.default.disable_ipv6` sind in ip-sysctl.txt **nicht eigens dokumentiert** — `all`/`default` sind die generische sysctl-Mechanik für Interface-Keys | ebd. (Negativbefund) | 15.08.2026 | mittel |
| 6.3 | Drop-ins unter `/etc/sysctl.d/*.conf` werden von `sysctl --system` eingelesen und sind reboot-fest | `sysctl.d(5)` | 15.08.2026 | hoch |
| 6.4 | `loginctl enable-linger [USER…]` / `disable-linger [USER…]`: „If enabled for a specific user, a user manager is spawned for the user at boot and kept around after logouts. This allows users who are not logged in to run long-running services. Takes one or more user names or numeric UIDs as argument." | <https://manpages.debian.org/trixie/systemd/loginctl.1.en.html> | 15.08.2026 | hoch |
| 6.5 | Ob `loginctl show-user <u> --property=Linger` existiert, ist in der Manpage **nicht** aufgeführt | ebd. (Negativbefund) | 15.08.2026 | mittel |
| 6.6 | Quad9: empfohlene Adressen `9.9.9.9` und `149.112.112.112` (Secure-Service: Blocklist + DNSSEC) | <https://quad9.net/service/service-addresses-and-features/> · <https://docs.quad9.net/services/> | 15.08.2026 | hoch |

Zu 6.2/6.5: `modules/05-network.sh` schreibt `all`, `default` **und** `lo`, weil
`all`/`default` neu erzeugte Interfaces nicht rückwirkend erfassen bzw.
umgekehrt — die Kombination ist die verbreitete Praxis, aber nicht wörtlich
dokumentiert. `modules/50-lingering.sh` prüft den Zustand deshalb
**primär über die Existenz von `/var/lib/systemd/linger/<user>`** und nutzt
`loginctl show-user` nur als zusätzliche Anzeige.

`[UNVERIFIZIERT-ONBOX]` → siehe Abschnitt 9, Punkte O-2 und O-3.

---

## 7 · sshd unter Debian 13

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 7.1 | Debian 13 kann sshd **entweder** über `ssh.service` **oder** über Socket-Aktivierung (`ssh.socket`) betreiben; welches von beidem aktiv ist, hängt von Installations- bzw. Upgrade-Weg ab | <https://www.claudiokuenzler.com/blog/1522/debian-13-trixie-ssh-service-reload-error-cannot-bind-address> | 15.08.2026 | mittel |

Das ist keine offizielle Quelle, deshalb `mittel`. Konsequenz:
`modules/20-user-ssh.sh` **erkennt** den aktiven Betriebsmodus und handelt
entsprechend — `systemctl reload ssh.service` nur, wenn `ssh.service` aktiv ist.
Bei Socket-Aktivierung wird nicht reloadet (jede Verbindung startet ohnehin
einen frischen sshd, der die Config neu liest) und stattdessen ein Hinweis
ausgegeben. In keinem Fall `restart` — das würde laufende Sessions töten.

`[UNVERIFIZIERT-ONBOX]` → siehe Abschnitt 9, Punkt O-4.

---

## 8 · Hermes-Agent und Sandbox-Image

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 8.1 | Das offizielle Repo ist `github.com/NousResearch/hermes-agent` | <https://github.com/NousResearch/hermes-agent> | 15.08.2026 | hoch |
| 8.2 | Aktuelles Release: Tag `v2026.8.13`, Name „Hermes Agent v0.20.1 (2026.8.13)", veröffentlicht 2026-08-13 — passt zur erwarteten Serie 0.20.x | <https://api.github.com/repos/NousResearch/hermes-agent/releases/latest> | 15.08.2026 | hoch |
| 8.3 | Die im README des Repos genannte Installationsmethode (Linux/macOS/WSL2/Termux) lautet wörtlich: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh \| bash` | README unter 8.1 | 15.08.2026 | hoch |
| 8.4 | `nikolaik/python-nodejs:python3.12-nodejs22` existiert, Status `active`, `last_updated` 2026-07-29T16:57:34Z | <https://hub.docker.com/v2/repositories/nikolaik/python-nodejs/tags/python3.12-nodejs22> | 15.08.2026 | hoch |
| 8.5 | Aktueller Manifest-List-Digest dieses Tags: `sha256:88c41488c175453b29007809b82c3059c9a55b721f14f5a5a4ea64cb995e26e7` | ebd. | 15.08.2026 | hoch |

### Wichtige Hinweise

**Zu 8.3 — Domain-Ring:** Um den Hermes-Installer existieren nachweislich
ähnlich benannte Domains mit abweichenden `curl | bash`-Kommandos. Als Quelle
wurde ausschließlich die im GitHub-Repo selbst gerenderte README akzeptiert.
Die URL steht **nur hier in dieser Datei** und **in keinem Script**. Die
Installation erfolgt später manuell.

**Zu 8.5 — der Digest ist unverändert:** Der Vorgängerstand pinnte
`@sha256:88c41488…`. Der heute gültige Digest ist derselbe. Der Tag hat sich
also nicht bewegt; ein Update des Pins ist nicht nötig. Der Wert steht in
`config.env.example` als `SANDBOX_IMAGE_DIGEST` und wird von `90-verify.sh` nur
**ausgegeben**, nicht geprüft — der echte Abgleich geht erst nach einem
`docker pull` auf der VM.

---

## 9 · Nicht online klärbar — on-box offen

Zu keinem dieser Punkte existiert Script-Logik, die etwas voraussetzt. Sie sind
im Code als `[UNVERIFIZIERT-ONBOX]` markiert.

| ID | Offene Frage | Wo relevant |
|---|---|---|
| O-1 | Prüft der von Debian 13 ausgelieferte dhcpcd-Hook (10.1.0) `/etc/resolv.conf.head` tatsächlich? Test: `grep -n 'resolv.conf.head' /usr/lib/dhcpcd/dhcpcd-hooks/20-resolv.conf` | `modules/05-network.sh` |
| O-2 | Greifen die drei IPv6-sysctl-Keys auf dieser Kiste wie erwartet (keine globale v6-Adresse mehr nach `sysctl --system`)? | `modules/05-network.sh`, `90-verify.sh` |
| O-3 | Liefert `loginctl show-user <user> --property=Linger` auf trixie eine Ausgabe? | `modules/50-lingering.sh` |
| O-4 | Läuft sshd auf dieser VM als `ssh.service` oder via `ssh.socket`? | `modules/20-user-ssh.sh` |
| O-5 | Hermes-0.20-Config-Keys | nicht gescriptet |
| O-6 | Installationsweg des Hermes-Dashboards | nicht gescriptet |
| O-7 | RAM-Fußabdruck von Hermes + Sandbox unter Last (16 GB reichen?) | nicht gescriptet |
| O-8 | Digest-Abgleich nach `docker pull` gegen 8.5 | `90-verify.sh` gibt den Sollwert nur aus |
| O-9 | Syncthing: exakter Pfad der `config.xml` auf dieser Installation (XDG-Wechsel ab 1.27.0, s. Abschnitt 10) | `docs/60-syncthing-spezifikation.md` |
| O-10 | Syncthing: wie viel davon per `syncthing cli config …` setzbar ist statt per XML-Edit | ebd. |

---

## 10 · Syncthing (nur Doku, kein Modul)

| # | Behauptung | Quelle | Abruf | Konfidenz |
|---|---|---|---|---|
| 10.1 | Globale Discovery: `<globalAnnounceEnabled>` unter `<options>` | <https://docs.syncthing.net/users/config.html> | 15.08.2026 | hoch |
| 10.2 | Lokale Discovery: `<localAnnounceEnabled>` unter `<options>` | ebd. | 15.08.2026 | hoch |
| 10.3 | Relays: `<relaysEnabled>` unter `<options>` | ebd. | 15.08.2026 | hoch |
| 10.4 | NAT-Traversal/UPnP: `<natEnabled>` unter `<options>` | ebd. | 15.08.2026 | hoch |
| 10.5 | Sync-Protokoll-Listener: `<listenAddress>` unter `<options>` | ebd. | 15.08.2026 | hoch |
| 10.6 | GUI-Bind: `<address>` unter `<gui>` | ebd. | 15.08.2026 | hoch |
| 10.7 | Versionierung: `<versioning>` unter `<folder>`, Kindelemente u. a. `<cleanupIntervalS>`, `<fsPath>`, `<fsType>` | ebd. | 15.08.2026 | hoch |
| 10.8 | Staggered: `versioning.type = "staggered"`, Parameter `params.maxAge` (in Sekunden bzw. „0 = für immer behalten"), plus `cleanupIntervalS`, optional `fsPath` | <https://docs.syncthing.net/users/versioning.html> | 15.08.2026 | mittel |
| 10.9 | Config-Verzeichnis auf Linux ab Version 1.27.0: `$XDG_STATE_HOME/syncthing` bzw. `$HOME/.local/state/syncthing`; ältere Installationen nutzen weiter `$XDG_CONFIG_HOME/syncthing` bzw. `$HOME/.config/syncthing`. Überschreibbar per `--config`/`--home` bzw. `$STCONFDIR`/`$STHOMEDIR` | <https://docs.syncthing.net/users/config.html> | 15.08.2026 | hoch |
| 10.10 | systemd-User-Unit heißt `syncthing.service`, aktiviert per `systemctl --user enable syncthing.service`; die System-Variante ist `syncthing@.service` (instanziiert als `syncthing@user.service`) | <https://docs.syncthing.net/users/autostart.html> | 15.08.2026 | hoch |

Zu 10.8 nur `mittel`: Die Doku-Seite zeigt ein wörtliches XML-Beispiel für
*Simple* File Versioning, nicht für *Staggered*. Die Parameternamen stammen aus
dem Referenzabschnitt, nicht aus einem Komplettbeispiel. Vor dem Bau von
Modul 60 gegen eine real erzeugte `config.xml` gegenprüfen.

Zu 10.9/10.10: beantwortet zwei der drei im Auftragsprompt als „offen zu lassen"
markierten Fragen (Pfad der `config.xml`, Name der User-Unit). Offen bleibt die
CLI-Konfigurierbarkeit → O-10.

---

## 11 · Werkzeuge dieser Arbeitsumgebung

| # | Behauptung | Konfidenz |
|---|---|---|
| 11.1 | `shellcheck` war auf der Arbeitsmaschine nicht installiert und liess sich mangels passwortlosem `sudo` nicht per `apt-get` nachziehen. Stattdessen wurde das offizielle statische Binary v0.11.0 (<https://github.com/koalaman/shellcheck/releases>) in ein temporäres Verzeichnis geladen und von dort ausgeführt. Das System wurde nicht verändert. | hoch |
