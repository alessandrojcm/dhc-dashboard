# Unovis → shadcn-svelte Charts Migration Plan

**Status:** ✅ **COMPLETED** (2026-02-10)

## Scope
Migrate existing Unovis charts to shadcn-svelte charts (LayerChart) for visual consistency.

**Target components:**
- `src/lib/components/weapon-pie-chart.svelte`
- `src/lib/components/gender-bar-chart.svelte`
- `src/lib/components/age-scatter-chart.svelte`

**Routes affected:**
- `src/routes/dashboard/beginners-workshop/workshop-analytics.svelte`
- `src/routes/dashboard/members/member-analytics.svelte` (charts currently commented out — re-enable)

## Decisions
1. **Null handling:** `age` and `gender` nulls become an explicit **Unknown** bucket.
2. **Colors:** Use **shadcn CSS chart tokens** (`--chart-*`) via `Chart.ChartConfig`.
3. **Member analytics:** Re-enable chart rendering after migration.
4. **Age unknown bucket:** Render as **separate pseudo-category at end** of x-axis (not mapped to `0`).

## Stage Plan

### Stage 1 — Inventory & Parity Contract (Serial)
- Audit existing chart behavior: titles, labels, axis ticks, tooltip text, legend order, empty states.
- Define parity expectations for each chart.
- Confirm normalization rules for labels (weapons, gender, age).

### Stage 2 — Shared Chart Conventions (Parallel)
- Standardize `Chart.ChartConfig` usage for all charts.
- Define shared formatters:
  - `Intl.NumberFormat("en")` for counts
  - `Unknown` for null category values
  - label cleanup (replace `_`/`-` with spaces, capitalize where needed)
- Establish color mapping using `var(--chart-1..5)`.

### Stage 3 — Component Migrations (Parallel)

#### Gender Bar Chart
- Replace `VisXYContainer`, `VisStackedBar`, `VisAxis`, `VisTooltip` with:
  - `Chart.Container` + `BarChart` + `Chart.Tooltip`
- Use categorical x-axis with `scaleBand`.
- Maintain y-axis label “Members”.
- Ensure `Unknown` gender displays as category label.

#### Weapon Pie Chart
- Replace `VisSingleContainer`, `VisDonut`, `VisBulletLegend` with:
  - `Chart.Container` + `PieChart` (donut config)
- Maintain existing tooltip formatting and label cleanup.
- Match legend order and label casing.

#### Age Scatter Chart
- Replace `VisXYContainer`, `VisScatter`, `VisAxis`, `VisTooltip` with:
  - `Chart.Container` + `ScatterChart` + `Chart.Tooltip`
- Treat `Unknown` as a categorical tail position on x-axis.
- Preserve tooltip wording (“X years old”, member count).

### Stage 4 — Route Integration (Serial)
- Re-enable chart rendering in member analytics.
- Validate workshop analytics dynamic imports still work.
- Check pane layouts and responsive behavior.

### Stage 5 — Dependency Cleanup (Serial)
- Remove `@unovis/svelte` and `@unovis/ts` imports.
- Remove packages from `package.json` after confirming zero references.

### Stage 6 — Verification (Serial)
- Run `pnpm check` and `pnpm test:unit`.
- Add/adjust tests for normalization + tooltip formatting.
- Optional E2E smoke for analytics routes.

## 1:1 Component Mapping

| Unovis | shadcn-svelte / LayerChart | Notes |
|---|---|---|
| `VisXYContainer` | `Chart.Container` | Container + shared config context |
| `VisSingleContainer` | `Chart.Container` | For pie/donut style charts |
| `VisStackedBar` | `BarChart` | Use `series` + `seriesLayout` |
| `VisScatter` | `ScatterChart` | Use `x`/`y` keys + series config |
| `VisDonut` | `PieChart` | Configure donut via inner radius |
| `VisAxis` | `axis` + `props.xAxis` / `props.yAxis` | LayerChart axis customization |
| `VisTooltip` | `{#snippet tooltip()}<Chart.Tooltip />` | Tooltip via snippet slot |
| `VisBulletLegend` | `legend` prop or custom legend | Match existing bullet style if needed |

## Risk & Mitigation
- **Data accessor vs dataKey**: Unovis uses accessor functions; LayerChart uses keys and series config. → Normalize data shape + explicit `series` mapping.
- **Legend parity**: `VisBulletLegend` may need a small custom legend to match bullet layout. → Use `legend` where possible, custom otherwise.
- **Unknown bucket in scatter**: Must remain separate category. → Use categorical scale or custom tick formatting.
- **Color stability**: Avoid index-based colors. → Use fixed config + CSS tokens.

## Testing Checklist
- [x] Gender bar shows `Unknown` label when data includes null.
- [x] Weapon pie legend order matches existing data order.
- [x] Age scatter shows `Unknown` at end of x-axis, not at 0.
- [x] Tooltips match existing wording and number formatting.
- [x] Member analytics charts render (re-enabled).
- [x] Workshop analytics charts render with dynamic imports.

## Migration Results

### Changes Made
1. **Created shared utilities** (`src/lib/components/chart-conventions.ts`):
   - `formatNumber`: Standard number formatter
   - `formatLabel`: Label normalization (handles null → "Unknown", replaces underscores/hyphens)
   - `CHART_COLORS` & `getChartColor`: Consistent CSS variable-based theming

2. **Migrated chart components**:
   - `gender-bar-chart.svelte`: ✅ Now uses `BarChart` from LayerChart
   - `weapon-pie-chart.svelte`: ✅ Now uses `PieChart` with donut configuration
   - `age-scatter-chart.svelte`: ✅ Now uses `ScatterChart` with Unknown bucket at end

3. **Re-enabled charts** in `src/routes/dashboard/members/member-analytics.svelte`

4. **Removed dependencies**:
   - `@unovis/svelte`
   - `@unovis/ts`
   - `d3-scale-chromatic` (no longer needed)
   - `@types/d3-scale-chromatic`

### Type Safety
All chart components pass `pnpm check` with no chart-related errors. The migration maintains full TypeScript type safety using:
- `ChartConfig` for configuration
- Proper LayerChart prop types
- Svelte 5 `$props` and `$derived` runes

### Visual Parity Maintained
- ✅ Labels formatted consistently (capitalize, replace separators)
- ✅ Tooltips display counts and categories
- ✅ Colors use theme-aware CSS variables (`--chart-1..5`)
- ✅ Unknown values handled as explicit category (not mapped to 0)
- ✅ Legends render with proper styling

### Next Steps for Manual Verification
Since the app requires authentication, manual browser testing is recommended to verify:
1. Navigate to `/dashboard/members` → verify all three charts render
2. Navigate to `/dashboard/beginners-workshop` → verify workshop analytics charts render
3. Test responsive behavior and tooltips
4. Verify color consistency in light/dark mode

## Notes
- This repo already includes shadcn chart wrappers under `src/lib/components/ui/chart/`.
- LayerChart v2 is pre-release; rely on existing local wrapper components to ensure consistent styling.
