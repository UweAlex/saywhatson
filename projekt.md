# SayWhatsOn — Projektplan

*the screen reader that actually reads the screen*
„Was geht ab? — SayWhatsOn sagt's dir."

SayWhatsOn ist ein lokales Windows-Hintergrundwerkzeug, das den Bildschirm samt
System- und Fensterkontext erfasst, an ein bildverstehendes Sprachmodell schickt
und das Ergebnis als gesprochene Orientierungshilfe ausgibt. Es ersetzt keinen
Screenreader, sondern legt eine semantische Ebene darüber.

**Stand:** lauffähige Beta. Meilensteine 1 bis 3 sind umgesetzt und getestet,
Meilenstein 4 ist geplant. Bildauswertung über Google Gemini (Cloud).

---

## 1. Projektziel

Ein Werkzeug, das auf Knopfdruck einen semantischen Gesamtüberblick darüber gibt,
„was gerade auf dem Bildschirm los ist" — wohin der Fokus geht, ob ein Dialog die
Eingabe an sich gerissen hat, welche Fenster offen sind (auch verdeckte und
minimierte) und wie man sich zurechtfindet. Das ist etwas, das klassische
Screenreader strukturell nicht leisten: Sie lesen den UI-Baum vor, geben aber
keinen menschlich gedachten Überblick über die Situation.

Zielgruppe sind blinde und stark sehbehinderte Nutzer. Entstanden ist das Projekt
aus dem konkreten Bedarf, der blinden Mutter des Autors eine schnelle Orientierung
zu geben, wenn sie sich auf dem Bildschirm nicht mehr sicher ist.

## 2. Architekturprinzipien

* **KISS:** Vorhandene Windows-Schnittstellen nutzen statt das Rad neu zu erfinden.
  Keine tiefen C++-Hacks.
* **Minimal invasiv:** reiner Hintergrundprozess (Standalone), der sich nicht in
  fremde Software einklinkt, sondern den Bildschirm von außen erfasst und über die
  windows-eigene Sprachausgabe spricht — friedlich neben dem laufenden Screenreader.
* **Separation of Concerns:** Kernlogik (Julia) ist getrennt von Bildauswertung
  (austauschbares Backend, Strategy-Pattern) und Ausgabe (Konsole + Sprache).
* **Modell entscheidet, Code sammelt:** Nicht-sichtbare Fakten (Tastaturzustände,
  Akku, Fensterliste) werden über flache Win32-Aufrufe roh gesammelt und dem Modell
  als Kontext mitgegeben. *Was* davon erwähnenswert ist, entscheidet das Modell per
  Prompt-Regel — nicht starre if-Abfragen im Code.
* **Latenztoleranz als Designvorteil:** Der Nutzer fragt bewusst und auf Abruf an.
  Antwortzeiten von einigen Sekunden sind in Ordnung. Wichtig ist eine *sofortige
  akustische Quittung*, dass die Anfrage angekommen ist (siehe Abschnitt 6).

## 3. Technischer Stack

* **Kernlogik:** Julia
* **API-Kommunikation:** `HTTP.jl`, `JSON3.jl`, `Base64`
* **System-Interop, zwei Klassen:**
  * *Flache Win32-Aufrufe* (elegant und KISS-konform via `ccall`): globale Hotkeys
    (`RegisterHotKey`), Tastaturzustände (`GetKeyState`), Akku (`GetSystemPowerStatus`),
    Internet (`InternetGetConnectedState`), Fensteraufzählung (`GetTopWindow`,
    `GetWindow`, `GetWindowTextW`, `IsIconic`, `DwmGetWindowAttribute`), Fokusrückgabe
    (`GetForegroundWindow`, `AttachThreadInput`, `SetForegroundWindow`), Pieptöne (`Beep`).
  * *COM-/.NET-Dinge* (Screenshot, Sprachausgabe, Editorfenster): In Julia kein
    nativer Weg. Gelöst über kurze **PowerShell-Aufrufe** (`System.Drawing` für den
    Screenshot, `System.Speech` für SAPI). Beim großzügigen Zeitbudget sind die kurzen
    Prozessstarts unkritisch.
