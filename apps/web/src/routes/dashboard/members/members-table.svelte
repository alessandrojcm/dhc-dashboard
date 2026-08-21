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
	type SortingState,
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
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { Button } from "$lib/components/ui/button";
import {
	createSvelteTable,
	FlexRender,
	renderComponent,
} from "$lib/components/ui/data-table/index.js";
import { Input } from "$lib/components/ui/input";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import * as Select from "$lib/components/ui/select";
import * as Table from "$lib/components/ui/table/index.js";
import SortHeader from "$lib/components/ui/table/sort-header.svelte";
import {
	PAGE_SIZE_OPTIONS,
	parsePageSize,
	transitionCursorQuery,
} from "$lib/cursor-query";
import { cn } from "$lib/utils";
import MemberActions from "./member-actions.svelte";
import MemberDateCell from "./member-date-cell.svelte";
import MemberDetails from "./member-details.svelte";
import MemberIdentityCell from "./member-identity-cell.svelte";
import MemberPhoneCell from "./member-phone-cell.svelte";
import MemberStatusBadge from "./member-status-badge.svelte";
import type { MemberStatus, MemberTableRow } from "./member-table.types";
import MemberWeapons from "./member-weapons.svelte";

type MemberTableQueryParams = {
	searchQuery: string;
	sort: MemberTableSortField;
	direction: "asc" | "desc";
	pageSize: (typeof pageSizeOptions)[number];
	membershipStatus: readonly MemberStatus[] | null;
	cursor: string | null;
};

type MemberTablePage = {
	data: MemberTableRow[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};

const pageSizeOptions = PAGE_SIZE_OPTIONS;
const statusOptions = ["active", "paused", "inactive"] as const;

const memberSortFields = [
	"first_name",
	"last_name",
	"email",
	"phone_number",
	"age",
	"membership_start_date",
	"last_payment_date",
	"subscription_paused_until",
	"is_active",
] as const;

type MemberTableSortField = (typeof memberSortFields)[number];

const memberSortMap = {
	first_name: "firstName",
	last_name: "lastName",
	email: "email",
	phone_number: "phoneNumber",
	age: "age",
	membership_start_date: "membershipStartDate",
	last_payment_date: "lastPaymentDate",
	subscription_paused_until: "subscriptionPausedUntil",
	is_active: "isActive",
} satisfies Record<MemberTableSortField, MembersListSortField>;

function navigateToMembers(
	searchParams: URLSearchParams,
	options: { replaceState?: boolean } = {},
) {
	const query = searchParams.toString();
	const url = `${page.url.pathname}${query ? `?${query}` : ""}`;
	void goto(url, {
		keepFocus: true,
		noScroll: true,
		replaceState: options.replaceState,
	});
}

function isMemberSortField(
	value: string | null,
): value is MemberTableSortField {
	return memberSortFields.some((field) => field === value);
}

const pageSize = $derived(parsePageSize(page.url.searchParams, "pageSize"));
const searchQuery = $derived(page.url.searchParams.get("q") || "");
const cursor = $derived(page.url.searchParams.get("cursor"));
const membershipStatusFilter = $derived.by(() => {
	const raw = page.url.searchParams.get("membershipStatus") || "";
	const selected = raw
		.split(",")
		.map((status) => status.trim())
		.filter(
			(status): status is MemberStatus =>
				status === "active" || status === "inactive" || status === "paused",
		);

	if (selected.length === 0 || selected.length === statusOptions.length) {
		return null;
	}

	return statusOptions.filter((status) => selected.includes(status));
});
const activeSort = $derived.by(() => {
	const requestedSortColumn = page.url.searchParams.get("sort");
	const sortColumn = isMemberSortField(requestedSortColumn)
		? requestedSortColumn
		: "last_name";
	const sortDirection = page.url.searchParams.get("direction");

	return {
		sort: sortColumn,
		direction: sortDirection === "desc" ? "desc" : "asc",
	} as const;
});
const sortingState: SortingState = $derived([
	{
		id: activeSort.sort,
		desc: activeSort.direction === "desc",
	},
]);
const hasActiveFilters = $derived(
	searchQuery !== "" || membershipStatusFilter !== null,
);

let searchDraft = $derived(searchQuery);
let expandedState = $state({});

const membersQueryParams = $derived<MemberTableQueryParams>({
	searchQuery,
	sort: activeSort.sort,
	direction: activeSort.direction,
	pageSize,
	membershipStatus: membershipStatusFilter,
	cursor,
});

function toTableRow(member: Member): MemberTableRow {
	return {
		id: member.id,
		first_name: member.firstName,
		last_name: member.lastName,
		email: member.email,
		phone_number: member.phoneNumber,
		gender: member.gender,
		pronouns: member.pronouns,
		is_active: member.isActive,
		preferred_weapon: member.preferredWeapon,
		membership_start_date: member.membershipStartDate,
		membership_end_date: member.membershipEndDate,
		last_payment_date: member.lastPaymentDate,
		insurance_form_submitted: member.insuranceFormSubmitted,
		age: member.age,
		social_media_consent: member.socialMediaConsent,
		next_of_kin_name: member.nextOfKinName,
		next_of_kin_phone: member.nextOfKinPhone,
		guardian_first_name: member.guardianFirstName,
		guardian_last_name: member.guardianLastName,
		guardian_phone_number: member.guardianPhoneNumber,
		medical_conditions: member.medicalConditions,
		subscription_paused_until: member.subscriptionPausedUntil,
		membership_status: member.membershipStatus,
	};
}

const membersQuery = createQuery(() => ({
	...membersListOptions({
		query: {
			limit: membersQueryParams.pageSize,
			cursor: membersQueryParams.cursor ?? undefined,
			q: membersQueryParams.searchQuery || undefined,
			membershipStatus:
				membersQueryParams.membershipStatus &&
				membersQueryParams.membershipStatus.length > 0
					? membersQueryParams.membershipStatus.join(",")
					: undefined,
			sort: memberSortMap[membersQueryParams.sort],
			direction: membersQueryParams.direction,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response): MemberTablePage => {
		const result = response.data;
		return {
			data: result.members.map(toTableRow),
			count: result.totalCount,
			nextCursor: result.nextCursor,
			previousCursor: result.previousCursor,
		};
	},
}));

function onPaginationChange(newPageSize: number) {
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		updates: { pageSize: newPageSize.toString() },
	});
	navigateToMembers(newParams, { replaceState: true });
}

function onCursorChange(newCursor: string | null | undefined) {
	if (!newCursor) return;
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		cursor: newCursor,
	});
	navigateToMembers(newParams);
}

