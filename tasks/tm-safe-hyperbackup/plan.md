# plan.md — tm-safe-hyperbackup

## Aufgabe in einem Satz
Ein einzelnes, im DSM-Aufgabenplaner einsetzbares Skript, das pro TM-Freigabe
prueft ob das Sparsebundle gerade in Benutzung ist, geduldig wartet bis es zu
ist, und dann den zugehoerigen Hyper-Backup-Task ausloest.

## Ergebnis
Eine Datei `tm-safe-hyperbackup.sh` im Repo-Root, ca. 100–150 Zeilen,
POSIX-sh-kompatibel, mit allen Konfigurationswerten oben als Variablen. Per
Copy-Paste in einen DSM-Aufgabenplaner-Task einsetzbar. Pro TM-Freigabe eine
eigene Kopie mit angepassten Werten.

## Konventionen aus CLAUDE.md, die wir einhalten
- Bash bzw. POSIX-sh, kompatibel zur DSM-Umgebung.
- Konfiguration inline; keine Zugangsdaten; keine externe Logdatei (DSM
  Aufgabenplaner sammelt Stdout/Stderr).
- Robuste Fehlerbehandlung; sprechendes Logging.
- KISS, wartungsarm.
- **Einfach verstaendlich + ausreichend kommentiert.** Jede Funktion bekommt
  einen kurzen Kommentarblock dariber (Zweck, Rueckgabe, ggf. Nebeneffekt).
  Im Hauptablauf wird vor jedem Phasenwechsel eine Kommentarzeile gesetzt,
  die in einem Satz erklaert, was als Naechstes passiert. Keine "schlauen"
  One-Liner; lieber drei lesbare Zeilen.

## Skript-Aufbau

### 1. Kopfblock
- Shebang: `#!/bin/sh` (DSM-Aufgabenplaner-konform).
- Header-Kommentar mit Beschreibung, Autor, **Changelog-Block** (Format:
  Datum + Aenderung).
- Hinweis im Header, dass pro TM-Freigabe eine eigene Kopie genommen wird, und
  die markierten Variablen unten anzupassen sind.

### 2. Shell-Optionen
- `set -eu` — bei nicht-deklarierten Variablen und unbehandelten Fehlern
  abbrechen. (Kein `-x` Trace-Modus; kein `pipefail`, weil POSIX-sh es nicht
  garantiert hat.)
- Begruendung kurz als Kommentar: "kein -x: Aufgabenplaner-Log soll lesbar
  bleiben".

### 3. Konfigurationsblock (oben, klar markiert)
```sh
# ====== Anpassen pro TM-Freigabe ======
# Beispiel: TM_host_a  -> TASK_ID=4, TASK_NAME="SynoC2-TM_host_a"
# Beispiel: TM_host_b -> TASK_ID=1, TASK_NAME="SynoC2-TM_host_b"
TM_SHARE="TM_host_a"                    # Name der TM-Freigabe (wie in DSM)
TASK_ID="4"                           # Hyper-Backup-Task-ID (aus synobackup.conf)
TASK_NAME="SynoC2-TM_host_a"            # Hyper-Backup-Task-Name (zum Log-Filtern)
DRY_RUN=0                             # 1 = nichts ausloesen, nur protokollieren
DEBUG=0                               # 1 = rohe smbstatus-Auszuege ins Log (fuer Diagnose ohne Coder-Hilfe)
# ====== Selten anzupassen ======
SMB_POLL_INTERVAL=60                  # Sekunden zwischen den zwei smbstatus-Samples einer is_share_writing-Pruefung
SMB_POLL_TIMEOUT_SEC=1800             # max. Wartezeit auf TM-Ruhe (1800 s = 30 min); bei Timeout: Fallthrough mit Warn-Log
HB_POLL_INTERVAL=30                   # Sekunden zwischen HB-Log-Checks
HB_POLL_TIMEOUT_SEC=21600             # max. Wartezeit auf Backup-Ende (21600 s = 6 h)
VOLUME_PATH="/volume2"                # Volume mit TM_SHARE (fuer Btrfs-Check); anpassen falls nicht /volume2
# Volle Bin-Pfade als Default, PATH-unabhaengig:
SMBSTATUS_BIN="/usr/local/bin/smbstatus"
SYNOBACKUP_BIN="/usr/syno/bin/synobackup"
JQ_BIN="/usr/bin/jq"
HB_LOG="/var/packages/HyperBackup/var/log/synolog/synobackup.log"
```

