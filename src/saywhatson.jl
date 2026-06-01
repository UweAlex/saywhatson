# src/saywhatson.jl — SayWhatsOn, Meilenstein 3 (Hotkey + Aufnahme + Sprache + Editor + Systemkontext + Fensterliste)
#
# 📍 ORT IN DER PROJEKTARCHITEKTUR:
#   Eingabe:       Strg+Druck → Screenshot + Systemkontext + Fensterliste;  Umschalt+Druck → letzte Beschreibung lesen
#   Verarbeitung:  Kontext + Screenshot → austauschbares Vision-LLM-Backend → Text
#   Ausgabe:       SAPI-Sprachausgabe + Konsole (zentral: `ausgeben`); optional Editor (JAWS)
#   Verantwortlichkeiten:
#     - Zwei globale Hotkeys registrieren UND konsumieren (RegisterHotKey)
#     - Bildschirm aufnehmen; Systemstatus (Feststelltaste, Akku, Internet) und die
#       Liste ALLER offenen Fenster (auch verdeckte/minimierte) sammeln; beides ans Modell geben
#     - Letzte Beschreibung auf Wunsch im Editor zum Navigieren oeffnen; Fokus zurueck
#     - Das Modell entscheidet selbst, welche Kontextfakten erwaehnenswert sind
#     - NICHT zuständig: echter UI-Fokus innerhalb des Fensters via UIAutomation (M4)
#
# WINDOWS-ONLY. Einrichtung:
#   julia -e 'using Pkg; Pkg.add(["HTTP","JSON3"])'
#   set GEMINI_API_KEY=dein_key     (oder dauerhaft via setx, dann neues Fenster)
#   julia src/saywhatson.jl
# Bedienung:
#   Strg+Druck     -> Bildschirm beschreiben und vorlesen
#   Umschalt+Druck -> letzte Beschreibung im Editor oeffnen (mit JAWS lesbar); Fokus zurueck
#   Strg+C         -> beenden

using HTTP, JSON3, Base64

# ----------------------------- Konfiguration ---------------------------------
const MOD_CONTROL::Cuint        = 0x0002
const MOD_SHIFT::Cuint          = 0x0004
const MOD_NOREPEAT::Cuint       = 0x4000
const VK_SNAPSHOT::Cuint        = 0x2c       # Druck-Taste (Print Screen)
const VK_CAPITAL::Cint          = 0x14       # Feststelltaste
const VK_NUMLOCK::Cint          = 0x90       # Nummernblock
const WM_HOTKEY::Cuint          = 0x0312
const PM_REMOVE::Cuint          = 0x0001
const HOTKEY_BESCHREIBEN::Cint  = 1          # Strg+Druck
const HOTKEY_EDITOR::Cint       = 2          # Umschalt+Druck
const LOOP_SLEEP::Float64       = 0.02
const SPEECH_RATE::Int          = -1         # etwas langsamer = besser verstaendlich

# Win32-Konstanten fuer die Fensteraufzaehlung
const GW_HWNDNEXT::Cuint        = 2
const GW_OWNER::Cuint           = 4
const GWL_EXSTYLE::Cint         = -20
const WS_EX_TOOLWINDOW::Int     = 0x00000080
const DWMWA_CLOAKED::Cuint      = 14         # DwmGetWindowAttribute: Fenster „cloaked" (Phantom)
const MAX_FENSTER::Int          = 12         # Liste begrenzen, damit es knapp bleibt

const LETZTE_BESCHREIBUNG = Ref{String}("")  # fuer das Lesen im Editor