function onSortingChange(newSorting: SortingState) {
	const [nextSorting] = newSorting;
	if (!nextSorting) return;
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		updates: {
			sort: nextSorting.id,
			direction: nextSorting.desc ? "desc" : "asc",
		},
	});
	navigateToMembers(newParams, { replaceState: true });
}

function onSearchChange(newSearch: string) {
	const normalizedSearch = newSearch.trim();
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		updates: { q: normalizedSearch || null },
	});
	navigateToMembers(newParams, { replaceState: true });
}

function onSearchSubmit(event: SubmitEvent) {
	event.preventDefault();
	onSearchChange(searchDraft);
}

function onStatusFilterChange(status: MemberStatus | null) {
	let membershipStatus: string | null;

	if (status === null) {
		membershipStatus = null;
	} else {
		const current = membershipStatusFilter ?? [];
		const next = current.includes(status)
			? current.filter((value) => value !== status)
			: [...current, status];

		if (next.length === 0 || next.length === statusOptions.length) {
			membershipStatus = null;
		} else {
			membershipStatus = statusOptions
				.filter((value) => next.includes(value))
				.join(",");
		}
	}

	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		updates: { membershipStatus },
	});
	navigateToMembers(newParams, { replaceState: true });
}

function resetFilters() {
	searchDraft = "";
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "cursor",
		updates: { q: null, membershipStatus: null },
	});
	navigateToMembers(newParams, { replaceState: true });
}

