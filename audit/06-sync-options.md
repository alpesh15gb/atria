# 06 — Desktop + mobile sync: what the options actually are

Scope: one firm's books editable from a **Windows desktop** and an **Android
phone**, both mostly offline, converging without a backend for us to run and
babysit. This is a decision document, not a change log.

Sources are listed at the end. Everything in §2 was read out of this
repository, not remembered.

---

## 1. What "flawless" has to mean, concretely

"Flawless" is not a feeling, it is four testable claims:

1. **Convergence** — after both devices go online, they hold the same rows,
   byte for byte, and stay that way.
2. **No silent money corruption** — no sequence of offline edits on two devices
   can produce a total that neither user typed.
3. **No duplicated or lost documents** — an invoice typed once becomes one
   invoice on both devices, never two, never none.
4. **Nothing for us to operate** — no cluster, no container, no cron, no
   pager. A managed service is fine; *our* server is not.

Claim 2 is the one that decides the architecture, and it is the one the current
schema is not yet ready for (§4.1, §4.2).

---

## 2. What Atria already has going for it

The schema was built by someone anticipating sync. Verified inventory:

| Property | Where | Why sync cares |
|---|---|---|
| **UUID v7 primary keys, generated on the client** | `lib/core/utils/id_utils.dart:11` (`return _uuid.v7();`, commented *"collision-free across devices before sync"*), and every `TextColumn get id => text()()` in `tables/*.dart` | No server-assigned IDs, so no ID remapping, no sequence collisions. This removes the single biggest class of sync bug. |
| **`createdAt` / `updatedAt` on entities** | `tables/{items,parties,purchases,sales_invoices}.dart` | The ordering field for last-write-wins. (Caveat: device clock — §4.5.) |
| **Soft delete + tombstones** | `isDeleted` + `deletedAt` on items, parties, purchases, sales invoices | Deletes travel as data instead of vanishing, so they can't be resurrected by the next pull. |
| **`firmId` on every business row** | `tables/sales_invoices.dart:16` etc., `NOT NULL REFERENCES firms(id) ON DELETE CASCADE` | The natural sync partition — one firm is one sync bucket, and one RLS policy. |
| **An outbox, already written to** | `tables/settings.dart:19` `SyncQueue`: `id, firmId, entity, entityId, operation, payload, createdAt, syncedAt, error, attempts`; written by `repositories/sync_mixin.dart` `enqueue()` | The push queue exists. It has a sortable unique op id (good for idempotency) and `attempts`/`error`/`syncedAt` for retry bookkeeping. |
| **A firm roster** | `FirmMembers` ("Device/user identities for multi-user firms") | Where per-device and per-user identity lands. |
| **Append-only audit trail** | `AuditLogs` | Free conflict forensics. |
| **Sync settings + UI** | `SettingsRepository.kSyncEnabled / kSupabaseUrl / kSupabaseAnonKey`; Settings → Sync with Supabase URL + anon key fields | The switch and the credentials box already exist. |
| **`supabase_flutter` already a dependency** | `pubspec.yaml`: `supabase_flutter: ^2.8.0`, commented *"Optional cloud sync (inert until configured in Settings)"* | No new client to choose or adopt. |

**What is missing is only the engine.** Grep finds no reader of `syncQueue`
anywhere: it is written and never drained. There is no `lib/core/sync/`.

So the honest starting position is: *the furniture is in place; the engine is
not written, and two columns types will corrupt money if it is written naively.*

---

## 3. The options