const PROMPT::String = """
Du bist die Augen eines blinden Computernutzers. Er sieht den Bildschirm nicht und hat gerade eine Taste gedrückt, weil er sich vermutlich nicht mehr sicher ist, wo er gerade ist. Es kann gut sein, dass unerwartet ein Fenster oder Dialog aufgetaucht ist und den Fokus übernommen hat, während er glaubt, noch in einem anderen Programm zu sein. Geh nicht davon aus, dass seine Annahme stimmt. Liefere keine neutrale Bildbeschreibung, sondern eine Orientierungshilfe zum Handeln und Navigieren.

Regeln:
- Antworte auf Deutsch in klar gesprochener Sprache, die ein Screenreader vorlesen kann. Verwende keinerlei Formatierung: keine Sternchen, keine Aufzählungszeichen, keine Überschriften, kein Markdown. Nur kurze, fließende Sätze.
- Dir wird zusätzlich der aktuelle Systemstatus mitgegeben, etwa Feststelltaste, Akku und Internetverbindung. Erwähne davon nur, was gerade wichtig ist: Warne deutlich und am Anfang, wenn die Feststelltaste an ist, oder wenn der Akku niedrig ist oder keine Internetverbindung besteht. Ist nichts davon auffällig, lass den Systemstatus ganz weg.
- Dir wird außerdem eine vom Betriebssystem ausgelesene Liste aller offenen Fenster mitgegeben, von vorne nach hinten geordnet, mit Vermerk, welches im Vordergrund ist und welche minimiert oder verdeckt sind. Nutze sie doppelt: Erstens benenne die sichtbaren Fenster mit ihrem echten Titel aus dieser Liste, statt den Namen aus dem Bild zu raten. Zweitens weise den Nutzer kurz auf geöffnete Fenster hin, die verdeckt oder minimiert und daher im Bild nicht zu sehen sind, damit er weiß, was sonst noch offen ist. Über den Inhalt verdeckter Fenster darfst du nichts erfinden, nenne dort nur den Titel.
- Englische Beschriftungen, Knopftexte und Begriffe vom Bildschirm gibst du wörtlich wieder, wie sie dort stehen (zum Beispiel Settings, Submit, Download). Übersetze sie nicht, denn der Nutzer muss genau diese Aufschrift wiederfinden.
- Beginne danach mit dem, was gerade den Fokus hat, also wohin seine Eingaben und ein Druck auf Enter gehen. Hat ein Dialog oder Pop-up den Fokus an sich gerissen, sage das zuerst und deutlich und nenne, wie er es schließt oder verlässt, um zu seiner Aufgabe zurückzukehren.
- Beschreibe danach die Hauptanwendung, in der er arbeiten will, nach ihren navigierbaren Bereichen, etwa Ordnerliste, Nachrichtenliste, Lesebereich, Symbolleiste. Nenne in jedem Bereich die wichtigsten sichtbaren Elemente beim Namen, ohne jeden einzelnen Eintrag vorzulesen.
- Gib konkrete Navigationshinweise, wie er dorthin gelangt und sich zwischen den Bereichen bewegt. Bevorzuge verlässliche Tastenkürzel und das Anspringen benannter Bereiche, etwa mit F6 zwischen den Hauptbereichen zu wechseln, statt unzuverlässiger Angaben wie einer festen Anzahl Tab-Drücke. Wenn du ein Tastenkürzel nicht sicher weißt, sag das ehrlich, statt zu raten.
- Weise auf alles hin, das eine Reaktion braucht, etwa Fehlermeldungen, Eingabeaufforderungen oder Passwortfelder.
- Lass reine Dekoration weg, etwa Desktop-Symbole oder Uhrzeit, solange sie für die nächste Handlung nicht wichtig ist.
- Fasse dich so knapp wie möglich, aber opfere die Orientierung und die Navigationshilfe nicht der Kürze.
"""

# ------------------- Akustisches Feedback (Win32 Beep, kein COM) --------------
beep(freq::Integer, dur::Integer) =
    (ccall((:Beep, "kernel32"), Cint, (Cuint, Cuint), UInt32(freq), UInt32(dur)); nothing)
beep_start() = beep(880, 120)                                   # "verstanden, arbeite"
beep_ready() = beep(1320, 90)                                   # "Antwort kommt"
beep_error() = (beep(330, 160); sleep(0.05); beep(330, 160))    # "Fehler"

