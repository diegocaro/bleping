# App Review notes (iPhone app)

Draft text for the **App Review Information › Notes** field in App Store Connect.
Fill in the `<…>` placeholders before submitting.

---

## What bleping does

bleping shows your Mac's notifications on your iPhone. It's made of two apps:

- **bleping for Mac**, a menu bar app distributed outside the Mac App Store (Developer ID, notarized):
  `<download URL>`
- **bleping for iPhone** (this app), which receives the notifications from the Mac over Bluetooth Low
  Energy and shows them as local notifications.

The iPhone app needs the Mac app to work: it has no server and no account. The two devices talk only to
each other, directly over Bluetooth.

## Why the app uses the `bluetooth-central` background mode

Receiving the Mac's notifications while bleping isn't on screen is the app's core feature. Without
background Bluetooth, notifications would only arrive while the user is looking at the app, which
defeats its purpose.

- The iPhone stays connected to the **one Mac the user paired with**, and iOS wakes the app when that
  Mac sends a notification. The app then posts a local notification and goes back to sleep.
- It connects only to devices advertising bleping's own Bluetooth service, and accepts data only from
  the Mac it paired with (verified with a key shared at pairing; everything is end-to-end encrypted).
- It doesn't scan for, track or record other Bluetooth devices, and it uses no location data.
- The Bluetooth permission prompt says this: "bleping connects to your Mac over Bluetooth to receive
  its notifications, including while bleping is in the background, so they reach your iPhone when the
  app isn't open."

## How to test

You need a Mac (macOS 14 or later) with Bluetooth, and the iPhone nearby.

1. On the Mac, download and open bleping: `<download URL>`. A bell appears in the menu bar.
2. macOS asks to allow Bluetooth: click **Allow**. In the bleping panel, follow the link to turn on
   **Full Disk Access** for bleping (System Settings › Privacy & Security › Full Disk Access), then
   click **Retry**. This lets the Mac app see the Mac's notifications.
3. On the iPhone, open bleping and tap **Pair with Mac**. Allow Bluetooth when asked.
4. On the Mac, click the bell › **Pair iPhone…**. A 6-digit code appears on the iPhone. Type it on
   the Mac. Allow notifications when asked.
5. **Background test:** lock the iPhone. On the Mac, open Settings › Troubleshooting and click
   **Send Test**. A "Test notification" appears on the iPhone's Lock Screen within a few seconds.
6. Any notification on the Mac (for example from Calendar or Mail) also appears on the iPhone, showing
   the app's name and the notification's title. The message body is never sent.

A screen recording of these steps: `<video URL>`

## Privacy

- Data Not Collected: nothing is sent to us or any server. Notifications go straight from the user's
  Mac to their iPhone, encrypted.
- Only the app name, title and subtitle of each notification are sent, never the body.
- The iPhone keeps the list of received notifications for 24 hours, on the device only (excluded from
  backups).
- Privacy policy: `<privacy policy URL>`
