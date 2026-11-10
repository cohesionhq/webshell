---
name: run-the-app
description: Launch the Apple Cohesion client (Cohesion for iPad and Mac) on the iPad simulator or the Mac and take a screenshot, to see a native change running. Use when asked to run, launch or screenshot the app, or to confirm a native UI change (banners, menus, the pairing form, safe areas) beyond a build.
---

# Run the app

The bundle ID is `com.hellocohesion.apple.client`. Build first (see
`verify-change`).

## iPad simulator

```sh
APP="$(xcodebuild -project mac/CohesionWebHarness.xcodeproj -scheme Cohesion -destination 'generic/platform=iOS Simulator' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Cohesion.app"
xcrun simctl list devices booted            # boot one if none: xcrun simctl boot "iPad Pro 11-inch (M5)"
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.hellocohesion.apple.client
sleep 3; xcrun simctl io booted screenshot /tmp/cohesion-ipad.png
```

Then Read the PNG to look at it. Use the `device-interaction` skill to tap or
type. Installing over an earlier build keeps the app's data and keychain, so a
paired simulator stays paired.

## Mac

```sh
APP="$(xcodebuild -project mac/CohesionWebHarness.xcodeproj -scheme Cohesion -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Cohesion.app"
open "$APP"
```

This opens a window on the desktop, so do it only when a Mac-only change
(title bar, the Cohesion menu) needs seeing, and quit it afterwards with
`osascript -e 'quit app "Cohesion"'`.

## Past the pairing screen

An unpaired app shows "Pair with Cohesion", which asks for a setup code. Getting
one registers a new client with a real daemon, so don't pair unless
the task says to. Check what you can on the pairing screen, and list
anything past it (the web UI, the update banner, `--titlebar-inset`) as a
manual check in the report.
