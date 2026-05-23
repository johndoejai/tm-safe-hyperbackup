#!/bin/sh
# =============================================================================
# tm-safe-hyperbackup.sh
#
# Triggert einen HyperBackup-Task fuer eine Time-Machine-Freigabe und wartet
# danach im HB-Log auf den Erfolgs-/Fehler-Eintrag. Vorher wird (opportunistisch,
# nicht zwingend) versucht, ein ruhiges Fenster ohne aktive TM-Schreibvorgaenge
# zu finden.
#
# Voraussetzungen: DSM 7.x, Btrfs-Volume fuer die TM-Freigabe, HyperBackup-
# Paket, ein bereits angelegter HB-Task pro TM-Freigabe. Externe Tools:
# smbstatus (Samba 4.12+, --json), jq, synobackup, cksum, awk, sort, sed, stat.
#
# Einsatz: per Copy-Paste in einen DSM-Aufgabenplaner-Task (User: root). Pro
# TM-Freigabe eine eigene Kopie mit angepassten Werten im Konfigurationsblock.
#
# Schnellstart und volle Doku siehe README.md.
#
# ----------------------------------------------------------------------------
# Konsistenz-Garantie und Rolle der Wartephase
# ----------------------------------------------------------------------------
# Die Konsistenz-Garantie kommt NICHT aus der SMB-Heuristik, sondern aus:
#   1. Hyper Backup macht beim Backup-Start automatisch einen atomaren
#      Btrfs-Snapshot der Quelle (offiziell dokumentiert; Voraussetzung Btrfs).
#   2. macOS Time Machine Sparsebundles sind crash-konsistent designt:
#      CoW-aehnliche Bands, atomare Token-Writes. Mid-write-Snapshots werden
#      beim naechsten Mount routinemaessig repariert. (Seit 2007.)
#
# Die Wartephase (Phase A unten) ist nur ein OPPORTUNISTISCHER Versuch, den
# Snapshot in ein ruhiges Fenster zu legen — KEIN Korruptionsschutz. Wenn nach
# 30 min keine Ruhe gefunden wird (Power Nap, Stuck Leases, grosser Backup-
# Lauf), wird trotzdem getriggert. Das ist beabsichtigt und kein Bug.
#
# Hintergrund Stuck Leases: macOS-SMB haelt OpLock-Leases im Cache, auch wenn
# nichts mehr geschrieben wird. Wir erkennen das per Hash-Vergleich zwischen
# zwei smbstatus-Samples — gleiche Lock-Liste in 60s = keine echte Aktivitaet.
#
# Strategie-Details: siehe tasks/tm-safe-hyperbackup/research.md (Nachtrag 3).
#
# Changelog
# ---------
# 2026-05-17  Erstversion
# 2026-05-21  Strategie-Wechsel zu D' (Best-Effort-Trigger + Hash-Heuristik
#             + Snapshot-Garantie). Hash-basierte is_share_writing() ersetzt
#             striktes is_share_open(). Phase-A-Timeout fuehrt jetzt zu
#             Fallthrough (kein exit 10 mehr). DEBUG-Schalter ergaenzt.
# 2026-05-22  Robustheits-Verbesserungen: smbstatus -L --json mit jq-Filter
#             statt Tabellen-Parsing (immun gegen Samba-Spaltendrift),
#             volle Bin-Pfade als Default (PATH-unabhaengig), VOLUME_PATH
#             als Variable (statt hardcoded /volume2).
# =============================================================================

# -u: nicht-deklarierte Variablen sind Fehler. -e: bei nicht behandeltem
# Fehler abbrechen. Kein -x (Trace) und kein pipefail (POSIX-sh hat es nicht
# garantiert).
set -eu


