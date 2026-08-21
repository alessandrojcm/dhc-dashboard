<script lang="ts">
import { membersAnalyticsOptions } from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import { ChartColumn, CalendarDays, Swords, Users } from "@lucide/svelte";
import * as Card from "$lib/components/ui/card/index.js";
import { Skeleton } from "$lib/components/ui/skeleton/index.js";
import {
	formatLabel,
	formatNumber,
} from "$lib/components/chart-conventions.js";

const ageRanges = [
	{ label: "Under 18", shortLabel: "<18", min: 0, max: 17 },
	{ label: "18 to 24", shortLabel: "18–24", min: 18, max: 24 },
	{ label: "25 to 34", shortLabel: "25–34", min: 25, max: 34 },
	{ label: "35 to 44", shortLabel: "35–44", min: 35, max: 44 },
	{ label: "45 to 54", shortLabel: "45–54", min: 45, max: 54 },
	{ label: "55 to 64", shortLabel: "55–64", min: 55, max: 64 },
	{ label: "65 and over", shortLabel: "65+", min: 65, max: Infinity },
] as const;

const analyticsQuery = createQuery(() => membersAnalyticsOptions());

const analytics = $derived(analyticsQuery.data?.data);
const totalCount = $derived(analytics?.totalCount ?? 0);
const averageAge = $derived(analytics?.averageAge ?? 0);

const ageBuckets = $derived.by(() => {
	const buckets = ageRanges.map((range) => ({ ...range, value: 0 }));

	for (const item of analytics?.ageDistribution ?? []) {
		const bucket = buckets.find(
			(range) => item.age >= range.min && item.age <= range.max,
		);
		if (bucket) bucket.value += item.value;
	}

	const maximum = Math.max(...buckets.map((bucket) => bucket.value), 1);
	return buckets.map((bucket) => ({
		...bucket,
		percentageOfMaximum: (bucket.value / maximum) * 100,
	}));
});

const knownAgeCount = $derived(
	ageBuckets.reduce((total, bucket) => total + bucket.value, 0),
);
const largestAgeGroup = $derived(
	ageBuckets.reduce((largest, bucket) =>
		bucket.value > largest.value ? bucket : largest,
	),
);

const weaponDistribution = $derived.by(() => {
	const rows = [...(analytics?.weaponDistribution ?? [])].sort(
		(a, b) => b.value - a.value,
	);
	const maximum = Math.max(...rows.map((row) => row.value), 1);
	return rows.map((row) => ({
		label: formatLabel(row.weapon),
		value: row.value,
		percentageOfMaximum: (row.value / maximum) * 100,
	}));
});

const genderDistribution = $derived.by(() => {
	const rows = [...(analytics?.genderDistribution ?? [])].sort(
		(a, b) => b.value - a.value,
	);
	const total = rows.reduce((sum, row) => sum + row.value, 0);
	return rows.map((row) => ({
		label: formatLabel(row.gender),
		value: row.value,
		percentage: total > 0 ? (row.value / total) * 100 : 0,
	}));
});

const mostPopularWeapon = $derived(weaponDistribution[0]);
</script>

