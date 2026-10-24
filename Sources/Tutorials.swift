//
//  Tutorials.swift
//  Step-by-step guides shown from Settings › Tutorials. Content is static;
//  code blocks are copyable.
//

import SwiftUI
import UIKit

// MARK: - Model

struct Tutorial: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let minutes: Int
    let steps: [TutorialStep]
}

struct TutorialStep: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    var code: String? = nil
    var codeTitle: String? = nil
    var tip: String? = nil
}

// MARK: - Content

enum TutorialLibrary {
    static let all: [Tutorial] = [phoneOnly, nativeInstall, localInstall, signingCerts, installErrors, launchErrors, certs, flex, hooking, pipeline]

    // 0. Phone-only setup
    static let phoneOnly = Tutorial(
        id: "phone", icon: "iphone", title: "Set up with just your phone",
        subtitle: "No computer. Sign in to GitHub, link a repo, done", minutes: 5,
        steps: [
            TutorialStep(
                title: "What you need",
                body: "An iPhone with this app, a GitHub account, and a domain you control (optional — airshare.lol is preconfigured). That's the whole list. No Mac, no Xcode, no server, no terminal — every build, sign, install and cert renewal runs on GitHub Actions or on the phone itself."),
            TutorialStep(
                title: "Sign in to GitHub and make a token",
                body: "On github.com (Safari is fine): Settings › Developer settings › Fine-grained tokens › Generate. Repository access: the repo(s) you'll use. Permissions — Contents, Actions, Workflows: Read and write. Copy it.",
                code: "https://github.com/settings/personal-access-tokens/new",
                codeTitle: "Token page"),
            TutorialStep(
                title: "Paste the token",
                body: "Settings › Access token › paste. It's stored in the Keychain and only ever sent to api.github.com."),
            TutorialStep(
                title: "Link a repo",
                body: "Create an empty repo on github.com (private is fine). Settings › Repository: owner + repo + branch. That's where zips you drop get pushed and where the Build tab watches runs."),
            TutorialStep(
                title: "Link the certs folder (one tap)",
                body: "Settings › AirShare Domain › Cert repo: same owner/repo (or a separate one), your Let's Encrypt email, tap Link repo. First link-up installs the certbot workflow into the repo and creates the `certs` folder (a branch) automatically. Nothing to create by hand.",
                tip: "Linking is idempotent — tap it again any time; it only adds what's missing."),
            TutorialStep(
                title: "Point your domain (optional)",
                body: "Skip this to use airshare.lol. For your own domain: at your DNS host add an A record `*` → 127.0.0.1 (and `@` → 127.0.0.1). Then Settings › AirShare Domain: type the domain, tap Check — it should say → 127.0.0.1 ✓. Save."),
            TutorialStep(
                title: "Issue the cert",
                body: "Tap Renew now. Within a minute the DNS challenge card shows a TXT name and value — add it at your DNS host, the workflow notices and continues; a second value follows for the apex, add it too (keep both). When it finishes, Pull latest. Done — installs now go over https://mr.<your domain>."),
            TutorialStep(
                title: "Daily loop",
                body: "Drop zip → Push → Build tab shows the run → tap the IPA artifact → Sign tab → Sign → Install. Certs auto-refresh from the certs folder before they expire."),
        ])

