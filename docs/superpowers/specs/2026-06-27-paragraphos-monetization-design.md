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

**Quellen sind nicht gegated:** YouTube-Ingest (und jede andere Quelle) ist
im Free-Tier voll nutzbar — manuell. Nur der *automatische* Pull/Watch fällt
unter die Automatik-Grenze. Es kostet nichts, *was* man holt; es kostet nur,
dass es *unbeaufsichtigt* geholt wird.

---

## 2. Geschäftsmodell

- **Abo** (Subscription), passend zu „solange im Hintergrund läuft".
  Vorschlag (Recherche-Stand): **€4,99/Monat · €39/Jahr** (jährlich führen,
  ~2 Monate gratis). Lifetime-Tier vorerst zurückstellen.
- **Account-Login statt Lizenzschlüssel:** Pro wird an einen Nutzer-Account
  gebunden, Login per E-Mail-Magic-Link/OTP (kein Key zum Aufbewahren,
  Mehrgeräte inklusive). Details §4.
- **Trial:** Der Free-Tier deckt das Ausprobieren bereits ab; ein
  separater zeitlich begrenzter Pro-Trial ist optional, nicht MVP.
- **Free-Tier-Upsell:** Hinweis aufs Premium-Angebot **1×/Tag** (Default).
  In den Einstellungen kann der Nutzer die Frequenz **drosseln — minimal
  1×/Woche** (nicht ganz abschaltbar). Pro-/eingeloggte Abonnenten sehen den
  Hinweis nicht. Dezent halten (kein modaler Vollbild-Block), Zeitpunkt der
  letzten Anzeige lokal merken.
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

## 4. Auth & Entitlement-Flow

**Login statt Lizenzschlüssel** — kein Key, den der Nutzer aufbewahren muss.

1. Nutzer kauft Pro beim MoR (Zahlung + EU-VAT). Ein **MoR-Webhook** meldet
   das Abo an das Entitlement-Backend (Nhost), das den Abo-Status pro Account
   führt.
2. In-App „Anmelden" → **E-Mail-Magic-Link / OTP** über Nhost-Auth (kein
   Passwort). Nhost liefert ein **JWT**.