# ------------------------------- Systemkontext (flache Win32-ccalls) ----------
"""
    systemkontext() -> String

📤 AUSGABE: kurze Faktenliste (Feststelltaste, Nummernblock, Akku, Internet);
            leerer String auf Nicht-Windows. Bewertet NICHTS — das Modell filtert.
"""
function systemkontext()::String
    Sys.iswindows() || return ""
    teile = String[]

    caps = (ccall((:GetKeyState, "user32"), Cshort, (Cint,), VK_CAPITAL) & 1) != 0
    num  = (ccall((:GetKeyState, "user32"), Cshort, (Cint,), VK_NUMLOCK) & 1) != 0
    push!(teile, "Feststelltaste " * (caps ? "an" : "aus"))
    push!(teile, "Nummernblock " * (num ? "an" : "aus"))

    buf = zeros(UInt8, 12)   # SYSTEM_POWER_STATUS
    if ccall((:GetSystemPowerStatus, "kernel32"), Cint, (Ptr{UInt8},), buf) != 0
        ac  = buf[1]         # ACLineStatus: 0 Akku, 1 Netz, 255 unbekannt
        pct = buf[3]         # BatteryLifePercent: 0..100, 255 unbekannt
        akku = pct == 0xff ? "" : "Akku $(Int(pct)) Prozent"
        netz = ac == 0x01 ? "am Netz" : (ac == 0x00 ? "im Akkubetrieb" : "")
        s = strip(join(filter(!isempty, [akku, netz]), ", "))
        isempty(s) || push!(teile, s)
    end

    flags = Ref{Cuint}(0)
    online = ccall((:InternetGetConnectedState, "wininet"), Cint,
                   (Ptr{Cuint}, Cuint), flags, 0) != 0
    push!(teile, online ? "Internet verbunden" : "Internet nicht verbunden")

    return join(teile, ", ")
end

# ------------------------------- Fensterliste (flache Win32-ccalls) -----------
"""
    fenstertitel(h, maxlen) -> String

Liest den Fenstertitel zum Handle `h` (GetWindowTextW) in einen UTF-16-Puffer.
"""
function fenstertitel(h::Ptr{Cvoid}, maxlen::Int)::String
    buf = Vector{UInt16}(undef, maxlen)
    n = ccall((:GetWindowTextW, "user32"), Cint,
              (Ptr{Cvoid}, Ptr{UInt16}, Cint), h, buf, Cint(maxlen))
    return n > 0 ? transcode(String, buf[1:n]) : ""
end

"""
    klassenname(h) -> String

Liest den Fensterklassennamen zum Handle `h` (GetClassNameW).
"""
function klassenname(h::Ptr{Cvoid})::String
    buf = Vector{UInt16}(undef, 256)
    n = ccall((:GetClassNameW, "user32"), Cint,
              (Ptr{Cvoid}, Ptr{UInt16}, Cint), h, buf, Cint(256))
    return n > 0 ? transcode(String, buf[1:n]) : ""
end

"""
    ist_cloaked(h) -> Bool

Prueft via DwmGetWindowAttribute, ob ein Fenster „cloaked" ist — ein unsichtbares
Phantom-Fenster wie die Windows-Eingabeerfahrung. Solche werden ausgelassen.
"""
function ist_cloaked(h::Ptr{Cvoid})::Bool
    cloaked = Ref{Cint}(0)
    hr = ccall((:DwmGetWindowAttribute, "dwmapi"), Clong,
               (Ptr{Cvoid}, Cuint, Ptr{Cint}, Cuint),
               h, DWMWA_CLOAKED, cloaked, Cuint(sizeof(Cint)))
    return hr == 0 && cloaked[] != 0
end

