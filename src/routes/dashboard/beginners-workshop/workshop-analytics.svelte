<script lang="ts">
import * as Card from "$lib/components/ui/card/index.js";
import * as Resizable from "$lib/components/ui/resizable/index.js";
import { Skeleton } from "$lib/components/ui/skeleton/index.js";
import { createQuery } from "@tanstack/svelte-query";
import { browser } from "$app/environment";
import { onMount } from "svelte";
import { getWaitlistAnalytics } from "./admin.remote";

let GenderBarChart:
	| typeof import("$lib/components/gender-bar-chart.svelte").default
	| null = $state(null);
let AgeScatterChart:
	| typeof import("$lib/components/age-scatter-chart.svelte").default
	| null = $state(null);

onMount(async () => {
	if (browser) {
		GenderBarChart = (await import("$lib/components/gender-bar-chart.svelte"))
			.default;
		AgeScatterChart = (await import("$lib/components/age-scatter-chart.svelte"))
			.default;
	}
});

type GenderDistributionItem = { gender: string; value: number };

const analyticsQuery = createQuery(() => ({
	queryKey: ["waitlist", "analytics"],
	queryFn: () => getWaitlistAnalytics(),
}));

const genderDistributionData = $derived.by(() => {
	if (!analyticsQuery.data) return [];
	return analyticsQuery.data.genderDistribution.map((row) => ({
		gender: row.gender,
		value: row.value,
	})) as GenderDistributionItem[];
});
const ageDistribution = $derived.by(() => {
	const result = analyticsQuery.data?.ageDistribution ?? [];
	return result.map((row) => ({
		age: row.age,
		value: row.value,
	}));
});
</script>

<h2 class="prose prose-h2 text-lg mb-2">Workshop analytics</h2>

<div class="flex flex-wrap justify-center md:justify-start gap-4">
	<Card.Root class="bg-green-200 w-36 text-center md:text-left">
		<Card.Header>
			<Card.Description class="text-black">Total waitlist</Card.Description>
		</Card.Header>
		<Card.Content>
			{#if analyticsQuery.isLoading}
				<Skeleton class="h-[2.5rem] w-[5rem]" />
			{:else}
				<p class="text-black text-4xl">
					{analyticsQuery.data?.totalCount ?? 0}
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
					{(analyticsQuery.data?.averageAge ?? 0).toLocaleString('en-UK', { maximumFractionDigits: 2 })}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
</div>

<Resizable.PaneGroup direction="vertical" class="mt-2">
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if GenderBarChart && genderDistributionData}
			<GenderBarChart {genderDistributionData} />
		{/if}
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if AgeScatterChart && ageDistribution}
			<AgeScatterChart {ageDistribution} />
		{/if}
	</Resizable.Pane>
</Resizable.PaneGroup>
