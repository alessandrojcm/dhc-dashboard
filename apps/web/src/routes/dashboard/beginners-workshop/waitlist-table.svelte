<script lang="ts">
import type { WaitlistEntry } from "@dhc/api-client";
import {
	getCoreRowModel,
	getExpandedRowModel,
	getPaginationRowModel,
	getSortedRowModel,
	type TableOptions,
} from "@tanstack/table-core";
import dayjs from "dayjs";
import { LoaderCircle, Search, X } from "@lucide/svelte";
import { createRawSnippet } from "svelte";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import {
	createSvelteTable,
	FlexRender,
	renderComponent,
	renderSnippet,
} from "#lib/components/ui/data-table/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import * as Empty from "#lib/components/ui/empty/index.js";
import * as Select from "#lib/components/ui/select/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import SortHeader from "#lib/components/ui/table/sort-header.svelte";
import {
	ToggleGroup,
	ToggleGroupItem,
} from "#lib/components/ui/toggle-group/index.js";
import { PAGE_SIZE_OPTIONS } from "#lib/cursor-query.js";
import { personScope } from "#lib/beginners-workshops/refunds/scope.js";
import DeleteDialog from "#lib/components/beginners-workshops/refunds/delete-dialog.svelte";
import WithdrawDialog from "#lib/components/beginners-workshops/refunds/withdraw-dialog.svelte";
import ActionButtons from "./actions-buttons.svelte";
import WaitlistEntryDetails from "./waitlist-entry-details.svelte";
import WaitlistStatusBadge from "./waitlist-status-badge.svelte";
import {
	createWaitlistTable,
	WAITLIST_STANDINGS,
	type WaitlistStanding,
	type WaitlistTableDeps,
} from "./waitlist-table.svelte.js";

let { deps }: { deps?: WaitlistTableDeps } = $props();

// The deps are fixed for the table's lifetime.
// svelte-ignore state_referenced_locally
const waitlist = createWaitlistTable(deps);
const waitlistUrl = waitlist.url;

// State for expanded rows
let expandedState = $state({});

// ALE-387: the person the Withdraw dialog is for.
let withdrawing = $state<WaitlistEntry | null>(null);
let withdrawOpen = $state(false);

function openWithdraw(entry: WaitlistEntry) {
	withdrawing = entry;
	withdrawOpen = true;
}

// ALE-396: the person the Delete dialog is for.
let deleting = $state<WaitlistEntry | null>(null);
let deleteOpen = $state(false);

function openDelete(entry: WaitlistEntry) {
	deleting = entry;
	deleteOpen = true;
}

const standingLabel = $derived(
	waitlist.standing === "removed" ? "removed" : "waiting",
);

function formatDate(value: string | null | undefined) {
	return value ? dayjs(value).format("DD/MM/YYYY") : "N/A";
}

/**
 * The Status cell: the standing, when a removed person was removed, and
 * whether they hold a Carried Fee (ALE-388).
 */
function statusText(entry: WaitlistEntry) {
	const standing =
		entry.status === "removed"
			? `Removed ${formatDate(entry.removedAt)}`
			: "Waiting";
	return waitlist.carriedFee(entry.id)
		? `${standing} · Workshop credit`
		: standing;
}

