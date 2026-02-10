<script lang="ts">
import { PieChart } from "layerchart";
import * as Chart from "$lib/components/ui/chart/index.js";
import {
	formatLabel,
	formatNumber,
	getChartColor,
} from "./chart-conventions.js";

type WeaponDistribution = { weapon: string; count: number };

const {
	weaponDistributionData = [],
}: { weaponDistributionData?: Array<WeaponDistribution> } = $props();

// Normalize data: format weapon labels and assign colors
const normalizedData = $derived(
	weaponDistributionData.map((item, index) => ({
		weapon: formatLabel(item.weapon),
		count: item.count,
		color: getChartColor(index),
	})),
);

// Build chart config from data for theming
const chartConfig = $derived.by(() => {
	const config: Record<string, { label: string; color: string }> = {};
	normalizedData.forEach((item, index) => {
		const key = item.weapon.toLowerCase().replace(/\s+/g, "_");
		config[key] = {
			label: item.weapon,
			color: item.color,
		};
	});
	return config satisfies Chart.ChartConfig;
});
</script>

<h3>Preferred weapon</h3>
<div class="h-[300px] mt-4">
	<Chart.Container config={chartConfig} class="h-full w-full">
		<PieChart
			data={normalizedData}
			key="weapon"
			value="count"
			c="color"
			innerRadius={60}
			padAngle={0.01}
			cornerRadius={4}
			legend
			props={{
				pie: {
					motion: "tween",
				},
				legend: {
					placement: "top",
					orientation: "horizontal",
				},
			}}
		>
			{#snippet tooltip()}
				<Chart.Tooltip />
			{/snippet}
		</PieChart>
	</Chart.Container>
</div>
