<script lang="ts">
	import { Scale, Scatter } from '@unovis/ts';
	import { VisXYContainer, VisScatter, VisAxis, VisTooltip } from '@unovis/svelte';
	import { schemeTableau10 } from 'd3-scale-chromatic';

	type AgeValue = string | number | null;
	type AgeDistribution = { age: AgeValue; value: number };
	// Accept different age data formats from different sources
	const { ageDistribution }: { ageDistribution: Array<{ age: AgeValue; value: number }> } =
		$props();

	// Scatter props
	const x = (d: { age: AgeValue; value: number }) => {
		// Handle different age formats
		if (d.age === null) return 0;
		return typeof d.age === 'string' ? Number(d.age) : d.age;
	};
	const y = (d: { age: AgeValue; value: number }) => d.value;
	const size = (d: AgeDistribution) => d.value; // Fixed size for all points

	// Create a color scale similar to the original
	const colorScale = Scale.scaleOrdinal(schemeTableau10).domain(
		[
			...new Set(
				ageDistribution
					.map((a) => a.age)
					.filter((age) => age !== null)
					.map((age) => String(age))
			)
		].sort()
	);
	const color = (d: AgeDistribution) => colorScale(d.age?.toString() ?? '');

	// Tooltip configuration
	const triggers = {
		[Scatter.selectors.point]: (d: AgeDistribution) => `
      ${d.age} years old<br/>Number of members: ${d.value.toLocaleString()}
    `
	};
</script>

<h3 class="mb-4">Age groups</h3>
<div class="h-[300px]">
	<VisXYContainer data={ageDistribution} height={300}>
		<VisScatter {x} {y} {color} {size} cursor="pointer" sizeRange={[10, 50]} />
		<VisAxis type="x" label="Age" gridVisible={true} />
		<VisAxis type="y" label="Members" gridVisible={true} domain={[0, null]} nice={true} />
		<VisTooltip {triggers} />
	</VisXYContainer>
</div>
