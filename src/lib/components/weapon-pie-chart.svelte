<script lang="ts">
import { VisBulletLegend, VisDonut, VisSingleContainer } from "@unovis/svelte";
import { schemeTableau10 } from "d3-scale-chromatic";

type WeaponDistribution = { weapon: string; count: number };

// Use Svelte 5 props syntax
const {
	weaponDistributionData = [],
}: { weaponDistributionData?: Array<WeaponDistribution> } = $props();

// Format number for display
const formatNumber = Intl.NumberFormat("en").format;

// Generate legend items from the data
const legendItems = $derived(
	weaponDistributionData.map((item) => ({
		name:
			item.weapon.charAt(0).toUpperCase() +
			item.weapon.slice(1).replaceAll(/[_-]/g, " "),
		color:
			schemeTableau10[
				weaponDistributionData.indexOf(item) % schemeTableau10.length
			],
	})),
);

// Configure tooltip content
const tooltipConfig = {
	content: (d: WeaponDistribution) => `
			<div>
				<div style="font-weight: bold; margin-bottom: 4px; text-transform: capitalize;">${d.weapon.replaceAll(/[_-]/g, " ")}</div>
				<div>Count: ${formatNumber(d.count)}</div>
			</div>
		`,
};
</script>

<h3>Preferred weapon</h3>
<div class="mt-2">
	<VisBulletLegend items={legendItems} />
</div>
<div class="h-[300px] mt-4">
	<VisSingleContainer data={weaponDistributionData} height={250}>
		<VisDonut
			value={(d: WeaponDistribution) => d.count}
			color={(d: WeaponDistribution, i: number) => schemeTableau10[i % schemeTableau10.length]}
			showEmptySegments={false}
			padAngle={0.01}
			arcWidth={60}
			tooltip={tooltipConfig}
		/>
	</VisSingleContainer>
</div>
