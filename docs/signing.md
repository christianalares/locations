# Installing Locations on an iPhone

Physical-device builds must be signed with a development certificate and
provisioning profile. Xcode's automatic signing manages these for you; you do
not need a separate Mac Developer ID certificate for an iPhone app.

## Free or paid Apple account?

A free Apple Account can install apps on its own devices through an Xcode
Personal Team. Its provisioning profiles expire after seven days, so you need
to rebuild and reinstall periodically. This makes it useful for trying a fork,
but inconvenient for a diary you want recording continuously.

A paid Apple Developer Program membership avoids the free Personal Team's
seven-day cycle, though signing credentials and profiles still expire. It also
allows distribution through TestFlight and the App Store. Apple lists the
program at USD 99 per membership year, or local currency where available.
People installing a distributed app do not need their own developer membership.

Apple currently lists HealthKit, background modes, and Maps as available to
free Apple developer accounts. The HealthKit entitlement in this repository
therefore does not by itself imply a paid-membership requirement. Xcode still
needs to create a valid profile for your chosen account and bundle identifier.

Sources: [Apple account and Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account),
[supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/),
and [program enrollment](https://developer.apple.com/help/account/membership/program-enrollment).

## Build and install

1. Use a Mac with full Xcode and an iPhone running iOS 26 or later. The package
   requires Swift 6.2 or later; the project has been tested with Xcode 27.
2. Install XcodeGen, then run `xcodegen generate` from `apps/ios/` and open
   `LocationsIOS.xcodeproj`.
3. Sign in to your Apple Account in Xcode's account settings.
4. For a fresh personal fork, choose a unique bundle identifier in
   `apps/ios/project.yml`, such as `com.example.locations.ios`, and regenerate.
   Keep that identifier stable across updates; changing it creates a separate
   app container. Existing users must back up their ledger before changing it.
5. In the target's Signing & Capabilities settings, select your team and enable
   automatic signing. This team selection stays in the ignored generated project.
6. Connect and trust your iPhone, select it as the run destination, and follow
   Xcode's prompts to enable Developer Mode. On the phone, this is under
   Settings → Privacy & Security → Developer Mode and requires a restart.
7. Build and run. Open Locations, enable tracking, and grant Always and Precise
   Location access. If replacing a phone, restore before enabling tracking.

For command-line builds, pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild`.
The simulator needs no signing identity, but cannot validate real background
location capture. Use the full Xcode toolchain for native tests; if macOS is
using only Command Line Tools, set `DEVELOPER_DIR` to your Xcode Developer
folder for the command.

[Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
cover pairing and on-device confirmation.

## Sharing builds with friends

A source fork lets a friend build and sign with their own Apple Account. A
signed IPA alone is not a universal installer: its distribution method and
provisioning must allow the recipient's device. TestFlight or App Store
releases are the more convenient path for friends who do not want Xcode;
this repository does not currently publish either.

Keep private keys, certificate exports, provisioning profiles, archives, and
IPAs outside Git. Never uninstall an existing capture app as a troubleshooting
step before preserving its ledger. See `migration.md` and
`sync-and-restore.md` for migration and recovery.
