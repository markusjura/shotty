# Signing verification: free Apple Development certificate for Shotty

## Current status, 25 September 2026

The free Apple Development identity signs the Shotty target on studio. The bundle identifier is `local.markus.Shotty`, the deployment target is macOS 26, and Hardened Runtime is on. The signed Release app passes `codesign --verify --deep --strict`. It has no embedded provisioning profile, and entitlement inspection is empty because Release disables Xcode's injected development entitlements. App Sandbox is off.

The app is installed at `/Applications/Shotty.app` on studio and has launched through Computer Use after several signed Release replacements. The first install and the first rebuilt update had identical designated requirements. Markus granted Screen Recording and Accessibility, and both remained available after multiple signed Release replacements. Evidence and remaining gates are in [native verification](native-verification.md).

No paid membership, Developer ID identity, notarization, key export, or security bypass was used. m1 launch, its own permission grants, and update continuity there are deferred to a separate fleet PR at Markus's request. A signed harness was copied to m1 before that scope change and its signature checked, but it was never launched there.

## Identity setup, 25 September 2026

Markus signed into Xcode on studio. The free Personal Team is available. Manual Manage Certificates initially showed Apple Development disabled; selecting the Personal Team for a disposable target triggered automatic creation. `security find-identity -v -p codesigning` reports one valid Apple Development identity. The issuer is Apple Worldwide Developer Relations Certification Authority, G3. The certificate is valid from 25 September 2026 at 14:00:20 UTC until 25 September 2027 at 14:00:19 UTC. The private key remains in the login keychain; nothing was exported or committed.

Before the Shotty target existed, a disposable probe project at `/tmp/ShottySigningProbe` (bundle identifier `local.markus.ShottySigningProbe`) built with the same settings. It is outside the repository and is superseded by the Shotty target results above.

## Background research

The research below was done before the identity existed. Its starting state of zero identities is historical, not a current blocker. Developer ID and notarization remain unavailable on the free route.

Scope: sign Shotty, a private macOS app, with a free Apple Account (Xcode Personal Team) and run it on `mj-studio` and `mj-m1`. Researched 2026-09-25 from Apple primary sources. Nothing was created or changed in Xcode, keychains, or the Apple account. Starting state: `security find-identity -v -p codesigning` on `mj-studio` reports 0 valid identities.

## Answer

A free Apple Account can get an Apple Development certificate for a macOS app through Xcode's Personal Team. Apple lists Apple Development as the certificate type for running macOS apps (and other platforms) on devices during development, and lists Hardened Runtime as supported for the free "Apple Developer" tier on macOS. A Mac app that claims no restricted entitlements needs no provisioning profile, so the Personal Team 7-day profile limit should not apply to Shotty. Developer ID signing and notarization are not available to a free account. Apple's documented Personal Team limits are platform-generic, and Apple DTS has said there is no formal documentation of free provisioning limits. The macOS behavior over weeks and after certificate expiry therefore has to be tested.

## Facts

- Free tier. The macOS capability reference defines the "Apple Developer" column as Apple Account holders who accepted the Apple Developer Agreement: "No cost is associated with this agreement and developers can't distribute apps." In that table, Hardened runtime is checked for ADP, Developer ID, and Apple Developer. Capabilities like iCloud, push, and keychain sharing are not available to the free tier. https://developer.apple.com/help/account/reference/supported-capabilities-macos/
- Membership isn't required to build and test on personal devices. https://developer.apple.com/help/account/membership/programs-overview/
- Personal Team. After you sign in to Xcode with an account that has no program membership, Xcode shows it as a Personal Team. App IDs, devices, certificates, and profiles are managed in Xcode, and apps must be reprovisioned periodically. The page lists up to 10 App IDs and up to 3 devices, each expiring after 7 days, a limit of 3 apps per device, and provisioning profiles that expire 7 days after issuance. None of these limits is qualified by platform. https://developer.apple.com/support/compare-memberships/
- Certificate type. Apple Development is for running "an iOS, iPadOS, macOS, tvOS, visionOS, watchOS app on devices" during development. Developer ID Application is to "Sign a Mac app before distributing it outside the Mac App Store." Development certificates belong to individuals, and the developer account appends the computer name to identify them. https://developer.apple.com/help/account/certificates/certificates-overview/
- Creating an identity in Xcode: Xcode > Settings > Accounts, select the Apple Account and team, click Manage Certificates, click + and choose the type. Automatic signing normally does this for you. https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates
- Provisioning on macOS (TN3125): "Unlike Apple's other platforms, macOS doesn't require a provisioning profile to run third-party code." Unrestricted entitlements are `com.apple.security.get-task-allow`, App Groups, the App Sandbox entitlements, and the Hardened Runtime entitlements. "A Mac app that uses no restricted entitlements doesn't need a provisioning profile." When a Mac app does have a profile, it lives at `Contents/embedded.provisionprofile`. https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
- Developer ID requires the paid Apple Developer Program, with the Account Holder role, and allows up to five Developer ID Application certificates. https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
- Notarization requires a Developer ID certificate ("Don't use a Mac Distribution, ad hoc, Apple Developer, or local development certificate."), Hardened Runtime, a secure timestamp, and no `get-task-allow`. https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- Gatekeeper applies "When a user downloads and opens" software from outside the App Store. It verifies the software came from an identified developer, was notarized, and hasn't been altered, and it asks for approval on first open. https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web
- Designated requirement (TN3127). Xcode's Apple Development DR pins the leaf certificate CN `Apple Development: …` and the WWDR issuer OID `1.2.840.113635.100.6.2.1`. It differs from the Developer ID DR, so switching certificate types triggers new privacy prompts. https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
- Apple DTS (forum, not formal docs). "we currently don't have any formal documentation about the limits of our free provisioning (Personal Team) feature". Xcode should renew expired Personal Team certificates automatically. Certificates, Identifiers & Profiles on the website is paid-only. https://developer.apple.com/forums/thread/737307
- Apple DTS (forum). Only Developer ID signed code passes Gatekeeper. Other options, including a Personal Team Apple Development identity, require bypassing Gatekeeper. https://developer.apple.com/forums/thread/712555
- A forum report (user, not Apple) describes a Personal Team Mac app with App Sandbox and Hardened Runtime that failed to launch every few weeks with "could harm your Mac" until it was rebuilt. DTS suspected an expiring Personal Team resource, profile or certificate, and asked whether `embedded.provisionprofile` was present. The cause was not established. https://developer.apple.com/forums/thread/705932
- Notarization attempt with a Personal Team, reported by a user: Xcode issued an Apple Development certificate but refused notarization because the team "is not enrolled in the Apple Developer Program". https://developer.apple.com/forums/thread/121113