"""
    offene_fenster() -> String

📤 AUSGABE: Liste der offenen Anwendungsfenster von vorne nach hinten (Z-Reihenfolge),
            je mit Titel und Vermerk (im Vordergrund / minimiert / im Hintergrund).

🔄 LOGIK & NEBENEFFEKTE:
  - Laeuft die Top-Level-Fenster ueber GetTopWindow + GetWindow(GW_HWNDNEXT) ab
    (kein @cfunction-Callback noetig).
  - Behaelt nur „echte" Anwendungsfenster: mit Titel, ohne Owner, kein Tool-Fenster,
    sichtbar ODER minimiert. Desktop/Shell (Progman, WorkerW) wird uebersprungen.
  - Ein verdecktes Fenster gilt weiterhin als sichtbar (IsWindowVisible), wird also
    mit aufgenommen — genau das, was im Screenshot fehlt.
"""
function offene_fenster()::String
    Sys.iswindows() || return ""
    vordergrund = ccall((:GetForegroundWindow, "user32"), Ptr{Cvoid}, ())
    eintraege = String[]
    h = ccall((:GetTopWindow, "user32"), Ptr{Cvoid}, (Ptr{Cvoid},), C_NULL)
    schritte = 0
    while h != C_NULL && length(eintraege) < MAX_FENSTER && schritte < 1000
        schritte += 1
        weiter() = ccall((:GetWindow, "user32"), Ptr{Cvoid}, (Ptr{Cvoid}, Cuint), h, GW_HWNDNEXT)

        len = ccall((:GetWindowTextLengthW, "user32"), Cint, (Ptr{Cvoid},), h)
        if len <= 0
            h = weiter(); continue
        end
        owner = ccall((:GetWindow, "user32"), Ptr{Cvoid}, (Ptr{Cvoid}, Cuint), h, GW_OWNER)
        exstyle = ccall((:GetWindowLongPtrW, "user32"), Int, (Ptr{Cvoid}, Cint), h, GWL_EXSTYLE)
        sichtbar  = ccall((:IsWindowVisible, "user32"), Cint, (Ptr{Cvoid},), h) != 0
        minimiert = ccall((:IsIconic, "user32"), Cint, (Ptr{Cvoid},), h) != 0
        if owner != C_NULL || (exstyle & WS_EX_TOOLWINDOW) != 0 || !(sichtbar || minimiert)
            h = weiter(); continue
        end
        klasse = klassenname(h)
        # Desktop/Shell sowie Phantom-System-Fenster (z.B. Windows-Eingabeerfahrung,
        # DWM Notification Window) ueberspringen
        if klasse in ("Progman", "WorkerW", "Dwm") || ist_cloaked(h)
            h = weiter(); continue
        end
        titel = strip(fenstertitel(h, len + 1))
        if !isempty(titel)
            marke = h == vordergrund ? " (im Vordergrund)" :
                    minimiert         ? " (minimiert)" :
                                        " (im Hintergrund, evtl. verdeckt)"
            push!(eintraege, titel * marke)
        end
        h = weiter()
    end
    return join(eintraege, "; ")
end

"""
    kontext_sammeln() -> String

Buendelt Systemstatus und Fensterliste zu einem beschrifteten Kontextblock fuers Modell.
"""
function kontext_sammeln()::String
    teile = String[]
    s = systemkontext(); isempty(s) || push!(teile, "Systemstatus: " * s)
    f = offene_fenster(); isempty(f) || push!(teile, "Offene Fenster (von vorne nach hinten): " * f)
    return join(teile, "\n")
end

# ------------------------------- Bildschirmaufnahme ---------------------------
"""
    screen_png() -> Union{Vector{UInt8}, Nothing}

Nimmt den primaeren Bildschirm ueber PowerShell auf und liefert PNG-Bytes (oder nothing).
"""
function screen_png()::Union{Vector{UInt8},Nothing}
    tmp = joinpath(tempdir(), "saywhatson_screen.png")
    isfile(tmp) && rm(tmp; force=true)
    ps = """
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    \$bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    \$bmp = New-Object System.Drawing.Bitmap \$bounds.Width, \$bounds.Height
    \$g = [System.Drawing.Graphics]::FromImage(\$bmp)
    \$g.CopyFromScreen(\$bounds.X, \$bounds.Y, 0, 0, \$bmp.Size)
    \$bmp.Save('$tmp', [System.Drawing.Imaging.ImageFormat]::Png)
    \$g.Dispose(); \$bmp.Dispose()
    Write-Output 'OK'
    """
    out = try
        read(`powershell -NoProfile -Command $ps`, String)
    catch e
        @error "Screenshot fehlgeschlagen" exception = e
        return nothing
    end
    (occursin("OK", out) && isfile(tmp)) || return nothing
    return read(tmp)
end

# ------------------- Sprachausgabe (SAPI, uebernommen aus KI.jl) --------------
"""
    clean_for_speech(text::AbstractString) -> String

Markdown entfernen, Einheiten ausschreiben, Dezimalpunkt zu Komma,
PowerShell-Sonderzeichen entschaerfen.
"""
function clean_for_speech(text::AbstractString)::String
    text = String(text)
    text = replace(text, r"^#+\s*"m => "")
    text = replace(text, r"\*\*" => "")
    text = replace(text, r"__" => "")
    text = replace(text, r"\*" => "")
    text = replace(text, r"_" => "")
    text = replace(text, "`" => "")
    text = replace(text, r"\[([^\]]+)\]\([^\)]+\)" => s"\1")
    text = replace(text, r"\|" => " ")
    text = replace(text, r"\n+" => " ")
    text = replace(text, "g/cm³" => " Gramm pro Kubikzentimeter ")
    text = replace(text, "kg/m³" => " Kilogramm pro Kubikmeter ")
    text = replace(text, "km/h" => " Kilometer pro Stunde ")
    text = replace(text, "m/s" => " Meter pro Sekunde ")
    text = replace(text, "°C" => " Grad Celsius ")
    text = replace(text, "°F" => " Grad Fahrenheit ")
    text = replace(text, r"(\d)\s*K\b" => s"\1 Kelvin")
    text = replace(text, "m²" => " Quadratmeter ")
    text = replace(text, "m³" => " Kubikmeter ")
    text = replace(text, " Hz" => " Hertz")
    text = replace(text, " kHz" => " Kilohertz")
    text = replace(text, " MHz" => " Megahertz")
    text = replace(text, "%" => " Prozent ")
    text = replace(text, r"(\d)\.(\d)" => s"\1,\2")
    text = replace(text, "'" => "''")
    text = replace(text, "\$" => "")
    text = replace(text, "\"" => "")
    return strip(text)