Anmerkung zu den Timeouts: Wir warten **nur auf "Backup task finished
successfully."**, NICHT auf die Versions-Rotation, die im Anschluss laeuft.
Beispiel TM_host_a am 17. Mai 2026: Backup 01:07 → 03:30 (knapp 2,5 h),
Rotation 03:30 → 11:43 (gut 8 h). Sechs Stunden Backup-Timeout sind also
grosszuegig fuer den Backup-Teil, ohne dass wir in die Rotation hineinwarten.

Begruendung der Trennung: was du pro Freigabe anpasst (oben) vs. was systemweit
gleich ist (unten). Vermeidet versehentliche Aenderungen an System-Pfaden.

### 4. Hilfsfunktion: zeitgestempeltes Loggen
```sh
log() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
}
```
Alle Statusmeldungen gehen ueber `log`. Das macht das Aufgabenplaner-Log
zeilenweise filterbar (`grep` per Datum/Stichwort).

### 5. Hilfsfunktion: aktiven Schreibvorgang erkennen
**Strategiewechsel nach Stuck-Lease-Befund (siehe research.md Nachtrag 3):**
Statt "irgendein Lock = offen" pruefen wir, ob sich die Lock-Liste zwischen
zwei Samples **veraendert** hat. macOS haelt OpLock-Leases im Cache, auch
nach Backup-Ende — eine konstante Lock-Liste heisst also "kein Schreibvorgang
in den letzten 60 s".

```sh
# Hash der Lock-Pfade fuer einen Share. Bei leerer Eingabe gibt cksum den
# konstanten Wert 4294967295 zurueck — der wird im Vergleich automatisch zu
# "ruhig".
#
# Robustheit: Wir parsen den offiziellen JSON-Output von smbstatus (--json,
# Samba 4.12+). Das Schema ist stabil — immun gegen Tabellen-Spaltendrift
# bei Samba-Updates. jq filtert auf service_path-Endpunkt (= Share) und
# auf bands/mapped-Subpfade (= Schreib-Locks).
share_lock_hash() {
    "$SMBSTATUS_BIN" -L --json 2>/dev/null \
        | "$JQ_BIN" -r --arg share "$TM_SHARE" '
            .open_files
            | to_entries[]
            | select(.value.service_path | endswith("/" + $share))
            | select(.value.filename | test("\\.sparsebundle/(bands|mapped)/"))
            | .key
          ' \
        | sort -u \
        | cksum \
        | awk '{print $1}'
}

# Prueft, ob TM gerade aktiv schreibt.
# Liefert 0 (= "schreibt") wenn sich die Lock-Liste zwischen zwei Samples
# (60 s Abstand) geaendert hat. Liefert 1 (= "ruhig") sonst.
#
# Wichtig: "ruhig" heisst hier "keine neuen/verschwundenen Locks in 60 s" —
# Stuck-Lease-Cache wird korrekt als "ruhig" erkannt. Wenn ueberhaupt keine
# Schreib-Locks da sind (Mac OFFLINE oder IDLE), ist der Hash der "leere"
# 4294967295-Wert und stimmt zwischen beiden Samples eh ueberein.
is_share_writing() {
    h1=$(share_lock_hash)
    sleep "$SMB_POLL_INTERVAL"
    h2=$(share_lock_hash)
    if [ "$h1" = "$h2" ]; then
        return 1   # ruhig
    fi
    return 0   # aktiv schreibend
}
```

**Wichtig zur Interpretation** (steht auch im Skript-Header explizit drin):

