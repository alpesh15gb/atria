#!/usr/bin/env python3
"""Pull your Swipe books out of the *web app* and write a `.vyb` Atria imports.

`tools/swipe_to_vyb.py` talks to Swipe's official Partner API, which needs an
API key — and Swipe sells API access as a premium feature, so most accounts can
never run it. This script reaches the same data through the calls the Swipe web
app makes in your own logged-in browser session, so it needs no key and no paid
plan: just the session token that is already sitting in your browser.

It writes exactly the same thing as the Partner-API script — a Vyapar-shaped
`.vyb` — because Atria already reads that (`Settings -> Import from Vyapar`, see
`lib/core/services/vyapar_backup.dart`). Parties, items, GST rates, document
numbering and payment links all come across through Atria's own importer, which
is the part that actually knows how to keep the books balanced.

What comes across
  * sales invoices, purchases (bills), estimates, sales orders, purchase orders
    and delivery challans, with their line items
  * payments in and out, linked back to the document they settle
  * expenses, with their category, amount, mode and vendor
  * customers, vendors, expense categories and the product catalog

Getting the token (about ten seconds)
  1. Open https://app.getswipe.in and sign in.
  2. Open your browser's developer console (F12 -> Console).
  3. Paste this and press Enter:

       copy(localStorage.accessToken)

     The token is now on your clipboard. Pass it with --token or set
     SWIPE_TOKEN, or save it to a file and use --token-file.

  The token is a bearer token for your Swipe session: treat it like a password.
  It is sent only to app.getswipe.in and is never written to disk by this script
  (the `--cache` files hold the *responses*, never the token).

Usage
  python tools/swipe_web_to_vyb.py --token "$SWIPE_TOKEN" \\
      --firm-name "Active IT Solutions" --firm-gstin 36CZFPM0045M2Z7 \\
      --from 01-04-2020 --to 31-03-2027 --out atria_from_swipe.vyb

  # keep every response under ./swipe-web-cache and rebuild the .vyb offline
  python tools/swipe_web_to_vyb.py --token T --cache ./swipe-web-cache
  python tools/swipe_web_to_vyb.py --from-json ./swipe-web-cache --out retry.vyb

Swipe's web API is undocumented and not rate limited like the Partner API, but
this script still spaces its requests out and retries the transient failures, so
a book of a few hundred documents takes a couple of minutes.

Known limits (the same ones the Partner-API script has)
  * Sales and purchase returns have no Vyapar document code Atria maps, so they
    are reported and skipped rather than guessed into a credit note.
  * Cancelled documents are skipped: they are not books.
  * Swipe's web API has no company-profile endpoint that is stable across
    versions, so pass --firm-gstin (the state follows from it). Without it every
    supply is treated as local and the run says so.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# The .vyb format layer is the same one the Partner-API script uses: one writer,
# one set of tables, one round-trip through Atria's importer to keep honest.
import swipe_to_vyb as core  # noqa: E402
from swipe_to_vyb import (  # noqa: E402
    DOC_TXN_TYPE,
    Books,
    SwipeError,
    VyaparWriter,
    as_float,
    as_text,
    day_from_cli,
    normalise_state,
    slug,
    state_from_gstin,
)

API_BASE = "https://app.getswipe.in/api"
APP_ORIGIN = "https://app.getswipe.in"
WEB_VERSION = "v1.25.56-3-gef53999a1"

# The document types the web API accepts in `document_type`. `expense`,
# `payment`, `proforma` and `credit_note` are all rejected with "Invalid
# document type" — expenses and payments have endpoints of their own below.
WEB_DOC_TYPES = (
    "invoice",
    "purchase",
    "estimate",
    "purchase_order",
    "delivery_challan",
    "purchase_return",
    "sales_return",
)

DEFAULT_DOCS = "invoice,purchase,estimate,purchase_order,delivery_challan"

# `payment_status: 3` is what the web app itself sends for "every status".
PAYMENT_STATUS_ALL = 3

# The page size the web app uses, and the most it has ever returned in one go.
PAGE_SIZE = 100


# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------


class SwipeWebSession:
    """The handful of web-app calls that between them carry a whole book.

    Every call is a POST of a JSON body to `/api/<menu>/<path>` with the same
    `Authorization: Bearer <token>` header the app sends. Nothing else is
    required — not the device hash, not the request id, not the trace headers —
    which is why a single copied token is enough.
    """

    def __init__(
        self,
        token: str,
        cache_dir: str | None = None,
        verbose: bool = True,
        offline: bool = False,
        pause: float = 0.35,
        retries: int = 3,
    ) -> None:
        token = as_text(token)
        if token.lower().startswith("bearer "):
            token = token[7:].strip()
        if not token and not offline:
            raise SwipeError(
                "A Swipe session token is required. Sign in at "
                "https://app.getswipe.in, run `copy(localStorage.accessToken)` "
                "in the browser console, then pass it with --token (or set "
                "SWIPE_TOKEN)."
            )
        self.token = token
        self.cache_dir = cache_dir
        self.verbose = verbose
        self.offline = offline
        self.pause = pause
        self.retries = retries
        self.requests = 0
        if cache_dir:
            os.makedirs(cache_dir, exist_ok=True)

    # -- transport --------------------------------------------------------

    def log(self, message: str) -> None:
        if self.verbose:
            print(f"  {message}", file=sys.stderr, flush=True)

    def _cache_path(self, name: str) -> str | None:
        if not self.cache_dir:
            return None
        safe = "".join(c if c.isalnum() or c in "-_. " else "_" for c in name)
        return os.path.join(self.cache_dir, f"{safe}.json")

    def post(self, menu: str, path: str, body: dict | None = None, cache_key: str | None = None):
        """POST JSON to the web API, with a disk cache and polite retries."""
        cached = self._cache_path(cache_key) if cache_key else None
        if cached and os.path.exists(cached):
            with open(cached, "r", encoding="utf-8") as handle:
                return json.load(handle)
        if self.offline:
            raise SwipeError(
                f"The cache has no response for {cache_key or path} — re-run "
                "without --from-json, or point --from-json at the directory an "
                "earlier run wrote with --cache."
            )

        payload = json.dumps(body or {}).encode("utf-8")
        last_error: Exception | None = None
        for attempt in range(self.retries):
            request = urllib.request.Request(
                f"{API_BASE}/{menu}/{path}",
                data=payload,
                method="POST",
                headers={
                    "Authorization": f"Bearer {self.token}",
                    "Accept": "application/json, text/plain, */*",
                    "Content-Type": "application/json",
                    "source": "web",
                    "web_version": WEB_VERSION,
                    "DeviceHash": str(uuid.uuid4()),
                    "Origin": APP_ORIGIN,
                    "Referer": f"{APP_ORIGIN}/",
                    "User-Agent": core.USER_AGENT,
                },
            )
            try:
                self.requests += 1
                with urllib.request.urlopen(request, timeout=60) as response:
                    data = json.loads(response.read().decode("utf-8"))
                if isinstance(data, dict) and data.get("logout"):
                    raise SwipeError(
                        "Swipe rejected the session token (it has been logged "
                        "out or replaced). Sign in again and copy a fresh "
                        "localStorage.accessToken."
                    )
                if isinstance(data, dict) and data.get("success") is False:
                    message = as_text(data.get("message")) or "the request failed"
                    # A wrong menu/path answers 500 "Something went wrong";
                    # anything else is a real, worth-showing message.
                    raise SwipeError(f"{menu}/{path}: {message}")
                if cached:
                    with open(cached, "w", encoding="utf-8") as handle:
                        json.dump(data, handle, indent=2)
                time.sleep(self.pause)
                return data
            except SwipeError:
                raise
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code in (401, 403):
                    raise SwipeError(
                        "Swipe refused the session token (HTTP "
                        f"{error.code}). Sign in at {APP_ORIGIN}, run "
                        "`copy(localStorage.accessToken)` and pass the fresh "
                        "token with --token."
                    ) from error
                if error.code == 429 or error.code >= 500:
                    self.log(f"{menu}/{path} -> HTTP {error.code}, retrying")
                    time.sleep(2.0 * (attempt + 1) + random.random())
                    continue
                raise SwipeError(
                    f"{menu}/{path} -> HTTP {error.code}: {error.reason}"
                ) from error
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                last_error = error
                self.log(f"{menu}/{path} -> {error}, retrying")
                time.sleep(1.5 * (attempt + 1) + random.random())
        raise SwipeError(f"{menu}/{path} failed after {self.retries} tries: {last_error}")

    # -- reads ------------------------------------------------------------

    def paged(self, menu: str, path: str, body: dict, key: str, cache_prefix: str) -> list[dict]:
        """Walk `page` (0-based) until the API stops handing out rows."""
        rows: list[dict] = []
        page = 0
        while True:
            page_body = {**body, "page": page, "num_records": PAGE_SIZE}
            data = self.post(menu, path, page_body, f"{cache_prefix}_{page:03d}")
            found = (data or {}).get(key) or []
            if not isinstance(found, list):
                break
            rows.extend(row for row in found if isinstance(row, dict))
            if self.verbose and page == 0 and found and len(found) < PAGE_SIZE:
                self.log(f"{path}: {len(found)} row(s)")
            total = data.get("total_records")
            if len(found) < PAGE_SIZE:
                break
            if isinstance(total, int) and total and len(rows) >= total:
                break
            page += 1
            if page > 500:  # a runaway guard; no real book has 50k pages
                break
        return rows

    def document_list(self, document_type: str, window: str) -> list[dict]:
        return self.paged(
            "v2/doc",
            "get_transactions",
            {
                "payment_status": PAYMENT_STATUS_ALL,
                "search": "",
                "search_type": "Customer",
                # Every key must be present: the endpoint answers 500 when one is
                # missing, which is why an incomplete filter object looks like a
                # broken API key.
                "filters": {
                    "invoice_type": [],
                    "payment_mode": "",
                    "filtered_users": [],
                    "status": "",
                    "is_export": False,
                    "type_of_doc": [],
                    "prefixes": [],
                },
                "date": window,
                "document_type": document_type,
                "sort_type": "",
                "sort_order": "",
                "project_id": [],
            },
            "transactions",
            f"web_docs_{document_type}_{window.replace(' - ', '_').replace(' ', '')}",
        )

    def document_detail(self, document_type: str, new_hash_id: str) -> dict:
        """`new_hash_id` — not `hash_id`, not `id` — is what this endpoint wants."""
        return self.post(
            "v2/doc",
            "get_invoice",
            {
                "document_type": document_type,
                "new_hash_id": new_hash_id,
                "is_pdf": False,
                "identifier": "inv_details",
            },
            f"web_detail_{document_type}_{new_hash_id}",
        )

    def payment_list(self, window: str) -> list[dict]:
        return self.paged(
            "v3/payments",
            "timeline",
            {"date": window},
            "transactions",
            f"web_payments_{window.replace(' - ', '_').replace(' ', '')}",
        )

    def expense_list(self, window: str) -> list[dict]:
        return self.paged(
            "expenses",
            "get",
            {
                "document_type": "expense",
                "payment_status": "",
                "search": "",
                "filters": {},
                "date": window,
            },
            "transactions",
            f"web_expenses_{window.replace(' - ', '_').replace(' ', '')}",
        )

    def expense_detail(self, serial_number: str) -> dict:
        return self.post(
            "expenses",
            "get_expense",
            {"serial_number": serial_number, "document_type": "expense"},
            f"web_expense_{slug(serial_number)}",
        )

    def product_list(self) -> list[dict]:
        return self.paged(
            "v3/products",
            "search",
            {"query": "", "category": "", "selected_price_list": 0},
            "products",
            "web_products",
        )

    def customer_list(self) -> list[dict]:
        return self.paged(
            "v2/customer",
            "get",
            {"search_type": "", "search": "", "is_delete": 0},
            "allData",
            "web_customers",
        )

    def vendor_list(self) -> list[dict]:
        return self.paged(
            "v2/vendor",
            "get",
            {"search_type": "", "search": "", "is_delete": 0},
            "allData",
            "web_vendors",
        )

    def expense_categories(self) -> list[dict]:
        data = self.post("expenses", "get_categories", {}, "web_expense_categories")
        rows = (data or {}).get("categories") or []
        return [row for row in rows if isinstance(row, dict)]


# ---------------------------------------------------------------------------
# Normalising what the web API returns into the shape the writer expects
# ---------------------------------------------------------------------------

# "08 Mar 2026", "08 Mar 2026 02:00 AM", "Sun, 08 Mar 2026 00:00:00 GMT" and
# "14-02-2024" all turn up in the same book.
_WEB_DATE_FORMATS = (
    "%d %b %Y",
    "%d %b %Y %H:%M %p",
    "%a, %d %b %Y %H:%M:%S",
    "%a, %d %b %Y %H:%M:%S %Z",
    "%d-%m-%Y",
    "%Y-%m-%d",
)


def web_day(value) -> str | None:
    """Any of Swipe's date spellings -> DD-MM-YYYY, which `to_iso` accepts."""
    text = as_text(value)
    if not text:
        return None
    text = text.replace("GMT", "").strip().rstrip(",").strip()
    for pattern in _WEB_DATE_FORMATS:
        try:
            return datetime.strptime(text, pattern).strftime("%d-%m-%Y")
        except ValueError:
            continue
    return None