    // 0a. Fully local install (own root CA, no DNS challenge)
    static let localInstall = Tutorial(
        id: "local", icon: "iphone.and.arrow.forward", title: "Fully local install (no ACME)",
        subtitle: "Your own root CA — instant certs, no DNS challenge, one-time trust", minutes: 5,
        steps: [
            TutorialStep(
                title: "What this is",
                body: "Instead of asking Let's Encrypt for a cert (and doing the DNS TXT dance), the phone becomes its own certificate authority. It generates a root CA once, signs a leaf for your install host, and serves installs with it. iOS trusts it after you install the root profile a single time. Private keys never leave the Keychain."),
            TutorialStep(
                title: "Pick the host and point it at loopback",
                body: "Any name that resolves to 127.0.0.1 works. At your DNS host add an A record for it → 127.0.0.1. In registrar panels the Subdomain field usually wants just the label (e.g. `sign`), not the full name — entering `sign.example.com` there makes `sign.example.com.example.com`. No DNS control? Use a free loopback name like 127-0-0-1.nip.io.",
                tip: "This DNS step is separate from trust. If the host doesn't resolve to 127.0.0.1, iOS silently never shows the install sheet."),
            TutorialStep(
                title: "Switch to Fully local",
                body: "Settings › AirShare Domain › Certificate mode › Fully local. The Active cert card shows exactly which cert is live and whether it matches your host."),
            TutorialStep(
                title: "Create the CA and issue a leaf",
                body: "Settings › AirShare Domain › Open local CA settings › enter the host › Create CA & issue leaf. Tap Check to confirm the host resolves to 127.0.0.1."),
            TutorialStep(
                title: "Inspect, then install the trust profile",
                body: "Tap View profile contents first — it's plain XML with one payload: your root cert. Then Install profile → Settings walks you through it. Finally: Settings › General › About › Certificate Trust Settings › toggle MRvEK Local Root CA on.",
                tip: "iOS shows a red 'Unmanaged Root Certificate' warning. That's correct — it's a root you made, granting trust only on this device."),
            TutorialStep(
                title: "Sign & Install",
                body: "Library › pick IPA › Configure & Sign › Sign IPA › Install. The iOS sheet appears (\"<host> would like to install…\"). After you tap Install, the Install trace card shows what installd did and diagnoses any failure."),
            TutorialStep(
                title: "If it says 'Unable to Install'",
                body: "The delivery worked; installd rejected the package. Almost always: this device's UDID isn't in the .mobileprovision (Settings › Certificates shows ✅/❌ per profile), or an app with the same bundle ID is already installed from another team — delete it, or change the bundle ID in the sign sheet.",
                tip: "Re-issuing a leaf for a new host is instant and needs no new profile — the root you trusted covers anything it signs."),
        ])

    // 0b. Certs in depth
    static let certs = Tutorial(
        id: "certs", icon: "lock.shield.fill", title: "How the AirShare cert works",
        subtitle: "Loopback domain + Let's Encrypt wildcard, issued by Actions", minutes: 6,
        steps: [
            TutorialStep(
                title: "Why a public cert for 127.0.0.1",
                body: "iOS only installs from itms-services manifests served over HTTPS with a trusted cert. A hostname that resolves to loopback but carries a real Let's Encrypt cert satisfies that: the phone talks to a server on itself, over TLS iOS already trusts."),
            TutorialStep(
                title: "DNS-01 is the only way for wildcards",
                body: "Let's Encrypt won't issue *.domain over HTTP; it needs a TXT record at _acme-challenge.<domain>. certbot gives one value for the wildcard and another for the apex — both on the same record name.",
                code: "_acme-challenge.example.com  TXT  \"<value A>\"\n_acme-challenge.example.com  TXT  \"<value B>\"",
                codeTitle: "Two records, same name"),
            TutorialStep(
                title: "The wait-before-validate hook",
                body: "certs.yml runs certbot with a manual auth hook. The hook publishes the value to challenge.json, then polls Cloudflare and Google DNS-over-HTTPS every 20s. Only when the record is visible does it return and let certbot ask Let's Encrypt — so a slow DNS edit never burns a validation attempt.",
                code: "curl -H 'accept: application/dns-json' \\\n  'https://cloudflare-dns.com/dns-query?name=_acme-challenge.example.com&type=TXT'",
                codeTitle: "What the hook checks"),
            TutorialStep(
                title: "Where the files go",
                body: "server.crt (fullchain), server.pem (private key), pack.json (expiry + hashes) on the `certs` branch. The app pulls them with your token; Build.yml bakes the latest pair into every IPA so fresh installs work offline."),
            TutorialStep(
                title: "Renewal",
                body: "Weekly cron re-issues when < 30 days remain (needs repo variable LE_EMAIL for unattended runs), or tap Renew now. The app auto-pulls when within 21 days of expiry at install time."),
        ])