end

"""
    speak(text::AbstractString) -> Nothing

Liest `text` ueber System.Speech (SAPI) vor, etwas langsamer (SPEECH_RATE).
Blockiert bis zum Ende; Escape bricht ab, sofern die Konsole den Fokus hat.
"""
function speak(text::AbstractString)::Nothing
    cleaned = clean_for_speech(text)
    isempty(cleaned) && return nothing
    if !Sys.iswindows()
        println("[Sprachausgabe nur unter Windows] $cleaned")
        return nothing
    end
    tpath = joinpath(tempdir(), "saywhatson_speech.txt")
    try
        open(tpath, "w") do f
            write(f, cleaned)
        end
    catch e
        @error "Konnte Sprachtext nicht schreiben" exception = e
        return nothing
    end
    ps = """
    Add-Type -AssemblyName System.Speech
    \$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
    \$s.Rate = $SPEECH_RATE
    \$s.Volume = 100
    \$s.SpeakAsync((Get-Content '$tpath' -Raw -Encoding UTF8)) | Out-Null
    while (\$s.State -eq 'Speaking') {
        if ([Console]::KeyAvailable) {
            if ([Console]::ReadKey(\$true).Key -eq 'Escape') {
                \$s.SpeakAsyncCancelAll()
                break
            }
        }
        Start-Sleep -Milliseconds 100
    }
    """
    try
        run(`powershell -NoProfile -ExecutionPolicy Bypass -Command $ps`)
    catch e
        @error "Sprachausgabe fehlgeschlagen" exception = e
    end
    return nothing
end

# ------------------- Editor-Anzeige mit Fokus-Rueckgabe (Notepad) -------------
"""
    fokus_zuruecksetzen(hwnd::Ptr{Cvoid}) -> Nothing

Holt das Fenster `hwnd` wieder in den Vordergrund (Anhaengen an dessen
Eingabe-Thread, um die Vordergrundsperre zu umgehen).
"""
function fokus_zuruecksetzen(hwnd::Ptr{Cvoid})::Nothing
    hwnd == C_NULL && return nothing
    eigener = ccall((:GetCurrentThreadId, "kernel32"), Cuint, ())
    ziel = ccall((:GetWindowThreadProcessId, "user32"), Cuint,
                 (Ptr{Cvoid}, Ptr{Cuint}), hwnd, C_NULL)
    if ziel != 0 && ziel != eigener
        ccall((:AttachThreadInput, "user32"), Cint, (Cuint, Cuint, Cint), eigener, ziel, 1)
        ccall((:SetForegroundWindow, "user32"), Cint, (Ptr{Cvoid},), hwnd)
        ccall((:AttachThreadInput, "user32"), Cint, (Cuint, Cuint, Cint), eigener, ziel, 0)
    else
        ccall((:SetForegroundWindow, "user32"), Cint, (Ptr{Cvoid},), hwnd)
    end
    return nothing
end

"""
    im_editor_oeffnen(text::AbstractString) -> Nothing

Merkt sich das aktive Fenster, schreibt `text` in eine Datei, oeffnet sie in
Notepad (blockiert bis zum Schliessen) und gibt den Fokus danach zurueck.
"""
function im_editor_oeffnen(text::AbstractString)::Nothing
    if isempty(strip(text))
        ausgeben("Es gibt noch keine Beschreibung zum Lesen. Bitte zuerst Strg und Druck drücken.")
        return nothing
    end
    vorheriges = ccall((:GetForegroundWindow, "user32"), Ptr{Cvoid}, ())
    tpath = joinpath(tempdir(), "saywhatson_text.txt")
    try
        open(tpath, "w") do f
            write(f, strip(text))
        end
    catch e
        @error "Konnte Editortext nicht schreiben" exception = e
        return nothing
    end
    try
        run(`notepad $tpath`)            # blockiert, bis Notepad geschlossen wird
    catch e
        @error "Editor konnte nicht geoeffnet werden" exception = e
    end
    fokus_zuruecksetzen(vorheriges)
    return nothing
