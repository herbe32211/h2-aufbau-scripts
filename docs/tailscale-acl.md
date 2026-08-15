# Tailnet-Policy für den H2-Agent-Node

Fertiges Snippet für das Tailnet-Policy-File im Admin-Panel
(**Access Controls** → Policy-File, HuJSON).

Verifiziert gegen <https://tailscale.com/kb/1337/acl-syntax> und
<https://tailscale.com/kb/1018/acls>, Abruf 15.08.2026. Siehe
`VERIFIKATION.md`, Abschnitt 2.

---

## Zielbild in einem Satz

Admin-Geräte dürfen den H2-Node erreichen. Der H2-Node darf **kein** anderes
Tailnet-Gerät erreichen.

Das ist die Tailnet-Hälfte derselben Idee wie die Proxmox-Firewall: Die
Agent-VM ist ein Gerät, dem man Zugriff *gibt*, nicht eines, dem man Zugriff
*erlaubt zu nehmen*. Wenn der Agent kompromittiert wird, soll er nicht auf
Laptop, NAS oder Router weiterspringen können.

---

## Drei Dinge, die vorher zu wissen sind

**1 · Die Policy muss VOR dem `tailscale up` stehen.**
`tailscale up --advertise-tags=tag:h2-agent` schlägt fehl, wenn `tag:h2-agent`
im Policy-File nicht unter `tagOwners` definiert ist. Erst Policy speichern,
dann verbinden.

**2 · Ein Tailnet ohne eigene Policy läuft im allow-all-Modus.**
Neue Tailnets starten mit einer Default-Policy, die jedem Gerät den Zugriff auf
jedes andere erlaubt. Sobald hier eine eigene Policy gespeichert wird, gilt
deny-by-default: **alles, was nicht ausdrücklich erlaubt ist, wird gesperrt.**

Konsequenz: Wenn dein Tailnet bisher ohne eigene Regeln lief, funktioniert nach
dem Speichern schlagartig nichts mehr, was hier nicht aufgeführt ist — auch
Verbindungen zwischen bestehenden Geräten, die vorher selbstverständlich waren.
Deshalb enthält das Snippet unten eine Regel, die den bisherigen Zustand für
alle *anderen* Geräte erhält. Diese Regel prüfen und an das eigene Tailnet
anpassen, nicht blind übernehmen.

**3 · Getaggte Geräte gehören keinem Benutzer mehr.**
Das ist gewollt (keine Key-Expiry, saubere Regelzuordnung), heisst aber auch:
Der Node taucht nicht mehr unter „deine Geräte" auf, und Zugriff darauf regelt
ausschliesslich diese Policy.

---

## Snippet

Platzhalter, die zu ersetzen sind:

| Platzhalter | Bedeutung |
|---|---|
| `admin@example.com` | dein Tailscale-Login (die Adresse, mit der du dich am Admin-Panel anmeldest) |
| `laptop`, `handy` | die Tailscale-Gerätenamen deiner Admin-Geräte |

```jsonc
{
  // ---------------------------------------------------------------------
  // Wer darf welchen Tag vergeben.
  // Ohne diesen Block scheitert `tailscale up --advertise-tags=tag:h2-agent`.
  // ---------------------------------------------------------------------
  "tagOwners": {
    "tag:h2-agent": ["admin@example.com"],
  },

  // ---------------------------------------------------------------------
  // Benannte Gruppen — hält die Regeln unten lesbar.
  // ---------------------------------------------------------------------
  "groups": {
    "group:h2-admins": ["admin@example.com"],
  },

  "acls": [
    // -------------------------------------------------------------------
    // 1) Admins dürfen den H2-Node erreichen.
    //    SSH über das Tailnet plus das spätere Dashboard über
    //    `tailscale serve` (443).
    // -------------------------------------------------------------------
    {
      "action": "accept",
      "src":    ["group:h2-admins"],
      "dst":    ["tag:h2-agent:22", "tag:h2-agent:443"],
    },

    // -------------------------------------------------------------------
    // 2) Bestandsschutz für alles ausser dem H2-Node.
    //
    //    Diese Regel bildet den bisherigen allow-all-Zustand für deine
    //    übrigen Geräte nach — OHNE den H2-Node als Quelle einzuschliessen.
    //    Ohne sie sperrt das Speichern dieser Policy schlagartig auch
    //    Verbindungen aus, die vorher funktioniert haben.
    //
    //    Wenn dein Tailnet bereits eigene, engere Regeln hatte: diese Regel
    //    ersetzen statt ergänzen.
    // -------------------------------------------------------------------
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:member:*"],
    },

    // -------------------------------------------------------------------
    // KEINE Regel mit "src": ["tag:h2-agent"].
    //
    // Genau das ist der Punkt. Der H2-Node steht in keiner src-Liste, also
    // darf er von sich aus kein Tailnet-Gerät erreichen. Antwortpakete auf
    // Verbindungen, die ein Admin aufgebaut hat, sind davon nicht betroffen
    // — Tailscale-ACLs wirken auf Verbindungsaufbau, nicht auf einzelne
    // Pakete.
    //
    // "autogroup:member" oben umfasst Benutzer, keine getaggten Geräte.
    // Der H2-Node ist getaggt und fällt deshalb nicht darunter.
    // -------------------------------------------------------------------
  ],

  // ---------------------------------------------------------------------
  // Tailscale SSH bewusst NICHT aktiviert.
  // Der Zugang läuft über den normalen sshd mit Key-Auth (Modul 20). Zwei
  // parallele SSH-Wege sind zwei Wege, die man härten und im Blick behalten
  // muss.
  // ---------------------------------------------------------------------
  "ssh": [],
}
```

---

## Negativtest — gehört zur Abnahme

Nach `tailscale up` **auf der Agent-VM** ausführen. Ziel ist die Tailscale-IP
(100.x.y.z) eines anderen Tailnet-Geräts, nicht dessen LAN-IP:

```bash
tailscale status                      # Tailscale-IPs der anderen Peers ablesen
tailscale ping <peer-tailscale-ip>    # MUSS scheitern bzw. timeouten
nc -vz <peer-tailscale-ip> 22         # MUSS scheitern
```

Beides muss fehlschlagen. Gelingt eines davon, greift Regel 2 weiter als
gedacht — dann prüfen, ob der H2-Node versehentlich unter `autogroup:member`
fällt (passiert, wenn das Tagging nicht funktioniert hat und der Node noch an
einem Benutzerkonto hängt).

Gegenprobe in die andere Richtung, vom Admin-Laptop aus:

```bash
ssh hermes@<h2-tailscale-ip>          # MUSS klappen
```

Und die Kontrolle, dass das Tagging überhaupt gegriffen hat:

```bash
tailscale status --json | grep -i tag
```

---

## Später: Dashboard über `tailscale serve`

Nur zur Dokumentation, wird von den Bootstrap-Scripts nicht ausgeführt.
Syntax verifiziert gegen <https://tailscale.com/kb/1242/tailscale-serve>
(Abruf 15.08.2026):

```bash
# Lokalen Dienst auf Port 3000 als HTTPS im Tailnet veröffentlichen
tailscale serve --bg localhost:3000

tailscale serve status
tailscale serve reset
```

`serve` veröffentlicht ausschliesslich innerhalb des Tailnets — im Gegensatz zu
`tailscale funnel`, das ins öffentliche Internet exponiert. **`funnel` hier
niemals verwenden.** Der Zugriff auf den veröffentlichten Port unterliegt
weiterhin Regel 1 oben.
