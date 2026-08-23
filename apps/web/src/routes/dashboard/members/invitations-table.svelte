<script lang="ts">
import {
	type Invitation,
	type InvitationListSortField,
	invitationsDeleteMutation,
	invitationsListOptions,
	invitationsResendMutation,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	keepPreviousData,
} from "@tanstack/svelte-query";
import dayjs from "dayjs";
import {
	ArrowDown,
	ArrowUp,
	ChevronLeft,
	ChevronRight,
	Mail,
	RotateCcw,
	Search,
	Send,
	Trash2,
	X,
} from "@lucide/svelte";
import { SvelteSet } from "svelte/reactivity";
import { toast } from "svelte-sonner";
import { goto } from "$app/navigation";
import { page } from "$app/state";
import { Badge, type BadgeVariant } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import * as Select from "$lib/components/ui/select";
import * as Table from "$lib/components/ui/table/index.js";
import SortHeader from "$lib/components/ui/table/sort-header.svelte";
import {
	isPageSize,
	PAGE_SIZE_OPTIONS,
	parsePageSize,
	transitionCursorQuery,
} from "$lib/cursor-query";
import { cn } from "$lib/utils";
import { getInvitationLink } from "$lib/utils/invitation";
import InvitationActions from "./invitation-actions.svelte";
import InvitationSelectionCheckbox from "./invitation-selection-checkbox.svelte";

const pageSizeOptions = PAGE_SIZE_OPTIONS;
const invitationSortFields = [
	"email",
	"status",
	"expires_at",
	"created_at",
] as const;
const sortOptions = [
	{ value: "created_at", label: "Sent date" },
	{ value: "expires_at", label: "Expiry date" },
	{ value: "email", label: "Email" },
	{ value: "status", label: "Status" },
] as const;

type InvitationTableSortField = (typeof invitationSortFields)[number];
type SortDirection = "asc" | "desc";
type InvitationTableRow = {
	id: string;
	email: string;
	status: Invitation["status"];
	pricing_tier: Invitation["pricingTier"];
	expires_at: string;
	created_at: string;
};
type InvitationTablePage = {
	data: InvitationTableRow[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};
type InvitationTableQueryParams = {
	pageSize: (typeof pageSizeOptions)[number];
	searchQuery: string;
	sort: InvitationTableSortField;
	direction: SortDirection;
	cursor: string | null;
};

const invitationSortMap = {
	email: "email",
	status: "status",
	expires_at: "expiresAt",
	created_at: "createdAt",
} satisfies Record<InvitationTableSortField, InvitationListSortField>;

function isInvitationSortField(
	value: string | null | undefined,
): value is InvitationTableSortField {
	return invitationSortFields.some((field) => field === value);
}

function navigateToInvitations(
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

const pageSize = $derived(
	parsePageSize(page.url.searchParams, "invitePageSize"),
);
const searchQuery = $derived(page.url.searchParams.get("inviteQ") || "");
const cursor = $derived(page.url.searchParams.get("inviteCursor"));
const activeSort = $derived.by(() => {
	const requestedSortColumn = page.url.searchParams.get("inviteSort");
	const sortColumn = isInvitationSortField(requestedSortColumn)
		? requestedSortColumn
		: "created_at";
	const sortDirection = page.url.searchParams.get("inviteDirection");

	return {
		sort: sortColumn,
		direction: sortDirection === "asc" ? "asc" : "desc",
	} as const;
});
const invitationsQueryParams = $derived<InvitationTableQueryParams>({
	pageSize,
	searchQuery,
	sort: activeSort.sort,
	direction: activeSort.direction,
	cursor,
});

let searchDraft = $derived(searchQuery);
const selectedRows = new SvelteSet<string>();

function toTableRow(invitation: Invitation): InvitationTableRow {
	return {
		id: invitation.id,
		email: invitation.email,
		status: invitation.status,
		pricing_tier: invitation.pricingTier,
		expires_at: invitation.expiresAt,
		created_at: invitation.createdAt,
	};
}

function discountBadgeLabel(tier: Invitation["pricingTier"]): string | null {
	if (tier === "coach") return "Coach discount";
	if (tier === "student") return "Student discount";
	return null;
}

const invitationsQuery = createQuery(() => ({
	...invitationsListOptions({
		query: {
			limit: invitationsQueryParams.pageSize,
			cursor: invitationsQueryParams.cursor ?? undefined,
			q: invitationsQueryParams.searchQuery || undefined,
			sort: invitationSortMap[invitationsQueryParams.sort],
			direction: invitationsQueryParams.direction,
		},
	}),
	placeholderData: keepPreviousData,
	select: (response): InvitationTablePage => {
		const result = response.data;
		return {
			data: result.invitations.map(toTableRow),
			count: result.totalCount,
			nextCursor: result.nextCursor,
			previousCursor: result.previousCursor,
		};
	},
}));

const invitations = $derived(invitationsQuery.data?.data ?? []);
const invitationIds = $derived(invitations.map((invitation) => invitation.id));
const selectedRowsArray = $derived(Array.from(selectedRows));
const allInvitationsSelected = $derived(
	invitationIds.length > 0 &&
		invitationIds.every((invitationId) => selectedRows.has(invitationId)),
);
const someInvitationsSelected = $derived(
	!allInvitationsSelected &&
		invitationIds.some((invitationId) => selectedRows.has(invitationId)),
);

function clearSelection() {
	selectedRows.clear();
}

function setInvitationSelected(invitationId: string, selected: boolean) {
	if (selected) selectedRows.add(invitationId);
	else selectedRows.delete(invitationId);
}

function setAllInvitationsSelected(selected: boolean) {
	for (const invitationId of invitationIds) {
		if (selected) selectedRows.add(invitationId);
		else selectedRows.delete(invitationId);
	}
}

function onPaginationChange(newPageSize: number) {
	if (!isPageSize(newPageSize)) return;
	clearSelection();
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "inviteCursor",
		updates: { invitePageSize: newPageSize.toString() },
	});
	navigateToInvitations(newParams, { replaceState: true });
}