3. Mit dem JWT fragt die App den Entitlement-Status ab („hat dieser Account
   ein aktives Pro-Abo?"). JWT + Entitlement-Antwort werden lokal gecacht.
4. Das Pro-Paket prüft das gecachte Entitlement beim Start des Automatik-
   Daemons. Aktiv → Automatik läuft.
5. Periodische stille Revalidierung (Token-Refresh + Entitlement-Recheck):
   - **Server nicht erreichbar → fail-open** (weiterlaufen, Grace verlängern).
   - Account eindeutig nicht (mehr) berechtigt (Abo gekündigt/abgelaufen) →
     Automatik pausiert, App fällt sauber in den Free/Manuell-Modus zurück
     (nichts geht kaputt).

---

## 5. Schutz-Posture (bewusste Entscheidung)

Das Modell ist **„ehrlicher Zahler mit Reibung"**, kein hartes DRM:

- Echter Schutz liegt bei **(a)** dem **Account-Login** (gültiges Abo nötig,
  Accounts/Abos serverseitig widerrufbar) und **(b)** dem **closed-source
  Automatik-Code**.
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
| ffmpeg | LGPL/GPL | **Entschieden: LGPL-Build bündeln**, dynamisch gelinkt, keine GPL-Komponenten (x264/x265). Löst die Homebrew-Abhängigkeit ab. |
| yt-dlp | Unlicense | lizenzrechtlich frei. **YouTube-Ingest bleibt im Free-Tier** (manuell, wie jeder Download). YouTube-ToS-/Abmahnrisiko betrifft damit den Gratis-Teil; in About/EULA transparent halten. |

### 6.2 Backend: Zahlung getrennt von Auth/Entitlement

Login-Modell → zwei getrennte Dienste statt einer Lizenz-API. Beide sollen
in **EU-Mitgliedstaaten** domiziliert sein und damit voll der DSGVO
unterliegen. (UK fällt seit Brexit nur unter UK-GDPR + Angemessenheits-
beschluss, ist kein EU-Mitglied → Paddle/Payhip nicht erste Wahl.)

- **Auth + Entitlement: Nhost** — EU-Firma (**Schweden**), managed, Supabase-
  ähnlich (Postgres + Auth + Functions), EU-Hosting. Magic-Link-Login (JWT),
  `subscriptions`-Tabelle, Entitlement-Check. Echtes EU-Domizil (≠ Supabase,
  US-Firma mit EU-Region). **Recherche-Stand:** AVV ist **vorab unterzeichnet**
  (gegenzeichnen an privacy@nhost.io) ✓. Einziger gelisteter Sub-Prozessor:
  **AWS**, Region wählbar → **EU/Frankfurt** ✓ (Daten EU-resident, aber AWS =
  US-Mutter → CLOUD Act; bei minimaler Datenhaltung geringes Praxisrisiko,
  dokumentieren). Pro-Plan (~$25/mo) nötig (Free-Tier pausiert nach 1 Woche
  idle). **Einzig offen:** exakte schwedische Rechtsperson — direkt erfragen.
- **Merchant of Record / Zahlung (EU-VAT) — EU-domiziliert.** Recherche-Stand
  (`research/2026-06-27-monetization-decisions.md`):
  - **Mollie (NL) + OSS — empfohlener Launch-Pfad:** voll EU, transparente
    Gebühren (**1,8 % + 0,29 € EU-Karten**, keine Monatsgebühr), Recurring/
    Subscriptions + Webhooks unterstützt. VAT zentral über das deutsche
    **BZSt-One-Stop-Shop** (freiwillig, vierteljährliche Meldung), ggf. via
    Quaderno automatisiert. Du bist rechtlich Verkäufer, aber dank OSS leichte
    Admin.
  - **Vatly (NL, *Sandorian Consultancy B.V.*) — Upgrade-Option:** echter
    EU-MoR (nimmt VAT komplett ab), keine Monatsgebühr, aber **Transaktions-%
    nicht öffentlich** + 2025 Early-Access → vor Commit direkt anfragen.
    Lohnt, sobald Volumen das VAT-Offloading rechtfertigt.
  - **Cleverbridge (DE) / Nexway (FR) — raus:** enterprise-gated, kein
    Self-Serve.

US-Anbieter (Lemonsqueezy, Gumroad, FastSpring) ausgeschlossen. Exakte
Domizile + DSGVO-Auftragsverarbeitung vor Vertrag bestätigen.

### 6.3 Rechtliche To-dos vor Launch

- **Eigene Pro-EULA**, getrennt von der MIT-Lizenz des offenen Kerns.
  (MIT „as is"-Disclaimer trägt beim Bezahlprodukt nicht; EU/DE-Verbraucher-
  recht greift.)
- **DSGVO-Datenschutzerklärung** (Telemetrie nur opt-in; alles lokal hält
  das einfach).
- **Impressum** nach **DDG** (Digitale-Dienste-Gesetz — hat das TMG im
  Mai 2024 abgelöst), **Widerrufsrecht** für digitale Produkte.
- **Onboarding-Disclaimer mit verpflichtender Zustimmung** (siehe §6.4).
- EULA-Klausel: Nutzer ist für **auto-geholte Inhalte** verantwortlich
  (relevant, weil die *bezahlte* Funktion unbeaufsichtigt fremde Inhalte
  zieht).
- Optional: Marke „Paragraphos" schützen.

### 6.4 Onboarding-Disclaimer (verpflichtende Zustimmung)

Beim **ersten Start** zeigt der Setup-Guide einen Disclaimer, dem der Nutzer
**aktiv zustimmen muss**, bevor die App nutzbar ist (kein „Weiter" ohne
Häkchen). Inhalt der Verpflichtung:

- Das Programm ist **nur für die private Nutzung** geeignet.
- **Datenschutz und Urheberrechte** Dritter müssen gewahrt werden.
- Nutzung erfolgt **auf eigene Gefahr** / in Eigenverantwortung.
- Heruntergeladene bzw. transkribierte Inhalte dürfen **nur genutzt werden,
  wenn der Nutzer die Rechtesituation geklärt hat**.

Der Nutzer verpflichtet sich per aktiver Zustimmung (Checkbox + Bestätigen).
Zustimmung wird mit **Zeitstempel + Disclaimer-Version** lokal protokolliert;
bei materiell geänderter Fassung erneut einholen. Gilt für **Free und Pro**.

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
3. **Auth + Entitlement** — Nhost-Magic-Link-Login (JWT), Login-UI im Client,
   Entitlement-Cache + fail-open-Revalidierung, MoR-Webhook → Nhost-
   `subscriptions`, Pro-Tier-Gate gegen den Entitlement-Status.
4. **Distribution & Recht** — Signing/Notarization/Sparkle + EULA/DSGVO/
   Impressum + Billing-Setup.

---

## Offene Entscheidungs-Items

- [ ] Nhost: exakte schwedische Rechtsperson erfragen (AVV ✓ vorab
      unterzeichnet, Sub-Prozessor = AWS ✓, EU/Frankfurt-Region ✓, Pro-Plan).
- [ ] MoR-Pfad bestätigen: **Mollie + OSS** zum Launch (empfohlen) vs. Vatly
      abwarten (Gebühr/Verfügbarkeit direkt anfragen). Cleverbridge/Nexway raus.
- [ ] Preise €4,99/Mo · €39/Jahr bestätigen (Recherche-Vorschlag).

**Entschieden:** ffmpeg = LGPL-Build bündeln (§6.1). YouTube-Ingest bleibt
Free; nur Automatik kostet (§1).