    // 0c. Signing certificates — what the Certificates screen manages (opened from its Help and Support button)
    static let signingCerts = Tutorial(
        id: "signing-certs", icon: "checkmark.seal.fill", title: "Your signing certificates",
        subtitle: "Get, import and manage the certificate AirShare signs apps with", minutes: 4,
        steps: [
            TutorialStep(
                title: "What a certificate is",
                body: "A signing certificate is two files plus a password: the .p12 (your signing identity), the .mobileprovision (the profile that says which devices may run what you sign) and the .p12's password. AirShare signs every app with the certificate marked ACTIVE on this screen."),
            TutorialStep(
                title: "Get one",
                body: "With no certificate yet you get two options. Request a Certificate asks AirShare staff for one for this device; requests are reviewed by hand, and when yours is approved it appears here by itself, so you don't need to keep the screen open. Add Certificate imports a certificate you already have.",
                tip: "You can cancel a pending request from the Activation process card."),
            TutorialStep(
                title: "Import your own",
                body: "In Add Certificate, pick the .p12 and the .mobileprovision together, or a single .zip that contains both. A .txt file in the zip is read as the password (a leading \"password:\" label is fine). Pick exactly one of each; if there are two .p12 files or two profiles, AirShare asks you to choose just one.",
                code: "MyCert.zip\n├── MyCert.p12\n├── MyCert.mobileprovision\n└── password.txt",
                codeTitle: "A .zip AirShare can import in one go"),
            TutorialStep(
                title: "Make sure it covers this phone",
                body: "Development and ad-hoc profiles only install on devices listed inside them. Set your UDID on the device card at the top and every certificate shows whether its profile includes this phone. AirShare fills the UDID in for you when the certificate is named after it, or when the profile lists exactly one device.",
                tip: "\"Unable to Install\" almost always means this phone's UDID isn't in the profile."),
            TutorialStep(
                title: "Use, Export, Remove",
                body: "Use makes a certificate the active one. Export, on the active certificate, saves it as a .zip (.p12, profile and password.txt) that you can import on another device. Remove deletes it from AirShare; apps you already signed with it keep working until its profile expires."),
            TutorialStep(
                title: "Certificates provided by your admin",
                body: "A certificate attached to your account by AirShare staff shows a lock and PROVIDED BY ADMIN · CAN'T EXPORT. You can sign with it like any other, but it can't be exported, removed or included in a backup on any device. Tap Can't export to see why."),
            TutorialStep(
                title: "Watch the expiry date",
                body: "Each certificate shows when its profile expires and how many days are left. Once it expires, apps signed with it stop opening; add or request a new certificate and sign them again.",
                tip: "Re-sign apps a few days before expiry so nothing stops working."),
        ])

    // 0d. Install errors — what "integrity could not be verified" and friends actually mean
    static let installErrors = Tutorial(
        id: "install-errors", icon: "exclamationmark.triangle.fill", title: "Fix \u{201C}Unable to Install\u{201D}",
        subtitle: "Why iOS rejects a sideloaded app, and the fix for each cause", minutes: 6,
        steps: [
            TutorialStep(
                title: "What the integrity error really means",
                body: "\u{201C}This app cannot be installed because its integrity could not be verified\u{201D} is iOS's catch-all. Before installing, iOS checks four things: the certificate is still valid, the profile belongs to that certificate, the profile lists this phone, and the app only asks for permissions (entitlements) the profile allows. If any one fails you get the same message. Work through the next steps in order; the first ones are the most common.",
                tip: "If every app fails, it's the certificate or the profile. If only one app fails, it's that app's entitlements or extensions."),
            TutorialStep(
                title: "1 \u{00B7} This phone isn't in the profile",
                body: "Development and ad-hoc profiles only install on devices whose UDID is listed inside them. On the Certificates screen, set your UDID once; each certificate then shows whether its profile includes this phone. If it doesn't, no setting in AirShare can fix it: use a certificate whose profile includes this phone, or have the UDID added and get a new profile.",
                tip: "This is the cause most of the time."),
            TutorialStep(
                title: "2 \u{00B7} The certificate was revoked",
                body: "Apple can revoke a certificate at any time, and shared certificates get revoked often. After that, new installs fail with the integrity error and apps already signed with it stop opening. Re-signing with the same certificate won't help, because iOS checks revocation online. You need a different certificate: add or request one, make it active, and sign again."),
            TutorialStep(
                title: "3 \u{00B7} The app asks for permissions the profile doesn't allow",
                body: "Apps carry entitlements such as push notifications, App Groups, iCloud and Siri. If the profile doesn't grant one the app asks for, iOS refuses it. In the sign sheet, turn on Auto-fix entitlements, which strips anything your certificate's team can't grant. If it still fails, turn on Disable Push Notifications and Disable App Groups as well.",
                tip: "Certificates from free or limited accounts usually lack push and App Groups. The app installs, but features that need them (notifications, widgets sharing data) won't work."),
            TutorialStep(
                title: "4 \u{00B7} The .p12 and profile don't belong together",
                body: "A .mobileprovision is issued for one specific certificate. If the .p12 came from one account and the profile from another, or the profile was made for an older certificate, every install fails. Check the Team shown on the certificate card, and re-import a .p12 and profile that were issued together."),
            TutorialStep(
                title: "5 \u{00B7} Extensions or a Watch app break the signature",
                body: "Many apps bundle extensions (widgets, share sheet, notification service) and sometimes a Watch app, each signed separately. One that can't be signed for your profile fails the whole install. In the sign sheet, turn on Strip PlugIns and Remove Watch apps, then sign again.",
                tip: "Stripping extensions removes widgets and share-sheet entries for that app; the main app still works."),
            TutorialStep(
                title: "6 \u{00B7} The same app is already installed",
                body: "If an app with the same bundle ID is already on the phone, signed by a different team (for example the App Store version), the install is rejected. Delete the existing app first, or turn on Randomize bundle ID in the sign sheet so both can be installed side by side.",
                tip: "Randomize bundle ID gives the copy separate data, so it won't see the original's logins or files."),
            TutorialStep(
                title: "7 \u{00B7} The app doesn't support this phone or iOS version",
                body: "Some IPAs limit which device models may install them; AirShare removes that limit automatically every time it signs. If the message says the app needs a newer iOS, Force min iOS 12.0 in the sign sheet lowers the requirement, but an app that really uses newer iOS features can still crash on launch.",
                tip: "Still failing after all of this? Download the IPA again. A partly downloaded file fails the same integrity check."),
        ])

