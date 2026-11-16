# How TV Remote for Mac works

This is the long version of [How it works](../README.md#how-it-works) in the README. Everything here is taken from the code; file names point to where each part lives. The protocol layer is the Swift package `ItsytvCore`, which comes from [Itsytv](https://github.com/nickustinov/itsytv-macos); much of what it knows about the Apple TV was first documented by [pyatv](https://github.com/postlund/pyatv).

**Contents**

1. [The big picture](#1-the-big-picture)
2. [Finding the Apple TV](#2-finding-the-apple-tv)
3. [Pairing and connecting](#3-pairing-and-connecting)
4. [What goes over the wire](#4-what-goes-over-the-wire)
5. [Pressing a key](#5-pressing-a-key)
6. [Typing on the Apple TV](#6-typing-on-the-apple-tv)
7. [Now playing over the AirPlay tunnel](#7-now-playing-over-the-airplay-tunnel)
8. [Staying connected](#8-staying-connected)
9. [Message reference](#9-message-reference)
10. [Code map](#10-code-map)

## 1. The big picture

The Mac app is a thin UI on top of one object, `AppleTVManager`, which owns the connection and all state the UI shows. It talks to two services on the Apple TV: **Companion Link** for remote-control input, and **MediaRemote (MRP)** carried inside an **AirPlay** session for what's playing.

```mermaid
flowchart TB
    subgraph APP["Menu bar app: itsytv/"]
        direction TB
        SI["Status item and floating NSPanel<br/>AppController"]
        VIEW["Remote UI in SwiftUI<br/>MenuBarView, ComposeAwareTextField"]
        KEYS["Local key monitor<br/>RemoteShortcut table"]
        HOT["Global hotkeys, AppleScript, Shortcuts action"]
    end

    subgraph CORE["Protocol package: ItsytvCore/"]
        direction TB
        MGR["AppleTVManager<br/>lifecycle, queue, reconnects, text input"]
        DISC["DeviceDiscovery<br/>Bonjour browser"]
        COMP["CompanionConnection<br/>frames, OPACK, encryption"]
        CRYPTO["PairSetup and PairVerify<br/>SRP, Ed25519, X25519"]
        MRPM["MRPManager<br/>now playing, media commands"]
        TUN["AirPlayMRPTunnel<br/>control, event and data channels"]
    end

    subgraph STORE["Stored on the Mac"]
        KC[("Keychain<br/>pairing keys per Apple TV")]
        UD[("UserDefaults<br/>custom keys, app order, last device")]
    end

    subgraph ATV["Apple TV"]
        CLS["Companion Link service<br/>_companion-link._tcp"]
        APS["AirPlay service, port 7000<br/>MediaRemote inside"]
    end

    SI --> VIEW
    KEYS --> MGR
    VIEW --> MGR
    HOT --> MGR
    MGR --> DISC
    MGR --> COMP
    MGR --> CRYPTO
    MGR --> MRPM
    MRPM --> TUN
    CRYPTO -.-> KC
    MGR -.-> UD
    DISC -.->|"Bonjour browse"| CLS
    COMP <-->|"TCP, ChaCha20-Poly1305"| CLS
    TUN <-->|"TCP, HAP encryption"| APS
```

Two rules shape the code:

- **All manager state lives on the main thread.** Network callbacks arrive on background queues; `AppleTVManager.attach` hops every one of them to the main thread and drops callbacks from a link that has already been replaced, so a late "disconnected" from an old link can't tear down a new one.
- **Commands never go out on a half-ready link.** If the link isn't verified yet, a key press is queued and sent once the session is up (see [Staying connected](#8-staying-connected)).

## 2. Finding the Apple TV

`DeviceDiscovery` browses Bonjour for `_companion-link._tcp` services and reads each one's TXT record.

| Step | What the code does |
|---|---|
| Filter | Keeps only services whose `rpFl` flags include `0x4000`. HomePods, Macs and iPads advertise the same service without that flag. |
| Identify | Uses the Bonjour service name as the device ID (`rpBA` rotates for privacy). Pairing keys in the Keychain are stored under this ID. |
| Keep looking | Restarts the browser every 5 seconds to catch devices that were asleep or whose mDNS packets got lost. |
| Wake a sleeping TV | On refresh, opens a TCP connection to the last device on ports 3689, 7000, 49152 and 49153; a sleeping Apple TV then re-advertises its services. |
| Stop | Pauses browsing once a session is connected. |

## 3. Pairing and connecting

`CompanionConnection` opens TCP (`NWConnection`) straight to the Bonjour service, then one of two things happens.

- **No keys in the Keychain:** pair-setup. This is the only time you see a PIN.
- **Keys found:** pair-verify. Both sides prove they hold the keys from pairing and derive fresh session keys.

```mermaid
sequenceDiagram
    actor You
    participant Mac as AppleTVManager
    participant TV as Apple TV

    Mac->>TV: TCP connect to the Companion Link service

    alt First time: no keys in the Keychain
        Mac->>TV: pair-setup M1
        TV-->>Mac: M2 with SRP salt and public key
        Note over TV: Shows a 4-digit PIN
        Note over Mac: Status becomes pairing, the PIN pad appears
        You->>Mac: Type the PIN
        Mac->>TV: M3 with SRP proof built from the PIN
        TV-->>Mac: M4 with the TV's proof
        Mac->>TV: M5 with the Mac's Ed25519 identity, encrypted
        TV-->>Mac: M6 with the TV's identity
        Note over Mac: Keys saved to the Keychain
        Mac->>TV: Close and open a fresh TCP connection
    end

    Mac->>TV: pair-verify M1 with a one-time X25519 key
    TV-->>Mac: M2 with its key and a signed, encrypted proof
    Mac->>TV: M3 with the Mac's signed, encrypted proof
    TV-->>Mac: M4 done
    Note over Mac,TV: Session keys derived, every frame from now on is encrypted
    Note over Mac,TV: At the same time the AirPlay tunnel for now playing starts, see section 7

    Mac->>TV: _systemInfo (reply carries the tvOS version)
    Mac->>TV: _sessionStart
    TV-->>Mac: session ID
    Mac->>TV: _touchStart (1000 x 1000 virtual touchpad)
    Mac->>TV: _interest in _tiStarted and _tiStopped
    Mac->>TV: _tiStart (is a text field already open?)
    Mac->>TV: TVRCSessionStart
    TV-->>Mac: reply, or the Mac moves on after 2 s
    Note over Mac: Status becomes connected, queued keys are sent
    Mac->>TV: FetchLaunchableApplicationsEvent
    TV-->>Mac: installed apps
```

Details worth knowing:

- **Why a fresh connection after pairing.** A comment in `AppleTVManager` notes that tvOS 27 ignores pair-verify on the connection used for pair-setup and only closes it about 30 seconds later, so the app verifies on a new connection, as pyatv does.
- **Why `TVRCSessionStart`.** On tvOS 26.5 and later the TV silently drops the app-list request unless a TV-remote session is registered first. Older tvOS may not answer, so the app also moves on after 2 seconds.
- **Apple TV reset or replaced.** If pair-verify finds a different identity than the one stored, the app deletes the stale keys and starts pairing again by itself.
- **Local network access denied.** If macOS blocks local network access, the status says so and the connection keeps waiting; it continues on its own once you allow access.

## 4. What goes over the wire

Every Companion Link message is a frame:

```text
+----------+----------------------+--------------------------------------+
| type     | length               | payload                              |
| 1 byte   | 3 bytes, big-endian  | OPACK dictionary                     |
|          |                      | encrypted payload + 16-byte tag      |
+----------+----------------------+--------------------------------------+
```

- **OPACK** is Apple's compact binary encoding of dictionaries. Each message has `_t` (1 event, 2 request, 3 response), `_i` (the message name, such as `_hidC`), `_c` (content) and, for requests, `_x` (an ID that the response echoes back).
- **Encryption.** After pair-verify each direction has its own ChaCha20-Poly1305 key and its own nonce counter, starting at 0 and growing by one per frame. The 4-byte header is authenticated as additional data.
- **Why there's one lock.** Commands are sent from the main thread, from timers (button release, swipes) and from the 30-second keep-alive at the same time. If two frames were encrypted in one order and written in another, the Apple TV's nonce counter would be off and it would drop the link. `CompanionConnection` encrypts and hands the frame to the network inside one critical section, so nonce order always equals wire order.
- **One disconnect report.** A dropped link shows up both as a receive error and as a failed state; the connection reports it to the manager only once.

## 5. Pressing a key

Keys are caught by a local `NSEvent` monitor on the remote panel (`AppController`) and looked up in the `RemoteShortcut` table, which you can change in the Keyboard shortcuts window. A button is sent as `_hidC` with `_hBtS` 1 (down) and 2 (up).

```mermaid
sequenceDiagram
    actor You
    participant AC as AppController
    participant M as AppleTVManager
    participant TV as Apple TV

    Note over You,TV: Click keys: arrows, = and −
    You->>AC: key down ←
    AC->>M: pressButton(left)
    M->>TV: _hidC left, down
    M->>TV: _hidC left, up, 50 ms later
    Note right of AC: Key repeat sends more clicks, so holding an arrow scrolls

    Note over You,TV: Hold keys: Return, Esc, Delete, Space
    You->>AC: key down Esc
    AC->>M: pressDown(menu)
    M->>TV: _hidC menu, down
    You->>AC: key repeat
    Note right of AC: Swallowed
    You->>AC: key up Esc
    AC->>M: release(menu)
    M->>TV: _hidC menu, up
    Note over TV: tvOS decides: short press is Back, long press is the Home screen
```

- Because the button really stays down for as long as you hold the key, tvOS itself tells a click from a hold, exactly as with a Siri Remote. Hold Return for the context menu, Esc for the Home screen, Delete for Control Center.
- A held button is released after at most 8 seconds, or when the panel loses focus, so a lost key-up can't leave a button stuck down on the TV.
- Shortcuts with ⌘ (⌘K, ⌘F, ⌘W, ⇧⌘M) work even while the text field has focus; plain keys go to the field, except ↑ and ↓ (see below).
- Mute is not a Companion button: it goes over MediaRemote as a HID consumer-page mute key.

## 6. Typing on the Apple TV

The Apple TV tells subscribers when one of its text fields gets or loses focus, the same signal the iPhone remote uses to pop up its keyboard. Text travels in `_tiD` payloads: binary property lists in the format of `RTIKeyedArchiver`, Apple's private text-input classes, which `TextInputSession` builds and reads by hand.

```mermaid
sequenceDiagram
    actor You
    participant F as Mac text field
    participant M as AppleTVManager
    participant TV as Apple TV

    Note over M,TV: Once per connection
    M->>TV: _interest in _tiStarted and _tiStopped
    M->>TV: _tiStart
    TV-->>M: current field, if one is already focused

    Note over TV: You open Search, a login or a YouTube search
    TV-->>M: _tiStarted with session ID and the field's text
    M->>F: Open the field, fill it with that text
    You->>F: Type "star"
    F->>M: committed text "star"
    M->>TV: _tiC insert "star"
    You->>F: Delete one letter
    F->>M: committed text "sta"
    M->>TV: _tiC clear the field and insert "sta", in one event

    alt You press ↑ or ↓
        You->>F: Press ↑ or ↓
        F->>M: The key skips the field and goes to the remote
        M->>TV: _hidC up or down
    end
    Note over TV: Focus leaves the text field
    TV-->>M: _tiStopped
    M->>F: Close the field
```

How each piece works:

| Piece | Behaviour |
|---|---|
| Text already on the TV | `_tiStarted` carries the field's state. The app joins the text before the cursor, the selection and the text after it (`contextBeforeInput`, `selectedText`, `contextAfterInput`) and shows it in the Mac field with the cursor at the end. |
| Typing forward | If the new text starts with what was already sent, only the new characters go out as an insert. |
| Deleting or editing | Otherwise the app sends one event that clears the field and inserts the whole new text, so the TV never flashes an empty field. |
| Input methods | `ComposeAwareTextField` reports only committed text. Characters still being composed (Japanese, Chinese, Korean) are held back until you confirm them. |
| A new field on the TV | Each focused field gets a new session ID; the app always types into the latest one. |
| Opening the field by hand (⌘K) | The app restarts the text session (`_tiStop`, then `_tiStart`) to read the current field. The `_tiStopped` that its own restart may cause is ignored for 1.5 s, so the field doesn't close itself. |
| Leaving with ↑ / ↓ | While a TV field is focused, real ↑ and ↓ keys skip the one-line Mac field and move focus on the TV, which then sends `_tiStopped`. |

## 7. Now playing over the AirPlay tunnel

Now-playing data comes from MediaRemote (MRP), Apple's protobuf protocol, which the app reaches through an AirPlay 2 session on port 7000 of the same Apple TV. It reuses the keys from Companion pairing.

```mermaid
sequenceDiagram
    participant MRP as MRPManager
    participant T as AirPlayMRPTunnel
    participant TV as Apple TV, port 7000

    T->>TV: TCP connect
    T->>TV: POST /pair-verify with the stored keys
    Note over T,TV: Control channel switches to HAP encryption
    T->>TV: RTSP SETUP event channel
    T->>TV: connect event channel
    T->>TV: RTSP RECORD
    T->>TV: RTSP SETUP data channel
    T->>TV: connect data channel
    Note over T,TV: POST /feedback every 2 s keeps the session alive
    MRP->>TV: DEVICE_INFO
    MRP->>TV: SET_CONNECTION_STATE
    MRP->>TV: CLIENT_UPDATES_CONFIG
    MRP->>TV: PLAYBACK_QUEUE_REQUEST with 600 x 600 artwork
    TV-->>MRP: SET_STATE with title, progress, supported commands
    TV-->>MRP: UPDATE_CONTENT_ITEM when something changes
    Note over MRP,TV: A heartbeat message every 30 s
```

The remote's previous and next track buttons, seeking, AppleScript `play` and `pause`, and mute go over this tunnel. Everything else (d-pad, Select, Back, TV, Play/Pause button, volume buttons, apps, typing) goes over Companion Link. If the tunnel drops, the app retries it up to 3 times, a second apart; after that it disconnects.

## 8. Staying connected

The Apple TV closes the Companion Link from time to time, which is routine, and Wi-Fi drops happen. What the user sees as "connected" stays connected while the app quietly rebuilds the link underneath.

```mermaid
stateDiagram-v2
    [*] --> Disconnected
    Disconnected --> Connecting: you pick an Apple TV, or a key is pressed
    Connecting --> LocalNetworkDenied: macOS blocks local network access
    LocalNetworkDenied --> Connecting: you allow access
    Connecting --> Pairing: no stored keys, TV shows a PIN
    Pairing --> Connecting: paired, keys saved, fresh link
    Pairing --> Error: wrong PIN or pairing failed
    Connecting --> Connected: pair-verify and session start done
    Connecting --> Error: link failed and no keys stored

    Connected --> Rebuilding: Companion link closed
    Connecting --> Rebuilding: link failed, keys stored
    Rebuilding --> Waiting: attempt failed or took over 10 s
    Waiting --> Rebuilding: after 1, 2, 4 or 8 s
    Rebuilding --> Connected: pair-verify and session start done
    Waiting --> Disconnected: 5 failed attempts in a row

    Connected --> Disconnected: you close the remote, or AirPlay tunnel lost 3 times
    Error --> Connecting: try again
```

The rules, all in `AppleTVManager`:

| Rule | Value |
|---|---|
| First retry after a drop | immediately |
| Later retries | 1 s, 2 s, 4 s, then 8 s |
| Time limit per attempt | 10 s (an unreachable TV could otherwise keep the link waiting forever) |
| Give up after | 5 failed attempts in a row, then disconnect |
| Retry counter resets | when pair-verify succeeds |
| Status shown during a rebuild | stays "connected" (now playing still works over AirPlay) |
| Key presses during a rebuild | queued, sent in order once the new link is verified and the session started |
| Key presses while fully disconnected | queued, and the app reconnects to the last Apple TV on its own |

Here, "Rebuilding" and "Waiting" are internal: the status the UI shows is still `connected` (or `connecting` on the very first try), but `isCompanionReady` is false, so commands wait in the queue. A link is "ready" only when the status is connected, a link exists and no rebuild is running.

## 9. Message reference

**Companion Link frames**

| Frame | Purpose |
|---|---|
| pair-setup start / next | First pairing, M1 to M6 |
| pair-verify start / next | Every connection, M1 to M4 |
| encrypted OPACK | Every message after pair-verify |
| NoOp | Keep-alive every 30 s |

**Companion Link messages**

| Message | Kind | Direction | Purpose |
|---|---|---|---|
| `_systemInfo` | request | Mac → TV | Introduce the client; the reply's `_osV` is the tvOS version |
| `_sessionStart` | request | Mac → TV | Start a `com.apple.tvremoteservices` session |
| `_touchStart` | request | Mac → TV | Open a 1000 × 1000 virtual touchpad |
| `_interest` | event | Mac → TV | Subscribe to `_tiStarted` and `_tiStopped` |
| `TVRCSessionStart` | request | Mac → TV | Register a TV remote session (needed for the app list on tvOS 26.5+) |
| `FetchLaunchableApplicationsEvent` | request | Mac → TV | List installed apps (bundle ID and name) |
| `_launchApp` | request | Mac → TV | Open an app by bundle ID |
| `_hidC` | request | Mac → TV | Button down (`_hBtS` 1) or up (`_hBtS` 2) |
| `_hidT` | event | Mac → TV | Touch at x, y with phase press, hold or release (swipes, touchpad) |
| `_tiStart` | request | Mac → TV | Get the focused text field: session ID and current text |
| `_tiStop` | request | Mac → TV | End the current text session |
| `_tiC` | event | Mac → TV | Insert text, or clear and insert, in a text session |
| `_tiStarted` | event | TV → Mac | A text field got focus; carries session ID and text |
| `_tiStopped` | event | TV → Mac | The text field lost focus |

**MediaRemote messages (inside the AirPlay tunnel)**

| Message | Direction | Purpose |
|---|---|---|
| `DEVICE_INFO`, `SET_CONNECTION_STATE` | Mac → TV | Introduce the client |
| `CLIENT_UPDATES_CONFIG` | Mac → TV | Ask for now playing, artwork, volume, keyboard and output device updates |
| `PLAYBACK_QUEUE_REQUEST` | Mac → TV | Fetch the current item with 600 × 600 artwork |
| `SET_STATE`, `UPDATE_CONTENT_ITEM` | TV → Mac | Title, progress, artwork, supported commands |
| `SEND_COMMAND` | Mac → TV | Play, pause, previous, next, skip, seek |
| `SEND_HID_EVENT` | Mac → TV | Mute key, followed by a generic message to reset protocol state |
| `GENERIC_MESSAGE` | Mac → TV | Heartbeat every 30 s |

## 10. Code map

| Path | What's there |
|---|---|
| `itsytv/UI/AppController.swift` | Status item, floating panel, local key monitor, key holds, PIN pad |
| `itsytv/UI/MenuBarView.swift` | Remote UI; opens and closes the text field when the TV says so |
| `itsytv/UI/ComposeAwareTextField.swift` | Text field that understands input methods; cursor at the end |
| `itsytv/Shortcuts/RemoteShortcut.swift` | Default keys, which keys hold, custom keys in UserDefaults |
| `itsytv/Utilities/` | Global hotkeys, AppleScript commands, update check |
| `ItsytvCore/.../Protocol/AppleTVManager.swift` | Connection lifecycle, command queue, reconnects, text input |
| `ItsytvCore/.../Protocol/CompanionConnection.swift` | TCP link, frame parsing, encryption, request and response matching |
| `ItsytvCore/.../Protocol/CompanionCommands.swift` | `_hidC`, `_hidT`, `_launchApp`, `_tiC`, `_interest` and friends |
| `ItsytvCore/.../Protocol/TextInputSession.swift` | `RTIKeyedArchiver` payloads for typing |
| `ItsytvCore/.../Crypto/` | Pair-setup (SRP), pair-verify, ChaCha20-Poly1305, Keychain storage |
| `ItsytvCore/.../Discovery/` | Bonjour discovery and waking a sleeping Apple TV |
| `ItsytvCore/.../AirPlay/` | AirPlay 2 session that carries MediaRemote |
| `ItsytvCore/.../MRP/` | MediaRemote messages: now playing, artwork, media commands |
