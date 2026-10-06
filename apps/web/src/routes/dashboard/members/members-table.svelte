<script lang="ts">
import {
	type Member,
	type MembersListSortField,
	membersListOptions,
} from "@dhc/api-client";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import {
	getCoreRowModel,
	getExpandedRowModel,
	getSortedRowModel,
	type TableOptions,
} from "@tanstack/table-core";
import {
	ChevronLeft,
	ChevronRight,
	RotateCcw,
	Search,
	Users,
	X,
} from "@lucide/svelte";
import { page } from "$app/state";
import { Button } from "#lib/components/ui/button/index.js";
import {
	createSvelteTable,
	FlexRender,
	renderComponent,
} from "#lib/components/ui/data-table/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import LoaderCircle from "#lib/components/ui/loader-circle.svelte";
import * as Select from "#lib/components/ui/select/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import SortHeader from "#lib/components/ui/table/sort-header.svelte";
import { PAGE_SIZE_OPTIONS } from "#lib/cursor-query.js";
import { createCursorTableUrl } from "#lib/cursor-table-url.svelte.js";
import {
	ToggleGroup,
	ToggleGroupItem,
} from "#lib/components/ui/toggle-group/index.js";
import { cn } from "#lib/utils.js";
import MemberActions from "./member-actions.svelte";
import MemberDateCell from "./member-date-cell.svelte";
import MemberDetails from "./member-details.svelte";
import MemberIdentityCell from "./member-identity-cell.svelte";
import MemberPhoneCell from "./member-phone-cell.svelte";
import MemberStatusBadge from "./member-status-badge.svelte";
import MemberWeapons from "./member-weapons.svelte";
import ReactivateMemberDialog from "#lib/components/ui/reactivate-member-dialog.svelte";