    // 0e. Launch problems — the app installed, but won't open or closes immediately
    static let launchErrors = Tutorial(
        id: "launch-errors", icon: "xmark.app.fill", title: "Fix apps that won't open",
        subtitle: "Untrusted developer, Developer Mode, revoked or expired, instant crashes", minutes: 5,
        steps: [
            TutorialStep(
                title: "\u{201C}Untrusted Developer\u{201D}",
                body: "The first time you open an app signed with a new certificate, iOS asks you to trust its developer. Go to Settings \u{203A} General \u{203A} VPN & Device Management, tap the developer under Enterprise App or Developer App, and tap Trust. You only do this once per certificate.",
                tip: "The phone needs internet the first time so iOS can check the certificate."),
            TutorialStep(
                title: "\u{201C}Developer Mode required\u{201D}",
                body: "On iOS 16 and later, apps signed with a development certificate won't open until Developer Mode is on. Go to Settings \u{203A} Privacy & Security \u{203A} Developer Mode, turn it on, let the phone restart, and tap Turn On when asked. Ad-hoc and enterprise certificates don't need it.",
                tip: "The Developer Mode switch only appears after a development-signed app has been installed."),
            TutorialStep(
                title: "\u{201C}No longer available\u{201D} or it closes right away",
                body: "If apps that worked yesterday stop opening, the certificate was revoked or its profile expired. Nothing on the phone can bring them back; sign them again with a valid certificate. The Certificates screen shows each profile's expiry date and days left.",
                tip: "Free Apple ID certificates last only 7 days and allow 3 sideloaded apps at once."),
            TutorialStep(
                title: "Crashes the instant it opens",
                body: "Apps taken straight from the App Store are encrypted (FairPlay) and can only run with Apple's own signature. AirShare checks this when you sign: if the sign sheet says FairPlay ENCRYPTED, the app will crash after re-signing. Get a decrypted copy from the Decrypt tab, then sign that.",
                tip: "Check the encryption line in the sign sheet before signing any IPA whose source you don't know."),
            TutorialStep(
                title: "Crashes after injecting a tweak",
                body: "If an app crashes only after you added a tweak or dylib, the tweak is usually missing a library it depends on, or doesn't match this app version. Turn on Weak dylib references, which lets the app start even if a library is missing, and make sure the tweak is built for this app version.",
                tip: "Sign once without the tweak. If that copy opens, the problem is the tweak, not the certificate."),
            TutorialStep(
                title: "Features missing after signing",
                body: "If the app opens but notifications, widgets, iCloud sync or Sign in with Apple don't work, that's the cost of the entitlements that were stripped so it could install. Those features need a certificate whose profile grants them; with most sideloading certificates they can't be brought back."),
        ])

