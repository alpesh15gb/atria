#!/usr/bin/env python3
"""Pull your Swipe books and write a `.vyb` that Atria imports.

Atria already reads Vyapar company backups (`Settings -> Import from Vyapar`,
see `lib/core/services/vyapar_backup.dart`). That reader is a plain SQLite
database inside a ZIP, so this script does not invent a new format: it reads
Swipe's official Partner API and writes a Vyapar-shaped `.vyb` from it. Atria's
importer then does the real work -- party and item creation, GST rate wise tax,
document numbering, payment linking and the reconciliation of every party
balance against the source books.

What comes across
  * sales invoices, purchases (bills), estimates, pro-forma invoices,
    sales orders, purchase orders and delivery challans, with line items
  * payments in and out, linked back to the document they settle
  * customers, vendors and the product catalog (units, HSN, tax rate, stock)
  * expense heads, so expense categories exist in Atria

Swipe's API key
  Sign in to https://app.getswipe.in, open
  https://app.getswipe.in/user?tab=api_integration and generate a key. It is
  scoped to the company you generate it in. Pass it as `--api-key` or set
  SWIPE_API_KEY. The key is never written to disk by this script.

Usage
  python tools/swipe_to_vyb.py --api-key K --firm-name "Active IT Solutions" \\
      --firm-gstin 36CZFPM0045M2Z7 --from 01-04-2020 --to 31-03-2027

  # cache every API response under ./swipe-cache and rebuild offline later
  python tools/swipe_to_vyb.py --api-key K --cache ./swipe-cache
  python tools/swipe_to_vyb.py --from-json ./swipe-cache --out from_swipe.vyb

The Partner API allows one request per second per key, so a full book takes
about a second per document: the script prints progress and caches as it goes.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import date, datetime, timedelta

BASE_URL = "https://app.getswipe.in/api/partner"
USER_AGENT = "atria-swipe-export/1.0"

# ---------------------------------------------------------------------------
# Swipe document types -> Vyapar txn_type
# ---------------------------------------------------------------------------
# Vyapar's codes, as decoded in lib/core/services/vyapar_backup.dart from
# Vyapar's own `tnc_txn_type_mapping` table. Anything without a code here is
# reported and skipped rather than guessed at -- an invoice mis-filed as a
# credit note would corrupt GST returns.
DOC_TXN_TYPE = {
    "invoice": 1,
    "purchase": 2,
    "sales_order": 24,
    "estimate": 27,
    "purchase_order": 28,
    "delivery_challan": 30,
    "pro_forma_invoice": 83,
}

# Documents that only exist as Atria drafts/open documents, not issued ones.
OPEN_DOC_TYPES = {
    "estimate",
    "sales_order",
    "purchase_order",
    "delivery_challan",
    "pro_forma_invoice",
}

# Vyapar's paymentType_type values: Atria maps CASH/CHEQUE/BANK/CARD onto its
# own modes (and reads UPI from the payment reference).
# Spelled the way Swipe's payment-modes list and the web app spell them, with
# the spacing removed so "Net Banking", "netbanking" and "NetBanking" all land
# on a bank transfer rather than silently falling back to cash.
MODE_TO_PAYMENT_TYPE = {
    "cash": ("CASH", "Cash"),
    "cheque": ("CHEQUE", "Cheque"),
    "chequedd": ("CHEQUE", "Cheque"),
    "demanddraft": ("CHEQUE", "Demand Draft"),
    "dd": ("CHEQUE", "Demand Draft"),
    "card": ("CARD", "Card"),
    "creditcard": ("CARD", "Card"),
    "debitcard": ("CARD", "Card"),
    "emi": ("CARD", "EMI"),
    "upi": ("BANK", "UPI"),
    "netbanking": ("BANK", "Net Banking"),
    "banking": ("BANK", "Net Banking"),
    "banktransfer": ("BANK", "Bank Transfer"),
    "bank": ("BANK", "Bank"),
    "neft": ("BANK", "NEFT/RTGS"),
    "rtgs": ("BANK", "NEFT/RTGS"),
    "imps": ("BANK", "IMPS"),
    "wallet": ("BANK", "Wallet"),
    "paytm": ("BANK", "Paytm"),
    "phonepe": ("BANK", "PhonePe"),
    "googlepay": ("BANK", "Google Pay"),
}

PARTY_KINDS = {"customer": 1, "vendor": 1}


class SwipeError(RuntimeError):
    """Anything that should stop the export with a readable message."""


# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------


class SwipeApi:
    """Thin wrapper over the Partner API: bearer auth, 1 req/s, polite retries."""

    def __init__(
        self,
        api_key: str,
        cache_dir: str | None,
        verbose: bool = True,
        offline: bool = False,
    ):
        self.api_key = api_key
        self.cache_dir = cache_dir
        self.verbose = verbose
        self.offline = offline
        self._last_call = 0.0
        self.requests = 0

    # -- plumbing ---------------------------------------------------------

    def log(self, message: str) -> None:
        if self.verbose:
            print(message, flush=True)

    def _throttle(self) -> None:
        # "Rate limit: 1 request/second per API key" -- stay a hair under it.
        gap = 1.05 - (time.monotonic() - self._last_call)
        if gap > 0:
            time.sleep(gap)
        self._last_call = time.monotonic()

    def get(self, path: str, params: dict | None = None) -> dict:
        url = f"{BASE_URL}{path}"
        if params:
            query = urllib.parse.urlencode(
                {k: v for k, v in params.items() if v not in (None, "")}
            )
            if query:
                url = f"{url}?{query}"

        last_error: Exception | None = None
        for attempt in range(4):
            self._throttle()
            request = urllib.request.Request(
                url,
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "Accept": "application/json",
                    "User-Agent": USER_AGENT,
                },
            )
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    self.requests += 1
                    payload = json.loads(response.read().decode("utf-8"))
                if isinstance(payload, dict) and payload.get("success") is False:
                    raise SwipeError(
                        f"{path}: {payload.get('message') or payload.get('error_code')}"
                    )
                return payload
            except urllib.error.HTTPError as error:
                body = error.read().decode("utf-8", "replace")[:200]
                if error.code in (429, 500, 502, 503, 504) and attempt < 3:
                    wait = 2 * (attempt + 1)
                    self.log(f"  .. {error.code} on {path}, retrying in {wait}s")
                    time.sleep(wait)
                    last_error = SwipeError(f"{error.code} {body}")
                    continue
                if error.code == 401:
                    raise SwipeError(
                        "Swipe rejected the API key (401). Generate a fresh key at "
                        "https://app.getswipe.in/user?tab=api_integration -- it is "
                        "scoped to one company."
                    ) from error
                raise SwipeError(f"{path} failed: HTTP {error.code} {body}") from error
            except urllib.error.URLError as error:
                if attempt < 3:
                    time.sleep(2 * (attempt + 1))
                    last_error = error
                    continue
                raise SwipeError(f"{path} failed: {error}") from error
        raise SwipeError(f"{path} failed: {last_error}")

    # -- cache ------------------------------------------------------------

    def _cache_path(self, name: str) -> str | None:
        if not self.cache_dir:
            return None
        os.makedirs(self.cache_dir, exist_ok=True)
        return os.path.join(self.cache_dir, name)

    def cached(self, name: str, producer, empty=None):
        """Runs [producer] once, then serves the JSON from disk on later runs.

        Offline (--from-json) a missing entry is reported and treated as empty
        rather than reaching for the network, so a partial cache still builds.
        """
        path = self._cache_path(name)
        if path and os.path.exists(path):
            with open(path, "r", encoding="utf-8") as handle:
                return json.load(handle)
        if self.offline:
            self.log(f"  (nothing cached for {name})")
            return [] if empty is None else empty
        value = producer()
        if path:
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(value, handle, indent=1)
        return value

    # -- endpoints --------------------------------------------------------

    def product_list(self) -> list[dict]:
        return self.cached("products.json", lambda: self._paged("/v2/product/list"))

    def customer_list(self) -> list[dict]:
        return self.cached("customers.json", lambda: self._paged("/v2/customer/list"))

    def vendor_list(self) -> list[dict]:
        return self.cached("vendors.json", lambda: self._paged("/v2/vendor/list"))

    def payment_list(self, start: str, end: str) -> list[dict]:
        def fetch() -> list[dict]:
            return self._paged(
                "/v2/payment/list",
                extra={"start_date": start, "end_date": end, "status": "success"},
            )

        return self.cached(f"payments_{start}_{end}.json", fetch)

    def document_list(self, document_type: str, start: str, end: str) -> list[dict]:
        def fetch() -> list[dict]:
            return self._paged(
                "/v2/doc/list",
                extra={
                    "document_type": document_type,
                    "start_date": start,
                    "end_date": end,
                    "payment_status": "all",
                },
            )

        return self.cached(f"docs_{document_type}_{start}_{end}.json", fetch)

    def document_detail(self, document_type: str, hash_id: str) -> dict:
        def fetch() -> dict:
            payload = self.get(f"/v2/doc/{urllib.parse.quote(hash_id)}")
            return payload.get("data") or {}

        return self.cached(f"detail_{document_type}_{hash_id}.json", fetch, empty={})

    def _paged(self, path: str, extra: dict | None = None) -> list[dict]:
        rows: list[dict] = []
        page = 1
        while True:
            params = {"num_records": 100, "page": page}
            params.update(extra or {})
            payload = self.get(path, params)
            data = payload.get("data") or {}
            batch = _first_list(data)
            rows.extend(batch)
            total = data.get("total_records")
            if not batch or (total is not None and len(rows) >= int(total)):
                break
            if len(batch) < 100:
                break
            page += 1
        return rows


def _first_list(data) -> list[dict]:
    """Swipe names the array differently per endpoint; take whichever is there."""
    if isinstance(data, list):
        return [row for row in data if isinstance(row, dict)]
    if isinstance(data, dict):
        for key in (
            "transactions",
            "items",
            "products",
            "customers",
            "vendors",
            "parties",
            "payments",
            "records",
            "list",
        ):
            value = data.get(key)
            if isinstance(value, list):
                return [row for row in value if isinstance(row, dict)]
    return []


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------


def as_float(value, default: float = 0.0) -> float:
    if isinstance(value, bool):
        return default
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        text = value.replace(",", "").replace("₹", "").strip()
        try:
            return float(text)
        except ValueError:
            return default
    return default


def as_text(value) -> str:
    return "" if value is None else str(value).strip()


def to_iso(day: str | None) -> str | None:
    """Swipe dates are DD-MM-YYYY; Vyapar stores ISO strings."""
    text = as_text(day)
    if not text:
        return None
    for pattern in ("%d-%m-%Y", "%Y-%m-%d", "%d/%m/%Y", "%d-%m-%Y %H:%M:%S"):
        try:
            parsed = datetime.strptime(text, pattern)
            return parsed.strftime("%Y-%m-%d 00:00:00")
        except ValueError:
            continue
    return None


def to_iso_timestamp(day: str | None, fallback: datetime | None = None) -> str:
    iso = to_iso(day)
    if iso:
        return iso
    return (fallback or datetime.now()).strftime("%Y-%m-%d 00:00:00")


def day_from_cli(text: str) -> str:
    for pattern in ("%d-%m-%Y", "%Y-%m-%d"):
        try:
            return datetime.strptime(text, pattern).strftime("%d-%m-%Y")
        except ValueError:
            continue
    raise SwipeError(f"date {text!r} is not DD-MM-YYYY")


def normalise_state(name: str | None) -> str | None:
    """Swipe gives state names the way Vyapar (and Atria) spell them."""
    text = as_text(name)
    if not text:
        return None
    return text.upper()


STATE_BY_CODE = {
    "01": "JAMMU AND KASHMIR",
    "02": "HIMACHAL PRADESH",
    "03": "PUNJAB",
    "04": "CHANDIGARH",
    "05": "UTTARAKHAND",
    "06": "HARYANA",
    "07": "DELHI",
    "08": "RAJASTHAN",
    "09": "UTTAR PRADESH",
    "10": "BIHAR",
    "11": "SIKKIM",
    "12": "ARUNACHAL PRADESH",
    "13": "NAGALAND",
    "14": "MANIPUR",
    "15": "MIZORAM",
    "16": "TRIPURA",
    "17": "MEGHALAYA",
    "18": "ASSAM",
    "19": "WEST BENGAL",
    "20": "JHARKHAND",
    "21": "ODISHA",
    "22": "CHHATTISGARH",
    "23": "MADHYA PRADESH",
    "24": "GUJARAT",
    "26": "DADRA & NAGAR HAVELI & DAMAN & DIU",
    "27": "MAHARASHTRA",
    "29": "KARNATAKA",
    "30": "GOA",
    "31": "LAKSHADWEEP",
    "32": "KERALA",
    "33": "TAMIL NADU",
    "34": "PUDUCHERRY",
    "35": "ANDAMAN AND NICOBAR ISLANDS",
    "36": "TELANGANA",
    "37": "ANDHRA PRADESH",
    "38": "LADAKH",
    "97": "OTHER TERRITORY",
}


def state_from_gstin(gstin: str | None) -> str | None:
    text = as_text(gstin).upper()
    if len(text) < 2:
        return None
    return STATE_BY_CODE.get(text[:2])


def slug(text: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9]+", "-", as_text(text)).strip("-")
    return cleaned or "company"


# ---------------------------------------------------------------------------
# Collected books
# ---------------------------------------------------------------------------


class Books:
    """Everything the writer needs, already flattened out of Swipe's JSON."""

    def __init__(self) -> None:
        self.documents: list[dict] = []
        self.payments: list[dict] = []
        self.products: list[dict] = []
        self.customers: list[dict] = []
        self.vendors: list[dict] = []
        self.expenses: list[dict] = []
        self.warnings: list[str] = []
        self.skipped_types: dict[str, int] = {}

    def warn(self, message: str) -> None:
        if message not in self.warnings:
            self.warnings.append(message)


