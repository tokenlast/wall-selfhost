# Install Wall on your iPad

Wall is a native iPad app, not a web app that can be installed from a URL. You need a Mac with Xcode, an iPad running iPadOS 15+, and your own Apple account/signing team. The current source targets iPad only. An unsigned simulator build cannot be installed on a physical iPad.

1. Open WipeWall.xcodeproj and select the WipeWall scheme. The generated project is supplied. If editing project.yml, install/use XcodeGen on your own Mac and regenerate it first.
2. Use a unique bundle identifier and your own signing team for the app and test targets. Automatic signing in Xcode can manage your provisioning. Do not use another person's certificates, team or profiles. project.yml defaults to org.example.wall.wipewall; change that placeholder and the corresponding test IDs when needed.
3. Edit WipeWall/Info.plist before building:

| Key | Value |
|---|---|
| WallServerURL | Your HTTPS Wall origin; music broker, photos, gallery and canvas use it |
| WallLocalPasscode | Your numeric local Photo Booth unlock code; blank means those controls cannot be unlocked |
| WallSiftServerURL | Optional compatible Sift API base URL, including /cloud/ if required |
| WallSpotifyClientID | Optional public client ID for your own native PKCE Spotify app |
| WallSonosSpotifyServiceID / WallSonosSpotifyAccountSerial | Optional integer fallback identity for your own speaker/account; observed identity takes priority |

The local passcode is UI protection and is extractable from a built app; server authorization protects server data. Service credentials, long-lived access tokens and passwords must not be placed in Info.plist.

4. Connect and trust the iPad, choose it as the Xcode destination, and enable Developer Mode on device versions that require it (iPadOS 16+). Build and Run, then approve the Wall device on your server as described in SELF_HOSTING.md. Allow Camera, Microphone/Speech and Local Network only for features you intend to use.
5. Test camera/photo upload, canvas sync, gallery and touch interactions on the real iPad. Simulator compilation does not validate the camera, microphone, LAN discovery, account login or speaker playback.

Apple's free Personal Team supports testing on your own devices with limits and profiles that expire after seven days, requiring rebuild/reinstallation. TestFlight/App Store distribution and more advanced capabilities require suitable Apple Developer Program membership and additional signing/review setup. No signing, agreement acceptance, device provisioning or upload was performed for this source export. See [Apple account requirements](https://developer.apple.com/help/account/basics/about-your-developer-account) and [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

## Optional music and voice

For native Spotify PKCE sign-in, register wall-spotify-login://callback for your own Spotify app and set WallSpotifyClientID. If you change the callback scheme, update both SpotifyAccountService.swift and Info.plist's URL scheme. Alternatively connect through your server's browser workspace; the app restores the approved-device broker account.

Sift login uses your configured Sift endpoint and stores the resulting token in the iPad Keychain. The optional voice bridge expects a compatible POST endpoint accepting text and returning text; that external agent service is not bundled.

Voice is unconfigured. For your own development launches only, RealtimeSecrets reads WALL_REALTIME_API_KEY from the process environment (Xcode scheme Run environment). Do not share a scheme containing a key. Do not ship a long-lived OpenAI key in an app bundle. A short-lived token broker and real-account testing remain separate implementation/setup work.

## Unsigned simulator check

```sh
xcodebuild -project WipeWall.xcodeproj -scheme WipeWall \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/wall-derived-data CODE_SIGNING_ALLOWED=NO build
```

This checks compilation without credentials. It does not produce a device-installable signed app.
