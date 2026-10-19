# Aurelia PMS: automation and connectivity

## Internet and AI controls

Settings exposes separate app-level Internet and AI toggles. Internet off prevents the AI bridge from calling a remote model and uses offline guidance. It does not turn off the Android device's Wi-Fi/mobile radio or automatically block every third-party SDK request.

AI on enables local diagnostics and optional online assistance. Online model responses require the separately deployed secure gateway in `backend/ai-gateway`; no API key is embedded in the APK. Only the question the user explicitly submits is sent to the gateway.

## Safe repair

The Settings health check repairs only known structural defects (missing collection arrays and malformed settings containers). It reports duplicate identifiers and malformed rows but does not delete, merge, or rewrite financial records. It is not possible to promise automatic repair of every possible error; unknown defects require diagnosis and explicit tests.

## Release gates

Before production distribution, deploy and secure the AI gateway, configure rate limiting and budget alerts, run all GitHub Actions, install the APK on a physical device, and verify hotel/restaurant isolation, food-only room billing, offline operations, backup/restore, and network-off behavior. A passing debug build alone is not a production certification.