# Swipe stores rich-text descriptions; Atria wants the words, not the markup —
# and a product with no description comes back as an empty `<p></p>`.
_HTML_TAG = re.compile(r"<[^>]*>")
_HTML_ENTITIES = (
    ("&nbsp;", " "),
    ("&amp;", "&"),
    ("&quot;", '"'),
    ("&#39;", "'"),
    ("&lt;", "<"),
    ("&gt;", ">"),
)


def clean_html(value) -> str:
    text = _HTML_TAG.sub(" ", as_text(value))
    for entity, replacement in _HTML_ENTITIES:
        text = text.replace(entity, replacement)
    return " ".join(text.split())


def product_key(row: dict) -> str:
    """The catalog key a product and the lines that use it must agree on.

    Swipe lists every variant separately under one `product_id`, so the variant
    is part of the key — otherwise two variants would collapse into one item.
    """
    base = as_text(row.get("product_id")) or as_text(row.get("id"))
    variant = row.get("variant_id")
    if variant in (None, 0, "0", ""):
        return base
    return f"{base}-{as_text(variant)}"


def item_display_name(row: dict) -> str:
    name = as_text(row.get("product_name")) or as_text(row.get("name")) or "Item"
    variant = as_text(row.get("variant_name"))
    return f"{name} {variant}" if variant else name