function onCursorChange(newCursor: string | null | undefined) {
	if (!newCursor) return;
	clearSelection();
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "inviteCursor",
		cursor: newCursor,
	});
	navigateToInvitations(newParams);
}

function onSortingChange(
	sort: InvitationTableSortField,
	direction: SortDirection,
) {
	clearSelection();
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "inviteCursor",
		updates: { inviteSort: sort, inviteDirection: direction },
	});
	navigateToInvitations(newParams, { replaceState: true });
}

function toggleSort(sort: InvitationTableSortField) {
	const direction =
		activeSort.sort === sort && activeSort.direction === "asc" ? "desc" : "asc";
	onSortingChange(sort, direction);
}

function sortDirectionFor(
	sort: InvitationTableSortField,
): SortDirection | false {
	return activeSort.sort === sort ? activeSort.direction : false;
}

function onSearchChange(newSearch: string) {
	clearSelection();
	const normalizedSearch = newSearch.trim();
	const newParams = transitionCursorQuery(page.url.searchParams, {
		cursorKey: "inviteCursor",
		updates: { inviteQ: normalizedSearch || null },
	});
	navigateToInvitations(newParams, { replaceState: true });
}

function onSearchSubmit(event: SubmitEvent) {
	event.preventDefault();
	onSearchChange(searchDraft);
}

function resetSearch() {
	searchDraft = "";
	onSearchChange("");
}

const resendInvitation = createMutation(() => ({
	...invitationsResendMutation(),
	onSuccess: () => toast.success("Invitation email resent"),
	onError: () => toast.error("Failed to resend invitation email"),
}));

const resendSelectedInvitations = createMutation(() => ({
	...invitationsResendMutation(),
	onSuccess: () => {
		toast.success("Selected invitation emails resent");
		clearSelection();
	},
	onError: () => toast.error("Failed to resend selected invitations"),
}));

const deleteInvitations = createMutation(() => ({
	...invitationsDeleteMutation(),
	onSuccess: () => {
		toast.success("Invitation deleted");
		clearSelection();
		void invitationsQuery.refetch();
	},
	onError: () => toast.error("Failed to delete invitation"),
}));

