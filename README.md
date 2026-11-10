# Altiro

Shows your Mac's notifications on your iPhone over Bluetooth LE. The iPhone app pairs with the Mac
once using a 6-digit code, stays connected, and shows each notification as "Mail — Ana García".
Only the app name and the notification's title are sent, encrypted. The message body never leaves the Mac.
With **Send only the app name** on, the title stays on the Mac too.

```
Mail notification ─▶ usernoted DB ─▶ Altiro (Mac) ══ encrypted BLE ══▶ Altiro (iPhone) ─▶ local notification
```

## How it works

- **Detecting notifications.** macOS has no public API for this. `altiro` polls Notification
  Center's own SQLite database once a second (read-only):
  `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. It takes the app and the title
  (falling back to the subtitle), never the body.
- **Connection.** The Mac is a BLE peripheral that always advertises service
  `7268617C-DB3D-4D61-9142-9C2D94ACBE6C`. The iPhone finds it, connects, and stays connected. iOS
  keeps that connection while the app is in the background and wakes it when data arrives.
- **Pairing.** `altiro pair` on the Mac, "Pair with Mac" on the iPhone. The two run an ECDH key
  exchange (P-256) and each derives a 6-digit code from it. Both show the code and ask "Pair with …?",
  like Apple's own Bluetooth pairing: check they match and press **Pair** on both. Matching codes
  prove nobody intercepted the exchange, and because you confirm on both, a stranger's phone or Mac
  in range can't pair with yours. A stalled attempt times out. The Mac commits to its nonce
  before seeing the iPhone's, so an attacker in the middle can't steer the codes to match. Both
  sides then keep the same 256-bit key: the iPhone in its Keychain, the menu bar app in your login
  Keychain, and the CLI in `~/Library/Application Support/altiro/pairing.json` (readable only by
  you). No system Bluetooth pairing is involved.
- **Reconnecting.** Anything can advertise the Altiro service or connect to it, so on every connect
  the two check each other: each sends a random challenge the other can answer only with the pairing
  key. The Mac sends notifications only to an iPhone that passed.
- **Sending.** Each notification is encrypted with ChaCha20-Poly1305 and pushed over a GATT
  characteristic, split into chunks if it's bigger than one BLE packet. Nearby devices can connect but
  can't read or fake anything.
- **Catching up** (can be turned off). The Mac keeps the last hour's notifications (up to 20), and the
  iPhone asks for them every time it connects. The iPhone drops ones it has already shown, and anything older than an hour.

[`mac/Sources/AltiroCore/Wire.swift`](mac/Sources/AltiroCore/Wire.swift) holds the wire format and crypto. Both
the Mac side and the iPhone app compile that one file.

## Layout

```
mac/Sources/AltiroCore/   shared Mac logic: Bluetooth, pairing, notification watching (Engine.swift ties it together)
mac/Sources/altiro/       the command-line tool
mac/App/                   the menu bar app (XcodeGen project)
ios/                       the iPhone app (XcodeGen project)
tools/make-icons.swift      draws the app icon and writes both asset catalogs
```

## Mac menu bar app

```bash
cd mac/App && xcodegen
xcodebuild -project AltiroMac.xcodeproj -scheme AltiroMac -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/Altiro.app /Applications/
open /Applications/Altiro.app
```

It lives in the menu bar (no Dock icon). The panel shows the connection, the pairing code to
compare while pairing, and the last notifications (with their app icons) and whether each reached the iPhone.
Settings (the gear button) has pairing and unpairing, **Send missed notifications** (turn it off to
skip notifications that arrive while the iPhone is away instead of sending them when it reconnects),
**Send only the app name** (off by default; the iPhone then shows "Mail" but not who it's from),
Open at Login, Send Test and the log. Allow Bluetooth when asked and turn on Full Disk Access
for **Altiro** (the panel links to the setting). Set your own `DEVELOPMENT_TEAM` in
`mac/App/project.yml`.

The app and the CLI keep separate pairings: the app's key is in your login Keychain, the CLI's in
`~/Library/Application Support/altiro/pairing.json`. The iPhone pairs with one of them at a time, so
switching between them means pairing again. Run only one of them at a time. (An app that was paired
before it used the Keychain moves its key there on first launch and removes the file.)

## Mac command-line tool

```bash
cd mac
swift build -c release
.build/release/altiro pair          # first time: pair, then keep forwarding
.build/release/altiro               # afterwards
```

On first run, macOS needs two permissions for **the app you run it from** (Terminal, iTerm, …):

1. **Full Disk Access.** Go to System Settings › Privacy & Security › Full Disk Access. Without it you get
   `authorization denied`. Pairing and `--test` still work without it.
2. **Bluetooth.** macOS shows a prompt. If you miss it, go to System Settings › Privacy & Security › Bluetooth.

Restart that app after granting Full Disk Access.

```
altiro pair       pair with the iPhone app (compare a 6-digit code), then keep forwarding
altiro unpair     forget the paired iPhone
--interval SEC     DB poll interval (default 1)
--only IDS         only these bundle IDs, comma-separated, e.g. com.apple.mail,com.apple.MobileSMS
--ignore IDS       skip these bundle IDs
--no-catch-up      don't resend missed notifications when the iPhone reconnects
--app-name-only    send only the app's name, never the notification's title or subtitle
--test             send a test notification at startup
```

## iPhone

This requires Xcode (the full app, not just the command-line tools).

```bash
brew install xcodegen
cd ios && xcodegen && open Altiro.xcodeproj
```

In Xcode, pick your Team under Signing & Capabilities and run on your iPhone. Allow Bluetooth and
notifications when it asks. Then tap **Pair with Mac** while `altiro pair` runs on the Mac.

### iOS caveats

- **Don't swipe the app away.** iOS drops the Bluetooth connection of apps the user force-quits.
  Leaving it in the background is fine, and iOS will even relaunch it if the system killed it.
- **Range** is normal Bluetooth range, roughly the same room or a nearby one. Out of range, the iPhone
  reconnects by itself when you come back, and gets the notifications it missed (up to an hour old).
