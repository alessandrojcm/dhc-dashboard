<script lang="ts">
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	import * as Card from '$lib/components/ui/card/index.js';
	import * as Resizable from '$lib/components/ui/resizable/index.js';
	import { Skeleton } from '$lib/components/ui/skeleton/index.js';
	import { createQuery } from '@tanstack/svelte-query';

	import {
		ageChart,
		demographicsChart,
		preferredWeaponChart
	} from '$lib/components/ui/analytics-charts.svelte';

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();
	const totalCountQuery = createQuery(() => ({
		queryKey: ['members', 'totalCount'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('id', { count: 'exact', head: true })
				.eq('is_active', true)
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.count ?? 0)
	}));
	const averageAge = createQuery<number>(() => ({
		queryKey: ['members', 'avgAge'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('avg_age:age.avg()')
				.eq('is_active', true)
				.abortSignal(signal)
				.single()
				.throwOnError()
				.then((res) => res.data?.avg_age ?? 0)
	}));
	const genderDistribution = createQuery<
		{ gender: Database['public']['Enums']['gender']; value: number }[]
	>(() => ({
		queryKey: ['members', 'genderDistribution'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('gender,value:gender.count()')
				.eq('is_active', true)
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data ?? [])
	}));
	const genderDistributionData = $derived(genderDistribution.data ?? []);
	const ageDistributionQuery = createQuery<
		{ age: number | null; value: number }[]
	>(() => ({
		queryKey: ['members', 'ageDistribution'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('age,value:age.count()')
				.eq('is_active', true)
				.order('age', { ascending: true })
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data ?? [])
	}));
	const weaponPreferencesDistribution = createQuery<
		{ weapon: string; count: number }[]
	>(() => ({
		queryKey: ['members', 'weaponPreferencesDistribution'],
		queryFn: async ({ signal }) => {
			const { data } = await supabase
				.from('member_management_view')
				.select('preferred_weapon')
				.eq('is_active', true)
				.abortSignal(signal)
				.throwOnError();

			// Process the data in JavaScript
			const weapons = data?.flatMap((d) => d.preferred_weapon) ?? [];
			const counts = weapons.reduce(
				(acc, weapon) => {
					acc[weapon] = (acc[weapon] || 0) + 1;
					return acc;
				},
				{} as Record<string, number>
			);

			return Object.entries(counts)
				.map(([weapon, count]) => ({
					weapon,
					count
				}))
				.sort((a, b) => a.weapon.localeCompare(b.weapon));
		}
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

<h2 class="prose prose-h2 text-lg mb-2">Members analytics</h2>

<div class="flex gap-2">
	<Card.Root class="bg-green-200 w-36">
		<Card.Header>
			<Card.Description class="text-black">Total Members</Card.Description>
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
		<Resizable.PaneGroup direction="horizontal">
			<Resizable.Pane class="min-h-[400px]">
				{@render demographicsChart(genderDistributionData)}
			</Resizable.Pane>
			<Resizable.Handle />
			<Resizable.Pane class="min-h-[400px] pl-4">
				{@render preferredWeaponChart(weaponPreferencesDistribution.data ?? [])}
			</Resizable.Pane>
		</Resizable.PaneGroup>
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{@render ageChart(ageDistribution)}
	</Resizable.Pane>
</Resizable.PaneGroup>