def collect(api: SwipeApi, start: str, end: str, doc_types: list[str]) -> Books:
    books = Books()

    def safely(label: str, producer) -> list[dict]:
        # The catalog lists only enrich what the documents already carry, so a
        # failure here must never cost the user their documents.
        try:
            return producer()
        except SwipeError as error:
            books.warn(f"{label} could not be read: {error}")
            return []

    books.products = safely("the product list", api.product_list)
    books.customers = safely("the customer list", api.customer_list)
    books.vendors = safely("the vendor list", api.vendor_list)
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
            rows = api.document_list(document_type, start, end)
        except SwipeError as error:
            # One bad type must not lose the whole book: report it and carry on.
            books.warn(f"{document_type} could not be listed: {error}")
            continue
        print(f"{document_type}: {len(rows)} document(s)")
        for row in rows:
            if as_text(row.get("payment_status")).lower() == "cancelled":
                books.warn(
                    "Cancelled documents are not imported (they are not books "
                    "yet); the cancelled ones were skipped."
                )
                continue
            hash_id = as_text(row.get("hash_id"))
            if not hash_id:
                continue
            detail = api.document_detail(document_type, hash_id)
            document = detail.get("invoice_details") or detail
            if not isinstance(document, dict) or not document:
                books.warn(f"{document_type} {hash_id} could not be read in full.")
                continue
            document.setdefault("hash_id", hash_id)
            document["_document_type"] = document_type
            # The list row carries fields the detail view does not always repeat.
            for key in ("amount_paid", "amount_pending", "payment_status"):
                if document.get(key) in (None, "") and row.get(key) is not None:
                    document[key] = row[key]
            books.documents.append(document)

    books.payments = api.payment_list(start, end)
    print(f"payments: {len(books.payments)}")
    return books