# =============================================================================
# Konfigurationsblock
# =============================================================================
#
# Hinweis: alle Werte unten sind per Umgebungsvariable ueberschreibbar.
# Im DSM-Aufgabenplaner laeuft das Skript ohne ENV-Variablen — dann gelten
# die Defaults rechts vom ":-". Fuer Tests per SSH praktisch:
#     DRY_RUN=1 sudo sh tm-safe-hyperbackup.sh
#     SMB_POLL_TIMEOUT_SEC=90 sudo sh tm-safe-hyperbackup.sh
# Beim Anpassen pro TM-Freigabe einfach den Default-Wert (rechts vom ":-")
# aendern.

# ====== Anpassen pro TM-Freigabe ======
# 1. TM_SHARE: Name der TM-Freigabe wie in DSM angelegt (Systemsteuerung ->
#    Freigegebener Ordner). Beispiele: "TimeMachine", "TM_MacBook", "TM_kids".
# 2. TASK_ID + TASK_NAME: aus /var/packages/HyperBackup/etc/synobackup.conf
#    auslesen. Im [task_N]-Block, dessen "backup_folders" deine TM-Freigabe
#    enthaelt, ist N die TASK_ID und der Wert von name="..." der TASK_NAME.
TM_SHARE="${TM_SHARE:-TimeMachine}"                # Name der TM-Freigabe (wie in DSM)
TASK_ID="${TASK_ID:-1}"                            # HyperBackup-Task-ID
TASK_NAME="${TASK_NAME:-MyHyperBackupTask}"        # HyperBackup-Task-Name (Log-Filter)
DRY_RUN="${DRY_RUN:-0}"                            # 1 = nichts ausloesen, nur protokollieren
DEBUG="${DEBUG:-0}"                                # 1 = rohe smbstatus-Auszuege ins Log (Diagnose)

# ====== Selten anzupassen ======
SMB_POLL_INTERVAL="${SMB_POLL_INTERVAL:-60}"               # Sekunden zwischen den beiden Samples einer Pruefung
SMB_POLL_TIMEOUT_SEC="${SMB_POLL_TIMEOUT_SEC:-1800}"       # max. Wartezeit TM-Ruhe (30 min); danach Fallthrough
HB_POLL_INTERVAL="${HB_POLL_INTERVAL:-30}"                 # Sekunden zwischen HB-Log-Checks
HB_POLL_TIMEOUT_SEC="${HB_POLL_TIMEOUT_SEC:-21600}"        # max. Wartezeit Backup-Ende (6 h)
HB_STARTED_TIMEOUT_SEC="${HB_STARTED_TIMEOUT_SEC:-300}"    # max. Wartezeit Started-Marker (5 min)
VOLUME_PATH="${VOLUME_PATH:-/volume2}"                     # Volume, auf dem TM_SHARE liegt (fuer Btrfs-Check)
# Volle Bin-Pfade als Default, damit das Skript unabhaengig vom PATH
# funktioniert (DSM-Aufgabenplaner-Kontext hat einen anderen PATH als der
# interaktive SSH-Login):
SMBSTATUS_BIN="${SMBSTATUS_BIN:-/usr/local/bin/smbstatus}"
SYNOBACKUP_BIN="${SYNOBACKUP_BIN:-/usr/syno/bin/synobackup}"
JQ_BIN="${JQ_BIN:-/usr/bin/jq}"
HB_LOG="${HB_LOG:-/var/packages/HyperBackup/var/log/synolog/synobackup.log}"
HB_CONF="${HB_CONF:-/var/packages/HyperBackup/etc/synobackup.conf}"


# =============================================================================
# Hilfsfunktionen
# =============================================================================

# Schreibt eine zeitgestempelte Statuszeile nach stdout. Der DSM-Aufgabenplaner
# sammelt stdout/stderr ein und macht beides im UI sichtbar — wir brauchen
# also keine eigene Logdatei.
log() {
    echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"
}

