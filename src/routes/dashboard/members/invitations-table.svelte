<script lang="ts">
import type { SupabaseClient } from "@supabase/supabase-js";
import {
	createMutation,
	createQuery,
	keepPreviousData,
} from "@tanstack/svelte-query";
import {
	getCoreRowModel,
	getExpandedRowModel,
	getSortedRowModel,
	type SortingState,
} from "@tanstack/table-core";
import dayjs from "dayjs";
import { SendIcon, Trash2 } from "lucide-svelte";
import { createRawSnippet } from "svelte";
import { SvelteURLSearchParams } from "svelte/reactivity";
import { Cross2 } from "svelte-radix";
import { toast } from "svelte-sonner";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { page } from "$app/state";
import type { Database } from "$database";
import {
	type Invitation,
	type InvitationListSortField,
	invitationsList,
} from "@dhc/api-client";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import * as ButtonGroup from "$lib/components/ui/button-group";
import { Checkbox } from "$lib/components/ui/checkbox";
import {
	createSvelteTable,
	FlexRender,
	renderComponent,
	renderSnippet,
} from "$lib/components/ui/data-table/index.js";
import { Input } from "$lib/components/ui/input";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import * as Select from "$lib/components/ui/select";
import * as Table from "$lib/components/ui/table/index.js";
import { getInvitationLink } from "$lib/utils/invitation";
import {
	deleteInvitations,
	resendInvitations,
} from "../beginners-workshop/admin.remote";
import InvitationActions from "./invitation-actions.svelte";

const pageSizeOptions = [10, 25, 50, 100] as const;

// The table sorts on DB column names (snake_case) to stay compatible with the
// existing column ids; these map to the camelCase sort fields the API expects.
const invitationSortFields = [
	"email",
	"status",
	"expires_at",
	"created_at",
] as const;

type InvitationTableSortField = (typeof invitationSortFields)[number];

const invitationSortMap: Record<
	InvitationTableSortField,
	InvitationListSortField
> = {
	email: "email",
	status: "status",
	expires_at: "expiresAt",
	created_at: "createdAt",
};

type InvitationTableRow = {
	id: string;
	email: string;
	status: Invitation["status"];
	expires_at: string;
	created_at: string;
};

