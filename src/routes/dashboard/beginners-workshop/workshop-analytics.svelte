<script lang="ts">
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	import * as Card from '$lib/components/ui/card/index.js';
	import * as Resizable from '$lib/components/ui/resizable/index.js';
	import { Skeleton } from '$lib/components/ui/skeleton/index.js';
	import { createQuery } from '@tanstack/svelte-query';
	import { ageChart, demographicsChart } from '$lib/components/ui/analytics-charts.svelte';

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();
	const totalCountQuery = createQuery<number>(() => ({
		queryKey: ['waitlist', 'totalCount'],
		queryFn: async ({ signal }) =>
			supabase
				.from('waitlist_management_view')
				.select('id', { count: 'exact', head: true })
				.neq('status', 'completed')
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
				.neq('status', 'completed')
				.abortSignal(signal)
				.single()
				.throwOnError()
				.then((res) => res.data?.avg_age)
	}));
	const genderDistribution = createQuery<{
		gender: Database['public']['Enums']['gender'];
		count: number;
	}>(() => ({
		queryKey: ['waitlist', 'genderDistribution'],
		queryFn: async ({ signal }) =>
			supabase
				.from('user_profiles')
				.select('gender,value:gender.count()')
				.is('is_active', false)
				.not('waitlist_id', 'is', null)
				.is('supabase_user_id', null)
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data)
	}));
	const genderDistributionData = $derived(genderDistribution.data ?? []);
	const ageDistributionQuery = createQuery<
		[
			{
				age: string;
				count: number;
			}
		]
	>(() => ({
		queryKey: ['waitlist', 'ageDistribution'],
		queryFn: async ({ signal }) =>
			supabase
				.from('waitlist_management_view')
				.select('age,value:age.count()')
				.neq('status', 'completed')
				.order('age', { ascending: true })
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data)
	}));
	const ageDistribution = $derived.by(() => {
		const result = ageDistributionQuery.data ?? [];
		const distribution = new Map();
		result.forEach((row) => {
			if (!distribution.has(row.age)) {
				distribution.set(row.age, [row]);
			} else {
				distribution.set(row.age, [...distribution.get(row.age), row]);
			}
		});
		return Array.from(distribution.entries()).map(([age, rows], i) => ({
			key: age,
			data: rows,
			color: 'hsl(var(--color-primary))'
		}));
	});
</script>

<h2 class="prose prose-h2 text-lg mb-2">Workshop analytics</h2>

<div class="flex gap-2">
	<Card.Root class="bg-green-200 w-36">
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
	<Card.Root class="bg-yellow-200 w-36">
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
		{@render demographicsChart(genderDistributionData)}
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{@render ageChart(ageDistribution)}
	</Resizable.Pane>
</Resizable.PaneGroup>
