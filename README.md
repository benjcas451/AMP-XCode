# AMP Control

Native iOS-App (Swift, SwiftUI) zur Steuerung eines CubeCoders-AMP-Panels über dessen JSON-API.
Portierung der Flutter-App [AMP-Flutter](https://github.com/benjcas451/AMP-Flutter).

## Funktionen

- **Einstellungen**: Server-URL, Benutzer, Passwort – mit Verbindungstest, sicher gespeichert
  im iOS-Schlüsselbund
- **Instanzliste**: alle Instanzen des ADS mit Status, CPU/RAM/Spielern, Auto-Refresh
  - AMP-Instanzen direkt starten / stoppen, mit getrenntem Instanz- und Serverstatus
  - Bestätigung vor dem Instanzstopp; Aktionen bleiben bis zur Statusbestätigung gesperrt
- **Instanz-Details**
  - Übersicht: Serverstatus, Metriken, Server starten / stoppen / neustarten / Kill
  - Konsole: Live-Ausgabe, Befehle senden
  - Spieler: aktuell verbundene Benutzer
  - Backups, Dateien, Settings, Zeitplan, Ereignisse, Spielserver-Update – jeweils nur,
    wenn die AMP-Installation die zugehörige API-Methode anbietet

## Aufbau

```
AMPControl/
  AMPControlApp.swift            Einstiegspunkt
  API/AMPClient.swift            Login, Session-Handling, ADS-Proxy, alle API-Aufrufe
  API/Models.swift               Instanzen, Status, Metriken, Konsolenzeilen, …
  API/JSONValue.swift            lose typisiertes JSON der AMP-Antworten
  API/HTTPTransport.swift        Netzwerk-Schnittstelle (URLSession bzw. Fake im Test)
  Services/                      Schlüsselbund-Speicher, Sperrlogik für Instanzaktionen
  State/                         App-Zustand und View-Models (Observation)
  Views/                         SwiftUI-Oberfläche
AMPControlTests/                 Unit-Tests (Swift Testing) gegen ein Fake-AMP
AMPControlUITests/               UI-Tests (XCUITest) gegen einen lokalen Mock-AMP-Server
```

Instanzen werden über den ADS-Proxy angesprochen (`/API/ADSModule/Servers/<id>/API/...`),
die App braucht daher nur die URL des ADS (z. B. `http://192.168.1.10:8080`).
Die AMP-Instanzen selbst werden über `ADSModule/StartInstance` und
`ADSModule/StopInstance` gesteuert. Beim Stoppen einer Instanz wird auch ein darin
laufender Server beendet; der ADS-Controller selbst wird nicht in der Liste angezeigt.

## Bauen

Voraussetzungen: iOS 17 oder neuer; gebaut und getestet mit Xcode 26 (das Projektformat
setzt mindestens Xcode 16 voraus). Keine externen Abhängigkeiten.

`AMPControl.xcodeproj` in Xcode öffnen und starten, oder auf der Kommandozeile:

```bash
xcodebuild test -project AMPControl.xcodeproj -scheme AMPControl \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Bundle-ID: `de.tschapps.ampControl` (wie die iOS-Variante der Flutter-App; dort
gespeicherte Zugangsdaten werden deshalb weiterverwendet).

## Tests

Jeder Push und jeder Pull Request läuft durch den Workflow
[`.github/workflows/ci.yml`](.github/workflows/ci.yml) auf einem macOS-Runner: bauen,
Unit-Tests und UI-Tests im iOS-Simulator. Die Screenshots der UI-Tests hängen als
Artefakt `screenshots` am jeweiligen Lauf.

## Hinweise

- HTTP ist erlaubt (`NSAllowsArbitraryLoads`), damit das Panel im LAN funktioniert.
  Für Zugriff von unterwegs HTTPS (Reverse Proxy) oder ein VPN verwenden.
- Für die App am besten einen eigenen AMP-Benutzer mit passenden Rechten anlegen.
