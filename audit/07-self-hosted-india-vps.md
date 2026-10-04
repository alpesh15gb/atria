# 07 — Self-hosting in India: own VPS, nginx + Docker, `api.apexbooks.in`

Follows [06 — sync options](06-sync-options.md). Read that first for the
engine comparison; this document answers the different question you asked:
*run it ourselves, on our own Indian server, and say so in the terms.*

---

## 1. Verdict, up front

**Yes — do it.** Your own VPS in India is the right call, and not mainly for
legal reasons. Three reasons, in order of weight:

1. **The reliability bar is unusually low for this app.** Atria is offline-first:
   the local SQLite file is the source of truth and the app is fully usable with
   the server down. A dead VPS means *"changes haven't synced yet"*, not *"the
   app is broken"*. Almost no other product type gets to make that trade, and it
   is what makes single-VPS hosting defensible here.
2. **"Your books are in India, on our servers" is a sales claim** for an Indian
   SMB product, and a good one against cloud accounting tools that put the data
   wherever the cheapest region is.
3. **You control the data path end to end**, including the ability to *actually*
   delete a firm's data on request rather than filing a ticket.

**But the hosting location does not change which sync engine to pick**, and this
is the trap in the question as posed. See §3.

---

## 2. Does the law require an Indian server?

Mostly no — and the honest answer matters, because it determines what you're
allowed to *say*.

- The DPDP Act 2023 does **not** mandate localization. Section 16 permits
  transfer to any country **except those the Central Government restricts** —
  a "negative list", the opposite of GDPR's adequacy model. Rule 15 of the DPDP
  Rules 2025 states it directly: *"A Data Fiduciary may transfer personal data
  outside India except where the Central Government restricts such transfer."*
- Per the notification dated **13 November 2025**, obligations are staggered:
  foundational sections immediately, some consent and Significant-Data-Fiduciary
  provisions one year later, and **Section 16 plus the operational obligations
  eighteen months after publication — i.e. around May 2027**.
- So today, and for the next while, keeping data in India is *permitted and
  simple*, not *compelled*.

What that means practically: **"data stored on our Indian server" is a
trust-and-marketing claim, which makes it a claim you must be able to
substantiate completely.** If backups sit in a Singapore bucket, if OTP email
goes through a US provider, or if crash reporting ships staff names to a foreign
SaaS, the sentence in your terms is misleading even though the primary database
is in Mumbai. Every sub-processor is part of the claim, or the claim gets
narrowed to the truth.

Separately, DPDP does impose duties that your server design has to support,
regardless of where it runs:

| Rule | What it demands | What it means for us |
|---|---|---|
| **Rule 6** — security safeguards | Encryption, access controls, masking, monitoring, backups, log retention | TLS everywhere, encrypted disks, no public DB port, audited admin access |
| **Rule 7** — breach notification | Notify the Board and affected principals on a strict timeline (dual notification) | You need to *detect* a breach and know which firms were affected. Log retention is not optional. |
| **Rule 8** — retention and deletion | Deletion must propagate, with audit trails | A **real server-side purge per firm**, distinct from the client tombstones in §4.9 of doc 06 |
| **Rule 14** — data principal rights | Access, correction, erasure on request | An export path (Atria already has CSV/Excel exports) and a delete path |
| **Rule 23** | Government may demand information | Data must be retrievable promptly — easier when you hold it |

And the two live ones in an Indian small-business product: **a real, explicit,
versioned consent** at firm creation (not a link in the footer), and **a named
grievance contact**. Neither is hard, but neither exists today.

> Not legal advice. Have a lawyer read the final privacy policy and terms once
> you know exactly which countries your backups and emails transit.

---

## 3. What self-hosting does *not* change

This is the part worth being clear-eyed about.

**The client-side work is identical.** The reason doc 06 was lukewarm on
PowerSync was never "it costs money" or "it's managed" — it was that PowerSync
owns the SQLite file, so Atria would move from `drift` over `sqlite3`/`LazyDatabase`
to `sqlite_async`, through `drift_sqlite_async`, which is **v0.3.x and labelled
Beta by drift's own docs**. Deciding to host the server yourself does nothing to
that migration.

**Self-hosting PowerSync does not give you a backend.** PowerSync's own
self-hosting docs list what an instance needs before clients can sync: a source
database, bucket storage, **client authentication**, and a data upload service.
Self-hosted PowerSync is the *download* path only. You still build and run auth
and the write path.

So the comparison, restated for a self-hosted world where "we run a server" is
no longer a downside:

|  | Own engine, own VPS | PowerSync self-hosted, own VPS |
|---|---|---|
| Containers | Postgres + 1 API + nginx ≈ **3** | Postgres + bucket storage + PowerSync API(s) + replication + auth + upload API + nginx ≈ **6–7** |
| Client change | none — keeps `drift` as-is | move DB layer to `sqlite_async` + Beta drift bridge |
| Download path | ours to write, including resumable first sync | **theirs — battle-tested, resumable, schema-aware** |
| Subdomain | one | **PowerSync requires its own dedicated subdomain** |
| Migrations to run | your schema | your schema *plus* PowerSync's storage migrations (`migrate up`) on every service update |
| Failure mode | your bug, your logs | someone else's bug, their logs, your 3am |

**Recommendation: build the engine, on your own Postgres. Keep PowerSync as a
later, additive option.** The decisive reason is that the *Postgres schema is
identical either way* — PowerSync replicates from the same tables into client
SQLite. So you can build the schema, the auth, the write path, and the number
allocator now, ship the own-engine version, and bolt PowerSync on later behind
its own subdomain without touching the database or re-doing any of it. Only the
client's database-opening changes at that point, and it's a change you can make
on your own schedule, when device counts or row volumes justify it.

---

## 4. The stack

```
                    Internet
                       │
              ┌────────▼─────────┐
              │   nginx :443     │  TLS (Let's Encrypt), HSTS,
              │  (host service)  │  limit_req, proxy_buffering off
              └───┬──────────┬───┘
                  │          │
    api.apexbooks.in    sync.apexbooks.in   ← RESERVED, empty today.
                  │     (reserved)            PowerSync requires a dedicated
                  │                            subdomain; claim the DNS now.
        ┌─────────▼──────────┐
        │   api container    │  write path (push), auth/JWT, number-block
        │   (Dart or Node)   │  allocator, firm purge, admin
        └─────────┬──────────┘
                  │  docker network only — no host port
        ┌─────────▼──────────┐      ┌────────────────────┐
        │  postgres:17       │◄─────│  backup container  │  nightly pg_dump,
        │  wal_level=logical │      │                    │  encrypted, verified
        └────────────────────┘      └────────────────────┘
```

Notes on choices:

- **Postgres 17, `wal_level=logical` from day one.** It costs nothing now and is
  the one setting you cannot retrofit without a restart and a replication-slot
  dance. It is what makes adding PowerSync later a config change rather than a
  migration project.
- **No public database port.** Bind Postgres to the Docker network only. This is
  the single most common self-hosting breach.
- **One API container, not the Supabase stack.** Full self-hosted Supabase is
  **11+ containers** and its docs recommend **8 GB RAM / 4 cores minimum**
  (4 GB / 2 cores is the floor). You would be paying that to get Studio, Storage,
  Realtime and Edge Functions you don't need. What you actually need from
  Supabase is Auth + Data API; a single small API container covers both.
- **Realtime is optional at this scale.** Liveness is a nicety, not a
  correctness property: pull-on-foreground plus a 30-second poll while the app is
  open gives a phone and a desktop the appearance of instant sync for the tens of
  devices you'll have. Add push later if it's actually felt.
- **`sync.apexbooks.in` claimed but unused** — DNS is free and a dedicated
  subdomain is a hard requirement for PowerSync later.
- **`api.apexbooks.in` as you proposed** — good, and consistent with the product
  name.

---

## 5. Sizing: what to buy

Start here and don't over-provision:

| | Spec |
|---|---|
| **VPS** | 4 vCPU / 8 GB RAM / 160 GB NVMe, Ubuntu 24.04 LTS |
| **Region** | Mumbai (or whichever Indian region is closest to your users) |
| **Provider** | any with snapshots + an Indian region; a second provider later for the backup copy |
| **Disk** | the constraint that matters — WAL, daily dumps and 30 days of retention are all disk |

That is sized for *thousands* of devices worth of headroom in this stack; the
8 GB is there so that adding PowerSync's containers (2–3 GB) or MongoDB (2 GB) is
a decision, not a purchase. If you want the absolute floor: 2 vCPU / 4 GB is
enough for Postgres + one API container for a pilot of a handful of firms. The
PowerSync docs' own numbers, for reference: their production baseline is a 1 GB
replication container plus 1 GB per API container (100–200 connections each),
and 2 GB+ per storage node.

Spend the savings on **backups and monitoring**, which is where self-hosted
projects actually fail.

---

