<script lang="ts">
import {
	discordDoctorKickMutation,
	discordDoctorReportOptions,
	membersMeOptions,
	type DiscordDoctorKickRequest,
	type DiscordDoctorKickResult,
	type DiscordDoctorMemberSummary,
	type DiscordDoctorServerMember,
	type DiscordDoctorServerMembers,
	type MembershipStatus,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	keepPreviousData,
} from "@tanstack/svelte-query";
import {
	getCoreRowModel,
	getFilteredRowModel,
	getSortedRowModel,
	type ColumnDef,
	type Row,
	type SortingState,
	type TableOptions,
} from "@tanstack/table-core";
import {
	TriangleAlert,
	LoaderCircle,
	RefreshCw,
	Search,
	ServerCog,
	ShieldCheck,
	UserMinus,
	Users,
	X,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { onMount } from "svelte";
import * as AlertDialog from "$lib/components/ui/alert-dialog";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { createSvelteTable } from "$lib/components/ui/data-table";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import { Skeleton } from "$lib/components/ui/skeleton";
import * as Table from "$lib/components/ui/table";
import SortHeader from "$lib/components/ui/table/sort-header.svelte";
import * as Tabs from "$lib/components/ui/tabs";
import { Textarea } from "$lib/components/ui/textarea";
import { cn } from "$lib/utils";

type DoctorView = "server" | "members";
type ServerBucket = keyof DiscordDoctorServerMembers;
type KickReview = {
	bucket: ServerBucket;
	targets: DiscordDoctorServerMember[];
	skipped: DiscordDoctorServerMember[];
};

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

const auditBucketNames = {
	linkedActive: "linked_active",
	linkedInactive: "linked_inactive",
	pendingLink: "pending_link",
	unrecognized: "unrecognized",
} satisfies Record<ServerBucket, string>;

const outcomeLabels = {
	kicked: "Kicked",
	already_left: "Already left",
	refused: "Refused",
	failed: "Failed",
} satisfies Record<DiscordDoctorKickResult["outcome"], string>;

let view = $state<DoctorView>("server");
let selectedBucket = $state<ServerBucket>("linkedActive");
let bypassCache = $state(false);
let now = $state(Date.now());
let kickDialogOpen = $state(false);
let kickReview = $state<KickReview | null>(null);
let kickNote = $state("");
let kickResults = $state<Record<string, DiscordDoctorKickResult>>({});
let latestKickRows = $state<DiscordDoctorServerMember[]>([]);
let globalFilter = $state("");
let sorting = $state<SortingState>([{ id: "serverAccount", desc: true }]);

const reportQuery = createQuery(() => ({
	...discordDoctorReportOptions({ query: { refresh: bypassCache } }),
	placeholderData: keepPreviousData,
	refetchOnWindowFocus: false,
}));

const report = $derived(reportQuery.data?.data);

// A single tab panel renders the selected server-view bucket; the shared
// table swaps its rows when the tab changes while keeping the active search
// and join-date sort.
const bucket = $derived(
	buckets.find((candidate) => candidate.key === selectedBucket) ?? buckets[0],
);
const rows = $derived(report?.serverMembers[bucket.key] ?? []);
const currentUserQuery = createQuery(() => ({
	...membersMeOptions(),
	refetchOnWindowFocus: false,
}));
const adminName = $derived.by(() => {
	const member = currentUserQuery.data?.data;
	return member ? `${member.firstName} ${member.lastName}` : "";
});
const auditReasonPreview = $derived.by(() => {
	if (!kickReview || !adminName) return "Loading admin name…";
	const base = `DHC Doctor — ${adminName}: ${auditBucketNames[kickReview.bucket]}`;
	const note = kickNote.trim();
	return note ? `${base} — ${note}` : base;
});
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

const kickMutation = createMutation(() => ({
	...discordDoctorKickMutation(),
	onSuccess: (response) => {
		const nextResults = { ...kickResults };
		for (const result of response.data.results) {
			nextResults[result.discordUserId] = result;
		}
		kickResults = nextResults;
		latestKickRows = kickReview?.targets ?? [];
		kickDialogOpen = false;
		kickReview = null;
		kickNote = "";
		toast.success("Kick request completed");
		void reportQuery.refetch();
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to kick server accounts");
	},
}));

const doctorColumns: ColumnDef<DiscordDoctorServerMember>[] = [
	{
		id: "serverAccount",
		accessorFn: (row) => joinedAtTime(row),
		sortingFn: sortByJoinedAt,
	},
	{ id: "memberMatch" },
	{ id: "membershipStatus" },
	{ id: "status" },
	{ id: "actions", enableSorting: false },
];

// One reactive table drives every server-view bucket; switching tabs swaps the
// underlying rows while keeping the active search and join-date sort.
const tableOptions = $state<TableOptions<DiscordDoctorServerMember>>({
	columns: doctorColumns,
	globalFilterFn: doctorGlobalFilter,
	getCoreRowModel: getCoreRowModel(),
	getFilteredRowModel: getFilteredRowModel(),
	getSortedRowModel: getSortedRowModel(),
	getRowId: (row) => row.discordUserId,
	get data() {
		return report?.serverMembers[selectedBucket] ?? [];
	},
	onGlobalFilterChange: (updater) => {
		globalFilter =
			updater instanceof Function ? updater(globalFilter) : updater;
	},
	onSortingChange: (updater) => {
		sorting = updater instanceof Function ? updater(sorting) : updater;
	},
	state: {
		get globalFilter() {
			return globalFilter;
		},
		get sorting() {
			return sorting;
		},
	},
});

const table = createSvelteTable(tableOptions);
const accountColumn = $derived(table.getColumn("serverAccount"));
const accountSort = $derived(
	table.getColumn("serverAccount")?.getIsSorted() ?? false,
);

onMount(() => {
	const interval = window.setInterval(() => {
		now = Date.now();
	}, 1000);
	return () => window.clearInterval(interval);
});

function fullName(member: DiscordDoctorMemberSummary): string {
	return `${member.firstName} ${member.lastName}`;
}

function joinedAtTime(row: DiscordDoctorServerMember): number | null {
	if (!row.joinedAt) return null;
	const time = Date.parse(row.joinedAt);
	return Number.isNaN(time) ? null : time;
}

function doctorGlobalFilter(
	row: Row<DiscordDoctorServerMember>,
	_columnId: string,
	filterValue: string,
): boolean {
	const needle = filterValue.trim().toLowerCase();
	if (!needle) return true;
	const account = row.original;
	return (
		account.displayName.toLowerCase().includes(needle) ||
		account.username.toLowerCase().includes(needle) ||
		Boolean(
			account.member && fullName(account.member).toLowerCase().includes(needle),
		)
	);
}

function sortByJoinedAt(
	a: Row<DiscordDoctorServerMember>,
	b: Row<DiscordDoctorServerMember>,
): number {
	const aTime = joinedAtTime(a.original);
	const bTime = joinedAtTime(b.original);
	if (aTime === null && bTime === null) return 0;
	if (aTime === null) return 1;
	if (bTime === null) return -1;
	return aTime - bTime;
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

function canKick(
	bucket: ServerBucket,
	row: DiscordDoctorServerMember,
): boolean {
	return bucket !== "linkedActive" && row.kickable && !row.protected;
}

function bulkActionLabel(bucket: ServerBucket): string | null {
	switch (bucket) {
		case "linkedInactive":
			return "Kick all inactive";
		case "unrecognized":
			return "Kick all unrecognized";
		case "linkedActive":
		case "pendingLink":
			return null;
	}
}

function startSingleKick(bucket: ServerBucket, row: DiscordDoctorServerMember) {
	if (!canKick(bucket, row)) return;
	kickReview = { bucket, targets: [row], skipped: [] };
	kickNote = "";
	kickDialogOpen = true;
}

function startBulkKick(
	bucket: ServerBucket,
	rows: DiscordDoctorServerMember[],
) {
	if (!bulkActionLabel(bucket)) return;
	const targets = rows.filter((row) => canKick(bucket, row));
	if (targets.length === 0) return;
	kickReview = {
		bucket,
		targets,
		skipped: rows.filter((row) => !canKick(bucket, row)),
	};
	kickNote = "";
	kickDialogOpen = true;
}

function updateKickDialog(open: boolean) {
	if (!open && kickMutation.isPending) return;
	kickDialogOpen = open;
	if (!open) {
		kickReview = null;
		kickNote = "";
	}
}

function submitKick() {
	if (!kickReview || kickReview.targets.length === 0 || !adminName) return;
	const note = kickNote.trim();
	const body: DiscordDoctorKickRequest = {
		discordUserIds: kickReview.targets.map((row) => row.discordUserId),
	};
	if (note) body.note = note;
	kickMutation.mutate({ body });
}

function skipReason(row: DiscordDoctorServerMember): string {
	if (row.protected) return "Protected member";
	if (row.membershipStatus === "paused") return "Paused member";
	return "Not eligible for removal";
}

function outcomeStyle(outcome: DiscordDoctorKickResult["outcome"]): string {
	switch (outcome) {
		case "kicked":
			return "border-primary/30 bg-primary/10 text-primary";
		case "already_left":
			return "border-primary/25 bg-primary/5 text-foreground";
		case "refused":
			return "border-secondary bg-secondary/20 text-foreground";
		case "failed":
			return "border-destructive/30 bg-destructive/10 text-destructive";
	}
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
				<TriangleAlert class="size-10 text-destructive" aria-hidden="true" />
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
				{#if latestKickRows.length > 0}
					<section
						class="mb-4 rounded-2xl border border-border bg-card p-4 shadow-[4px_4px_0_hsl(var(--secondary)/0.25)] sm:p-5"
						aria-live="polite"
						aria-labelledby="latest-kick-results-title"
					>
						<h2
							id="latest-kick-results-title"
							class="font-heading text-lg text-foreground"
						>
							Latest kick results
						</h2>
						<div class="mt-3 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
							{#each latestKickRows as row (row.discordUserId)}
								{@const outcome = kickResults[row.discordUserId]}
								{#if outcome}
									<div
										class="flex items-start justify-between gap-3 rounded-xl border border-border bg-muted/20 p-3"
									>
										<div class="min-w-0">
											<p class="truncate font-semibold text-foreground">
												{row.displayName}
											</p>
											<p class="truncate text-xs text-muted-foreground">
												@{row.username}
											</p>
											{#if outcome.reason || outcome.error}
												<p class="mt-1 text-xs text-muted-foreground">
													{outcome.reason ?? outcome.error}
												</p>
											{/if}
										</div>
										<Badge
											variant="outline"
											class={outcomeStyle(outcome.outcome)}
										>
											{outcomeLabels[outcome.outcome]}
										</Badge>
									</div>
								{/if}
							{/each}
						</div>
					</section>
				{/if}
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

					<Tabs.Content value={selectedBucket} class="mt-4">
						<section
							class="overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
						>
							<header
								class="flex flex-col gap-4 border-b border-border bg-muted/20 p-4 sm:flex-row sm:items-center sm:justify-between sm:p-5"
							>
								<div>
									<h2 class="font-heading text-xl text-foreground">
										{bucket.label}
									</h2>
									<p class="mt-1 text-sm leading-6 text-muted-foreground">
										{bucket.blurb}
									</p>
								</div>
								{#if bulkActionLabel(bucket.key) && rows.some( (row) => canKick(bucket.key, row) )}
									<Button
										variant="destructive"
										class="min-h-11 self-start sm:self-center"
										onclick={() => startBulkKick(bucket.key, rows)}
									>
										<UserMinus aria-hidden="true" />
										{bulkActionLabel(bucket.key)}
									</Button>
								{/if}
							</header>

							{#if rows.length === 0}
								<p class="p-8 text-center text-sm text-muted-foreground">
									Nothing in this bucket.
								</p>
							{:else}
								<div
									class="flex flex-col gap-3 border-b border-border bg-muted/10 p-4 sm:flex-row sm:items-center"
								>
									<div class="relative w-full sm:max-w-xs">
										<Search
											class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground"
											aria-hidden="true"
										/>
										<Input
											type="search"
											class="min-h-11 pl-9 pr-11"
											bind:value={globalFilter}
											placeholder="Filter by name or @username"
											aria-label="Filter accounts by name or username"
										/>
										{#if globalFilter}
											<Button
												variant="ghost"
												size="icon"
												type="button"
												class="absolute top-0 right-0"
												aria-label="Clear filter"
												onclick={() => {
													globalFilter = "";
												}}
											>
												<X class="size-4" aria-hidden="true" />
											</Button>
										{/if}
									</div>
									{#if globalFilter.trim()}
										<p
											class="text-xs text-muted-foreground sm:ml-auto"
											aria-live="polite"
										>
											Showing {table.getRowModel().rows.length} of {rows.length}
										</p>
									{/if}
								</div>

								{#if table.getRowModel().rows.length === 0}
									<p class="p-8 text-center text-sm text-muted-foreground">
										No accounts match “{globalFilter.trim()}”.
									</p>
								{:else}
									<div class="overflow-x-auto">
										<Table.Root class="min-w-[54rem]">
											<Table.Caption class="sr-only">
												{bucket.label} Discord server accounts
											</Table.Caption>
											<Table.Header>
												<Table.Row>
													<Table.Head
														aria-sort={accountSort === "asc"
															? "ascending"
															: accountSort === "desc"
																? "descending"
																: undefined}
													>
														<SortHeader
															onclick={() =>
																accountColumn?.toggleSorting(
																	accountColumn.getIsSorted() === "asc",
																)}
															header="Server account"
															class="-ml-2 h-9 px-2"
															sortDirection={accountSort}
														/>
													</Table.Head>
													<Table.Head>Member match</Table.Head>
													<Table.Head>Membership</Table.Head>
													<Table.Head>Status</Table.Head>
													<Table.Head class="text-right">Actions</Table.Head>
												</Table.Row>
											</Table.Header>
											<Table.Body>
												{#each table.getRowModel().rows as tableRow (tableRow.id)}
													{@const row = tableRow.original}
													{@const outcome = kickResults[row.discordUserId]}
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
															<div class="flex flex-col items-start gap-2">
																{#if outcome}
																	<Badge
																		variant="outline"
																		class={outcomeStyle(outcome.outcome)}
																	>
																		{outcomeLabels[outcome.outcome]}
																	</Badge>
																	{#if outcome.reason || outcome.error}
																		<p
																			class="max-w-48 whitespace-normal text-xs text-muted-foreground"
																		>
																			{outcome.reason ?? outcome.error}
																		</p>
																	{/if}
																{/if}
																{#if row.protected}
																	<Badge
																		variant="outline"
																		class="border-primary/40 bg-primary/10 font-semibold text-primary"
																	>
																		<ShieldCheck aria-hidden="true" />
																		Protected
																	</Badge>
																{:else if bucket.key === "pendingLink"}
																	<Badge variant="secondary"
																		>Unproven match</Badge
																	>
																{:else if !outcome}
																	<span class="text-sm text-muted-foreground"
																		>Review</span
																	>
																{/if}
															</div>
														</Table.Cell>
														<Table.Cell class="p-4 text-right sm:p-5">
															{#if canKick(bucket.key, row)}
																<Button
																	variant="destructive"
																	size="sm"
																	class="min-h-11"
																	aria-label={`Kick ${row.displayName}`}
																	disabled={kickMutation.isPending}
																	onclick={() =>
																		startSingleKick(bucket.key, row)}
																>
																	<UserMinus aria-hidden="true" />
																	Kick
																</Button>
															{:else}
																<span class="text-sm text-muted-foreground"
																	>No action</span
																>
															{/if}
														</Table.Cell>
													</Table.Row>
												{/each}
											</Table.Body>
										</Table.Root>
									</div>
								{/if}
							{/if}
						</section>
					</Tabs.Content>
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

<AlertDialog.Root open={kickDialogOpen} onOpenChange={updateKickDialog}>
	{#if kickReview}
		<AlertDialog.Content
			class="max-h-[calc(100svh-2rem)] overflow-y-auto rounded-2xl border-border/80 sm:max-w-2xl"
		>
			<AlertDialog.Header>
				<div
					class="mb-1 flex size-11 items-center justify-center rounded-xl bg-destructive/10 text-destructive"
					aria-hidden="true"
				>
					<UserMinus class="size-5" />
				</div>
				<AlertDialog.Title>
					Kick {kickReview.targets.length}
					{kickReview.targets.length === 1 ? "account" : "accounts"} from the server?
				</AlertDialog.Title>
				<AlertDialog.Description class="leading-6">
					Kicks run immediately and are logged to the Discord audit log only —
					there is no record in this system. Review every account before
					continuing.
				</AlertDialog.Description>
			</AlertDialog.Header>

			{#if kickReview.bucket === "pendingLink"}
				<div
					class="flex gap-3 rounded-xl border border-secondary bg-secondary/15 p-4 text-sm"
				>
					<TriangleAlert
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-foreground"
					/>
					<div>
						<p class="font-bold text-foreground">
							Unconfirmed match — verify on Discord first…
						</p>
						<p class="mt-1 leading-6 text-muted-foreground">
							This assignment has not been confirmed by the member. Pending
							links can only be reviewed one at a time.
						</p>
					</div>
				</div>
			{/if}

			<div class="grid gap-4 sm:grid-cols-2">
				<section
					class="rounded-xl border border-destructive/25 bg-destructive/5 p-4"
				>
					<h3 class="text-sm font-bold text-foreground">
						Will be kicked ({kickReview.targets.length})
					</h3>
					<ul class="mt-3 space-y-2">
						{#each kickReview.targets as row (row.discordUserId)}
							<li class="rounded-lg border border-border bg-background p-3">
								<p class="font-semibold text-foreground">{row.displayName}</p>
								<p class="text-xs text-muted-foreground">@{row.username}</p>
								{#if row.member}
									<p class="mt-1 text-xs text-muted-foreground">
										Member match: {fullName(row.member)}
									</p>
								{/if}
							</li>
						{/each}
					</ul>
				</section>

				<section class="rounded-xl border border-border bg-muted/20 p-4">
					<h3 class="text-sm font-bold text-foreground">
						Skipped — will not be kicked ({kickReview.skipped.length})
					</h3>
					{#if kickReview.skipped.length === 0}
						<p class="mt-3 text-sm text-muted-foreground">
							No accounts will be skipped.
						</p>
					{:else}
						<ul class="mt-3 space-y-2">
							{#each kickReview.skipped as row (row.discordUserId)}
								<li class="rounded-lg border border-border bg-background p-3">
									<div class="flex items-start justify-between gap-3">
										<div>
											<p class="font-semibold text-foreground">
												{row.displayName}
											</p>
											<p class="text-xs text-muted-foreground">
												@{row.username}
											</p>
										</div>
										<Badge variant="outline">{skipReason(row)}</Badge>
									</div>
								</li>
							{/each}
						</ul>
					{/if}
				</section>
			</div>

			<div class="space-y-4 rounded-xl border border-border bg-muted/20 p-4">
				<div>
					<p class="text-sm font-bold text-foreground">Discord audit reason</p>
					<code
						class="mt-2 block break-words rounded-lg border border-border bg-background px-3 py-2 font-mono text-xs leading-5 text-foreground"
						aria-live="polite"
					>
						{auditReasonPreview}
					</code>
				</div>
				<div class="space-y-2">
					<Label for="discord-kick-note">Audit note (optional)</Label>
					<Textarea
						id="discord-kick-note"
						bind:value={kickNote}
						rows={2}
						placeholder="Add context for the Discord audit log"
						disabled={kickMutation.isPending}
					/>
				</div>
			</div>

			<AlertDialog.Footer>
				<AlertDialog.Cancel disabled={kickMutation.isPending}>
					Cancel
				</AlertDialog.Cancel>
				<Button
					variant="destructive"
					disabled={kickMutation.isPending || !adminName}
					onclick={submitKick}
				>
					{#if kickMutation.isPending}
						<LoaderCircle aria-hidden="true" class="animate-spin" />
						Kicking…
					{:else}
						<UserMinus aria-hidden="true" />
						Kick {kickReview.targets.length}
						{kickReview.targets.length === 1 ? "account" : "accounts"}
					{/if}
				</Button>
			</AlertDialog.Footer>
		</AlertDialog.Content>
	{/if}
</AlertDialog.Root>