end

# ----------------- Backend-Abstraktion (Strategy-Pattern) ---------------------
abstract type ImageBackend end

struct GeminiBackend <: ImageBackend
    model::String
    apikey::String
end
GeminiBackend(; model::String = "gemini-2.5-flash") =
    GeminiBackend(model, get(ENV, "GEMINI_API_KEY", get(ENV, "GOOGLE_API_KEY", "")))

"""
    beschreibe_bild(b::GeminiBackend, png::Vector{UInt8}, kontext::AbstractString="") -> String

Sendet Betriebssystem-Kontext (optional) + Bild an Gemini (Cloud) und liefert die
deutsche Orientierungsbeschreibung. Keine automatische Wiederholung.
"""
function beschreibe_bild(b::GeminiBackend, png::Vector{UInt8}, kontext::AbstractString="")::String
    isempty(b.apikey) && error("GEMINI_API_KEY ist nicht gesetzt.")
    url = "https://generativelanguage.googleapis.com/v1beta/models/$(b.model):generateContent?key=$(b.apikey)"
    parts = Any[Dict("text" => PROMPT)]
    isempty(strip(kontext)) ||
        push!(parts, Dict("text" => "Zusätzliche Fakten vom Betriebssystem:\n" * kontext))
    push!(parts, Dict("inline_data" => Dict("mime_type" => "image/png",
                                            "data" => base64encode(png))))
    body  = Dict("contents" => [Dict("parts" => parts)])
    resp  = HTTP.post(url, ["Content-Type" => "application/json"], JSON3.write(body))
    j     = JSON3.read(resp.body)
    teile = j.candidates[1].content.parts
    return join((haskey(p, :text) ? p.text : "" for p in teile), "")
end

struct OllamaBackend <: ImageBackend
    model::String
    host::String
end
OllamaBackend(; model::String = "llama3.2-vision", host::String = "http://localhost:11434") =
    OllamaBackend(model, host)

"""
    beschreibe_bild(b::OllamaBackend, png::Vector{UInt8}, kontext::AbstractString="") -> String

Wie die Gemini-Variante, aber gegen eine lokale Ollama-Instanz (kein Datenabfluss).
"""
function beschreibe_bild(b::OllamaBackend, png::Vector{UInt8}, kontext::AbstractString="")::String
    voll = isempty(strip(kontext)) ? PROMPT :
           PROMPT * "\n\nZusätzliche Fakten vom Betriebssystem:\n" * kontext
    body = Dict("model" => b.model, "prompt" => voll,
                "images" => [base64encode(png)], "stream" => false)
    resp = HTTP.post("$(b.host)/api/generate",
                     ["Content-Type" => "application/json"], JSON3.write(body))
    return JSON3.read(resp.body).response
end

# ------------------- Ausgabe (zentral: Konsole + Sprache) ---------------------
function ausgeben(text::AbstractString)::Nothing
    println("\n===== SayWhatsOn =====")
    println(strip(text))
    println("======================\n")
    speak(text)
    return nothing
end

# --------------------------- Eine Anfrage verarbeiten -------------------------
"""
    verarbeite(backend::ImageBackend) -> Nothing

beep_start, Bildschirm aufnehmen, Kontext (Systemstatus + Fensterliste) sammeln,
beides beschreiben lassen, merken, beep_ready, sprechen. Fehler werden gesprochen.
"""
function verarbeite(backend::ImageBackend)::Nothing
    beep_start()
    png = screen_png()
    if png === nothing
        beep_error()
        ausgeben("Die Bildschirmaufnahme ist fehlgeschlagen. Bitte versuche es noch einmal.")
        return nothing
    end
    try
        text = beschreibe_bild(backend, png, kontext_sammeln())
        LETZTE_BESCHREIBUNG[] = text
        beep_ready()
        ausgeben(text)
    catch e
        beep_error()
        if e isa HTTP.Exceptions.StatusError
            meldung = if e.status in (429, 500, 502, 503, 504)
                "Der Bilddienst ist gerade überlastet. Bitte versuche es in ein paar Sekunden noch einmal mit Strg und Druck."
            elseif e.status in (400, 401, 403)
                "Zugriff verweigert. Das liegt wahrscheinlich am API-Schlüssel oder am Kontingent; ein erneuter Versuch hilft hier nicht."
            else
                "Der Bilddienst meldet einen Fehler mit der Nummer $(e.status). Bitte versuche es später noch einmal."
            end
            ausgeben(meldung)
        else
            ausgeben("Es gab einen unerwarteten Fehler. Bitte versuche es noch einmal.")
            @error "Technischer Fehler" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

