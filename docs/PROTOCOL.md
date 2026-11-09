# iMac-Display – Architektur & Schnittstellen (verbindlich für alle Teile)

## Überblick

> Stand: Der iMac nutzt die native App „iMac Display Empfänger“ (Receiver/, AVSampleBufferDisplayLayer)
> statt Chrome – Chrome lässt sich auf Monterey nicht mehr installieren. Das Wire-Protokoll ist unverändert;
> `Resources/index.html` (WebCodecs) bleibt als Browser-Player für Tests. Abschnitte zu Chrome/Secure Context
> unten sind historisch.

```
MacBook (macOS 13+, hier 26.5, Apple Silicon)                 iMac 4K 21.5" (Monterey)
┌───────────────────────────────────────────────┐             ┌───────────────────────────────┐
│ imac-display (Swift CLI)                      │  Ethernet   │ Chrome (Kiosk, eigenes Profil)│
│  VirtualDisplay  4096x2304 px (HiDPI 2048x1152)│  direkt     │  http://10.77.0.1:8080/       │
│  ScreenCapture   ScreenCaptureKit → NV12       │ 10.77.0.1   │  WebSocket /ws                │
│  H264Encoder     VideoToolbox HW, Annex B      │ ⇄ 10.77.0.2 │  WebCodecs VideoDecoder       │
│  StreamServer    HTTP + WebSocket :8080        │             │  → <canvas> 4096x2304, 1:1    │
└───────────────────────────────────────────────┘             └───────────────────────────────┘
```

- Netz: direktes Kabel, statische IPs **MacBook 10.77.0.1/24**, **iMac 10.77.0.2/24**, kein Router/Gateway
  (damit Wi-Fi Default-Route bleibt). Fallback: Link-Local 169.254.x.x.
- Server akzeptiert standardmäßig nur Verbindungen von Loopback, 10.77.0.0/24 und 169.254.0.0/16
  (Sicherheit: im Café-WLAN darf niemand den Bildschirm sehen). `--allow-any-network` hebt das auf.
- WebCodecs braucht einen Secure Context. `http://10.77.0.1:8080` ist keiner → der iMac-Launcher startet Chrome mit
  `--user-data-dir=<eigenes Profil> --unsafely-treat-insecure-origin-as-secure=http://10.77.0.1:8080`.
  `http://127.0.0.1:8080` (lokaler Test) ist automatisch secure.

## Dateien & Zuständigkeit

| Datei | Zuständig |
|---|---|
| `Package.swift`, `Sources/CGVirtualDisplayPrivate/*` | PM (fertig) |
| `Sources/imac-display/main.swift`, `VirtualDisplay.swift`, `ScreenCapture.swift`, `H264Encoder.swift` | Agent „Host“ |
| `Sources/imac-display/SPSRewriter.swift` | PM (Integration) |
| `Sources/imac-display/StreamServer.swift` | Agent „Server“ (API unten ist fix) |
| `Sources/imac-display/Resources/index.html` (eine einzige Datei, inline JS/CSS) | Agent „Web“ |
| `scripts/**`, `README.md` | Agent „Scripts“ |

## Swift-API `StreamServer` (fix – nicht ändern ohne PM)

```swift
final class StreamServer {
    struct Options {
        var port: UInt16 = 8080
        var allowAnyNetwork = false
    }
    /// Wird aufgerufen, wenn ein neuer WebSocket-Client verbunden ist (beliebiger Thread).
    var onClientConnected: (() -> Void)?
    /// Client hat {"type":"keyframe"} geschickt oder Server hat wegen Rückstau Frames verworfen (beliebiger Thread).
    var onKeyframeRequested: (() -> Void)?

    init(options: Options, indexHTML: Data)
    func start() throws
    func stop()
    /// JSON-Objekt (UTF-8) des Stream-Configs. Wird gespeichert, an alle aktuellen Clients gesendet
    /// und jedem neuen Client direkt nach dem Verbinden zuerst geschickt. Thread-safe.
    func setConfig(_ json: Data)
    /// Eine kodierte Access Unit (H.264 Annex B, bei Keyframes inkl. SPS/PPS). Thread-safe.
    func broadcastVideo(_ annexB: Data, isKeyframe: Bool, timestampUs: UInt64)
    var clientCount: Int { get }
}
```

HTTP-Routen: `GET /` und `GET /index.html` → indexHTML (`text/html; charset=utf-8`, `Cache-Control: no-store`),
`GET /ws` mit Upgrade → WebSocket, sonst 404.

## WebSocket-Wire-Protokoll

Server → Client: **nur Binary-Messages**, erstes Byte = Typ.

| Typ | Aufbau |
|---|---|
| `0x01` Config | `0x01` + UTF-8 JSON: `{"codec":"avc1.640033","width":4096,"height":2304,"fps":60}` |
| `0x02` Video | `0x02` + `flags` (1 Byte, Bit0 = Keyframe) + `timestampUs` (8 Byte, uint64 **big-endian**) + Annex-B-Daten |

- `codec` wird vom Encoder aus der echten SPS gebildet: `"avc1." + hex2(sps[1]) + hex2(sps[2]) + hex2(sps[3])`
  (sps = NAL ohne Startcode; NAL-Typ = `sps[0] & 0x1f == 7`, VideoToolbox liefert Header-Byte `0x27`).
