<script lang="ts" module>
	import { ScatterChart, Tooltip, BarChart, PieChart, Svg, Axis, Points } from 'layerchart';
	import { schemeTableau10 } from 'd3-scale-chromatic';

	export { ageChart, demographicsChart, preferredWeaponChart };
</script>

{#snippet ageChart(ageDistribution: [{ age: string; value: number }])}
	<h3 class="mb-4">Age groups</h3>
	<div class="h-[300px]">
		<ScatterChart
			series={ageDistribution}
			x="age"
			y="value"
			yDomain={[0, null]}
			yNice
			c="value"
			cDomain={[50, 90]}
			cRange={schemeTableau10}
			padding={{ left: 16, bottom: 24 }}
		>
			<Svg>
				<Axis placement="left" grid rule />
				<Axis placement="bottom" rule grid />
				<Points class="stroke-surface-content/50" />
			</Svg>

			<Tooltip.Root let:data>
				<Tooltip.Header>
					{data.seriesKey} years old
				</Tooltip.Header>
				<Tooltip.List>
					<Tooltip.Item label="Members" value={data.value} />
				</Tooltip.List>
			</Tooltip.Root>
		</ScatterChart>
	</div>
{/snippet}

{#snippet demographicsChart(genderDistributionData: [{ gender: string; value: number }])}
	<h3>Gender demographics</h3>
	<div class="h-[300px] mt-4">
		<BarChart
			data={genderDistributionData}
			x="gender"
			y="value"
			yDomain={[0, null]}
			cRange={schemeTableau10}
			legend
		>
			<svelte:fragment slot="tooltip" let:y let:classes let:x>
				<Tooltip.Root clas={classes} let:data>
					<Tooltip.Header class="capitalize">
						{x(data)}
					</Tooltip.Header>
					<Tooltip.List>
						<Tooltip.Item label="Members" value={y(data)} />
					</Tooltip.List>
				</Tooltip.Root>
			</svelte:fragment>
		</BarChart>
	</div>
{/snippet}

{#snippet preferredWeaponChart(
	preferredWeaponDistributionData: [{ weapon: string; count: number }]
)}
	<h3>Preferred weapon</h3>
	<div class="h-[300px] mt-4">
		<PieChart
			data={preferredWeaponDistributionData}
			key="weapon"
			value="count"
			cRange={schemeTableau10}
			legend
			label={(d: { weapon: string }) => d.weapon.replaceAll(/[_-]/g, ' ')}
		>
			<svelte:fragment slot="tooltip" let:y let:classes let:x>
				<Tooltip.Root clas={classes} let:data>
					<Tooltip.Header class="capitalize">
						{x(data)}
					</Tooltip.Header>
					<Tooltip.List>
						<Tooltip.Item
							class="capitalize"
							label="Weapon"
							value={y(data).replaceAll(/[_-]/g, ' ')}
						/>
					</Tooltip.List>
				</Tooltip.Root>
			</svelte:fragment>
		</PieChart>
	</div>
{/snippet}