def load_expenses(path: str) -> list[dict]:
    """Read a Swipe expenses export (CSV or JSON) if the user has one.

    Swipe's Partner API does not expose the Expenses module, so this is the one
    part of a Swipe book the API cannot hand over. The expenses page in the
    dashboard can be exported to CSV/XLSX; save it as CSV next to this script
    and pass it with --expenses-file. Columns are matched loosely
    (date/amount/category/vendor/notes), so an edited file still works.
    """
    with open(path, "r", encoding="utf-8-sig") as handle:
        text = handle.read().strip()
    if not text:
        return []
    if text[0] in "[{":
        raw = json.loads(text)
        rows = raw if isinstance(raw, list) else raw.get("transactions", [])
        return [row for row in rows if isinstance(row, dict)]

    import csv
    import io

    reader = csv.DictReader(io.StringIO(text))
    out: list[dict] = []
    for row in reader:
        lowered = {as_text(k).lower(): v for k, v in row.items()}
        amount = None
        for key in ("amount", "total", "total amount", "expense amount", "value"):
            if lowered.get(key) not in (None, ""):
                amount = as_float(lowered.get(key))
                break
        if not amount:
            continue
        out.append(
            {
                "date": lowered.get("date") or lowered.get("expense date"),
                "category": lowered.get("category")
                or lowered.get("expense category")
                or lowered.get("head")
                or "Expense",
                "amount": amount,
                "vendor": lowered.get("vendor")
                or lowered.get("party")
                or lowered.get("paid to")
                or "",
                "notes": lowered.get("notes") or lowered.get("description") or "",
                "mode": lowered.get("mode")
                or lowered.get("payment mode")
                or "cash",
            }
        )
    return out