def state_name(value) -> str | None:
    """Swipe writes states as `36-TELANGANA`; Atria wants `TELANGANA`."""
    text = as_text(value)
    if not text:
        return None
    head, sep, tail = text.partition("-")
    if sep and head.isdigit():
        return normalise_state(tail)
    return normalise_state(text)


def _party_address(party: dict, prefix: str) -> dict:
    billing = party.get("billing") if isinstance(party.get("billing"), dict) else {}
    return {
        "address_line1": as_text(party.get(f"{prefix}_address_1"))
        or as_text(billing.get("address_1")),
        "address_line2": as_text(party.get(f"{prefix}_address_2"))
        or as_text(billing.get("address_2")),
        "city": as_text(party.get(f"{prefix}_city")) or as_text(billing.get("city")),
        "state": state_name(party.get(f"{prefix}_state") or billing.get("state")),
        "pincode": as_text(party.get(f"{prefix}_pincode")) or as_text(billing.get("pincode")),
        "country": "India",
    }


def party_from_document(document: dict, document_type: str) -> dict:
    """Swipe puts the party on `customer` even for some purchases, and marks the
    real side with `party_type`; vendors use a `billing` sub-object."""
    raw = {}
    for key in ("vendor", "customer"):
        candidate = document.get(key)
        if isinstance(candidate, dict) and candidate:
            raw = candidate
            if as_text(candidate.get("type")).lower() == key:
                break
    if not isinstance(raw, dict):
        raw = {}

    kind = as_text(raw.get("type") or document.get("party_type")).lower()
    if kind not in ("customer", "vendor"):
        kind = "vendor" if as_text(document_type).startswith("purchase") else "customer"

    name = (
        as_text(raw.get("name"))
        or as_text(raw.get("company_name"))
        or as_text(document.get("customer_name"))
        or as_text(document.get("vendor_name"))
    )
    return {
        "id": raw.get("customer_id") or raw.get("vendor_id") or raw.get("id"),
        "type": kind,
        "name": name,
        "gstin": as_text(raw.get("gstin")) or as_text(raw.get("vendor_gstin")),
        "phone_number": as_text(raw.get("phone")) or as_text(raw.get("phone_number")),
        "email": as_text(raw.get("email")),
        "billing_address": _party_address(raw, "billing"),
        "shipping_address": _party_address(raw, "shipping"),
    }


