# Decisions

## Vendor phosphor_flutter rather than upgrade (2026-09-25)

**Decision:** Keep a patched copy of `phosphor_flutter` at `third_party/phosphor_flutter/`,
referenced by `dependency_overrides` in the root `pubspec.yaml`.

**Why:**
- `phosphor_flutter` 2.1.0 (the last published release) declares
  `class PhosphorIconData extends IconData`. Flutter 3.47.2 made `IconData` a `final`
  class, so this is a hard compile error on **every** platform. The app could not produce
  any binary.
- Upstream has not published a fix, and 2.1.0 is the latest version — there is nothing to
  upgrade to.
- Replacing the icon set with Material Icons would have changed the app's visual identity
  and required hand-mapping ~60 call sites.

**How the patch works:**
- `phosphor_icon_data.dart` no longer declares `PhosphorIconData` / `PhosphorFlatIconData`
  at all. The generated style files were rewritten so every icon is a plain
  `IconData(codePoint, fontFamily: 'Phosphor<Style>', fontPackage: 'phosphor_flutter',
  matchTextDirection: true)`. Font assets are unchanged, so glyph appearance is identical.
- Duotone two-layer rendering was removed (the `PhosphorDuotoneIconData` class depended on
  the illegal subclassing). Duotone icons still resolve to a single-layer glyph from
  `Phosphor-Duotone.ttf`. The app only uses the Regular and Fill styles, so nothing in the
  app changes visually.
- `phosphor_icons_base.dart` annotates with `IconData` and imports `flutter/widgets.dart`.

**Verify:** `flutter analyze` clean, 22/22 tests pass, both `build windows --debug` and
`build apk --debug` succeed.

**Revisit if:** upstream publishes a fixed version, or the app needs duotone icons.

## Cloud sync: relabelled EXPERIMENTAL, not built (2026-09-25)

**Decision:** Mark the Settings → Cloud sync section "EXPERIMENTAL / Coming soon" rather
than implement the Supabase sync worker. Chosen by the user over building the worker.

**Why:**
- The toggle persisted `kSyncEnabled` but nothing read it — the one feature in the app
  whose UI promised something the code did not deliver. Every other write path is real.
- The outbox side is already complete: all 7 entities (firms, parties, items,
  sales_invoices, purchase_bills, payments, expenses) enqueue insert/update/delete into
  `sync_queue` via `SyncQueueMixin`. Only the drain side is missing.
- Building the worker needs `Supabase.initialize` + a sync loop; without the user's own
  Supabase project URL/anon key it could not be verified end-to-end, so shipping it would
  have replaced one unverified claim with another.

**How to make it real later:** add `supabase_flutter` init (the dependency is already in
`pubspec.yaml`), a worker draining `sync_queue` honouring `kSyncEnabled`, and revert the
`_syncSection()` copy to "Sync books across devices via Supabase".

## `flutter test` excludes the golden captures (2026-09-25)

**Decision:** Light-mode goldens are a manual visual audit tool, excluded from the default
test run via `dart_test.yaml` (`exclude_tags: golden`) plus `@Tags(['golden'])` on
`library;` in `test/golden_light_mode_test.dart`.

**Why:** each capture opens drift streams whose teardown takes minutes; the artifact that
matters is the PNG a human eyeballs, not a pass/fail in CI. Leaving them in made
`flutter test` fail on teardown timeouts, which would train people to ignore a red suite.

**Gotchas:** `@Tags` carries `@Target({TargetKind.library})` — on `main()` it is silently
ignored and the tests still run. `exclude_tags` takes a comma-separated **string**, not a
YAML list. Regenerate with
`flutter test --tags golden --update-goldens test/golden_light_mode_test.dart`.

## `flutter analyze` does not validate buildability

`flutter analyze` does not type-check code inside the pub cache. The app reported a clean
analyzer while a dependency had a fatal compile error that blocked all native builds.
**A green analyzer is not evidence that the app builds.** Run the actual platform builds as
the real gate.