const tableOptions = $state<TableOptions<WaitlistEntry>>({
	autoResetPageIndex: false,
	manualPagination: true,
	manualSorting: true,
	getExpandedRowModel: getExpandedRowModel(),
	state: {
		get expanded() {
			return expandedState;
		},
		get pagination() {
			return waitlistUrl.table.state.pagination;
		},
		get sorting() {
			return waitlistUrl.table.state.sorting;
		},
	},
	onExpandedChange: (updater) => {
		if (updater instanceof Function) {
			expandedState = updater(expandedState);
		} else {
			expandedState = updater;
		}
	},
	columns: [
		{
			header: "Actions",
			cell: ({ row }) => {
				return renderComponent(ActionButtons, {
					adminNotes: row.original.adminNotes ?? "N/A",
					isExpanded: row.getIsExpanded(),
					onToggleExpand: () => row.toggleExpanded(),
					onEdit: (adminNotes) =>
						waitlist.updateAdminNotes(row.original.id, adminNotes),
					onRestore: waitlist.offers(row.original, "restore")
						? () => waitlist.restore(row.original.id)
						: undefined,
					restoreDisabled: waitlist.isRestoring,
					onWithdraw: waitlist.offers(row.original, "withdraw")
						? () => openWithdraw(row.original)
						: undefined,
					onDelete: waitlist.offers(row.original, "delete_person")
						? () => openDelete(row.original)
						: undefined,
				});
			},
		},
		{
			accessorKey: "position",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Position",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
		},
		{
			accessorKey: "fullName",
			header: "Full Name",
			footer: ({ table }) =>
				`Total ${table.getRowCount() ?? 0} people ${standingLabel}`,
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () =>
							`<div class="min-w-32 whitespace-normal font-semibold">${value()}</div>`,
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "email",
			header: "Email",
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () =>
							`<a href="mailto:${value()}" class="text-primary underline-offset-4 hover:underline">${value()}</a>`,
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "phoneNumber",
			header: "Phone Number",
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () => `<div class="w-[120px]">${value()}</div>`,
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "socialMediaConsent",
			header: "Social  Consent",
			cell: ({ getValue }) => {
				return renderComponent(Badge, {
					variant:
						getValue() !== "no"
							? getValue() === "yes_recognizable"
								? "default"
								: "secondary"
							: "destructive",
					class: "text-xs",
					children: createRawSnippet(() => ({
						render: () =>
							`<p class="first-letter:capitalize">${getValue().replace("_", ", ")}</p>`,
					})),
				});
			},
		},
		{
			accessorKey: "status",
			header: "Status",
			cell: ({ row }) => {
				return renderComponent(WaitlistStatusBadge, {
					removed: row.original.status === "removed",
					text: () => statusText(row.original),
				});
			},
		},
		{
			accessorKey: "age",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Age",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () => {
							return `<div class="tabular-nums ${value() < 18 ? "font-semibold text-destructive" : ""}">${value() < 18 ? value() + " (under 18)" : value()}</div>`;
						},
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "initialRegistrationDate",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Initial Registration",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet(() => ({
						render: () =>
							`<div class="w-[120px]">${dayjs(getValue()).format("DD/MM/YYYY")}</div>`,
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "lastContacted",
			header: "Last Contacted",
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () => `<div class="w-[120px]">${value()}</div>`,
					})),
					getValue() ?? "N/A",
				);
			},
		},
	],
	get data() {
		return waitlist.entries;
	},
	onPaginationChange: waitlistUrl.table.onPaginationChange,
	onSortingChange: waitlistUrl.table.onSortingChange,
	get rowCount() {
		return waitlist.count;
	},
	getRowId: (row) => row.id,
	getCoreRowModel: getCoreRowModel(),
	getPaginationRowModel: getPaginationRowModel(),
	getSortedRowModel: getSortedRowModel(),
});
const table = createSvelteTable(tableOptions);
</script>