# Berechnet einen cksum-Hash der aktuellen Schreib-Lock-Pfade fuer TM_SHARE.
# Bei leerer Eingabe (keine Schreib-Locks) gibt cksum den konstanten Wert
# 4294967295 zurueck — der wird ueber den Vergleich automatisch zu "ruhig".
#
# Robustheit: wir parsen den offiziellen JSON-Output von smbstatus (Samba
# 4.12+, "--json"). Das Schema ist stabil und immun gegen Tabellen-Spalten-
# Drift bei Samba-Updates.
#
# jq-Filter:
# - "$share" matcht den Endpunkt von "service_path" (z. B. "/volume2/TM_host_a").
#   Damit ist die Pfad-Erkennung unabhaengig vom Volume-Namen.
# - "filename | test(...)" filtert auf Schreib-Locks mit Subpfad-ID
#   ("bands/<hex>" oder "mapped/<hex>") — Mount-Locks (lock, Info.plist,
#   bands-Directory ohne Subpfad) werden ausgeschlossen.
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

# Prueft, ob TM aktuell aktiv schreibt.
# Rueckgabe: 0 = aktiv schreibend (weiter warten), 1 = ruhig (Backup ok).
#
# Mechanik: zwei smbstatus-Samples mit SMB_POLL_INTERVAL Sekunden Abstand.
# Wenn die Lock-Liste identisch geblieben ist (= gleicher Hash), wurde in
# der Zwischenzeit nichts geschrieben — der OpLock-Cache kann ueber Stunden
# hinweg dieselben Locks halten, ohne dass etwas passiert ("Stuck Leases").
# Aktive Schreibvorgaenge erkennt man dagegen daran, dass Bands geoeffnet
# und geschlossen werden — die Lock-Liste fluktuiert sekuendlich.
#
# Wichtig: Diese Heuristik ist OPPORTUNISTISCH, kein Korruptionsschutz.
# Bei Stuck-Lease-Cache koennte sich theoretisch innerhalb eines bereits
# offenen Locks der Datei-Inhalt aendern (gleicher Pfad, neue Bytes) — die
# Heuristik wuerde "ruhig" sagen, wir wuerden mitten in einen Write
# triggern. Den Fall fangt der Btrfs-Snapshot von Hyper Backup ab
# (filesystem-konsistent) plus Sparsebundle-Crash-Toleranz.
is_share_writing() {
    h1=$(share_lock_hash)
    if [ "$DEBUG" -eq 1 ]; then
        log "DEBUG: Sample 1 hash=${h1}"
        # Zeigt die ersten 3 Schreib-Lock-Pfade aus dem JSON-Output zur
        # Diagnose, falls die Heuristik unerwartete Ergebnisse liefert.
        "$SMBSTATUS_BIN" -L --json 2>/dev/null \
            | "$JQ_BIN" -r --arg share "$TM_SHARE" '
                .open_files
                | to_entries[]
                | select(.value.service_path | endswith("/" + $share))
                | .key
              ' \
            | head -3 \
            | while IFS= read -r line; do log "DEBUG:   $line"; done
    fi
    sleep "$SMB_POLL_INTERVAL"
    h2=$(share_lock_hash)
    if [ "$DEBUG" -eq 1 ]; then
        log "DEBUG: Sample 2 hash=${h2}"
    fi
    if [ "$h1" = "$h2" ]; then
        return 1   # ruhig (gleiche Lock-Liste in SMB_POLL_INTERVAL s)
    fi
    return 0   # aktiv schreibend (Lock-Liste hat sich geaendert)
}

# Suchen einer HB-Log-Zeile, die seit START_TS hinzugekommen ist, von
# unserem TASK_NAME stammt und ein bestimmtes Marker-Textfragment enthaelt.
# Gibt die erste passende Zeile aus (oder leere Ausgabe, wenn nichts gefunden).
#
# Aufbau einer HB-Log-Zeile (Tab-getrennt):
#   info<TAB>2026/05/17 03:30:21<TAB>SYSTEM:<TAB>[Synology C2][SynoC2-TM_host_a] Backup task ...
# Mit FS="\t" ist $2 das vollstaendige "yyyy/mm/dd HH:MM:SS" und kann
# lexikographisch mit START_TS verglichen werden — bei diesem Format ist
# String-Vergleich aequivalent zum Zeitvergleich.
find_log_marker() {
    marker_text="$1"
    awk -F '\t' \
        -v start_ts="$START_TS" \
        -v needle="[${TASK_NAME}] ${marker_text}" \
        'BEGIN { found = "" }
         $2 >= start_ts && index($0, needle) > 0 { found = $0; exit }
         END { print found }' "$HB_LOG"
}