def lines_from_document(document: dict) -> list[dict]:
    """Web line items: `qty`, `price` (GST-exclusive), `tax`, `net_amount`."""
    lines: list[dict] = []
    for item in document.get("items") or []:
        if not isinstance(item, dict):
            continue
        name = item_display_name(item)
        quantity = as_float(item.get("qty"), 1.0) or 1.0
        # `price` and `unit_price` are the taxable rate; `price_with_tax` is the
        # display figure. Vyapar's `priceperunit` is the taxable rate, so the
        # ex-GST one is the one to keep.
        rate = as_float(item.get("price")) or as_float(item.get("unit_price"))
        net = as_float(item.get("net_amount")) or quantity * rate
        tax_amount = as_float(item.get("tax_amount"))
        total = as_float(item.get("total_amount")) or (net + tax_amount)
        lines.append(
            {
                # Must be the same key `product_from_row` gives the catalog row,
                # or the line gets a phantom item and loses its name.
                "id": product_key(item),
                "name": name,
                "quantity": quantity,
                "unit": as_text(item.get("unit")) or as_text(item.get("item_unit")) or "NOS",
                "unit_price": rate,
                "tax_rate": as_float(item.get("tax")) or as_float(item.get("base_tax")),
                "net_amount": net,
                "total_amount": total,
                "discount_amount": as_float(item.get("discount_amount")),
                "discount_percent": (
                    as_float(item.get("discount")) if item.get("is_discount_percent") else 0.0
                ),
                "hsn_code": as_text(item.get("hsn_code")),
                "description": clean_html(item.get("description")) or name,
            }
        )
    return lines


