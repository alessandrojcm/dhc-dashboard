<script lang="ts">
import {
	discordDoctorReportOptions,
	type DiscordDoctorMemberSummary,
	type DiscordDoctorServerMembers,
	type MembershipStatus,
} from "@dhc/api-client";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import {
	AlertTriangle,
	RefreshCw,
	ServerCog,
	ShieldCheck,
	Users,
} from "@lucide/svelte";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import * as Table from "$lib/components/ui/table";
import * as Tabs from "$lib/components/ui/tabs";
import { cn } from "$lib/utils";

type DoctorView = "server" | "members";
type ServerBucket = keyof DiscordDoctorServerMembers;

const buckets = [
	{
		key: "linkedActive",
		label: "Linked – active",
		blurb:
			"Server accounts proven to belong to members in good standing. Paused memberships count as active.",
	},
	{
		key: "linkedInactive",
		label: "Linked – inactive",
		blurb:
			"Server accounts linked to members whose membership is no longer active.",
	},
	{
		key: "pendingLink",
		label: "Pending link",
		blurb:
			"Accounts matched to a member by an assignment that the member has not confirmed.",
	},
	{
		key: "unrecognized",
		label: "Unrecognized",
		blurb: "Human server accounts with no live member match.",
	},
] as const satisfies ReadonlyArray<{
	key: ServerBucket;
	label: string;
	blurb: string;
}>;

const membershipStyles = {
	active: "border-primary/30 bg-primary/10 text-primary",
	paused: "border-secondary bg-secondary/25 text-foreground",
	inactive: "border-destructive/30 bg-destructive/10 text-destructive",
} satisfies Record<MembershipStatus, string>;

const linkStatusLabels = {
	linked: "Linked",
	pending: "Pending link",
	never_linked: "Never linked",
} as const;

let view = $state<DoctorView>("server");
let selectedBucket = $state<ServerBucket>("linkedActive");
let bypassCache = $state(false);
let now = $state(Date.now());

const reportQuery = createQuery(() => ({
	...discordDoctorReportOptions({ query: { refresh: bypassCache } }),
	placeholderData: keepPreviousData,
	refetchOnWindowFocus: false,
}));

const report = $derived(reportQuery.data?.data);
const cacheAgeSeconds = $derived.by(() => {
	if (!report?.cache.fetchedAt) return 0;
	const fetchedAt = Date.parse(report.cache.fetchedAt);
	return Number.isNaN(fetchedAt)
		? 0
		: Math.max(0, Math.floor((now - fetchedAt) / 1000));
});
const cacheIsStale = $derived(
	Boolean(report) && cacheAgeSeconds >= (report?.cache.ttlSeconds ?? 0),
);

$effect(() => {
	const interval = window.setInterval(() => {
		now = Date.now();
	}, 1000);
	return () => window.clearInterval(interval);
});

function fullName(member: DiscordDoctorMemberSummary): string {
	return `${member.firstName} ${member.lastName}`;
}

function formatJoinedAt(value: string | null): string {
	if (!value) return "Join date unavailable";
	const date = new Date(value);
	if (Number.isNaN(date.valueOf())) return "Join date unavailable";
	return `Joined ${new Intl.DateTimeFormat("en-IE", {
		day: "numeric",
		month: "short",
		year: "numeric",
	}).format(date)}`;
}

async function refreshMembers() {
	if (bypassCache) {
		await reportQuery.refetch();
		return;
	}

	bypassCache = true;
}
</script>

<svelte:head>
	<title>Discord Doctor | Dublin HEMA Club</title>
</svelte:head>

