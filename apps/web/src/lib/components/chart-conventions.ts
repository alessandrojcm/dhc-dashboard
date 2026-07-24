/**
 * Shared chart conventions and utilities for consistent formatting across all charts
 */

/**
 * Standard number formatter for displaying counts and values
 */
export const formatNumber = Intl.NumberFormat("en").format;

/**
 * Format labels by replacing underscores/hyphens with spaces and capitalizing
 */
export function formatLabel(label: string | null | undefined): string {
	if (label === null || label === undefined) return "Unknown";

	return (
		label.charAt(0).toUpperCase() + label.slice(1).replaceAll(/[_-]/g, " ")
	);
}

/**
 * CSS chart color tokens for theming
 * These map to the --chart-* CSS variables defined in the theme
 */
export const CHART_COLORS = [
	"hsl(var(--chart-1))",
	"hsl(var(--chart-2))",
	"hsl(var(--chart-3))",
	"hsl(var(--chart-4))",
	"hsl(var(--chart-5))",
] as const;

/**
 * Get a chart color by index, wrapping around if needed
 */
export function getChartColor(index: number): string {
	return CHART_COLORS[index % CHART_COLORS.length];
}