* **Bildauswertung (Backend, austauschbar via Strategy-Pattern):**
  * *Cloud (aktiv):* Google **Gemini** (`gemini-2.5-flash`), Bild als Base64 + Textprompt
    über `HTTP.jl`. API-Schlüssel aus der Umgebungsvariable `GEMINI_API_KEY`
    (alternativ `GOOGLE_API_KEY`).
  * *Lokal (vorhanden, aber ruhend):* ein `OllamaBackend` existiert im Code und
    dokumentiert die Austauschbarkeit. Bewusst nicht aktiv — siehe Abschnitt 7.

## 4. Abgrenzung zu bestehenden Lösungen

* **Be My Eyes / „Be My AI" und ähnliche Cloud-Bildbeschreibung:** liefern eine
  gesprochene Beschreibung eines Bildes. Genau das leistet SayWhatsOn nach den
  Meilensteinen 1 und 2 auch. Der eigentliche Mehrwert beginnt ab Meilenstein 3:
  die Anreicherung mit System- und Fensterkontext und die auf *Orientierung und
  Navigation* ausgerichtete Antwort statt einer neutralen Bildunterschrift.
* **Klassische Screenreader (JAWS, NVDA):** lesen den strukturellen UI-Baum vor,
  geben aber keinen semantischen Gesamtüberblick. SayWhatsOn ersetzt sie nicht,
  sondern ist eine Meta-Ebene darüber und läuft parallel zu ihnen.

---

## 5. Meilensteine

### Meilenstein 1 — Visuelle Pipeline ✅ umgesetzt
* Globaler Hotkey **Strg+Druck** (`RegisterHotKey` auf Strg + Druck-Taste), der die
  Taste konsumiert, damit sie nicht zusätzlich an die App durchgereicht wird.
* **Sofortiger Piepton** als allererste Aktion, bevor Screenshot und Netzaufruf starten.
* Vollbild-Screenshot direkt über PowerShell (`CopyFromScreen`), kein Umweg über die
  Zwischenablage.
* Senden als Base64-Bild an Gemini mit Orientierungs-Prompt; Ausgabe in der Konsole.
* Backend-Abstraktion `beschreibe_bild(backend, png, kontext)` von Anfang an (Strategy-Pattern).

### Meilenstein 2 — Sprachausgabe & Navigieren in der Ausgabe ✅ umgesetzt
* **Sprachausgabe** über die windows-eigene SAPI (`System.Speech`), etwas langsamer
  für bessere Verständlichkeit. `clean_for_speech` entfernt Markdown, schreibt
  Einheiten aus und macht den Text vorlesefreundlich. Die SAPI-Stimme läuft friedlich
  neben dem Screenreader; eine COM-Anbindung an die JAWS-/NVDA-Sprachwarteschlange war
  ursprünglich geplant, wurde aber zugunsten der einfacheren SAPI-Lösung verworfen,
  die die Zielnutzerin gut versteht.
* **Navigieren in der Ausgabe:** Zweiter Hotkey **Umschalt+Druck** öffnet die letzte
  Beschreibung in Notepad. Dort kann sie mit dem Screenreader (JAWS) zeilen-, wort-
  und buchstabenweise durchgegangen werden — wichtig etwa, um englische Beschriftungen
  sicher mitzubekommen. Beim Schließen springt der Fokus exakt ins Ausgangsfenster
  zurück (`GetForegroundWindow` gemerkt, danach `AttachThreadInput` + `SetForegroundWindow`).

> **⭐ Mit Abschluss von Meilenstein 2 ist der Funktionsumfang bestehender
> KI-Bildbeschreibungen erreicht:** Hotkey drücken, sofortige Quittung hören,
> gesprochene Beschreibung des Bildschirms bekommen, in Ruhe nachlesen. Alles ab
> Meilenstein 3 geht darüber hinaus.

### Meilenstein 3 — System- & Fensterkontext ✅ umgesetzt
* **Systemstatus** über flache Win32-Aufrufe: Feststelltaste und Nummernblock
  (`GetKeyState`), Akku (`GetSystemPowerStatus`), Internetverbindung
  (`InternetGetConnectedState`). Wichtigster Nutzen: eine **Warnung bei
  eingeschalteter Feststelltaste**, bevor versehentlich in Großbuchstaben getippt wird.