# Sucht in HB_LOG nach einem bekannten Fehler-Marker fuer unseren Task,
# seit START_TS. Gibt die erste Treffer-Zeile aus.
find_failure_marker() {
    awk -F '\t' \
        -v start_ts="$START_TS" \
        -v task="[${TASK_NAME}]" \
        'BEGIN { found = "" }
         $2 >= start_ts && index($0, task) > 0 &&
         (index($0, "Backup task was cancelled.") > 0 ||
          index($0, "Failed to run backup task.")  > 0 ||
          index($0, "Failed to start backup task.") > 0)
         { found = $0; exit }
         END { print found }' "$HB_LOG"
}

# Wird in den Polling-Schleifen vor jedem grep aufgerufen. Erkennt, wenn das
# HB-Log seit dem letzten Aufruf rotiert wurde (Inode-Wechsel), und
# aktualisiert START_INODE entsprechend. START_TS bleibt unveraendert, weil
# wir lexikographisch nach Datum filtern — das funktioniert ueber den
# Rotations-Schnitt hinweg, solange der neue Logfile gelesen wird.
check_logrotate() {
    current_inode=$(stat -c '%i' "$HB_LOG" 2>/dev/null || echo "")
    if [ -n "$current_inode" ] && [ "$current_inode" != "$START_INODE" ]; then
        log "Hinweis: HB-Log wurde rotiert (Inode ${START_INODE} -> ${current_inode}). Suche im neuen File ab ${START_TS}."
        START_INODE="$current_inode"
    fi
}