{#snippet emptyState()}
	<Empty.Root>
		<Empty.Header>
			<Empty.Title>No people found</Empty.Title>
			<Empty.Description>
				{waitlistUrl.search
					? "Try a different search or status filter."
					: "People will appear here when they register for the waitlist."}
			</Empty.Description>
		</Empty.Header>
	</Empty.Root>
{/snippet}

<section
	aria-labelledby="waitlist-title"
	aria-busy={waitlist.isFetching}
	class="flex flex-col overflow-hidden rounded-2xl border border-border bg-card shadow-[4px_4px_0_hsl(var(--secondary)/0.35)] lg:h-full lg:min-h-0"
>
	<header class="shrink-0 border-b border-border bg-muted/20 p-4 sm:p-5">
		<div class="flex flex-wrap items-start justify-between gap-3">
			<div>
				<h2 id="waitlist-title" class="font-heading text-2xl text-foreground">
					Waitlist
				</h2>
				<p class="mt-1 text-sm text-muted-foreground">
					{waitlist.count} people {standingLabel}
				</p>
			</div>
			{#if waitlist.isFetching}
				<div
					class="flex min-h-11 items-center gap-2 text-sm font-medium text-muted-foreground"
					role="status"
				>
					<LoaderCircle
						class="size-4 animate-spin motion-reduce:animate-none"
						aria-hidden="true"
					/>
					<span>Updating waitlist</span>
				</div>
			{/if}
		</div>
		<div class="mt-5 grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
			<div class="grid gap-2">
				<Label for="waitlist-search">Search people</Label>
				<div class="relative">
					<Search
						class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-muted-foreground"
						aria-hidden="true"
					/>
					<Input
						id="waitlist-search"
						type="search"
						value={waitlistUrl.search}
						oninput={(
							t: Event & { currentTarget: EventTarget & HTMLInputElement },
						) => waitlistUrl.setSearch(t.currentTarget.value)}
						placeholder="Search for a person"
						class="h-11 w-full pl-10 pr-11"
					/>

					{#if waitlistUrl.search !== ""}
						<Button
							variant="ghost"
							size="icon"
							class="absolute right-0 top-0"
							type="button"
							aria-label="Clear search"
							onclick={() => waitlistUrl.setSearch("")}
						>
							<X class="size-4" aria-hidden="true" />
						</Button>
					{/if}
				</div>
			</div>
			<fieldset class="grid gap-2">
				<legend class="mb-2 text-sm font-semibold text-foreground"
					>Status</legend
				>

				<!-- A single-choice switch; clicking the active item would clear a
	     single ToggleGroup, so an empty value is ignored. -->
				<ToggleGroup
					type="single"
					variant="outline"
					value={waitlist.standing}
					onValueChange={(next) => {
						if (next) waitlist.setStanding(next as WaitlistStanding);
					}}
					aria-label="Waitlist status"
					class="flex-wrap gap-2 shadow-none"
				>
					{#each WAITLIST_STANDINGS as standing (standing.value)}
						<ToggleGroupItem
							value={standing.value}
							class="min-h-11 flex-none rounded-lg border-l px-3.5 font-semibold shadow-none first:rounded-lg last:rounded-lg data-[variant=outline]:border-l data-[state=on]:border-primary data-[state=on]:bg-primary data-[state=on]:text-primary-foreground data-[state=on]:hover:bg-primary/90 data-[state=on]:hover:text-primary-foreground"
						>
							{standing.label}
						</ToggleGroupItem>
					{/each}
				</ToggleGroup>
			</fieldset>
		</div>
	</header>
	<!-- Desktop Table View (hidden on mobile) -->
	<div class="hidden min-h-0 flex-1 overflow-auto lg:block">
		<Table.Root class="w-full">
			<Table.Header class="bg-muted/50">
				{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
					<Table.Row class="hover:bg-transparent">
						{#each headerGroup.headers as header (header.id)}
							<Table.Head
								scope="col"
								aria-sort={header.column.getIsSorted() === "asc"
									? "ascending"
									: header.column.getIsSorted() === "desc"
										? "descending"
										: undefined}
								class="px-4 text-xs font-bold uppercase tracking-wide text-muted-foreground"
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
					<Table.Row>
						{#each row.getVisibleCells() as cell (cell.id)}
							<Table.Cell class="px-4 py-3.5">
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
								class="p-4 bg-muted/20"
							>
								<WaitlistEntryDetails
									entry={row.original}
									layout="table"
									carriedFee={waitlist.carriedFee(row.original.id)}
									waitlistId={row.original.id}
									carriedFeeDeps={deps?.carriedFee}
								/>
							</Table.Cell>
						</Table.Row>
					{/if}
				{:else}
					<Table.Row
						><Table.Cell colspan={table.getAllColumns().length} class="p-0"
							>{@render emptyState()}</Table.Cell
						></Table.Row
					>
				{/each}
			</Table.Body>
			<Table.Footer class="bg-muted/20">
				{#each table.getFooterGroups() as footerGroup (footerGroup.id)}
					<Table.Row>
						{#each footerGroup.headers as header (header.id)}
							<Table.Cell>
								{#if !header.isPlaceholder}
									<FlexRender
										content={header.column.columnDef.footer}
										context={header.getContext()}
									/>
								{/if}
							</Table.Cell>
						{/each}
					</Table.Row>
				{/each}
			</Table.Footer>
		</Table.Root>
	</div>

	<!-- Mobile Card View (hidden on desktop) -->
	<div class="lg:hidden">
		{#if table.getRowCount() === 0}
			{@render emptyState()}
		{/if}
		<ul class="divide-y divide-border" aria-label="People on the waitlist">
			{#each table.getRowModel().rows as row (row.id)}
				<li class="p-4 sm:p-5">
					<!-- Name and Actions Row -->
					<div class="flex flex-wrap justify-between items-center gap-3 mb-3">
						<div class="min-w-0 break-words font-semibold text-base">
							{row.original.fullName}
							<!-- Position Badge -->
							<span
								class="ml-2 text-xs bg-muted text-muted-foreground rounded-full px-2 py-1"
							>
								#{row.original.position}
							</span>
						</div>
						<!-- Actions -->
						<div>
							<ActionButtons
								adminNotes={row.original.adminNotes ?? "N/A"}
								isExpanded={row.getIsExpanded()}
								onToggleExpand={() => row.toggleExpanded()}
								onEdit={(adminNotes) =>
									waitlist.updateAdminNotes(row.original.id, adminNotes)}
								onRestore={waitlist.offers(row.original, "restore")
									? () => waitlist.restore(row.original.id)
									: undefined}
								restoreDisabled={waitlist.isRestoring}
								onWithdraw={waitlist.offers(row.original, "withdraw")
									? () => openWithdraw(row.original)
									: undefined}
								onDelete={waitlist.offers(row.original, "delete_person")
									? () => openDelete(row.original)
									: undefined}
							/>
						</div>
					</div>

					<!-- Status -->
					<div class="mb-3">
						<Badge
							variant={row.original.status === "removed"
								? "outline"
								: "secondary"}>{statusText(row.original)}</Badge
						>
					</div>

					<!-- Email -->
					<div class="grid grid-cols-3 py-1 border-b">
						<div class="text-sm font-medium text-muted-foreground">Email</div>
						<div class="col-span-2 text-sm break-words">
							<a href="mailto:{row.original.email}">{row.original.email}</a>
						</div>
					</div>

					<!-- Phone -->
					<div class="grid grid-cols-3 py-1 border-b">
						<div class="text-sm font-medium text-muted-foreground">Phone</div>
						<div class="col-span-2 text-sm">
							{row.original.phoneNumber || "N/A"}
						</div>
					</div>

					<!-- Age -->
					<div class="grid grid-cols-3 py-1 border-b">
						<div class="text-sm font-medium text-muted-foreground">Age</div>
						<div class="col-span-2 text-sm">
							{row.original.age || "N/A"}
						</div>
					</div>

					<!-- Registration Date -->
					<div class="grid grid-cols-3 py-1 border-b">
						<div class="text-sm font-medium text-muted-foreground">
							Registered
						</div>
						<div class="col-span-2 text-sm">
							{#if row.original.initialRegistrationDate}
								{dayjs(row.original.initialRegistrationDate).format(
									"MMM D, YYYY",
								)}
							{:else}
								N/A
							{/if}
						</div>
					</div>

					<!-- Last Contacted -->
					<div class="grid grid-cols-3 py-1">
						<div class="text-sm font-medium text-muted-foreground">
							Last Contact
						</div>
						<div class="col-span-2 text-sm">
							{#if row.original.lastContacted}
								{dayjs(row.original.lastContacted).format("MMM D, YYYY")}
							{:else}
								Never
							{/if}
						</div>
					</div>

					<!-- Expanded Content -->
					{#if row.getIsExpanded()}
						<div class="mt-4 pt-4 border-t border-muted">
							<WaitlistEntryDetails
								entry={row.original}
								layout="card"
								carriedFee={waitlist.carriedFee(row.original.id)}
								waitlistId={row.original.id}
								carriedFeeDeps={deps?.carriedFee}
							/>
						</div>
					{/if}
				</li>
			{/each}
		</ul>
	</div>
	<div
		class="flex shrink-0 flex-col sm:flex-row items-center justify-between gap-4 p-4 sm:p-5 bg-muted/20 border-t border-border"
	>
		<div class="flex items-center gap-2 w-full md:w-auto justify-start">
			<p class="text-sm text-muted-foreground">People per page</p>
			<Select.Root
				type="single"
				value={waitlistUrl.pageSize.toString()}
				onValueChange={(value) => waitlistUrl.setPageSize(Number(value))}
			>
				<Select.Trigger
					class="w-20 h-11"
					aria-label="Waitlist elements per page"
					>{waitlistUrl.pageSize}</Select.Trigger
				>
				<Select.Content>
					{#each PAGE_SIZE_OPTIONS as pageSizeOption (pageSizeOption)}
						<Select.Item value={pageSizeOption.toString()}>
							{pageSizeOption}
						</Select.Item>
					{/each}
				</Select.Content>
			</Select.Root>
		</div>
		<div
			class="w-full md:w-auto flex items-center justify-center md:justify-end gap-2"
		>
			<Button
				variant="outline"
				disabled={!waitlist.previousCursor || waitlist.isFetching}
				onclick={() => waitlistUrl.goTo(waitlist.previousCursor)}
			>
				Previous
			</Button>
			<p class="text-sm text-muted-foreground">
				{waitlist.count} total
			</p>
			<Button
				variant="outline"
				disabled={!waitlist.nextCursor || waitlist.isFetching}
				onclick={() => waitlistUrl.goTo(waitlist.nextCursor)}
			>
				Next
			</Button>
		</div>
	</div>
</section>

{#if withdrawing}
	{@const person = withdrawing}
	{#key person.id}
		<WithdrawDialog
			scope={personScope(person.id)}
			name={person.fullName}
			choice={waitlist.refundChoice(person.id)}
			queryClient={deps?.queryClient}
			bind:open={withdrawOpen}
		/>
	{/key}
{/if}

{#if deleting}
	{@const person = deleting}
	{#key person.id}
		<DeleteDialog
			waitlistId={person.id}
			name={person.fullName}
			choice={waitlist.refundChoice(person.id)}
			queryClient={deps?.queryClient}
			bind:open={deleteOpen}
		/>
	{/key}
{/if}