| # | Option | Who runs the server | Code we write | Cash | Verdict |
|---|---|---|---|---|---|
| **A** | **PowerSync** (Cloud, or self-hosted Open Edition) + Postgres/Supabase | PowerSync Cloud — nobody | Sync Streams YAML, upload endpoint *or* Supabase RLS, DB-layer migration to `sqlite_async` | Free tier → Pro → Team from $599/mo | **Very strong, one real cost: the drift DB layer moves.** |
| **B** | **ElectricSQL** | Electric Cloud / self-host | own write API (Electric is read-only) | — | **Not today** — read path only, and no current Dart client. |
| **C** | **Supabase (managed Postgres + Auth + RLS) + our own outbox sync** | Supabase — nobody | the sync engine (~1.5k lines), SQL schema + RLS policies | Supabase free tier for a pilot, paid beyond | **Best fit for this codebase.** |
| **D** | **Firebase Firestore** | Google — nobody | reimplement the data layer | usage-based | No — document store, wrong shape for relational books. |
| **E** | **MongoDB Atlas Device Sync / Realm** | — | — | — | **Dead.** EOL 30 Sep 2025. |
| **F** | Turso/libSQL, Ditto, ObjectBox, Couchbase Lite | varies | — | — | Screened out on shape (§3.6), not researched to the same depth. |

### 3.1 PowerSync — the "buy it" answer

It is a sync service: Postgres (also MongoDB/MySQL/SQL Server) → client SQLite,
via "Sync Streams" defined in SQL-ish YAML. The Dart/Flutter SDK is stable and,
critically for us, **covers desktop**: the supported-platforms matrix lists
macOS 14.0+, Linux glibc 2.34+, **Windows 10+** alongside Android/iOS. The
Flutter SDK is actively maintained (v2.0 unified all Dart platforms in Apr 2026;
v2.4.0 landed Sep 2026).

The download half is genuinely "flawless" by construction: resumable, real-time,
handles schema changes, and the drift integration (`drift_sqlite_async`)
propagates change notifications into drift's stream queries so the existing
Riverpod streams just update.

**The upload half is where the honesty is needed.** PowerSync is
*server-authoritative* and unopinionated: mutations are persisted locally into an
upload queue, and **our backend must drain that queue**. Their stated default
semantics are per-field last-write-wins with *deletes always win*, and operations
must be idempotent.

With Supabase there is a shortcut that avoids a custom backend entirely: the
upload path goes through the **Supabase client libraries with Row Level
Security**, so clients write straight to Postgres and RLS is the authority. That
is the configuration that satisfies "we're not in the middle" — PowerSync Cloud
for the read path, Supabase's Data API for the write path, neither operated by
us.

**What it costs us, specifically:** PowerSync owns the SQLite file. Atria opens
its database with `drift` over `LazyDatabase` + `sqlite3` /
`sqlite3_flutter_libs` (`app_database.dart`). Moving to PowerSync means opening
that same file through `sqlite_async` instead — `drift_sqlite_async` is
published by PowerSync but is **v0.3.x, i.e. pre-1.0**, and the drift docs still
label the PowerSync drift package "currently in Beta". We would also mirror every
table in Postgres under the exact same names, because PowerSync copies rows
verbatim into the client DB.

Also worth knowing before committing: Supabase's own integration guide carries a
standing warning that logical replication plus idle Supabase instances causes
excessive WAL growth and maxed disk, recommending `max_wal_size` /
`max_slot_wal_keep_size` tuning on the project. That is a knob on the database
you're paying for, not a blocker.

Pricing: a **$0 Free plan** with soft limits and project deactivation, limited to
**50 peak concurrent clients**; Pro above that; Team from **$599/month**. Billing
is now on *data synced*. Self-hosting is free and source-available (Functional
Source License, `journeyapps/powersync-service` on Docker Hub) but that is
exactly the server we said we don't want to run.

### 3.2 ElectricSQL — read-only, so not sufficient

Electric streams Postgres changes to clients as "shapes". It is a fine read
path, and it is the one non-drift-native option with real community drift
interest — but **writes are ours to build**: the client docs point at Electric's
own Writes Guide, and there is no server-side write path at all.

It is also the weakest on Dart. Drift's own comparison page says it plainly:
the Dart package it references is "an older version of Electric SQL, the current
version does not appear to be available to Dart apps." The current Dart client
on pub.dev is `electric_sql_flutter_client` at **v0.0.1**, self-described as
under active development with an API that may change. Building two-way sync on a
0.0.1 read client and a write API we'd also have to write is strictly worse than
§3.3, which needs no third-party client at all.