## Corrections to earlier claims

- Personal Teams can sign macOS apps with Apple Development. The capability reference, certificate types table, and DTS all say so. The earlier open question "whether Personal Teams sign macOS app targets" is resolved as yes by documentation and by the Shotty Release build on studio.
- Do not describe Personal Team Mac builds as expiring every 7 days. The 7-day figure applies to Personal Team App IDs, devices, and provisioning profiles, and Apple states it without naming a platform. On macOS, a profile is only needed for restricted entitlements (TN3125). If Shotty has no `embedded.provisionprofile`, the 7-day profile expiry has nothing to act on. The built Shotty app confirms it has no profile.
- The Personal Team certificate lifetime is not documented. Do not state a number.

## Steps

Markus signs in, because that creates credentials:

1. Xcode > Settings > Accounts > + > Apple Account. The team then appears as "Markus … (Personal Team)".
2. Shotty target > Signing & Capabilities: check Automatically manage signing, set Team to the Personal Team, and use a unique bundle ID. Keep Hardened Runtime and leave App Sandbox off. Do not add restricted capabilities such as iCloud, Push, Keychain Sharing, or Associated Domains. Xcode should create the Apple Development identity on first build. Manage Certificates > + > Apple Development is the manual route.
3. Read-only verification after the build:
   - `security find-identity -v -p codesigning` should list one `Apple Development: …` identity.
   - `codesign -dv --verbose=4 Shotty.app` should show `Authority=Apple Development: …` and `TeamIdentifier=` set to the Personal Team ID.
   - Run `codesign -d -r- Shotty.app` and record the DR.
   - `codesign -d --entitlements - --xml Shotty.app` should show only unrestricted entitlements.
   - `ls Shotty.app/Contents/embedded.provisionprofile` should find nothing. If a profile is present, run `security cms -D -i Shotty.app/Contents/embedded.provisionprofile` and record `ExpirationDate` and `ProvisionedDevices`.
   - `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject -enddate` records the certificate's CN and expiry.
4. For `mj-m1`, pick one of two routes:
   - Copy the app from `mj-studio` (`ditto`/`rsync` over SSH). One identity and one DR cover both Macs.
   - Sign in on `mj-m1` and build there. Each Mac then gets its own development certificate. Whether both certificates share the same CN, and so satisfy one DR, is untested.

## Empirical tests

Resolved on studio:

- Xcode 27 with the Personal Team signs the macOS Shotty target without an `embedded.provisionprofile`.
- The Screen Recording and Accessibility grants survive signed Release rebuilds on studio.

Still open:

1. Does Shotty still launch after the certificate's `notAfter` date (25 September 2027) with no rebuild? Record whether the signature has a secure timestamp (`codesign -dv` shows `Timestamp=` for secure timestamps). Without one, expiry behavior is unknown (inference). Keep one untouched build to test this.
2. Do the permission grants survive a Personal Team certificate renewal? Compare `codesign -d -r-` before and after.
3. Long-running check: Shotty still launches after 7 days and after 30 days without a rebuild. This directly tests the thread 705932 failure mode.
4. Fleet PR: the copied app launches on `mj-m1` with no Gatekeeper prompt, gets its own grants, and keeps them across an update. Check `xattr -l Shotty.app` for `com.apple.quarantine` after the copy, but judge the result by the actual launch. Record `spctl -a -vv Shotty.app` for reference; Apple Development code is expected to be rejected by spctl assessment even though an unquarantined copy may still launch.

If test 1, 3, or 4 fails, the fallbacks are rebuilding periodically (free) or the Apple Developer Program with Developer ID and notarization (99 USD/year), which is the only Apple-documented path that passes Gatekeeper.
