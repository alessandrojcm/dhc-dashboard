<script lang="ts">
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	import * as Card from '$lib/components/ui/card/index.js';
	import * as Resizable from '$lib/components/ui/resizable/index.js';
	import { Skeleton } from '$lib/components/ui/skeleton/index.js';
	import { createQuery } from '@tanstack/svelte-query';
	import { onMount } from 'svelte';
	import { browser } from '$app/environment';

	let WeaponPieChart: typeof import('$lib/components/weapon-pie-chart.svelte').default | null =
		$state(null);
	let GenderBarChart: typeof import('$lib/components/gender-bar-chart.svelte').default | null =
		$state(null);
	let AgeScatterChart: typeof import('$lib/components/age-scatter-chart.svelte').default | null =
		$state(null);

	onMount(async () => {
		if (browser) {
			WeaponPieChart = (await import('$lib/components/weapon-pie-chart.svelte')).default;
			GenderBarChart = (await import('$lib/components/gender-bar-chart.svelte')).default;
			AgeScatterChart = (await import('$lib/components/age-scatter-chart.svelte')).default;
		}
	});

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
				.then((r) => r.count ?? 0) as Promise<number>
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
				.then((res) => res.data?.avg_age ?? 0) as Promise<number>
	}));

	const genderDistribution = createQuery(() => ({
		queryKey: ['members', 'genderDistribution'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('gender,count:gender.count()')
				.eq('is_active', true)
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data ?? [])
	}));
	const ageDistributionQuery = createQuery(() => ({
		queryKey: ['members', 'ageDistribution'],
		queryFn: ({ signal }) =>
			supabase
				.from('member_management_view')
				.select('age,value:age.count()')
				.eq('is_active', true)
				.order('age', { ascending: true })
				.abortSignal(signal)
				.throwOnError()
				.then((r) => r.data ?? []) as Promise<
				{
					age: number | null;
					value: number;
				}[]
			>
	}));
	const weaponPreferencesDistribution = createQuery<{ weapon: string; count: number }[]>(() => ({
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
					if (weapon !== null) {
						acc[weapon] = (acc[weapon] || 0) + 1;
					}
					return acc;
				},
				{} as Record<string, number>
			);

			return Object.entries(counts)
				.map(([weapon, count]) => ({
					weapon,
					count
				}))
				.sort((a, b) => a.weapon.localeCompare(b.weapon)) as Array<{
				weapon: string;
				count: number;
			}>;
		}
	}));

	const genderDistributionData = $derived.by(() => {
		return genderDistribution.data
			? genderDistribution.data.map((row) => ({ gender: row.gender, value: row.count }))
			: [];
	});

	const ageDistributionData = $derived.by(() => {
		return ageDistributionQuery.data ?? [];
	});

	const weaponPreferencesDistributionData = $derived.by(() => {
		return weaponPreferencesDistribution.data ?? [];
	});
</script>

<h2 class="prose prose-h2 text-lg mb-2">Members analytics</h2>

<div class="flex flex-wrap justify-center md:justify-start gap-4">
	<Card.Root class="bg-green-200 w-36 text-center md:text-left">
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
	<!-- Gender Demographics Card -->
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		<h3 class="text-lg font-medium mb-4">Gender Demographics</h3>
		{#if GenderBarChart && genderDistributionData && genderDistributionData.length > 0}
			<GenderBarChart
				genderDistributionData={genderDistributionData}
			/>
		{/if}
	</Resizable.Pane>

	<!-- Separator between Gender and Weapon cards -->
	<Resizable.Handle />

	<!-- Preferred Weapons Card -->
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		<h3 class="text-lg font-medium mb-4">Preferred Weapons</h3>
		{#if WeaponPieChart && weaponPreferencesDistributionData}
			<WeaponPieChart weaponDistributionData={weaponPreferencesDistributionData} />
		{/if}
	</Resizable.Pane>
	<Resizable.Handle />
	<Resizable.Pane class="min-h-[400px] p-4 border rounded">
		{#if AgeScatterChart && ageDistributionData}
			<AgeScatterChart ageDistribution={ageDistributionData} />
		{/if}
	</Resizable.Pane>
</Resizable.PaneGroup>