type MemberTablePage = {
	data: Member[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};

const pageSizeOptions = PAGE_SIZE_OPTIONS;
const statusOptions = ["active", "paused", "inactive"] as const;

// Column ids are the API sort fields; sortable fields without a column stay
// reachable through the URL.
const membersUrl = createCursorTableUrl({
	sort: {
		fields: {
			firstName: "firstName",
			lastName: "lastName",
			email: "email",
			phoneNumber: "phoneNumber",
			age: "age",
			membershipStartDate: "membershipStartDate",
			lastPaymentDate: "lastPaymentDate",
			subscriptionPausedUntil: "subscriptionPausedUntil",
			isActive: "isActive",
		} satisfies Record<string, MembersListSortField>,
		default: "lastName",
	},
	filters: ["membershipStatus"],
});

// The URL keeps the raw string; unknown statuses are dropped and selecting
// every status means no filter.
const membershipStatusFilter = $derived.by(() => {
	const raw = membersUrl.filter("membershipStatus") ?? "";
	const selected = raw.split(",").map((status) => status.trim());
	const statuses = statusOptions.filter((status) => selected.includes(status));

	if (statuses.length === 0 || statuses.length === statusOptions.length) {
		return null;
	}

	return statuses;
});
const hasActiveFilters = $derived(
	membersUrl.search.trim() !== "" || membershipStatusFilter !== null,
);

let expandedState = $state({});

// ALE-252: Reactivate row action, shown only when the viewer holds a
// billing-authority role (layout load mirrors the minting pipeline) and the
// row's membership status is inactive.
const canReactivate = $derived(page.data.canReactivate === true);
let reactivateOpen = $state(false);
let reactivateTargetId = $state<string | null>(null);

function openReactivation(memberId: string) {
	reactivateTargetId = memberId;
	reactivateOpen = true;
}

const membersQuery = createQuery(() => ({
	...membersListOptions({
		query: {
			...membersUrl.request,
			membershipStatus: membershipStatusFilter?.join(","),
		},
	}),
	placeholderData: keepPreviousData,
	select: (response): MemberTablePage => {
		const result = response.data;
		return {
			data: result.members,
			count: result.totalCount,
			nextCursor: result.nextCursor,
			previousCursor: result.previousCursor,
		};
	},
}));

function onSearchSubmit(event: SubmitEvent) {
	event.preventDefault();
	membersUrl.submitSearch();
}

// "All" is the group's reset item: turning it on, turning everything off, or
// selecting every status all mean no filter, which the URL encodes as absent.
const ALL_STATUSES = "all";
const statusFilterValue = $derived(membershipStatusFilter ?? [ALL_STATUSES]);

function onStatusFilterChange(next: string[]) {
	const addedAll =
		next.includes(ALL_STATUSES) && membershipStatusFilter !== null;
	const statuses = statusOptions.filter((status) => next.includes(status));
	const membershipStatus =
		addedAll ||
		statuses.length === 0 ||
		statuses.length === statusOptions.length
			? null
			: statuses.join(",");

	membersUrl.setFilter("membershipStatus", membershipStatus);
}

function resetFilters() {
	membersUrl.setSearch("");
	// Writes the cleared search in the same navigation.
	membersUrl.setFilter("membershipStatus", null);
}

const tableOptions = $state<TableOptions<Member>>({
	autoResetPageIndex: false,
	manualPagination: true,
	manualSorting: true,
	getExpandedRowModel: getExpandedRowModel(),
	columns: [
		{
			accessorKey: "lastName",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Member",
					class: "-ml-2 h-9 px-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ row }) =>
				renderComponent(MemberIdentityCell, { member: row.original }),
		},
		{
			accessorKey: "membershipStatus",
			header: "Status",
			cell: ({ row }) =>
				renderComponent(MemberStatusBadge, {
					status: row.original.membershipStatus,
				}),
		},
		{
			accessorKey: "phoneNumber",
			header: "Phone",
			cell: ({ row }) =>
				renderComponent(MemberPhoneCell, {
					phone: row.original.phoneNumber,
				}),
		},
		{
			accessorKey: "preferredWeapon",
			header: "Weapons",
			cell: ({ row }) =>
				renderComponent(MemberWeapons, {
					weapons: row.original.preferredWeapon,
				}),
		},
		{
			accessorKey: "membershipStartDate",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Member since",
					class: "-ml-2 h-9 px-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ row }) =>
				renderComponent(MemberDateCell, {
					date: row.original.membershipStartDate,
					emptyLabel: "Never",
				}),
		},
		{
			accessorKey: "lastPaymentDate",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Last payment",
					class: "-ml-2 h-9 px-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ row }) =>
				renderComponent(MemberDateCell, {
					date: row.original.lastPaymentDate,
					emptyLabel: "Never",
				}),
		},
		{
			id: "actions",
			header: "Actions",
			cell: ({ row }) =>
				renderComponent(MemberActions, {
					memberId: row.original.id,
					isExpanded: row.getIsExpanded(),
					onToggleExpand: () => row.toggleExpanded(),
					canReactivate,
					membershipStatus: row.original.membershipStatus,
					onReactivate: () => openReactivation(row.original.id),
				}),
		},
	],
	get data() {
		return membersQuery.data?.data ?? [];
	},
	onSortingChange: membersUrl.table.onSortingChange,
	getRowId: (row) => row.id,
	state: {
		get expanded() {
			return expandedState;
		},
		get sorting() {
			return membersUrl.table.state.sorting;
		},
	},
	onExpandedChange: (updater) => {
		expandedState =
			updater instanceof Function ? updater(expandedState) : updater;
	},
	getCoreRowModel: getCoreRowModel(),
	getSortedRowModel: getSortedRowModel(),
});

const table = createSvelteTable(tableOptions);
</script>

{#snippet emptyState()}
	<div class="flex flex-col items-center justify-center px-6 py-12 text-center">
		<div
			class="flex size-12 items-center justify-center rounded-2xl bg-primary/10 text-primary"
		>
			<Users class="size-6" aria-hidden="true" />
		</div>
		<h3 class="mt-4 font-heading text-xl text-foreground">No members found</h3>
		<p class="mt-1 max-w-sm text-sm leading-6 text-muted-foreground">
			{hasActiveFilters
				? "Try changing your search or status filters."
				: "Member records will appear here once they have been added."}
		</p>
		{#if hasActiveFilters}
			<Button variant="outline" class="mt-4" onclick={resetFilters}>
				<RotateCcw class="size-4" aria-hidden="true" />
				Reset filters
			</Button>
		{/if}
	</div>
{/snippet}

<section
	aria-labelledby="member-directory-title"
	aria-busy={membersQuery.isFetching}
	class="overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
>
	<header class="border-b border-border bg-muted/20 p-4 sm:p-5">
		<div class="flex flex-wrap items-start justify-between gap-3">
			<div>
				<h2
					id="member-directory-title"
					class="font-heading text-2xl text-foreground"
				>
					Member directory
				</h2>
				<p class="mt-1 text-sm text-muted-foreground">
					{membersQuery.data?.count ?? 0}
					{membersQuery.data?.count === 1 ? "member" : "members"}
				</p>
			</div>
			{#if membersQuery.isFetching}
				<div
					class="flex min-h-11 items-center gap-2 text-sm font-medium text-muted-foreground"
					role="status"
					aria-live="polite"
				>
					<LoaderCircle />
					<span class="sr-only sm:not-sr-only">Updating members</span>
				</div>
			{/if}
		</div>

		<div
			class="mt-5 grid gap-4 xl:grid-cols-[minmax(20rem,1fr)_auto] xl:items-end"
		>
			<form class="grid gap-2" onsubmit={onSearchSubmit}>
				<label
					for="member-search"
					class="text-sm font-semibold text-foreground"
				>
					Search members
				</label>
				<div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2">
					<div class="relative">
						<Search
							class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
							aria-hidden="true"
						/>
						<Input
							id="member-search"
							name="q"
							type="search"
							value={membersUrl.search}
							oninput={(event) =>
								membersUrl.setSearch(event.currentTarget.value)}
							placeholder="Name, email, or phone"
							class="h-11 pl-10 pr-11"
							autocomplete="off"
						/>
						{#if membersUrl.search}
							<Button
								variant="ghost"
								size="icon"
								type="button"
								class="absolute right-0 top-0"
								aria-label="Clear search"
								onclick={() => {
									membersUrl.setSearch("");
									membersUrl.submitSearch();
								}}
							>
								<X class="size-4" aria-hidden="true" />
							</Button>
						{/if}
					</div>
					<Button type="submit" variant="outline">
						<Search class="size-4 sm:hidden" aria-hidden="true" />
						<span class="hidden sm:inline">Search</span>
						<span class="sr-only sm:hidden">Search members</span>
					</Button>
				</div>
			</form>

			<fieldset class="grid gap-2">
				<legend class="text-sm font-semibold text-foreground"
					>Membership status</legend
				>
				<div class="flex flex-wrap gap-2">
					<ToggleGroup
						type="multiple"
						variant="outline"
						value={statusFilterValue}
						onValueChange={onStatusFilterChange}
						aria-label="Membership status"
						class="flex-wrap gap-2 shadow-none"
					>
						<ToggleGroupItem
							value={ALL_STATUSES}
							class="min-h-11 flex-none rounded-lg border-l px-3.5 font-semibold shadow-none first:rounded-lg last:rounded-lg data-[variant=outline]:border-l data-[state=on]:border-primary data-[state=on]:bg-primary data-[state=on]:text-primary-foreground data-[state=on]:hover:bg-primary/90 data-[state=on]:hover:text-primary-foreground"
							>All</ToggleGroupItem
						>
						{#each statusOptions as status (status)}
							<ToggleGroupItem
								value={status}
								class="min-h-11 flex-none rounded-lg border-l px-3.5 font-semibold shadow-none first:rounded-lg last:rounded-lg data-[variant=outline]:border-l data-[state=on]:border-primary data-[state=on]:bg-primary data-[state=on]:text-primary-foreground data-[state=on]:hover:bg-primary/90 data-[state=on]:hover:text-primary-foreground capitalize"
							>
								{status}
							</ToggleGroupItem>
						{/each}
					</ToggleGroup>
					{#if hasActiveFilters}
						<Button
							variant="ghost"
							size="sm"
							type="button"
							class="min-h-11"
							onclick={resetFilters}
						>
							<RotateCcw class="size-4" aria-hidden="true" />
							Reset
						</Button>
					{/if}
				</div>
			</fieldset>
		</div>
	</header>

	{#if membersQuery.isError}
		<div
			class="flex flex-col items-center justify-center px-6 py-14 text-center"
			role="alert"
		>
			<h3 class="font-heading text-xl text-foreground">
				Members could not be loaded
			</h3>
			<p class="mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				Check your connection and try again. Your filters have been kept.
			</p>
			<Button class="mt-4" onclick={() => membersQuery.refetch()}
				>Try again</Button
			>
		</div>
	{:else if membersQuery.isPending}
		<div class="flex min-h-72 items-center justify-center" role="status">
			<LoaderCircle />
			<span class="sr-only">Loading members</span>
		</div>
	{:else}
		<!-- A compact data table preserves scan speed on larger screens. -->
		<div data-testid="members-table" class="hidden overflow-x-auto lg:block">
			<Table.Root class="min-w-[900px]">
				<Table.Caption class="sr-only">
					Member directory. Sortable columns include member name, member since,
					and last payment.
				</Table.Caption>
				<Table.Header class="bg-muted/50">
					{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
						<Table.Row class="hover:bg-transparent">
							{#each headerGroup.headers as header (header.id)}
								{@const sortDirection = header.column.getIsSorted()}
								<Table.Head
									scope="col"
									aria-sort={sortDirection === "asc"
										? "ascending"
										: sortDirection === "desc"
											? "descending"
											: undefined}
									class={cn(
										"px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground",
										header.column.id === "actions" && "text-right",
									)}
								>
									<FlexRender
										content={header.column.columnDef.header}
										context={header.getContext()}
									/>
								</Table.Head>
							{/each}
						</Table.Row>
					{/each}
				</Table.Header>
				<Table.Body>
					{#each table.getRowModel().rows as row (row.id)}
						<Table.Row class="group">
							{#each row.getVisibleCells() as cell (cell.id)}
								<Table.Cell
									class={cn(
										"px-4 py-3.5",
										cell.column.id === "lastName" && "min-w-64",
										cell.column.id === "actions" && "text-right",
									)}
								>
									<FlexRender
										content={cell.column.columnDef.cell}
										context={cell.getContext()}
									/>
								</Table.Cell>
							{/each}
						</Table.Row>
						{#if row.getIsExpanded()}
							<Table.Row>
								<Table.Cell
									colspan={row.getVisibleCells().length}
									class="bg-muted/20 p-4"
								>
									<MemberDetails member={row.original} />
								</Table.Cell>
							</Table.Row>
						{/if}
					{:else}
						<Table.Row>
							<Table.Cell colspan={table.getAllColumns().length} class="p-0">
								{@render emptyState()}
							</Table.Cell>
						</Table.Row>
					{/each}
				</Table.Body>
			</Table.Root>
		</div>

		<!-- Mobile and tablet cards reveal secondary data only on request. -->
		<div
			class="divide-y divide-border lg:hidden"
			data-testid="members-card-list"
		>
			{#each table.getRowModel().rows as row (row.id)}
				<article class="p-4 sm:p-5">
					<div class="flex items-start justify-between gap-3">
						<MemberIdentityCell member={row.original} />
						<MemberStatusBadge status={row.original.membershipStatus} />
					</div>

					<div
						class="mt-4 grid gap-3 rounded-xl bg-muted/35 p-3 sm:grid-cols-2"
					>
						<div>
							<p
								class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
							>
								Phone
							</p>
							<div class="mt-1">
								<MemberPhoneCell phone={row.original.phoneNumber} />
							</div>
						</div>
						<div>
							<p
								class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
							>
								Member since
							</p>
							<div class="mt-1">
								<MemberDateCell
									date={row.original.membershipStartDate}
									emptyLabel="Never"
								/>
							</div>
						</div>
						{#if row.original.preferredWeapon.length > 0}
							<div class="sm:col-span-2">
								<p
									class="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground"
								>
									Weapons
								</p>
								<MemberWeapons weapons={row.original.preferredWeapon} />
							</div>
						{/if}
					</div>

					<div class="mt-4">
						<MemberActions
							memberId={row.original.id}
							isExpanded={row.getIsExpanded()}
							onToggleExpand={() => row.toggleExpanded()}
							showLabels
							{canReactivate}
							membershipStatus={row.original.membershipStatus}
							onReactivate={() => openReactivation(row.original.id)}
						/>
					</div>

					{#if row.getIsExpanded()}
						<div class="mt-4 border-t border-border pt-4">
							<MemberDetails member={row.original} />
						</div>
					{/if}
				</article>
			{:else}
				{@render emptyState()}
			{/each}
		</div>
	{/if}

	{#if !membersQuery.isError}
		<footer
			class="flex flex-col gap-4 border-t border-border bg-muted/20 p-4 sm:flex-row sm:items-center sm:justify-between"
		>
			<div
				class="flex flex-wrap items-center justify-between gap-3 sm:justify-start"
			>
				<p class="text-sm text-muted-foreground">
					<span class="font-semibold text-foreground">
						{table.getRowModel().rows.length}
					</span>
					shown of
					<span class="font-semibold text-foreground">
						{membersQuery.data?.count ?? 0}
					</span>
				</p>
				<div class="flex items-center gap-2">
					<span
						id="members-page-size-label"
						class="text-sm text-muted-foreground"
					>
						Rows
					</span>
					<Select.Root
						type="single"
						value={membersUrl.pageSize.toString()}
						onValueChange={(value) => membersUrl.setPageSize(Number(value))}
					>
						<Select.Trigger
							class="h-11 w-20"
							aria-labelledby="members-page-size-label"
						>
							{membersUrl.pageSize}
						</Select.Trigger>
						<Select.Content>
							{#each pageSizeOptions as pageSizeOption (pageSizeOption)}
								<Select.Item value={pageSizeOption.toString()}>
									{pageSizeOption}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
			</div>

			<nav class="grid grid-cols-2 gap-2" aria-label="Member directory pages">
				<Button
					variant="outline"
					disabled={!membersQuery.data?.previousCursor ||
						membersQuery.isFetching}
					onclick={() => membersUrl.goTo(membersQuery.data?.previousCursor)}
				>
					<ChevronLeft class="size-4" aria-hidden="true" />
					Previous
				</Button>
				<Button
					variant="outline"
					disabled={!membersQuery.data?.nextCursor || membersQuery.isFetching}
					onclick={() => membersUrl.goTo(membersQuery.data?.nextCursor)}
				>
					Next
					<ChevronRight class="size-4" aria-hidden="true" />
				</Button>
			</nav>
		</footer>
	{/if}
</section>

{#if reactivateTargetId}
	<ReactivateMemberDialog
		bind:open={reactivateOpen}
		memberId={reactivateTargetId}
		onSettled={() => {
			void membersQuery.refetch();
		}}
	/>
{/if}
