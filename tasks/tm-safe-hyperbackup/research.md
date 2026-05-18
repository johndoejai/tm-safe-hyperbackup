# research.md — tm-safe-hyperbackup

## Aufgabenstellung (zur Erinnerung)
Ein Skript fuer den DSM-Aufgabenplaner (laeuft als root, auf dem NAS, per Copy-
Paste eingefuegt), das **vor** dem Start eines Hyper-Backup-Tasks auf eine
Time-Machine-Freigabe (z. B. `TM_host_a` unter `/volume2/TM_host_a`) sicherstellt,
dass das `.sparsebundle` darin gerade geschlossen ist. Erst dann wird Hyper
Backup ausgeloest. Mit aussagekraeftigen Exit-Codes (offen / geschlossen /
Fehler). Konfiguration inline, kein externes Logfile (DSM sammelt Stdout/Stderr).
KISS, wenig Abhaengigkeiten, wartungsarm.

## Was wir wissen

### NAS-Umgebung (eigene Recherche per SSH)
- DSM 7.3, Samba 4.x.
- `smbstatus`-Binary unter `/usr/local/bin/smbstatus`, nicht in `$PATH` fuer
  Standard-User. Im Aufgabenplaner laeuft das Skript als root, dort ist es per
  vollem Pfad sicher aufrufbar.
- TM-Share `TM_host_a` liegt unter `/volume2/TM_host_a`.
- Bei aktivem TM-Mount sind im Sparsebundle persistent geoeffnet:
  - `…/lock` (mit `DENY_ALL`)
  - `Info.plist`
  - `token`
  - zusaetzlich die aktuell beschriebenen Band-Dateien.
- `smbstatus -L` in Spalte 7 (SharePath) zeigt absolute Pfade
  (`/volume2/TM_host_a`), nicht den Share-Namen. Filter daher
  `awk '$7 ~ "/" TM_SHARE "$" { ... }'`.

### Lokales Beispielskript als Stil-Referenz (`inbox/2025_07_29_myapp_hyper_backup_w_update.sh`)
Was wir daraus uebernehmen koennen:
- Skript wird im DSM-Aufgabenplaner inline geklebt, Output via `echo`.
- Header mit Changelog-Block.
- `set -eu` / `set -euo pipefail` als scharfer Modus oben (wir bewerten unten,
  wie scharf wir das setzen).
- Hyper Backup wird per `synobackup --backup <id> --type image` ausgeloest;
  die Fertig-Erkennung erfolgt ueber **Tail auf das HyperBackup-Logfile**, weil
  `synobackup` selbst sofort zurueckkehrt.

Was wir nicht uebernehmen:
- `set -x` (Trace-Modus) — macht den Aufgabenplaner-Output unleserlich, fuer
  ein wartungsarmes Skript nicht ideal.
- Unquotete Variablen.
- `function`-Keyword (nicht POSIX-portabel, aber funktioniert in bash).

### Nachtrag: gezielte Recherche in der deutschen Synology-KB (kb.synology.com/de-de)
Per Browser-Session am 17. Mai 2026 wurden die fuenf zuvor identifizierten Begriffe
in der offiziellen KB durchsucht. Wichtige *Nicht-Befunde* — also Sachen, die wir
**nicht** in der KB gefunden haben, was selbst aussagekraeftig ist:

- **Suche `synobackup`**: **0 Treffer.** Der Befehl, der die Hyper-Backup-Tasks
  triggert (in allen Community-Skripten genutzt), ist in der offiziellen KB
  **nicht dokumentiert**. Er bleibt also ein inoffizielles, internes Tool — wir
  duerfen es verwenden, muessen aber damit rechnen, dass Synology Verhalten oder
  Flags ohne Vorwarnung aendert.
- **Suche `SMB-Dienst beenden`**: 340 Treffer, aber kein Artikel beschreibt einen
  offiziellen CLI-Befehl zum Stoppen des SMB-Dienstes. Es gibt nur GUI-Workflows
  (`Systemsteuerung → Dateidienste → SMB`) und das Resource-Monitor-"Verbindung
  beenden". `synosystemctl`, `synoservice` etc. **tauchen in der DE-KB nicht
  auf**. Die KB-Aussage "Bestimmte Anwendungen versuchen, die Verbindung
  automatisch wiederherzustellen" (Artikel: SMB-Verbindung beenden hilft nicht)
  bestaetigt: granulares Trennen einer einzelnen SMB-Session ist generell nicht
  zuverlaessig.