# Phase 0 — Preflight: prueft alle Voraussetzungen einmal vorab. Lieber
# sofort scheitern mit klarer Meldung als 6 h spaeter still verhungern.
preflight() {
    log "Phase 0: Preflight-Check"

    # Konfigwerte gesetzt?
    if [ -z "$TM_SHARE" ] || [ -z "$TASK_ID" ] || [ -z "$TASK_NAME" ]; then
        log "FEHLER: TM_SHARE, TASK_ID oder TASK_NAME ist leer"
        exit 1
    fi

    # Bins auffindbar und ausfuehrbar? (Volle Pfade als Default, deshalb pruefen
    # wir Existenz statt PATH-Lookup.)
    if [ ! -x "$SMBSTATUS_BIN" ]; then
        log "FEHLER: '$SMBSTATUS_BIN' nicht ausfuehrbar"
        exit 1
    fi
    if [ ! -x "$SYNOBACKUP_BIN" ]; then
        log "FEHLER: '$SYNOBACKUP_BIN' nicht ausfuehrbar"
        exit 1
    fi
    if [ ! -x "$JQ_BIN" ]; then
        log "FEHLER: '$JQ_BIN' nicht ausfuehrbar (fuer smbstatus-JSON-Parsing benoetigt)"
        exit 1
    fi

    # HB-Log und HB-Config lesbar?
    if [ ! -r "$HB_LOG" ]; then
        log "FEHLER: HB-Log nicht lesbar ($HB_LOG) — als root im Aufgabenplaner ausfuehren"
        exit 1
    fi
    if [ ! -r "$HB_CONF" ]; then
        log "FEHLER: HB-Config nicht lesbar ($HB_CONF)"
        exit 1
    fi

    # TASK_ID <-> TASK_NAME Konsistenz: im [task_$TASK_ID]-Block die name=-Zeile
    # finden und mit TASK_NAME vergleichen.
    # awk laeuft durch synobackup.conf, merkt sich ob wir im [task_<ID>]-Block
    # sind (bis zur naechsten [..]-Sektion), und prueft dort die name=-Zeile.
    # Robust gegen variable Block-Laengen (im task_4-Block kommt name= erst
    # nach ~25 Konfig-Zeilen).
    if ! awk -v id="$TASK_ID" -v name="$TASK_NAME" '
            BEGIN              { in_block = 0; found = 0 }
            /^\[/              { in_block = ($0 == "[task_" id "]") }
            in_block && $0 == "name=\"" name "\"" { found = 1; exit }
            END                { exit !found }
        ' "$HB_CONF"; then
        log "FEHLER: TASK_ID=${TASK_ID} passt nicht zu TASK_NAME=\"${TASK_NAME}\" laut $HB_CONF"
        exit 1
    fi

    # Volume-Typ (nur Warnung) — Hyper Backup macht den automatischen Snapshot
    # nur auf Btrfs. VOLUME_PATH ist konfigurierbar (Default /volume2).
    if [ ! -d "$VOLUME_PATH" ]; then
        log "WARNUNG: VOLUME_PATH '${VOLUME_PATH}' existiert nicht — Btrfs-Check uebersprungen."
    else
        vol_type=$(stat -f -c '%T' "$VOLUME_PATH" 2>/dev/null || echo "unknown")
        if [ "$vol_type" != "btrfs" ]; then
            log "WARNUNG: ${VOLUME_PATH} ist nicht btrfs ('${vol_type}'). HyperBackup-Snapshot faellt weg — nur SMB-Heuristik schuetzt vor Inkonsistenz."
        fi
    fi

    log "Preflight OK: TM_SHARE=${TM_SHARE} TASK_ID=${TASK_ID} TASK_NAME=\"${TASK_NAME}\" VOLUME_PATH=${VOLUME_PATH} DRY_RUN=${DRY_RUN}"
}


# =============================================================================
# Hauptablauf
# =============================================================================

log "=== tm-safe-hyperbackup.sh startet ==="

# Phase 0: Voraussetzungen pruefen.
preflight

# ---------------------------------------------------------------------------
# Phase A — opportunistische Suche nach ruhigem Snapshot-Fenster
# ---------------------------------------------------------------------------
# Wir versuchen bis zu SMB_POLL_TIMEOUT_SEC lang, eine Phase ohne aktive
# TM-Schreibvorgaenge zu finden. Wenn das gelingt: Backup laeuft auf
# bekannt sauberem Bundle. Wenn nicht: Backup laeuft trotzdem; der
# Btrfs-Snapshot von Hyper Backup ist die Konsistenz-Garantie (siehe
# Header-Kommentar).
#
# Jede Iteration der Schleife ruft is_share_writing() auf, das selbst
# zwei smbstatus-Samples mit SMB_POLL_INTERVAL Sekunden Abstand macht.
# Eine Iteration dauert also ~SMB_POLL_INTERVAL Sekunden Wallclock.
log "Phase A: suche ruhiges Fenster fuer /${TM_SHARE}/ (Sample-Intervall ${SMB_POLL_INTERVAL}s, Timeout $((SMB_POLL_TIMEOUT_SEC / 60))min)"

elapsed=0
while is_share_writing; do
    elapsed=$((elapsed + SMB_POLL_INTERVAL))
    if [ "$elapsed" -ge "$SMB_POLL_TIMEOUT_SEC" ]; then
        log "WARNUNG: bypass_after_timeout=1 — /${TM_SHARE}/ nach $((elapsed / 60)) min noch aktiv (Power Nap oder grosser Backup-Lauf). Triggere trotzdem; HB-Btrfs-Snapshot faengt Crash-Konsistenz ab."
        break
    fi
    log "/${TM_SHARE}/ schreibt aktiv (verstrichen: ${elapsed}s) — warte weiter"
done

if [ "$elapsed" -lt "$SMB_POLL_TIMEOUT_SEC" ]; then
    log "/${TM_SHARE}/ ist ruhig — starte Backup"
fi

# ---------------------------------------------------------------------------
# Phase B — DRY_RUN: alle Vorarbeiten gemacht, nichts ausloesen
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY_RUN=1: wuerde jetzt '${SYNOBACKUP_BIN} --backup ${TASK_ID} --type image' ausfuehren — Skript beendet sich ohne Trigger"
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase C — Backup ausloesen und auf Erfolg/Fehler warten
# ---------------------------------------------------------------------------
log "Phase C: triggere HyperBackup-Task ${TASK_ID} (${TASK_NAME})"

# Anker vor dem Trigger setzen: Datum/Uhrzeit als untere Grenze fuer awk-
# Filter im HB-Log, Inode des Logfiles fuer Rotations-Erkennung.
START_TS=$(date '+%Y/%m/%d %H:%M:%S')
START_INODE=$(stat -c '%i' "$HB_LOG")
log "Anker gesetzt: START_TS='${START_TS}', START_INODE=${START_INODE}"

# Trigger. synobackup kehrt sofort zurueck — die eigentliche Arbeit laeuft
# im Hintergrund. Wenn der Aufruf selbst fehlschlaegt, ist HB nicht ansprechbar.
if ! "$SYNOBACKUP_BIN" --backup "$TASK_ID" --type image; then
    log "FEHLER: '${SYNOBACKUP_BIN} --backup ${TASK_ID} --type image' fehlgeschlagen"
    exit 11
fi
log "synobackup ausgeloest — Sanity-Gate: warte auf Started-Marker"

# Schritt 10 — Started-Marker-Sanity-Gate (max. HB_STARTED_TIMEOUT_SEC).
# Falls HB den Task gar nicht aufnimmt (z. B. Repo gesperrt, Task disabled),
# laufen wir nicht stundenlang in den 6-h-Timeout, sondern brechen frueh ab.
started_elapsed=0
while true; do
    check_logrotate
    if [ -n "$(find_log_marker 'Backup task started.')" ]; then
        log "Started-Marker gefunden — HB hat den Task aufgenommen"
        break
    fi
    if [ "$started_elapsed" -ge "$HB_STARTED_TIMEOUT_SEC" ]; then
        log "FEHLER: Started-Marker fuer [${TASK_NAME}] kam nicht binnen $((HB_STARTED_TIMEOUT_SEC / 60))min — HB hat Task nicht angenommen"
        exit 11
    fi
    log "warte auf Started-Marker (verstrichen: ${started_elapsed}s)"
    sleep "$HB_POLL_INTERVAL"
    started_elapsed=$((started_elapsed + HB_POLL_INTERVAL))
done

# Schritt 11–13 — auf Finished-/Failed-Marker pollen (max. HB_POLL_TIMEOUT_SEC).
# Logrotation wird in jeder Iteration ueber check_logrotate behandelt.
hb_elapsed=0
while true; do
    check_logrotate

    finished_line=$(find_log_marker 'Backup task finished successfully.')
    if [ -n "$finished_line" ]; then
        log "ERFOLG: ${finished_line}"
        exit 0
    fi

    failed_line=$(find_failure_marker)
    if [ -n "$failed_line" ]; then
        log "FEHLER laut HB-Log: ${failed_line}"
        exit 12
    fi

    if [ "$hb_elapsed" -ge "$HB_POLL_TIMEOUT_SEC" ]; then
        log "WARNUNG: Backup-Ende nach $((hb_elapsed / 60))min nicht erkannt — Lauf moeglicherweise noch aktiv"
        exit 13
    fi

    log "warte auf Backup-Ende (verstrichen: $((hb_elapsed / 60))min)"
    sleep "$HB_POLL_INTERVAL"
    hb_elapsed=$((hb_elapsed + HB_POLL_INTERVAL))
done

# nicht erreichbar
#EOF