type InvitationTablePage = {
	data: InvitationTableRow[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};

const { supabase }: { supabase: SupabaseClient<Database> } = $props();

const pageSize = $derived.by(() => {
	const requestedPageSize =
		Number(page.url.searchParams.get("invitePageSize")) || 10;
	return pageSizeOptions.includes(
		requestedPageSize as (typeof pageSizeOptions)[number],
	)
		? (requestedPageSize as (typeof pageSizeOptions)[number])
		: (10 as (typeof pageSizeOptions)[number]);
});
const searchQuery = $derived(page.url.searchParams.get("inviteQ") || "");
const cursor = $derived(page.url.searchParams.get("inviteCursor"));
const activeSort = $derived.by(() => {
	const requestedSortColumn = page.url.searchParams.get("inviteSort");
	const sortColumn = invitationSortFields.includes(
		requestedSortColumn as (typeof invitationSortFields)[number],
	)
		? (requestedSortColumn as InvitationTableSortField)
		: "created_at";
	const sortDirection = page.url.searchParams.get("inviteDirection");

	return {
		sort: sortColumn,
		direction: sortDirection === "asc" ? ("asc" as const) : ("desc" as const),
	} as const;
});
const sortingState: SortingState = $derived.by(() => {
	return [
		{
			id: activeSort.sort,
			desc: activeSort.direction === "desc",
		},
	];
});

type InvitationTableQueryParams = {
	pageSize: (typeof pageSizeOptions)[number];
	searchQuery: string;
	sort: InvitationTableSortField;
	direction: "asc" | "desc";
	cursor: string | null;
};

const invitationsQueryParams = $derived<InvitationTableQueryParams>({
	pageSize,
	searchQuery,
	sort: activeSort.sort,
	direction: activeSort.direction,
	cursor,
});

async function loadInvitationsPage(
	params: InvitationTableQueryParams,
): Promise<InvitationTablePage> {
	const response = await invitationsList({
		query: {
			limit: params.pageSize,
			cursor: params.cursor ?? undefined,
			q: params.searchQuery || undefined,
			sort: invitationSortMap[params.sort],
			direction: params.direction,
		},
	});

	if (response.error) {
		throw new Error("Failed to load invitations. Please try again later.");
	}

	const result = response.data.data;

	return {
		data: result.invitations.map(toTableRow),
		count: result.totalCount,
		nextCursor: result.nextCursor,
		previousCursor: result.previousCursor,
	};
}

function toTableRow(invitation: Invitation): InvitationTableRow {
	return {
		id: invitation.id,
		email: invitation.email,
		status: invitation.status,
		expires_at: invitation.expiresAt,
		created_at: invitation.createdAt,
	};
}

const invitationsQueryKey = $derived(["invitations", invitationsQueryParams]);
const invitationsQuery = createQuery<InvitationTablePage>(() => ({
	queryKey: invitationsQueryKey,
	placeholderData: keepPreviousData,
	initialData: { data: [], count: 0, nextCursor: null, previousCursor: null },
	queryFn: ({ signal, queryKey }) => {
		signal.throwIfAborted();
		return loadInvitationsPage(queryKey[1] as InvitationTableQueryParams);
	},
}));

let selectedRows = $state<Set<string>>(new Set());

// Derived state for bulk operations
const selectedRowsArray = $derived(Array.from(selectedRows));

type MembersUrl = `/dashboard/members?${string}`;

function navigateToMembers(searchParams: SvelteURLSearchParams) {
	const url = `/dashboard/members?${searchParams.toString()}` as MembersUrl;
	goto(resolve(url as any), { keepFocus: true, noScroll: true });
}

function onPaginationChange(newPageSize: (typeof pageSizeOptions)[number]) {
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("invitePageSize", newPageSize.toString());
	// Changing page size resets the cursor (the old cursor bound the prior limit).
	newParams.delete("inviteCursor");
	navigateToMembers(newParams);
}

function onCursorChange(newCursor: string | null | undefined) {
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	if (newCursor) {
		newParams.set("inviteCursor", newCursor);
	} else {
		newParams.delete("inviteCursor");
	}
	navigateToMembers(newParams);
}

function onSortingChange(newSorting: SortingState) {
	const [sorting] = newSorting;
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("inviteSort", sorting.id);
	newParams.set("inviteDirection", sorting.desc ? "desc" : "asc");
	// Re-sorting invalidates the cursor (it bound the prior sort field/direction).
	newParams.delete("inviteCursor");
	navigateToMembers(newParams);
}

function onSearchChange(newSearch: string) {
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("inviteQ", newSearch);
	// Re-searching invalidates the cursor (it bound the prior query).
	newParams.delete("inviteCursor");
	navigateToMembers(newParams);
}

const resendInvitationLink = createMutation(() => ({
	mutationFn: async (data: { email: string; invitationId: string }[]) => {
		return resendInvitations({ emails: data.map((e) => e.email) });
	},
	onSuccess: () => {
		toast.success("Invitation link resent");
	},
	onError: () => {
		toast.error("Failed to resend invitation link");
	},
}));

const bulkResendInvitations = createMutation(() => ({
	mutationFn: async (selectedIds: string[]) => {
		const selectedInvitations =
			invitationsQuery.data?.data?.filter((invitation) =>
				selectedIds.includes(invitation.id),
			) || [];
		return resendInvitations({
			emails: selectedInvitations.map((invitation) => invitation.email),
		});
	},
	onSuccess: () => {
		toast.success("Invitation links resent successfully");
		selectedRows = new Set();
	},
	onError: () => {
		toast.error("Failed to resend invitation links");
	},
}));

// Bulk delete mutation
const bulkDeleteInvitations = createMutation(() => ({
	mutationFn: async (selectedIds: string[]) => {
		await deleteInvitations(selectedIds);
	},
	onSuccess: () => {
		toast.success("Invitations deleted successfully");
		selectedRows = new Set(); // Clear selection
		invitationsQuery.refetch(); // Refresh data
	},
	onError: () => {
		toast.error("Failed to delete invitations");
	},
}));

// Create table
const table = createSvelteTable({
	autoResetPageIndex: false,
	manualPagination: true,
	manualSorting: true,
	enableRowSelection: true,
	get data() {
		return invitationsQuery.data?.data || [];
	},
	columns: [
		{
			id: "select",
			header: () =>
				renderComponent(Checkbox, {
					checked: table.getIsAllRowsSelected(),
					indeterminate: table.getIsSomeRowsSelected(),
					onCheckedChange: (state: boolean) => {
						table.toggleAllRowsSelected(state);
					},
				}),
			cell: ({ row }) =>
				renderComponent(Checkbox, {
					checked: row.getIsSelected(),
					onCheckedChange: (state: boolean) => row.toggleSelected(state),
				}),
		},
		{
			id: "actions",
			header: "Actions",
			cell: ({ row }) => {
				return renderComponent(InvitationActions, {
					resendInvitation: () =>
						resendInvitationLink.mutate([
							{
								email: row.original.email,
								invitationId: row.original.id,
							},
						]),
					invitationLink: getInvitationLink(
						row.original.id,
						row.original.email,
					),
					deleteInvitation: () =>
						deleteInvitations([row.original.id]).then(() => {
							toast.success("Invitation deleted");
							invitationsQuery.refetch();
						}),
				});
			},
		},
		{
			id: "email",
			header: "Email",
			accessorKey: "email",
			cell: (info) => info.getValue(),
		},
		{
			id: "status",
			header: "Status",
			accessorKey: "status",
			cell: (info) => {
				const status = info.getValue() as string;
				return renderComponent(Badge, {
					children: createRawSnippet(() => ({
						render: () => status,
					})),
					variant: status === "pending" ? "default" : "destructive",
					class: "capitalize",
				});
			},
		},
		{
			id: "expires_at",
			header: () => "Expires",
			accessorKey: "expires_at",
			cell: (info) => {
				const expiresAt = info.getValue() as string;
				const isExpired = dayjs(expiresAt).isBefore(dayjs());
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () => `
						<div class="flex items-center">
							<span class="${isExpired ? "text-destructive" : ""}">
								${dayjs(value()).format("MMM D, YYYY")}
							</span>
						</div>
					`,
					})),
					expiresAt,
				);
			},
		},
	],
	state: {
		get sorting() {
			return sortingState;
		},
		get rowSelection() {
			return Array.from(selectedRows).reduce(
				(prv, curr) => ({
					...prv,
					[curr]: true,
				}),
				{},
			);
		},
	},
	onSortingChange: (updater) => {
		if (typeof updater === "function") {
			onSortingChange(updater(sortingState));
		} else {
			onSortingChange(updater);
		}
	},
	getCoreRowModel: getCoreRowModel(),
	getSortedRowModel: getSortedRowModel(),
	getExpandedRowModel: getExpandedRowModel(),
	getRowId: (row) => row.id,
	onRowSelectionChange: (updater) => {
		if (typeof updater === "function") {
			const currentSelection = Array.from(selectedRows).reduce(
				(prv, curr) => ({
					...prv,
					[curr]: true,
				}),
				{},
			);
			const newSelection = updater(currentSelection);
			selectedRows = new Set(
				Object.keys(newSelection).filter((key) => newSelection[key]),
			);
		} else {
			selectedRows = new Set(
				Object.keys(updater).filter((key) => updater[key]),
			);
		}
	},
});
</script>

