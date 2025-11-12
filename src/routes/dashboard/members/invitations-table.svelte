<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import type { Database } from '$database';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import {
		createSvelteTable,
		FlexRender,
		renderComponent,
		renderSnippet
	} from '$lib/components/ui/data-table/index.js';
	import * as Pagination from '$lib/components/ui/pagination/index.js';
	import * as Select from '$lib/components/ui/select';
	import * as Table from '$lib/components/ui/table/index.js';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import { createMutation, createQuery, keepPreviousData } from '@tanstack/svelte-query';
	import {
		getCoreRowModel,
		getPaginationRowModel,
		getSortedRowModel,
		getExpandedRowModel,
		type PaginationState,
		type SortingState
	} from '@tanstack/table-core';
	import dayjs from 'dayjs';
	import { createRawSnippet } from 'svelte';
	import { toast } from 'svelte-sonner';
	import InvitationActions from './invitation-actions.svelte';
	import { SendIcon, Trash2 } from 'lucide-svelte';
	import { getInvitationLink } from '$lib/utils/invitation';
	import { deleteInvitations } from '$lib/services/members.remote';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { Input } from '$lib/components/ui/input';
	import { Cross2 } from 'svelte-radix';
	import * as ButtonGroup from '$lib/components/ui/button-group';

	const columns = 'id,email,status,expires_at,created_at';

	let pageSizeOptions = [10, 25, 50, 100];

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();

	const currentPage = $derived.by(() => Number(page.url.searchParams.get('invitePage')) || 0);
	const pageSize = $derived.by(() => Number(page.url.searchParams.get('invitePageSize')) || 10);
	const searchQuery = $derived.by(() => page.url.searchParams.get('inviteQ') || '');
	const rangeStart = $derived.by(() => currentPage * pageSize);
	const rangeEnd = $derived.by(() => rangeStart + pageSize);
	const sortingState: SortingState = $derived.by(() => {
		const sortColumn = page.url.searchParams.get('inviteSort');
		const sortDirection = page.url.searchParams.get('inviteDirection');
		if (!sortColumn) return [];
		return [
			{
				id: sortColumn,
				desc: sortDirection === 'desc'
			}
		];
	});

	const invitationsQueryKey = $derived([
		'invitations',
		pageSize,
		currentPage,
		rangeStart,
		sortingState,
		searchQuery
	]);

	// Query to fetch invitations
	const invitationsQuery = createQuery(() => ({
		queryKey: invitationsQueryKey,
		placeholderData: keepPreviousData,
		initialData: { data: [], count: 0 },
		queryFn: async ({ signal }) => {
			let query = supabase.from('invitations').select(columns, { count: 'estimated' });

			// Filter by status (pending or expired)
			query = query.in('status', ['pending', 'expired']);
			if (searchQuery.length > 0) {
				query = query.textSearch('search_text', `'${searchQuery}'`, {
					type: 'websearch'
				});
			}
			// Add sorting if provided
			if (sortingState.length > 0) {
				query = query.order(sortingState[0].id, { ascending: !sortingState[0].desc });
			} else {
				// Default sort by created_at descending
				query = query.order('created_at', { ascending: false });
			}

			const { data, error, count } = await query
				.range(rangeStart, rangeEnd)
				.abortSignal(signal)
				.throwOnError();

			if (error) {
				throw error;
			}

			return { data, count: count || data.length };
		}
	}));

	let selectedRows = $state<Set<string>>(new Set());

	// Derived state for bulk operations
	const hasSelectedRows = $derived(selectedRows.size > 0);
	const selectedRowsArray = $derived(Array.from(selectedRows));

	function onPaginationChange(newPagination: Partial<PaginationState>) {
		const paginationState: PaginationState = {
			pageIndex: currentPage,
			pageSize,
			...newPagination
		};
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('invitePage', paginationState.pageIndex.toString());
		newParams.set('invitePageSize', paginationState.pageSize.toString());
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	function onSortingChange(newSorting: SortingState) {
		const [sortingState] = newSorting;
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('inviteSort', sortingState.id);
		newParams.set('inviteDirection', sortingState.desc ? 'desc' : 'asc');
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	function onSearchChange(newSearch: string) {
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('inviteQ', newSearch);
		goto(`/dashboard/members?${newParams.toString()}`);
	}

	const resendInvitationLink = createMutation(() => ({
		mutationFn: async (data: { email: string; invitationId: string }[]) => {
			return fetch(`/api/admin/invite-link`, {
				method: 'POST',
				body: JSON.stringify({
					emails: data.map((e) => e.email)
				})
			}).then((res) => {
				if (!res.ok) {
					throw new Error('Failed to resend invitation link');
				}
			});
		},
		onSuccess: () => {
			toast.success('Invitation link resent');
		},
		onError: () => {
			toast.error('Failed to resend invitation link');
		}
	}));

	// Bulk resend mutation
	const bulkResendInvitations = createMutation(() => ({
		mutationFn: async (selectedIds: string[]) => {
			const selectedInvitations =
				invitationsQuery.data?.data?.filter((invitation) => selectedIds.includes(invitation.id!)) ||
				[];

			return fetch(`/api/admin/invite-link`, {
				method: 'POST',
				body: JSON.stringify({
					emails: selectedInvitations.map((invitation) => invitation.email)
				})
			}).then((res) => {
				if (!res.ok) {
					throw new Error('Failed to resend invitation links');
				}
			});
		},
		onSuccess: () => {
			toast.success('Invitation links resent successfully');
			selectedRows = new Set(); // Clear selection
		},
		onError: () => {
			toast.error('Failed to resend invitation links');
		}
	}));

	// Bulk delete mutation
	const bulkDeleteInvitations = createMutation(() => ({
		mutationFn: async (selectedIds: string[]) => {
			await deleteInvitations(selectedIds);
		},
		onSuccess: () => {
			toast.success('Invitations deleted successfully');
			selectedRows = new Set(); // Clear selection
			invitationsQuery.refetch(); // Refresh data
		},
		onError: () => {
			toast.error('Failed to delete invitations');
		}
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
				id: 'select',
				header: () =>
					renderComponent(Checkbox, {
						checked: table.getIsAllRowsSelected(),
						indeterminate: table.getIsSomeRowsSelected(),
						onCheckedChange: (state: boolean) => {
							table.toggleAllRowsSelected(state);
						}
					}),
				cell: ({ row }) =>
					renderComponent(Checkbox, {
						checked: row.getIsSelected(),
						onCheckedChange: (state: boolean) => row.toggleSelected(state)
					})
			},
			{
				id: 'actions',
				header: 'Actions',
				cell: ({ row }) => {
					return renderComponent(InvitationActions, {
						resendInvitation: () =>
							resendInvitationLink.mutate([
								{
									email: row.original.email,
									invitationId: row.original.id!
								}
							]),
						invitationLink: getInvitationLink(row.original.id!, row.original.email),
						deleteInvitation: () =>
							deleteInvitations([row.original.id!]).then(() => {
								toast.success('Invitation deleted');
								invitationsQuery.refetch();
							})
					});
				}
			},
			{
				id: 'email',
				header: 'Email',
				accessorKey: 'email',
				cell: (info) => info.getValue()
			},
			{
				id: 'status',
				header: 'Status',
				accessorKey: 'status',
				cell: (info) => {
					const status = info.getValue() as string;
					return renderComponent(Badge, {
						children: createRawSnippet(() => ({
							render: () => status
						})),
						variant: status === 'pending' ? 'default' : 'destructive',
						class: 'capitalize'
					});
				}
			},
			{
				id: 'expires_at',
				header: () => 'Expires',
				accessorKey: 'expires_at',
				cell: (info) => {
					const expiresAt = info.getValue() as string;
					const isExpired = dayjs(expiresAt).isBefore(dayjs());
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => `
						<div class="flex items-center">
							<span class="${isExpired ? 'text-destructive' : ''}">
								${dayjs(value()).format('MMM D, YYYY')}
							</span>
						</div>
					`
						})),
						expiresAt
					);
				}
			}
		],
		state: {
			get sorting() {
				return sortingState;
			},
			get rowSelection() {
				return Array.from(selectedRows).reduce(
					(prv, curr) => ({
						...prv,
						[curr]: true
					}),
					{}
				);
			}
		},
		onPaginationChange: (updater) => {
			if (typeof updater === 'function') {
				onPaginationChange(
					updater({
						pageIndex: currentPage,
						pageSize
					})
				);
			} else {
				onPaginationChange(updater);
			}
		},
		onSortingChange: (updater) => {
			if (typeof updater === 'function') {
				onSortingChange(updater(sortingState));
			} else {
				onSortingChange(updater);
			}
		},
		getCoreRowModel: getCoreRowModel(),
		getSortedRowModel: getSortedRowModel(),
		getPaginationRowModel: getPaginationRowModel(),
		getExpandedRowModel: getExpandedRowModel(),
		getRowId: (row) => row.id,
		onRowSelectionChange: (updater) => {
			if (typeof updater === 'function') {
				const currentSelection = Array.from(selectedRows).reduce(
					(prv, curr) => ({
						...prv,
						[curr]: true
					}),
					{}
				);
				const newSelection = updater(currentSelection);
				selectedRows = new Set(Object.keys(newSelection).filter((key) => newSelection[key]));
			} else {
				selectedRows = new Set(Object.keys(updater).filter((key) => updater[key]));
			}
		}
	});
