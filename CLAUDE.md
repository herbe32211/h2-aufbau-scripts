# CLAUDE.md — H2 Agent-VM Bootstrap-Scripts

## Kontext

Dieses Repo enthält modulare Bootstrap-Scripts für die Agent-VM (VM 100, "worker")
auf dem Proxmox-Host `pve-h2`. Die VM betreibt später einen KI-Agenten (Hermes
0.20.x) mit Docker-Sandbox. **Die Scripts bereiten nur das Fundament vor — sie
installieren den Agenten selbst NICHT.**

Arbeitssprache: Deutsch.

## Verbindliche Arbeitsweise

1. **Erst Plan, dann Ausführung.** Struktur und offene Fragen zeigen, auf OK
   warten, dann erst Dateien schreiben.
2. **Nicht raten.** Jede Tatsachenbehauptung (Paketname, Repo-URL, Kommando-
   Syntax, Config-Key) wird per Websuche gegen eine offizielle Quelle
   verifiziert und in `VERIFIKATION.md` mit Quelle · Abrufdatum · Konfidenz
   festgehalten. Was nicht verifizierbar ist, wird als `[UNVERIFIZIERT-ONBOX]`
   markiert plus TODO-Kommentar im Script — nie ein plausibler Wert erfunden.
   Bei mehrdeutiger Quellenlage (z. B. mehrere gleichnamige Repos): **fragen**.
3. **Keine Secrets.** Kein Script enthält oder erzeugt API-Keys, Tokens oder
   Passwörter. SSH-Public-Key kommt als Variable, niemals ein Private Key.
   `config.env` mit realen Werten ist per `.gitignore` ausgeschlossen;
   versioniert wird nur `config.env.example`.
4. **K2 — Host bleibt agentenfrei.** Claude Code erzeugt Scripts und Blöcke.
   Claude Code arbeitet **niemals selbst per SSH** auf dem Proxmox-Host oder
   der VM. Ausführung macht der Mensch gegen Live-Output.

## Was dieses Repo nicht anfasst

Proxmox-Host-Konfiguration (`qm`, PVE-Firewall) · Hermes-Installation ·
Provider-Keys · Discord · Tailnet-ACLs im Admin-Panel · `tailscale up`
(interaktiver Auth-Flow). Diese Schritte bleiben bewusst manuell und werden
nur **dokumentiert**, nicht gescriptet.

## Code-Standards

- Bash, `set -euo pipefail`, shellcheck-sauber (0 Findings), jede Aktion geloggt.
- **Jedes Modul idempotent und einzeln lauffähig** — zweiter Lauf = No-op mit
  klarer Meldung, kein Fehler. Das ist keine Kür: die Module laufen ggf. über
  eine bereits teilkonfigurierte VM.
- Nummernlücken in `modules/` sind Absicht — `run.sh` nimmt neue Module
  automatisch auf. Entfernen = Datei löschen.
- Pfade konsequent quoten.
- `.gitattributes` erzwingt LF (CRLF-Checkout unter Windows killt Scripts).
- Variablennamen: `AGENT_USER` / `AGENT_HOSTNAME` statt `USERNAME`/`HOSTNAME`
  (Kollision mit Bash-Builtins).
- Fail-closed bei unbekanntem Zustand: lieber abbrechen mit klarer Meldung als
  in eine Config schreiben, die niemand liest.
- **Laufende Remote-Sessions nie gefährden:** nichts, was Netz oder sshd
  abschneiden könnte, ohne Vorprüfung + Rollback (z. B. `sshd -t` vor dem
  Deaktivieren von Passwort-Login).

## Ziel-Umgebung (on-box verifiziert, 14.08.2026)

| Fakt | Wert |
|---|---|
| Host | Proxmox VE 9.2.10, `pve-h2.home.arpa`, ext4 + LVM-thin |
| VM | ID 100, Name/Hostname `worker`, 6 vCPU (1 Socket), 16 GB RAM, Ballooning AUS, 128 GB Disk |
| OS | Debian 13.6 (trixie), Kernel 6.12.101, Minimal (nur SSH-Server + Standardwerkzeuge) |
| Agent-User | `hermes`, sudo, aktuell noch Passwort-Login |
| Netz-Stack | **ifupdown** (`/etc/network/interfaces`), Interface `ens18`, statisch |
| IP (Übergangsphase) | 10.42.0.20/24, GW 10.42.0.1 — Box hängt hinter NAT eines Dell-Rechners, zieht später ins 192.168.178.0/24 um |
| DNS | extern (9.9.9.9), direkt in `/etc/resolv.conf` + `/etc/resolv.conf.head` |
| DHCP-Client | **dhcpcd** (nicht dhclient!) — räumt beim Shutdown die `resolv.conf` leer, wenn er noch aktiv ist |
| qemu-guest-agent | vom Installer bereits mitgebracht, aktiv |
| Zeitzone | aktuell Europe/Berlin, NTP aktiv, RTC in UTC |

## Offene Entscheidung, die im Prompt auftaucht

`TIMEZONE`: Der ursprüngliche Entwurf sah `UTC` in der VM vor. Die VM steht
aktuell auf `Europe/Berlin`. Der Aufbauplan verlangt UTC nur für `log.jsonl`
(Anzeige lokal), nicht zwingend für die Systemzeit. **Nicht eigenmächtig
umstellen — fragen.**