- **Suche `Time Machine Hyper Backup`**: 2298 Treffer, aber **kein einziger
  Artikel beschreibt unseren Anwendungsfall** (TM-Sparsebundle vor Hyper Backup
  absichern). Synologys eigene Anleitungen behandeln Time Machine **nur als
  Backup-Ziel** vom Mac, nicht als Quelle, die selbst gesichert wird. Unser
  Anwendungsfall ist also eine eigene Konstruktion ohne Hersteller-Empfehlung.

Und die ueberraschende Korrektur:

- **Im offiziellen Tutorial-Artikel "Wie sichere ich meine Daten in einem lokalen
  freigegebenen Ordner ... mit Hyper Backup" (DE-KB, 24. Dez. 2024,
  [Link][kb_hb_local]) ist KEINE "konsistente Sicherung"- oder "Snapshot vor
  Backup"-Option fuer freigegebene Ordner aufgefuehrt.** Die einzige
  Konsistenz-bezogene Option ist die **Integritaetspruefung** — und die prueft
  **nachtraeglich** die `.hbk`-Datei auf Beschaedigung. Das ist nicht das, was
  wir wollten.
- Damit faellt **Strategie D** in der oben formulierten Form **weg**: Hyper
  Backup uebernimmt fuer freigegebene Ordner keinen Snapshot-Schritt von sich
  aus. Die "Dateisystem-konsistente Sicherung", die in Whitepapers auftaucht,
  ist offenbar ein **VM-Manager- bzw. LUN-Begriff** (vgl. KB-Artikel "Was ist
  der Unterschied zwischen crash-konsistenten und dateisystemkonsistenten
  OVA-Dateien?"), nicht eine Option fuer SMB-Ordner.

[kb_hb_local]: https://kb.synology.com/de-de/DSM/tutorial/How_to_back_up_your_data_to_local_shared_folders_or_USB_with_Hyper_Backup

**Konsequenz:** Wir koennen nicht auf eine Hersteller-Garantie zaehlen. Konsistenz
des Sparsebundles muss vom Skript selbst hergestellt werden — also Strategie A,
B oder C. Falls wir trotzdem Snapshots als Konsistenzhebel haben wollen, muessten
wir das parallele Paket "Snapshot Replication" auf TM_host_a aktivieren und unser
Skript laesst Hyper Backup aus einem dieser Snapshots lesen — das ist eine
**neue Strategie E**, die wir unten ergaenzt haben.

### Nachtrag 2 (Korrektur): Hyper Backup MACHT einen Snapshot — fuer Btrfs-Quellen, automatisch
Nach der Anmerkung des Nutzers ("Ich bin mir ziemlich sicher, dass Hyperbackup
einen Snapshot macht — habe das in Logs gesehen") gezielt nachrecherchiert. Der
**offizielle Hyper-Backup-Hilfeartikel** in DSM ([Backup Tasks | Hyper Backup,
en-global, version=7][hb_help]) enthaelt im Abschnitt "Manage a suspended backup
task" diesen Satz wortwoertlich:

> "If the source of a backup task is stored in the Btrfs file system, the
> snapshot created by the task will not be retained after the task gets
> suspended. A new snapshot will be used when the task is resumed."

Eine KB-Suche nach genau diesem Zeichenkette liefert genau **einen** Treffer
(eben den Help-Artikel) — sonst nichts in der KB. Das ist also die einzige
offizielle Stelle, aber sie ist eindeutig.

[hb_help]: https://kb.synology.com/en-global/DSM/help/HyperBackup/data_backup_create?version=7

**Was das heisst:**
- Hyper Backup legt **fuer jeden Backup-Task automatisch einen Btrfs-Snapshot der
  Quelle an**, wenn die Quelle auf einem Btrfs-Volume liegt.
- Es ist **kein UI-Schalter** noetig — passiert von selbst, weshalb der
  Tutorial-Artikel (UI-Setup) ihn nicht erwaehnt.
- Hyper Backup liest danach **aus diesem Snapshot**, nicht aus dem Live-Share.
  Damit kann der Mac waehrend des Backups weiterhin in das Sparsebundle
  schreiben — das Backup selbst sieht den eingefrorenen Zustand.
- TM_host_a liegt laut Anmerkung auf einem **Btrfs-Volume** — Voraussetzung erfuellt.

**Mein Fehler vorher:** Ich hatte nur den Tutorial-Artikel ("Wie sichere ich
meine Daten in einem lokalen freigegebenen Ordner …") angeschaut und daraus
geschlossen, dass die Snapshot-Option nicht existiert. Stattdessen passiert sie
automatisch und steht nur in der Hilfe-Referenz fuer das Paket, nicht im
Setup-Tutorial. Strategie D wird damit **rehabilitiert** und neu formuliert
weiter unten.

**Offene Detailfragen** zur Konsistenz-Garantie, die der Hilfe-Artikel NICHT
beantwortet:
- Welcher Konsistenz-Level — Crash, Dateisystem, App? (Synology schweigt dazu in
  diesem Artikel; aus Btrfs-Snapshot-Mechanik folgt: mindestens
  Dateisystem-konsistent zum Zeitpunkt der Snapshot-Erstellung.)
- Was passiert bei aktivem TM-Schreibvorgang im Snapshot-Moment? (Sparsebundle
  ist gegen genau diese Art Zustand robust designt, weil das Wear-Leveling der
  Baender CoW-aehnlich ist, aber keine 100%-Garantie aus offizieller Quelle.)
- Sind die Snapshots irgendwo sichtbar/auffindbar (z. B. unter
  `/volume2/@HyperBackup/...`)? — unklar.

---
Anmerkung: Ich bin mir ziemlich sicher, dass Hyperbackup einen Snapshot macht. Zum einen habe ich das bereits in Logs gesehen (müsste ich wieder suchen), zum anderen gibt es dieses Whitepaper https://global.download.synology.com/download/Document/Software/WhitePaper/Firmware/DSM/All/enu/Synology_Data_Protection_White_Paper.pdf. Die TM-Freigaben liegen auf BTRFS-Volumen.
---
### Web-Recherche: was DSM offiziell / etabliert bietet (Stand vor KB-Nachtrag)

**1. SMB-Aktivitaet auf einer Freigabe erkennen.** `smbstatus` (Samba-Bordmittel)
bleibt der saubere Weg. Es gibt **keine** offizielle DSM-API oder ein
Synology-CLI, das einen "Share in Benutzung"-Status liefert:
- File Station API (offiziell, [Guide][fs]): liefert Datei- und Verzeichnis-
  Metadaten, aber keinen Lock-/In-use-Status.
- `synoshare --enum/--get` (in offiziellem [CLI Guide][cli]): listet Freigaben,
  liefert aber **keine Aktivitaet**.
- `lsof`: nicht im DSM-Basisbild; ueber Entware nachinstallierbar — verstoesst
  gegen KISS, fliegt raus.
- DSM-GUI "Verbundene Benutzer" im Resource Monitor zieht dieselben Daten wie
  `smbstatus` ([KB][rm], offiziell).

**2. SMB-Dienst kontrolliert pausieren/stoppen.** Unter DSM 7+ ist
`synosystemctl` der gaengige Befehl. Dokumentation dazu ist primaer Community
([dannyda.com][danny], [darknebular Cheatsheet][darkn]):
- `synosystemctl stop pkg-synosamba-smbd.service`
- `synosystemctl start pkg-synosamba-smbd.service`
- `synosystemctl status pkg-synosamba-smbd.service`

Granulares Trennen einer **einzelnen** Freigabe (statt des gesamten SMB-Dienstes)
ist offenbar nicht vorgesehen. Das heisst: SMB-Stop kickt **alle** SMB-Clients,
nicht nur den TM-Client.

**3. Hyper Backup triggern und auf Ende warten.**
- Befehl: `/usr/syno/bin/synobackup --backup <task_id> --type image`.
  Durchgehend Community-belegt ([albal/synobackup][alb], [Jip-Hop Gist][jip]),
  im offiziellen CLI Guide **nicht** in dieser Semantik dokumentiert.
- Task-ID-Quelle: `/usr/syno/etc/synobackup.conf` (oft Symlink/Spiegel von
  `/var/packages/HyperBackup/etc/synobackup.conf`).
- Log-Quelle: `/var/log/synolog/synobackup.log`. (In `inbox/`-Skript stand
  `/var/packages/HyperBackup/var/log/synolog/synobackup.log` — beides kursiert;
  vor dem Loslegen pruefen wir, welcher Pfad bei dir Daten enthaelt.)
- **Wichtig:** `synobackup --backup` kehrt **sofort** zurueck, der eigentliche
  Backup-Lauf erfolgt im Hintergrund. Es gibt **keinen verlaesslichen Exit-Code**
  fuer Erfolg/Fehler.
- Fortschritt erkennen via:
  - Log-Tail (so macht es das `inbox/`-Skript), oder
  - Prozesspolling: `pidof -s -x /var/packages/HyperBackup/target/bin/img_backup`.
- Ein offizielles `--is-running` oder Aehnliches: **unklar**, kein Beleg gefunden.

**4. Btrfs-Snapshot als Konsistenzgarantie.** Wenn `/volume2` ein Btrfs-Volume
ist, kann Hyper Backup beim Anlegen/Bearbeiten eines Tasks die Option
**"Dateisystem-konsistente Sicherung aktivieren"** ([Synology Data Protection
White Paper][dp], offiziell; ergaenzend Community: [iFeeltech][ift],
[blackvoid][bv]) gesetzt bekommen. Wirkung:
- Hyper Backup macht **vor jedem Backup** einen Btrfs-Snapshot der Quelle und
  liest aus dem Snapshot. Das Backup ist damit **innerhalb des Snapshots
  konsistent** — egal was der Mac waehrenddessen schreibt.
- **Caveat:** Das ist *Crash-Konsistenz*, nicht *App-Konsistenz*. Der Snapshot
  friert den Zustand atomar ein, aber moeglicherweise mitten in einem
  Sparsebundle-Schreibvorgang. Time Machine ist gegen so was ueblicherweise
  robust (CoW in den Baendern), aber **eine 100%-Garantie eines "sauber
  geschlossenen" Bundles ist das nicht**.
- Voraussetzungen: Quelle muss **Btrfs** sein; bei verschluesselten Volumes
  teilweise Einschraenkungen (laut KB **unklar**, ob es die Hyper-Backup-Option
  betrifft).

[fs]: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Package/FileStation/All/enu/Synology_File_Station_API_Guide.pdf
[cli]: https://global.download.synology.com/download/Document/Software/DeveloperGuide/Firmware/DSM/All/enu/Synology_DiskStation_Administration_CLI_Guide.pdf
[rm]: https://kb.synology.com/en-global/DSM/help/DSM/ResourceMonitor/rsrcmonitor_connected_users
[danny]: https://dannyda.com/2022/11/09/how-to-use-command-manually-restart-start-stop-services-in-synology-dsm-7-and-newer-versions/
[darkn]: https://github.com/darknebular/Synology_Commands
[alb]: https://github.com/albal/synobackup
[jip]: https://gist.github.com/Jip-Hop/b9ddb2cc124302a5558659e1298c36ec
[dp]: https://global.download.synology.com/download/Document/Software/WhitePaper/Firmware/DSM/All/enu/Synology_Data_Protection_White_Paper.pdf
[ift]: https://ifeeltech.com/blog/synology-snapshots-explained
[bv]: https://www.blackvoid.club/synology-backup-tools-usage-and-comparison/

## Strategie-Optionen (zur Entscheidung)

### A — Sanft: Vorab-Check, sonst nichts
1. `smbstatus -L` ausfuehren.
2. Wenn offen: Skript loggt das, Exit mit Code 10 (Share offen). Hyper Backup
   wird heute nicht gestartet.
3. Wenn zu: Hyper Backup starten, auf Ende warten, Status loggen.

- **Sicherheit:** maximal — nichts wird angefasst, was offen ist.
- **Komplexitaet:** minimal — eine Pruefung, ein Trigger, ein Wait-Loop.
- **Risiko:** Wenn der Mac dauerhaft eingeschaltet ist und TM regelmaessig
  schreibt, **kann das Backup beliebig oft uebersprungen werden**.

### B — Geduldig: kurz polling-warten
1. `smbstatus -L` ausfuehren.
2. Wenn offen: bis zu N Minuten (z. B. 30) im Minutentakt warten, bis kein
   Sparsebundle-Lock mehr da ist.
3. Wenn ruhig: Hyper Backup wie in A.
4. Wenn Timeout: Skript loggt, Exit 10.

- **Sicherheit:** wie A — fasst nichts an.
- **Komplexitaet:** etwas hoeher (Schleife, Timeout, Logging).
- **Risiko:** wie A, mit verschobenem Backup-Fenster.

### C — Robust: SMB stoppen, Backup, SMB an
1. SMB-Dienst stoppen (`synosystemctl stop pkg-synosamba-smbd.service`).
2. Kurz warten (z. B. 10 s) bis Locks weg sind.
3. Hyper Backup starten, auf Ende warten.
4. SMB-Dienst wieder starten.

- **Sicherheit:** Bundle wird **erzwungen geschlossen** — aber unsauber
  (vergleichbar mit Kabel ziehen). TM muss beim naechsten Mount evtl. eine
  Wiederherstellung machen. Sparsebundle-Crash-Recovery ist robust, aber **kein
  Null-Risiko**.
- **Komplexitaet:** mittel — drei Befehle, aber Fehlerpfade muessen sauber
  sein (z. B. SMB wieder anschalten, auch wenn Backup fehlschlaegt — `trap`).
- **Risiko:** SMB-Stop trifft **alle** Clients, nicht nur TM. Wenn andere
  Geraete gerade SMB nutzen, werden sie getrennt.

### D — Hyper Backup macht den Snapshot selbst (rehabilitiert nach Nachtrag 2)
Hyper Backup legt fuer jeden Backup-Task auf Btrfs-Quellen automatisch einen
Snapshot an und liest daraus (siehe Nachtrag 2 oben mit Quelle). Damit wird das
Skript zum reinen Trigger:

1. `synobackup --backup <task_id> --type image` starten.
2. Auf Ende warten (Log-Tail oder Prozesspolling), Status ins Stdout-Log
   ausgeben.

- **Sicherheit:** Btrfs-Snapshot ist atomar konsistent zum Snapshot-Zeitpunkt
  (mindestens Dateisystem-Level). Sparsebundle wird in dem Zustand eingefroren,
  in dem es im Snapshot-Moment war. TM ist gegen Crash-Konsistenz robust;
  Synology garantiert dies aber **nicht explizit** fuer TM.
- **Komplexitaet:** minimal — kein SMB-Check, keine Wartelogik, kein
  Dienst-Stoppen.
- **Risiko:** Wenn TM mitten in einer Multi-Band-Schreibsequenz ist, friert der
  Snapshot moeglicherweise einen Halb-fertig-Zustand ein. Bisher in der Praxis
  unauffaellig, aber keine Hersteller-Garantie.
- **Voraussetzung:** Quell-Volume ist Btrfs (laut Anmerkung im Nachtrag 2:
  erfuellt fuer TM_host_a auf `/volume2`).

### A+D — Hybrid: Sanfter Check zusaetzlich zum automatischen Snapshot
Belt-and-suspenders-Variante. Hyper Backup macht eh seinen Snapshot, aber als
zusaetzliche Sicherheitsebene wird vorher geprueft, ob der TM-Client gerade
schreibt; falls ja, wird ein Hinweis geloggt (oder das Backup verschoben).

1. `smbstatus -L` ausfuehren — nur zur Diagnose.
2. Wenn TM_host_a offen ist: deutlich loggen (z. B. "WARNUNG: TM_host_a gerade in
   Benutzung — Snapshot wird einen Schreibmoment einfrieren"). Optional: Backup
   abbrechen (Exit 10), je nach Wunsch.
3. Hyper Backup starten, auf Ende warten.

- **Sicherheit:** Identisch zu D plus Logging.
- **Komplexitaet:** etwa wie A (mit Skip-Pfad) bzw. wie D (ohne Skip).
- **Risiko:** Wie D — Snapshot-Mechanik bleibt das, was sie ist; der Vorab-Check
  ist nur Diagnose, keine echte Konsistenzverbesserung.

### E — Snapshot Replication vorschalten
Snapshot Replication (separates DSM-Paket) macht periodisch Btrfs-Snapshots des
TM-Shares. Hyper Backup liest dann **aus dem juengsten Snapshot**, nicht aus dem
Live-Share.

1. Snapshot Replication ist auf TM_host_a aktiviert, macht z. B. stuendlich einen
   Snapshot. (Einmal-Setup, ausserhalb des Skripts.)
2. Skript fragt vor dem Backup ggf. einen frischen Snapshot an (`synosnap` o. a.
   — Befehl in dieser Recherche noch nicht bestaetigt).
3. Hyper-Backup-Task ist so konfiguriert, dass er aus dem Snapshot-Pfad liest.
4. Backup starten, warten, fertig.

- **Sicherheit:** Block-/Dateisystem-atomar konsistent zum Snapshot-Zeitpunkt
  (Crash-Konsistenz). Mac kann waehrenddessen weiterschreiben — irrelevant fuer
  das Backup, da aus dem Snapshot gelesen wird.
- **Komplexitaet:** mittel-hoch — Einmal-Setup ist gross (zusaetzliches Paket,
  Snapshot-Pfade, Hyper-Backup-Task umkonfigurieren), das Skript selbst wird
  einfach.
- **Risiko:** Sparsebundle ist auch im Snapshot nur crash-konsistent, nicht
  sauber geschlossen. Plattenplatz fuer Snapshots.

  ---
  Anmerkung: Snapshot-Replication ist bereits für die Freigabe aktiviert. Verbraucht viel Platz. Und auchbhier ist das Hauptproblem: Wie sorgt man dafür, dass der Snapshot gemacht wird, wenn Sparsebundle geschlossen und konsistent?
  ---

## Strategie-Entscheidung
**Gewaehlt: B (mit D als Nebeneffekt)** (17. Mai 2026).

Ablauf:
1. `smbstatus -L` pruefen.
2. Wenn die TM-Freigabe offen ist: alle **30 Sekunden** erneut pruefen, bis zu
   **30 Minuten** lang. (= max 60 Iterationen)
3. Sobald Bundle zu ist: Hyper Backup ausloesen (`synobackup --backup <id>`).
   Hyper Backup legt dabei *zusaetzlich* automatisch einen Btrfs-Snapshot der
   Quelle an (siehe Nachtrag 2) — das ist kostenlose Zusatzsicherung, aber
   nicht Teil unserer Strategie-Logik.
4. Wenn nach 30 Minuten immer noch offen: Backup **abbrechen** mit Exit-Code
   und Warnung im Log. Kein Backup heute.

Rationale: B sorgt aktiv dafuer, dass HyperBackups Snapshot in einem bekannt
sauberen Zustand gemacht wird. Beim Timeout wird bewusst nicht gezwungen — lieber
kein Backup als ein Snapshot ueber einen Multi-Band-Write.

## Offene Punkte vor dem Plan
1. ~~Welche Strategie~~ → entschieden, siehe oben.
Anmerkung: Wir müssen hier noch einmal iterieren, wenn die Snapshot-Strategie klar ist. Grundsätzlich tendiere ich zu B.

3. **Volume-Typ pruefen:** ist `/volume2` Btrfs? (`btrfs subvolume show /volume2`
   oder DSM-Speicher-Manager). Wenn ja, Option D ueberhaupt moeglich.
Anmerkung: Volueme ist Btrfs.

5. **Hyper-Backup-Task-ID** fuer `TM_host_a`: gibt es schon einen, oder muss er
   noch angelegt werden? Falls ja, ID auslesen aus
   `/usr/syno/etc/synobackup.conf` bzw. `synobackup --list`.
Anmerkungen: Es gibt schon einen Task. ID können wir später besorgen. Es gibt mehrere TM-Freigaben und jeweils dafür separate bereits angelegte HyperBackup-Tasks. 

6. **Log-Pfad pruefen:** `/var/log/synolog/synobackup.log` vs.
   `/var/packages/HyperBackup/var/log/synolog/synobackup.log` — welcher hat
   bei dir aktuellen Inhalt?
Anmerkung: Nimm das aus meinem Skript aus der inbox. Das funktioniert bisher.

7. **Trockenlauf:** in Phase eins (vor Implementierung der "scharfen" Aktion)
   wollen wir das Skript wahrscheinlich erst im **Dry-Run-Modus** testen —
   d. h. es macht den Vorab-Check, loggt was es taete, **startet aber kein
   Hyper Backup**. Schalter `DRY_RUN=1`.

## Zusammenfassung der Entscheidungen (Stand 17. Mai 2026, vor plan.md)
- Strategie: **B (mit D als Nebeneffekt)**, Polling 30s, Timeout 30min,
  Timeout-Verhalten: Abbruch mit Exit-Code.
- Volume-Typ: TM-Freigaben liegen auf Btrfs (laut Nutzer).
- Architektur: **ein Skript pro TM-Freigabe**. Bei mehreren Freigaben N
  Aufgabenplaner-Eintraege mit jeweils eigener Kopie. KISS-konform.
- Task-ID: pro Skript inline als Variable; konkrete Werte besorgen wir spaeter
  per `synobackup --list` bzw. aus `/usr/syno/etc/synobackup.conf`.
- Log-Pfad: `/var/packages/HyperBackup/var/log/synolog/synobackup.log` (laut
  Nutzer-Anmerkung; funktioniert im inbox-Skript bereits).
- DRY_RUN-Schalter als Variable oben im Skript.

## Naechste Schritte
- Plan wird in `plan.md` ausgearbeitet (Skriptstruktur, Code-Schnipsel,
  Todo-Liste, Test-Plan).
- Annotations-Zyklus auf plan.md vor der Implementierung.
