# iPhone signing

Generate the project with XcodeGen from `apps/ios/`, then open
`LocationsIOS.xcodeproj`. The simulator does not need a signing identity.

For a physical iPhone, select your own development team in Xcode's Signing &
Capabilities settings and let Xcode manage the development certificate and
provisioning profile. The generated Xcode project is ignored by Git, so this
selection stays local. For command-line builds, pass
`DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild`.

The existing bundle identifier is retained for compatibility with installed
copies. For a separate installation or distribution, choose a bundle identifier
you control in `apps/ios/project.yml`.

Keep certificates, private keys, provisioning profiles, signed archives, and
IPAs outside the repository. Keep device tokens in the iPhone Keychain and
server tokens in runtime environment variables.

Before using a replacement build as the sole capture app, back up the complete
source ledger and verify the migration checks in `migration.md`. For a new
phone, follow `sync-and-restore.md`.