# ---------------- Hotkey-Schleife (RegisterHotKey + PeekMessage) --------------
"""
    hotkey_loop(on_hotkey) -> Nothing

Pollt die Nachrichten-Warteschlange. Bei WM_HOTKEY wird die Hotkey-ID aus dem
wParam-Feld der MSG gelesen (Offset 16) und `on_hotkey(id)` aufgerufen.
"""
function hotkey_loop(on_hotkey)::Nothing
    msg = Vector{UInt8}(undef, 64)
    GC.@preserve msg begin
        p = pointer(msg)
        while true
            got = ccall((:PeekMessageW, "user32"), Cint,
                        (Ptr{Cvoid}, Ptr{Cvoid}, Cuint, Cuint, Cuint),
                        p, C_NULL, 0, 0, PM_REMOVE)
            if got != 0
                message = unsafe_load(Ptr{Cuint}(p + 8))    # MSG.message
                if message == WM_HOTKEY
                    id = unsafe_load(Ptr{UInt}(p + 16))      # MSG.wParam = Hotkey-ID
                    on_hotkey(Int(id))
                end
            else
                sleep(LOOP_SLEEP)
            end
        end
    end
    return nothing
end

# --------------------------------- Einstieg -----------------------------------
"""
    main(; backend::ImageBackend = GeminiBackend()) -> Nothing

Registriert Strg+Druck (beschreiben) und Umschalt+Druck (Editor), laeuft bis
Strg+C und gibt beide Hotkeys beim Beenden wieder frei.
"""
function main(; backend::ImageBackend = GeminiBackend())::Nothing
    ok1 = ccall((:RegisterHotKey, "user32"), Cint, (Ptr{Cvoid}, Cint, Cuint, Cuint),
                C_NULL, HOTKEY_BESCHREIBEN, MOD_CONTROL | MOD_NOREPEAT, VK_SNAPSHOT)
    ok2 = ccall((:RegisterHotKey, "user32"), Cint, (Ptr{Cvoid}, Cint, Cuint, Cuint),
                C_NULL, HOTKEY_EDITOR, MOD_SHIFT | MOD_NOREPEAT, VK_SNAPSHOT)
    ok1 == 0 && error("RegisterHotKey (Strg+Druck) fehlgeschlagen — schon belegt?")
    ok2 == 0 && @warn "RegisterHotKey (Umschalt+Druck) fehlgeschlagen — Editor-Taste nicht verfuegbar."
    try
        println("SayWhatsOn laeuft.")
        println("  Strg+Druck     = Bildschirm beschreiben und vorlesen")
        println("  Umschalt+Druck = letzte Beschreibung im Editor lesen")
        println("  Strg+C         = beenden")
        if backend isa GeminiBackend && isempty(backend.apikey)
            @warn "GEMINI_API_KEY ist nicht gesetzt — bitte vor dem ersten Ausloesen setzen."
        end
        hotkey_loop() do id
            if id == Int(HOTKEY_BESCHREIBEN)
                verarbeite(backend)
            elseif id == Int(HOTKEY_EDITOR)
                im_editor_oeffnen(LETZTE_BESCHREIBUNG[])
            end
        end
    finally
        ccall((:UnregisterHotKey, "user32"), Cint, (Ptr{Cvoid}, Cint), C_NULL, HOTKEY_BESCHREIBEN)
        ccall((:UnregisterHotKey, "user32"), Cint, (Ptr{Cvoid}, Cint), C_NULL, HOTKEY_EDITOR)
    end
    return nothing
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
    # Fuer den lokalen Weg spaeter:  main(backend = OllamaBackend())
end