def document_from_detail(detail: dict, row: dict, document_type: str) -> dict:
    """One web-app document -> the flat document `VyaparWriter` reads."""
    document = detail if isinstance(detail, dict) else {}
    if not document:
        document = row

    date = (
        web_day(document.get("document_date"))
        or web_day(document.get("expense_date"))
        or web_day(document.get("invoice_date"))
        or web_day(row.get("invoice_date"))
        or web_day(row.get("document_date"))
    )
    due = (
        web_day(document.get("document_due_date"))
        or web_day(document.get("supplier_doc_date"))
        or web_day(document.get("due_date"))
        or web_day(row.get("due_date"))
    )
    party = party_from_document(document, document_type)
    if not party.get("name"):
        # Some list rows carry only the customer name as a string.
        fallback = row.get("customer")
        if isinstance(fallback, str):
            party["name"] = as_text(fallback)
        elif isinstance(fallback, dict):
            party["name"] = as_text(fallback.get("name"))

    total = as_float(document.get("total_amount")) or as_float(row.get("total_amount"))
    tax = as_float(document.get("tax_amount")) or as_float(row.get("tax_amount"))
    return {
        "hash_id": as_text(document.get("new_hash_id"))
        or as_text(row.get("new_hash_id"))
        or as_text(document.get("hash_id"))
        or as_text(row.get("hash_id")),
        "serial_number": as_text(document.get("serial_number")) or as_text(row.get("serial_number")),
        "document_date": date,
        "due_date": due,
        "document_type": document_type,
        "party": party,
        "items": lines_from_document(document),
        "net_amount": as_float(document.get("net_amount")),
        "total_amount": total,
        "tax_amount": tax,
        "total_discount": as_float(document.get("total_discount"))
        or as_float(document.get("discount_amount")),
        "amount_paid": as_float(document.get("amount_paid")) or as_float(row.get("amount_paid")),
        "amount_pending": as_float(document.get("amount_pending"))
        if document.get("amount_pending") is not None
        else as_float(row.get("amount_pending")),
        "payment_status": as_text(document.get("payment_status"))
        or as_text(row.get("payment_status")),
        "notes": as_text(document.get("notes")),
        "terms": as_text(document.get("terms")),
        "place_of_supply": state_name(
            document.get("place_of_supply") or party.get("billing_address", {}).get("state")
        ),
        # The web app keeps payments made *with* the document here; `payment`
        # (singular) is only the default mode and carries no amount.
        "payments": [
            {
                "amount": as_float(payment.get("amount")),
                "method": as_text(payment.get("method")) or as_text(payment.get("payment_mode")),
                "bank_details": {"bank_name": as_text(payment.get("bank_name"))},
            }
            for payment in (document.get("payments") or [])
            if isinstance(payment, dict) and as_float(payment.get("amount")) > 0
        ],
        "_document_type": document_type,
    }


def product_from_row(row: dict) -> dict:
    """A `v3/products/search` row -> the flat product `VyaparWriter.catalog` reads."""
    return {
        "id": product_key(row),
        "name": item_display_name(row),
        "item_type": as_text(row.get("product_type")) or "Product",
        "hsn_code": as_text(row.get("hsn_code")),
        "tax_rate": as_float(row.get("tax")) or as_float(row.get("base_tax")),
        "unit": as_text(row.get("unit")) or as_text(row.get("item_unit")),
        "unit_price": as_float(row.get("price")) or as_float(row.get("unit_price")),
        "purchase_price": as_float(row.get("purchase_price")),
        "quantity": as_float(row.get("qty")),
        "category": as_text(row.get("product_category")),
        "description": clean_html(row.get("description")),
    }