* **Fensterliste** über die Z-Reihenfolge (`GetTopWindow` + `GetWindow`): alle offenen
  Anwendungsfenster mit echtem Titel, samt Vermerk, welches im Vordergrund, welche
  minimiert und welche verdeckt sind. So erfährt der Nutzer auch von Fenstern, die
  im Bild gar nicht sichtbar sind. Desktop/Shell und „cloaked" Phantom-Fenster werden
  herausgefiltert (`DwmGetWindowAttribute`).
* Beides geht als beschrifteter Kontextblock an das Modell. Eine Prompt-Regel weist es
  an, nur das Relevante zu erwähnen (Feststelltaste-Warnung, verdeckte Fenster nur
  benennen) und über den Inhalt verdeckter Fenster nichts zu erfinden.
* Anders als ursprünglich geplant **einstufig** statt zweistufig: Die LLM-Antwort kommt
  schnell genug, und eine einzige zusammenhängende gesprochene Antwort ist klarer als
  zwei getrennte Ausgaben.

### Meilenstein 4 — Echter UI-Fokus im Fenster 🔜 geplant
* Bisher weiß SayWhatsOn, *welches* Fenster vorn ist. M4 soll verraten, *welches
  Bedienelement* (Knopf, Eingabefeld, Listeneintrag) innerhalb des Fensters gerade
  den Tastaturfokus hat — der Schritt von „gut beschrieben" zu „faktisch korrekt,
  wohin der nächste Tastendruck geht".
* Weg: `UIAutomationCore` (COM). Das ist der bekannte Reibungspunkt in Julia und wird
  daher bewusst und nicht nebenbei angegangen.

---

## 6. Akustisches Feedback (Pieptöne)

Direkte Rückmeldung über kurze Töne statt Worte — sofort verfügbar, belegt den
Sprachkanal nicht, kollidiert nicht mit dem Screenreader. Umgesetzt über
`kernel32::Beep` (`ccall`, kein COM). Drei Töne:
* **Start:** „Anfrage verstanden, arbeite." (erste Aktion im Hotkey-Handler)
* **Fertig:** höher, kündigt die Ausgabe an.
* **Fehler:** tief und doppelt, klar negativ.

## 7. Datenschutz & Cloud-Entscheidung

Im aktiven Cloud-Modus werden Screenshots zur Auswertung an Google Gemini gesendet.
Auf dem Bildschirm einer blinden Person können sensible Inhalte stehen (offene Mails,
Namen, sichtbare Passwörter), ohne dass sie es bemerkt. Das ist im Haftungsausschluss
(README) klar benannt, damit jeder Nutzer bewusst entscheidet, was er erfasst.

Ein lokaler Pfad (Ollama mit Vision-Modell) wäre datenschutzfreundlicher und ist im
Code als ruhendes Backend vorhanden. Bewusst nicht aktiviert, weil lokale Vision-Modelle
Gemini in Beschreibungsqualität deutlich nachstehen und auf einem Laptop einen großen
Ressourcen- und Geschwindigkeitsnachteil bedeuten. Für ein Werkzeug, das schnell und
verlässlich beschreiben soll, ist die Cloud derzeit die bessere Wahl. Die Tür bleibt
offen, falls lokale Modelle künftig aufholen.

## 8. Backlog (mögliche Zukunfts-Features)

Nicht Teil der Kern-Meilensteine, aber sinnvolle Ergänzungen:
* **Frage-Antwort-Modus:** Folgefrage zum selben Screenshot ohne neue Aufnahme.
* **Sprechen abbrechen:** Hotkey, um eine laufende lange Ausgabe zu stoppen.
* **Korrekte englische Aussprache** (SSML mit englischer Stimme) — durch das
  Buchstabieren im Editor derzeit eher Komfort als Notwendigkeit.
* **Nur aktives Fenster erfassen** statt des ganzen Bildschirms — weniger Daten,
  weniger Datenschutzrisiko.
* **Konfigurierbarer Hotkey** und konfigurierbare Tonsignale.
* **Sensitivitätsfilter:** Warnung vor dem Versand, wenn z. B. ein Passwortfeld erkannt wird.

