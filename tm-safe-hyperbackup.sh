#!/bin/sh
# =============================================================================
# tm-safe-hyperbackup.sh
#
# Wartet vor dem Hyper-Backup-Start, bis das Time-Machine-Sparsebundle der unten
# konfigurierten Freigabe geschlossen ist, und triggert dann den zugehoerigen
# HyperBackup-Task. Wenn die Freigabe innerhalb des Timeouts nicht ruhig wird,
# wird KEIN Backup ausgeloest (lieber kein Backup als ein Snapshot mitten in
# einem Schreibvorgang).
#
# Einsatz: per Copy-Paste in einen DSM-Aufgabenplaner-Task. Pro TM-Freigabe
# eine eigene Kopie mit angepassten Werten im Konfigurationsblock.
#
# Strategie B (siehe tasks/tm-safe-hyperbackup/research.md): warten auf Ruhe,
# bei Timeout abbrechen; sonst HyperBackup ausloesen und im HB-Log auf den
# Erfolgs-Marker pollen. Hyper Backup macht fuer Btrfs-Quellen zusaetzlich
# automatisch einen Snapshot (D als Nebeneffekt) — als Bonus-Sicherung.
#
# Changelog
# ---------
# 2026-05-17  Erstversion
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
# Beispiel: TM_host_a  -> TASK_ID=4, TASK_NAME="SynoC2-TM_host_a"
# Beispiel: TM_host_b -> TASK_ID=1, TASK_NAME="SynoC2-TM_host_b"
TM_SHARE="${TM_SHARE:-TM_host_a}"                    # Name der TM-Freigabe (wie in DSM)
TASK_ID="${TASK_ID:-4}"                            # HyperBackup-Task-ID
TASK_NAME="${TASK_NAME:-SynoC2-TM_host_a}"           # HyperBackup-Task-Name (Log-Filter)
DRY_RUN="${DRY_RUN:-0}"                            # 1 = nichts ausloesen, nur protokollieren

# ====== Selten anzupassen ======
SMB_POLL_INTERVAL="${SMB_POLL_INTERVAL:-30}"               # Sekunden zwischen smbstatus-Checks
SMB_POLL_TIMEOUT_SEC="${SMB_POLL_TIMEOUT_SEC:-1800}"       # max. Wartezeit TM-Ruhe (30 min)
HB_POLL_INTERVAL="${HB_POLL_INTERVAL:-30}"                 # Sekunden zwischen HB-Log-Checks
HB_POLL_TIMEOUT_SEC="${HB_POLL_TIMEOUT_SEC:-21600}"        # max. Wartezeit Backup-Ende (6 h)
HB_STARTED_TIMEOUT_SEC="${HB_STARTED_TIMEOUT_SEC:-300}"    # max. Wartezeit Started-Marker (5 min)
SMBSTATUS_BIN="${SMBSTATUS_BIN:-smbstatus}"               # bei "command not found": /usr/local/bin/smbstatus
SYNOBACKUP_BIN="${SYNOBACKUP_BIN:-synobackup}"             # bei "command not found": /usr/syno/bin/synobackup
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

# Prueft, ob die TM-Freigabe gerade SMB-Datei-Locks haelt (Mac schreibt).
# Rueckgabe: 0 = offen, 1 = geschlossen.
#
# Wir suchen per fixer Zeichenkette "/<TM_SHARE>/" in der smbstatus-Ausgabe.
# Der finale Slash schuetzt vor False-Positives auf Freigaben mit aehnlichem
# Praefix (z. B. "TM_host_a_old"). Die Pipe steht im if-Kontext — set -e
# kann hier nicht zuschlagen, auch wenn grep nichts findet.
is_share_open() {
    if "$SMBSTATUS_BIN" -L 2>/dev/null | grep -q -F -- "/${TM_SHARE}/"; then
        return 0
    fi
    return 1
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

    # Bins auffindbar?
    if ! command -v "$SMBSTATUS_BIN" >/dev/null 2>&1; then
        log "FEHLER: '$SMBSTATUS_BIN' nicht im PATH gefunden"
        exit 1
    fi
    if ! command -v "$SYNOBACKUP_BIN" >/dev/null 2>&1; then
        log "FEHLER: '$SYNOBACKUP_BIN' nicht im PATH gefunden"
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
    # nur auf Btrfs.
    vol_type=$(stat -f -c '%T' /volume2 2>/dev/null || echo "unknown")
    if [ "$vol_type" != "btrfs" ]; then
        log "WARNUNG: /volume2 ist nicht btrfs ('${vol_type}'). HyperBackup-Snapshot faellt weg — Strategie-B-Wartephase greift wie geplant."
    fi

    log "Preflight OK: TM_SHARE=${TM_SHARE} TASK_ID=${TASK_ID} TASK_NAME=\"${TASK_NAME}\" DRY_RUN=${DRY_RUN}"
}


# =============================================================================
# Hauptablauf
# =============================================================================

log "=== tm-safe-hyperbackup.sh startet ==="

# Phase 0: Voraussetzungen pruefen.
preflight

# ---------------------------------------------------------------------------
# Phase A — auf Ruhe der TM-Freigabe warten
# ---------------------------------------------------------------------------
log "Phase A: warte auf Ruhe der TM-Freigabe /${TM_SHARE}/ (Intervall ${SMB_POLL_INTERVAL}s, Timeout $((SMB_POLL_TIMEOUT_SEC / 60))min)"

elapsed=0
while is_share_open; do
    if [ "$elapsed" -ge "$SMB_POLL_TIMEOUT_SEC" ]; then
        log "WARNUNG: /${TM_SHARE}/ nach $((elapsed / 60)) min immer noch offen — Backup wird NICHT ausgeloest"
        exit 10
    fi
    log "/${TM_SHARE}/ ist offen (verstrichen: ${elapsed}s), warte ${SMB_POLL_INTERVAL}s"
    sleep "$SMB_POLL_INTERVAL"
    elapsed=$((elapsed + SMB_POLL_INTERVAL))
done
log "/${TM_SHARE}/ ist geschlossen — bereit fuer Backup"

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