</script>

<div class="flex w-full items-center space-x-2 mb-2 p-2">
	<Input
		value={searchQuery}
		onchange={(t: Event & { currentTarget: EventTarget & HTMLInputElement }) =>
			onSearchChange(t.currentTarget.value)}
		placeholder="Search members"
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
			onValueChange={(value) => onPaginationChange({ pageSize: Number(value) })}
		>
			<Select.Trigger class="w-16 h-8">{pageSize}</Select.Trigger>
			<Select.Content>
				{#each pageSizeOptions as pageSizeOption}
					<Select.Item value={pageSizeOption.toString()}>
						{pageSizeOption}
					</Select.Item>
				{/each}
			</Select.Content>
		</Select.Root>
	</div>
	<div class="w-full md:w-auto flex justify-center md:justify-end">
		<Pagination.Root
			count={invitationsQuery?.data?.count ?? 0}
			perPage={pageSize}
			page={currentPage + 1}
			onPageChange={(page) => table.setPageIndex(page - 1)}
			class="m-0"
		>
			{#snippet children({ pages, currentPage })}
				<Pagination.Content>
					<Pagination.Item>
						<Pagination.PrevButton />
					</Pagination.Item>
					{#each pages as page (page.key)}
						{#if page.type === 'ellipsis'}
							<Pagination.Item class="hidden sm:block">
								<Pagination.Ellipsis />
							</Pagination.Item>
						{:else}
							<Pagination.Item
								class={page.value !== currentPage &&
								page.value !== currentPage - 1 &&
								page.value !== currentPage + 1
									? 'hidden sm:block'
									: ''}
							>
								<Pagination.Link {page} isActive={currentPage === page.value}>
									{page.value}
								</Pagination.Link>
							</Pagination.Item>
						{/if}
					{/each}
					<Pagination.Item>
						<Pagination.NextButton />
					</Pagination.Item>
				</Pagination.Content>
			{/snippet}
		</Pagination.Root>
	</div>
</div>
