# Signing verification: free Apple Development certificate for Shotty

## Native target verification, 25 September 2026

The milestone-0 Shotty target now builds with the existing identity, bundle identifier `local.markus.Shotty`, macOS 26 deployment target, and Hardened Runtime. The signed Release app passes `codesign --verify --deep --strict`, has no embedded provisioning profile, and has no entitlements after disabling Xcode's injected development entitlements for Release. An initial install and a rebuilt update both launched at `/Applications/Shotty.app` on studio through Computer Use; their designated requirements match. Screen Recording has not yet been granted, so permission continuity remains untested. Actual launch and permission checks on m1 are still pending. See [native verification](native-verification.md) for the current evidence and remaining gates. No paid membership, Developer ID identity, notarization, key export, or security bypass was used.

## Observed setup result, 25 September 2026

Markus signed into Xcode on studio. The free Personal Team is available. Manual Manage Certificates initially showed Apple Development disabled; selecting the Personal Team for a disposable target triggered automatic creation. `security find-identity -v -p codesigning` now reports one valid Apple Development identity. The issuer is Apple Worldwide Developer Relations Certification Authority, G3. The certificate is valid from 25 September 2026 at 14:00:20 UTC until 25 September 2027 at 14:00:19 UTC. The private key remains in the login keychain; nothing was exported or committed.

A disposable project at `/tmp/ShottySigningProbe` built successfully with Xcode 27 for macOS arm64, Release configuration, Apple Development signing, Hardened Runtime enabled, App Sandbox disabled, and bundle identifier `local.markus.ShottySigningProbe`. Output is `/tmp/ShottySigningProbe-build/Build/Products/Release/ShottySigningProbe.app`; build log is `/tmp/shotty-signing-build.log`. This probe is outside the repository and is not the Shotty application. Explicit signature/entitlement/profile inspection, actual launch on each Mac, and update/TCC-continuity tests have not yet run. The user requested a pause before app implementation to rename the GitHub repository/local folder and restart the desktop app.

The research below predates this successful identity creation and build. Its initial no-identity statements describe the earlier state, not a current blocker. Developer ID and notarization remain unavailable on the free route.

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

- Personal Teams can sign macOS apps with Apple Development. The capability reference, certificate types table, and DTS all say so. The earlier open question "whether Personal Teams sign macOS app targets" is resolved as yes by documentation. Xcode 27 behavior still needs one confirmation build.
- Do not describe Personal Team Mac builds as expiring every 7 days. The 7-day figure applies to Personal Team App IDs, devices, and provisioning profiles, and Apple states it without naming a platform. On macOS, a profile is only needed for restricted entitlements (TN3125). If Shotty has no `embedded.provisionprofile`, the 7-day profile expiry has nothing to act on. That is an inference from TN3125 and must be checked in the built app.
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

## Unresolved empirical tests

1. Xcode 27 with a Personal Team builds and signs the macOS Shotty target without an `embedded.provisionprofile`.
2. The Personal Team Apple Development certificate's `notAfter` date. Does Shotty still launch after that date, with no rebuild? Record whether the signature has a secure timestamp (`codesign -dv` shows `Timestamp=` for secure timestamps). Without one, expiry behavior is unknown (inference). Keep one untouched build to test this.
3. The copied app launches on `mj-m1` with no Gatekeeper prompt. Check `xattr -l Shotty.app` for `com.apple.quarantine` after the copy, but judge the result by the actual launch. Record `spctl -a -vv Shotty.app` output for reference. Apple Development code is expected to be "rejected" by spctl assessment, even though an unquarantined copy may still launch.
4. The Screen Recording grant survives a rebuild on each Mac (same DR). It also survives a Personal Team certificate renewal: compare `codesign -d -r-` before and after.
5. Long-running check: Shotty still launches after 7 days and after 30 days without a rebuild on both Macs. This directly tests the thread 705932 failure mode.

If test 2, 3, or 5 fails, the fallbacks are rebuilding periodically (free) or the Apple Developer Program with Developer ID and notarization (99 USD/year), which is the only Apple-documented path that passes Gatekeeper.
