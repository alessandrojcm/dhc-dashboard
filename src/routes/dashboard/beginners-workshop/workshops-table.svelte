<script lang="ts">
	import {
		createSvelteTable,
		FlexRender,
		renderComponent,
		renderSnippet
	} from '$lib/components/ui/data-table/index.js';
	import * as Table from '$lib/components/ui/table/index.js';
	import * as Pagination from '$lib/components/ui/pagination/index.js';
	import {
		getCoreRowModel,
		getSortedRowModel,
		getPaginationRowModel,
		type SortingState
	} from '@tanstack/table-core';
	import { createQuery, keepPreviousData } from '@tanstack/svelte-query';
	import dayjs from 'dayjs';
	import * as Select from '$lib/components/ui/select/index.js';
	import type { SupabaseClient } from '@supabase/supabase-js';
	import type { Database } from '$database';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { Badge } from '$lib/components/ui/badge/index.js';
	import { createRawSnippet } from 'svelte';

	// Define the workshop type based on the API response
	interface Workshop {
		id: string;
		workshop_date: string;
		location: string;
		status: string;
		capacity: number;
		coach: {
			first_name: string;
			last_name: string;
		};
	}

	const { supabase }: { supabase: SupabaseClient<Database> } = $props();

	const pageSizeOptions = [10, 25, 50, 100];
	const currentPage = $derived(Number(page.url.searchParams.get('workshopPage')) || 0);
	const pageSize = $derived(Number(page.url.searchParams.get('workshopPageSize')) || 10);
	const rangeStart = $derived(currentPage * pageSize);
	const rangeEnd = $derived(rangeStart + pageSize - 1);
	let sortingState: SortingState = $state([]);

	const columns = [
		{
			accessorKey: 'workshop_date',
			header: 'Date',
			cell: ({ getValue }: { getValue: () => string }) =>
				dayjs(getValue()).format('ddd, D MMM YYYY'),
			enableSorting: true
		},
		{
			accessorKey: 'location',
			header: 'Location',
			enableSorting: true
		},
		{
			accessorKey: 'coach',
			header: 'Coach',
			cell: ({ getValue }: { getValue: () => Workshop['coach'] | null }) => `${getValue()?.first_name} ${getValue()?.last_name}` || 'Unassigned',
			enableSorting: true
		},
		{
			accessorKey: 'status',
			header: 'Status',
			cell: ({ getValue }: { getValue: () => string }) => {
				return renderComponent(Badge, {
					variant: getValue() === 'draft' ? 'default' : 'outline',
					class: 'h-8',
					children: createRawSnippet(() => ({
						render: () => `<p class="capitalize">${getValue()}</p>`
					}))	
				});
			}
		},
		{
			accessorKey: 'capacity',
			header: 'Capacity',
			cell: ({ getValue }: { getValue: () => number }) => getValue()
		}
	];

	const workshopsQueryKey = $derived(['workshops', { rangeStart, rangeEnd, sortingState }]);

	const workshopsQuery = createQuery<Workshop[]>(() => ({
		queryKey: workshopsQueryKey,
		placeholderData: keepPreviousData,
		refetchOnMount: true,
		queryFn: async ({ signal }) => {
			return supabase
				.from('workshops')
				.select(`id, workshop_date, location, status, capacity, coach:user_profiles!workshops_coach_id_fkey(first_name, last_name)`)
				.order('created_at', { ascending: false })
				.range(rangeStart, rangeEnd)
				.throwOnError()
				.abortSignal(signal)
				.then(({ data }) => (data as Workshop[]) ?? []);
		}
	}));

	function onPaginationChange(newPagination: { pageIndex: number; pageSize: number }) {
		const newParams = new URLSearchParams(page.url.searchParams);
		newParams.set('workshopPage', newPagination.pageIndex.toString());
		newParams.set('workshopPageSize', newPagination.pageSize.toString());
		goto(`/dashboard/beginners-workshop?${newParams.toString()}`);
	}

	const table = createSvelteTable({
		get data() {
			return workshopsQuery.data ?? [];
		},
		columns,
		state: {
			get sorting() {
				return sortingState;
			},
			get pagination() {
				return { pageIndex: currentPage, pageSize };
			}
		},
		onSortingChange: (updater) => {
			if (typeof updater === 'function') sortingState = updater(sortingState);
			else sortingState = updater;
		},
		onPaginationChange: (updater) => {
			if (typeof updater === 'function') {
				const next = updater({ pageIndex: currentPage, pageSize });
				onPaginationChange(next);
			} else {
				onPaginationChange(updater);
			}
		},
		getCoreRowModel: getCoreRowModel(),
		getSortedRowModel: getSortedRowModel(),
		getPaginationRowModel: getPaginationRowModel(),
		manualPagination: true,
		manualSorting: false,
		autoResetPageIndex: false
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
							<FlexRender content={header.column.columnDef.header} context={header.getContext()} />
						</Table.Head>
					{/each}
				</Table.Row>
			{/each}
		</Table.Header>
		<Table.Body>
			{#if table.getRowModel().rows.length === 0}
				<Table.Row>
					<Table.Cell colspan={columns.length} class="text-center py-8 text-muted-foreground">
						No workshops found
					</Table.Cell>
				</Table.Row>
			{:else}
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
			{/if}
		</Table.Body>
	</Table.Root>
</div>

<!-- Mobile Card View (hidden on desktop) -->
<div class="md:hidden overflow-y-auto h-[60svh] px-2 py-1">
	<div class="space-y-4">
		{#if table.getRowModel().rows.length === 0}
			<p class="text-foreground">No workshops found</p>
		{/if}
		{#each table.getRowModel().rows as row (row.id)}
			<div class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base">
						<FlexRender
							content={row.getVisibleCells()[0].column.columnDef.cell}
							context={row.getVisibleCells()[0].getContext()}
						/>
					</div>
					<FlexRender
						content={row.getVisibleCells()[columns.length - 1].column.columnDef.cell}
						context={row.getVisibleCells()[columns.length - 1].getContext()}
					/>
				</div>
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Location</div>
					<div class="col-span-2 text-sm">
						<FlexRender
							content={row.getVisibleCells()[1].column.columnDef.cell}
							context={row.getVisibleCells()[1].getContext()}
						/>
					</div>
				</div>
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Coach</div>
					<div class="col-span-2 text-sm">
						<FlexRender
							content={row.getVisibleCells()[2].column.columnDef.cell}
							context={row.getVisibleCells()[2].getContext()}
						/>
					</div>
				</div>
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Status</div>
					<div class="col-span-2 text-sm">
						<FlexRender
							content={row.getVisibleCells()[3].column.columnDef.cell}
							context={row.getVisibleCells()[3].getContext()}
						/>
					</div>
				</div>
				<div class="grid grid-cols-3 py-1">
					<div class="text-sm font-medium text-muted-foreground">Capacity</div>
					<div class="col-span-2 text-sm">
						<FlexRender
							content={row.getVisibleCells()[4].column.columnDef.cell}
							context={row.getVisibleCells()[4].getContext()}
						/>
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
				onPaginationChange({ pageIndex: currentPage, pageSize: Number(value) })}
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
			count={table.getRowCount()}
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
