<script lang="ts">
import { ScatterChart } from "layerchart";
import * as Chart from "$lib/components/ui/chart/index.js";
import { formatNumber, getChartColor } from "./chart-conventions.js";

type AgeValue = string | number | null;
type AgeDistribution = { age: AgeValue; value: number };

const { ageDistribution }: { ageDistribution: Array<AgeDistribution> } =
	$props();

// Process data: separate numeric ages from unknown, then combine with Unknown at end
const processedData = $derived.by(() => {
	const numericAges: Array<{
		age: number;
		value: number;
		label: string;
		color: string;
	}> = [];
	let unknownValue = 0;

	ageDistribution.forEach((item) => {
		if (item.age === null) {
			unknownValue += item.value;
		} else {
			const ageNum = typeof item.age === "string" ? Number(item.age) : item.age;
			numericAges.push({
				age: ageNum,
				value: item.value,
				label: `${ageNum} years`,
				color: getChartColor(0),
			});
		}
	});

	// Sort numeric ages
	numericAges.sort((a, b) => a.age - b.age);

	// Add Unknown at the end if there are any unknown values
	const result = [...numericAges];
	if (unknownValue > 0) {
		// Use a position beyond the max age for Unknown
		const maxAge =
			numericAges.length > 0 ? numericAges[numericAges.length - 1].age : 0;
		result.push({
			age: maxAge + 10, // Position Unknown 10 units beyond max age
			value: unknownValue,
			label: "Unknown",
			color: getChartColor(1),
		});
	}

	return result;
});

// Build chart config
const chartConfig = $derived({
	primary: {
		label: "Age",
		color: "hsl(var(--chart-1))",
	},
} satisfies Chart.ChartConfig);

// Check if we have unknown data
const hasUnknown = $derived(
	ageDistribution.some((item) => item.age === null && item.value > 0),
);

// Get max age for x-axis domain calculation
const maxAge = $derived(
	processedData.length > 0 ? processedData[processedData.length - 1].age : 100,
);
</script>

<h3 class="mb-4">Age groups</h3>
<div class="h-[300px]">
	<Chart.Container config={chartConfig} class="h-full w-full">
		<ScatterChart
			data={processedData}
			x="age"
			y="value"
			r="value"
			c="color"
			rRange={[4, 14]}
			axis={true}
			grid={true}
			xDomain={[0, maxAge + 5]}
			yDomain={[0, null]}
			props={{
				xAxis: {
					format: (d: number) => {
						// Check if this is the unknown position (10 units beyond max age)
						const numericAges = processedData.filter((p) => p.label !== "Unknown");
						const maxRealAge =
							numericAges.length > 0 ? numericAges[numericAges.length - 1].age : 0;
						if (hasUnknown && d > maxRealAge + 5) {
							return "Unknown";
						}
						return String(d);
					},
				},
				yAxis: {
					format: (d: number) => formatNumber(d),
				},
			}}
		>
			{#snippet tooltip()}
				<Chart.Tooltip />
			{/snippet}
		</ScatterChart>
	</Chart.Container>
</div>