Die Hash-Heuristik ist **Best-Effort-Hoeflichkeit, kein Korruptionsschutz**.
Die eigentliche Konsistenz-Garantie kommt aus zwei Schichten:
- **Hyper Backup macht einen Btrfs-Snapshot** vor dem Backup (offiziell
  dokumentiert; automatisch bei Btrfs-Quellen).
- **Sparsebundle ist Crash-konsistent** designt (CoW-Bands, atomare Token-
  Schreibmuster). macOS Time Machine ist gegen Mid-write-Snapshots robust.

Phase A versucht nur, das Snapshot-Fenster opportunistisch in eine ruhige
Phase zu legen. Beim Timeout wird trotzdem getriggert (siehe Phase A unten).

Erklaerung fuer Anfaenger:
- `smbstatus -L` listet Datei-Locks; wir filtern auf Schreib-Locks im
  Sparsebundle (`bands/<id>` oder `mapped/<id>`).
- `cksum` macht aus der sortierten Lock-Liste einen kurzen Zahlen-Fingerabdruck.
- Zwei Samples mit 60 s Abstand: wenn der Fingerabdruck identisch ist, hat
  sich nichts geaendert -> nichts wird geschrieben -> ruhig.

### 6. Hauptablauf: Preflight + Warten + Backup ausloesen + Auf Erfolg warten

#### Phase 0 — Preflight (Voraussetzungen pruefen)
**Zweck:** lieber sofort scheitern mit klarer Meldung als 6 h spaeter still
verhungern. Wird ganz am Anfang ausgefuehrt.

`preflight()` prueft in dieser Reihenfolge:

1. **Konfigwerte gesetzt:** `TM_SHARE`, `TASK_ID`, `TASK_NAME` sind nicht
   leer (`[ -n "$TM_SHARE" ]` etc.). Sonst log Fehler, **exit 1**.
2. **Bins auffindbar:** `command -v "$SMBSTATUS_BIN" >/dev/null` und das
   gleiche fuer `SYNOBACKUP_BIN`. Sonst **exit 1**.
3. **HB-Log lesbar:** `[ -r "$HB_LOG" ]`. Sonst **exit 1**.
4. **TASK_ID ↔ TASK_NAME konsistent:** im HB-Config-File schauen, ob die
   Kombination tatsaechlich existiert:
   ```sh
   if ! grep -A2 "^\[task_${TASK_ID}\]" /var/packages/HyperBackup/etc/synobackup.conf \
        | grep -q "name=\"${TASK_NAME}\""; then
       ...
   fi
   ```
   Schlaegt fehl → log "TASK_ID/TASK_NAME passen nicht in synobackup.conf
   zusammen", **exit 1**.
5. **Volume-Typ:** `stat -f -c %T /volume2 2>/dev/null` sollte "btrfs"
   liefern. Wenn nicht: nur Warnung (kein Exit, weil Hyper Backup auch
   ohne Btrfs-Snapshot funktioniert — bloss ohne automatischen Snapshot).

Konfig-Werte und Bin-Versionen werden anschliessend einmal ins Log
geschrieben, damit man im Aufgabenplaner-Log nachvollziehen kann, was
geprueft wurde.

#### Phase A — opportunistische Suche nach ruhigem Snapshot-Fenster
**Neue Semantik (siehe research.md Nachtrag 3):** Phase A blockiert das Backup
**nicht** mehr. Sie versucht, ein ruhiges Fenster zu finden — wenn das in
30 min nicht klappt, geht das Backup trotzdem durch (Btrfs-Snapshot fangt
ab). `exit 10` ist damit obsolet und faellt aus der Exit-Code-Tabelle.

1. `log "Start"` plus Konfigwerte ins Log schreiben (zum Nachvollziehen).
2. **`elapsed=0`** explizit setzen (sonst knallt `set -u` in der Schleife).
3. Schleife: solange `is_share_writing` ODER `elapsed < SMB_POLL_TIMEOUT_SEC`:
   - Pro Iteration ruft `is_share_writing` zwei smbstatus-Samples auf
     (jeweils 60s Abstand). Iteration dauert also ~60 s Wallclock.
   - Bei "schreibt": log "TM_host_a schreibt aktiv (verstrichen: ${elapsed}s)"
   - Bei "ruhig": log "TM_host_a ruhig — bereit fuer Backup", `break`
   - `elapsed += $SMB_POLL_INTERVAL`