const tableOptions = $state<TableOptions<MemberTableRow>>({
	autoResetPageIndex: false,
	manualPagination: true,
	manualSorting: true,
	getExpandedRowModel: getExpandedRowModel(),
	columns: [
		{
			id: "last_name",
			accessorKey: "last_name",
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
			accessorKey: "membership_status",
			header: "Status",
			cell: ({ row }) =>
				renderComponent(MemberStatusBadge, {
					status: row.original.membership_status,
				}),
		},
		{
			accessorKey: "phone_number",
			header: "Phone",
			cell: ({ row }) =>
				renderComponent(MemberPhoneCell, {
					phone: row.original.phone_number,
				}),
		},
		{
			accessorKey: "preferred_weapon",
			header: "Weapons",
			cell: ({ row }) =>
				renderComponent(MemberWeapons, {
					weapons: row.original.preferred_weapon,
				}),
		},
		{
			accessorKey: "membership_start_date",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Member since",
					class: "-ml-2 h-9 px-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ row }) =>
				renderComponent(MemberDateCell, {
					date: row.original.membership_start_date,
					emptyLabel: "Never",
				}),
		},
		{
			accessorKey: "last_payment_date",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Last payment",
					class: "-ml-2 h-9 px-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ row }) =>
				renderComponent(MemberDateCell, {
					date: row.original.last_payment_date,
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
				}),
		},
	],
	get data() {
		return membersQuery.data?.data ?? [];
	},
	onSortingChange: (updater) => {
		onSortingChange(
			updater instanceof Function ? updater(sortingState) : updater,
		);
	},
	getRowId: (row) => row.id,
	state: {
		get expanded() {
			return expandedState;
		},
		get sorting() {
			return sortingState;
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
							bind:value={searchDraft}
							placeholder="Name, email, or phone"
							class="h-11 pl-10 pr-11"
							autocomplete="off"
						/>
						{#if searchDraft}
							<Button
								variant="ghost"
								size="icon"
								type="button"
								class="absolute right-0 top-0"
								aria-label="Clear search"
								onclick={() => {
									searchDraft = "";
									onSearchChange("");
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
					<Button
						variant="outline"
						size="sm"
						type="button"
						aria-pressed={membershipStatusFilter === null}
						class={cn(
							"min-h-11 shadow-none",
							membershipStatusFilter === null &&
								"border-primary bg-primary text-primary-foreground hover:bg-primary/90 hover:text-primary-foreground",
						)}
						onclick={() => onStatusFilterChange(null)}
					>
						All
					</Button>
					{#each statusOptions as status (status)}
						{@const selected =
							membershipStatusFilter?.includes(status) ?? false}
						<Button
							variant="outline"
							size="sm"
							type="button"
							aria-pressed={selected}
							class={cn(
								"min-h-11 capitalize shadow-none",
								selected &&
									"border-primary bg-primary text-primary-foreground hover:bg-primary/90 hover:text-primary-foreground",
							)}
							onclick={() => onStatusFilterChange(status)}
						>
							{status}
						</Button>
					{/each}
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
										cell.column.id === "last_name" && "min-w-64",
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
						<MemberStatusBadge status={row.original.membership_status} />
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
								<MemberPhoneCell phone={row.original.phone_number} />
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
									date={row.original.membership_start_date}
									emptyLabel="Never"
								/>
							</div>
						</div>
						{#if row.original.preferred_weapon.length > 0}
							<div class="sm:col-span-2">
								<p
									class="mb-1 text-xs font-semibold uppercase tracking-wide text-muted-foreground"
								>
									Weapons
								</p>
								<MemberWeapons weapons={row.original.preferred_weapon} />
							</div>
						{/if}
					</div>

					<div class="mt-4">
						<MemberActions
							memberId={row.original.id}
							isExpanded={row.getIsExpanded()}
							onToggleExpand={() => row.toggleExpanded()}
							showLabels
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
						value={pageSize.toString()}
						onValueChange={(value) => onPaginationChange(Number(value))}
					>
						<Select.Trigger
							class="h-11 w-20"
							aria-labelledby="members-page-size-label"
						>
							{pageSize}
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
					onclick={() => onCursorChange(membersQuery.data?.previousCursor)}
				>
					<ChevronLeft class="size-4" aria-hidden="true" />
					Previous
				</Button>
				<Button
					variant="outline"
					disabled={!membersQuery.data?.nextCursor || membersQuery.isFetching}
					onclick={() => onCursorChange(membersQuery.data?.nextCursor)}
				>
					Next
					<ChevronRight class="size-4" aria-hidden="true" />
				</Button>
			</nav>
		</footer>
	{/if}
</section>
