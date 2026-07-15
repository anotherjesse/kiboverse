# Kibo for iPhone and Apple Watch

The SwiftUI clients use the existing `kibod` HTTP API. The iPhone app has a
large hold-to-talk surface, durable on-device recording before upload, an
explicit Ask Kibo action, project/conversation navigation, a live timeline,
and reply playback. The Watch app fetches projects and conversations from the
same server and remembers its most recently selected project.

Generate the Xcode project and run the checks:

```sh
cd ios
xcodegen generate
xcodebuild -project Kibo.xcodeproj -scheme Kibo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Kibo.xcodeproj -scheme KiboWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' build
```

Start the server from the repository root with `KIBO_AI_MODE=mock cargo run -p
kibod`. Both apps default to `https://wideboi.stingray-nominal.ts.net/` and
Settings can point them at another URL. For local integration testing, use
`http://127.0.0.1:3000`. Plain HTTP is enabled only for the current trusted
local-network server phase and should not be used on a public network.