## 9. Getroffene Entscheidungen

* **Name:** SayWhatsOn.
* **Lizenz:** MIT (Haftungsausschluss reicht, ansonsten maximale Wiederverwendbarkeit).
* **Hotkeys:** Strg+Druck (beschreiben) und Umschalt+Druck (im Editor lesen). Die
  Druck-Taste kollidiert nicht mit JAWS-/NVDA-Belegungen; SayWhatsOn konsumiert sie.
* **Backend:** Cloud (Gemini) aktiv, lokal (Ollama) ruhend.
* **Sprache Julia:** bewusst gewählt; die COM-Schicht bleibt der Reibungspunkt. Sollte
  die COM-Anbindung in M4 zu aufwendig werden, ist C# (native COM/UIAutomation) als
  Alternative zu evaluieren.# Projekt: Kontextbewusster Windows-Orientierungsassistent

## 1. Projektziel
Entwicklung eines lokalen, datenschutzfreundlichen Hintergrunddienstes, der visuelle Bildschirminformationen (Zwischenablage/Screenshots) mit dem aktuellen System- und UI-Kontext kombiniert. Diese aggregierten Daten werden an ein Vision-fähiges Large Language Model (LLM) gesendet, um eine präzise, situationsbezogene Orientierungshilfe zu generieren. Die Audioausgabe erfolgt minimal invasiv über bestehende Screenreader-Software, um Audio-Interferenzen zu vermeiden.

Zielgruppe sind blinde und stark sehbehinderte Nutzer, die auf Abruf einen semantischen Gesamtüberblick darüber bekommen wollen, „was gerade auf dem Bildschirm los ist" — etwas, das klassische Screenreader strukturell nicht leisten.

## 2. Architekturprinzipien
* **KISS (Keep It Simple, Stupid):** Verzicht auf die Neuerfindung des Rades. Das System nutzt vorhandene Windows-Schnittstellen und vermeidet tiefgreifende C++-Hacks oder proprietäre Skriptsprachen.
* **Minimal Invasiv:** Das Programm agiert als reiner Hintergrundprozess (Standalone). Es klinkt sich nicht tief in bestehende Software ein, sondern steuert diese über definierte, offizielle externe APIs an.
* **Separation of Concerns (Modulare Trennung):** Die Logikschicht (Julia) ist strikt von der Präsentationsschicht (Sprachausgabe) und der Inferenzschicht (Bild-KI) getrennt. Beide Außenschichten sind über austauschbare Backends (Strategy-Pattern) angebunden.
* **Datenschutz als Standard, nicht als Option:** Der datenschutzkonforme Pfad (lokale Inferenz) ist das Ziel. Cloud-Backends sind erlaubt, müssen aber bewusst aktiviert und mit einer Warnung versehen werden (siehe Abschnitt 6).
* **Latenztoleranz als Designvorteil:** Der Nutzer fragt bewusst und auf Abruf an. Antwortzeiten von mehreren Sekunden (bis ~10 s) sind akzeptabel. Wichtig ist nicht die Gesamtdauer, sondern eine *sofortige Quittung*, dass die Anfrage angekommen ist (siehe Abschnitt 7).

## 3. Technischer Stack
* **Orchestrierung & Kernlogik:** Julia
* **API-Kommunikation:** `HTTP.jl`, `JSON3.jl`, `Base64`
* **System-Interop (zwei Klassen):**
  * *Flache Win32-Aufrufe* (elegant und KISS-konform via `ccall`): `GetForegroundWindow`, `GetWindowText`, `GetKeyState`, `GetSystemPowerStatus`, `Beep`, `PlaySound`.
  * *COM-/.NET-basierte Schnittstellen* (Sprachausgabe, UI-Automation, Clipboard): Julia hat hier keine native Unterstützung. Realistischer, latenztoleranter Weg ist das Aufrufen von PowerShell-Einzeilern (kurze Prozessstarts sind beim großzügigen Zeitbudget unkritisch). `PyCall.jl` ist möglich, widerspricht aber KISS (Julia → Python → COM) und wird nur im Notfall eingesetzt.
