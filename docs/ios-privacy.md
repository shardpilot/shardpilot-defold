# iOS privacy manifest integration

**Unreleased:** the SDK supplies
[`shardpilot/privacy/PrivacyInfo.xcprivacy`](../shardpilot/privacy/PrivacyInfo.xcprivacy)
as a contribution to the game's privacy manifest. **Merge it explicitly into
the game's own manifest.** A loose file in this pure-Lua library is not proof
that it reaches an iOS bundle. Do not select the fragment alone as the game's
manifest: its empty required-reason API array would omit the engine's reasons.

This guide describes SDK source at `632128e16228cb1eb4c32b8fc09ea7db89b7fd38`
and the CI-pinned Defold 1.13.0 engine
`f735c12192bf95684e6ae1ae27c400b8170fc6d8`, measured on 2026-09-25.
It supplies an integration starting point, not an App Store disclosure or
proof that every supported game build includes the declarations. See
[#83](https://github.com/shardpilot/shardpilot-defold/issues/83) for the
source assessment and outstanding archive/report evidence.

## Merge into the game

1. Start from the **game's existing manifest**, preserving its own declarations
   and those of other dependencies. If it uses Defold's default, copy the
   `/builtins/manifests/ios/PrivacyInfo.xcprivacy` resource from the **engine
   version used by the game** into a game-owned resource, for example
   `/privacy/PrivacyInfo.xcprivacy`.
2. Merge the fragment's `NSPrivacyCollectedDataTypes` into that resource.
   Match rows by `NSPrivacyCollectedDataType`; combine purposes without
   duplicates. For a type used by several components, preserve `true` for
   linkage or tracking when **any** applicable use requires it. The table below
   identifies optional SDK features; omit a contribution only after establishing
   that the shipped integration cannot collect it. An initial unknown consent
   state is not evidence that collection cannot occur after a grant.
3. Preserve the game's `NSPrivacyAccessedAPITypes`, merging additional categories
   and reason codes from the actual engine and dependencies. The SDK fragment's
   empty array means **no additional SDK-owned reasons established by this
   audit**; it is not an instruction to clear the game's array.
4. Preserve `NSPrivacyTracking = true` if the game or any dependency tracks,
   and retain their tracking domains. The fragment's `false` and empty domains
   describe the SDK use below; they must not erase another component's entries.
   Add any extra data types and purposes your own payloads or uses require.
5. Select the merged resource in the game's existing `[ios]` section of
   `game.project` (do not add a duplicate section):

   ```ini
   [ios]
   privacymanifest = /privacy/PrivacyInfo.xcprivacy
   ```

   This is the [Defold privacy manifest setting](https://defold.com/manuals/project-settings/#privacy-manifest).
   Keep the SDK library's `include_dirs = shardpilot` unchanged.
6. Validate the merged file on macOS with
   `plutil -lint privacy/PrivacyInfo.xcprivacy`, build the actual iOS game, then
   inspect the effective manifest in its final app/archive and the Xcode
   privacy report. A valid source plist or a library ZIP is not this proof.

Repeat the merge review when the SDK, engine, other dependencies or collection
configuration changes. Commit the game-owned result with those version pins.
This SDK adds no native extension to trigger automatic manifest merging.

## What the fragment declares

The fragment covers the built-in data flows across analytics, consent,
configuration, experiments and crash reporting when those features are used.
It is a conservative union, not a claim that importing the module immediately
sends all eight categories. Names below have the prefix
`NSPrivacyCollectedDataType`; purposes have the prefix
`NSPrivacyCollectedDataTypePurpose` and use Apple's
[data-use keys](https://developer.apple.com/documentation/technotes/tn3184-adding-data-collection-details-to-your-privacy-manifest).

| Data type suffix | SDK fields or activity, and collection condition | Purpose suffixes in fragment |
| --- | --- | --- |
| `DeviceID` | Persistent SDK-generated per-app anonymous/client ID in events, consent receipts or explicit configuration fetches; experiment subject ID when experiments are enabled. These are not IDFA or IDFV. | `Analytics`, `AppFunctionality`, `ProductPersonalization` (configured variant/targeting use) |
| `UserID` | Host-supplied `identify(user_id)` on events, or a verified account actor for consent where configured. | `Analytics`, `AppFunctionality` |
| `ProductInteraction` | Sessions, screens, progression, host interaction events, enabled experiment exposure/outcome events and interaction breadcrumbs. | `Analytics` |
| `AdvertisingData` | Host-called ad-impression telemetry: impression/network/placement/format/revenue/currency, admitted under analytics consent. | `Analytics` |
| `PerformanceData` | Frame/performance summaries after a granted active session and host updates. | `Analytics`, `AppFunctionality` |
| `OtherDiagnosticData` | Ping/disconnect summaries and technical OS/build/module context when included in telemetry or diagnostics. | `Analytics`, `AppFunctionality` |
| `CrashData` | Native dump, Lua/manual exception, stack and bounded crash context after separate crash initialization, while enabled. | `Analytics`, `AppFunctionality` |
| `OtherDataTypes` | Consent state/category/time and the forced-minor denial reason on an explicit decision or retained receipt. No raw date of birth is generated or sent by this path. | `AppFunctionality` |

Every row declares **Linked = true, Tracking = false**. Persistent pseudonymous
IDs can link data to a device or account; their name or hashing does not establish
an unlinked use. The fragment includes supported linked crash integration too.
Standalone crash defaults have no configured actor/session identity, and previous
dump forwarding omits current identities; configured live crash reports can carry
them. A standalone variant may warrant a different linkage declaration only
after assessing its entire transport/backend correlation, not just missing
identity fields. See Apple's [linkage definition](https://developer.apple.com/app-store/app-privacy-details/#data-linked-to-the-user).

`NSPrivacyTracking = false`, no tracking domains and per-row tracking false
describe first-party product analytics, configuration and reliability. Typed
ad-impression revenue measurement does not itself supply an advertising SDK or
authorize tracking. Reassess customer endpoints, cross-company advertising,
brokers and other uses against Apple's [tracking definition](https://developer.apple.com/app-store/app-privacy-details/#tracking).
An analytics consent grant is not ATT authorization.

Custom properties, context, breadcrumbs and targeting values need the game's
own data mapping. For example, `geo` may require a location category at its actual
precision; `user_segment`, `custom_attribute_*`, gameplay or purchase payloads
may add types or purposes. The SDK does not automatically collect all those
values. Add `ProductPersonalization` to other data types if your actual use of
them customizes the experience; the fragment declares that purpose for the
identifier used in configured variant/targeting flows. Review purpose entries
against what your service actually does with each type.

## Defaults and consent boundaries

- Importing a module does not initialize its clients. A fresh analytics client
  creates/persists a random anonymous ID and starts with unknown consent.
  Analytics events require a grant; a stored grant can resume collection.
  Denial stops the analytics event path. Local persistence alone differs from
  off-device collection.
- Explicit consent decisions and retained receipts still transmit actor identity
  and decision metadata while analytics is denied or unknown. A fresh install
  without a decision has no receipt to send.
- An explicitly configured remote-config fetch transmits the anonymous client ID
  without requiring analytics consent. Targeting attributes require their opt-in
  and a grant. Experiments are off by default and have their own consent gates.
- Crash reporting requires separate initialization. Once initialized with valid
  configuration it is enabled by default on a fresh install, independent of
  analytics consent, with a persisted opt-out and failure-closed settings reads.
  Previous-dump forwarding defaults on; automatic Lua error-handler capture
  defaults off. `crash.set_enabled(false)` stops crash collection.

The complete storage, receipt and configuration rules remain in
[`privacy.md`](privacy.md), [`configuration.md`](configuration.md) and
[`crash.md`](crash.md). Analytics denial is not a global network-off switch.

## Engine APIs and the unused IDFV read

The traced SDK storage calls use Defold's Application Support paths and ordinary
file load/save operations. The clock path uses wall-clock time; frame samples
use host-supplied `dt`. Previous-dump reading uses the engine's crash file APIs.
These paths did not establish an additional SDK-owned required-reason API use.
Persistence alone is not evidence of UserDefaults or disk-space API use.

The pinned [Defold base manifest](https://github.com/defold/defold/blob/f735c12192bf95684e6ae1ae27c400b8170fc6d8/engine/engine/content/builtins/manifests/ios/PrivacyInfo.xcprivacy)
declares **FileTimestamp / C617.1** for the engine's archive `fstat` use and
**SystemBootTime / 35F9.1** for Remotery. Those are **engine/game declarations**,
not reasons introduced or supplied by this SDK. Preserve the engine version's
actual reasons in the game manifest. This source trace is not a whole-binary
API audit; later native SDK use needs its own accurate reasons under Apple's
[required-reason rules](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

There is an unused identifier read: [`platform.lua`](../shardpilot/platform.lua)
calls `sys.get_sys_info()` without `ignore_secure`. In the pinned engine,
[`script_sys.cpp`](https://github.com/defold/defold/blob/f735c12192bf95684e6ae1ae27c400b8170fc6d8/engine/script/src/script_sys.cpp#L791)
therefore requests secure info and
[`sys_apple.mm`](https://github.com/defold/defold/blob/f735c12192bf95684e6ae1ae27c400b8170fc6d8/engine/dlib/src/dlib/sys_apple.mm#L315)
reads IDFV. The SDK consumes only the platform name and **discards IDFV**; it
does not transmit that value or use it as its anonymous ID. This fragment does
not change that runtime behavior. The local IDFV read, off-device data collection
and required-reason API classification are separate findings.

## Archive evidence still required

The pinned [iOS bundler helper](https://github.com/defold/defold/blob/f735c12192bf95684e6ae1ae27c400b8170fc6d8/com.dynamo.cr/com.dynamo.cr.bob/src/com/dynamo/bob/bundle/BundleHelper.java#L265)
copies an extender-produced manifest when present, otherwise the game's selected
manifest resource. An arbitrary Lua dependency file is not selected by that
fallback. Verify at least the pure-Lua/no-native route and a game with a custom
manifest and other dependencies; do not infer one route's result from another.

For each claimed build route, retain SDK/engine versions, build command or Editor
settings, final app/archive manifest path and contents, `plutil` result, and the
Xcode privacy report. Check the merged data/linkage/tracking rows and retained
engine reasons. Existing Linux `bob-build` CI is not an iOS archive or privacy
report check. iOS bundle inspection, device/simulator/custom-engine coverage,
signing and App Store acceptance have not been established by this contribution.
