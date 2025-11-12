<script lang="ts">
	import { VisXYContainer, VisStackedBar, VisAxis, VisTooltip } from '@unovis/svelte';
	import { StackedBar } from '@unovis/ts';
	import { schemeTableau10 } from 'd3-scale-chromatic';

	type GenderDistribution = { gender: string; value: number };

	// Use Svelte 5 props syntax
	const { genderDistributionData = [] }: { genderDistributionData?: Array<GenderDistribution> } =
		$props();

	// Format number for display
	const formatNumber = Intl.NumberFormat('en').format;

	// Bar chart props
	// Map gender strings to indices for x-axis positioning
	const genderIndices = new Map(genderDistributionData.map((item, index) => [item.gender, index]));

	const x = (d: GenderDistribution) => genderIndices.get(d.gender) || 0;
	const y = (d: GenderDistribution) => d.value;
	const color = (d: GenderDistribution) => {
		// Use the index in the data array to determine color
		const index = genderDistributionData.findIndex((item) => item.gender === d.gender);
		return schemeTableau10[index % schemeTableau10.length];
	};

	// Tooltip configuration
	const triggers = {
		[StackedBar.selectors.bar]: (d: GenderDistribution) => `
			<div>
				<div style="font-weight: bold; margin-bottom: 4px; text-transform: capitalize;">${d.gender}</div>
				<div>Members: ${formatNumber(d.value)}</div>
			</div>
		`
	};
</script>

<h3>Gender demographics</h3>
<div class="h-[300px] mt-4">
	<VisXYContainer data={genderDistributionData} height={300}>
		<VisStackedBar {x} y={[(d: GenderDistribution) => d.value]} {color} cursor="pointer" />
		<VisAxis
			type="x"
			label="Gender"
			gridVisible={false}
			tickFormat={(value) => {
				// Convert numeric indices back to gender labels
				for (const [gender, index] of genderIndices.entries()) {
					if (index === value) return gender;
				}
				return '';
			}}
		/>
		<VisAxis type="y" label="Members" gridVisible={true} domain={[0, null]} nice={true} />
		<VisTooltip {triggers} />
	</VisXYContainer>
</div>