# ---------------------------------------------------------------------------
# Writer: Swipe JSON -> Vyapar-shaped SQLite
# ---------------------------------------------------------------------------

SCHEMA = """
CREATE TABLE kb_firms (
  firm_id INTEGER, firm_name TEXT, firm_gstin_number TEXT, firm_state TEXT,
  firm_address TEXT, firm_pincode TEXT, firm_phone TEXT, firm_email TEXT,
  firm_invoice_prefix TEXT, firm_bank_name TEXT, firm_bank_account_number TEXT,
  firm_bank_ifsc_code TEXT);
CREATE TABLE kb_names (
  name_id INTEGER, full_name TEXT, party_billing_name TEXT, name_type INTEGER,
  name_group_id INTEGER, name_gstin_number TEXT, name_state TEXT,
  phone_number TEXT, email TEXT, amount REAL, address TEXT, pincode TEXT,
  credit_limit INTEGER, credit_limit_enabled INTEGER, name_expense_type TEXT,
  name_customer_type INTEGER);
CREATE TABLE kb_settings (setting_id INTEGER, setting_key TEXT,
  setting_value TEXT);
CREATE TABLE kb_tax_code (
  tax_code_id INTEGER, tax_code_name TEXT, tax_rate REAL, tax_code_type INTEGER);
CREATE TABLE kb_item_units (
  unit_id INTEGER, unit_name TEXT, unit_short_name TEXT);
CREATE TABLE kb_item_categories (
  item_category_id INTEGER, item_category_name TEXT);
CREATE TABLE kb_party_groups (
  party_group_id INTEGER, party_group_name TEXT);
CREATE TABLE kb_paymentTypes (
  paymentType_id INTEGER, paymentType_type TEXT, paymentType_name TEXT,
  paymentType_bankName TEXT);
CREATE TABLE kb_items (
  item_id INTEGER, item_name TEXT, item_code TEXT, base_unit_id INTEGER,
  item_hsn_sac_code TEXT, item_tax_id INTEGER, item_tax_type INTEGER,
  item_sale_unit_price REAL, item_purchase_unit_price REAL,
  item_stock_quantity REAL, item_min_stock_quantity REAL, item_type INTEGER,
  category_id INTEGER, item_mrp REAL, item_wholesale_price REAL,
  item_description TEXT, item_catalogue_description TEXT,
  item_additional_cess_per_unit REAL);
CREATE TABLE kb_transactions (
  txn_id INTEGER, txn_date TEXT, txn_due_date TEXT, txn_name_id INTEGER,
  txn_type INTEGER, txn_sub_type INTEGER, txn_status INTEGER,
  txn_payment_status INTEGER, txn_ref_number_char TEXT,
  txn_invoice_prefix TEXT, txn_payment_reference TEXT,
  txn_cash_amount REAL, txn_balance_amount REAL, txn_round_off_amount REAL,
  txn_discount_amount REAL, txn_discount_percent REAL, txn_tax_amount REAL,
  txn_tax_inclusive INTEGER, txn_payment_type_id INTEGER,
  txn_place_of_supply TEXT, txn_billing_address TEXT, txn_shipping_address TEXT,
  txn_description TEXT);
CREATE TABLE kb_lineitems (
  lineitem_id INTEGER, lineitem_txn_id INTEGER, item_id INTEGER,
  quantity REAL, priceperunit REAL, total_amount REAL,
  lineitem_tax_amount REAL, lineitem_discount_amount REAL,
  lineitem_discount_percent REAL, lineitem_additional_cess REAL,
  lineitem_unit_id INTEGER, lineitem_tax_id INTEGER, lineitem_description TEXT);
CREATE TABLE kb_txn_links (
  txn_links_id INTEGER, txn_links_txn_1_id INTEGER, txn_links_txn_2_id INTEGER,
  txn_links_amount REAL, txn_links_txn_1_type INTEGER,
  txn_links_txn_2_type INTEGER);
CREATE TABLE txn_payment_mapping (
  id INTEGER, payment_id INTEGER, cheque_id INTEGER, txn_id INTEGER,
  amount REAL, payment_reference TEXT);
"""


