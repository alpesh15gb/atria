# Atria Orbit ? application design system

## Direction
A financial workspace with a Web3 sensibility: deep ink, electric cobalt,
mineral white and crisp outlined panels. The visual signature is the relationship
between quiet working surfaces and saturated actions. Keep financial information
clear; use gradients only for the brand and summary surfaces.

## App-wide component plan
- Foundations: AppColors, AppTypography, AppRadius and AppShadows own the palette,
  hierarchy, geometry and elevation. Mobile and desktop share these foundations.
- Navigation: retain the existing adaptive shell, destinations and search. Selected
  destinations use a cobalt-tinted surface. Phone navigation retains its touch targets.
- Page hierarchy: AtriaPageHeader owns page titles and actions; AtriaListPage owns
  search, filters and results. Desktop headings are more expressive than row labels.
- Working surfaces: AtriaCard provides a shared outlined panel. AtriaNavRow provides
  destination cards with inset, outlined icon tiles.
- Forms: AtriaFormSection owns section framing and icon badges. Existing responsive
  field rows, validation, editor shortcuts and totals remain in place.
- Controls: the Material theme owns fields, buttons, chips, tabs, menus, dialogs,
  pickers and sheets. Hover/focus feedback uses the same cobalt family.
- Summary emphasis: AtriaSummaryPanel provides a deep blue gradient with a local
  dark theme so nested financial figures remain readable in either page mode.
- Financial states: green means positive/settled, red means danger/negative and amber
  means attention. Never use action blue to replace a financial status colour.

## Screen coverage
Foundations flow through onboarding and sign-in; dashboard; sales, quotations and
purchases; items and stock; parties and statements; payments and expenses; ledger;
reports and GST; settings, backup and administration; and their editors/dialogs.
Use the existing shared components for new screens rather than duplicating styles.

## Guardrails
Preserve data access, calculations, routes, callbacks, permissions and persistence.
Keep body text compact for accounting tables. Avoid decorative glass blur behind
numbers, excessive gradients, invented dashboard data and animation that obstructs
entry. Keep bundled Inter for offline typography. Do not force a theme preference.

## Verification
Run static analysis, existing navigation/editor/responsive tests, and the real-screen
visual dump on desktop and phone. Inspect captures for clipped titles, input labels,
status contrast and long tables. A visual direction is not a claim of an award.

Validated: `dart analyze lib` passes. The 60 real-screen captures and 38 selected
navigation, theme, editor, onboarding and responsive regression tests pass.
Repository-wide analysis also includes a separate server package with unresolved
dependencies and a pre-existing bank-statement test type error.

## Distinct mobile workspace (October 2026)
The phone hierarchy is purpose-built: workspace switcher and search, a sales-led
business overview, two primary creation cards, a compact secondary action strip,
recent invoices, then a two-column workspace directory. All eleven creation
routes remain available through the All actions sheet. This replaces both
four-column reference grids rather than reskinning them.

The inset navigation dock retains the same five destinations and branch state.
MobileTabSwitch is shared by document and party directories. Document cards place
identity and metadata above a readable amount/status row. Create buttons carry
visible labels. Party balances use neutral panels instead of red/green banners.
Settings reuse AtriaNavRow and display the active workspace.

Mobile document editors begin with the subject and products, followed by totals,
document metadata and optional sections. Shared picker cards retain FormField
validation and the searchable choice sheet. The save bar gives the primary save
more space while retaining Save and new. Desktop anatomy is unchanged.

Accessibility: the launcher heading reflows at large text sizes; its regression
check uses a 320dp phone at 2x text scale. Bulk-selection tests scroll to the
requested row and back to the selection toolbar rather than assuming every row
fits into a fixed test viewport.

Mobile redesign validation: 77 selected regression checks pass, including invoice
and purchase save/reopen, required-field validation, bulk selection after scroll,
phone/tablet layouts and responsive desktop editors. Seventeen phone captures
pass in each of dark and light themes. `dart analyze lib` reports no issues.

## One ecosystem across devices
Desktop and mobile read the same creation catalogue for labels, icons, grouping
and routes. Mobile promotes four catalogue entries but offers every action in its
sheet, including debit notes. Both dashboards use AtriaSummaryPanel for Business
snapshot. Navigation, brand mark, semantic states, typography and panel tokens
remain shared; screen arrangements adapt to pointer versus touch input.
System appearance follows the device on both platforms; explicit light/dark
preferences retain the same meaning. Do not introduce device-specific synonyms
or a second action catalogue in future screens.


## User-selected interface size

Use the root `InterfaceScale` wrapper for app-wide scaling; do not independently multiply font sizes or control dimensions. Settings exposes 85%, 100%, 115% and 130%, stored per device. The wrapper adjusts layout constraints and MediaQuery insets while preserving the OS text scaler. Narrow layouts must wrap or stack actions and metadata, and show financial figures completely. Use labelled cards for dense mobile ledger rows. Appearance sheets must scroll at larger sizes.