### 3.3 Supabase + our own outbox — the "build it, but it's mostly built" answer

Architecture:

- **Backend:** Supabase = managed Postgres + Auth + RLS + Realtime. We operate
  nothing.
- **Identity:** Supabase Auth. Every row is already `firmId`-scoped, so the
  security model is one policy:
  `firm_id in (select firm_id from firm_members where user_id = auth.uid())`.
- **Push:** drain `syncQueue` in id order. Each entry already carries a unique
  sortable op id (idempotency), `payload` JSON, and `attempts`. Push
  `INSERT … ON CONFLICT (id) DO UPDATE` per **document aggregate**, not per row
  (§4.6).
- **Pull:** `select * from t where server_updated_at > :watermark` per table,
  page by page, upsert locally. Pull is the source of truth for correctness,
  because it can't miss anything.
- **Liveness:** Supabase Realtime — but **Broadcast from Database, not Postgres
  Changes**. Supabase's own docs now say Postgres Changes "have some limitations
  as your application scales. We recommend using Broadcast for most use cases."
  Realtime is only a nudge to pull sooner; it is never the delivery guarantee.
- **Conflict policy:** optimistic concurrency on a `revision` integer, plus a
  `sync_conflicts` table (§4.4). Not silent LWW on money.

Cost: no new dependencies (supabase_flutter is already in `pubspec.yaml`),
no database-layer migration, keeps drift's stream queries working, and every row
of the §2 inventory gets used. Effort is real — this is the biggest single piece
of work in this document — but it is *our* code in *our* schema.

### 3.4 Firebase Firestore — no

Managed, offline persistence works, Flutter support is official. But it is a
document store: no joins, no aggregates, no transactions across collections in
the shape accounting needs. Atria's reports (GSTR-1, statements, trial balance)
are drift queries over a relational model, and `decimal`-based money math has no
counterpart. Adopting it means two sources of truth or a rewrite. Only the right
answer if we were starting over.

### 3.5 Realm / Atlas Device Sync — dead, and worth saying out loud

This was the obvious suggestion for years. MongoDB announced deprecation in
September 2024 and **ended Atlas Device Sync and the Device SDKs on 30 September
2025**. Any article recommending it predates that. Do not build on it.

### 3.6 Screened out on shape

Stated with less confidence, because I read no primary docs for these:
**Turso/libSQL** is SQLite-primary with a single writer and read replicas, which
addresses read scale rather than two devices writing; **ObjectBox Sync** and
**Ditto** are object/P2P stores (Ditto's no-internet peer sync is genuinely
attractive for a counter and a phone on one LAN, but it is commercial and gives
no cloud backup); **Couchbase Lite + Sync Gateway** has a mature replication
protocol but no official Dart SDK. None of them are relational in the way these
books are.

---

## 4. What actually breaks it

The engine choice matters less than these nine things. Every one of them is
specific to this codebase.

### 4.1 Derived columns must never be synced — this is the big one

Denormalized, device-computed projections:

- `items.currentStock` (`tables/items.dart:30`)
- `stock_movements.balanceAfter` (`tables/items.dart:58`)
- `sales_invoices.paidAmount`, `sales_invoices.balanceDue` (`:27`, `:28`)
- `purchase_bills.paidAmount`, `purchase_bills.balanceDue` (`tables/purchases.dart:26`, `:27`)

Take the phone and the desktop, offline. Invoice INV-100 for ₹10,000. The desktop
records a ₹5,000 payment; the phone records a different ₹5,000 payment. Each
device computes `balanceDue = 5,000` from what it can see. Last-write-wins
converges them on **₹5,000 outstanding when ₹10,000 has been paid and the
invoice should read PAID**. Symmetrically for stock: two devices each sell one
unit from a stock of ten, each writes `currentStock = 9`, merge yields 9 instead
of 8.

