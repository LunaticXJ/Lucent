# VLCKit binary

This directory contains VideoLAN's official VLCKit XCFramework for Lucent's
MKV and other non AVFoundation media path.

Source archive: `https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20260929-1631.zip`

SHA-256: `f37c8dbdd4427d1a3f5d75dc4b8bd1ae863cef4426f9a405a2fd1c5c9012f1fb`

Run `./scripts/setup-vlckit.sh` from the repository root before generating the
Xcode project or building. The script downloads the upstream archive, verifies
its checksum, and installs the XCFramework at this package's expected path.
The binary is omitted from Git because it exceeds GitHub's file size limit.
The framework is currently an upstream 4.0 alpha build.
