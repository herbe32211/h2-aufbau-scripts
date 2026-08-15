# Spezifikation für das spätere Modul 60 — Syncthing

**Das ist eine Anforderungsbeschreibung, kein Modul.**

Bewusst liegt diese Datei unter `docs/` und nicht als `modules/60-syncthing.sh`:
`run.sh` sammelt alle `modules/[0-9][0-9]-*.sh` automatisch ein und würde ein
halbfertiges Modul mitausführen. Wer Modul 60 baut, legt die Script-Datei neu
an — ab dann läuft sie automatisch mit.

Alle Konfigurationsschlüssel unten sind gegen die offizielle Syncthing-Doku
verifiziert (Abruf 15.08.2026, siehe `VERIFIKATION.md`, Abschnitt 10), damit
beim Bau nichts mehr recherchiert werden muss.

---

## Zweck

Ein definierter Unterordner der Agent-VM wird mit genau einem Admin-Gerät
synchronisiert — als Arbeitsablage und als Weg, Dateien hinein- und
herauszubekommen, ohne `scp`-Turnerei.

## Sicherheitsvorgabe: Syncthing darf ausschliesslich über das Tailnet reden

Syncthing bringt von Haus aus Global Discovery, Relays und NAT-Traversal mit.
Alles drei ist dafür gebaut, Verbindungen über fremde Infrastruktur zustande zu
bringen, auch durch Firewalls hindurch. Genau das unterläuft sowohl die
Proxmox-Firewall (`pve-firewall-zielbild.md`) als auch die Tailnet-ACL
(`tailscale-acl.md`).

Deshalb wird alles davon abgeschaltet, und Syncthing bindet nur an die
Tailscale-IP.

---

## Sollzustand der Konfiguration

### `<options>`

| Element | Sollwert | Warum |
|---|---|---|
| `globalAnnounceEnabled` | `false` | Kein Melden an Syncthings öffentliche Discovery-Server. |
| `localAnnounceEnabled` | `false` | Kein Broadcast/Multicast ins lokale Netz — das LAN soll die VM nicht sehen. |
| `relaysEnabled` | `false` | Keine Verbindungen über fremde Relay-Server. |
| `natEnabled` | `false` | Kein UPnP/NAT-PMP-Löcherbohren im Router. |
| `listenAddress` | `tcp://<TAILSCALE_IP>:22000` | Sync-Protokoll ausschliesslich auf dem Tailnet-Interface. **Nicht** der Default `default`, der auf allen Interfaces lauscht. |

### `<gui>`

| Element | Sollwert | Warum |
|---|---|---|
| `address` | `<TAILSCALE_IP>:8384` | Weboberfläche nur über das Tailnet. Default `127.0.0.1:8384` wäre auch vertretbar plus `tailscale serve` davor — dann Variante B unten. |

### `<folder>` — Versionierung

Staggered File Versioning aktiv, damit ein fehlgeleiteter Agent-Schreibzugriff
nicht endgültig ist:

| Element / Parameter | Sollwert |
|---|---|
| `versioning.type` | `staggered` |
| `versioning.params.maxAge` | noch festzulegen (`0` = für immer behalten) |
| `versioning.cleanupIntervalS` | Default belassen, sofern kein Grund dagegen spricht |
| `versioning.fsPath` | optional, nur wenn die Versionen ausserhalb des Ordners liegen sollen |

> **Konfidenz mittel.** Die Doku-Seite zeigt ein wörtliches XML-Beispiel nur für
> *Simple* File Versioning; die Parameternamen für *staggered* stammen aus dem
> Referenzabschnitt. Vor dem Bau des Moduls gegen eine real erzeugte
> `config.xml` gegenprüfen — am einfachsten, indem man Staggered einmal über
> die GUI einschaltet und danach in die Datei sieht.

### Freigegebene Ordner

Genau **ein** definierter Unterordner, nicht das Home-Verzeichnis und erst
recht nicht `/`. Der Pfad gehört in `config.env` als eigene Variable
(Vorschlag: `SYNCTHING_FOLDER_PATH`), nicht ins Script.

---

## Betriebsmodell

Syncthing läuft als **User-Unit** unter `AGENT_USER`, nicht als Systemdienst:

```bash
systemctl --user enable --now syncthing.service
```

Verifiziert: Die User-Unit heisst `syncthing.service`, die System-Variante
`syncthing@.service` (instanziiert als `syncthing@hermes.service`).

Das funktioniert nur, weil Modul 50 Lingering aktiviert hat — sonst würde
systemd den User-Manager beim Logout abbauen und Syncthing mitnehmen. Modul 60
muss diese Abhängigkeit prüfen und mit klarer Meldung abbrechen, wenn
`/var/lib/systemd/linger/<AGENT_USER>` fehlt.

---

## Reihenfolgeproblem, das beim Bau zu lösen ist

Die Tailscale-IP ist erst bekannt, **nachdem** `tailscale up` gelaufen ist —
und das ist ein manueller, interaktiver Schritt (Modul 40 führt ihn bewusst
nicht aus).

Modul 60 muss deshalb:

1. die Tailscale-IP zur Laufzeit ermitteln (`tailscale ip -4`),
2. mit klarer Meldung abbrechen, wenn Tailscale noch nicht verbunden ist —
   **nicht** ersatzweise auf `0.0.0.0` binden,
3. beim erneuten Lauf eine geänderte Tailscale-IP sauber übernehmen.

---

## Offene Fragen vor dem Bau

| ID | Frage | Stand |
|---|---|---|
| S-1 | Exakter Pfad der `config.xml` auf dieser Installation | Ab Syncthing 1.27.0 `$XDG_STATE_HOME/syncthing` bzw. `~/.local/state/syncthing`; ältere Installationen nutzen weiter `~/.config/syncthing`. Debians Paketversion prüfen und **on-box** nachsehen, welcher Pfad tatsächlich benutzt wird. `[UNVERIFIZIERT-ONBOX]` |
| S-2 | Wie viel lässt sich per `syncthing cli config …` setzen, statt XML zu editieren? | **Offen.** Ein CLI-Weg wäre deutlich idempotenter als sed/xmlstarlet auf der `config.xml`. Vor dem Bau klären — davon hängt die Struktur des ganzen Moduls ab. `[UNVERIFIZIERT-ONBOX]` |
| S-3 | Wird die Konfiguration im laufenden Betrieb neu eingelesen, oder braucht es einen Neustart der Unit? | Offen. Relevant für die Idempotenz. |
| S-4 | Welcher Wert für `maxAge`? | Produktentscheidung, nicht technisch. |
| S-5 | GUI-Variante A (direkt auf Tailscale-IP binden) oder B (auf 127.0.0.1 binden, `tailscale serve` davor)? | Offen. B ist sauberer (TLS und Zugriffskontrolle über die Tailnet-ACL), A ist einfacher. |

Die `config.xml` von Hand zu editieren ist die letzte Wahl, nicht die erste.
Wenn S-2 einen brauchbaren CLI-Weg ergibt, wird das Modul deutlich robuster.

---

## Abnahme des späteren Moduls

```bash
# Nur die Tailscale-IP darf lauschen — keine 0.0.0.0-Zeile:
ss -tlnp | grep -E '22000|8384'

# Kein Discovery-/Relay-Verkehr:
grep -E 'globalAnnounceEnabled|relaysEnabled|natEnabled|localAnnounceEnabled' <config.xml>
# alle vier müssen false sein

# Vom LAN aus (nicht vom Tailnet): beides MUSS scheitern
nc -vz -w2 <VM_LAN_IP> 8384
nc -vz -w2 <VM_LAN_IP> 22000
```