<div class="flex w-full items-center space-x-2 mb-2 p-2">
	<Input
		value={searchQuery}
		onchange={(t: Event & { currentTarget: EventTarget & HTMLInputElement }) =>
			onSearchChange(t.currentTarget.value)}
		placeholder="Search invitations"
		class="max-w-md"
	/>

	{#if searchQuery !== ''}
		<Button variant="ghost" type="button" onclick={() => onSearchChange('')}>
			<Cross2 />
		</Button>
	{/if}
	{#if invitationsQuery.isFetching}
		<LoaderCircle />
	{/if}

	<div class="flex items-center justify-between ml-auto">
		<ButtonGroup.Root>
			<!-- Bulk Resend Button -->
			<Button
				variant="outline"
				size="sm"
				disabled={bulkResendInvitations.isPending || selectedRows.size === 0}
				onclick={() => bulkResendInvitations.mutate(selectedRowsArray)}
				class="flex items-center gap-2"
			>
				<SendIcon class="h-4 w-4" />
				<span class="hidden sm:inline">
					{bulkResendInvitations.isPending
						? 'Sending...'
						: `Resend${selectedRows.size === 0 ? '' : ` ${selectedRows.size}`}`}
				</span>
			</Button>

			<!-- Bulk Delete Button -->
			<Button
				variant="destructive"
				size="sm"
				disabled={bulkDeleteInvitations.isPending || selectedRows.size === 0}
				onclick={() => bulkDeleteInvitations.mutate(selectedRowsArray)}
				class="flex items-center gap-2"
			>
				<Trash2 class="h-4 w-4" />
				<span class="hidden sm:inline">
					{bulkDeleteInvitations.isPending
						? 'Deleting...'
						: `Delete${selectedRows.size === 0 ? '' : ` ${selectedRows.size}`}`}
				</span>
			</Button>
		</ButtonGroup.Root>
	</div>
</div>

<!-- Desktop Table View (hidden on mobile) -->
<div class="hidden md:block overflow-x-auto overflow-y-auto h-[65svh]">
	<Table.Root class="w-full">
		<Table.Header class="sticky top-0 z-10 bg-white">
			{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
				<Table.Row>
					{#each headerGroup.headers as header (header.id)}
						<Table.Head class="text-black prose prose-p text-xs md:text-sm font-medium p-2">
							<FlexRender
								content={header.column.columnDef.header ?? ''}
								context={header.getContext() ?? {}}
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
							<FlexRender content={cell.column.columnDef.cell} context={cell.getContext()} />
						</Table.Cell>
					{/each}
				</Table.Row>
			{/each}
		</Table.Body>
	</Table.Root>
</div>

<!-- Mobile Card View (hidden on desktop) -->
<div class="md:hidden overflow-y-auto h-[60svh] px-2 py-1">
	<div class="space-y-4">
		{#if table.getRowCount() === 0}
			<p class="text-foreground">No results found</p>
		{/if}
		{#each table.getRowModel().rows as row (row.id)}
			<div class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
				<!-- Checkbox and Email Row -->
				<div class="flex items-center gap-2 mb-3">
					<Checkbox checked={row.getIsSelected()} onchange={() => row.toggleSelected()} />
					<div class="font-medium text-base break-words">
						{row.original.email}
					</div>
				</div>

				<!-- Actions Row -->
				<div class="flex items-center space-x-2 mb-3">
					<Button
						variant="ghost"
						size="icon"
						class="h-8 w-8"
						aria-label="Resend invitation"
						onclick={() =>
							resendInvitationLink.mutate([
								{
									email: row.original.email,
									invitationId: row.original.id
								}
							])}
					>
						<SendIcon class="h-4 w-4" />
					</Button>
				</div>

				<!-- Status Badge -->
				<div class="mb-3">
					<Badge
						variant={row.original.status === 'pending' ? 'default' : 'destructive'}
						class="h-6"
					>
						<p class="capitalize">{row.original.status || 'Unknown'}</p>
					</Badge>
				</div>

				<!-- Expires -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Expires</div>
					<div class="col-span-2 text-sm">
						{#if row.original.expires_at}
							<span
								class={dayjs(row.original.expires_at).isBefore(dayjs()) ? 'text-destructive' : ''}
							>
								{dayjs(row.original.expires_at).format('MMM D, YYYY')}
							</span>
						{:else}
							N/A
						{/if}
					</div>
				</div>

				<!-- Created -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Created</div>
					<div class="col-span-2 text-sm">
						{#if row.original.created_at}
							{dayjs(row.original.created_at).format('MMM D, YYYY')}
						{:else}
							Unknown
						{/if}
					</div>
				</div>
			</div>
		{/each}
	</div>
</div>

<div class="flex flex-col md:flex-row items-center justify-between gap-4 p-4 bg-card border-t">
	<div class="flex items-center gap-2 w-full md:w-auto justify-start">
		<p class="text-sm text-muted-foreground">Elements per page</p>
		<Select.Root
			type="single"
			value={pageSize.toString()}
			onValueChange={(value) =>
				onPaginationChange(Number(value) as (typeof pageSizeOptions)[number])}
		>
			<Select.Trigger class="w-16 h-8" aria-label="Invitations elements per page">
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
	<div class="w-full md:w-auto flex items-center justify-center md:justify-end gap-2">
		<Button
			variant="outline"
			disabled={!invitationsQuery.data?.previousCursor || invitationsQuery.isFetching}
			onclick={() => onCursorChange(invitationsQuery.data?.previousCursor)}
		>
			Previous
		</Button>
		<p class="text-sm text-muted-foreground">
			{invitationsQuery.data?.count ?? 0} total
		</p>
		<Button
			variant="outline"
			disabled={!invitationsQuery.data?.nextCursor || invitationsQuery.isFetching}
			onclick={() => onCursorChange(invitationsQuery.data?.nextCursor)}
		>
			Next
		</Button>
	</div>
</div>