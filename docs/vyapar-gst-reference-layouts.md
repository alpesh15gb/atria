# Vyapar reference workbook layouts

The supplied GSTR1, GSTR2 and GSTR3B Excel workbooks define the export layout. The app retains their tab order, 516 fixed labels, header and summary cell positions, blank separators, Calibri 12 font, date formats and original OOXML column widths. Exported values come from the selected business and period; the sample's GSTIN, party names, amounts and transactions are not bundled in the app.

GSTR1 has 14 tabs: `GSTR1 Report`, `b2b,sez,de`, `b2cl`, `b2cs`, `cdnr`, `cdnur`, `exp`, `at`, `atadj`, `exemp`, `hsn(b2b)`, `hsn(b2c)`, `itemSummary`, `docs`.

GSTR2 has 13 tabs: `GSTR2 Report`, `b2b`, `b2bur`, `imps`, `impg`, `cdnr`, `cdnur`, `at`, `atadj`, `exemp`, `itcr`, `hsnsum`, `itemSummary`.

GSTR3B has four tabs: `3.1 Report`, `3.2 Report`, `4 Report`, `5 Report`.

Both Reports → Excel and GST Reports → Save Excel workbook use these layouts. GSTR2 is available as GSTR2 Purchase Report. The standard Excel exporter renames the default sheet before accessing it, and explicitly sets the populated sheet as the default; the GST exporters do the same. All 47 report exports are tested to contain no `Sheet1`.

Multi-rate invoice rows aggregate by rate in the appropriate section, but invoice counts and invoice-value summaries count each document once. The main purchase sheet aggregates item rows into one document row. Mixed invoice numbering series remain separate in documents issued; JSON groups those series under their document type.

These are reference-format preparation workbooks, not certification of GST portal acceptance. The supplied GSTR3B layout omits some current statutory adjustments. Imports, advances, specific exempt/non-GST classifications, reversals and other amounts not captured by the accounting records require review; blank/zero template sections are not evidence that no such activity occurred. JSON exports remain separate preparation data with their existing filing-period validation. Matching the reference layout does not copy its sample balances or automatically establish ITC eligibility.

Verification compares all fixed labels and widths against the supplied files, round-trips generated Excel, checks tab order and active sheet, tests separate tax heads and multi-rate invoice totals, and asserts no empty default sheet across the entire report catalogue.