class VyaparWriter:
    """Turns [Books] into the tables Atria's Vyapar reader looks for."""

    def __init__(self, books: Books, firm: dict):
        self.books = books
        self.firm = firm
        self.db = sqlite3.connect(":memory:")
        self.db.executescript(SCHEMA)
        self.name_ids: dict[tuple[str, str], int] = {}
        self.item_ids: dict[str, int] = {}
        self.tax_ids: dict[float, int] = {}
        self.unit_ids: dict[str, int] = {}
        self.category_ids: dict[str, int] = {}
        self.payment_type_ids: dict[str, int] = {}
        self.doc_ids: dict[str, int] = {}
        self.link_count = 0
        self.mapping_count = 0
        self.line_count = 0
        self.counts: dict[str, int] = {}

    # -- ids --------------------------------------------------------------

    def tax_id(self, rate: float) -> int:
        key = round(float(rate or 0), 3)
        if key not in self.tax_ids:
            new_id = len(self.tax_ids) + 1
            self.tax_ids[key] = new_id
            self.db.execute(
                "INSERT INTO kb_tax_code VALUES (?, ?, ?, 1)",
                (new_id, f"GST@{key:g}%", key),
            )
        return self.tax_ids[key]

    def unit_id(self, unit: str | None) -> int:
        name = as_text(unit) or "NOS"
        key = name.lower()
        if key not in self.unit_ids:
            new_id = len(self.unit_ids) + 1
            self.unit_ids[key] = new_id
            self.db.execute(
                "INSERT INTO kb_item_units VALUES (?, ?, ?)",
                (new_id, name.upper(), name),
            )
        return self.unit_ids[key]

    def category_id(self, category: str | None) -> int | None:
        name = as_text(category)
        if not name:
            return None
        key = name.lower()
        if key not in self.category_ids:
            new_id = len(self.category_ids) + 1
            self.category_ids[key] = new_id
            self.db.execute(
                "INSERT INTO kb_item_categories VALUES (?, ?)", (new_id, name)
            )
        return self.category_ids[key]

    def payment_type_id(self, mode: str | None, bank_name: str | None) -> int:
        text = re.sub(r"[^a-z]", "", as_text(mode).lower())
        kind, label = MODE_TO_PAYMENT_TYPE.get(text, ("CASH", "Cash"))
        if kind in ("BANK", "CARD") and as_text(bank_name):
            label = as_text(bank_name)
        key = f"{kind}:{label}".lower()
        if key not in self.payment_type_ids:
            new_id = len(self.payment_type_ids) + 1
            self.payment_type_ids[key] = new_id
            self.db.execute(
                "INSERT INTO kb_paymentTypes VALUES (?, ?, ?, ?)",
                (new_id, kind, label, as_text(bank_name)),
            )
        return self.payment_type_ids[key]

    def item_id(self, swipe_item_id: str, name: str) -> int:
        key = as_text(swipe_item_id) or as_text(name).lower()
        if key not in self.item_ids:
            new_id = len(self.item_ids) + 1
            self.item_ids[key] = new_id
        return self.item_ids[key]

    # -- parties ----------------------------------------------------------

    def parties(self) -> None:
        rows: dict[tuple[str, str], dict] = {}

        for kind, listed in (
            ("customer", self.books.customers),
            ("vendor", self.books.vendors),
        ):
            for row in listed:
                name = as_text(row.get("name") or row.get("party_name"))
                if not name:
                    continue
                rows[(name.lower(), kind)] = row

        # Parties on documents are authoritative: they carry the state the
        # invoice was actually taxed in.
        for document in self.books.documents:
            party = document.get("party") or document.get("customer") or {}
            name = as_text(party.get("name"))
            if not name:
                continue
            kind = as_text(party.get("type")).lower() or (
                "vendor" if document.get("_document_type", "").startswith("purchase") else "customer"
            )
            rows[(name.lower(), kind)] = {**rows.get((name.lower(), kind), {}), **party}

        for (_, _kind), row in rows.items():
            self._write_party(row)

        # Expense heads: Vyapar keeps them among the names with name_type 2, and
        # Atria turns exactly those into expense categories.
        for expense in self.books.expenses:
            head = as_text(expense.get("category"))
            if not head:
                continue
            cursor = self.db.execute(
                "SELECT 1 FROM kb_names WHERE name_type = 2 AND lower(full_name) = ?",
                (head.lower(),),
            )
            if cursor.fetchone():
                continue
            new_id = len(self.name_ids) + 1
            self.name_ids[("expense:" + head.lower(), "expense")] = new_id
            self.db.execute(
                "INSERT INTO kb_names (name_id, full_name, name_type, amount, "
                "name_customer_type, name_expense_type) VALUES (?, ?, 2, 0, 0, '1')",
                (new_id, head),
            )

    def _write_party(self, row: dict) -> None:
        name = as_text(row.get("name"))
        if not name:
            return
        billing = row.get("billing_address") or {}
        address_lines = [
            as_text(billing.get(key))
            for key in ("address_line1", "address_line2", "city")
            if as_text(billing.get(key))
        ]
        state = normalise_state(billing.get("state"))
        gstin = as_text(row.get("gstin")).upper()
        phone = as_text(row.get("phone_number"))
        country_code = as_text(row.get("country_code")) or "91"

        new_id = len(self.name_ids) + 1
        self.name_ids[(name.lower(), "party")] = new_id
        self.db.execute(
            "INSERT INTO kb_names (name_id, full_name, party_billing_name, "
            "name_type, name_gstin_number, name_state, phone_number, email, "
            "amount, address, pincode, credit_limit, credit_limit_enabled, "
            "name_customer_type) VALUES (?, ?, ?, 1, ?, ?, ?, ?, 0, ?, ?, 0, 0, ?)",
            (
                new_id,
                name,
                name,
                gstin or None,
                state,
                f"{country_code}{phone}" if phone else None,
                as_text(row.get("email")) or None,
                "\n".join(address_lines) or None,
                as_text(billing.get("pincode")) or None,
                1 if gstin and len(gstin) == 15 else 0,
            ),
        )

    def party_name_id(self, name: str, document_type: str) -> int | None:
        key = (as_text(name).lower(), "party")
        if key in self.name_ids:
            return self.name_ids[key]
        for (candidate, kind), value in self.name_ids.items():
            if candidate == key[0] and kind in ("party", "customer", "vendor"):
                return value
        return None

    # -- catalog ----------------------------------------------------------

    def catalog(self) -> None:
        for row in self.books.products:
            swipe_id = as_text(row.get("id") or row.get("swipe_id"))
            name = as_text(row.get("name"))
            if not name:
                continue
            item_id = self.item_id(swipe_id, name)
            is_service = as_text(row.get("item_type")).lower() == "service"
            self.db.execute(
                "INSERT INTO kb_items (item_id, item_name, item_code, "
                "base_unit_id, item_hsn_sac_code, item_tax_id, item_tax_type, "
                "item_sale_unit_price, item_purchase_unit_price, "
                "item_stock_quantity, item_min_stock_quantity, item_type, "
                "category_id, item_mrp, item_wholesale_price, item_description, "
                "item_additional_cess_per_unit) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, 0, ?, ?, 0, 0, ?, 0)",
                (
                    item_id,
                    name,
                    swipe_id or None,
                    self.unit_id(row.get("unit")),
                    as_text(row.get("hsn_code")) or None,
                    self.tax_id(as_float(row.get("tax_rate"))),
                    2 if is_service else 1,
                    as_float(row.get("unit_price")),
                    as_float(row.get("quantity")),
                    1,
                    self.category_id(row.get("category")),
                    as_text(row.get("description")) or None,
                ),
            )
        self.counts["items"] = len(self.item_ids)

    # -- documents --------------------------------------------------------

    def documents(self) -> None:
        txn_id = 0
        for document in self.books.documents:
            document_type = document.get("_document_type") or "invoice"
            txn_type = DOC_TXN_TYPE.get(document_type)
            if txn_type is None:
                continue
            txn_id += 1
            hash_id = as_text(document.get("hash_id"))
            self.doc_ids[hash_id] = txn_id

            party = document.get("party") or document.get("customer") or {}
            party_name = as_text(party.get("name")) or "Walk-in customer"
            name_id = self.party_name_id(party_name, document_type)
            billing = party.get("billing_address") or {}
            place_of_supply = normalise_state(billing.get("state"))
            if not place_of_supply:
                place_of_supply = state_from_gstin(party.get("gstin"))

            total = as_float(document.get("total_amount"))
            status = 2 if document_type in OPEN_DOC_TYPES else 1
            payment_status = as_text(document.get("payment_status")).lower()
            vyapar_payment_status = {"paid": 3, "pending": 1}.get(payment_status, 1)

            # Vyapar's two figures are: what was paid through the document's own
            # payment-mode map (`txn_cash_amount`) and what is still owed before
            # its separate payment transactions are subtracted
            # (`txn_balance_amount`). Atria's importer subtracts each linked
            # payment transaction from the balance, so emitting Swipe's
            # already-netted `amount_pending` here would deduct those payments
            # twice and show a settled bill as paid twice over.
            embedded_total = sum(
                as_float(payment.get("amount"))
                for payment in (document.get("payments") or [])
                if isinstance(payment, dict)
            )
            cash_amount = embedded_total
            balance_amount = max(total - embedded_total, 0.0)

            self.db.execute(
                "INSERT INTO kb_transactions (txn_id, txn_date, txn_due_date, "
                "txn_name_id, txn_type, txn_sub_type, txn_status, "
                "txn_payment_status, txn_ref_number_char, txn_invoice_prefix, "
                "txn_payment_reference, txn_cash_amount, txn_balance_amount, "
                "txn_round_off_amount, txn_discount_amount, txn_discount_percent, "
                "txn_tax_amount, txn_tax_inclusive, txn_payment_type_id, "
                "txn_place_of_supply, txn_description) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, '', NULL, ?, ?, 0, ?, 0, ?, 2, "
                "NULL, ?, ?)",
                (
                    txn_id,
                    to_iso_timestamp(document.get("document_date")),
                    to_iso(document.get("due_date")),
                    name_id,
                    txn_type,
                    1,
                    status,
                    vyapar_payment_status,
                    as_text(document.get("serial_number")) or None,
                    cash_amount if status == 1 else 0,
                    balance_amount if status == 1 else total,
                    as_float(document.get("total_discount")),
                    as_float(document.get("tax_amount")),
                    place_of_supply,
                    as_text(document.get("notes")) or as_text(document.get("terms")) or None,
                ),
            )

            self._lines(txn_id, document)
            self._embedded_payments(txn_id, document)
            self.counts[document_type] = self.counts.get(document_type, 0) + 1

        self.counts["documents"] = txn_id

    def _lines(self, txn_id: int, document: dict) -> None:
        line_id = self.line_count
        written = 0
        for item in document.get("items") or []:
            if not isinstance(item, dict):
                continue
            line_id += 1
            written += 1
            self.line_count = line_id
            name = as_text(item.get("name")) or "Item"
            rate = as_float(item.get("tax_rate"))
            quantity = as_float(item.get("quantity"), 1.0) or 1.0
            unit_price = as_float(item.get("unit_price"))
            net = as_float(item.get("net_amount"))
            if not net:
                net = quantity * unit_price
            total = as_float(item.get("total_amount")) or net
            discount_amount = as_float(item.get("discount_amount"))
            discount_percent = as_float(item.get("discount_percent"))
            self.db.execute(
                "INSERT INTO kb_lineitems (lineitem_id, lineitem_txn_id, item_id, "
                "quantity, priceperunit, total_amount, lineitem_tax_amount, "
                "lineitem_discount_amount, lineitem_discount_percent, "
                "lineitem_additional_cess, lineitem_unit_id, lineitem_tax_id, "
                "lineitem_description) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)",
                (
                    line_id,
                    txn_id,
                    self.item_id(as_text(item.get("id")), name),
                    quantity,
                    unit_price,
                    total,
                    round(total - net, 4),
                    discount_amount,
                    discount_percent,
                    self.unit_id(item.get("unit")),
                    self.tax_id(rate),
                    as_text(item.get("description")) or name,
                ),
            )
        if not written:
            self.books.warn(
                f"{document.get('serial_number') or 'a document'} came back with no "
                "line items, so only its totals could be imported."
            )

    def _embedded_payments(self, txn_id: int, document: dict) -> None:
        """Payments recorded together with the document (`payments[]`)."""
        for payment in document.get("payments") or []:
            if not isinstance(payment, dict):
                continue
            amount = as_float(payment.get("amount"))
            if amount <= 0:
                continue
            mode = as_text(payment.get("method"))
            bank = as_text((payment.get("bank_details") or {}).get("bank_name"))
            self.db.execute(
                "INSERT INTO txn_payment_mapping VALUES (?, ?, NULL, ?, ?, ?)",
                (
                    self.mapping_count + 1,
                    self.payment_type_id(mode, bank),
                    txn_id,
                    amount,
                    mode.upper() or None,
                ),
            )
            self.mapping_count += 1

    # -- payments ---------------------------------------------------------

    def payments(self) -> None:
        txn_id = max(self.doc_ids.values(), default=0)
        number = 0
        document_by_key: dict[tuple[str, str], str] = {}
        for document in self.books.documents:
            key = (
                as_text(document.get("_document_type")),
                as_text(document.get("serial_number")).lower(),
            )
            document_by_key[key] = as_text(document.get("hash_id"))

        for payment in self.books.payments:
            total = as_float(payment.get("total_amount")) or as_float(
                payment.get("amount")
            )
            if total <= 0:
                continue
            number += 1
            txn_id += 1
            flow = as_text(payment.get("payment_type")).lower()
            is_in = flow not in ("out", "payment_out", "debit")
            party = payment.get("customer") or payment.get("party") or {}
            party_name = as_text(party.get("name")) or as_text(payment.get("name"))
            name_id = self.party_name_id(party_name, "payment")
            mode = as_text(payment.get("payment_mode")) or "cash"
            bank = as_text((payment.get("bank_details") or {}).get("bank_name"))

            self.db.execute(
                "INSERT INTO kb_transactions (txn_id, txn_date, txn_due_date, "
                "txn_name_id, txn_type, txn_sub_type, txn_status, "
                "txn_payment_status, txn_ref_number_char, txn_invoice_prefix, "
                "txn_payment_reference, txn_cash_amount, txn_balance_amount, "
                "txn_round_off_amount, txn_discount_amount, txn_discount_percent, "
                "txn_tax_amount, txn_tax_inclusive, txn_payment_type_id, "
                "txn_place_of_supply, txn_description) "
                "VALUES (?, ?, NULL, ?, ?, 1, 1, ?, ?, '', ?, ?, 0, 0, 0, 0, 0, 2, "
                "?, NULL, ?)",
                (
                    txn_id,
                    to_iso_timestamp(payment.get("payment_date")),
                    name_id,
                    3 if is_in else 4,
                    None,
                    f"PAY-{number:05d}",
                    mode.upper(),
                    # A payment's own amount rides in `txn_cash_amount`: that is
                    # where Vyapar keeps it, and Atria's importer reads a
                    # payment transaction's amount from there.
                    total,
                    self.payment_type_id(mode, bank),
                    as_text(payment.get("notes"))
                    or as_text(payment.get("exclusive_notes"))
                    or None,
                ),
            )
            self.counts["payment_in" if is_in else "payment_out"] = (
                self.counts.get("payment_in" if is_in else "payment_out", 0) + 1
            )

            for linked in payment.get("linked_docs") or []:
                if not isinstance(linked, dict):
                    continue
                amount = as_float(linked.get("amount_settled")) or total
                key = (
                    as_text(linked.get("document_type")),
                    as_text(linked.get("serial_number")).lower(),
                )
                hash_id = document_by_key.get(key)
                target = self.doc_ids.get(hash_id or "")
                if target is None:
                    self.books.warn(
                        f"A payment of {amount:g} settled "
                        f"{as_text(linked.get('serial_number')) or 'a document'} that "
                        "was not in the exported window; it was imported unallocated."
                    )
                    continue
                document_type = DOC_TXN_TYPE.get(key[0], 1)
                self.link_count += 1
                self.db.execute(
                    "INSERT INTO kb_txn_links VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        self.link_count,
                        txn_id,
                        target,
                        amount,
                        3 if is_in else 4,
                        document_type,
                    ),
                )

    # -- expenses ---------------------------------------------------------

    def expenses(self) -> None:
        """Swipe's API has no expenses endpoint, so these come from the export.

        They are written the way Vyapar writes an expense: a journal entry that
        debits the expense head and credits cash or bank.
        """
        if not self.books.expenses:
            return
        self.db.executescript(
            """
CREATE TABLE IF NOT EXISTS other_accounts (
  id INTEGER, name TEXT, opening_balance REAL, opening_balance_date TEXT,
  account_type INTEGER, account_identifier INTEGER, created_by TEXT,
  modified_by TEXT, created_at TEXT, modified_at TEXT);
CREATE TABLE IF NOT EXISTS journal_entry (
  id INTEGER, journal_firm_id INTEGER, reference_number TEXT, date TEXT,
  description TEXT, created_by TEXT, modified_by TEXT, created_at TEXT,
  modified_at TEXT);
CREATE TABLE IF NOT EXISTS journal_entry_line_items (
  id INTEGER, journal_entry_id INTEGER, account_id INTEGER, amount REAL,
  amount_type TEXT, reference_account_id INTEGER, txn_link_id INTEGER);
"""
        )
        # The account's *name* is what the reader can match on, so the display
        # spelling is kept (`Rent`, not `rent`) and only the lookup key is
        # folded to lower case.
        accounts: dict[str, int] = {}
        for label, account_type in (
            [("Cash", 201), ("Bank", 201)]
            + [
                (as_text(expense.get("category")) or "Expense", 101)
                for expense in self.books.expenses
            ]
        ):
            key = label.lower()
            if key in accounts:
                continue
            account_id = len(accounts) + 1
            accounts[key] = account_id
            self.db.execute(
                "INSERT INTO other_accounts (id, name, opening_balance, "
                "account_type) VALUES (?, ?, 0, ?)",
                (account_id, label, account_type),
            )

        entry_id = 0
        line_id = 0
        for expense in self.books.expenses:
            amount = as_float(expense.get("amount"))
            if amount <= 0:
                # An expense head with nothing against it is a category, not a
                # journal entry -- Vyapar keeps those separately, and a zero
                # amount would only add noise to the ledger.
                continue
            entry_id += 1
            date_text = expense.get("date") or expense.get("expense_date")
            iso = to_iso(date_text) or to_iso_timestamp(None)
            vendor = as_text(expense.get("vendor"))
            notes = as_text(expense.get("notes"))
            description = " - ".join(part for part in (vendor, notes) if part) or "Expense"
            self.db.execute(
                "INSERT INTO journal_entry (id, journal_firm_id, "
                "reference_number, date, description) VALUES (?, 1, ?, ?, ?)",
                (entry_id, f"EXP-{entry_id:05d}", iso, description),
            )
            head_account = accounts[(as_text(expense.get("category")) or "Expense").lower()]
            mode = as_text(expense.get("mode")).lower()
            cash_account = accounts["bank" if mode and mode != "cash" else "cash"]
            for account_id, amount_type in ((head_account, "debit"), (cash_account, "credit")):
                line_id += 1
                self.db.execute(
                    "INSERT INTO journal_entry_line_items VALUES (?, ?, ?, ?, ?, "
                    "NULL, NULL)",
                    (line_id, entry_id, account_id, amount, amount_type),
                )
            self.counts["expenses"] = self.counts.get("expenses", 0) + 1

    # -- firm -------------------------------------------------------------

    def firm_row(self) -> None:
        self.db.execute(
            "INSERT INTO kb_firms VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                self.firm["name"],
                self.firm.get("gstin"),
                self.firm.get("state"),
                self.firm.get("address"),
                self.firm.get("pincode"),
                self.firm.get("phone"),
                self.firm.get("email"),
                self.firm.get("invoice_prefix"),
                self.firm.get("bank_name"),
                self.firm.get("bank_account_number"),
                self.firm.get("bank_ifsc"),
            ),
        )
        # VYAPAR.GSTENABLED is how Vyapar records GST registration -- kb_firms
        # itself carries no such flag, and Atria reads it from here.
        self.db.execute(
            "INSERT INTO kb_settings VALUES (1, 'VYAPAR.GSTENABLED', ?)",
            ("1" if self.firm.get("gstin") else "0",),
        )

    # -- output -----------------------------------------------------------

    def write(self, out_path: str) -> None:
        self.firm_row()
        self.catalog()
        self.parties()
        self.documents()
        self.payments()
        self.expenses()
        self.db.commit()

        with tempfile.TemporaryDirectory(prefix="swipe_to_vyb_") as workdir:
            db_path = os.path.join(workdir, "company.vyp")
            file_db = sqlite3.connect(db_path)
            self.db.backup(file_db)
            file_db.close()
            with zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.write(
                    db_path,
                    f"{slug(self.firm['name'])}__t_"
                    f"{datetime.now().strftime('%Y_%m_%d_%H_%M_%S')}_swipe.vyp",
                )
        self.db.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Export a Swipe company into Atria's Vyapar-format .vyb backup."
    )
    parser.add_argument("--api-key", default=os.environ.get("SWIPE_API_KEY", ""))
    parser.add_argument(
        "--from-json",
        metavar="DIR",
        help="build from cached API responses instead of calling Swipe "
        "(the directory --cache writes)",
    )
    parser.add_argument("--cache", metavar="DIR", help="cache API responses here")
    parser.add_argument("--from", dest="start", default=None, help="DD-MM-YYYY")
    parser.add_argument("--to", dest="end", default=None, help="DD-MM-YYYY")
    parser.add_argument(
        "--docs",
        default="invoice,purchase,estimate,pro_forma_invoice,delivery_challan,"
        "purchase_order",
        help="comma separated Swipe document types (invoice, purchase, estimate, "
        "pro_forma_invoice, delivery_challan, purchase_order)",
    )
    parser.add_argument(
        "--expenses-file",
        help="CSV/JSON export of Swipe's Expenses page (the Partner API does not "
        "expose expenses)",
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
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    start = day_from_cli(args.start) if args.start else "01-01-2000"
    end = day_from_cli(args.end) if args.end else (
        datetime.now() + timedelta(days=1)
    ).strftime("%d-%m-%Y")
    doc_types = [part.strip() for part in args.docs.split(",") if part.strip()]

    if args.from_json:
        if not os.path.isdir(args.from_json):
            raise SwipeError(f"{args.from_json} is not a directory")
        if not args.expenses_file:
            candidate = os.path.join(args.from_json, "expenses.csv")
            if os.path.exists(candidate):
                args.expenses_file = candidate
        api = SwipeApi(
            api_key="cached",
            cache_dir=args.from_json,
            verbose=not args.quiet,
            offline=True,
        )
        print(f"reading cached Swipe responses from {args.from_json}")
    else:
        if not args.api_key:
            raise SwipeError(
                "An API key is required. Generate one at "
                "https://app.getswipe.in/user?tab=api_integration and pass it with "
                "--api-key or set SWIPE_API_KEY."
            )
        api = SwipeApi(api_key=args.api_key, cache_dir=args.cache, verbose=not args.quiet)

    books = collect(api, start, end, doc_types)
    if args.expenses_file:
        books.expenses = load_expenses(args.expenses_file)
        print(f"expenses file: {len(books.expenses)} expense(s)")

    if not books.documents and not books.payments and not books.products:
        raise SwipeError(
            "Nothing came back for that date range. Widen --from/--to (Swipe's "
            "API always wants an explicit range) and run again."
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
    if writer.counts.get("expenses"):
        print(
            "  note: expenses are written the way Vyapar writes them -- one "
            "journal entry per expense -- and import as Atria expenses."
        )
    for warning in books.warnings:
        print(f"  ! {warning}")
    print(f"  api requests: {api.requests}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SwipeError as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(2)
