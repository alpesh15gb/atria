Vendored from pdfrx_engine 0.4.4 on pub.dev (MIT; see LICENSE).

Two null assertions in pdf_file_cache.dart preserve the existing cache invariant
under Dart 3.13's stricter promotion across awaits. No extraction behavior changes.
Upgrading to pdfrx_engine 0.6 requires archive 4, conflicting with the app's Excel
dependency on archive 3. Remove this override when both dependencies can upgrade.
