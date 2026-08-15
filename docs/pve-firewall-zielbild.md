# Zielbild der Proxmox-VM-Firewall (VM 100 „worker")

**Referenzdokument, kein Script.** Nach Grundsatz K2 fasst dieses Repo die
Proxmox-Host-Konfiguration nicht an. Die Regeln werden von Hand im PVE-Webinterface
oder in `/etc/pve/firewall/100.fw` gesetzt.

---

## Warum überhaupt

Auf der VM läuft ein KI-Agent mit Werkzeugzugriff und einer Docker-Sandbox. Er
braucht das Internet — Modell-APIs, Paketquellen, Git. Er braucht das
Heimnetz **nicht**: keinen NAS-Zugriff, keine Drucker, kein Router-Webinterface,
keine anderen Rechner.

Diese Asymmetrie ist die ganze Idee. Ein Agent, der sich verrennt oder
kompromittiert wird, soll nach aussen telefonieren können (das lässt sich nicht
sinnvoll verhindern, wenn er arbeiten soll), aber nicht ins eigene Netz
hineingreifen.

---

## Regelwerk

Bezeichnungen wie `<LAN_SUBNET>` sind zu ersetzen. In der Übergangsphase ist
das `10.42.0.0/24`, nach dem Umzug `192.168.178.0/24`.

### Ausgehend (Direction OUT)

| # | Aktion | Ziel | Zweck |
|---|---|---|---|
| 1 | DROP | `<LAN_SUBNET>` | **Die zentrale Regel.** Kein Zugriff auf Nachbargeräte. |
| 2 | ACCEPT | alles übrige | Internet: Modell-APIs, apt, Docker Hub, GitHub, Tailscale. |

Reihenfolge ist entscheidend: DROP muss **vor** ACCEPT stehen.

### Eingehend (Direction IN)

| # | Aktion | Quelle | Zweck |
|---|---|---|---|
| 1 | ACCEPT | `100.64.0.0/10` | Tailnet (CGNAT-Bereich, den Tailscale nutzt). |
| 2 | DROP | alles übrige | Default-Policy IN = DROP. |

Der Zugang läuft ausschliesslich über das Tailnet. Wer *innerhalb* des Tailnets
was darf, regelt `tailscale-acl.md` — die PVE-Firewall macht hier nur die grobe
Tür auf.

---

## Warum keine Ausnahme für den Router nötig ist

Das ist der Grund, warum Modul 05-network so gebaut ist, wie es gebaut ist:

* **DNS** geht an öffentliche Resolver (Quad9), nicht an den Router. Regel OUT-1
  blockt den Router mit, das ist folgenlos.
* **DHCP** wird nicht gebraucht — die IP ist statisch aus `config.env`.
* **NTP** läuft über öffentliche Server, nicht über den Router.

Ohne diese drei Punkte bräuchte man eine Ausnahme für die Router-IP, und genau
die wäre das Loch, durch das der Agent doch wieder ins LAN käme.

Wer diese Firewall aktiviert, ohne vorher `05-network.sh` laufen zu lassen,
schneidet der VM die Namensauflösung ab und `apt` bleibt hängen.

---

## IPv6

IPv6 ist **in der VM** deaktiviert (`DISABLE_IPV6=true`, Modul 05-network,
sysctl-Drop-in `/etc/sysctl.d/99-h2-disable-ipv6.conf`).

Der Grund gehört hierher: Das Regelwerk oben ist IPv4-formuliert. Eine
DROP-Regel auf `192.168.178.0/24` sagt nichts über `fd00::/8` oder ein
globales IPv6-Präfix. Bliebe IPv6 aktiv, wäre es der offene Umweg um genau
diese Sperre herum — Nachbargeräte im LAN sind über IPv6 in der Regel genauso
erreichbar wie über IPv4.

Zwei Wege führen zum Ziel, und dies ist der gewählte:

1. **In der VM abschalten** (gewählt). Ein Mechanismus, an einer Stelle,
   überprüfbar mit `ip -6 addr show scope global`.
2. Die Firewall-Regeln für IPv6 spiegeln. Doppelte Pflege, doppelte
   Gelegenheit, eine Regel zu vergessen.

Wenn IPv6 später gebraucht wird, muss **zuerst** das Regelwerk gespiegelt
werden — nicht umgekehrt.

---

## Negativtests

Nach dem Aktivieren der Firewall auf der VM ausführen. Ohne diese Tests ist die
Firewall nicht abgenommen, sondern nur konfiguriert.

**Rückfallebene bereithalten:** Die Proxmox-Konsole (noVNC) funktioniert
unabhängig vom Gastnetz. Wer sich mit einer Regel aussperrt, kommt darüber
wieder hinein.

```bash
# 1) LAN-Nachbargerät muss unerreichbar sein.
#    <LAN_PEER> = IP eines anderen Geräts im Heimnetz, z. B. NAS oder Drucker.
ping -c2 -W2 <LAN_PEER>          # MUSS scheitern
nc -vz -w2 <LAN_PEER> 22         # MUSS scheitern
nc -vz -w2 <LAN_PEER> 80         # MUSS scheitern

# 2) Router-Webinterface muss unerreichbar sein.
nc -vz -w2 <GATEWAY_IP> 80       # MUSS scheitern

# 3) IPv6 ist geschlossen — nicht durch eine Regel, sondern durch Abwesenheit.
ip -6 addr show scope global     # MUSS leer sein
ping6 -c2 -W2 <LAN_PEER_V6>      # MUSS scheitern ("Network is unreachable")

# 4) Internet muss weiterhin gehen — sonst ist die Regel zu scharf.
getent hosts deb.debian.org      # MUSS klappen
curl -sS -o /dev/null -w '%{http_code}\n' https://deb.debian.org/   # 200

# 5) Tailnet muss weiterhin gehen.
tailscale status                 # MUSS Peers zeigen
```

Punkt 4 ist kein Nebenschauplatz: Eine Firewall, die auch das Internet
abschneidet, fällt beim nächsten `apt-get update` auf — aber unter Umständen
erst Wochen später und dann mit einer irreführenden Fehlermeldung.

Vollständige Gegenprobe: `modules/90-verify.sh` erneut laufen lassen. Es prüft
Punkt 3 und 4 mit ab.

---

## Was diese Firewall nicht leistet

* Sie hindert den Agenten nicht daran, Daten ins Internet zu schicken. Das ist
  eine bewusste Grenze: ein Agent, der arbeiten soll, braucht ausgehende
  Verbindungen. Wer das einschränken will, braucht eine Allowlist auf
  Zielhost-Ebene — ein anderes, deutlich aufwendigeres Konzept.
* Sie ersetzt die Tailnet-ACL nicht. Ohne `tailscale-acl.md` darf der Node über
  das Tailscale-Interface auf andere Tailnet-Geräte zugreifen — und die stehen
  womöglich genau in dem LAN, das hier gesperrt wurde.
