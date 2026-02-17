<script lang="ts">
import { scaleBand } from "d3-scale";
import { BarChart } from "layerchart";
import * as Chart from "$lib/components/ui/chart/index.js";
import {
	formatLabel,
	formatNumber,
	getChartColor,
} from "./chart-conventions.js";

interface GenderDistribution {
	gender: string;
	value: number;
}

// Accept raw data with null gender values

const {
	genderDistributionData = [],
}: { genderDistributionData?: Array<GenderDistribution> } = $props();

// Normalize data: convert null gender to "Unknown" and format labels
const normalizedData = $derived(
	genderDistributionData.map((item, index) => ({
		gender: formatLabel(item.gender),
		value: item.value,
		color: getChartColor(index),
	})),
);

const chartConfig = $derived.by(() => {
	const config: Record<string, { label: string; color: string }> = {};
	normalizedData.forEach((item, index) => {
		const key = `gender_${index}`;
		config[key] = {
			label: item.gender,
			color: item.color,
		};
	});
	return config satisfies Chart.ChartConfig;
});
</script>

<h3>Gender demographics</h3>
<div class="h-[300px] mt-4">
	<Chart.Container config={chartConfig} class="h-full w-full">
		<BarChart
			data={normalizedData}
			x="gender"
			y="value"
			c="color"
			xScale={scaleBand().padding(0.25)}
			axis={true}
			grid={true}
			series={[
				{
					key: "value",
					label: "Members",
					color: "hsl(var(--chart-1))",
				},
			]}
			props={{
				xAxis: {
					format: (d: string) => d,
				},
				yAxis: {
					format: (d: number) => formatNumber(d),
				},
			}}
		>
			{#snippet tooltip()}
				<Chart.Tooltip />
			{/snippet}
		</BarChart>
	</Chart.Container>
</div>
