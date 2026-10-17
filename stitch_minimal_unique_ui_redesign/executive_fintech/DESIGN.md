---
name: Executive FinTech
colors:
  surface: '#fff8f5'
  surface-dim: '#e0d8d5'
  surface-bright: '#fff8f5'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#faf2ee'
  surface-container: '#f4ece8'
  surface-container-high: '#eee7e3'
  surface-container-highest: '#e9e1dd'
  on-surface: '#1e1b19'
  on-surface-variant: '#3d4947'
  inverse-surface: '#33302d'
  inverse-on-surface: '#f7efeb'
  outline: '#6d7a77'
  outline-variant: '#bcc9c6'
  surface-tint: '#006a61'
  primary: '#00685f'
  on-primary: '#ffffff'
  primary-container: '#008378'
  on-primary-container: '#f4fffc'
  inverse-primary: '#6bd8cb'
  secondary: '#5b598c'
  on-secondary: '#ffffff'
  secondary-container: '#c7c3fe'
  on-secondary-container: '#514f81'
  tertiary: '#006948'
  on-tertiary: '#ffffff'
  tertiary-container: '#00855d'
  on-tertiary-container: '#f5fff7'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#89f5e7'
  primary-fixed-dim: '#6bd8cb'
  on-primary-fixed: '#00201d'
  on-primary-fixed-variant: '#005049'
  secondary-fixed: '#e3dfff'
  secondary-fixed-dim: '#c4c1fb'
  on-secondary-fixed: '#181445'
  on-secondary-fixed-variant: '#444173'
  tertiary-fixed: '#85f8c4'
  tertiary-fixed-dim: '#68dba9'
  on-tertiary-fixed: '#002114'
  on-tertiary-fixed-variant: '#005137'
  background: '#fff8f5'
  on-background: '#1e1b19'
  surface-variant: '#e9e1dd'
typography:
  headline-xl:
    fontFamily: Manrope
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.03em
  headline-lg:
    fontFamily: Manrope
    fontSize: 24px
    fontWeight: '700'
    lineHeight: 32px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Manrope
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
    letterSpacing: -0.015em
  headline-sm:
    fontFamily: Manrope
    fontSize: 16px
    fontWeight: '600'
    lineHeight: 24px
    letterSpacing: -0.01em
  body-lg:
    fontFamily: Hanken Grotesk
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Hanken Grotesk
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Hanken Grotesk
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
  label-lg:
    fontFamily: Hanken Grotesk
    fontSize: 14px
    fontWeight: '600'
    lineHeight: 20px
    letterSpacing: 0.01em
  label-md:
    fontFamily: Hanken Grotesk
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Hanken Grotesk
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.03em
  currency-display:
    fontFamily: Manrope
    fontSize: 28px
    fontWeight: '700'
    lineHeight: 34px
    letterSpacing: -0.02em
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  gutter: 0.75rem
  margin: 1rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 0.75rem
  space-lg: 1.25rem
  space-xl: 1.75rem
---

## Brand & Style

This design system establishes an executive-tier financial workspace tailored for modern entrepreneurs, finance leads, and growing commercial enterprises. It actively moves away from utilitarian, high-density desktop-ported billing spreadsheets toward an elevated, bespoke mobile wealth and ledger management experience.

The visual direction pairs structured institutional precision with modern FinTech warmth. Surfaces are built on warm off-white and soft cream foundations rather than cold synthetic grays. Bold accents provide clear intentionality: deep indigo structures the core hierarchy, while rich teal delivers active operational emphasis and transactional clarity. The tone is assured, organized, and quietly luxurious, reinforcing confidence in complex daily ledgers and multi-entity accounting.

## Colors

The palette balances executive weight with crisp action cues:

- **Primary (`#0D9488`):** Deep, radiant teal deployed for primary interactive targets, active state selections, and metric accents.
- **Secondary (`#1E1B4B`):** Deep indigo providing strong structural contrast for executive cards, dark navigation bars, header elements, and master metrics.
- **Tertiary (`#059669`):** Grounded emerald reserved for positive delta changes, settled balances, and success statuses. Paired alongside an alert coral (`#E11D48`) for outstanding dues and debit alerts.
- **Neutral & Canvas:** Backdrops rely on a warm mineral tint (`#FBFBF9`), elevated by pure white (`#FFFFFF`) card surfaces and bordered with delicate neutral strokes (`#E7E5E4`). High-contrast typography employs dark stone (`#1C1917`) down to muted graphite (`#78716C`) for metadata.

## Typography

Typography prioritizes clarity, data legibility, and geometric sharpness:

- **Headlines (`Manrope`):** Delivers clean geometry and authority across key balance tallies, ledger totals, and section headings. Numeric representations utilize tabular figures to prevent layout jitter across fluctuating balances.
- **Body & Labels (`Hanken Grotesk`):** Provides high-clarity legibility at compact mobile scale. Designed for dense ledger rows, tax descriptions, client identifiers, and audit histories without visual degradation.
- **Numbers & Currencies:** Currency symbols and integer figures must share strict baseline alignment. Never downscale currency glyphs unnaturally; maintain proportional tracking across financial data points.

## Layout & Spacing

The layout is constructed specifically for mobile viewport ergonomics:

- **Grid Architecture:** Employs a fluid 4-column system on phones with `1rem` outer margins and `0.75rem` column gutters. Expanding to an 8-column layout for tablets and landscape displays with `1.5rem` outer gutters.
- **Vertical Hierarchy:** Sections are separated by `space-lg` to provide breathing room between metric overviews, creation triggers, and detailed ledger registries.
- **Component Breathing Room:** Replaces tight, congested grids with grouped action cards utilizing `space-md` interior padding, ensuring targets meet a minimum 48px touch boundary for rapid field input.

## Elevation & Depth

This design system avoids heavy drop shadows, relying on layered warmth, structural boundaries, and soft ambient light:

- **Layer 0 (Canvas):** Warm stone background (`#FBFBF9`) acting as the recessed plane.
- **Layer 1 (Card Surfaces):** Crisp pure white (`#FFFFFF`) surfaces defined by a 1px soft border (`#E7E5E4`) and a subtle ambient occlusion shadow (`0 2px 8px -2px rgba(28, 25, 23, 0.04)`).
- **Layer 2 (Interactive Modules):** Highlighted cards and context modals receive a deeper, diffused shadow (`0 8px 24px -4px rgba(30, 27, 75, 0.08)`), introducing soft indigo-tinted depth.
- **Layer 3 (Floating Bars & Sheets):** Bottom navigation bars and slide-up modal drawers use backdrop blur filters (`backdrop-blur-md`) combined with translucent white fills (`rgba(255, 255, 255, 0.92)`) to keep underlying content subtly visible while scrolling.

## Shapes

The shape hierarchy is calibrated at roundedness level `2`:

- **Containers & Master Cards:** Styled with `rounded-xl` (`1.5rem` / 24px) for prominent metrics, company switcher headers, and category enclosures.
- **Action Modules & Inputs:** Standardized at `rounded-lg` (`1rem` / 16px) across input boxes, interactive creation blocks, and list items.
- **Badges, Tags, & Switches:** Utilize pill curvature (`9999px`) to immediately signal transient states, tax flags, and payment status indicators.

## Components

### Action Cards (Replacing Flat Grid Icons)
- Rather than bare icons floating on plain grids, actions are presented inside dedicated structural cards.
- Each card incorporates a softly tinted background badge (e.g., primary teal at 8% opacity), a refined 2-tone icon, a crisp title (`label-lg`), and an optional micro-descriptor (`body-sm`) showing recent activity or counts.

### Buttons & Quick Actions
- **Primary Action Button:** Solid `#0D9488` background, white label, full-width or substantial tap area with `rounded-lg`, using subtle active scale depression (`active:scale-[0.98]`).
- **Secondary Action Button:** Deep `#1E1B4B` surface with crisp white text for high-impact secondary workflows (e.g., "Add Customer", "Create Invoice").
- **Ghost/Tertiary:** No background, `#0D9488` text with subtle chevron indicators.

### Micro-Badges & Status Tags
- Pill-shaped (`rounded-full`) tags displaying payment states ("Settled", "Pending", "Overdue", "Draft").
- Employs low-opacity tinted backgrounds paired with deep, saturated text:
  - *Settled:* `#ECFDF5` background with `#047857` text.
  - *Pending:* `#FFFBEB` background with `#B45309` text.
  - *Overdue:* `#FFF1F2` background with `#BE123C` text.

### Inputs & Form Fields
- Surface: `#FFFFFF` encased in a 1px `#E7E5E4` border.
- Focus State: Smooth transition to a 1.5px `#0D9488` stroke with a soft teal ring highlight (`ring-2 ring-teal-500/10`).
- Dedicated prefix support for currency glyphs (`₹`, `$`) styled in muted neutral tones to anchor numerical input.

### Ledger & Record Lists
- Record items feature a structured three-column format: Left icon/avatar with company initial, center customer and invoice details, right value and settlement badge.
- Divided by hairline borders (`#F5F5F4`) with generous vertical tap targets (`min-h-[64px]`).

### Navigation Dock
- Bottom navigation uses an elevated frosted container anchored with clean icon-plus-label targets. Active states are denoted by a solid teal accent dot beneath the active category indicator.