    // 0f. Native installs — the recommended way on iOS 27
    static let nativeInstall = Tutorial(
        id: "native-install", icon: "iphone.and.arrow.forward", title: "Native installs on iOS 27",
        subtitle: "Why to update, how to set it up, and what you get", minutes: 6,
        steps: [
            TutorialStep(
                title: "Why we recommend iOS 27",
                body: "On iOS 27 AirShare can pair with your iPhone and install apps directly over a private VPN that runs only on the phone. Nothing goes through a website, there's no install link or \u{201C}Would like to install\u{201D} prompt, and installs keep going in the background. On older iOS versions AirShare can only use the classic install-link method (OTA). Native installs need iOS 27 because that's where pairing can be created on the phone itself.",
                tip: "Everything you already have keeps working after you update; your certificates and signed apps stay where they are."),
            TutorialStep(
                title: "1 \u{00B7} Update to iOS 27",
                body: "Go to Settings \u{203A} General \u{203A} Software Update and install iOS 27. Back up first and keep the phone charging. If iOS 27 doesn't appear, check that your iPhone model supports it."),
            TutorialStep(
                title: "2 \u{00B7} Turn on Developer Mode",
                body: "Go to Settings \u{203A} Privacy & Security \u{203A} Developer Mode, turn it on, let the phone restart, then tap Turn On when asked. Pairing lives under this setting, so it has to be on.",
                tip: "If Developer Mode is ever turned off or reset, pair again (step 5)."),
            TutorialStep(
                title: "3 \u{00B7} Allow Local Network and connect to Wi-Fi",
                body: "AirShare finds the phone's pairing service over the local network. When iOS asks whether AirShare may find devices on your local network, tap Allow. If you said no earlier, turn it back on in Settings \u{203A} Privacy & Security \u{203A} Local Network \u{203A} AirShare. Stay on Wi-Fi during setup."),
            TutorialStep(
                title: "4 \u{00B7} Run Setup",
                body: "In AirShare, open Settings \u{203A} Install Method to get to the Connection Controller, then tap Setup. When iOS asks to add a VPN configuration, tap Allow. This VPN never leaves the phone; it's the private road installs travel on.",
                tip: "iOS runs one VPN at a time, so this can turn off another VPN while AirShare is installing."),
            TutorialStep(
                title: "5 \u{00B7} Enter the pairing code",
                body: "AirShare shows a pairing code. Go to Settings \u{203A} Privacy & Security \u{203A} Developer Mode \u{203A} Pair with AirShare and type it in. Back in AirShare, the Pairing, VPN, Tunnel and Device lights turn green and it says Connected."),
            TutorialStep(
                title: "6 \u{00B7} Switch to Native",
                body: "In the Connection Controller, set Install method to Native. From now on, Install sends apps straight to the phone. AirShare reconnects by itself before each install, so you don't need to open this screen again.",
                tip: "If setup can't create the VPN, your copy of AirShare wasn't signed with VPN permission. Reinstall the official AirShare build."),
            TutorialStep(
                title: "What you get",
                body: "\u{2022} No install link, no domain and no HTTPS certificate: apps go straight onto the phone.\n\u{2022} Installs finish in the background, with progress in a notification, so you can leave AirShare.\n\u{2022} Automatic app updates, optionally only on Wi-Fi or while charging, with Skip and Roll back if an update misbehaves.\n\u{2022} Batch installs and app sets: pick several signed apps and install them in one go.\n\u{2022} Uninstall apps from the phone right inside AirShare.\n\u{2022} The install queue (download, sign and install) runs hands-free, because no install prompt has to be tapped.\n\u{2022} Restore VPN reconnects in one tap, or from a Shortcut, if the connection drops."),
            TutorialStep(
                title: "Can't update yet?",
                body: "Keep using OTA, the classic install-link method; it works on older iOS versions. Advanced users can also choose the Manual connection in the Connection Controller, which uses a pairing file made on a computer plus their own local VPN.",
                tip: "Re-pair (Forget pairing, then Setup) if you switch phones or the tunnel stops responding."),
        ])