function resendSelected() {
	const emails = invitations
		.filter((invitation) => selectedRows.has(invitation.id))
		.map((invitation) => invitation.email);
	if (emails.length === 0) return;
	resendSelectedInvitations.mutate({ body: { emails } });
}

function deleteSelected() {
	if (selectedRowsArray.length === 0) return;
	deleteInvitations.mutate({
		body: { invitationIds: selectedRowsArray },
	});
}

function formatDate(value: string): string {
	return dayjs(value).isValid() ? dayjs(value).format("D MMM YYYY") : "Unknown";
}

function statusVariant(status: Invitation["status"]): BadgeVariant {
	if (status === "accepted") return "secondary";
	if (status === "expired") return "destructive";
	if (status === "revoked") return "outline";
	return "default";
}
</script>

{#snippet statusBadge(status: Invitation["status"])}
	<Badge variant={statusVariant(status)} class="capitalize">{status}</Badge>
{/snippet}

{#snippet discountBadge(tier: Invitation["pricingTier"])}
	{@const label = discountBadgeLabel(tier)}
	{#if label}
		<Badge variant="outline">{label}</Badge>
	{/if}
{/snippet}

{#snippet expirationDate(value: string)}
	{@const expired = dayjs(value).isBefore(dayjs())}
	<span class={cn("text-sm tabular-nums", expired && "text-destructive")}>
		{#if expired}<span class="font-semibold">Expired </span>{/if}
		<time datetime={value}>{formatDate(value)}</time>
	</span>
{/snippet}

{#snippet emptyState()}
	<div class="flex flex-col items-center justify-center px-6 py-12 text-center">
		<div
			class="flex size-12 items-center justify-center rounded-2xl bg-primary/10 text-primary"
		>
			<Mail class="size-6" aria-hidden="true" />
		</div>
		<h3 class="mt-4 font-heading text-xl text-foreground">
			No invitations found
		</h3>
		<p class="mt-1 max-w-sm text-sm leading-6 text-muted-foreground">
			{searchQuery
				? "Try a different email address or clear your search."
				: "Sent invitations will appear here so you can track and manage them."}
		</p>
		{#if searchQuery}
			<Button variant="outline" class="mt-4 min-h-11" onclick={resetSearch}>
				<RotateCcw class="size-4" aria-hidden="true" />
				Clear search
			</Button>
		{/if}
	</div>
{/snippet}

<section
	aria-labelledby="invitation-activity-title"
	aria-busy={invitationsQuery.isFetching}
	class="overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)]"
>
	<header class="border-b border-border bg-muted/20 p-4 sm:p-5">
		<div class="flex flex-wrap items-start justify-between gap-3">
			<div>
				<h2
					id="invitation-activity-title"
					class="font-heading text-2xl text-foreground"
				>
					Invitation activity
				</h2>
				<p class="mt-1 text-sm text-muted-foreground">
					{invitationsQuery.data?.count ?? 0}
					{invitationsQuery.data?.count === 1 ? "invitation" : "invitations"}
				</p>
			</div>
			{#if invitationsQuery.isFetching}
				<div
					class="flex min-h-11 items-center gap-2 text-sm font-medium text-muted-foreground"
					role="status"
					aria-live="polite"
				>
					<LoaderCircle />
					<span class="sr-only sm:not-sr-only">Updating invitations</span>
				</div>
			{/if}
		</div>

		<div
			class="mt-5 grid gap-4 xl:grid-cols-[minmax(20rem,1fr)_auto] xl:items-end"
		>
			<form class="grid gap-2" onsubmit={onSearchSubmit}>
				<label
					for="invitation-search"
					class="text-sm font-semibold text-foreground"
				>
					Search invitations
				</label>
				<div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2">
					<div class="relative">
						<Search
							class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
							aria-hidden="true"
						/>
						<Input
							id="invitation-search"
							name="inviteQ"
							type="search"
							bind:value={searchDraft}
							placeholder="Email address"
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
								onclick={resetSearch}
							>
								<X class="size-4" aria-hidden="true" />
							</Button>
						{/if}
					</div>
					<Button type="submit" variant="outline">
						<Search class="size-4 sm:hidden" aria-hidden="true" />
						<span class="hidden sm:inline">Search</span>
						<span class="sr-only sm:hidden">Search invitations</span>
					</Button>
				</div>
			</form>

			<div class="grid gap-2">
				<span
					id="invitation-sort-label"
					class="text-sm font-semibold text-foreground"
				>
					Sort invitations
				</span>
				<div class="grid grid-cols-[minmax(0,1fr)_auto] gap-2">
					<Select.Root
						type="single"
						value={activeSort.sort}
						onValueChange={(value) => {
							if (isInvitationSortField(value)) {
								onSortingChange(value, activeSort.direction);
							}
						}}
					>
						<Select.Trigger
							class="min-w-40 data-[size=default]:h-11"
							aria-labelledby="invitation-sort-label"
						>
							{sortOptions.find((option) => option.value === activeSort.sort)
								?.label}
						</Select.Trigger>
						<Select.Content>
							{#each sortOptions as option (option.value)}
								<Select.Item value={option.value}>{option.label}</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
					<Button
						type="button"
						variant="outline"
						class="min-h-11"
						onclick={() =>
							onSortingChange(
								activeSort.sort,
								activeSort.direction === "asc" ? "desc" : "asc",
							)}
					>
						{#if activeSort.direction === "asc"}
							<ArrowUp class="size-4" aria-hidden="true" />
							Ascending
						{:else}
							<ArrowDown class="size-4" aria-hidden="true" />
							Descending
						{/if}
					</Button>
				</div>
			</div>
		</div>

		{#if selectedRows.size > 0}
			<div
				class="mt-4 flex flex-col gap-3 rounded-xl border border-primary/25 bg-primary/5 p-3 sm:flex-row sm:items-center sm:justify-between"
			>
				<p class="text-sm font-semibold text-foreground" aria-live="polite">
					{selectedRows.size}
					{selectedRows.size === 1 ? "invitation" : "invitations"} selected
				</p>
				<div class="grid grid-cols-3 gap-2">
					<Button
						variant="outline"
						size="sm"
						class="min-h-11"
						disabled={resendSelectedInvitations.isPending}
						onclick={resendSelected}
					>
						<Send class="size-4" aria-hidden="true" />
						<span class="hidden sm:inline">
							{resendSelectedInvitations.isPending ? "Sending…" : "Resend"}
						</span>
						<span class="sr-only sm:hidden">Resend selected invitations</span>
					</Button>
					<Button
						variant="destructive"
						size="sm"
						class="min-h-11"
						disabled={deleteInvitations.isPending}
						onclick={deleteSelected}
					>
						<Trash2 class="size-4" aria-hidden="true" />
						<span class="hidden sm:inline">
							{deleteInvitations.isPending ? "Deleting…" : "Delete"}
						</span>
						<span class="sr-only sm:hidden">Delete selected invitations</span>
					</Button>
					<Button
						variant="ghost"
						size="sm"
						class="min-h-11"
						onclick={clearSelection}
					>
						Clear
					</Button>
				</div>
			</div>
		{/if}
	</header>

	{#if invitationsQuery.isError}
		<div
			class="flex flex-col items-center justify-center px-6 py-14 text-center"
			role="alert"
		>
			<h3 class="font-heading text-xl text-foreground">
				Invitations could not be loaded
			</h3>
			<p class="mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				Check your connection and try again. Your search and sort settings have
				been kept.
			</p>
			<Button class="mt-4 min-h-11" onclick={() => invitationsQuery.refetch()}>
				Try again
			</Button>
		</div>
	{:else if invitationsQuery.isPending}
		<div class="flex min-h-72 items-center justify-center" role="status">
			<LoaderCircle />
			<span class="sr-only">Loading invitations</span>
		</div>
	{:else}
		<div
			data-testid="invitations-table"
			class="hidden overflow-x-auto xl:block"
		>
			<Table.Root class="min-w-[860px]">
				<Table.Caption class="sr-only">
					Invitation activity. Sortable columns include email, status, sent
					date, and expiry date.
				</Table.Caption>
				<Table.Header class="bg-muted/50">
					<Table.Row class="hover:bg-transparent">
						<Table.Head scope="col" class="w-14 px-4">
							<InvitationSelectionCheckbox
								checked={allInvitationsSelected}
								indeterminate={someInvitationsSelected}
								label="Select all invitations shown"
								onCheckedChange={(checked: boolean) =>
									setAllInvitationsSelected(checked)}
							/>
						</Table.Head>
						<Table.Head
							scope="col"
							aria-sort={activeSort.sort === "email"
								? activeSort.direction === "asc"
									? "ascending"
									: "descending"
								: undefined}
							class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
						>
							<SortHeader
								header="Email"
								sortDirection={sortDirectionFor("email")}
								class="-ml-2 min-h-11 px-2"
								onclick={() => toggleSort("email")}
							/>
						</Table.Head>
						<Table.Head
							scope="col"
							aria-sort={activeSort.sort === "status"
								? activeSort.direction === "asc"
									? "ascending"
									: "descending"
								: undefined}
							class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
						>
							<SortHeader
								header="Status"
								sortDirection={sortDirectionFor("status")}
								class="-ml-2 min-h-11 px-2"
								onclick={() => toggleSort("status")}
							/>
						</Table.Head>
						<Table.Head
							scope="col"
							aria-sort={activeSort.sort === "created_at"
								? activeSort.direction === "asc"
									? "ascending"
									: "descending"
								: undefined}
							class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
						>
							<SortHeader
								header="Sent"
								sortDirection={sortDirectionFor("created_at")}
								class="-ml-2 min-h-11 px-2"
								onclick={() => toggleSort("created_at")}
							/>
						</Table.Head>
						<Table.Head
							scope="col"
							aria-sort={activeSort.sort === "expires_at"
								? activeSort.direction === "asc"
									? "ascending"
									: "descending"
								: undefined}
							class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
						>
							<SortHeader
								header="Expires"
								sortDirection={sortDirectionFor("expires_at")}
								class="-ml-2 min-h-11 px-2"
								onclick={() => toggleSort("expires_at")}
							/>
						</Table.Head>
						<Table.Head
							scope="col"
							class="px-4 text-right text-xs font-bold uppercase tracking-wide text-muted-foreground"
						>
							Actions
						</Table.Head>
					</Table.Row>
				</Table.Header>
				<Table.Body>
					{#each invitations as invitation (invitation.id)}
						<Table.Row
							data-state={selectedRows.has(invitation.id)
								? "selected"
								: undefined}
						>
							<Table.Cell class="px-4 py-3.5">
								<InvitationSelectionCheckbox
									checked={selectedRows.has(invitation.id)}
									label={`Select invitation for ${invitation.email}`}
									onCheckedChange={(checked: boolean) =>
										setInvitationSelected(invitation.id, checked)}
								/>
							</Table.Cell>
							<Table.Cell
								class="min-w-64 px-4 py-3.5 font-semibold text-foreground"
							>
								{invitation.email}
								{@render discountBadge(invitation.pricing_tier)}
							</Table.Cell>
							<Table.Cell class="px-4 py-3.5">
								{@render statusBadge(invitation.status)}
							</Table.Cell>
							<Table.Cell
								class="px-4 py-3.5 text-sm tabular-nums text-muted-foreground"
							>
								<time datetime={invitation.created_at}>
									{formatDate(invitation.created_at)}
								</time>
							</Table.Cell>
							<Table.Cell class="px-4 py-3.5">
								{@render expirationDate(invitation.expires_at)}
							</Table.Cell>
							<Table.Cell class="px-4 py-3.5 text-right">
								<InvitationActions
									resendInvitation={() =>
										resendInvitation.mutate({
											body: { emails: [invitation.email] },
										})}
									invitationLink={getInvitationLink(
										invitation.id,
										invitation.email,
									)}
									deleteInvitation={() =>
										deleteInvitations.mutate({
											body: { invitationIds: [invitation.id] },
										})}
									isResending={resendInvitation.isPending}
									isDeleting={deleteInvitations.isPending}
								/>
							</Table.Cell>
						</Table.Row>
					{:else}
						<Table.Row>
							<Table.Cell colspan={6} class="p-0">
								{@render emptyState()}
							</Table.Cell>
						</Table.Row>
					{/each}
				</Table.Body>
			</Table.Root>
		</div>

		<div
			data-testid="invitations-card-list"
			class="divide-y divide-border xl:hidden"
		>
			{#each invitations as invitation (invitation.id)}
				<article
					class={cn(
						"p-4 transition-colors duration-200 sm:p-5",
						selectedRows.has(invitation.id) && "bg-primary/5",
					)}
				>
					<div class="flex items-start gap-3">
						<InvitationSelectionCheckbox
							checked={selectedRows.has(invitation.id)}
							label={`Select invitation for ${invitation.email}`}
							onCheckedChange={(checked: boolean) =>
								setInvitationSelected(invitation.id, checked)}
						/>
						<div class="min-w-0 flex-1">
							<p class="break-all font-semibold leading-6 text-foreground">
								{invitation.email}
							</p>
							<div class="mt-2 flex flex-wrap items-center gap-2">
								{@render statusBadge(invitation.status)}
								{@render discountBadge(invitation.pricing_tier)}
							</div>
						</div>
					</div>

					<div class="mt-4 grid grid-cols-2 gap-3 rounded-xl bg-muted/35 p-3">
						<div>
							<p
								class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
							>
								Sent
							</p>
							<time
								datetime={invitation.created_at}
								class="mt-1 block text-sm tabular-nums text-foreground"
							>
								{formatDate(invitation.created_at)}
							</time>
						</div>
						<div>
							<p
								class="text-xs font-semibold uppercase tracking-wide text-muted-foreground"
							>
								Expires
							</p>
							<div class="mt-1">
								{@render expirationDate(invitation.expires_at)}
							</div>
						</div>
					</div>

					<div class="mt-4">
						<InvitationActions
							resendInvitation={() =>
								resendInvitation.mutate({
									body: { emails: [invitation.email] },
								})}
							invitationLink={getInvitationLink(
								invitation.id,
								invitation.email,
							)}
							deleteInvitation={() =>
								deleteInvitations.mutate({
									body: { invitationIds: [invitation.id] },
								})}
							isResending={resendInvitation.isPending}
							isDeleting={deleteInvitations.isPending}
							showLabels
						/>
					</div>
				</article>
			{:else}
				{@render emptyState()}
			{/each}
		</div>
	{/if}

	{#if !invitationsQuery.isError}
		<footer
			class="flex flex-col gap-4 border-t border-border bg-muted/20 p-4 sm:flex-row sm:items-center sm:justify-between"
		>
			<div
				class="flex flex-wrap items-center justify-between gap-3 sm:justify-start"
			>
				<p class="text-sm text-muted-foreground">
					<span class="font-semibold text-foreground">{invitations.length}</span
					>
					shown of
					<span class="font-semibold text-foreground">
						{invitationsQuery.data?.count ?? 0}
					</span>
				</p>
				<div class="flex items-center gap-2">
					<span
						id="invitations-page-size-label"
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
							class="w-20 data-[size=default]:h-11"
							aria-labelledby="invitations-page-size-label"
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

			<nav class="grid grid-cols-2 gap-2" aria-label="Invitation pages">
				<Button
					variant="outline"
					class="min-h-11"
					disabled={!invitationsQuery.data?.previousCursor ||
						invitationsQuery.isFetching}
					onclick={() => onCursorChange(invitationsQuery.data?.previousCursor)}
				>
					<ChevronLeft class="size-4" aria-hidden="true" />
					Previous
				</Button>
				<Button
					variant="outline"
					class="min-h-11"
					disabled={!invitationsQuery.data?.nextCursor ||
						invitationsQuery.isFetching}
					onclick={() => onCursorChange(invitationsQuery.data?.nextCursor)}
				>
					Next
					<ChevronRight class="size-4" aria-hidden="true" />
				</Button>
			</nav>
		</footer>
	{/if}
</section>