<div class="px-4 pb-10 sm:px-6 lg:px-8">
	<div class="mx-auto w-full max-w-7xl">
		<header class="flex flex-col gap-5 py-6 sm:py-8">
			<div class="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
				<div class="max-w-2xl">
					<p
						class="mb-2 text-xs font-bold uppercase tracking-[0.18em] text-primary"
					>
						Club administration
					</p>
					<h1 class="font-heading text-3xl text-foreground sm:text-4xl">
						Discord Doctor
					</h1>
					<p class="mt-2 text-sm leading-6 text-muted-foreground sm:text-base">
						Cross-reference the Discord server against club membership and
						review accounts that may no longer belong.
					</p>
				</div>

				<div class="flex flex-wrap items-center gap-3">
					<p
						class={cn(
							"flex items-center gap-2 text-sm",
							cacheIsStale
								? "font-semibold text-destructive"
								: "text-muted-foreground",
						)}
						role="status"
						aria-live="polite"
					>
						<span
							class={cn(
								"size-2 rounded-full",
								cacheIsStale ? "bg-destructive" : "bg-primary",
							)}
							aria-hidden="true"
						></span>
						{#if reportQuery.isFetching}
							Refreshing members…
						{:else if cacheIsStale}
							Member list stale — fetched {cacheAgeSeconds}s ago
						{:else if report}
							Members fetched {cacheAgeSeconds}s ago
						{:else}
							Waiting for member data
						{/if}
					</p>
					<Button
						variant="outline"
						size="sm"
						class="min-h-11 cursor-pointer"
						disabled={reportQuery.isFetching}
						onclick={refreshMembers}
					>
						<RefreshCw
							class={cn("size-4", reportQuery.isFetching && "animate-spin")}
							aria-hidden="true"
						/>
						Refresh members
					</Button>
				</div>
			</div>

			<nav
				aria-label="Discord Doctor views"
				class="grid grid-cols-2 gap-1 rounded-xl border border-border bg-card p-1.5 shadow-[3px_3px_0_hsl(var(--secondary)/0.45)]"
			>
				{#each [{ key: "server", label: "Server view", icon: ServerCog }, { key: "members", label: "Members view", icon: Users }] as section (section.key)}
					<button
						type="button"
						aria-pressed={view === section.key}
						onclick={() => {
							view = section.key as DoctorView;
						}}
						class={cn(
							"flex min-h-11 cursor-pointer items-center justify-center gap-2 rounded-lg px-2 text-sm font-semibold transition-[color,background-color,box-shadow] duration-200 focus-visible:outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 sm:px-4",
							view === section.key
								? "bg-primary text-primary-foreground shadow-sm"
								: "text-muted-foreground hover:bg-primary/5 hover:text-foreground",
						)}
					>
						<section.icon class="hidden size-4 sm:block" aria-hidden="true" />
						<span>{section.label}</span>
					</button>
				{/each}
			</nav>
		</header>

		{#if reportQuery.isPending}
			<section
				aria-label="Loading Discord Doctor report"
				class="overflow-hidden rounded-2xl border border-border bg-card p-5 shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
			>
				<div class="space-y-4">
					<Skeleton class="h-10 w-full" />
					{#each { length: 4 } as _, index (index)}
						<Skeleton class="h-16 w-full" />
					{/each}
				</div>
			</section>
		{:else if reportQuery.isError}
			<section
				class="flex flex-col items-center rounded-2xl border border-destructive/40 bg-destructive/5 px-5 py-12 text-center"
			>
				<AlertTriangle class="size-10 text-destructive" aria-hidden="true" />
				<h2 class="mt-4 font-heading text-xl text-foreground">
					Member list unavailable
				</h2>
				<p class="mt-2 max-w-lg text-sm leading-6 text-muted-foreground">
					The Discord server could not be checked. Retry when the connection is
					available.
				</p>
				<Button
					variant="outline"
					class="mt-5 min-h-11 cursor-pointer"
					onclick={() => reportQuery.refetch()}
				>
					Retry
				</Button>
			</section>
		{:else if report}
			{#if view === "server"}
				<Tabs.Root bind:value={selectedBucket}>
					<Tabs.List
						class="h-auto w-full flex-wrap justify-start gap-1 bg-muted/60 p-1.5"
					>
						{#each buckets as bucket (bucket.key)}
							<Tabs.Trigger
								value={bucket.key}
								class="min-h-11 cursor-pointer gap-2 px-3"
							>
								{bucket.label}
								<Badge variant="secondary" class="px-1.5 tabular-nums">
									{report.serverMembers[bucket.key].length}
								</Badge>
							</Tabs.Trigger>
						{/each}
					</Tabs.List>

					{#each buckets as bucket (bucket.key)}
						{@const rows = report.serverMembers[bucket.key]}
						<Tabs.Content value={bucket.key} class="mt-4">
							<section
								class="overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
							>
								<header class="border-b border-border bg-muted/20 p-4 sm:p-5">
									<h2 class="font-heading text-xl text-foreground">
										{bucket.label}
									</h2>
									<p class="mt-1 text-sm leading-6 text-muted-foreground">
										{bucket.blurb}
									</p>
								</header>

								{#if rows.length === 0}
									<p class="p-8 text-center text-sm text-muted-foreground">
										Nothing in this bucket.
									</p>
								{:else}
									<Table.Root class="min-w-[46rem]">
										<Table.Caption class="sr-only">
											{bucket.label} Discord server accounts
										</Table.Caption>
										<Table.Header>
											<Table.Row>
												<Table.Head>Server account</Table.Head>
												<Table.Head>Member match</Table.Head>
												<Table.Head>Membership</Table.Head>
												<Table.Head>Status</Table.Head>
											</Table.Row>
										</Table.Header>
										<Table.Body>
											{#each rows as row (row.discordUserId)}
												<Table.Row>
													<Table.Cell class="p-4 sm:p-5">
														<div class="flex min-w-0 items-center gap-3">
															<div
																class="flex size-10 shrink-0 items-center justify-center rounded-full bg-primary/10 font-heading text-sm text-primary"
																aria-hidden="true"
															>
																{row.displayName.slice(0, 2).toUpperCase()}
															</div>
															<div class="min-w-0">
																<p class="font-semibold text-foreground">
																	<span>{row.displayName}</span>
																	<span
																		class="ml-1 font-normal text-muted-foreground"
																		>@{row.username}</span
																	>
																</p>
																<p class="text-xs text-muted-foreground">
																	{formatJoinedAt(row.joinedAt)}
																</p>
															</div>
														</div>
													</Table.Cell>
													<Table.Cell class="p-4 sm:p-5">
														{#if row.member}
															<p class="font-medium text-foreground">
																{fullName(row.member)}
															</p>
															{#if bucket.key === "pendingLink"}
																<p
																	class="mt-1 max-w-xs whitespace-normal text-xs text-destructive"
																>
																	Unconfirmed match — verify on Discord first.
																</p>
															{:else}
																<p class="text-xs text-muted-foreground">
																	Proven link
																</p>
															{/if}
														{:else}
															<span class="text-sm text-muted-foreground"
																>No member match</span
															>
														{/if}
													</Table.Cell>
													<Table.Cell class="p-4 sm:p-5">
														{#if row.membershipStatus}
															<Badge
																variant="outline"
																class={cn(
																	"capitalize",
																	membershipStyles[row.membershipStatus],
																)}
															>
																{row.membershipStatus}
															</Badge>
														{:else}
															<span class="text-sm text-muted-foreground"
																>Unknown</span
															>
														{/if}
													</Table.Cell>
													<Table.Cell class="p-4 sm:p-5">
														{#if row.protected}
															<Badge
																variant="outline"
																class="border-primary/40 bg-primary/10 font-semibold text-primary"
															>
																<ShieldCheck aria-hidden="true" />
																Protected
															</Badge>
														{:else if bucket.key === "pendingLink"}
															<Badge variant="secondary">Unproven match</Badge>
														{:else}
															<span class="text-sm text-muted-foreground"
																>Review</span
															>
														{/if}
													</Table.Cell>
												</Table.Row>
											{/each}
										</Table.Body>
									</Table.Root>
								{/if}
							</section>
						</Tabs.Content>
					{/each}
				</Tabs.Root>
			{:else}
				<section
					class="overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
				>
					<header class="border-b border-border bg-muted/20 p-4 sm:p-5">
						<h2 class="font-heading text-xl text-foreground">
							Missing from server ({report.missingMembers.length})
						</h2>
						<p class="mt-1 text-sm leading-6 text-muted-foreground">
							Members not known to be in the Discord server. This view is for
							review only; reconnections happen outside the dashboard.
						</p>
					</header>

					{#if report.missingMembers.length === 0}
						<p class="p-8 text-center text-sm text-muted-foreground">
							Every member with a Discord binding is present on the server.
						</p>
					{:else}
						<Table.Root class="min-w-[42rem]">
							<Table.Caption class="sr-only">
								Members missing from the Discord server
							</Table.Caption>
							<Table.Header>
								<Table.Row>
									<Table.Head>Member</Table.Head>
									<Table.Head>Membership</Table.Head>
									<Table.Head>Discord link</Table.Head>
									<Table.Head>Status</Table.Head>
								</Table.Row>
							</Table.Header>
							<Table.Body>
								{#each report.missingMembers as row (row.member.id)}
									<Table.Row>
										<Table.Cell
											class="p-4 font-semibold text-foreground sm:p-5"
										>
											{fullName(row.member)}
										</Table.Cell>
										<Table.Cell class="p-4 sm:p-5">
											<Badge
												variant="outline"
												class={cn(
													"capitalize",
													membershipStyles[row.membershipStatus],
												)}
											>
												{row.membershipStatus}
											</Badge>
										</Table.Cell>
										<Table.Cell class="p-4 sm:p-5">
											<Badge variant="secondary">
												{linkStatusLabels[row.linkStatus]}
											</Badge>
										</Table.Cell>
										<Table.Cell class="p-4 sm:p-5">
											{#if row.autoJoinPending}
												<Badge
													variant="outline"
													class="border-secondary bg-secondary/20 text-foreground"
												>
													Auto-join pending
												</Badge>
											{:else}
												<span class="text-sm text-muted-foreground"
													>Manual follow-up</span
												>
											{/if}
										</Table.Cell>
									</Table.Row>
								{/each}
							</Table.Body>
						</Table.Root>
					{/if}
				</section>
			{/if}
		{/if}
	</div>
</div>
