<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import type { Database } from '$database';
	import { Badge } from '$lib/components/ui/badge';
	import { Button } from '$lib/components/ui/button';
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
		type SortingState,
	} from '@tanstack/table-core';
	import dayjs from 'dayjs';
	import { createRawSnippet } from 'svelte';
	import { toast } from 'svelte-sonner';
	import InvitationActions from './invitation-actions.svelte';
	import { SendIcon } from 'lucide-svelte';
	import CopyButton from '$lib/components/ui/copy-button.svelte';
	import type { ComponentProps } from 'svelte';
	import { getInvitationLink } from '$lib/utils/invitation';

	const columns = 'id,email,status,expires_at,created_at';

	let pageSizeOptions = [10, 25, 50, 100];

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();

	const currentPage = $derived(Number(page.url.searchParams.get('invitePage')) || 0);
	const pageSize = $derived(Number(page.url.searchParams.get('invitePageSize')) || 10);
	const searchQuery = $derived(page.url.searchParams.get('inviteQ') || '');
	const rangeStart = $derived(currentPage * pageSize);
	const rangeEnd = $derived(rangeStart + pageSize);
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
	})

	const invitationsQueryKey = $derived(['invitations', pageSize, currentPage, rangeStart, sortingState, searchQuery]);

	// Query to fetch invitations
	const invitationsQuery = createQuery(() => ({
		queryKey: invitationsQueryKey,
		placeholderData: keepPreviousData,
		initialData: { data: [], count: 0 },
		queryFn: async ({ signal }) => {
			let query = supabase.from('invitations').select(columns, { count: 'estimated' });

			// Filter by status (pending or expired)
			query = query.in('status', ['pending', 'expired']);

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


	const resendInvitationLink = createMutation(() => ({
		mutationFn: async (data: { email: string, invitationId: string }[]) => {
			return fetch(`/api/admin/invite-link`, {
				method: 'POST',
				body: JSON.stringify({
					emails: data.map(e => e.email)
				})
			}).then(res => {
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


	// Create table
	const table = createSvelteTable({
		get data() {
			return invitationsQuery.data?.data || [];
		},
		columns: [
			{
				id: 'actions',
				header: 'Actions',
				cell: ({ row }) => {
					return renderComponent(InvitationActions, {
						resendInvitation: () => resendInvitationLink.mutate([{
							email: row.original.email,
							invitationId: row.original.id!
						}]),
						invitationLink: getInvitationLink(row.original.id!, row.original.email)
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
					return renderComponent(
						Badge,
						{
							children: createRawSnippet(() => ({
								render: () => status
							})),
							variant: status === 'pending' ? 'default' : 'destructive',
							class: 'capitalize'
						}
					);
				}
			},
			{
				id: 'expires_at',
				header: () => 'Expires',
				accessorKey: 'expires_at',
				cell: (info) => {
					const expiresAt = info.getValue() as string;
					const isExpired = dayjs(expiresAt).isBefore(dayjs());
					return renderSnippet(createRawSnippet(value => ({
						render: () => `
						<div class="flex items-center">
							<span class="${isExpired ? 'text-destructive' : ''}">
								${dayjs(value()).format('MMM D, YYYY')}
							</span>
						</div>
					`
					})), expiresAt);
				}
			}],
		state: {
			get sorting() {
				return sortingState;
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
		getRowId: (row) => row.id
	});
</script>

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
				<!-- Email and Actions Row -->
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base break-words">
						{row.original.email}
					</div>
					<div class="flex items-center space-x-2">
						<Button
							variant="ghost"
							size="icon"
							class="h-8 w-8"
							aria-label="Resend invitation"
							onclick={() => resendInvitationLink.mutate([{
								email: row.original.email,
								invitationId: row.original.id
							}])}
						>
							<SendIcon class="h-4 w-4" />
						</Button>
					</div>
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
							<span class={dayjs(row.original.expires_at).isBefore(dayjs()) ? 'text-destructive' : ''}>
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
								class={page.value !== currentPage && page.value !== currentPage - 1 && page.value !== currentPage + 1 ? 'hidden sm:block' : ''}>
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