The fix is a rule, not a feature: **the append-only event is the object that
syncs; the projection is recomputed.** Payments and stock movements are the
truth; `balanceDue`, `paidAmount`, `currentStock`, `balanceAfter` are caches
that each device rebuilds locally after a pull, and that a push must never send.
Two supporting details: the server should own the projection too (a Postgres
trigger or RPC), and the client should be able to drop and rebuild it — its
existence must never be load-bearing for a sync decision.

### 4.2 Money is stored as `REAL`

Every persisted amount is a double: `grandTotal`, `taxableValue`, `cgst`,
`sgst`, `igst`, `cess`, `roundOff`, `rate` (`tables/sales_invoices.dart:44–93`,
`tables/purchases.dart:40–87`), `payments.amount`, `expenses.amount`. The
calculation layer is exact — `lib/core/engine/gst_engine.dart` uses `Decimal`,
as do the repositories, `reports/gst_return_builder.dart` and
`money.dart` — and then values are narrowed at the persistence boundary
(`vyapar_import.dart` `.toDouble()`, `demo_seeder.dart:517`).

Within one device that is survivable. Across two it is not: two devices can
legitimately compute totals differing in the last bits for the same invoice, and
"last write wins" then has no right answer, because neither value is the one the
user typed. A GSTR-1 summed across a merged book accumulates the drift.

**Recommendation: before there is a second device, store money as integer
paise** (BIGINT) or `numeric(18,4)`, keep `decimal` as the calculation type, and
convert only at the edges. This is a migration and a wide but mechanical edit,
and it is dramatically cheaper now than after two devices have diverged.
Same reasoning for `quantity` (`RealColumn`, signed) — fractional units in kg
deserve integer milli-units rather than doubles.

### 4.3 Two devices will mint the same invoice number

`uq_sales_number` is unique on `{firmId, docType, number}`
(`tables/sales_invoices.dart:7–11`) and `uq_purchase_number` mirrors it
(`tables/purchases.dart:5–9`). That constraint is *local*. Offline, both devices
read "highest number so far" and both produce `INV-2026-001`. On push, one
either fails the constraint or silently renumbers — and a renumbered tax invoice
is a compliance problem, not a UI glitch.

Options, in preference order:

1. **Server-allocated blocks.** A `document_series` table with `next_number`; a
   device reserves a block (say 50) with one atomic RPC when online, spends it
   offline, returns the unused tail on sync. Numbers are contiguous per series,
   gaps are explainable, and offline keeps working. *(This is what Tally and
   Zoho do; it is the only option that stays correct and usable offline.)*
2. **Per-device series** (`INV-D-001`, `INV-P-001`) — never collides, never
   waits, but creates two sequences per firm and looks odd on a GST return.
3. Number as display-only — unacceptable for a tax document.

The FY-based prefixes and the April rollover interact with reserved blocks, so
the series row should be keyed by `{firmId, docType, prefix}`.

### 4.4 Concurrent edits need optimistic concurrency, not silent LWW

Per-field last-write-wins is the industry default and it is *fine for a
description field*. It is not fine for an invoice that one device edited and the
other device marked paid. The policy should be:

- Every synced row carries a `revision` counter (or is guarded on
  `server_updated_at`).
- Push does `UPDATE … WHERE id = ? AND revision = ?`. **Zero rows affected =
  conflict, not overwrite.**
- The losing version is kept in a `sync_conflicts` row and surfaced in the UI —
  the *AuditLogs* table is a natural place to hang "who changed what, and when",
  and a notification badge is enough for v1.