def party_from_list_row(row: dict, kind: str) -> dict:
    """A `v2/customer/get` or `v2/vendor/get` row -> a party the writer reads."""
    return {
        "id": row.get("customer_id") or row.get("vendor_id") or row.get("id"),
        "type": kind,
        "name": as_text(row.get("name")) or as_text(row.get("company_name")),
        "gstin": as_text(row.get("gstin")),
        "phone_number": as_text(row.get("phone")) or as_text(row.get("phone_number")),
        "country_code": as_text(row.get("dial_code")) or "91",
        "email": as_text(row.get("email")),
        # Customers keep the address flat (`billing_address_1`), vendors nest it
        # under `billing`; `_party_address` handles both.
        "billing_address": _party_address(row, "billing"),
        "shipping_address": _party_address(row, "shipping"),
    }


def payment_from_row(row: dict) -> dict:
    """A `v3/payments/timeline` row -> the flat payment the writer reads."""
    linked = []
    for doc in row.get("linked_docs") or []:
        if not isinstance(doc, dict):
            continue
        linked.append(
            {
                "document_type": as_text(doc.get("document_type")),
                # The timeline names the settled document `doc_serial_number`
                # (and, for invoices, `invoice_serial_number`) — the row's own
                # `serial_number` is the *payment's* number, not the document's.
                "serial_number": as_text(doc.get("doc_serial_number"))
                or as_text(doc.get("invoice_serial_number"))
                or as_text(doc.get("document_serial_number")),
                "amount_settled": as_float(doc.get("amount_paid"))
                or as_float(doc.get("amount_settled")),
            }
        )
    return {
        "serial_number": as_text(row.get("serial_number")),
        "total_amount": as_float(row.get("total_amount")) or as_float(row.get("amount")),
        "payment_type": as_text(row.get("payment_type")),
        "payment_date": web_day(row.get("payment_date")) or web_day(row.get("record_time")),
        "payment_mode": as_text(row.get("payment_mode")) or "Cash",
        "party": {"name": as_text(row.get("name")), "type": as_text(row.get("party_type"))},
        "bank_details": {"bank_name": as_text(row.get("bank_name"))},
        "notes": as_text(row.get("notes")) or as_text(row.get("exclusive_notes")),
        "linked_docs": linked,
    }


def expense_from_row(row: dict, detail: dict | None = None) -> dict:
    """A `expenses/get` row (optionally enriched by `expenses/get_expense`)."""
    document = detail if isinstance(detail, dict) else {}
    record = {**row, **document} if document else dict(row)
    party = (
        record.get("party_details")
        if isinstance(record.get("party_details"), dict)
        else record.get("party")
        if isinstance(record.get("party"), dict)
        else {}
    )

    category = (
        as_text(record.get("category"))
        or as_text(record.get("category_name"))
        or as_text(record.get("expense_category"))
        or as_text(record.get("expense_category_name"))
    )
    if not category:
        categories = record.get("categories")
        if isinstance(categories, list) and categories and isinstance(categories[0], dict):
            category = as_text(categories[0].get("category") or categories[0].get("name"))

    date = (
        web_day(record.get("expense_date"))
        or web_day(record.get("document_date"))
        or web_day(record.get("date"))
    )
    amount = (
        as_float(record.get("total_amount"))
        or as_float(record.get("amount"))
        or as_float(record.get("net_amount"))
        or as_float(record.get("amount_paid"))
    )
    return {
        "date": date,
        "amount": amount,
        "category": category or "Expense",
        "vendor": as_text(party.get("name")) or as_text(record.get("vendor"))
        or as_text(record.get("name")),
        "mode": as_text(record.get("payment_mode")) or "cash",
        "notes": as_text(record.get("notes")) or as_text(record.get("exclusive_notes")),
        "gst_amount": as_float(record.get("tax_amount")) or as_float(record.get("gst_amount")),
        "serial_number": as_text(record.get("serial_number")),
    }


# ---------------------------------------------------------------------------
# Collecting a whole book
# ---------------------------------------------------------------------------


