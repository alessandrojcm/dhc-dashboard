<script lang="ts">
import { createQuery } from "@tanstack/svelte-query";
import { onMount } from "svelte";
import { browser } from "$app/environment";
import * as Card from "$lib/components/ui/card/index.js";
import * as Resizable from "$lib/components/ui/resizable/index.js";
import { Skeleton } from "$lib/components/ui/skeleton/index.js";
import { getMembersAnalytics } from "./data.remote";

let WeaponPieChart:
	| typeof import("$lib/components/weapon-pie-chart.svelte").default
	| null = $state(null);
let GenderBarChart:
	| typeof import("$lib/components/gender-bar-chart.svelte").default
	| null = $state(null);
let AgeScatterChart:
	| typeof import("$lib/components/age-scatter-chart.svelte").default
	| null = $state(null);

onMount(async () => {
	if (browser) {
		WeaponPieChart = (await import("$lib/components/weapon-pie-chart.svelte"))
			.default;
		GenderBarChart = (await import("$lib/components/gender-bar-chart.svelte"))
			.default;
		AgeScatterChart = (await import("$lib/components/age-scatter-chart.svelte"))
			.default;
	}
});

// Single Phoenix read (`GET /api/members/analytics`) replaces the five
// browser-side PostgREST aggregates over `member_management_view`.
const analyticsQuery = createQuery(() => ({
	queryKey: ["members", "analytics"],
	queryFn: () => getMembersAnalytics(),
}));

const totalCount = $derived(analyticsQuery.data?.totalCount ?? 0);
const averageAge = $derived(analyticsQuery.data?.averageAge ?? 0);
const genderDistributionData = $derived.by(() => {
	if (!analyticsQuery.data) return [];
	return analyticsQuery.data.genderDistribution.map((row) => ({
		gender: row.gender,
		value: row.value,
	}));
});
const ageDistributionData = $derived.by(() => {
	if (!analyticsQuery.data) return [];
	return analyticsQuery.data.ageDistribution.map((row) => ({
		age: row.age,
		value: row.value,
	}));
});
const weaponDistributionData = $derived.by(() => {
	if (!analyticsQuery.data) return [];
	// Weapon items use the `{ weapon, value }` shape (renamed from `count`).
	return analyticsQuery.data.weaponDistribution.map((row) => ({
		weapon: row.weapon,
		value: row.value,
	}));
});
</script>

<h2 class="prose prose-h2 text-lg mb-2">Members analytics</h2>

<div class="flex flex-wrap justify-center md:justify-start gap-4">
	<Card.Root class="bg-green-200 w-36 text-center md:text-left">
		<Card.Header>
			<Card.Description class="text-black">Total Members</Card.Description>
		</Card.Header>
		<Card.Content>
			{#if analyticsQuery.isLoading}
				<Skeleton class="h-[2.5rem] w-[5rem]" />
			{:else}
				<p class="text-black text-4xl">
					{totalCount}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
	<Card.Root class="bg-yellow-200 w-36 text-center md:text-left">
		<Card.Header>
			<Card.Description class="text-black">Average age</Card.Description>
		</Card.Header>
		<Card.Content>
			{#if analyticsQuery.isLoading}
				<Skeleton class="h-[2.5rem] w-[5rem]" />
			{:else}
				<p class="text-black text-4xl">
					{averageAge.toLocaleString('en-UK', { maximumFractionDigits: 2 })}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
</div>

<Resizable.PaneGroup direction="vertical" class="mt-2">
	<!-- Gender Demographics Card -->
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		<h3 class="text-lg font-medium mb-4">Gender Demographics</h3>
		{#if GenderBarChart && genderDistributionData && genderDistributionData.length > 0}
			<GenderBarChart {genderDistributionData} />
		{/if}
	</Resizable.Pane>

	<!-- Separator between Gender and Weapon cards -->
	<Resizable.Handle />

	<!-- Preferred Weapons Card -->
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		<h3 class="text-lg font-medium mb-4">Preferred Weapons</h3>
		{#if WeaponPieChart && weaponDistributionData}
			<WeaponPieChart {weaponDistributionData} />
		{/if}
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if AgeScatterChart && ageDistributionData}
			<AgeScatterChart ageDistribution={ageDistributionData} />
		{/if}
	</Resizable.Pane>
</Resizable.PaneGroup>