4. Wenn Schleife endet weil Timeout (`is_share_writing` war bis zum Ende
   "aktiv"): log
   `WARNUNG: bypass_after_timeout=1 — TM dauer-aktiv (vermutlich Power Nap
   oder grosser Backup-Lauf). Triggere trotzdem; HB-Btrfs-Snapshot fangt
   Crash-Konsistenz ab.`
   Kein Exit hier — Fallthrough zu Phase B/C.
5. Wenn Schleife endet weil ruhig: log "TM_host_a ruhig, starte Backup".

#### Phase B — DRY_RUN-Pfad
7. Wenn `DRY_RUN=1`: log "DRY_RUN — wuerde jetzt `synobackup --backup
   $TASK_ID --type image` aufrufen", **exit 0**.

#### Phase C — Backup ausloesen und auf Erfolg/Fehler warten
**Zweck:** Hyper-Backup ausloesen, dann im HB-Log auf den Fertig-Eintrag
warten. Robust gegen Logrotation und gegen "synobackup hat zwar Exit 0,
HB hat den Task aber nicht aufgenommen".

8. **Zeitstempel und Inode vor synobackup merken:**
   ```sh
   START_TS=$(date '+%Y/%m/%d %H:%M:%S')  # Format wie im HB-Log
   START_INODE=$(stat -c '%i' "$HB_LOG")
   ```
   `START_TS` dient als Datums-Anker im awk-Filter unten — wir suchen nur
   Log-Eintraege, die **nach** unserem Start gemacht wurden. `START_INODE`
   merkt sich das Logfile-Objekt; bei Logrotation wechselt der Inode und
   wir wissen es.
9. `synobackup --backup "$TASK_ID" --type image` ausfuehren. Wenn Exit
   != 0: log Fehler, **exit 11**.
10. **Sanity-Gate — auf den Started-Marker warten** (max. 5 Minuten):
    Polling-Schleife mit `HB_POLL_INTERVAL`-Takt:
    - Aktuelles Logfile holen, ggf. Rotation behandeln (siehe Schritt 12).
    - `awk -v t="$START_TS" -v n="$TASK_NAME" '$2 >= substr(t,1,10) && index($0,"["n"] Backup task started.") {found=1; exit} END{exit !found}' "$HB_LOG"`
    - Treffer → weiter zu Schritt 11.
    - Kein Treffer nach 5 Min → log "HB hat Task nicht aufgenommen",
      **exit 11**.
11. **Polling auf Fertig-Eintrag** (max. `HB_POLL_TIMEOUT_SEC`):
    - In jeder Iteration nach `[$TASK_NAME] Backup task finished
      successfully.` greifen → log Erfolg, **exit 0**.
    - Sonst nach `[$TASK_NAME].*(Failed|cancelled|error)` greifen → log
      Fehler, **exit 12**.
    - Sonst: log Statuszeile mit Laufzeit, `sleep "$HB_POLL_INTERVAL"`.
12. **Logrotation behandeln** (in jeder Iteration vor dem grep):
    ```sh
    CURRENT_INODE=$(stat -c '%i' "$HB_LOG" 2>/dev/null || echo "")
    if [ "$CURRENT_INODE" != "$START_INODE" ]; then
        log "Hinweis: HB-Logfile wurde rotiert. Suche im neuen File ab Skriptstart."
        START_INODE="$CURRENT_INODE"
        # START_TS bleibt unveraendert — wir suchen weiter nach Datum
    fi
    ```
13. Wenn Polling-Timeout: log WARNUNG (Backup laeuft moeglicherweise
    noch), **exit 13**.

Warum kein `pidof`: der Hyper-Backup-Backup-Prozess bleibt nach
"Backup task finished successfully." noch fuer die Versions-Rotation aktiv
(beim TM_host_a-Beispiel mehrere Stunden). Wir wollen aber **nur auf die
Datensicherung** warten, nicht auf die Rotation. Das Erfolgs-Logeintrag ist
das definitive Signal.

Warum Zeitstempel-Filter statt Zeilenzaehlung: bei `wc -l`/`tail -n +N` haetten
wir bei Logrotation einen stillen Failure-Modus (Backup erfolgreich, Skript
findet es nicht, exit 13). Der Datums-Filter ueberlebt eine Rotation: nach dem
Wechsel auf das neue File grept das `awk` weiter im neuen File, mit dem
gleichen `START_TS` als Untergrenze.

### 7. Exit-Codes
| Code | Bedeutung |
|------|-----------|
| 0    | Erfolg (Backup gelaufen oder DRY_RUN gemacht) |
| 1    | Konfig-/Voraussetzungs-Fehler (z. B. Variable nicht gesetzt) |
| 11   | `synobackup`-Aufruf selbst fehlgeschlagen oder Started-Marker fehlt |
| 12   | Backup ausgefuehrt, aber Log zeigt Fehler/Abbruch |
| 13   | Backup-Ende nicht im Zeitfenster gefunden (HB_POLL_TIMEOUT_SEC) |

**Exit-Code 10 wurde entfernt** (war "TM-Timeout"-Abbruch). Phase-A-Timeout
fuehrt jetzt zu Fallthrough mit Warn-Log; das Backup wird trotzdem getriggert.
**Exit-Code 2 wurde entfernt** (war "smbstatus-Fehler"). Im Hash-Heuristik-
Modus geben smbstatus-Fehler einen leeren Hash zurueck, was als "ruhig"
interpretiert wird — Backup laeuft trotzdem; alternativ schlaegt schon
Preflight an `command -v smbstatus` an.

DSM-Aufgabenplaner zeigt den Exit-Code in seinem Statuslog. So kannst du auch
ohne Logtext erkennen, welcher Fall vorlag.

## Heikle Details, die wir in der Implementierung beachten

1. **Quoting:** alle Variablenexpansionen mit doppelten Anfuehrungszeichen
   ("$TM_SHARE", "$TASK_ID"). Inbox-Skript war hier nachlaessig — wir machen es
   sauber.
2. **Kein `function`-Keyword:** POSIX-Stil `name() { … }`.
3. **`grep -E`-Pattern (Heuristik "aktiv schreibend"):**
   `/${TM_SHARE}[[:space:]]+[^[:space:]]*/(bands|mapped)/`. Nicht jeder Lock
   bedeutet "in Benutzung" — macOS-TM haelt persistente Mount-Locks
   (`lock`, `Info.plist`, `bands`-Directory) auch zwischen den Backup-Laeufen.
   Diese sind unkritisch (Bundle ist konsistent). Aktive Writes erkennt man
   an Subpfaden `bands/<hex>` bzw. `mapped/<hex>` — nur diese matchen wir.
   Folge: Phase A wartet nur wenn TM **tatsaechlich gerade schreibt**, nicht
   bei einfach nur gemountetem Bundle. Drei "darf-laufen"-Zustaende: Mac aus,
   Mac schlafend (Bundle unmounted oder idle), Mac wach aber TM idle.
   (Frueher zwei Iterationen: `$7 ~ "/" share "$"` war richtig aber fragil;
   `/${TM_SHARE}/` war komplett falsch (SharePath endet ohne Slash);
   `/${TM_SHARE}[[:space:]]` war zu strikt (jeder Lock zaehlte).)
4. **Polling-Granularitaet:** in der HB-Wartephase pollen wir im selben Takt
   wie in der SMB-Wartephase (30 s). Schont CPU.
5. **Race in Schritt 6–9:** falls Mac in den ~1 s zwischen "share zu" und
   `synobackup` wieder oeffnet, ist das ein Pech-Fall, kein Bug. HyperBackups
   Snapshot faengt ihn ab (siehe research.md Nachtrag 2).
6. **Trap:** keine Aufraeumarbeiten noetig (lesendes Skript), kein `trap` —
   spart Komplexitaet.
7. **`set -eu` + Pipes:** wenn wir in Phase C eine Pipe haben, deren letzter
   Befehl `grep` ist und ggf. nichts findet (Exit 1), wuerde `set -e` nicht
   zuschlagen, weil die Pipe als Ganzes betrachtet wird (kein `pipefail`).
   Trotzdem: jede Pipe **explizit im `if`-Kontext** oder per `|| true`-Suffix
   einsetzen, damit die Absicht im Code klar steht. Ein Kommentar oberhalb
   der ersten solchen Pipe erklaert das Idiom.
7. **PATH:** `smbstatus` (`/usr/local/bin/`) und `synobackup` (`/usr/syno/bin/`)
   sind im Login-PATH und im Aufgabenplaner-PATH von DSM verfuegbar. Sollte
   ein "command not found" auftauchen, einfach die jeweilige Variable oben
   im Konfigblock auf den vollen Pfad setzen.
8. **HB-Log-Format** (per SSH bestaetigt): Tab-getrennte Spalten
   `<level>\t<datetime>\t<source>:\t<message>`. Beispielzeilen:
   ```
   info	2026/05/17 01:07:01	SYSTEM:	[Synology C2][SynoC2-TM_host_a] Backup task started.
   info	2026/05/17 03:30:21	SYSTEM:	[Synology C2][SynoC2-TM_host_a] Backup task finished successfully. [29837 files scanned] [...]
   ```
   Unser grep nach `[$TASK_NAME]` (mit eckigen Klammern, `grep -F`) findet
   nur Zeilen fuer diesen Task — der `[Synology C2]`-Praefix vorne stoert
   nicht.
9. **HB-Logfile root-only:** `/var/packages/HyperBackup/var/log/synolog/`
   ist als unprivilegierter Benutzer nicht lesbar. Im Aufgabenplaner als root kein Problem.
   Konsequenz fuer manuelle Tests: nur per `sudo` lesbar.
10. **Volume bestaetigt Btrfs:** `/volume2` ist Btrfs (`@syno`-Subvolume,
    UUID `f64217fe-...`). Voraussetzung fuer Hyper-Backup-Snapshot erfuellt.

## Test-Plan
- **Schritt 1** (vorbereitet): TASK_ID + TASK_NAME aus `synobackup.conf` gelesen
  (TM_host_a=4 / SynoC2-TM_host_a, TM_host_b=1 / SynoC2-TM_host_b).
- **Schritt 2** (Preflight-Test): Skript mit absichtlich falscher TASK_ID
  laufen lassen — muss in unter 5 s mit Exit 1 abbrechen und klar sagen,
  was nicht stimmt.
- **Schritt 3** (DRY_RUN-Test): `DRY_RUN=1`, Skript per SSH auf NAS laufen
  lassen. Pruefen: alle Phasen-Log-Zeilen vorhanden, kein `synobackup`
  ausgefuehrt, sauberer Exit 0.
- **Schritt 4** (Echter Lauf, Mac aus): Mac herunterfahren oder Bundle
  aushaengen, Skript ohne DRY_RUN laufen lassen. Pruefen: voller
  Backup-Lauf, Started-Marker wird gefunden (Phase 10), Finished-Marker
  wird gefunden (Phase 11), Exit 0.
- **Schritt 5** (Timeout-Test SMB): Mac an, Bundle offen. `SMB_POLL_TIMEOUT_SEC`
  voruebergehend auf 90 setzen. Pruefen: Exit 10 nach 90 s.
- **Schritt 6** (Logrotation-Robustheits-Test, optional): synthetisch das
  HB-Log umbenennen waehrend der Polling-Phase und ein neues `synobackup.log`
  anlegen. Pruefen: Skript erkennt Inode-Wechsel, loggt Hinweis, findet
  nach neuem Eintrag den Erfolgs-Marker.

## Todo-Liste (zum Abhaken waehrend der Umsetzung)

- [x] TASK_ID per SSH besorgen: TM_host_a=4, TM_host_b=1
- [x] HB-Log-Format per SSH ermittelt (siehe heikle Details Punkt 8)
- [x] Btrfs auf /volume2 bestaetigt
- [x] Strategie-Debatte abgeschlossen, 4 Konsens-Punkte uebernommen
- [x] Skript-Datei `tm-safe-hyperbackup.sh` im Repo-Root anlegen
- [x] Header + Changelog
- [x] Shell-Optionen `set -eu`
- [x] Konfigurationsblock (TM_SHARE, TASK_ID, TASK_NAME, DRY_RUN, beide
      Polling-Bloecke, System-Pfade) — alle via `${VAR:-default}`
      ENV-ueberschreibbar fuer Tests
- [x] Hilfsfunktion `log()` mit Kommentar
- [x] Hilfsfunktion `is_share_open()` mit `grep -F "/${TM_SHARE}/"`
- [x] **Phase 0:** `preflight()` (Konfig, Bins, HB-Log, TASK_ID/NAME-Konsistenz,
      Volume-Typ)
- [x] **Phase A:** SMB-Wartephase mit `elapsed=0`, Polling, Timeout, Exit 10
- [x] **Phase B:** DRY_RUN-Pfad
- [x] **Phase C Schritt 8:** START_TS und START_INODE merken
- [x] **Phase C Schritt 9:** synobackup-Aufruf, Exit 11 bei Fehler
- [x] **Phase C Schritt 10:** Started-Marker-Sanity-Gate (max 5 Min)
- [x] **Phase C Schritt 11:** Polling auf Finished/Failed
- [x] **Phase C Schritt 12:** Logrotation per Inode-Check behandeln
- [x] **Phase C Schritt 13:** Polling-Timeout, Exit 13
- [x] Pipe-Idiom-Kommentar einmal oben hinterlegen, dann durchhalten
- [x] Exit-Codes 0/1/10/11/12/13 ueberall konsistent
- [x] Mit `sh -n` syntaxpruefen (lokal + auf NAS); shellcheck nicht installiert
- [x] Test 2 (Preflight-Fail per falscher TASK_ID) — bestaetigt: Phase 0
      bricht mit Exit 1 ab, Fehlertext nennt TASK_ID und TASK_NAME
- [x] Test 3 (DRY_RUN) — bestaetigt: Phase 0 → Phase A (sofort durch, TM
      inaktiv) → Phase B "wuerde jetzt synobackup --backup 4 --type image
      ausfuehren" → Exit 0
- [ ] Test 4 (Echter Lauf, Mac aus) — bewusst nicht automatisiert, weil
      tatsaechlicher Backup-Lauf (~2,5 h). Nutzer entscheidet wann.
- [x] Test 5 (SMB-Timeout, kuenstlich verkuerzt) — bestaetigt: bei aktivem
      TM-Mac polled Phase A 6x im 15s-Takt, nach 90s Exit 10 mit WARNUNG.
      Hat zugleich den Bug im urspruenglichen is_share_open()-Filter
      aufgedeckt (siehe heikle Details Punkt 3): SharePath und Name sind
      in smbstatus -L getrennte Spalten, `/${TM_SHARE}/` mit finalem Slash
      matcht nie. Fix auf `grep -E /${TM_SHARE}[[:space:]]`.
- [ ] Test 6 (Logrotation-Robustheit, optional) — aufwendig zu inszenieren,
      Code-Pfad ist mit `check_logrotate()` aber dokumentiert und gepatcht.
- [ ] Skript per Copy-Paste in DSM-Aufgabenplaner einsetzen (GUI-Arbeit;
      pro TM-Freigabe ein Task; bei TM_host_b die drei Anpassen-Variablen
      oben aendern)
- [ ] Skript committen (nach Nutzer-Freigabe)