- Deletes always win (PowerSync's documented default, and correct here), because
  the tombstone already exists (§2).

Silent LWW on a financial record means a user's work disappears with no trace.
That is the single most likely way this project gets called "not flawless".

### 4.5 Clocks

`updatedAt` defaults to `currentDateAndTime` — the *device* clock. Two devices
with a skewed clock make LWW pick the wrong winner, and a phone that was
in airplane mode for a week is exactly how that happens. Order on a
**server-assigned** `server_updated_at` (`now()` in Postgres), keep the device
timestamp for display, and record a `device_id` on each row so a conflict can
name its sides.

### 4.6 An invoice is an aggregate, not a row

`SalesInvoices` + `SalesInvoiceItems` + payment links, `PurchaseBills` +
`PurchaseBillItems`, all with text FKs. Draining the outbox row by row will
eventually push a line before its header, or a payment before the invoice it
settles, and get a foreign-key failure — or worse, succeed partially. The outbox
`payload` column is already JSON, which is the hint: make **the document** the
unit of push, as one server-side RPC per aggregate in one transaction. This also
makes idempotency natural (`ON CONFLICT DO UPDATE`), and let the Postgres FKs be
`DEFERRABLE INITIALLY DEFERRED` as a belt-and-braces measure.

### 4.7 A partial book renders wrong reports

Reports are computed locally from local rows. A phone that has synced 60% of
5,000 invoices will confidently render a wrong GSTR-1 — worse than showing
nothing. Initial sync needs resumable paging plus a visible progress state, and
the report and dashboard screens need to refuse to total anything until the
baseline pull has completed. ("Showing 3,000 of ~5,000 invoices — reports
disabled until sync finishes.")

### 4.8 Identity, and one desktop-specific catch

There is no login today; sync needs one. Supabase Auth per user, linked to firms
through the existing `FirmMembers` row, keeps `firmId` as the tenancy key.
Practical trap: **OAuth on Flutter desktop needs OS-level deep-link
registration** — fine on Android, fiddly on Windows. Email + password, or a
typed OTP code, avoids the whole class of problem on the desktop build.

### 4.9 The unglamorous three

- **Idempotency:** the op id in `sync_mixin.dart` (`entity_id_<time36>_<seq36>`,
  sortable) is already the right shape. Persist it server-side as a
  `processed_operations` row so a retried push is a no-op. *Test: drain the same
  batch twice, assert identical final state.*
- **Schema skew:** `schemaVersion` is 5. A v5 desktop and a v4 phone must not
  silently diverge — gate sync on a minimum version and keep migrations additive.
- **Purge is a tombstone.** Any "purge old data" path that issues a hard
  `DELETE` will have the row cheerfully resurrected by the next pull. Route every
  deletion through `isDeleted`/`deletedAt`.

---

## 5. Recommendation

**Option C — Supabase as the managed backend, with our own outbox engine — as
the primary path**, and Option A (PowerSync Cloud + Supabase) as the answer if
we'd rather not own a sync engine forever and can accept moving the database
layer onto a pre-1.0 ORM bridge.

Why C wins for *this* repository: the schema was designed for it (client-side
UUID v7 keys, tombstones, `updatedAt`, `firmId`, and an outbox that is already
being written), `supabase_flutter` is already a dependency with settings and a UI
switch, no database-layer migration is needed, and drift's stream queries keep
working. The work is writing one engine and a set of SQL policies — code we
control, in a schema we already understand.

Suggested order, because steps 1–2 are worth doing regardless of which option is
chosen, and become far more expensive once there is a second device:

1. **Decide column ownership.** Mark every column client-owned, server-owned, or
   derived-and-never-synced (§4.1). Write it down as the contract.
2. **Move money to integer paise** (§4.2) and add `revision`, `device_id`,
   `server_updated_at` to synced rows. Mechanical, wide, best done before sync
   exists.
3. **Backend:** Supabase project, Postgres schema mirroring the drift tables,
   RLS policies keyed on `firmId`, the `document_series` allocator (§4.3), and
   sign-in.
4. **Engine:** push (aggregate-per-RPC, idempotent), pull (watermark + paging +
   initial-sync progress), conflict detection writing to `sync_conflicts`, and
   local projection rebuild.
5. **Then:** Realtime Broadcast as a latency optimisation, conflict UI,
   two-device offline test harness (two DB instances, a fake transport, drain
   twice, assert convergence).

If Option A is preferred instead, steps 1, 2 and 3 are unchanged and step 4
becomes "configure Sync Streams + RLS-scoped uploads" — smaller, but with the
`solid:async` migration and a Beta integration to live with.

**Update — self-hosted variant.** If we run our own Indian VPS instead of using
managed services, the analysis of *which engine* is unchanged: hosting location
does not affect the client-side work, and self-hosting PowerSync still leaves us
owning auth and the write path. The Postgres schema is identical either way, so
PowerSync stays an additive later option. Stack, sizing, backups, security and
the terms-and-conditions wording are in
[07 — self-hosted India VPS](07-self-hosted-india-vps.md).

---

## 6. What I need from you

1. **Build the engine, or buy PowerSync?** (§5)
2. **Money migration to integer paise now, or accept doubles across devices?**
   (§4.2 — I'd do it now.)
3. **Who signs in?** One person using two devices, or two people in the same
   firm? It changes the conflict UI and nothing else.
4. **Is a managed service acceptable at all?** "Without us being in the middle"
   is satisfied by Supabase/PowerSync Cloud; the only truly server-free variant
   is peer-to-peer (Ditto), which gives up cloud backup.

---

## 7. Sources

Read, not remembered:

- Drift, *Backend synchronization* — `drift.simonbinder.eu/examples/server_sync/`.
  Drift does not sync automatically; it lists Manual, PowerSync and ElectricSQL.
  Carries PowerSync's disclosure (they sponsor drift and employ its maintainer)
  and states the current Electric SQL is not available to Dart apps.
- PowerSync, *Handling Update Conflicts* —
  `docs.powersync.com/handling-writes/handling-update-conflicts`. Upload queue,
  server-authoritative reconciliation, per-field LWW default, deletes win,
  idempotent operations, per-client op id.
- PowerSync, *Supported Platforms* — `docs.powersync.com/resources/supported-platforms`.
  Windows 10+, macOS 14.0+, Linux glibc 2.34+.
- PowerSync, *Supabase + PowerSync* guide — `docs.powersync.com/integrations/supabase/guide`.
  Writes upload via Supabase client libraries under RLS; the WAL-growth caveat.
- PowerSync pricing — `powersync.com/pricing` and
  `docs.powersync.com/resources/usage-and-billing/usage-and-billing-faq`.
  $0 Free plan (50 peak concurrent clients), Team from $599/month, billing on
  data synced.
- PowerSync releases — Dart/Flutter SDK v2.0 (2026-04-13), v2.4.0 (2026-09-02);
  service v1.26.0 (2026-09-04).
- Pub.dev — `drift_sqlite_async` (PowerSync publisher, v0.3.x);
  `electric_sql_flutter_client` v0.0.1.
- PowerSync, *Deployment Architecture — Self-Hosting* and *Self-Hosted Instance
  Configuration* — `docs.powersync.com/maintenance-ops/self-hosting/deployment-architecture`,
  `docs.powersync.com/configuration/powersync-service/self-hosted-instances`.
  Self-hosted instances need a source DB, bucket storage (MongoDB **or**
  Postgres), client auth and an upload service; production sizing; the dedicated
  subdomain requirement.
- Supabase, *Self-Hosting with Docker* — `supabase.com/docs/guides/self-hosting/docker`.
  11+ containers, 4 GB RAM / 2 cores minimum, 8 GB / 4 cores recommended.
- Supabase, *Subscribing to Database Changes* —
  `supabase.com/docs/guides/realtime/subscribing-to-database-changes`:
  "We recommend using Broadcast for most use cases."
- MongoDB, *Atlas Device Sync deprecation*; Couchbase, *MongoDB Ends Mobile
  Support Today* (2025-09-30).
- This repository: `lib/core/utils/id_utils.dart`,
  `lib/core/database/tables/*.dart`, `lib/core/database/repositories/sync_mixin.dart`,
  `lib/core/database/repositories/settings_repository.dart`, `pubspec.yaml`.
