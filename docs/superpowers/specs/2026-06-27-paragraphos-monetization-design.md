# Paragraphos — Monetarisierung (Free-Tier + Pro-Abo)

**Status:** Design (genehmigt 2026-06-27)
**Scope:** Strategie- und Architektur-Design für die Weiterentwicklung von
Paragraphos zu einem Open-Core-Produkt mit kostenlosem manuellem Tier und
bezahltem Automatik-Tier. Dies ist ein Dach-Design; die Umsetzung wird in
vier eigenständige Sub-Projekte zerlegt (siehe §8), jedes mit eigenem
Spec → Plan → Implementierung.

> **Kein Rechtsrat.** Die rechtlichen Punkte (§6) sind eine technisch
> fundierte Einschätzung. Vor dem kommerziellen Launch von einem
> IT-/Urheberrechtsanwalt prüfen lassen.

---

## 1. Produktdefinition: Free vs. Pro

Leitsatz: **„Aktiver Klick = frei. Läuft ohne dich = Pro."**

| Funktion | Free (MIT, offen) | Pro (closed, Abo) |
| --- | :---: | :---: |
| Shows/Feeds hinzufügen, durchsuchen, anzeigen (Monitoring) | ✅ | ✅ |
| Manueller Download / Transkription / „Sync now" | ✅ | ✅ |
| Datei manuell ingestieren | ✅ | ✅ |
| **Zeitgesteuerter Auto-Pull** (Scheduler prüft Feeds selbstständig) | ❌ | ✅ |
| **Ordner-Watch** (auto-ingest bei neuer Datei) | ❌ | ✅ |
| Hintergrundlauf als Menüleisten-/LaunchAgent-Daemon | ❌ | ✅ |

**Bezahlgrenze:** *jede unbeaufsichtigte Automatik*. Das umfasst beide
existierenden Automatik-Subsysteme:

- `core/scheduler.py` — täglicher Cron-Lauf (Auto-Pull aus dem Netz).
- `core/watch_folder.py` — Watchdog-Observer, der abgelegte Mediendateien
  automatisch ingestiert.

Reine Interna wie `core/watchlist_watch.py` (lädt `watchlist.yaml` bei
Änderung neu) sind kein Nutzerfeature und bleiben im offenen Kern.

Die Free-Version ist **voll funktionsfähig**, nur unbeaufsichtigt nicht.
Der Pro-Value-Prop ist bewusst „Bequemlichkeit / Anwesenheit sparen",
kein verkrüppeltes Gratis-Produkt.

---

## 2. Geschäftsmodell

- **Abo** (Subscription), passend zu „solange im Hintergrund läuft".
  Vorschlag: monatlich + jährlich.
- **Trial:** Der Free-Tier deckt das Ausprobieren bereits ab; ein
  separater zeitlich begrenzter Pro-Trial ist optional, nicht MVP.
- **Merchant of Record (MoR)** übernimmt EU-VAT. Anbieter siehe §6.

---

## 3. Architektur: Open-Core-Split

### 3.1 Offenes Paket `paragraphos` (MIT, öffentlich)

Enthält den gesamten **manuellen** Funktionsumfang. Enthält **keinen**
Background-Runner mehr:

- Die Verdrahtung von `core/scheduler.py` (Start des `BackgroundScheduler`,
  aktuell in `app.py:403`) wird aus dem offenen Repo herausgelöst.
- Der Auto-Start-Lebenszyklus von `core/watch_folder.py` wird ebenfalls
  herausgelöst.
- Manuelle Pfade (`cmd_check`, `cmd_run_next`, `cmd_ingest_*`, manueller
  Sync) bleiben vollständig im offenen Kern.

Das offene Repo definiert eine **Plugin-/Erweiterungsschnittstelle**, über
die das Pro-Paket den Automatik-Runner einklinkt, wenn vorhanden und
aktiviert.

### 3.2 Privates Paket `paragraphos-pro` (closed-source)

- Automatik-Runner: Scheduler-Job-Verdrahtung + Ordner-Observer-Lebenszyklus.
- Entitlement-Client (§4).
- Wird zur Laufzeit als optionales Paket geladen. Fehlt es oder ist nicht
  aktiviert, verhält sich die App exakt wie die Free-Version.

**Schutzlogik:** Der Automatik-Code existiert im offenen Repo gar nicht
(nicht nur ein weg-patchbarer `if licensed:`-Check). Ein Bypass erfordert
Reimplementierung, nicht Entfernen einer Zeile. Die Scheduler-*Logik* selbst
ist trivial (Cron), der Moat ist also bewusst klein — das ist akzeptiert
(siehe §5).

### 3.3 PySide6-Migration (Voraussetzung)

PyQt6 ist GPL-3.0 ODER Riverbank-Commercial. Ein closed-source Pro-Paket,
das gegen GPL-PyQt6 linkt, würde GPL-infiziert. Daher Migration des
gesamten UI auf **PySide6 (LGPL-3.0)** — erlaubt closed-source bei
dynamischem Linken (Python). Die API ist weitgehend deckungsgleich;
Aufwand überwiegend mechanisch (Enums, Signal/Slot-Syntax, Imports).

---

## 4. Entitlement-Flow

1. Nutzer kauft Pro → erhält Lizenzschlüssel vom MoR.
2. In-App „Pro aktivieren" → Key an die Lizenz-API → **signiertes Token**
   (mit Ablauf, z. B. 30 Tage) wird lokal gecacht.
3. Das Pro-Paket prüft das Token beim Start des Automatik-Daemons.
   Gültig → Automatik läuft.