    /// The guides behind Certificates › Help and Support, in reading order.
    static let certHelp: [Tutorial] = [signingCerts, installErrors, launchErrors, nativeInstall]

    // 1. Capture class names with FLEX
    static let flex = Tutorial(
        id: "flex", icon: "scope", title: "Capture class names with FLEX",
        subtitle: "Find the exact view, class and selector to hook", minutes: 10,
        steps: [
            TutorialStep(
                title: "Get FLEX as a dylib",
                body: "FLEX (Flipboard Explorer) is an in-app runtime inspector. You need it as a standalone dylib so it can be injected into the target IPA without rebuilding the app. Grab the latest FLEX.dylib release (or build it from the FLEX repo with the dylib template in this app — Makefile target FLEX, files from Classes/).",
                code: "https://github.com/FLEXTool/FLEX/releases",
                codeTitle: "Source",
                tip: "Keep one FLEX.dylib in Files. You'll inject it into every app you want to explore."),
            TutorialStep(
                title: "Inject FLEX into the target IPA",
                body: "In AirShare, open the IPA › Sign › Extra dylibs › add FLEX.dylib. AirShare copies it into the app bundle, adds an LC_LOAD_DYLIB to the main binary, signs everything with your cert and installs. No jailbreak needed — the app now loads FLEX at launch.",
                tip: "Same flow you'll use later for your own dylib. FLEX first, your tweak second."),
            TutorialStep(
                title: "Open the explorer",
                body: "Launch the app. FLEX's toolbar shows on a shake (or add a 3-finger tap trigger in your own dylib with [FLEXManager.sharedManager showExplorer]). Tap 'select' in the toolbar, then tap any UI element on screen.",
                code: "// If FLEX is silent, force it from your own dylib:\n#import <FLEX/FLEX.h>\n[[FLEXManager sharedManager] showExplorer];",
                codeTitle: "Force the explorer"),
            TutorialStep(
                title: "Read the class from the breadcrumb",
                body: "After selecting a view, FLEX shows the hierarchy chain at the top, e.g. UIWindow › UITransitionView › UIView › AMSettingsHeaderView. The last item is the exact class of what you tapped. Tap 'views' to scrub up and down the hierarchy — pick the smallest view that still contains what you want to change.",
                tip: "Prefer the view controller over the view when you want to add things: tap the view, then in the object screen scroll to 'nearest view controller'."),
            TutorialStep(
                title: "Capture the selectors",
                body: "Tap the class name to open the object explorer. Sections: ivars, properties, methods, class methods, superclass chain. Long-press any selector to copy it. viewDidLoad / viewDidAppear: / layoutSubviews are the usual entry points; app-specific ones like -configureWithModel: or -reloadData are where the interesting data flows.",
                code: "// What you leave FLEX with:\nClass:     AMSettingsViewController\nSuper:     UITableViewController\nSelector:  -viewDidAppear:\nIvar:      _headerLabel (UILabel *)",
                codeTitle: "Notes to keep"),
            TutorialStep(
                title: "Verify at runtime before hooking",
                body: "Classes get renamed between app versions. Resolve them by string at runtime and log if they're missing — a nil class must never crash the host app.",
                code: "Class c = objc_getClass(\"AMSettingsViewController\");\nif (!c) { NSLog(@\"[MRvEK] class not found\"); return; }\nNSLog(@\"[MRvEK] found %@ (super %@)\", c, class_getSuperclass(c));",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Dump everything (optional)",
                body: "For a full class list without tapping around, use FLEX › Runtime Browser, or dump from code once and read it in Console. Search the dump for the strings you saw on screen — labels usually live near the class that owns them.",
                code: "unsigned int n = 0;\nMethod *ms = class_copyMethodList(objc_getClass(\"AMSettingsViewController\"), &n);\nfor (unsigned i = 0; i < n; i++) NSLog(@\"%@\", NSStringFromSelector(method_getName(ms[i])));\nfree(ms);",
                codeTitle: "Method dump"),
        ])