def collect(session: SwipeWebSession, window: str, doc_types: list[str]) -> Books:
    books = Books()

    def safely(label: str, producer) -> list[dict]:
        # The catalog only enriches what the documents already carry, so a
        # failure here must never cost the user their documents.
        try:
            return producer()
        except SwipeError as error:
            books.warn(f"{label} could not be read: {error}")
            return []

    books.products = [
        product_from_row(row)
        for row in safely("the product list", session.product_list)
    ]
    books.customers = [
        party_from_list_row(row, "customer")
        for row in safely("the customer list", session.customer_list)
        if as_text(row.get("name")) or as_text(row.get("company_name"))
    ]
    books.vendors = [
        party_from_list_row(row, "vendor")
        for row in safely("the vendor list", session.vendor_list)
        if as_text(row.get("name")) or as_text(row.get("company_name"))
    ]
    print(
        f"catalog: {len(books.products)} products, {len(books.customers)} customers, "
        f"{len(books.vendors)} vendors"
    )

    for document_type in doc_types:
        if document_type not in DOC_TXN_TYPE:
            books.warn(
                f"{document_type} has no Atria equivalent -- those "
                f"{document_type.replace('_', ' ')}s were skipped."
            )
            continue
        try:
            rows = session.document_list(document_type, window)
        except SwipeError as error:
            # One bad type must not lose the whole book.
            books.warn(f"{document_type} could not be listed: {error}")
            continue
        print(f"{document_type}: {len(rows)} document(s)")
        for row in rows:
            # Swipe marks a voided document as cancelled, as deleted, or both,
            # depending on how it was voided.
            flags = " ".join(
                as_text(row.get(key)).lower()
                for key in ("status", "payment_status", "document_status")
            )
            if "cancel" in flags or as_float(row.get("is_delete")) == 1:
                books.warn(
                    "Cancelled documents are not imported (they are not books "
                    "yet); the cancelled ones were skipped."
                )
                continue
            new_hash_id = as_text(row.get("new_hash_id")) or as_text(row.get("hash_id"))
            if not new_hash_id:
                continue
            try:
                detail = session.document_detail(document_type, new_hash_id)
            except SwipeError as error:
                books.warn(
                    f"{document_type} {as_text(row.get('serial_number')) or new_hash_id} "
                    f"could not be read in full: {error}"
                )
                continue
            document = document_from_detail(
                (detail or {}).get("invoice_details") or detail or {}, row, document_type
            )
            if not document.get("items") and not document.get("total_amount"):
                books.warn(
                    f"{document_type} {new_hash_id} came back empty and was skipped."
                )
                continue
            books.documents.append(document)

    try:
        books.payments = [payment_from_row(row) for row in session.payment_list(window)]
    except SwipeError as error:
        books.warn(f"payments could not be listed: {error}")
    print(f"payments: {len(books.payments)}")

    expenses = safely("the expense list", lambda: session.expense_list(window))
    collected: list[dict] = []
    for row in expenses:
        # The list row usually carries the category and the amount, so the
        # detail call is only worth making when it does not — that keeps a book
        # of a few hundred expenses to a couple of hundred requests instead of
        # twice that.
        probe = expense_from_row(row)
        detail: dict = {}
        serial = as_text(row.get("serial_number"))
        if serial and (probe["amount"] <= 0 or not as_text(row.get("category"))):
            detail = safely(
                f"the detail of expense {serial}",
                lambda serial=serial: (session.expense_detail(serial) or {}).get(
                    "expense_details"
                )
                or {},
            ) or {}
        expense = expense_from_row(row, detail)
        if expense["amount"] <= 0:
            books.warn(
                f"Expense {serial or '(unnumbered)'} has no readable amount and was skipped."
            )
            continue
        collected.append(expense)
    books.expenses = collected
    print(f"expenses: {len(books.expenses)}")

    # Swipe's expense *categories* become Atria expense categories, so a
    # category shows up in the picker even before its first expense.
    for category in safely("the expense categories", session.expense_categories):
        name = as_text(category.get("category")) or as_text(category.get("name"))
        if not name:
            continue
        if as_text(category.get("type")) == "indirect_income":
            continue
        if any(head["category"].lower() == name.lower() for head in books.expenses):
            continue
        books.expenses.append(
            {
                "date": None,
                "amount": 0.0,
                "category": name,
                "vendor": "",
                "mode": "",
                "notes": "",
                "gst_amount": 0.0,
                "serial_number": "",
                "_head_only": True,
            }
        )

    return books


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def read_token(args) -> str:
    if args.token:
        return args.token
    env = os.environ.get("SWIPE_TOKEN", "")
    if env:
        return env
    if args.token_file:
        with open(args.token_file, "r", encoding="utf-8-sig") as handle:
            text = handle.read().strip()
        if not text:
            raise SwipeError(f"{args.token_file} is empty.")
        if text[0] in "{[":
            data = json.loads(text)
            if isinstance(data, dict):
                for key in ("accessToken", "access_token", "token"):
                    if data.get(key):
                        return as_text(data[key])
            raise SwipeError(
                f"{args.token_file} is JSON but carries no accessToken field."
            )
        return text
    return ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Export a Swipe company into Atria's Vyapar-format .vyb backup using "
            "your logged-in Swipe web session (no API key required)."
        )
    )
    parser.add_argument(
        "--token",
        default="",
        help="Swipe web session token, from `copy(localStorage.accessToken)` in "
        "the browser console on app.getswipe.in",
    )
    parser.add_argument(
        "--token-file",
        default="",
        help="read the token from a file (plain text, or the JSON the console "
        "snippet writes)",
    )
    parser.add_argument(
        "--from-json",
        metavar="DIR",
        help="build from cached responses instead of calling Swipe (the "
        "directory --cache writes)",
    )
    parser.add_argument("--cache", metavar="DIR", help="cache API responses here")
    parser.add_argument("--from", dest="start", default=None, help="DD-MM-YYYY")
    parser.add_argument("--to", dest="end", default=None, help="DD-MM-YYYY")
    parser.add_argument(
        "--docs",
        default=DEFAULT_DOCS,
        help=f"comma separated Swipe document types ({', '.join(WEB_DOC_TYPES)})",
    )
    parser.add_argument("--out", default="atria_from_swipe.vyb")
    parser.add_argument("--firm-name", default="")
    parser.add_argument("--firm-gstin", default="")
    parser.add_argument("--firm-state", default="")
    parser.add_argument("--firm-address", default="")
    parser.add_argument("--firm-pincode", default="")
    parser.add_argument("--firm-phone", default="")
    parser.add_argument("--firm-email", default="")
    parser.add_argument("--invoice-prefix", default="")
    parser.add_argument(
        "--pause",
        type=float,
        default=0.35,
        help="seconds between requests (default 0.35)",
    )
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    start = day_from_cli(args.start) if args.start else "01-01-2000"
    end = day_from_cli(args.end) if args.end else (
        datetime.now() + timedelta(days=1)
    ).strftime("%d-%m-%Y")
    window = f"{start} - {end}"
    doc_types = [part.strip() for part in args.docs.split(",") if part.strip()]

    offline = bool(args.from_json)
    if offline and not os.path.isdir(args.from_json):
        raise SwipeError(f"{args.from_json} is not a directory")

    session = SwipeWebSession(
        token=read_token(args),
        cache_dir=args.from_json or args.cache,
        verbose=not args.quiet,
        offline=offline,
        pause=args.pause,
    )
    if offline:
        print(f"reading cached Swipe responses from {args.from_json}")
    print(f"window: {window}")

    books = collect(session, window, doc_types)
    if not books.documents and not books.payments and not books.products:
        raise SwipeError(
            "Nothing came back for that window. Swipe only returns documents "
            "inside the date range you ask for, so widen --from/--to and run "
            "again."
        )

    state = args.firm_state or state_from_gstin(args.firm_gstin) or ""
    firm = {
        "name": args.firm_name or "Imported from Swipe",
        "gstin": args.firm_gstin or None,
        "state": state or None,
        "address": args.firm_address or None,
        "pincode": args.firm_pincode or None,
        "phone": args.firm_phone or None,
        "email": args.firm_email or None,
        "invoice_prefix": args.invoice_prefix or "",
    }
    if not firm["gstin"]:
        books.warn(
            "No --firm-gstin was given, so the import cannot work out which "
            "supplies are inter-state (IGST) -- everything will be treated as "
            "local. Re-run with the firm's GSTIN if it is registered."
        )

    writer = VyaparWriter(books, firm)
    writer.write(args.out)

    print("\nwrote " + os.path.abspath(args.out))
    for key in sorted(writer.counts):
        print(f"  {key}: {writer.counts[key]}")
    for warning in books.warnings:
        print(f"  ! {warning}")
    print(f"  api requests: {session.requests}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SwipeError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
