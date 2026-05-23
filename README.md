# tm-safe-hyperbackup

Ein POSIX-sh-Skript für den **DSM-Aufgabenplaner**, das einen **Hyper-Backup-Task**
auf eine **Time-Machine-Freigabe** kontrolliert auslöst und dabei opportunistisch
versucht, das Backup in eine Phase ohne aktive TM-Schreibvorgänge zu legen.

Entstanden als Lernprojekt mit dokumentiertem Workflow (`tasks/`-Ordner mit
Recherche und Plan). Wer mag, kann dort nachlesen wie wir auf die Strategie
gekommen sind — die Erkenntnisse zum SMB-Lock-Verhalten von macOS Time Machine
sind unabhängig vom Skript interessant.

## Wann ist das nützlich?

Du hast einen Synology-NAS mit DSM 7.x und nutzt ihn als Time-Machine-Ziel für
einen oder mehrere Macs. Du willst die Time-Machine-Sparsebundle-Daten **selbst
nochmal sichern** — etwa mit Hyper Backup zu Synology C2, zu USB, oder zu einem
zweiten NAS. Naiv per Cron oder Hyper-Backup-Scheduler triggern hat zwei
Probleme:

- Time Machine schreibt potenziell **mitten in dein Backup hinein** (TM macht
  selbst regelmäßig Snapshots, der Mac steht in SMB-Verbindung mit der Freigabe).