    // 2. Hook without Substrate
    static let hooking = Tutorial(
        id: "hook", icon: "link", title: "Hook a class without Substrate",
        subtitle: "ObjC runtime swizzling that works sideloaded", minutes: 8,
        steps: [
            TutorialStep(
                title: "Why not %hook",
                body: "Logos %hook compiles to MSHookMessageEx, which needs libsubstrate on the device. Sideloaded apps don't have it. Use generator=internal in the Makefile (the dylib template does this) or write the swizzle yourself — same result, zero dependencies, runs jailbroken or not."),
            TutorialStep(
                title: "The swizzle helper",
                body: "Add the replacement method to the class if it isn't there, otherwise exchange the two implementations. This copes with methods inherited from a superclass.",
                code: "static void mrvek_swizzle(Class cls, SEL orig, SEL repl) {\n    Method m1 = class_getInstanceMethod(cls, orig);\n    Method m2 = class_getInstanceMethod(cls, repl);\n    if (!cls || !m1 || !m2) return;\n    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2)))\n        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));\n    else\n        method_exchangeImplementations(m1, m2);\n}",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Write the replacement as a category",
                body: "Declare the new selector in a category on the class you captured (or on its UIKit superclass if the app class is private). Call the original by calling the swizzled name — after the exchange, that resolves to the real implementation.",
                code: "@interface UIViewController (MRvEK)\n- (void)mrvek_viewDidAppear:(BOOL)a;\n@end\n@implementation UIViewController (MRvEK)\n- (void)mrvek_viewDidAppear:(BOOL)a {\n    [self mrvek_viewDidAppear:a];   // original\n    if ([NSStringFromClass([self class]) isEqualToString:@\"AMSettingsViewController\"]) {\n        // your overlay here\n    }\n}\n@end",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Install from a constructor",
                body: "A __attribute__((constructor)) runs when the dylib loads, before the app's main. Resolve private classes by name here.",
                code: "__attribute__((constructor))\nstatic void mrvek_init(void) {\n    Class c = objc_getClass(\"AMSettingsViewController\") ?: [UIViewController class];\n    mrvek_swizzle(c, @selector(viewDidAppear:), @selector(mrvek_viewDidAppear:));\n}",
                codeTitle: "Tweak.xm"),
            TutorialStep(
                title: "Read private ivars",
                body: "FLEX showed you _headerLabel. Pull it with the runtime instead of a header you don't have.",
                code: "Ivar iv = class_getInstanceVariable([self class], \"_headerLabel\");\nUILabel *label = iv ? object_getIvar(self, iv) : nil;\nlabel.text = @\"MRvEK Edition\";",
                codeTitle: "Ivar access"),
            TutorialStep(
                title: "Keep it idempotent",
                body: "viewDidAppear: fires every time the screen shows. Tag your added views and bail if the tag already exists, or you'll stack overlays.",
                code: "if ([self.view viewWithTag:0x4D5245]) return;\nbadge.tag = 0x4D5245;\n[self.view addSubview:badge];",
                codeTitle: "Guard"),
        ])

    // 3. Build + inject pipeline
    static let pipeline = Tutorial(
        id: "pipeline", icon: "arrow.triangle.branch", title: "Build & inject from your phone",
        subtitle: "Template → Push → Build tab → AirShare", minutes: 6,
        steps: [
            TutorialStep(
                title: "Generate the dylib template",
                body: "Settings › Templates › Dylib. Name it, paste the target bundle id (FLEX › Info shows it, or AirShare's IPA info), Generate. The workspace now holds Makefile, Tweak.xm, filter plist, control and a build.yml."),
            TutorialStep(
                title: "Push it",
                body: "Create an empty repo on github.com, set it in Settings › Repository, then Push. Your token needs Contents + Workflows: Read and write (the template contains .github/workflows)."),
            TutorialStep(
                title: "Watch it build",
                body: "Build tab › the run appears within seconds. Steps: Install Theos › Build › Upload dylib. Tap a run to follow the steps live. Red step = tap Open on GitHub for the log, fix Tweak.xm in Contents, Push again."),
            TutorialStep(
                title: "Download the artifact",
                body: "When the run completes, the artifacts list shows the build output. IPA artifacts jump straight into the Sign tab; a dylib artifact opens the share sheet — Save to Files, then add it as an extra dylib when signing."),
            TutorialStep(
                title: "Sign & install",
                body: "Sign tab › pick the target IPA › Sign with your cert › Install. The install runs over the on-device loopback AirShare server, same as AirShare. For dylib injection keep using AirShare's extra-dylibs step (keep FLEX in while iterating). Console / FLEX › System Log shows your [Tweak] loaded line first.",
                tip: "Iterate: edit Tweak.xm in Contents → Push → Build → re-sign. Whole loop runs from the phone."),
            TutorialStep(
                title: "Ship",
                body: "Remove FLEX from the extra dylibs, bump Version in control, tag the release. Keep the handle only in About/credits — no real names in shipped builds."),
        ])
}