<section aria-labelledby="membership-snapshot-heading">
	<div
		class="mb-4 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between"
	>
		<div>
			<p class="text-xs font-bold uppercase tracking-[0.16em] text-primary">
				Active membership
			</p>
			<h2
				id="membership-snapshot-heading"
				class="mt-1 font-heading text-2xl text-foreground"
			>
				Club snapshot
			</h2>
		</div>
		<p class="text-sm text-muted-foreground">
			Based on current active member profiles
		</p>
	</div>

	{#if analyticsQuery.isError}
		<Card.Root class="gap-2 border-destructive/40 bg-destructive/5 px-6">
			<h3 class="font-semibold text-foreground">
				Analytics could not be loaded
			</h3>
			<p class="text-sm text-muted-foreground">
				Refresh the page to try fetching the membership snapshot again.
			</p>
		</Card.Root>
	{:else}
		<div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
			<Card.Root class="gap-0 overflow-hidden p-0">
				<div class="h-1.5 bg-primary"></div>
				<div class="p-4 sm:p-5">
					<div class="mb-4 flex items-center justify-between gap-3">
						<p class="text-sm font-semibold text-muted-foreground">
							Active members
						</p>
						<span
							class="grid size-9 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary"
						>
							<Users class="size-4" aria-hidden="true" />
						</span>
					</div>
					{#if analyticsQuery.isLoading}
						<Skeleton class="h-10 w-20" />
					{:else}
						<p
							class="text-3xl font-bold tabular-nums text-foreground sm:text-4xl"
						>
							{formatNumber(totalCount)}
						</p>
					{/if}
					<p class="mt-2 text-xs leading-5 text-muted-foreground">
						Included in this snapshot
					</p>
				</div>
			</Card.Root>

			<Card.Root class="gap-0 overflow-hidden p-0">
				<div class="h-1.5 bg-secondary"></div>
				<div class="p-4 sm:p-5">
					<div class="mb-4 flex items-center justify-between gap-3">
						<p class="text-sm font-semibold text-muted-foreground">
							Average age
						</p>
						<span
							class="grid size-9 shrink-0 place-items-center rounded-lg bg-secondary/20 text-foreground"
						>
							<CalendarDays class="size-4" aria-hidden="true" />
						</span>
					</div>
					{#if analyticsQuery.isLoading}
						<Skeleton class="h-10 w-20" />
					{:else}
						<p
							class="text-3xl font-bold tabular-nums text-foreground sm:text-4xl"
						>
							{averageAge.toLocaleString("en-IE", { maximumFractionDigits: 1 })}
						</p>
					{/if}
					<p class="mt-2 text-xs leading-5 text-muted-foreground">
						From {formatNumber(knownAgeCount)} profiles with a date of birth
					</p>
				</div>
			</Card.Root>

			<Card.Root class="gap-0 overflow-hidden p-0">
				<div class="h-1.5 bg-accent"></div>
				<div class="p-4 sm:p-5">
					<div class="mb-4 flex items-center justify-between gap-3">
						<p class="text-sm font-semibold text-muted-foreground">
							Largest age group
						</p>
						<span
							class="grid size-9 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent"
						>
							<ChartColumn class="size-4" aria-hidden="true" />
						</span>
					</div>
					{#if analyticsQuery.isLoading}
						<Skeleton class="h-10 w-28" />
					{:else}
						<p class="text-2xl font-bold text-foreground sm:text-3xl">
							{largestAgeGroup.value > 0
								? largestAgeGroup.shortLabel
								: "No data"}
						</p>
					{/if}
					<p class="mt-2 text-xs leading-5 text-muted-foreground">
						{formatNumber(largestAgeGroup.value)} members
					</p>
				</div>
			</Card.Root>

			<Card.Root class="gap-0 overflow-hidden p-0">
				<div class="h-1.5 bg-primary/70"></div>
				<div class="p-4 sm:p-5">
					<div class="mb-4 flex items-center justify-between gap-3">
						<p class="text-sm font-semibold text-muted-foreground">
							Top weapon
						</p>
						<span
							class="grid size-9 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary"
						>
							<Swords class="size-4" aria-hidden="true" />
						</span>
					</div>
					{#if analyticsQuery.isLoading}
						<Skeleton class="h-10 w-28" />
					{:else}
						<p
							class="text-xl font-bold leading-tight text-foreground sm:text-2xl"
						>
							{mostPopularWeapon?.label ?? "No data"}
						</p>
					{/if}
					<p class="mt-2 text-xs leading-5 text-muted-foreground">
						{formatNumber(mostPopularWeapon?.value ?? 0)} member selections
					</p>
				</div>
			</Card.Root>
		</div>

		<div class="mt-6 grid gap-4 xl:grid-cols-12">
			<Card.Root class="gap-0 px-5 sm:px-6 xl:col-span-7">
				<div class="mb-6">
					<h3 class="font-heading text-xl text-foreground">Age distribution</h3>
					<p class="mt-1 text-sm text-muted-foreground">
						Active members grouped by age range
					</p>
				</div>

				{#if analyticsQuery.isLoading}
					<Skeleton class="h-64 w-full" />
				{:else if knownAgeCount === 0}
					<div
						class="grid h-64 place-items-center rounded-xl bg-muted/40 text-sm text-muted-foreground"
					>
						No age data is available.
					</div>
				{:else}
					<div
						class="flex h-64 items-end gap-2 border-b border-border px-1 pt-8 sm:gap-3"
						role="img"
						aria-label="Age distribution of active members"
					>
						{#each ageBuckets as bucket (bucket.shortLabel)}
							<div class="flex h-full min-w-0 flex-1 flex-col justify-end">
								<div
									class="mb-2 text-center text-xs font-semibold tabular-nums text-foreground"
								>
									{bucket.value}
								</div>
								<div class="flex h-[calc(100%-3.5rem)] items-end">
									<div
										class="w-full rounded-t-md bg-primary transition-[height] duration-300"
										style:height={`${bucket.percentageOfMaximum}%`}
										aria-hidden="true"
									></div>
								</div>
								<div
									class="mt-2 truncate text-center text-[10px] font-medium text-muted-foreground sm:text-xs"
								>
									{bucket.shortLabel}
								</div>
								<span class="sr-only"
									>{bucket.label}: {bucket.value} members</span
								>
							</div>
						{/each}
					</div>
				{/if}
			</Card.Root>

			<Card.Root class="gap-0 px-5 sm:px-6 xl:col-span-5">
				<div class="mb-6">
					<h3 class="font-heading text-xl text-foreground">
						Preferred weapons
					</h3>
					<p class="mt-1 text-sm text-muted-foreground">
						Ranked from active member selections
					</p>
				</div>

				{#if analyticsQuery.isLoading}
					<div class="space-y-5">
						{#each { length: 5 } as _, index (index)}
							<Skeleton class="h-9 w-full" />
						{/each}
					</div>
				{:else if weaponDistribution.length === 0}
					<div
						class="grid h-64 place-items-center rounded-xl bg-muted/40 text-sm text-muted-foreground"
					>
						No weapon preferences are available.
					</div>
				{:else}
					<ol class="space-y-4">
						{#each weaponDistribution as weapon, index (weapon.label)}
							<li>
								<div
									class="mb-1.5 flex items-center justify-between gap-3 text-sm"
								>
									<span class="min-w-0 truncate font-medium text-foreground">
										<span
											class="mr-2 text-xs tabular-nums text-muted-foreground"
											>{index + 1}</span
										>
										{weapon.label}
									</span>
									<span
										class="shrink-0 font-semibold tabular-nums text-foreground"
										>{weapon.value}</span
									>
								</div>
								<div class="h-2 overflow-hidden rounded-full bg-muted">
									<div
										class="h-full rounded-full bg-primary transition-[width] duration-300"
										style:width={`${weapon.percentageOfMaximum}%`}
									></div>
								</div>
							</li>
						{/each}
					</ol>
				{/if}
			</Card.Root>

			<Card.Root class="gap-0 px-5 sm:px-6 xl:col-span-12">
				<div class="mb-6 sm:flex sm:items-end sm:justify-between sm:gap-4">
					<div>
						<h3 class="font-heading text-xl text-foreground">
							Gender distribution
						</h3>
						<p class="mt-1 text-sm text-muted-foreground">
							Breakdown of profiles with a recorded gender
						</p>
					</div>
				</div>

				{#if analyticsQuery.isLoading}
					<Skeleton class="h-24 w-full" />
				{:else if genderDistribution.length === 0}
					<div
						class="grid h-24 place-items-center rounded-xl bg-muted/40 text-sm text-muted-foreground"
					>
						No gender data is available.
					</div>
				{:else}
					<div class="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
						{#each genderDistribution as gender (gender.label)}
							<div>
								<div class="mb-2 flex items-baseline justify-between gap-3">
									<span class="text-sm font-medium text-foreground"
										>{gender.label}</span
									>
									<span
										class="text-sm font-semibold tabular-nums text-foreground"
									>
										{gender.value}
										<span class="ml-1 font-normal text-muted-foreground">
											({gender.percentage.toLocaleString("en-IE", {
												maximumFractionDigits: 1,
											})}%)
										</span>
									</span>
								</div>
								<div class="h-2.5 overflow-hidden rounded-full bg-muted">
									<div
										class="h-full rounded-full bg-accent transition-[width] duration-300"
										style:width={`${gender.percentage}%`}
									></div>
								</div>
							</div>
						{/each}
					</div>
				{/if}
			</Card.Root>
		</div>
	{/if}
</section>
