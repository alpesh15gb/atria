# Decisions

## Conversion is a link, never a status (2026-10-04)

**Decision:** schema v9 adds `salesInvoices.convertedToInvoiceId` and
`convertedAt`. `markConverted` writes them and leaves `status` alone. Pre-v9 rows
that carry `status = 'converted'` stay exactly as they are, read through
`DocumentStatus.convertedLegacy`.

**Why:** conversion used to *overwrite* `status`. That destroyed the document's
real lifecycle — a quotation that had been sent became indistinguishable from a
cancelled one — and `markCancelled` on it silently un-converted it. One column
cannot carry both "expired" and "converted".

**Why the legacy rows are not migrated:** the invoice they became was never
recorded anywhere, so there is nothing to back-fill from. Rewriting them would
re-enable the convert action on quotations that have genuinely been invoiced,
which is worse than a row that reads oddly. They are kept, displayed as
"Converted", and `markCancelled` now *refuses* them — cancelling would wipe the
only record that they were invoiced.

## A stored legacy value is a constant, never `EnumName.name` (2026-10-04)

**Decision:** `DocumentStatus.legacyConvertedValue = 'converted'` exists
alongside `convertedLegacy`. All readers of the old column use the constant.

**Why:** the enum value is `convertedLegacy`, so `.name` is `"convertedLegacy"`
— it matches nothing in a database that stores `"converted"`. The failure is
silent and total: every guard returns false, so `markCancelled` accepts a
converted quotation and wipes its only flag. Found by a test that reverted the
guard and watched the guard-less behaviour return. **Verify any new legacy-column
read against the literal, not against the enum.**

## The vocabulary is one enum, scoped by document type (2026-10-04)

**Decision:** `lib/core/domain/document_status.dart` owns the labels, the chip
kinds, the allowed transitions and the expiry rule. `StatusChip.doc` and the
sales list's private `_statusText` / `_statusKindFor` both resolve through it.

**Why:** the vocabulary was written down twice and had already drifted —
`converted` fell through to a grey chip in one map and a blue badge in the other.
`StatusChip.doc` had one caller; the list had its own copy.

**"Accepted" is scoped to quotations deliberately.** An invoice is not accepted;
that word is meaningless for money owed. Each doc type gets its own state set,
and `of()` falls back rather than throwing, so a status from a restored backup
written by a newer build degrades to a plain chip instead of taking the list down.

**Note:** `confirmed` is in the quotation set because it is the *stored default*
for every saved document — the editor writes it unconditionally. Excluding it
left a freshly saved quotation with no legal moves at all. It is also why
`confirmed` means "open" for a quotation and "issued" for an invoice; the
transitions branch on doc type accordingly.

## Expired is derived, and only from the valid-till date (2026-10-04)