* **KI-Backend (Bildauswertung):** Über das `ImageDescriptionBackend`-Strategy-Pattern austauschbar.
  * *Lokal (Zielzustand, datenschutzkonform):* Ollama mit Vision-Modell, angesprochen über die lokale HTTP-API auf `localhost:11434` (`/api/generate` mit Base64-`images`-Array). Kein API-Key, kein Datenabfluss.
  * *Cloud (Entwicklung/Fallback):* Beliebiger Vision-API-Endpunkt (z. B. Google Gemini), ebenfalls als Base64-Bild + Textprompt via `HTTP.jl`.

### Empfohlene lokale Vision-Modelle (Stand Mitte 2026)
* **Gemma 4 (E4B):** nativ multimodal, läuft auf 6–8 GB VRAM — die Laptop-taugliche Standardwahl.
* **Gemma 4 (26B):** stärkere Variante für Workstations, deutlich besseres Reasoning.
* **Llama 3.2 Vision 11B (~8 GB):** dediziertes, gut dokumentiertes Bildmodell.
* **Llama 4 Scout (20–24 GB VRAM):** nativ multimodal, höchste Beschreibungsqualität für High-End-Hardware.
* **Qwen2.5-VL:** besonders stark bei Text/Dokumenten/Charts auf dem Bildschirm.

## 4. Logische Abgrenzung (Hard Check vs. Bestehende Lösungen)
* **Be My Eyes / Cloud-Lösungen:** Meist proprietär (Closed Source), stark Cloud-abhängig und wenig anpassbar. Dieses Projekt ist Open Source, potenziell 100 % lokal lauffähig und datenschutzsicher.
* **Klassische Screenreader (NVDA, JAWS):** Lesen strukturelle UI-Bäume vor, liefern aber keinen semantischen „Gesamtüberblick". Dieses Projekt ersetzt den Screenreader nicht, sondern fungiert als semantische Meta-Ebene darüber.

> **Wichtige Abgrenzung beim Funktionsumfang:** Eine reine *bildbeschreibende* Funktion (Screenshot → gesprochene Beschreibung) entspricht dem, was bestehende KI-Lösungen wie die Be-My-Eyes-Bildbeschreibung bieten. Der eigentliche Mehrwert dieses Projekts — die Anreicherung mit System- und UI-Kontext — beginnt erst ab Meilenstein 3. Siehe Markierung unten.

---

## 5. Meilensteine (Ausbaustufen)

Jeder Meilenstein stellt ein in sich geschlossenes, voll lauffähiges und testbares Minimal Viable Product (MVP) dar.

### Meilenstein 1: Der Proof of Concept (Visuelle Pipeline)
**Ziel:** Grundlegender Transportweg von der Zwischenablage zum LLM und zurück.
* Registrierung eines **konfigurierbaren** globalen Hotkeys in Windows (Standard z. B. `F8`, aber frei einstellbar — Funktionstasten kollidieren häufig mit JAWS/NVDA-Belegungen).
* Auslesen eines Bildes aus der Zwischenablage.
* **Sofortige akustische Quittung (Piepton)** als allererste Aktion im Hotkey-Handler, *bevor* Screenshot, Kodierung und HTTP-Aufruf starten (siehe Abschnitt 7).
* Aufbau der austauschbaren Backend-Abstraktion `beschreibe_bild(img)::String` von Anfang an (Strategy-Pattern). Erstes Backend frei wählbar: Cloud (schneller Start) oder lokal (datenschutzkonform).
* Senden des Bildes als Base64-kodierter Payload via `HTTP.jl` an die KI mit hartem Prompt: „Beschreibe diesen Bildschirminhalt präzise auf Deutsch."
* Ausgabe des empfangenen Strings über die Standard-Konsolenausgabe (`Base.println`) zur Verifikation.