- macOS hält **SMB-OpLock-Leases** nach jedem Backup im Cache, oft stundenlang.
  Naive Heuristiken („sind Locks da?") erkennen das nicht und blockieren das
  Backup für immer, obwohl gar nichts mehr geschrieben wird.

Dieses Skript löst beides:

1. Findet **echte Schreibaktivität** durch Vergleich zweier `smbstatus`-Samples
   (gleicher Hash = Lock-Cache, kein Schreibvorgang).
2. **Triggert das Backup trotzdem**, wenn es nach einem Timeout immer noch aktiv
   wirkt — und verlässt sich dabei auf den **automatischen Btrfs-Snapshot** von
   Hyper Backup als Konsistenz-Garantie (Crash-Konsistenz; TM-Sparsebundles sind
   dafür designt).

## Voraussetzungen

- Synology NAS mit **DSM 7.x** (auf 7.3 entwickelt und getestet)
- **Btrfs**-Volume für die TM-Freigaben (für den automatischen Snapshot von
  Hyper Backup — die eigentliche Konsistenz-Garantie)
- **Hyper Backup**-Paket installiert
- Pro TM-Freigabe ein **bereits angelegter Hyper-Backup-Task** (zum gewünschten
  Ziel — C2 Cloud, USB, Remote-NAS etc.)
- Externe Tools verfügbar: `smbstatus` (Samba 4.12+), `jq`, `synobackup`, `cksum`
  (alle Standard auf DSM 7.x)

## Schnellstart

### 1. Skript-Inhalt holen

```sh
git clone https://github.com/johndoejai/tm-safe-hyperbackup.git
cat tm-safe-hyperbackup/tm-safe-hyperbackup.sh | pbcopy   # macOS
# oder: xclip -selection clipboard < tm-safe-hyperbackup.sh   # Linux
```

### 2. Anpassen pro TM-Freigabe

Im **Konfigurationsblock oben** (`# ====== Anpassen pro TM-Freigabe ======`)
drei Werte ändern:

| Variable | Was | Wo finden |
|---|---|---|
| `TM_SHARE` | Name der TM-Freigabe in DSM | DSM → Systemsteuerung → Freigegebener Ordner |
| `TASK_ID` | Numerische ID des Hyper-Backup-Tasks | siehe unten |
| `TASK_NAME` | Name desselben Tasks (für Log-Filter) | siehe unten |

**TASK_ID und TASK_NAME ermitteln:** auf der NAS per SSH (als root oder via sudo):

```sh
cat /var/packages/HyperBackup/etc/synobackup.conf
```

Suche nach dem `[task_N]`-Block, in dem `backup_folders` deine TM-Freigabe
enthält. `N` ist die `TASK_ID`. Der Wert von `name="..."` im selben Block ist
der `TASK_NAME`.

### 3. Im DSM-Aufgabenplaner als root-Task einrichten

DSM → **Systemsteuerung → Aufgabenplaner → Erstellen → Geplante Aufgabe →
Benutzerdefiniertes Skript**

| Reiter | Feld | Wert |
|---|---|---|
| Allgemein | Aufgabe | z. B. `TM-Backup MyMac` |
| Allgemein | Benutzer | **root** |
| Zeitplan | (z. B.) | täglich 02:30 |
| Aufgabeneinstellungen | E-Mail bei abnormaler Beendigung | empfohlen |
| Aufgabeneinstellungen | Benutzerdefiniertes Skript | **Skript-Inhalt einfügen** |

### 4. Erst mit DRY_RUN testen

Im eingefügten Skript ganz oben:

```sh
DRY_RUN="${DRY_RUN:-0}"
```

→ ändere die `0` auf `1`. Task speichern, manuell ausführen (Button „Ausführen"),
nach 1–2 min „Ergebnis anzeigen". Erwartet: Phase 0/A/B durchlaufen, kein
echtes Backup, Exit 0.

Wenn das passt: `DRY_RUN` zurück auf `0`, speichern. Ab dem nächsten geplanten
Zeitpunkt läuft es scharf.

### 5. Für weitere TM-Freigaben

Pro Freigabe einen eigenen Aufgabenplaner-Task (eigene Kopie des Skripts mit
angepassten `TM_SHARE` / `TASK_ID` / `TASK_NAME`). Andere Startzeit wählen,
damit nicht zwei Hyper-Backup-Tasks parallel laufen.

## Konfigurations-Übersicht

| Variable | Default | Beschreibung |
|---|---|---|
| `TM_SHARE` | `TimeMachine` | Name der TM-Freigabe (wie in DSM) |
| `TASK_ID` | `1` | Hyper-Backup-Task-ID |
| `TASK_NAME` | `MyHyperBackupTask` | Task-Name für Log-Filter |
| `DRY_RUN` | `0` | Auf `1` setzen für Testlauf ohne Trigger |
| `DEBUG` | `0` | Auf `1` setzen für rohe `smbstatus`-Auszüge im Log |
| `SMB_POLL_INTERVAL` | `60` | Sekunden zwischen den zwei Samples einer Prüfung |
| `SMB_POLL_TIMEOUT_SEC` | `1800` (30 min) | Max. Wartezeit auf TM-Ruhe; danach Fallthrough mit Warn-Log |
| `HB_POLL_INTERVAL` | `30` | Sekunden zwischen HB-Log-Checks (Backup-Ende) |
| `HB_POLL_TIMEOUT_SEC` | `21600` (6 h) | Max. Wartezeit auf Backup-Ende |
| `HB_STARTED_TIMEOUT_SEC` | `300` (5 min) | Max. Wartezeit auf den „Started"-Log-Marker |
| `VOLUME_PATH` | `/volume2` | Volume mit den TM-Freigaben (für Btrfs-Check) |
| `SMBSTATUS_BIN` | `/usr/local/bin/smbstatus` | Voller Pfad |
| `SYNOBACKUP_BIN` | `/usr/syno/bin/synobackup` | Voller Pfad |
| `JQ_BIN` | `/usr/bin/jq` | Voller Pfad |
| `HB_LOG` | `/var/packages/HyperBackup/var/log/synolog/synobackup.log` | HB-Logfile |
| `HB_CONF` | `/var/packages/HyperBackup/etc/synobackup.conf` | HB-Config |

**Alle Werte sind per Umgebungsvariable überschreibbar**, z. B. für Tests:

```sh
sudo DRY_RUN=1 DEBUG=1 SMB_POLL_INTERVAL=15 SMB_POLL_TIMEOUT_SEC=60 \
    sh /pfad/zum/tm-safe-hyperbackup.sh
```

## Exit-Codes

| Code | Bedeutung |
|---|---|
| `0` | Erfolg (Backup gelaufen oder DRY_RUN gemacht) |
| `1` | Konfig-Fehler (Variable leer, Bin/Logfile nicht erreichbar, TASK_ID/TASK_NAME inkonsistent) |
| `11` | `synobackup`-Aufruf fehlgeschlagen ODER Backup wurde von HB nicht innerhalb von `HB_STARTED_TIMEOUT_SEC` gestartet |
| `12` | Backup im HB-Log als fehlgeschlagen/abgebrochen markiert |
| `13` | Backup-Ende nicht im Zeitfenster (`HB_POLL_TIMEOUT_SEC`) erkannt |

Im DSM-Aufgabenplaner zeigt sich der Exit-Code im Statuslog. Mit der
E-Mail-Option „nur bei abnormaler Beendigung" bekommst du eine Mail bei jedem
Exit ≠ 0.

## Wie die SMB-Lock-Heuristik funktioniert

`smbstatus -L --json` liefert alle aktuell auf dem NAS gehaltenen SMB-Datei-Locks.
Innerhalb eines TM-Sparsebundles unterscheiden wir zwei Sorten:

- **Mount-Locks**: `…sparsebundle/lock`, `…sparsebundle/Info.plist`,
  `…sparsebundle/bands` (das Verzeichnis ohne Subpfad), `…sparsebundle/token`.
  Diese hält der Mac persistent solange das Bundle gemountet ist — egal ob
  gerade geschrieben wird. Nicht aussagekräftig.
- **Schreib-Locks**: `…sparsebundle/bands/<hex>` und
  `…sparsebundle/mapped/<hex>` mit numerischer ID. Diese sehen wir nur während
  aktiver Schreibvorgänge — und macOS hält sie danach noch eine Weile (Minuten
  bis Stunden) im OpLock-Cache.

Wir filtern auf Schreib-Locks, berechnen einen `cksum`-Hash der sortierten
Pfad-Liste, warten `SMB_POLL_INTERVAL` Sekunden, berechnen den Hash erneut.
**Gleicher Hash = keine echte Aktivität** (Cache-Zustand unverändert).
**Anderer Hash = TM schreibt gerade Bänder** (neue Bänder hinzu, alte weg).

Diese Heuristik fängt **nicht** den Fall, dass macOS in dieselben Bands neue
Bytes schreibt ohne neue Locks zu öffnen — den fängt der Btrfs-Snapshot von
Hyper Backup ab (Filesystem-konsistent zum Snapshot-Zeitpunkt).

## Warum die Wartephase nicht blockiert

Bei einem Timeout (TM scheinbar dauer-aktiv, typisch wenn macOS Power Nap auf
einem ständig angeschlossenen Mac läuft) **läuft das Backup trotzdem**. Das
ist beabsichtigt:

- Hyper Backup macht für Btrfs-Quellen automatisch einen **atomaren Snapshot**
  vor dem Backup. Mid-write-Snapshots sind crash-konsistent.
- TM-Sparsebundles sind seit 2007 explizit gegen genau diesen Zustand designt
  (CoW-Bands, atomare Token-Writes).

Wer das nicht akzeptieren will, kann `SMB_POLL_TIMEOUT_SEC` auf einen sehr
hohen Wert setzen — dann wartet das Skript praktisch unendlich, mit dem
Risiko dass Backups bei Power-Nap-Macs nie laufen.

## Mehrere Macs / Freigaben

Pro TM-Freigabe eine eigene Skript-Kopie in einem eigenen
Aufgabenplaner-Task. Die Skript-Datei selbst kann identisch bleiben — anpasst
werden nur `TM_SHARE`, `TASK_ID`, `TASK_NAME` (oder per ENV-Variable
überschrieben).

## Dokumentation des Designprozesses

Im Ordner [`tasks/tm-safe-hyperbackup/`](tasks/tm-safe-hyperbackup/) liegen
zwei Markdown-Dateien, die den Designprozess festhalten:

- [`research.md`](tasks/tm-safe-hyperbackup/research.md) — Recherche zu DSM,
  Samba und Hyper Backup, drei Beobachtungsnächte mit Live-Monitor,
  Stuck-Lease-Befund, zwei Iterationen Strategie-Debatten.
- [`plan.md`](tasks/tm-safe-hyperbackup/plan.md) — konkreter Skript-Plan mit
  Code-Schnipseln, Exit-Code-Tabelle und Todo-Liste.

Beide Dateien sind ehrliche Lern-Artefakte, kein Whitepaper. Wer ähnliche
Probleme mit TM-auf-Synology hat, findet dort vermutlich Hilfreiches.

Der zugrundeliegende Arbeitsstil ist in [`CLAUDE.md`](CLAUDE.md) beschrieben
(Boris-Tane-inspirierter „Recherche → Plan → Umsetzung"-Workflow mit Claude
Code).

## Lizenz

[MIT](LICENSE). Nutzung auf eigene Gefahr — siehe auch den Hinweis im
Skript-Header: **dieses Skript fasst zwar nichts Destruktives an, triggert
aber `synobackup` und vertraut auf die Crash-Konsistenz von Btrfs-Snapshots
und TM-Sparsebundles.** Verifiziere deine Backups regelmäßig.