4. Nahe Ablauf: stille Online-Revalidierung.
   - **Server nicht erreichbar → fail-open** (weiterlaufen, Grace
     verlängern).
   - Token klar abgelaufen *und* Server meldet „ungültig/widerrufen" →
     Automatik pausiert, App fällt sauber in den Free/Manuell-Modus zurück
     (nichts geht kaputt).

---

## 5. Schutz-Posture (bewusste Entscheidung)

Das Modell ist **„ehrlicher Zahler mit Reibung"**, kein hartes DRM:

- Echter Schutz liegt bei **(a)** der einmaligen, server-gateten
  **Aktivierung** (gültiger Key nötig, Keys widerrufbar, keine
  Key-Weitergabe) und **(b)** dem **closed-source Automatik-Code**.
- **Fail-open** bei unerreichbarem Server ist Absicht (gute UX).
- **Akzeptierter Bypass:** Wer nach der Aktivierung selektiv nur die
  Lizenz-Domain blockt (Content-Domains offenlässt), nutzt Pro dauerhaft
  gratis. Das ist explizit in Kauf genommen: Die App ist ohne Netz ohnehin
  nutzlos (sie muss Inhalte aus dem Netz holen), und wer derart tief im
  Netzwerk-Traffic agiert, „könnte sich die App auch selbst bauen". Der
  erwartete Umsatzverlust ist vernachlässigbar.

---

## 6. Recht & Abrechnung

### 6.1 Lizenz-Kompatibilität

| Komponente | Lizenz | Implikation |
| --- | --- | --- |
| Eigener Kern | MIT | bleibt offen |
| PyQt6 → **PySide6** | GPL → **LGPL-3.0** | Wechsel zwingend für closed Pro |
| whisper.cpp | MIT | unkritisch |
| Whisper-Weights (large-v3-turbo) | MIT | unkritisch |
| sherpa-onnx (Diarization, optional) | Apache-2.0 | unkritisch |
| ffmpeg | LGPL/GPL (Homebrew-Build) | bei Bündelung **LGPL-Build** nötig, dynamisch gelinkt; sonst weiter extern via Homebrew |
| yt-dlp | Unlicense | lizenzrechtlich frei; **aber** YouTube-ToS-/Abmahnrisiko im Bezahlprodukt — Risiko bewerten |

### 6.2 Merchant of Record (MoR) — europäisch

US-Anbieter (Lemonsqueezy, Gumroad) sind ausgeschlossen (EU-Präferenz).
**Shortlist, Datenstandort zu verifizieren:**

- **Paddle** (UK) — MoR + Lizenz-API.
- **Payhip** (UK) — MoR + Lizenzschlüssel.

Entscheidungs-Item: Datenstandort/DSGVO-Auftragsverarbeitung prüfen, bevor
fixiert wird. Ein echt EU-domiziliertes All-in-One (MoR + Lizenz-API) ist
dünn gesät; UK ist der realistische „europäische" Kompromiss.

### 6.3 Rechtliche To-dos vor Launch

- **Eigene Pro-EULA**, getrennt von der MIT-Lizenz des offenen Kerns.
  (MIT „as is"-Disclaimer trägt beim Bezahlprodukt nicht; EU/DE-Verbraucher-
  recht greift.)
- **DSGVO-Datenschutzerklärung** (Telemetrie nur opt-in; alles lokal hält
  das einfach).
- **Impressum** (TMG), **Widerrufsrecht** für digitale Produkte.
- EULA-Klausel: Nutzer ist für **auto-geholte Inhalte** verantwortlich
  (relevant, weil die *bezahlte* Funktion unbeaufsichtigt fremde Inhalte
  zieht).
- Optional: Marke „Paragraphos" schützen.

---

## 7. Distribution

- **Notarisiertes DMG** (Apple Developer Program, 99 $/Jahr), Code-Signing,
  Auto-Update via **Sparkle**.
- **Kein Mac App Store** — die Sandbox verbietet die nötigen Subprozesse
  (whisper-cli, ffmpeg, yt-dlp, Homebrew).
- Pro läuft als **Menüleisten-/LaunchAgent-Daemon** (`LSUIElement` ist in
  `setup.py` bereits vorgesehen) — natürlicher Ort für Automatik + Token-
  Revalidierung.

---

## 8. Zerlegung in Sub-Projekte (Reihenfolge)

Zu groß für eine einzige Implementierung. Jedes Sub-Projekt bekommt einen
eigenen Spec → Plan → Implementierung:

1. **PySide6-Migration** — Flaschenhals; blockiert jede Closed-Source-
   Komponente. *Nächster Schritt.*
2. **Open-Core-Split** — Automatik-Runner (`scheduler`-Verdrahtung +
   `watch_folder`-Auto-Start) aus dem offenen Repo herauslösen,
   Plugin-Schnittstelle definieren, privates `paragraphos-pro`-Paket anlegen.
3. **Entitlement + Lizenz-Integration** — Token-Client, Aktivierungs-UI,
   fail-open-Revalidierung, MoR-Lizenz-API-Anbindung.
4. **Distribution & Recht** — Signing/Notarization/Sparkle + EULA/DSGVO/
   Impressum + Billing-Setup.

---

## Offene Entscheidungs-Items

- [ ] MoR final wählen (Paddle vs. Payhip) nach Datenstandort-Prüfung.
- [ ] Abo-Preise (monatlich/jährlich) festlegen.
- [ ] ffmpeg: weiter extern (Homebrew) oder LGPL-Build bündeln?
- [ ] YouTube-Ingest im Pro-Tier behalten oder als „bring your own URL /
      at your own risk" kapseln?