## 6. nginx

The PowerSync docs publish a working self-hosting nginx config, and two of its
details are easy to miss and expensive to debug:

```nginx
server {
    listen 443 ssl;
    server_name sync.apexbooks.in;   # must be a dedicated subdomain

    location / {
        proxy_pass http://powersync:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # Required: the Dart client can use long-lived HTTP streaming for sync.
        # With response buffering on, changes arrive in bursts or not at all.
        proxy_buffering off;
    }
}
```

1. **`proxy_buffering off`** — sync uses HTTP streaming. Buffering turns a live
   stream into a stalled one.
2. **A dedicated subdomain is mandatory** for PowerSync's API container; it will
   not share a name with another service. Plan for it.

Also worth doing while you're there: `limit_req` on the auth endpoints,
`client_max_body_size` set to something sane (a `.vyb` import could be tens of
MB if you ever add server-side import), HTTP→HTTPS redirect, HSTS, TLS from
Let's Encrypt with auto-renewal, and a health endpoint on the API container
PowerSync's equivalent is `/probes/liveness`; use the same pattern for ours) so
that monitoring has something to poke.

---

## 7. The security checklist

Short, and every line of it is a real-world incident:

- SSH: keys only, password login disabled, no root login, non-default port,
  fail2ban. Everything else on the host is behind Docker.
- `unattended-upgrades` on for security patches; a monthly reboot window you've
  tested.
- Docker images **pinned by version** (never `latest`), and a deliberate update
  routine. PowerSync's storage schema can need `migrate up` on service updates —
  read release notes before bumping.
- Secrets in an `.env` outside the repo or Docker secrets; **never** committed.
  Rotate the DB password when anyone who knew it leaves.
- Per-device tokens with short expiry and refresh, so a lost phone is revocable
  individually. Device id on every row (doc 06 §4.5) makes the audit meaningful.
- Postgres: no `postgres` superuser for the app; a role per purpose; RLS on the
  tables as the authority for the anon/authenticated roles.
- Log retention configured (Rule 6) and logs *out* of the container so a
  redeploy doesn't erase the evidence (Rule 7).
- `telemetry: disable_telemetry_sharing: true` in the PowerSync config if you
  take that path — by default the service reports anonymized usage metrics
  outbound, which is exactly the kind of detail that quietly contradicts an
  "everything stays in India" claim.

---

## 8. Backups — the part that actually loses data

Postgres is the only thing holding irreplaceable data. Everything else in this
stack is rebuildable: PowerSync's own docs note none of its containers use local
storage and that its bucket storage *can be recovered by re-replicating from the
source database*. That is a genuinely reassuring property, and it focuses the
whole problem on one dump.

Minimum bar:

- **Nightly `pg_dump` (custom format), encrypted, written to a second location
  in India** — ideally a different provider. A backup on the same VPS is not a
  backup; a backup in a foreign region weakens §2's claim.
- **30-day retention, weekly fulls, monthly archives.**
- **A restore you have actually performed**, into a scratch container, with the
  command written down in a runbook and the row counts compared. An untested
  backup is a hypothesis.
- **A `pg_dump` before every deploy**, plus a documented rollback (keep the
  previous image tag around).
- **Snapshot before migrations.** Schema changes and Postgres are where things
  go wrong.
- Restore point objective, stated honestly: with nightly dumps, a disaster costs
  up to 24 hours of *server* state — but every device still holds its own local
  copy of the book, so real-world exposure is smaller than it looks. Which is
  the offline-first dividend again.

---

## 9. What the terms and conditions can honestly say

Yes, declare it. Write it precisely, roughly like this:

> Your books are stored on servers located in India, operated by us. We do not
> transfer your data outside India. [If true:] Backups are also held in India.
> We use the following service providers: *(list — SMTP/OTP provider, payment
> gateway, crash reporting, SMS)*. *(Or: "We use no third-party providers that
> receive your data.")*
>
> We keep your data while your account is active and for *N* days after
> deletion before purging it from backups. You may export your data at any time
> in Excel/CSV, and you may request deletion, which removes your firm's records
> from our servers and, within *N* days, from backups.
>
> We act as the Data Fiduciary for the personal data you enter about your
> customers and suppliers. Grievance Officer: *(name, email, phone)*.

The four things that make the difference between a claim and a liability:

1. **Enumerate every sub-processor**, or state that there are none. This is the
   clause most likely to be quietly false.
2. **A real erasure path.** Rule 8 needs deletion to propagate, including into
   backups on a stated timeline. This is a *server-side firm purge* — separate
   from the client-side tombstones that keep sync correct (doc 06 §4.9). Build
   the endpoint before you write the sentence.
3. **Versioned consent** captured at firm creation, not implied by use.
4. What is a precise statement about *where data lives*, doesn't creep into
   "100% secure", "unhackable", or "ISO 27001 compliant" unless you hold the
   certification. Over-claiming security is what turns a breach into a legal
   problem.

The upside is real: for a GST-invoicing buyer, "your books never leave India and
we can delete them on request" is a differentiator you can put on the pricing
page — against tools that are, in fact, shipping Indian books to a foreign
region.

---

## 10. The honest cost of owning it

Being clear about what you've signed up for, because it's a recurring cost, not
a one-off:

- **Uptime becomes your pager.** At this scale, one VPS is a single point of
  failure. The mitigation is not HA — it's that sync is allowed to be down.
  Measure the right thing: "how long until devices converge", not "is nginx up".
- **The new failure mode is divergence, not downtime.** A server outage is
  obvious; a sync engine with a subtle bug corrupts books silently, on both
  devices, weeks later. This is why the two-device offline convergence test from
  doc 06 §5 step 5 is not optional.
- **TLS renewal, kernel patches, Postgres minor upgrades, disk monitoring, log
  rotation.** Maybe an hour a month on average, with occasional 3am incidents.
  Set up alerting on disk (>80%), Postgres down, API 5xx rate, and certificate
  expiry from day one — the first three will be silent otherwise.
- **You now hold the keys to other people's books.** Treat the admin access
  story (who can query the production DB, and is it logged?) as a feature to
  design, not an afterthought. Under DPDP it will be asked about.

---

## 11. Recommendation, in one paragraph

Rent a 4 vCPU / 8 GB Indian VPS, put Ubuntu LTS and Docker Compose on it, and
run **nginx + Postgres 17 (with `wal_level=logical`) + one small API container**
covering auth, the write path and the invoice-number allocator. Write the sync
engine against that, using the schema work doc 06 already calls for — money as
integer paise, declared column ownership, `revision`/`device_id`/
`server_updated_at`, and server-allocated number blocks. Claim
`api.apexbooks.in` and `sync.apexbooks.in` now; leave the second empty. Nightly
encrypted dumps to a second Indian location, with a restore you've performed.
Then, when device counts or row volumes justify it, drop PowerSync's containers
behind the reserved subdomain and move the client's database opening to
`sqlite_async` — the Postgres schema won't change, so nothing built in step one
is wasted. And write the terms with every sub-processor named, a real deletion
path, and no security adjectives you can't defend.

---

## 12. Sources

Read, not remembered:

- PowerSync, *Deployment Architecture — Self-Hosting* —
  `docs.powersync.com/maintenance-ops/self-hosting/deployment-architecture`.
  Staging vs production sizing, replication/API container roles, the daily
  compact job, the nginx config with `proxy_buffering off`, the dedicated
  subdomain requirement, `/probes/liveness`, `migrate up`, and the statement
  that no container uses local storage and bucket storage is recoverable by
  re-replicating from source.
- PowerSync, *Self-Hosted Instance Configuration* —
  `docs.powersync.com/configuration/powersync-service/self-hosted-instances`.
  The four prerequisites (source DB, bucket storage — **MongoDB or Postgres** —
  client auth, sync config), the YAML shape, `disable_telemetry_sharing`.
- PowerSync, *Deploy on Coolify* — `docs.powersync.com/maintenance-ops/self-hosting/coolify`.
  "A database, Authentication service, and Data upload service."
- PowerSync, *Introducing Postgres for Sync Bucket Storage* (2025-01-15) — no
  MongoDB required from service v1.3.8.
- Supabase, *Self-Hosting with Docker* —
  `supabase.com/docs/guides/self-hosting/docker`: minimum 4 GB RAM / 2 cores /
  40 GB SSD, recommended 8 GB / 4 cores / 80 GB+.
- K&S, *India's New Cross-Border Data Transfer Framework*; *India's DPDP Act:
  Balancing Data Localization & Flow* (both 2026-07-31) — Section 16, Rule 15,
  the negative-list model, the 13 Nov 2025 notification and the staggered
  timeline (Section 16 fully operational ~May 2027), and the Rule 6/7/8/14/23
  duties. Alongside: no-localization-mandate commentary from
  `nodguard.in/data-localization-dpdp` and Ahlawat & Associates on the negative
  list and SDF obligations.
