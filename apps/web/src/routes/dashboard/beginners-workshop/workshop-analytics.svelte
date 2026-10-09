<!--
	The Beginners' Workshop Dashboard tab: report only, never a command.
	The queue figures (Waiting, average age, age and gender) are
	`GET /api/waitlist/analytics`, over `waiting` people only (ALE-375). For
	`beginners.workshops.manage` holders, ALE-397's report follows: planning
	cards and the outcomes table (`GET /api/beginners-workshops/report`).
	Both reads are browser-side TanStack queries; Phoenix's pipelines gate them.
-->
<script lang="ts">
import {
	beginnersWorkshopReportShowOptions,
	waitlistAnalyticsOptions,
} from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import { CalendarDays, ChartColumn, Hourglass, Users } from "@lucide/svelte";
import { formatDays } from "#lib/beginners-workshops/report.js";
import {
	formatLabel,
	formatNumber,
} from "#lib/components/chart-conventions.js";
import * as Card from "#lib/components/ui/card/index.js";
import { Skeleton } from "#lib/components/ui/skeleton/index.js";
import Report from "./beginners-workshop-report.svelte";

const { canManageWorkshops = false }: { canManageWorkshops?: boolean } =
	$props();

const ageRanges = [
	{ label: "Under 18", shortLabel: "<18", min: 0, max: 17 },
	{ label: "18 to 24", shortLabel: "18–24", min: 18, max: 24 },
	{ label: "25 to 34", shortLabel: "25–34", min: 25, max: 34 },
	{ label: "35 to 44", shortLabel: "35–44", min: 35, max: 44 },
	{ label: "45 to 54", shortLabel: "45–54", min: 45, max: 54 },
	{ label: "55 to 64", shortLabel: "55–64", min: 55, max: 64 },
	{ label: "65 and over", shortLabel: "65+", min: 65, max: Infinity },
] as const;

const analyticsQuery = createQuery(() => waitlistAnalyticsOptions());
const reportQuery = createQuery(() => ({
	...beginnersWorkshopReportShowOptions(),
	enabled: canManageWorkshops,
}));

const analytics = $derived(analyticsQuery.data?.data);
const report = $derived(reportQuery.data?.data);

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

// The report counts every waiting entry; the analytics only profiles with a
// date of birth. Prefer the report's queue size when it is loaded.
const waiting = $derived(report?.queue.waiting ?? analytics?.totalCount ?? 0);

const cards = $derived([
	{
		label: "Waiting",
		value: formatNumber(waiting),
		note: "People in the queue now",
		icon: Users,
	},
	{
		label: "Average age",
		value: (analytics?.averageAge ?? 0).toLocaleString("en-IE", {
			maximumFractionDigits: 1,
		}),
		note: `From ${formatNumber(knownAgeCount)} waiting people with a date of birth`,
		icon: CalendarDays,
	},
	{
		label: "Largest age group",
		value: largestAgeGroup.value > 0 ? largestAgeGroup.shortLabel : "No data",
		note: `${formatNumber(largestAgeGroup.value)} waiting people`,
		icon: ChartColumn,
	},
	...(canManageWorkshops
		? [
				{
					label: "Longest wait",
					value: report ? formatDays(report.queue.longestWaitDays) : "—",
					note: report
						? `Median ${formatDays(report.queue.medianWaitDays)}`
						: "",
					icon: Hourglass,
				},
			]
		: []),
]);
</script>

<section aria-labelledby="bw-queue-heading">
	<div class="mb-4">
		<p class="text-xs font-bold uppercase tracking-[0.16em] text-primary">
			The queue
		</p>
		<h2
			id="bw-queue-heading"
			class="mt-1 font-heading text-2xl text-foreground"
		>
			Waiting now
		</h2>
		<p class="text-sm text-muted-foreground">
			Over waiting people only; removed, attended, invited and joined people are
			not counted.
		</p>
	</div>

	{#if analyticsQuery.isError}
		<Card.Root class="gap-2 border-destructive/40 bg-destructive/5 px-6">
			<h3 class="font-semibold text-foreground">
				The queue could not be loaded
			</h3>
			<p class="text-sm text-muted-foreground">
				Refresh the page to try again.
			</p>
		</Card.Root>
	{:else}
		<div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
			{#each cards as card (card.label)}
				<Card.Root class="gap-0 p-4 sm:p-5" data-testid="queue-card">
					<div class="mb-4 flex items-center justify-between gap-3">
						<p class="text-sm font-semibold text-muted-foreground">
							{card.label}
						</p>
						<span
							class="grid size-9 shrink-0 place-items-center rounded-lg bg-primary/10 text-primary"
						>
							<card.icon class="size-4" aria-hidden="true" />
						</span>
					</div>
					{#if analyticsQuery.isLoading}
						<Skeleton class="h-10 w-20" />
					{:else}
						<p class="text-3xl font-bold tabular-nums text-foreground">
							{card.value}
						</p>
					{/if}
					<p class="mt-2 text-xs leading-5 text-muted-foreground">
						{card.note}
					</p>
				</Card.Root>
			{/each}
		</div>

		<div class="mt-4 grid gap-4 xl:grid-cols-12">
			<Card.Root class="gap-0 px-5 sm:px-6 xl:col-span-7">
				<div class="mb-6">
					<h3 class="font-heading text-xl text-foreground">Age distribution</h3>
					<p class="mt-1 text-sm text-muted-foreground">
						Waiting people grouped by age range
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
						aria-label="Age distribution of waiting people"
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
									>{bucket.label}: {bucket.value} people</span
								>
							</div>
						{/each}
					</div>
				{/if}
			</Card.Root>

			<Card.Root class="gap-0 px-5 sm:px-6 xl:col-span-5">
				<div class="mb-6">
					<h3 class="font-heading text-xl text-foreground">
						Gender distribution
					</h3>
					<p class="mt-1 text-sm text-muted-foreground">
						Waiting people with a recorded gender
					</p>
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
					<ol class="space-y-4">
						{#each genderDistribution as gender (gender.label)}
							<li>
								<div
									class="mb-1.5 flex items-baseline justify-between gap-3 text-sm"
								>
									<span class="font-medium text-foreground">{gender.label}</span
									>
									<span class="font-semibold tabular-nums text-foreground">
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
							</li>
						{/each}
					</ol>
				{/if}
			</Card.Root>
		</div>
	{/if}
</section>

{#if canManageWorkshops}
	{#if reportQuery.isError}
		<Card.Root class="mt-8 gap-2 border-destructive/40 bg-destructive/5 px-6">
			<h3 class="font-semibold text-foreground">
				The workshop report could not be loaded
			</h3>
			<p class="text-sm text-muted-foreground">
				Refresh the page to try again.
			</p>
		</Card.Root>
	{:else if report}
		<Report {report} />
	{:else}
		<Skeleton class="mt-8 h-64 w-full" />
	{/if}
{/if}
