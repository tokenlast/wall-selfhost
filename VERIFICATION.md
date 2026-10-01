# Verification and limits

- All 39 server tests passed on the Mac using existing Python 3.9.13/Pillow 11.3.0, including JPEG/photo tests, registry selection and refusal to start with blank example authentication. A second run on Python 3.14.4 passed with two image checks skipped because Pillow is absent from that interpreter.
- The deployment requirements target Python 3.10+ and pin Pillow 12.3.0. That exact dependency pair has not been installed or tested here; run the documented full server suite in your own deployment environment. No software was installed on the Mac for this export.
- Endpoint configuration checks executed successfully: a recipient HTTPS origin is used for both music broker paths; invalid, HTTP, credential-bearing and query-bearing URLs fall back to an invalid example origin.
- Xcode 26.6 successfully built the app and compiled its unit/UI test targets for a generic iOS Simulator without signing. Swift unit/UI tests were compiled, not executed in a simulator.
- Source files are checked for credentials with redacted reports before upload. The independent repository starts with one source-only commit and no inherited .git directory. The upload verification compares the remote main commit and every Git blob with the local committed tree.

No physical-iPad installation, signing, live hosting, HTTPS deployment, real camera/audio/LAN test, provider login, cloud runtime, external agent integration or voice token broker was exercised. Weather/transit/music/provider changes may require recipient-specific adjustments. Source completeness excludes intentionally omitted private/runtime data, credentials, signing artifacts, historical host packaging and one audio effect; none is needed for the successful unsigned build.

This repository remains private. No recipient access or redistribution license is granted by the source upload. Original projects and repositories are retained unchanged.
