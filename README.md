# bleping

Shows your Mac's notifications on your iPhone over Bluetooth LE. The iPhone app pairs with the Mac
once using a 6-digit code, stays connected, and shows each notification as "Mail — Ana García".
Only the app name and the notification's title are sent, encrypted. The message body never leaves the Mac.

```
Mail notification ─▶ usernoted DB ─▶ bleping (Mac) ══ encrypted BLE ══▶ bleping (iPhone) ─▶ local notification
```

## How it works

- **Detecting notifications.** macOS has no public API for this. `bleping` polls Notification
  Center's own SQLite database once a second (read-only):
  `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. It takes the app and the title
  (falling back to the subtitle), never the body.
- **Connection.** The Mac is a BLE peripheral that always advertises service
  `7268617C-DB3D-4D61-9142-9C2D94ACBE6C`. The iPhone finds it, connects, and stays connected. iOS
  keeps that connection while the app is in the background and wakes it when data arrives.
- **Pairing.** `bleping pair` on the Mac, "Pair with Mac" on the iPhone. The two run an ECDH key
  exchange (P-256) and each derives a 6-digit code from it. The iPhone shows its code and you type it
  on the Mac. Matching codes prove nobody intercepted the exchange, and because you type the code on
  the Mac, a stranger's phone in range can't pair instead of yours (it would show a code you never
  see). Three wrong codes, or a stalled attempt, end pairing. The Mac commits to its nonce
  before seeing the iPhone's, so an attacker in the middle can't steer the codes to match. Both
  sides then keep the same 256-bit key: the Mac in `~/Library/Application Support/bleping/pairing.json`
  (readable only by you), the iPhone in its Keychain. No system Bluetooth pairing is involved.
- **Reconnecting.** Anything can advertise the bleping service, so on every connect the iPhone sends
  the Mac a random challenge and only goes on if the Mac answers it with the pairing key.
- **Sending.** Each notification is encrypted with ChaCha20-Poly1305 and pushed over a GATT
  characteristic, split into chunks if it's bigger than one BLE packet. Nearby devices can connect but
  can't read or fake anything.
- **Catching up** (can be turned off). The Mac keeps the last hour's notifications (up to 20), and the
  iPhone asks for them every time it connects. The iPhone drops ones it has already shown, and anything older than an hour.

[`mac/Sources/BlePingCore/Wire.swift`](mac/Sources/BlePingCore/Wire.swift) holds the wire format and crypto. Both
the Mac side and the iPhone app compile that one file.

## Layout

```
mac/Sources/BlePingCore/   shared Mac logic: Bluetooth, pairing, notification watching (Engine.swift ties it together)
mac/Sources/bleping/       the command-line tool
mac/App/                   the menu bar app (XcodeGen project)
ios/                       the iPhone app (XcodeGen project)
```

## Mac menu bar app

```bash
cd mac/App && xcodegen
xcodebuild -project BlePingMac.xcodeproj -scheme BlePingMac -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build
cp -R build/Build/Products/Release/bleping.app /Applications/
open /Applications/bleping.app
```

It lives in the menu bar (no Dock icon). The panel shows the connection, a field for the iPhone's
pairing code while pairing, and the last notifications (with their app icons) and whether each reached the iPhone.
Settings (the gear button) has pairing and unpairing, **Send missed notifications** (turn it off to
skip notifications that arrive while the iPhone is away instead of sending them when it reconnects),
Open at Login, Send Test and the log. Allow Bluetooth when asked and turn on Full Disk Access
for **bleping** (the panel links to the setting). Set your own `DEVELOPMENT_TEAM` in
`mac/App/project.yml`.

The app and the CLI share the pairing (`~/Library/Application Support/bleping/pairing.json`), so
pairing with either works for both. Run only one of them at a time.

## Mac command-line tool

```bash
cd mac
swift build -c release
.build/release/bleping pair          # first time: pair, then keep forwarding
.build/release/bleping               # afterwards
```

On first run, macOS needs two permissions for **the app you run it from** (Terminal, iTerm, …):

1. **Full Disk Access.** Go to System Settings › Privacy & Security › Full Disk Access. Without it you get
   `authorization denied`. Pairing and `--test` still work without it.
2. **Bluetooth.** macOS shows a prompt. If you miss it, go to System Settings › Privacy & Security › Bluetooth.

Restart that app after granting Full Disk Access.

```
bleping pair       pair with the iPhone app (type the code it shows), then keep forwarding
bleping unpair     forget the paired iPhone
--interval SEC     DB poll interval (default 1)
--only IDS         only these bundle IDs, comma-separated, e.g. com.apple.mail,com.apple.MobileSMS
--ignore IDS       skip these bundle IDs
--no-catch-up      don't resend missed notifications when the iPhone reconnects
--test             send a test notification at startup
```

## iPhone

This requires Xcode (the full app, not just the command-line tools).

```bash
brew install xcodegen
cd ios && xcodegen && open BlePing.xcodeproj
```

In Xcode, pick your Team under Signing & Capabilities and run on your iPhone. Allow Bluetooth and
notifications when it asks. Then tap **Pair with Mac** while `bleping pair` runs on the Mac.

### iOS caveats

- **Don't swipe the app away.** iOS drops the Bluetooth connection of apps the user force-quits.
  Leaving it in the background is fine, and iOS will even relaunch it if the system killed it.
- **Range** is normal Bluetooth range, roughly the same room or a nearby one. Out of range, the iPhone
  reconnects by itself when you come back, and gets the notifications it missed (up to an hour old).
