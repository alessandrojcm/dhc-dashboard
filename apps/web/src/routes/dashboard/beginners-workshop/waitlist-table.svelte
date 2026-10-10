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
import { LoaderCircle } from "@lucide/svelte";
import { createRawSnippet } from "svelte";
import { Cross2 } from "svelte-radix";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import {
	createSvelteTable,
	FlexRender,
	renderComponent,
	renderSnippet,
} from "#lib/components/ui/data-table/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import * as Select from "#lib/components/ui/select/index.js";
import * as Table from "#lib/components/ui/table/index.js";
import SortHeader from "#lib/components/ui/table/sort-header.svelte";
import {
	ToggleGroup,
	ToggleGroupItem,
} from "#lib/components/ui/toggle-group/index.js";
import { PAGE_SIZE_OPTIONS } from "#lib/cursor-query.js";
import ActionButtons from "./actions-buttons.svelte";
import WaitlistEntryDetails from "./waitlist-entry-details.svelte";
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

const standingLabel = $derived(
	waitlist.standing === "removed" ? "removed" : "waiting",
);

function formatDate(value: string | null | undefined) {
	return value ? dayjs(value).format("DD/MM/YYYY") : "N/A";
}

/** The Status cell: the standing, and when a removed person was removed. */
function statusText(entry: WaitlistEntry) {
	return entry.status === "removed"
		? `Removed ${formatDate(entry.removedAt)}`
		: "Waiting";
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
							`<div class="w-[100px] md:w-[120px] whitespace-break-spaces break-words">${value()}</div>`,
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
							`<a href="mailto:${value()}" class="w-[150px] md:w-[200px] whitespace-break-spaces break-words">${value()}</a>`,
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
					class: "h-8",
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
				return renderComponent(Badge, {
					variant: row.original.status === "removed" ? "outline" : "secondary",
					class: "h-8 whitespace-nowrap",
					children: createRawSnippet(() => ({
						render: () => `<span>${statusText(row.original)}</span>`,
					})),
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
							return `<div class="w-[120px] ${value() < 18 ? "text-red-800" : ""}">${value() < 18 ? value() + "(👶)" : value()}</div>`;
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

<div
	class="flex flex-col md:flex-row w-full max-w-auto items-stretch md:items-center space-x-2 mb-2 p-2"
>
	<span class="flex flex-nowrap items-center gap-2">
		<Input
			value={waitlistUrl.search}
			oninput={(t: Event & { currentTarget: EventTarget & HTMLInputElement }) =>
				waitlistUrl.setSearch(t.currentTarget.value)}
			placeholder="Search for a person"
			class="w-full md:max-w-md"
		/>

		{#if waitlistUrl.search !== ""}
			<Button
				variant="ghost"
				type="button"
				aria-label="Clear search"
				onclick={() => waitlistUrl.setSearch("")}
			>
				<Cross2 />
			</Button>
		{/if}
		{#if waitlist.isFetching}
			<LoaderCircle />
		{/if}
	</span>

	<!-- A single-choice switch; clicking the active item would clear a
	     single ToggleGroup, so an empty value is ignored. -->
	<ToggleGroup
		type="single"
		variant="outline"
		value={waitlist.standing}
		onValueChange={(next) => {
			if (next) waitlist.setStanding(next as WaitlistStanding);
		}}
		aria-label="Waitlist standing"
		class="md:ml-auto"
	>
		{#each WAITLIST_STANDINGS as standing (standing.value)}
			<ToggleGroupItem value={standing.value} class="px-3">
				{standing.label}
			</ToggleGroupItem>
		{/each}
	</ToggleGroup>
</div>
<!-- Desktop Table View (hidden on mobile) -->
<div class="hidden md:block overflow-x-auto overflow-y-auto h-[65svh]">
	<Table.Root class="w-full">
		<Table.Header class="sticky top-0 z-10 bg-white">
			{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
				<Table.Row>
					{#each headerGroup.headers as header (header.id)}
						<Table.Head
							class="text-black prose prose-p text-xs md:text-sm font-medium p-2"
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
						<Table.Cell
							class="whitespace-normal md:whitespace-nowrap py-2 md:py-4 px-2 md:px-3 text-xs md:text-sm prose prose-p"
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
							class="p-4 bg-muted/20"
						>
							<WaitlistEntryDetails entry={row.original} layout="table" />
						</Table.Cell>
					</Table.Row>
				{/if}
			{/each}
		</Table.Body>
		<Table.Footer class="sticky bottom-0 z-1 bg-white">
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
<div class="md:hidden overflow-y-auto h-[60svh] px-2 py-1">
	{#if table.getRowCount() === 0}
		<p class="text-foreground">No results found</p>
	{/if}
	<ul class="space-y-4" aria-label="Waitlist entries">
		{#each table.getRowModel().rows as row (row.id)}
			<li class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
				<!-- Name and Actions Row -->
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base">
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
						<WaitlistEntryDetails entry={row.original} layout="card" />
					</div>
				{/if}
			</li>
		{/each}
	</ul>
</div>
<div
	class="flex flex-col md:flex-row items-center justify-between gap-4 p-4 bg-card border-t"
>
	<div class="flex items-center gap-2 w-full md:w-auto justify-start">
		<p class="text-sm text-muted-foreground">Elements per page</p>
		<Select.Root
			type="single"
			value={waitlistUrl.pageSize.toString()}
			onValueChange={(value) => waitlistUrl.setPageSize(Number(value))}
		>
			<Select.Trigger class="w-16 h-8" aria-label="Waitlist elements per page"
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
