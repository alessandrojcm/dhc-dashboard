<script lang="ts">
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	import * as Card from '$lib/components/ui/card/index.js';
	import * as Resizable from '$lib/components/ui/resizable/index.js';
	import { Skeleton } from '$lib/components/ui/skeleton/index.js';
	import { createQuery } from '@tanstack/svelte-query';
	import { browser } from '$app/environment';
	import { onMount } from 'svelte';
	import { Component } from 'lucide-svelte';

	let GenderBarChart: typeof import('$lib/components/gender-bar-chart.svelte').default | null =
		$state(null);
	let AgeScatterChart: typeof import('$lib/components/age-scatter-chart.svelte').default | null =
		$state(null);

	onMount(async () => {
		if (browser) {
			GenderBarChart = (await import('$lib/components/gender-bar-chart.svelte')).default;
			AgeScatterChart = (await import('$lib/components/age-scatter-chart.svelte')).default;
		}
	});

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();
	const totalCountQuery = createQuery<number>(() => ({
		queryKey: ['waitlist', 'totalCount'],
		queryFn: async ({ signal }) =>
			supabase
				.from('waitlist_management_view')
				.select('id', { count: 'exact', head: true })
				.neq('status', 'joined')
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.count ?? 0)
	}));
	const averageAge = createQuery<number>(() => ({
		queryKey: ['waitlist', 'avgAge'],
		queryFn: async ({ signal }) =>
			supabase
				.from('waitlist_management_view')
				.select('avg_age:age.avg()')
				.neq('status', 'joined')
				.abortSignal(signal)
				.single()
				.throwOnError()
				.then((res) => res.data?.avg_age ?? 0)
	}));
	// Define the type for gender distribution data
	type GenderDistributionItem = { gender: string; value: number };

	const genderDistribution = createQuery(() => ({
		queryKey: ['waitlist', 'genderDistribution'],
		queryFn: async ({ signal }) =>
			supabase
				.from('user_profiles')
				.select('gender,count:gender.count()')
				.is('is_active', false)
				.not('waitlist_id', 'is', null)
				.is('supabase_user_id', null)
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data || [])
	}));

	// Transform the gender distribution data to match the expected format for GenderBarChart
	const genderDistributionData = $derived.by(() => {
		if (!genderDistribution.data) return [];
		return genderDistribution.data.map((row) => ({
			gender: row.gender,
			value: row.count
		})) as GenderDistributionItem[];
	});
	const ageDistributionQuery = createQuery(() => ({
		queryKey: ['waitlist', 'ageDistribution'],
		queryFn: async ({ signal }) =>
			supabase
				.from('waitlist_management_view')
				.select('age,value:age.count()')
				.neq('status', 'joined')
				.order('age', { ascending: true })
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data)
	}));
	const ageDistribution = $derived.by(() => {
		const result = ageDistributionQuery.data ?? [];
		// Transform the data to match the expected format for AgeScatterChart
		return result.map((row) => ({
			age: row.age,
			value: row.value
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
			{#if totalCountQuery.isLoading}
				<Skeleton class="h-[2.5rem] w-[5rem]" />
			{:else}
				<p class="text-black text-4xl">
					{totalCountQuery.data ?? 0}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
	<Card.Root class="bg-yellow-200 w-36 text-center md:text-left">
		<Card.Header>
			<Card.Description class="text-black">Average age</Card.Description>
		</Card.Header>
		<Card.Content>
			{#if averageAge.isLoading}
				<Skeleton class="h-[2.5rem] w-[5rem]" />
			{:else}
				<p class="text-black text-4xl">
					{(averageAge.data ?? 0).toLocaleString('en-UK', { maximumFractionDigits: 2 })}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
</div>

<Resizable.PaneGroup direction="vertical" class="mt-2">
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if GenderBarChart && genderDistributionData && genderDistributionData.length > 0}
			<GenderBarChart {genderDistributionData} />
		{/if}
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if AgeScatterChart && ageDistribution && ageDistribution.length > 0}
			<AgeScatterChart {ageDistribution} />
		{/if}
	</Resizable.Pane>
</Resizable.PaneGroup>