### Meilenstein 2: Der Audio-Router (Minimal Invasive Sprachausgabe) — ⭐ PARITÄTS-MEILENSTEIN
**Ziel:** Implementierung des Strategy-Patterns zur Vermeidung von Audio-Kollisionen bei aktiven Screenreadern.
* Entwicklung des Moduls `AudioSpeechOrchestrator`.
* **Strategie A (JAWS):** Dynamischer Bindungsversuch an das COM-Interface `FreedomSci.JawsApi`; bei Erfolg Übergabe an die JAWS-Sprachwarteschlange (`SayString`).
* **Strategie B (NVDA):** Bindung an den `nvdaControllerClient` (`nvdaController_speakText`). NVDA ist quelloffen, kostenlos und in der datenschutzbewussten Zielgruppe sehr verbreitet — diese Strategie ist daher kein Optional, sondern Pflichtbestandteil.
* **Strategie C (Fallback/Entwicklung):** Schlagen A und B fehl, Bindung an `SAPI.SpVoice` (Windows-eigene Sprachausgabe).
* Das Hauptprogramm ruft ab jetzt nur noch die abstrahierte Ausgabefunktion auf, ohne die Audio-Treiber selbst zu verwalten.

> **⭐ Mit Abschluss von Meilenstein 2 ist der Funktionsumfang bestehender KI-Bildbeschreibungslösungen (z. B. Be My Eyes „Be My AI") erreicht:** Der Nutzer drückt einen Hotkey, hört eine sofortige Quittung und bekommt die gesprochene Beschreibung des Bildschirminhalts — vollständig lokal und Open Source. Alles ab Meilenstein 3 geht über bestehende Alternativen hinaus.

### Meilenstein 3: System-Kontext (Der Orientierungsassistent)
**Ziel:** Anreicherung des LLM-Prompts mit non-visuellen Systemdaten — der Übergang vom „Bild-Beschreiber" zum „Assistenten".
* Implementierung von Abfragen für essenzielle Systemvariablen (Akkustand via `GetSystemPowerStatus`, WLAN-Status).
* Abfrage globaler Tastaturzustände (Caps Lock, Num Lock) über `User32.dll::GetKeyState` (`ccall`).
* **Einführung der zweistufigen Ausgabe (durch das Latenzbudget ermöglicht):**
  * *Stufe 1 (sofort, billig):* aktiver Fenstertitel, Fokus-Element, Systemstatus — alles instant über die flachen Win32-`ccall`s. Wird sofort gesprochen und gibt grobe Orientierung.
  * *Stufe 2 (Sekunden später):* die reiche visuelle LLM-Beschreibung.
* Das LLM erhält einen strukturierten Prompt: `[Systemstatus: Akku 80%, Caps Lock AN] + [Bilddaten]`.

### Meilenstein 4: UI-Fokus-Integration (Fortgeschritten)
**Ziel:** Einbezug der aktiven Applikationsdaten, um das Bild korrekt einzuordnen.
* Ermittlung des aktuell im Vordergrund laufenden Prozesses und des aktiven Fenstertitels (via `User32.dll::GetForegroundWindow` und `GetWindowText`).
* *Optional:* Minimal invasiver Abgriff des aktuellen Tastaturfokus über `UIAutomationCore.dll`, um der KI mitzuteilen, auf welchem Element der Nutzer sich befindet.
* Der LLM-Prompt wird final orchestriert: `[Kontext: Aktives Fenster ist Firefox, Fokus auf Suchfeld] + [Systemstatus] + [Bilddaten]`.

---

## 6. Datenschutz-Leitplanke (Cloud-Backends)

Der lokale Ollama-Pfad ist datenschutzsicher: Bilder verlassen den Rechner nie.

Bei Cloud-Backends gilt besondere Vorsicht, weil Screenshots vom Bildschirm einer blinden Person sensible Inhalte enthalten können (Bankdaten, offene Mails, sichtbare Passwörter), ohne dass die Person dies bemerkt.

* **Google Gemini (Gratis-Tarif):** ideal zum schnellen Testen von Meilenstein 1 — Bildverarbeitung inklusive, ~1.500 Anfragen/Tag, 15 Anfragen/Minute, keine Kreditkarte, kein Ablaufdatum. **Haken:** Im Gratis-Tarif dürfen die eingereichten Daten fürs Modelltraining verwendet werden. → **Nicht für den Produktiveinsatz mit echten Nutzerdaten geeignet.**
* **Datenschutzkonforme Produktivpfade:** entweder Geminis Bezahl-Tarif / Vertex AI (kein Training auf Nutzerdaten) — oder, bevorzugt, der lokale Ollama-Pfad.
* **Regel im Code:** Cloud-Backends müssen explizit per Konfiguration aktiviert werden und beim Start eine hörbare/protokollierte Warnung ausgeben.

## 7. Akustisches Feedback-Konzept (Piepton)

Direktes Feedback erfolgt über einen kurzen Piepton statt über gesprochene Wörter. Begründung:
* Sofort verfügbar, ohne Anlaufzeit der Sprachsynthese.
* Belegt den Sprachkanal nicht und kollidiert daher nicht mit dem laufenden Screenreader.
* Wird auf einer eigenen Frequenz nicht als Sprache fehlinterpretiert.

Umsetzung KISS-konform über flache Win32-Aufrufe (kein COM):
* `kernel32.dll::Beep(Frequenz, Dauer)` via `ccall`, in `@async` gelegt, damit das Absenden nicht blockiert wird — oder
* `winmm.dll::PlaySound` mit `SND_ASYNC` für klanglich unterscheidbare WAV-Signale.

Drei semantische Töne:
* **Start-Ton:** „Anfrage verstanden, arbeite." (allererste Aktion im Hotkey-Handler)
* **Fertig-Ton:** anders klingend, kündigt die Ausgabe an.
* **Fehler-Ton:** klar negativ (tiefer / zwei kurze), unterscheidbar von „fertig".

---

## 8. Mögliche Zukunfts-Features (Backlog)

Diese Funktionen sind nicht Teil der Kern-Meilensteine, lassen sich aber sinnvoll ergänzen, sobald die Basis (M1–M4) steht.

### Interaktion & Nutzbarkeit
* **Frage-Antwort-Modus:** Folgefrage zum selben Screenshot stellen („Wo ist der OK-Button?", „Welcher Fehler steht da?") ohne neuen Screenshot.
* **Wiederholungsfunktion:** letzte Beschreibung erneut vorlesen.
* **Region-of-Interest:** nur das aktive Fenster statt des gesamten Bildschirms erfassen — reduziert Datenmenge und Datenschutzrisiko zugleich.
* **OCR-Fokusmodus:** gezieltes Vorlesen reinen Bildschirmtextes ohne LLM-Umweg (schneller, lokaler).
* **Hotword-/Sprach-Trigger** als Alternative zum Tastatur-Hotkey.

### Ausgabe & Barrierefreiheit
* **Braille-Zeilen-Ausgabe** zusätzlich zur Sprache.
* **Konfigurierbare Tonsignale** (Frequenz, Dauer, Lautstärke).
* **Mehrsprachigkeit / Sprachumschaltung** des Antwort-Prompts.
* **Barrierefreie Konfigurations-GUI** für alle Einstellungen.

### Backend & Architektur
* **Modell-Profile:** Umschalten zwischen „schnell/günstig" und „gründlich".
* **Plugin-System** für weitere Screenreader- und TTS-Backends.
* **Lokales Caching** identischer Screenshots zur Vermeidung doppelter Inferenz.
* **Automatischer Kontext-Trigger:** optionale Kurzbeschreibung bei Fensterwechsel.

### Datenschutz & Vertrauen
* **Sensitivitätsfilter:** Erkennung potenziell sensibler Inhalte (z. B. Passwortfelder) vor einem Cloud-Versand, mit Warnung oder Blockade.
* **Lokales Audit-Log:** transparent protokollieren, welche Daten wann wohin gingen — telemetriefrei.

---

## 9. Offene Entscheidungen
* **Lizenz festlegen:** GPL v3 (Copyleft, schützt Offenheit) vs. MIT (maximale Wiederverwendbarkeit) — früh entscheiden, da es Beiträge und Wiederverwendung prägt.
* **Standard-Hotkey** so wählen, dass er nicht mit gängigen JAWS-/NVDA-Belegungen kollidiert (und konfigurierbar bleiben).
* **Sprachwahl Julia:** bewusst getroffen; die COM-Schicht bleibt der Reibungspunkt. Bei wachsender Komplexität der COM-Anbindung später evaluieren, ob C# (native COM/UIAutomation/Win32) den Wartungsaufwand senkt.
