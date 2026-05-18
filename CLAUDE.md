# Projekt: synology-backup-gate

## Ziel
Werkzeuge, um auf einem Synology-NAS das Hyper-Backup so zu steuern, dass der
Backup-Snapshot ein geschlossenes Time-Machine-Sparsebundle erfasst.

## Umgebung
- NAS: Synology, DSM 7.3
- Time-Machine-Freigabe: TM_host_a und später weitere
- Entwickelt wird auf einem Mac; das NAS wird per SSH erreicht.
- Verbindungsdaten stehen lokal in config.sh (nicht im Repo).

## Wichtige Randbedingungen
- Auf dem NAS liegen die einzigen Offsite-Kopien der Familienfotos. Absolute Vorsicht.
- DSM ist ein eingeschraenktes Linux (BusyBox-Umgebung); Skripte muessen damit laufen.
- Das Skript laeuft direkt auf dem NAS im DSM-Aufgabenplaner als root. Es wird
  per Copy-Paste in einen Aufgabenplaner-Task uebernommen — keine externen
  Configfiles, keine externe Logdatei (DSM protokolliert Stdout/Stderr selbst).
- KISS: moeglichst wenige Abhaengigkeiten, wartungsarm, robust gegen ungewohnte
  Zustaende.

## Ziel des Skripts
Vor dem Start eines Hyper-Backup-Tasks auf eine Time-Machine-Freigabe (z. B.
TM_host_a) sicherstellen, dass das Sparsebundle geschlossen ist (kein Mac hat
gerade Schreibzugriff), und erst dann das Hyper Backup ausloesen. Mit aussage-
kraeftigen Exit-Codes (offen/geschlossen/Fehler), damit Folgeskripte oder der
Aufgabenplaner darauf reagieren koennen.

## Workflow (nach Boris Tane)
Jede groessere Aufgabe laeuft in drei Phasen, moeglichst in einer einzigen Session,
mit zwei persistenten Dateien als Artefakt:

1. **Recherche** — Claude liest tief und schreibt `tasks/<task>/research.md`:
   wie der relevante Code bzw. das System aktuell funktioniert, welche Details
   wichtig sind, welche Annahmen aus echten Beobachtungen kommen. der Nutzer liest
   und gibt Feedback, bevor es weitergeht.

2. **Plan** — Claude schreibt `tasks/<task>/plan.md`: konkreter Aenderungsplan mit
   Dateipfaden, Code-Schnipseln, Abwaegungen. der Nutzer annotiert die Datei im
   Editor mit Inline-Notizen. Claude aktualisiert den Plan. Dieser Annotations-Zyklus
   laeuft 1–6 Mal, bis der Plan stimmt. Wichtig: jedes Mal explizit
   "noch nicht implementieren" sagen. Am Ende ergaenzt Claude eine Todo-Liste mit
   allen Schritten.

3. **Umsetzung** — der Nutzer gibt genau einmal das Startkommando, z. B.: "setze
   alles um, hak Aufgaben in plan.md ab, hoer nicht zwischendrin auf, keine
   ueberfluessigen Kommentare, fuehre fortlaufend Syntax-Checks aus". Claude
   arbeitet die Liste mechanisch ab und hakt erledigte Schritte in plan.md ab.
   Korrekturen sind kurz und konkret ("Funktion X fehlt", "Log-Format anders").

## Ablage von Aufgaben
- Jede Aufgabe bekommt einen eigenen Unterordner unter `tasks/`,
  z. B. `tasks/phase1-check-tm/`.
- Darin liegen `research.md` und `plan.md`.
- Diese Dateien werden committet — sie sind das Lernprotokoll und die Begruendung
  fuer den Code, der spaeter im Repo landet.

## Konventionen
- Bash bzw. POSIX-sh, kompatibel zur DSM-Umgebung; robuste Fehlerbehandlung;
  sprechendes Logging via stdout/stderr (DSM-Aufgabenplaner sammelt das ein).
- Konfiguration (TM_SHARE, Hyper-Backup-Task-ID etc.) inline im Skript, mit
  klaren Variablen oben.
- Keine Zugangsdaten im Code.
- Kleine, nachvollziehbare Commits.

## Testen
- Entwicklung am Mac, Test per SSH auf dem echten NAS (Port und User aus der eigenen DSM-Konfig),
  bzw. durch Reinkopieren in einen Aufgabenplaner-Task in DSM.