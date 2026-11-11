# Contributing Guide

Thank you for investing your time in contributing to LinearMouse!

Read our [Code of Conduct](CODE_OF_CONDUCT.md) to keep our community approachable and respectable.

## Build Instructions

Instructions for building LinearMouse on macOS.

### Dependencies

- [Xcode](https://apps.apple.com/app/xcode/id497799835), with a Swift 6.0 or newer toolchain
- [SwiftLint](https://github.com/realm/SwiftLint), used to lint Swift files
- [SwiftFormat](https://github.com/nicklockwood/SwiftFormat), used to format Swift files
- `npm` & [ts-json-schema-generator](https://www.npmjs.com/package/ts-json-schema-generator), used to generate the configuration JSON schema

Install tools using brew:

```bash
$ brew install npm swiftlint swiftformat
```

Command-line builds need the active developer directory to point at Xcode, not the standalone Command Line Tools.
If `xcodebuild -version` fails with "requires Xcode, but active developer directory ... is a command line tools instance", run

```sh
$ sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

or set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for a single shell.

### Set up the repository

```sh
$ git clone https://github.com/linearmouse/linearmouse.git
$ cd linearmouse
$ npm install
```

### Configure code signing

Code signing is required by Apple. You can generate a code signing configuration by running

```
$ make configure
```

> Note: If you want to contribute to LinearMouse, please don't modify the ‘Signing & Capabilities’ configurations directly in Xcode. Instead, use `make configure` or modify the `Signing.xcconfig`.

If there are no available code signing certificates in your Keychain, it will generate a configuration that uses ad-hoc certificates to sign the app.

When using ad-hoc signing, you may need to grant accessibility permission again after rebuilding the app.
In that case, using Apple Development certificates is recommended.
You can create an Apple Development certificate [in Xcode](https://help.apple.com/xcode/mac/current/#/dev154b28f09), which is totally free.

`make configure` also generates `Version.xcconfig`, which stamps the build with the current commit (`sha-<commit>`), and installs a pre-commit hook.
Both `Signing.xcconfig` and `Version.xcconfig` are only generated when missing.
After switching branches or committing, run `./Scripts/configure-version` to update the version stamp.

### Build and run

For day-to-day development, open the project in Xcode, select the `LinearMouse` scheme and press Cmd+R:

```sh
$ open LinearMouse.xcodeproj
```

To build and launch a debug build from the command line instead:

```sh
$ xcodebuild -project LinearMouse.xcodeproj -scheme LinearMouse -configuration Debug -derivedDataPath build/DerivedData build
$ open build/DerivedData/Build/Products/Debug/LinearMouse.app
```

On first launch, grant LinearMouse Accessibility access in System Settings > Privacy & Security > Accessibility.
Quit any other running copy of LinearMouse first, since only one instance can process events at a time.

### Lint, test and package

| Command        | What it does                                                                              |
| -------------- | ----------------------------------------------------------------------------------------- |
| `make`         | Configure, clean, lint, test and package (the same steps CI runs)                         |
| `make lint`    | Run `swiftformat --lint` and `swiftlint`                                                  |
| `make test`    | Run the Swift package tests in `Modules/` and the app's unit tests                        |
| `make package` | Archive a Release build, export it to `build/Release/` and create `build/LinearMouse.dmg` |
| `make clean`   | Remove the `build/` directory                                                             |

Pass extra `xcodebuild` arguments with `XCODEBUILD_ARGS`, for example to build without code signing:

```sh
$ make test XCODEBUILD_ARGS="CODE_SIGNING_ALLOWED=NO"
```

After changing `Documentation/Configuration.d.ts`, regenerate the JSON schema:

```sh
$ npm run generate:json-schema
```

### Releases

Official releases are built by GitHub Actions (`.github/workflows/build.yml`).
Pushing a `v*` tag builds, signs and notarizes the app with the project's Developer ID certificate, then uploads the DMG and dSYMs to a draft GitHub release.
A tag containing `-` (for example `v0.13.0-beta.6`) is marked as a prerelease.
Locally packaged builds are signed with your own certificate (or ad-hoc) and are not notarized, so Gatekeeper warns when they are opened on other Macs.