**Decision:** `DocumentStatus.isExpired` computes from `dueDate` (which is the
editor's "Valid till" for a quotation). No `expired` column, and `markStatus`
throws `ArgumentError` if asked to write it.

**Why:** the editor already has the field. A stored copy is one more thing that
can disagree with it, and it would disagree the moment the date moved. Invoices
are excluded deliberately — a due date passing makes an invoice *overdue*, not
expired; the document is unchanged, the money is late.

**Consequence:** an expired filter cannot ride in the SQL `WHERE`, so
`watchList` post-filters. That means the `limit` applies *before* the filter, so
"Expired" can return fewer rows than the limit on a busy month. Accepted: a
filter that silently under-reports is worse than one that pages, and the list
already states how many rows are loaded.

## The status filter is single-select, with "All" first (2026-10-04)

**Decision:** one `AtriaAdaptiveFilter<String>` after Date. Null means every
status. Its value is part of the list's stream cache key.

**Why the cache key matters:** the stream map is keyed by
`(docType, search, range)`. A filter that is not in the key returns the
*unfiltered* cached stream — the control works, the list does not change, and
nothing errors. This is the same class of bug as the one already recorded in
`STATE.md` about `_docType` being latched rather than derived.

**Why single-select:** a multi-select needs a control that stays visible while
you set it, and the filter row is one line of pills. A second sheet per list is
a worse trade than not offering combinations.

**"Converted" matches two shapes on purpose:** pre-v9 rows (status flag) and
post-v9 rows (the link). Matching the status column alone silently misses every
document converted since the upgrade — which is every document a new user has.

## The purchase side keeps its own conversion flag (2026-10-04)

**Decision:** `purchase_bills.status = 'converted'` is untouched.

**Why:** the purchase side has its own table, its own `markConverted`, its own
readers, and its own tests, and it is internally consistent. `DocumentRowMenu`
takes `convertedToInvoiceId` and treats *either* shape as converted, so the
shared menu behaves identically on both sides. Porting it is a separate change
with its own migration; bundling it here would make one commit touch two
lifecycles.

## Bulk delete counts what happened, never what was asked for (2026-10-04)

**Decision:** `SalesRepository.softDelete` and `restore` changed from
`Future<void>` to `Future<bool>`, and `bulkSoftDelete` treats `false` as a
failure. `BulkDeleteOutcome` carries the ids that were *confirmed* changed, and
that set — not the requested list — is what the undo is offered for.

**Why:** the repository's old bare `return` for an id it could not find is
correct behaviour for a single delete (there is nothing to report) and quietly
wrong at 200. "12 invoices deleted" for 11 rows that changed leaves the
operator believing their books are clean, and the undo then "restores" a
document that was never deleted — which, on a unique document number, can
collide with a live one.

**The alternative considered and rejected:** N existence-check queries up front
so the batch could report accurately without changing a repository signature.
That moves the cost to the fast path for every caller and still cannot cover a
row deleted between the check and the write. Making the repository honest is
strictly better: one source of truth, no TOCTOU window.

**Consequence:** any repository that wants to be usable in a bulk action should
return whether it did something. A `void` method cannot be called honestly
twice.

## Bulk delete is one transaction per row, not one transaction (2026-10-04)

**Decision:** `bulkSoftDelete` opens a transaction *per document* (via the
existing repository methods) and collects failures rather than throwing.

**Why:** these soft-deletes reverse stock and party balances. One transaction
around the whole batch means a single locked period halfway through a 200-row
delete rolls back all of it — leaving a button that either works or does
nothing at all, on documents that may have been selected by accident. Partial
progress plus an accurate report is more useful than all-or-nothing, and the
report is honest because of the decision above.

**Cost:** N commits instead of one. Measured as acceptable for the 200-row
cap; if a shop ever needs thousands, the right move is chunked batches of ~50
rather than reintroducing all-or-nothing.

## A selection is pruned against what is on screen, in build (2026-10-04)

**Decision:** the Sales list reconciles its `BulkSelection` into a **local**
inside the `StreamBuilder` builder, using `pruned(visibleIds)`, and only calls
`setState` from the tap handlers. `BulkSelection.pruned` returns the *same
instance* when nothing needs pruning, so the screen can compare by identity.

**Why:** the trap is operational, not visual — tick two invoices, delete one
from its own detail screen, come back, and the stale id silently joins the next
bulk delete. Reconciling in `build` (rather than in an effect) is what makes it
impossible to forget: the selection cannot be rendered in a state the visible
rows do not support. Mutating the field from `build` would throw; deriving it
locally is the only correct shape.

**Consequence:** the field is the *intent*, the local is the *truth*, and the
actions take the local. `BulkSelection` is immutable and has no `==` override,
so identity comparison in `_setSelection` is exact.

## The product is Apex Books; the Dart package is still `atria` (2026-10-04)

**Decision:** the rename covered everything a person can see — brand strings,
Android `applicationId`, the Windows binary name and version resource, the
installer, and the on-disk folders — but **not** the Dart package name, the
`Atria*` class names, or the `atria_*.dart` filenames.

**Why:** the package name is internal. Renaming it means rewriting every one of
the ~2,000 `package:atria/…` imports and every `.g.dart` codegen file, for zero
user-visible difference and a large chance of a mechanical mistake in 59 files.
The class names are the same story: `AtriaApp`, `AtriaLogo` and `AtriaListPage`
are identifiers, not branding. The rename used the regex `\bAtria\b` precisely
so these survived — `\bAtria\b` does not match `AtriaApp` because `A` is a word
character after it.

**Consequence:** a future developer will find `Atria` in the source and should
not "finish the rename" by sweeping it. The remaining occurrences are
deliberate, and this entry is the reason why.

**Deliberately not renamed:** `AppConstants.backupFileExt` (`.atriabak`,
declared and referenced nowhere), the Vyapar importer's `atriaId` locals and
`atria_vyapar_` temp dir (internal), and the server's `ATRIA_*` env vars
(a separately deployed service — changing them would break a running deploy).

## Changing `applicationId` is a data-loss event on Android (2026-10-04)

**Decision:** the rename changed `com.atria.atria` -> `com.apexbooks.app`, with
the user's explicit sign-off after being told what it costs.

**Why it matters:** Android's app-private directory is keyed by the application
id. The new id is a **different app** to Android — installing it is a fresh
install with no data, and the old package's database is unreadable to the new
package by design. There is no migration that can reach it.

**The asymmetry that makes this survivable:** on Windows the app-support root is
shared per-machine-user, so an in-place upgrade *does* find its books.
`AppDatabase.adoptLegacyDataDir` moves the old `atria/` folder across on first
launch, gated on the new folder not existing (so it is a no-op on every launch
after the first) and swallowing a failed move rather than refusing to start.

**Consequence:** an Android operator upgrading across this rename has **no** path
to their books except a backup. That is why `validateBackupJson` accepts both
the `Apex Books` and the legacy `atria` marker — refusing a pre-rename archive
would make every backup a customer had already taken worthless on the day they
needed it. If Android identity ever has to change again, the release note must
say "restore a backup", not "upgrade in place".

## The ledger is derived from documents, never written to (2026-10-03)

**Decision:** `LedgerRepository._book` re-reads the source tables (sales,
purchases, payments, expenses, journals, parties, accounts) and builds every
movement on each call. Reports are views, not stored state.

**Why:**
- Every report (`trialBalance`, `accountLedger`, `balanceSheet`) is recomputed
  from the documents each time, so a report can never disagree with the
  documents it summarises and can never go stale.
- The alternative — posting a real journal voucher when, say, a party's opening
  balance is set — fails three ways: the voucher goes stale when the party's
  opening is edited later; it is orphaned but still on the books when the party
  is purged (`deleteForever` refuses only when *documents* reference the party);
  and it puts an auto-generated row into a list the user edits by hand, with no
  way to tell them apart.

**Consequence for anything that shows a balance on screen:** it must read the
books through a provider that re-derives, and it needs an invalidation signal.
`watchBookMovement()` exists for that — it ticks once when any of the seven
posting tables moves. `cashBankBalancesProvider` is the pattern to copy. The
Payments cards used to sum the payment rows alone, which is exactly the
divergence this decision exists to prevent: a cash expense left "Cash in hand"
₹3,000 richer than the Cash account.

**The one place derivation is *not* used:** the hand-keyed journal vouchers
themselves, which are documents and live in `journal_entries`/`journal_lines`.

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

## The server is our own VPS: host nginx + Docker, no managed sync backend (2026-09-30)

**Decision:** `server/` scaffolds Atria's backend as Postgres 17 + one Dart (shelf) API
container on our own Indian VPS, fronted by system nginx at `api.apexbooks.in`. Sync
engine choice deferred, but the shape it will sit on is fixed: Postgres schema, RLS keyed
on `firmId`, client-minted UUIDv7 ids, migrations. `wal_level=logical` is switched on from
day one and `sync.apexbooks.in` is reserved (PowerSync needs a dedicated subdomain).

**Why:** offline-first means a dead VPS degrades to "not synced yet" rather than "app
down", so the availability bar is genuinely low — which is what makes single-VPS hosting
defensible. Data staying in India is a sales claim, not a legal one: DPDP §16 / Rule 15 is
a negative list (no localisation mandate), so the claim must be exactly true, backups and
all. Full reasoning and the rejected options (PowerSync, ElectricSQL, Firestore, the dead
Atlas Device Sync) are in `audit/06-sync-options.md` and `audit/07-self-hosted-india-vps.md`.

**Gotchas:** (a) The Postgres image does not export `PGHOST`/`PGDATABASE`/`PGUSER` and
starts socket-only during init, so `db/init/01-init.sh` sets them explicitly before calling
the migration runner. (b) `psql -c` does **not** interpolate `:'var'` — only `-f` files are
parsed client-side, so the runner interpolates the filename in the shell instead; a `-c`
string with `:'version'` reaches Postgres as a syntax error at the colon. (c)
`docker-entrypoint-initdb.d` runs only on an *empty* data directory, so a new migration
never applies to an existing volume by itself — use
`docker compose --profile tools run --rm migrate`. (d) The application role must not own
the tables: a table's owner bypasses RLS, which would make every policy decorative. (e)
`psql`/Postgres: a policy on a table that queries itself recurses, so the membership check
lives in a `SECURITY DEFINER` function. (f) PowerSync (if adopted) copies rows verbatim
into client SQLite, so Postgres table and column names must match the drift tables'
snake_case names — hence no camelCase anywhere in the schema. (g) `dart compile exe -o`
does not create the output directory. (h) `Uri()` in Dart validates user-info rather than
encoding it, so a base64 database password containing `/`, `+`, `@` or `#` must be
percent-encoded by hand or boot throws.

## Client configuration: which server, and which device (2026-09-30)

**Decision:** `lib/core/api/api_config.dart` resolves the API address in three layers — the
`api_base_url` setting first, then `--dart-define=ATRIA_API_BASE_URL`, then the deployed
`https://api.apexbooks.in` — and mints a `device_id` (UUID v7) once per install, persisted in
`app_settings`.

**Why:**
- Until now there was nothing to configure. The only cloud-shaped UI is the Supabase URL +
anon key box, which is inert and now names the wrong vendor: the backend is ours, at
`api.apexbooks.in`.
- Resolution is **not** cached, because the Settings screen writes the address at runtime;
a cached field would keep sending requests to the previous server until restart, which is
the half-configured state the UI would fail to show.
- An unusable stored address **throws** rather than falling back to production. A silent
fallback would send someone's sign-in — and their password — to a server they did not type.
- The device id is minted and persisted, never derived from hardware or hostname: a cloned
VM image or a renamed machine must not look like a second device, and the server binds
refresh tokens to this id, so re-minting signs the machine out of everything.

**Not built yet:** there is no HTTP client at all (`http`/`dio` are absent; `supabase_flutter`
pulls `http` transitively, which is not a reason to depend on it), no sign-in UI, no token
storage, and no worker draining `sync_queue`. `kSupabaseUrl` / `kSupabaseAnonKey` are now
vestigial; the Settings section should become "Atria server address" plus sign-in.

**Gotchas:** (a) `Uri.parse` is lenient — `"not a url"` parses to the host
`not%20a%20url`, so an explicit hostname shape check is required or the mistake surfaces
much later as a DNS error nobody can act on. (b) A trailing slash must be stripped before
use: every endpoint appends its own path. (c) `deviceId()` is single-flight; without that,
two callers racing on first launch each mint an id, one write loses, and the loser then
sends a `deviceId` the server has never seen.

**Verify:** `flutter analyze` clean; 18/18 in `test/api_config_test.dart`.

## Windows release packaging: bundle the MSVC runtime, install per-user (2026-09-30)

**Decision:** `windows/CMakeLists.txt` now installs the MSVC runtime next to the executable,
and `installer/atria.iss` (Inno Setup 6, installed at `C:\InnoSetup6\`) produces
`Atria-1.0.0-setup.exe` — a per-user install by default, with a dialog override for
all-users.

**Why:**
- The release bundle shipped **no** `msvcp140.dll`/`vcruntime140.dll`. A machine that has
never had the Visual C++ 2015-2022 redistributable fails in the loader before any app code
runs — no window, no error, just a click that does nothing, which is exactly the support
call we cannot diagnose from here. Bundling app-locally removes the dependency.
- Per-user by default so it installs without a UAC prompt on a shop PC where the person
installing is not an administrator; `PrivilegesRequiredOverridesAllowed=dialog` keeps the
all-users install available for an administrator.

**Gotchas:** (a) `InstallRequiredSystemLibraries` adds its own
`install(PROGRAMS ... DESTINATION bin)`. Flutter sets `CMAKE_INSTALL_PREFIX` to the
generator expression `$<TARGET_FILE_DIR:atria>`, and a *relative* destination cannot be
combined with that — the install script tries to create a literal directory named
`$<TARGET_FILE_DIR:atria>/bin` and fails the whole build with `file cannot create
directory`. Set `CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE` **before** including the
module, then install the DLLs yourself into the bundle dir. (b) Including the module alone
copies nothing — `CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS` has to be installed explicitly.
(c) `flutter analyze` clean and `flutter build windows --release` are different gates:
the analyzer never catches a broken install script, so the build is the real one.
(d) Inno's `{group}` and `{autoprograms}` both resolve under Start Menu\Programs, so using
both creates a folder *and* a loose shortcut with the same name.

**Verify:** `flutter build windows --release` succeeds and the bundle contains the eight
`msvcp140*`/`vcruntime140*`/`concrt140` DLLs; a silent install into a throwaway directory
registered `Atria 1.0.0 / com.atria` in Apps & features, and a silent uninstall removed both
the directory and the registry entry. Details in `installer/README.md`.

**Limits:** the setup exe is unsigned (SmartScreen will warn until there is a real
code-signing certificate), x64 only, and there is no auto-update.

## The server address is configured in Settings, and the Supabase box is gone (2026-09-30)

**Decision:** Settings → **Atria server** → *Server address*, saved to the `api_base_url`
setting, with a *Test connection* button. The Supabase project URL / anon key fields were
removed. The field is shown whether or not the sync toggle is on — pointing the app at a
server is a real, working setting, whereas only the sync worker is experimental.

**Why:**
- Before this, `api.apexbooks.in` was a constant in `ApiConfig` with no UI at all — there was
no way to point an installed build at a staging server, and the one cloud-shaped field on
the screen fed a Supabase project that no code has ever read.
- The field is pre-filled with the address **actually in force** (setting → `--dart-define`
→ built-in), not with the raw setting. Showing the raw setting would leave the box empty
while the app talks to production, which is the screen lying about the state of the world.
- An unusable address is refused with a reason and *not stored*: an address with a path, or
plaintext `http://` to a remote host, would otherwise fail later on a different screen with
nothing to connect it back to this box. Clearing the field reverts to the built-in address.
- `Test connection` refuses to be fooled by a healthy status alone. The Go server Atria
replaced on `api.apexbooks.in` answered HTTP 200 with exactly `{"status":"ok"}`; the API's
`version` field is what distinguishes ours from anything else that happens to answer.

**Gotchas:** (a) A `testWidgets` body runs under FakeAsync, where drift's **writes** never
complete — so anything that awaits one (here, minting the device id during `_loadSettings`)
hangs the test rather than failing it. Seed rows in `setUp`, which is outside FakeAsync.
(b) A `ListView` builds children lazily, so a section below the fold is simply not mounted
and cannot be found or typed into — scrolling in a widget test is needed, and `SettingsScreen`
has no widget-test harness in this repo for that reason. (c) `_loadSettings` now writes, so
it is wrapped in try/catch: a failed write must not leave the section on its spinner for
ever.

**Verify:** `flutter analyze` clean; 26 unit tests (18 `api_config`, 8 `server_probe`) green;
`flutter build windows --release` succeeds and both installer artifacts were rebuilt after
the change, so the packaged app contains the field. The section's *rendering* is covered by
the on-demand settings golden capture, not by an automated test.

## Erasing a business: `DELETE /v1/firms/{id}`, and a local-only or local-and-server choice (2026-09-30)

**Decision:** "Purge" means **erasing a whole business**, not the recycle bin. Three pieces:

1. **Server:** `DELETE /v1/firms/{firmId}` — a real `DELETE`, authorised by the existing
   `firms_delete_admin` RLS policy, cascading `firm_members`. A 404 covers *no such firm*,
   *not your firm* and *not an admin of it* alike. Migration `0002_firm_purges.sql` adds
   `app_firm_purges` (firm id, account, timestamp — nothing else) in the same transaction.
2. **Client:** Settings → Firm Profile → *Danger zone* → **Remove this business**, offering
   **"Only on this device"** or **"Here and on the Atria server"**, then a type-the-name
   confirmation. Server first, then the local wipe.
3. **Local:** `FirmRepository.purge` + a shared `eraseFirmRows`, which the Vyapar importer's
   rollback also uses now (one implementation instead of two).

**Why:**
- The audit already named this as missing (`audit/07` §9): a DPDP Rule 8 erasure claim needs
  deletion to *propagate*, and "a sync tombstone is not an erasure". The endpoint had to
  exist before the sentence could be written.
- **The ledger is what makes the erasure stick.** Without it, a device that was offline when
  the deletion happened pushes the firm back on its next sync and silently undoes it. Firm
  ids are client-minted UUID v7, so refusing one can never block a legitimate create —
  `POST /v1/firms` now answers 409 for a purged id.
- Erasing is **not** deletion of a document: there is no recycle bin behind a whole set of
  books, which is why the flow asks for the business name rather than "PURGE".
- The local wipe is explicit, child-before-parent, **not** a reliance on `ON DELETE
  CASCADE`: `stock_movements`, `app_settings`, `sync_queue` and `audit_logs` carry a
  `firm_id` with no foreign key at all, and an in-memory test database has
  `PRAGMA foreign_keys` off, so a cascade would have looked correct and left orphans.
- **Nothing is written to `sync_queue`** for a firm deletion, in either mode. A queued
  `firms`/`delete` would be wrong for "this device only", and would erase *itself* — the
  outbox row carries the firm's id and the purge deletes exactly those rows.
- Server-before-local ordering: the dialog promises the data is gone from Atria, so a local
  delete that then failed to reach the server would be a claim that is not true.

**Limits, deliberately accepted for now:**
- **The server option is disabled until sign-in exists.** There is no sign-in UI and no
  token storage, so `ServerSession.current()` returns null on every install today. The sheet
  says *why* rather than offering a button that would fail. `ServerClient.eraseFirm` and
  `ServerSession` are the whole seam: sign-in fills in `save()` and nothing else changes.
- "Only on this device" does **not** queue a removal. If the account is signed in again
  later, the server copy comes back — which is what the option says it does.
- A **restored backup** can re-create a purged firm locally; the push is then refused (409),
  so the business exists on that device and nowhere else. Alerting that case is future work.
- The firm's logo PNG (a shared `logos/firm_logo.png`, so it cannot simply be deleted when
  one firm goes) is **not** removed from disk.

**Gotchas:** (a) `shelf_router` passes path parameters positionally **only to an unwrapped
handler** (`RouterEntry.invoke` checks `_handler is Handler || _params.isEmpty` first), so a
handler wrapped in the `authenticate` middleware must read `request.params['firmId']` — a
`(Request, String)` signature behind `guard(...)` compiles and then throws at runtime on
every call. (b) `firm_members`, `sales_invoice_items` etc. cascade from `firms` because
referential actions bypass RLS — a membership row can be removed by a statement that had to
pass the `firm_members` policies to be authorised. (c) `dart:io`'s `HttpClient`, not an HTTP
package, matching `ServerProbe`. (d) `DELETE` bodies and `SocketException` never overlap: a
request that never got an answer has no status code, so `ServerRequestException.statusCode`
is nullable and "could not reach Atria" is a distinct message from an HTTP failure.

**Verify:** server `dart analyze` clean and `dart test` 51/51 (was 46); app `flutter analyze`
clean and `flutter test` 233/233, including 7 new `firm_purge` tests (one of which reads
`sqlite_master` for every table with a `firm_id` column, so a table added without teaching
`eraseFirmRows` about it fails the suite), 7 `server_session`, 7 `server_client` (against a
real loopback `HttpServer`). `scripts/smoke-test.py` **49/49** (was 34) on a throwaway local
stack, including that a **member who is not an admin** is refused, that the firm row and its
memberships are really gone from Postgres, and that the ledger holds three columns and no
firm data. Not yet run against the live VPS: migration 0002 must be applied there with
`docker compose --profile tools run --rm migrate`, which this machine has not touched.

## A floating panel carries its own edge, app-wide: menus, popovers and dropdowns (2026-09-30)

The top bar's business switcher looked transparent: with the menu open, the dashboard's
"Good Afternoon" line and the business name appeared to read straight through the panel.
The panel was not transparent. Measured off the report's screenshot, its surface is a solid
`#FFFFFF` and its items are drawn on top of it — but its top edge landed on the dashboard's
white header band (a `SliverAppBar` on `scheme.surface`, under a chrome band of the same
white) with only a drop shadow for separation, and at that distance the shadow is around one
part in 255 of a dim 8% grey. The edge was invisible, so the page's own text read as the
menu's contents. QBO's menus are hairline-bordered for the same reason.

- `menuShape` in `app_theme.dart` now carries `side: BorderSide(color: scheme.outline)`, which
  is what `cardTheme` and the chrome band already do — a hairline does the separating, not
  elevation. It feeds `popupMenuTheme`, `menuTheme`, `dropdownMenuTheme` and the pickers.
- Six `PopupMenuButton` call sites re-set `color`, `elevation: 8` and a borderless `shape`,
  silently overriding that theme: the top bar's two menus, the Create menu, the list toolbar's
  segment select, the row-action menu and `transaction_list`'s. They now inherit the theme, so
  there is one menu surface in the app instead of six private ones, at the theme's elevation 3.

**Verify:** `test/menu_surface_test.dart` opens the real switcher over a white band, captures
the frame through a `RepaintBoundary` placed above the navigator's overlay, and asserts the
panel's top and left edges render `AppColors.outline` while its inside renders the opaque
surface. Removing the hairline fails it with `BorderStyle.none`.

**Gotchas for capturing a widget test's pixels:** `RenderRepaintBoundary.toImage` only settles
on the real event loop, so the capture must run inside `tester.runAsync` — awaited from the
test body it hangs forever (no failure, just a test that never finishes). And hand the tree a
firm directly (`activeFirmProvider.overrideWith((ref) => Stream.value(firm))`): subscribing it
to the real drift stream closes that stream on teardown, and the zero-duration timer drift
schedules for the close trips flutter_test's "A Timer is still pending" invariant.

**App-wide, the same bug had three more homes**, found by walking every surface that opens
without a barrier — `PopupMenuButton`, `MenuAnchor`, `DropdownMenu`, the popovers the SDK does
not theme, and `DropdownButton`:

- The **type-ahead item picker** (`item_type_ahead.dart`) and the **HSN code lookup**
  (`item_editor_screen.dart`) each hand-rolled their own `Material` — and the type-ahead's
  comment even claimed to match `popupMenuTheme` while carrying a `borderRadius` and no `shape:`.
  A `Material` with a radius but no shape *cannot* draw a border, so both dropped edgeless white
  panels onto the white editor page. Both now use `AppTheme.menuShape(scheme)` and the theme's
  `menuElevation`, and both had been silently picking up Material 3's surface tint as well.
- `DropdownButton` paints its menu with `dropdownColor ?? canvasColor`, and there is **no
  `DropdownButtonTheme` in Flutter 3.47**, so all 26 dropdowns in the app opened a panel in
  `ThemeData.canvasColor` — which this theme had set to the *page* grey: a panel the same colour
  as the page it covered, square-cornered (the radius defaults to zero), defined only by Material
  2's drop shadow. `canvasColor: scheme.surface` is the whole fix, one line for all of them. The
  blast radius was audited before changing it: nothing else in `lib` reads `canvasColor` (every
  hand-built `Material` passes an explicit `color:`), there is no `Drawer`, and `Scaffold` /
  `BottomSheet` are pinned by `scaffoldBackgroundColor` / `bottomSheetTheme`. The SDK's *default*
  autocomplete options view (`Material(elevation: 4)` with no colour) had the same problem, and
  the payments screen still uses it — the same line fixes that too.
- **Deliberately not changed:** dialogs and modal sheets stay borderless, because their barrier
  dims the page and that dimming is their edge; and dropdown menus keep square corners, because
  the only knob is a per-call-site `borderRadius:` and a 26-site sweep over 15 files of other
  in-flight work is not worth a cosmetic radius. Recorded here so nobody "fixes" either by
  accident.

- **Dark mode was drawing black halos around every raised surface.** `ColorScheme.shadow` for the
dark theme was `Colors.black`, Material 3's default, and `Material` draws its elevation shadow
with `canvas.drawShadow(path, shadowColor, elevation, …)` — which scales the drawn shadow by that
colour's alpha. An opaque shadow colour therefore paints an almost solid black band: a hard black
edge behind dialogs, menus, cards and the FAB. The light scheme had always been 8%
(`0x14393A3D`, i.e. `AppShadows.card`'s quiet language); dark is now `0x80000000`, matching
`AppShadows.darkCard`. Found by the dark half of the pixel test, which failed on `0xFF000000` at
the panel's edge — the hairline is no longer the strongest thing at that edge.

**Guarded by `test/theme_surface_test.dart`:** for light *and* dark it asserts that
`popupMenuTheme`, `menuTheme`, `dropdownMenuTheme` and both picker themes are the opaque surface
at `AppTheme.menuElevation` with an `outline` hairline, that `cardTheme` and `appBarTheme` keep
the page hairlines, and that `canvasColor` is the panel colour rather than the page's. Its last
test scans `lib/**/*.dart` for the anti-pattern that produced the two popovers — a raised
`Material(` with no `shape:` — and fails with the fix in the message. Run on its own before the
fix it named exactly those two files and nothing else. It also asserts no scheme uses a
near-opaque shadow colour, and `test/menu_surface_test.dart` opens the real switcher over a band
of the panel's own colour in *both* themes and checks the panel's top and left edges are painted
in the outline colour with the opaque surface inside.

## Sign-in exists: `ServerSession`, `AuthClient`, and where a token renewal lives (2026-09-30)

**Decision:** Added `lib/core/api/auth_client.dart` + `lib/core/state/auth_controller.dart` and a
`/settings/sign-in` screen. The four `app_settings` keys (`access_token`, `refresh_token`,
`access_token_expires_at`, `user_email`) now have a writer.

**Why it had to come first:** it was the gate in front of everything account-scoped — "erase this
business from the server" was permanently disabled, the device list was unreachable, and a change
push has no token to present. `ServerSession` was already complete and unused, which is why this
is wiring plus two clients rather than a new design.

**Choices worth keeping:**

- **Renewal is a network call, so it lives in `AuthController`, not in `ServerSession`.** The
  rules: a live token is used with no round trip; an expired one is renewed once, silently, when a
  refresh token exists; a renewal the server *rejects* (401/403) clears the session locally,
  because retrying a revoked token can never succeed; a renewal that merely *failed* (offline,
  timeout) leaves the session in place. Being offline is not being signed out — that distinction is
  the whole reason the logic is not "if expired, sign out".
- **Refreshes are single-flight.** Refresh tokens rotate on every use, so two callers (a push and
  a manual erase) hitting an expiry at the same moment would have the second present a token the
  first already replaced, and the device would be signed out by its own retry.
- **The password is never stored**, only the token pair, and only through `ServerSession`. The
  settings screen's own note still stands: those rows are plaintext SQLite, and an OS-backed store
  (DPAPI / Keystore) remains separate work.
- **Sign-out is local-first.** It revokes the token when the server answers and clears the local
  session either way, returning a note when the revoke could not be delivered. Signing out on a
  train has to work.
- Server erase now goes through `AuthController.accessToken()` rather than reading
  `ServerSession.current()` directly, so "signed in yesterday with an expired access token" is no
  longer reported as "sign in again" in the one flow that must not say that.

**Guarded by** `test/auth_client_test.dart` (11 tests, real `HttpServer`: paths, device identity,
the 30-second expiry slack, a 200 with no tokens refused, a 401's own message, offline) and
`test/auth_controller_test.dart` (7 tests: launch with no session, a live token used with zero
network calls, silent renewal, a rejected refresh signing the device out, offline *not* signing it
out, sign-out offline and online).

## The outbox drains: push-only sync, journal on the server (2026-09-30)

**Decision:** `lib/core/sync/sync_engine.dart` drains `SyncQueue` into a new
`POST /v1/firms/<firmId>/changes` endpoint (server: `sync_repository.dart` + migration
`0003_firm_changes.sql`). **Push only** — no pull, no merge, no conflict resolution.

**Why push-only is a stopping point and not a half-feature:** pushing is worth having on its own —
the server ends up holding what each device sent, and the outbox (written on every save since day
one, read by nothing until now) stops growing without bound. A merge that guesses would silently
corrupt the books it was meant to protect, and the open question in `audit/06` §5 (which columns
are client-owned vs derived) is not answered by shipping one.

**What makes it safe to run at any time:**

- **The journal is append-only.** `firm_changes` has no UPDATE or DELETE policy, so a push can
  never destroy data on the server, and a later merge can be computed from the journal rather than
  guessed. Erasure still works: the firm's `ON DELETE CASCADE` takes the journal with it.
- **`change_id` is the device's own outbox id**, so a batch that landed but timed out on the way
  back is idempotent on retry, and the response reports `duplicates` instead of failing — a retry
  that worked must not look like an error.
- **Order is preserved** (`createdAt, id`), and a failed batch stops the run rather than skipping
  ahead: a hole in the order is exactly what breaks a replay later.
- **A failure is recorded, not lost.** `attempts = attempts + 1` and the reason are written on the
  exact rows that did not go, in one SQL statement (reading the count into Dart and writing back a
  sum would lose a concurrent increment). The failure does *not* move `sync_last_pushed_at`, so the
  screen cannot claim the books were sent when they were not.
- **`payload` is the row's current state**, normalised to drift's own `toJson()` shape. A raw
  `SELECT` hands back SQLite's storage form, and pushing that would have put `is_deleted: 0` in the
  journal, where nothing can tell it from a count. Booleans are converted, and drift's *seconds*
  timestamps become milliseconds, matching `toJson`.
- **A firm is registered once per install** before its first push (`kSyncRegisteredFirms`):
  `firm_changes.firm_id` is a foreign key, so pushing before the firm exists fails on a constraint
  the operator cannot act on. A 409 from `/v1/firms` is treated as success.
- **Sent rows are pruned after 14 days**, never unsent ones. The outbox grows on every save (fifty
  invoices a day is hundreds of rows); the queue is also the only device-side record of what was
  sent, which is why it is kept rather than deleted the moment it lands.
- The device id is **not** sent: the server reads it from the access token's own `dev` claim, which
  it has already verified.

**Deliberately not done:** `/ready` now probes `firm_changes` too, so a database at 0002 reports
`schema_missing` rather than serving 500s on every push. The live VPS still needs
`docker compose --profile tools run --rm migrate` (it is at 0001 and also missing 0002).

**Guarded by** `test/sync_engine_test.dart` (12 tests, real `HttpServer` + real outbox: toggle off,
signed out, empty outbox, register-once, ordering, failure recording, duplicate retry, an orphan
row retired with a reason, pruning, tombstone with a null payload, the bearer token) and
`server/api/test/handler_test.dart` (new `change push` group: 401 without a token, a bad firm id, an
empty push as a 200, a non-list body, an unknown operation naming `changes[0]`, an injection-shaped
entity name, the batch cap, and a well-formed change reaching the database). 274/274 app tests,
59/59 server tests, both analyzers clean.

## Tax at source is wired: TDS on purchases, TCS on sales (2026-09-30, schema v6)

**Decision:** `PurchaseBills.tds` / `SalesInvoices.tcs` now have writers. New rate columns
(`purchase_bills.tds_rate`, `sales_invoices.tcs_rate`) record the percentage the amount came from,
so an invoice can print "TCS @ 0.1%" and a report can re-derive rather than guess. Editors gained a
TDS % / TCS % field; the sale editor prefills from `Firms.invoiceTcsRate`, which until now was
another column nothing read.

**The arithmetic, which is the part worth getting right:** both are charged on the **taxable
value**, not the grand total. s.206C(1H)'s Explanation excludes GST from the sale consideration TCS
is charged on, and a 194Q deduction is taken on the value of the goods rather than on the GST the
buyer also remits. Charging on the total would over-deduct by the tax on every single document.
`GstEngine.settlementTax` is that rule in one place, and returns zero for a null rate so a caller
with no field wired up behaves exactly as before.

**Direction:** TCS is *added* to the invoice value (the customer owes it), TDS is *subtracted* from
what the supplier is paid. Both therefore change `grandTotal`, which is what `balanceDue`,
`paymentStatus` and every payment path already derive from — no other code needed teaching.

**Where it shows:** editor totals rows ("TCS 0.1%" / "TDS 0.1%", signed), the sale detail card, the
invoice PDF (between the tax and the round-off, matching the order the value is built in), and a new
**Tax at source** card in Reports fed by `ReportRepository.taxAtSource` — deliberately *not* folded
into `GstSummary`, because neither is GST and mixing them would make the number the operator files
against wrong. The card names the challan (ITNS-281, by the 7th).

**Verify:** `test/tds_tcs_test.dart` (6 tests: TCS on the taxable value, TDS on the taxable value,
no rate changing nothing, a TCS-inclusive total settling an invoice, an edit that removes the rate
putting the total back, and the report reading stored totals rather than recomputing). 280/280 app
tests, analyzer clean.

## Cheques have a lifecycle, and a bounce reverses the settlement (2026-09-30, schema v6)

**Decision:** `payments` gained `cheque_status`, `deposited_at`, `bounced_at`, `bounce_reason`, and
`PaymentRepository` gained `markChequeDeposited` / `markChequeCleared` / `markChequeBounced` plus
`watchUnclearedCheques` / `watchBouncedCheques`. The payments screen gained a cheque status chip, a
per-row cheque menu, and a bucket of everything still awaiting clearance.

**Why a lifecycle and not a flag:** the three states mean different things to the books. A cheque in
hand is money *promised*; deposited is still not arrived (the bank can return it); only cleared is
money. `chequeStatus` is set to `pending` by `PaymentRepository.create` itself when the mode is
`cheque`, so every path that records a cheque — the screen, a POS settlement, an import — starts in
the same state and the transitions have something to act on.

**The one rule that changes the numbers:** a cheque in hand keeps settling its document (the
optimistic reading every Indian billing app uses), and **a bounce releases it**. `_recomputeLinkedDoc`
skips payments whose status is `bounced`, so the invoice goes back to `unpaid` with its balance
restored instead of sitting Paid against a returned cheque. Re-depositing a returned cheque settles
it again and clears the old reason — the bounce was dealt with, and leaving the reason on the row
would keep a reversal in the books for ever.

**Reach:** the balances cards (`cashIn` / `bankIn` / `chequeIn`) ignore bounced cheques and count a
cheque only in the "Cheques to deposit" card, never in the bank balance. The bucket is *not* filtered
by the screen's date window on purpose: the cheque taken last quarter is exactly the one still
waiting, and hiding it behind "This month" is how a deposit gets forgotten.

**Guarded by** `test/cheque_lifecycle_test.dart` (7 tests: starts in hand and settles, depositing
moves nothing, clearing records the date and leaves the bucket, a bounce releases the invoice and
keeps the reason, re-deposit restores the settlement, cash has no cheque state, and a locked period
refuses the transition). 287/287 app tests, analyzer clean.

## Double entry: the chart of accounts and journal vouchers

The app could say how much was sold and how much each party owed, but it had no
accounts, so there was nowhere to put capital, depreciation or an opening
balance, and no report that could prove the books added up. Schema v7 adds
`accounts`, `journal_entries`, `journal_lines` (`lib/core/database/tables/ledger.dart`).

**Nothing is stored twice.** `LedgerRepository` posts the documents the app
already writes into accounts at read time rather than keeping a posting table:
an edited invoice changes the ledger immediately and there is no second copy to
drift. Document types that are not transactions (quotations, orders, delivery
notes) and cancelled documents are excluded, matching the P&L and the GST
returns. Credit notes and debit notes post into returns accounts rather than as
negative sales, which is how a return reads on a P&L.

**The rules the postings follow**, in one place each: shipping is revenue but
not taxable value; TCS collected is a liability, not income; TDS deducted is a
liability the buyer now owes the government (not a receivable); freight and
other charges on a bill are part of what the goods cost; a cheque sits in
"Cheques in hand" until the bank clears it and only then reaches the bank
account, so the ledger follows the cheque actions H6 added.

**A journal voucher must balance** — enforced in the repository *and* by the
unique index and the validation in `createJournal`, and shown live in the editor
while it is typed. Deleting a voucher is a soft delete so the numbering stays
intact; the next voucher never reuses a number.

**Reports**: trial balance (opening, movements, closing, with a balanced/out of
balance banner), balance sheet (assets, liabilities, equity, with profit to date
folded into equity — the app has no year-end close, so the sheet balances by
construction), and a per-account ledger with a running balance. 29 tests in
`test/ledger_test.dart`, most of which assert the trial balance agrees.

`eraseFirmRows` learned the three tables, and `test/firm_purge_test.dart` now
seeds one account and one voucher per firm, so a firm-scoped table that is not
taught to the purge fails the suite (the fixture discovers tables from
`sqlite_master` rather than listing them by hand).

Deliberately not done yet: `MoneyAccounts` as a first-class entity. Payments and
expenses post to Cash / Bank / Cheques in hand by their mode, so the ledger is
right, but "HDFC Current A/c 4412" is still free text on the payment rather than
an account with its own reconciliation. That is the next step for money
accounts; the ledger gives it somewhere to post.

## Expense GST is input credit (and the reports had never seen it)

`gstSummary()` computed input tax from purchase bills alone, so the GST inside a
rent, software or professional-fee bill was silently added to GST payable. It now
reads the expense GST too (`LedgerRepository.inputTaxFromExpenses`, which clamps
the component to the expense total) and reports it as its own line,
`GstSummary.inputFromExpenses`, which flows into `totalInputCredit` and
`netPayable`. GSTR-3B adds it to 4(A)(5) "all other ITC".

It is reported as one amount, not split across CGST/SGST/IGST: an expense carries
a single GST figure and no place of supply, so a split would be invented. Adding
the place of supply to expenses is the change that would allow a proper split.

`gstSummary()` also lost its N+1: it called `itemsFor(invoiceId)` inside the loop
over the month's invoices. `SalesRepository.itemsForMany` reads them in one
statement per 900 ids (SQLite caps parameters at 999), and
`test/gst_returns_test.dart` asserts the batched read returns exactly what the
per-document read did.

## Profit & loss: opening and closing stock

Every purchase was a cost of the month it was bought in, which is only right for
a business with nothing left on the shelf: buy stock for the season and the P&L
reported a loss on goods the firm still owned. `profitAndLoss` now values stock
at cost at both ends of the period (`ReportRepository.stockAtCost`, read from the
signed stock movements so it can be computed *as of a date*) and charges cost of
goods **sold**: opening stock + purchases - closing stock. Zero for a firm that
does not track stock, so a services business reads exactly as before, and the
trade account still lists the purchase line so the working is visible.
`test/profit_and_loss_test.dart` pins that closing stock of one period is the
opening stock of the next.

## UTGST is not a cosmetic label

The engine's `GstSplit.ut` arithmetic was always right, but documents printed
"SGST" for it. A dealer in or supplying a Union Territory charges CGST + UTGST,
and the invoice is what the customer reconciles their own return against.
`intraStateSecondHead(split)` now names the column on the invoice PDF and on the
sale detail screen (both of which have the firm's state and the place of supply,
so the heading is derived from the same state codes the engine used).

## Smaller improvements

- **Global search** reaches parties and items, not just pages and invoices: a
  name, phone, GSTIN, SKU or barcode finds the record, and a party result opens
  its statement.
- **Fiscal-year export** on the GST screen: April-to-selected-month, one row per
  month plus totals, written to `Documents\atria\gst\<gstin>\FY-<fy>\`. It is
  labelled a working paper in the UI because GSTR-1 and 3B are filed monthly and
  a year's worth concatenated is not something the portal accepts.
- **README** replaced the Flutter template: printer stack (ESC/POS receipts and
  TSPL/ZPL labels), the Windows-only winspool transport, the sync/sign-in and
  ledger features, the golden workflow and the installer pointers.

## H8: money stays a SQLite REAL, with a guard

Decision: **not** migrating every money column to integer paise, and the reason is
in `audit/06-sync-options.md`'s two corruption traps plus this: the columns are
read and written by ~40 repositories whose values come from a `Decimal` engine
that rounds to 2dp before anything is stored. A migration would touch every one
of them and every query that aggregates them, and the failure mode of getting it
half-done (a mixed set of rows) is worse than the double.

What makes it safe is a rule, not a type: **round to paise before writing, and
sum values as they were stored**. `test/money_precision_test.dart` is that rule
as a test: awkward rates must not store a fraction of a paisa, seven rounded line
totals must sum the same in double and in Decimal, a thousand receipts of 0.10
must still be exactly 100.00 in the ledger, and a TDS deduction must be a paise
amount. If a future code path writes an unrounded double, that file fails.

The schema surgery is still the right move *before* sync converges historical
rows between devices, and it should be a single migration that converts and
verifies, not a gradual one. Until then the guard test is what keeps the decision
honest.

## H9: dark-mode goldens

The dark scheme was implemented and switchable but had never been looked at
whole-screen. `test/golden_dark_mode_test.dart` captures the same six screens as
the light set (plus the chart of accounts, the newest surface) in
`ThemeMode.dark`, named `dark_*.png` so the two folders compare side by side.
`dart_test.yaml` documents the regeneration steps, including the trap that
`--tags golden` cannot override `exclude_tags` and the run reports "No tests match
the requested tag selectors" instead.

Known limitation: these captures hold drift streams open, and a capture can
overrun the five-minute per-test budget in teardown *after* writing its PNG (the
file is still correct). Regenerate one screen at a time with `--plain-name`.

## H10: signing hooks, and the auto-update contract

- `installer/atria.iss` gained optional signing (`/DSign=True` +
  `SignedUninstaller=yes`) so Inno signs the setup exe **and** the uninstaller it
  generates - which is the file SmartScreen actually complains about. Without the
  flag nothing changes and an unsigned build still compiles.
- `installer/README.md` documents the signing command and the auto-update
  contract: a stable `AppId` (so a newer setup is an upgrade, not a second copy),
  a per-user install (so no UAC prompt), `CloseApplications`, and a predictable
  file name. Auto-update itself is **not built**: it needs a release endpoint the
  app verifies a SHA-256 against, and it must not ship before the installer is
  signed, because silently downloading an unsigned executable is the behaviour
  users are warned about.
- `android/app/build.gradle.kts` reads `android/key.properties` for a release
  signing config and falls back to the debug key with a loud warning when it is
  absent. Distributing a debug-signed APK is not just non-compliant, it is
  un-updatable.

## The chart is seeded at launch, not by the screen that shows it

The chart of accounts used to seed itself from `ensureChartProvider`, watched by
the ledger screens. That is a *write on build*, and it cost a hang: in a widget
test the body runs in a fake-async zone where a drift write only progresses when
the test pumps, so the seed never completed, the teardown waited for the pending
transaction, and the capture/test timed out after minutes with no useful error
(the chart-of-accounts golden hung exactly this way). `AtriaApp._seedChart` now
seeds once at launch, after the first frame, alongside the outbox drain; the
ledger reports still call `ensureChart()` themselves as a second net, and
`createJournal` calls it too, so a firm created later is never stuck.

Two lessons worth keeping: a screen should not write just by being opened, and
any database work a widget test performs directly has to go inside
`tester.runAsync`.

## Release build: 1.0.0 artifacts, and the one thing standing between them and a shop

Built from the tree that carries the ledger, sync, auth, TDS/TCS and cheque work:

| Artifact | Size | SHA-256 (first 8 bytes) |
| --- | --- | --- |
| `installer/output/Atria-1.0.0-setup.exe` | 17.1 MB | `985CEB6C6D5CBEE7` |
| `installer/output/Atria-1.0.0-windows-x64-portable.zip` | 21.2 MB | `500CF107CE0D9863` |
| `build/app/outputs/flutter-apk/app-release.apk` | 78.7 MB | `79466D33325CE3E9` |

Times, all warm: `flutter build windows --release` 71 s, `ISCC` 11 s, Gradle
`assembleRelease` 171 s. The Windows runner exe keeps an old timestamp across
builds because only the CMake target that changed is relinked — the Dart code
lives in `data/app.so`, which is what actually moved.

**Neither artifact is signed, so neither may be handed to a shop.**
`Get-AuthenticodeSignature` on the setup exe says `NotSigned`, and the APK's
signer is `C=US, O=Android, CN=Android Debug` — `android/key.properties` does not
exist on this machine, so `build.gradle.kts` took its documented debug-key
fallback. The two unblocks are independent and cheap: a code-signing certificate
plus `ISCC /DSign=True`, and a keystore plus `key.properties`. Until the setup exe
is signed, an auto-updater has to stay off for the same reason it is not built.

The APK is the *universal* one, which is why it is 78.7 MB: it carries every ABI.
`--split-per-abi` would cut the download to roughly a third per device, at the
cost of three files to hand out instead of one. Left as is — one file is easier to
sideload from a phone, and this is not going through Play.

The setup exe was verified the way the README says: silent install into a
throwaway directory, then a silent uninstall, leaving no directory and no
`HKCU\...\Uninstall\{A37F4A6A-...}_is1` entry behind. Do that from PowerShell, not
Git Bash — bash hands the installer `/DIR=D:\tmp\atria-test` with the backslashes
eaten, so it reads a *relative* path and quietly installs into the current
directory, and the check passes while testing nothing. `MSYS2_ARG_CONV_EXCL='*'`
only fixes the leading-slash half of that; the README now shows the PowerShell
form.

## Sign-in on first run, and two races the widget tests caught

Firm setup's choice screen now offers a third path: sign in with email. The
sign-in form moved from `SignInScreen` into an embeddable `SignInForm` with an
awaited `onAuthenticated` callback; the standalone Settings screen passes null
and reacts to the auth state as before. Signing in on first run flips the
onboarding flag and shows a confirmation panel whose "Add my business" leads
to the manual form; there is deliberately no navigation away, because a
sign-in alone is not a configured business and the redirect would only send
the user straight back to firm setup. The redirect rule needed no change:
`/onboarding/firm-setup` stays reachable when the flag is set and no firm
exists, so a signed-in-but-no-business user lands here, not in a broken shell.

The 1280x900 test surface caught a production bug on the way past: the State
dropdown had no `isExpanded`, so selecting a long state name at a half-width
field (any window in the 560-640px band) overflowed the dropdown's inner row.

Two races worth remembering:

- **A callback that fires while the widget that owns it is being unmounted.**
  The embedded form's `if (!mounted) return;` guard skipped its own
  `onAuthenticated` callback, because the auth flip retires the form through
  the host's AnimatedSwitcher and unmounts it mid-await. The unmount is the
  flow *working*. A callback belongs to its host, not to the widget instance
  that happens to hold it; gate UI touches on `mounted`, never host actions.
- **A fresh controller's async `_init()` clobbering a write that raced it.**
  `OnboardingController.complete()` sets `state = true` synchronously, but a
  controller constructed lazily inside a callback had `_init()` still in
  flight, and its stale `state = persisted` landed *after* the flip, silently
  reverting it. `_init` now respects a completed write, and tests construct
  the boot-gate providers up front (`appInitializationProvider.future`) the
  way the real app does at launch. Reachable in production only if something
  reads the provider for the first time mid-session, but the same shape as
  the "Get Started did nothing" bug this app already fixed once.

## The release APK had no network, and only Android showed it

"Can't reach Atria. Check this device is online." on a fresh Android install,
while Windows signed in fine, was not a server or DNS problem: the Flutter
template declares INTERNET in the debug and profile manifests only, so
`flutter run` works and the release APK silently opens no socket at all. The
fix is one line in `android/app/src/main/AndroidManifest.xml`, and the check
that matters is not "does it work when installed from the IDE" but
`aapt dump permissions app-release.apk` on the actual release artifact.

## Two-way sync (pull + restore + auto-sync)

**Decision (2026-10-01):** sync is now push-then-pull. Migration `0004` stamps a
per-firm monotonic `seq` on `firm_changes`; `GET /v1/firms/<id>/changes?afterSeq=N`
pages the journal under the same RLS as the push. The client replays pages via
`PullApplier` with these rules, all in one class:

- **Row-level last-write-wins on `updated_at`.** A pulled row overwrites the
  local row only when strictly newer; missing/unparseable counts as old. Per
  ROW, not per document: simplest rule that cannot lose a newer edit. The
  server arbitrates nothing - it stores an ordered journal, and order +
  `updated_at` is the whole algorithm.
- **Children (invoice/bill items, journal lines, stock movements) are
  insert-if-absent, never updated.** The repositories treat them the same way
  (an edit deletes and re-inserts the set with fresh ids), so a replayed page
  cannot duplicate lines.
- **Never `INSERT OR REPLACE`.** SQLite's REPLACE deletes the conflicting row
  first, which fires ON DELETE CASCADE and would wipe an invoice's lines on
  every parent upsert. Upsert = explicit existence check + INSERT or UPDATE.
- **The cursor advances after the writes land, and even for skipped changes.**
  A crash between them re-applies a page (idempotent by the rules above); a
  cursor advanced first would skip a page for ever. An unknown entity is
  skipped with its cursor kept, so a newer app's entities cannot wedge an
  older app's sync; poison changes log loudly (debugPrint) and are skipped, not
  fatal.
- **Timestamp comparison quirk that bit us:** drift stores seconds; the push
  normalises to ms. Local raw reads are seconds. Parsing both with one
  assumption (UTC ms) made local 2026 look like 1970 and every old pulled
  write beat the local row. The parser now discriminates by magnitude
  (< 10^11 = seconds). Both units are zone-independent epoch values; no local/
  UTC conversion happens anywhere in the chain.

**Restore:** onboarding's signed-in panel lists `/v1/me` memberships and
`restoreFirm()` replays the chosen firm's whole journal - the firm row
materialises from its own journalled insert, so restore is the same code path
as steady-state pull. An empty journal (original device never pushed) refuses
to open books that look emptied, and says to press Send now there first.
Restore works with sync off (the switch governs background sync, not a pressed
action) and turns sync on after success.

**Auto-sync:** a 60s timer in `AtriaApp` runs `sync()` (never overlapping);
launch drain now syncs both directions too. The journal now also carries
`sales_invoice_items`, `purchase_bill_items`, `stock_movements`, `categories`,
`units` - without the line-item tables a restored invoice had totals but no
lines, which is the kind of gap you only find when a customer asks for a copy
of an invoice.

## Restore crash lesson: bind NULLs as NULL, test with real payloads

**Lesson (2026-10-01):** the first real restore on a phone failed with
`FormatException: Invalid radix-10 number (at character 1)` while every test
passed. The pull applier's variable binder fell through unknown values to
`Variable<String>('null')`, so nullable columns of pulled rows were stored as
the four characters "null". SQLite accepts that silently in ANY column;
drift's typed read of an int column then calls `int.parse` on it and throws
at read time, far from the write that caused it. Two rules came out of it:

1. In raw SQL layers, a null binds as SQL NULL - always. A stringified null
   is a landmine that only explodes when a screen finally reads the column.
2. Sync round-trip tests must build payloads by pushing through a REAL
   database (`test/sync_restore_roundtrip_test.dart`), never by typing JSON.
   Hand-built payloads omit nullable columns, which is precisely the shape
   difference between a test that passes and a user whose restore fails.
