import { type Component, getContext, setContext } from "svelte";
import * as v from "valibot";

export const THEMES = { light: "", dark: ".dark" } as const;

export type ChartConfig = {
	[k in string]: {
		label?: string;
		icon?: Component;
	} & (
		| { color?: string; theme?: never }
		| { color?: never; theme: Record<keyof typeof THEMES, string> }
	);
};

type TooltipValue = string | number | null;

export type TooltipPayload = {
	key: string;
	name?: string;
	label?: string;
	value?: TooltipValue;
	payload?: Record<string, TooltipValue>;
	color?: string;
};

const StringSchema = v.string();

function parsedString(value: TooltipValue | undefined): string | undefined {
	const result = v.safeParse(StringSchema, value);
	return result.success ? result.output : undefined;
}

// Helper to extract item config from a payload.
export function getPayloadConfigFromPayload(
	config: ChartConfig,
	payload: TooltipPayload,
	key: string,
) {
	let configLabelKey: string = key;

	if (payload.key === key) {
		configLabelKey = payload.key;
	} else if (payload.name === key) {
		configLabelKey = payload.name;
	} else {
		const directValue = new Map<string, TooltipValue | undefined>([
			["key", payload.key],
			["name", payload.name],
			["label", payload.label],
			["value", payload.value],
		]).get(key);
		configLabelKey =
			parsedString(directValue) ??
			parsedString(payload.payload?.[key]) ??
			configLabelKey;
	}

	return config[configLabelKey] ?? config[key];
}

type ChartContextValue = {
	config: ChartConfig;
};

const chartContextKey = Symbol("chart-context");

export function setChartContext(value: ChartContextValue) {
	return setContext(chartContextKey, value);
}

export function useChart() {
	return getContext<ChartContextValue>(chartContextKey);
}