- Die SPS wird vor dem Senden umgeschrieben (`SPSRewriter.swift`): VUI bekommt `bitstream_restriction` mit
  `max_num_reorder_frames = 0`. Ohne das puffert Chrome bis zu 16 Frames (~300 ms Latenz bei 4K).
- Annex B: jede NAL mit Startcode `00 00 00 01`. Keyframes beginnen mit SPS, PPS, dann IDR-Slices.
- Neuer Client bekommt immer zuerst die Config, dann erst ab dem nächsten Keyframe Video (Server verwirft vorher Deltas).

Client → Server: **Text-Messages** (JSON)

| Message | Wirkung |
|---|---|
| `{"type":"keyframe"}` | Server ruft `onKeyframeRequested` |
| `{"type":"stats", "fps":59.8, "decodeQueue":0, "dropped":0}` | optional, Server darf es loggen (max. 1×/5 s) |

Rückstau: Server zählt pro Client unbestätigte Bytes. Über 16 MB → Nicht-Keyframes für diesen Client verwerfen,
Client auf „wartet auf Keyframe“ setzen, `onKeyframeRequested` (max. 1×/s) aufrufen.

## Host-Verhalten (Kurzfassung)

- CLI: `imac-display [--width 4096] [--height 2304] [--fps 60] [--bitrate 100] (Mbit/s) [--port 8080] [--no-hidpi] [--allow-any-network] [--name "iMac 4K (Ethernet)"]`
- Virtuelles Display 4096×2304 Pixel, HiDPI → 2048×1152 Punkte (wie echter iMac 4K).
- Capture in Pixel-Auflösung, Cursor sichtbar, NV12.
- Encoder: H.264 HW, realtime, keine B-Frames, max. 1 Frame in Arbeit (neuester Frame gewinnt → ~19 ms Latenz;
  der M4-Pro-Encoder schafft bei 4096×2304 ca. 52–55 fps). Keyframe alle 5 s nur solange sich das Bild ändert,
  sonst nur auf Anfrage (neuer Client, Rückstau). Stillstand-Verfeinerung: 80 ms nach dem letzten Frame bis zu 12
  Frames mit 8× Bitrate (erster als IDR), bis ~60 dB → Text praktisch verlustfrei. 60 fps → `avc1.64003c` (Level 6.0),
  30 fps → `avc1.640034` (Level 5.2).
  Statischer Bildschirm liefert keine neuen Frames → letzten Pixelbuffer cachen und für den Keyframe neu kodieren.

## Erweiterung v2 (Steuerkanal, Verbinden-Knopf, Helligkeit) – verbindlich

### Server → Client: `0x03` Steuer-Nachricht (Binary)

`0x03` + UTF-8-JSON-Objekt mit Feld `"type"`. Unbekannte Typen ignorieren.

| type | Beispiel | Bedeutung |
|---|---|---|
| `status` | `{"type":"status","active":false,"autoReconnect":true}` | **dauerhaft** (sticky): jeder neue Client bekommt ihn direkt nach der Config, alle Clients alle **2 s** erneut (= Lebenszeichen, der Empfänger verbindet im Bereitschaftszustand also nicht neu). `active:true` = virtuelles Display aktiv, Video kommt. `active:false` = MacBook bereit, aber (noch) nicht verbunden → Empfänger zeigt Leerlauf mit „Jetzt verbinden“ + QR. `autoReconnect` = MacBook verbindet automatisch, sobald der iMac da ist (Info). |
| `brightness` | `{"type":"brightness","value":0.62}` | Helligkeit des iMac-Bildschirms setzen, 0.0 … 1.0. |

Server-API (`StreamServer`): `broadcastControl(_ object: [String: Any], sticky: Bool = false)`.

### Client → Server: Text-Nachrichten (zusätzlich)

| Nachricht | Wann | Server-API |
|---|---|---|
| `{"type":"hello","app":"receiver","version":"1.3"}` | direkt nach dem Verbinden | `onClientMessage(ip, json)` |
| `{"type":"brightness","supported":true,"value":0.62}` | nach dem Verbinden, nach jeder Änderung (auch über die iMac-Tasten, Abfrage alle 2 s), nach jedem Setzen | `onClientMessage(ip, json)` |

`supported:false` → MacBook zeigt den Helligkeitsregler deaktiviert mit Hinweis.

### Verbinden / automatisch wiederverbinden (MacBook)

- Neuer dauerhafter Wunsch-Zustand **„verbunden“** (UserDefaults `connectWanted`, Standard `false`).
- iMac-Client verbunden + Wunsch aus → **Bereitschaft**: kein virtuelles Display, `status active:false`; der große grüne Knopf leuchtet („Verbinden“), Menü „Jetzt verbinden“ aktiv.
- Klick „Verbinden“ → Wunsch an → virtuelles Display + Stream, `status active:true`.
- iMac weg (Kabel ab, iMac aus) → Display wird nach 10 s entfernt, Wunsch bleibt an → kommt der iMac wieder, wird **automatisch** wieder verbunden (auch nach Neustart der App).
- „Trennen“ → Wunsch aus → Display weg, iMac zeigt „Jetzt verbinden“.