// MARK: - Tutorials list (table) — tap a row to open the tutorial

struct TutorialsListScreen: View {
    /// Which guides to list (defaults to all of them), the title in the bar, and the note under the list.
    var tutorials: [Tutorial] = TutorialLibrary.all
    var title: String = "Tutorials"
    var footer: String = "Everything here is done from the phone: GitHub sign-in, one linked repo, and this app. Check steps off as you go."
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 8) {
                        Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                        Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.bg)
                .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

                List {
                    Section {
                        ForEach(tutorials) { t in
                            NavigationLink(value: t.id) {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14))
                                        Image(systemName: t.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                                    }.frame(width: 38, height: 38)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(t.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                                        Text(t.subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(2)
                                        Text("\(t.steps.count) steps · ~\(t.minutes) min").font(.caption2.monospaced()).foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .listRowBackground(Theme.card)
                        }
                    } header: {
                        Text("GUIDES").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                    } footer: {
                        Text(footer)
                            .font(.caption2).foregroundStyle(Theme.subtle)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                TutorialScreen(tutorial: tutorials.first { $0.id == id } ?? TutorialLibrary.all.first { $0.id == id } ?? TutorialLibrary.phoneOnly, pushed: true)
                    .toolbar(.hidden, for: .navigationBar)
            }
        }
        .tint(Theme.accent)
    }
}

// MARK: - Tutorial screen

struct TutorialScreen: View {
    let tutorial: Tutorial
    var pushed: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var done: Set<UUID> = []
    @State private var copied: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text("Tutorial").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: pushed ? "chevron.left" : "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.bg)
            .overlay(Rectangle().fill(Theme.stroke).frame(height: 1), alignment: .bottom)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(Array(tutorial.steps.enumerated()), id: \.element.id) { i, step in
                        stepCard(i + 1, step)
                    }
                    Text("Progress is per session. Work through the steps in order — each one assumes the previous.")
                        .font(.caption2).foregroundStyle(Theme.subtle).padding(.top, 4)
                }
                .padding(16)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var header: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.14))
                    Image(systemName: tutorial.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                }.frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tutorial.title).font(.headline).foregroundStyle(Theme.text)
                    Text(tutorial.subtitle).font(.caption).foregroundStyle(Theme.subtle)
                    Text("\(tutorial.steps.count) steps · ~\(tutorial.minutes) min · \(done.count)/\(tutorial.steps.count) done")
                        .font(.caption2.monospaced()).foregroundStyle(Theme.accent)
                }
                Spacer()
            }
        }
    }

    private func stepCard(_ n: Int, _ step: TutorialStep) -> some View {
        let isDone = done.contains(step.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    if isDone { done.remove(step.id) } else { done.insert(step.id) }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    ZStack {
                        Circle().fill(isDone ? Theme.accent : Theme.accent.opacity(0.14)).frame(width: 28, height: 28)
                        if isDone { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black) }
                        else { Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent) }
                    }
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                        .strikethrough(isDone, color: Theme.subtle)
                    Text(step.body).font(.system(size: 14)).foregroundStyle(Theme.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let code = step.code {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(step.codeTitle ?? "Code").font(.caption2.weight(.semibold)).foregroundStyle(Theme.subtle)
                        Spacer()
                        Button {
                            UIPasteboard.general.string = code
                            copied = step.id
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == step.id { copied = nil } }
                        } label: {
                            Label(copied == step.id ? "Copied" : "Copy", systemImage: copied == step.id ? "checkmark" : "doc.on.doc")
                                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            .padding(10)
                    }
                    .background(Theme.bg)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.leading, 40)
            }
            if let tip = step.tip {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.yellow)
                    Text(tip).font(.caption).foregroundStyle(Theme.subtle)
                }
                .padding(.leading, 40)
            }
        }
        .padding(14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(isDone ? Theme.accent.opacity(0.35) : Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
