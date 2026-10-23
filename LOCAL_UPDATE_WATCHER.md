# AirShare Local Source Auto-Update Flow

AirShare can monitor every source saved in Browse. The local watcher fetches each repo manifest, compares the latest app version with its persisted baseline, and can optionally use the active local signing certificate to sign a newer IPA.

Flow:

1. Source is saved in Browse.
2. LocalSourceUpdateWatcher scans source manifests on launch, foreground, and iOS BGAppRefresh opportunities.
3. A first scan establishes a baseline and does not notify for existing versions.
4. A later higher version triggers an update event.
5. If automatic local signing is enabled and an active certificate exists, AirShare downloads the IPA, signs it locally, stores it in Signed, registers it with the existing TLS AirShare server, and the normal install-ready notification is scheduled.
6. Tapping the notification opens `airshare://install?signedID=...`, which uses the existing OTAInstaller path and iOS `itms-services` install prompt.

The feature is intentionally opt-in for automatic signing. Source monitoring and update notifications can be controlled separately from Settings › Auto-Update Signing.
