<script lang="ts">
	import { createQuery, keepPreviousData } from '@tanstack/svelte-query';
	import {
		createSvelteTable,
		FlexRender,
		renderComponent,
		renderSnippet
	} from '$lib/components/ui/data-table/index.js';
	import {
		getCoreRowModel,
		getPaginationRowModel,
		getSortedRowModel,
		type PaginationState,
		type SortingState,
		type TableOptions
	} from '@tanstack/table-core';
	import { page } from '$app/stores';
	import { goto } from '$app/navigation';
	import type { Tables } from '$database';
	import * as Select from '$lib/components/ui/select';
	import * as Table from '$lib/components/ui/table/index.js';
	import * as Pagination from '$lib/components/ui/pagination/index.js';
	import SortHeader from '$lib/components/ui/table/sort-header.svelte';
	import dayjs from 'dayjs';
	import { createRawSnippet } from 'svelte';
	import type { QueryData } from '@supabase/supabase-js';
	import type { FetchAndCountResult } from '$lib/types';

	let pageSizeOptions = [10, 25, 50, 100];
	const { data } = $props();
	const supabase = data.supabase;
	const currentPage = $derived(Number($page.url.searchParams.get('page')) || 0);
	const pageSize = $derived(Number($page.url.searchParams.get('pageSize')) || 10);
	const rangeStart = $derived(currentPage * pageSize);
	const rangeEnd = $derived(rangeStart + pageSize);
	const sortingState: SortingState = $derived.by(() => {
		const sortColumn = $page.url.searchParams.get('sort');
		const sortDirection = $page.url.searchParams.get('direction');
		if (!sortColumn) return [];
		return [
			{
				id: sortColumn,
				desc: sortDirection === 'desc'
			}
		];
	});
	$inspect(rangeStart, rangeEnd);
	const waitlistQuery = createQuery<FetchAndCountResult<'waitlist'>, Error>(() => ({
		queryKey: ['waitlist', pageSize, currentPage, rangeStart, sortingState],
		placeholderData: keepPreviousData,
		initialData: {
				count: 0,
				data: []
		},
		queryFn: () => {
			const query = () =>
				supabase.from('waitlist').select('*', { count: 'estimated' }).range(rangeStart, rangeEnd);
			if (sortingState.length > 0) {
				return query()
					.order(sortingState[0].id, { ascending: !sortingState[0].desc })
					.throwOnError() as QueryData<Tables<'waitlist'>>;
			}
			return query().throwOnError() as QueryData<Tables<'waitlist'>>;
		}
	}));
	const waitlistData = $state(waitlistQuery.data);
	$inspect(waitlistData);
	// TODO: sorting etc, pagination, fix types, loading indicator
	function onPaginationChange(newPagination: Partial<PaginationState>) {
		const paginationState: PaginationState = {
			pageIndex: currentPage,
			pageSize,
			...newPagination
		};
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('page', paginationState.pageIndex.toString());
		newParams.set('pageSize', paginationState.pageSize.toString());
		goto(`/dashboard/beginners-workshop/waitlist?${newParams.toString()}`);
	}
	function onSortingChange(newSorting: SortingState) {
		const [sortingState] = newSorting;
		const newParams = new URLSearchParams($page.url.searchParams);
		newParams.set('sort', sortingState.id);
		newParams.set('direction', sortingState.desc ? 'desc' : 'asc');
		goto(`/dashboard/beginners-workshop/waitlist?${newParams.toString()}`);
	}
	const tableOptions = $state<TableOptions<Tables<'waitlist'>>>({
		autoResetPageIndex: false,
		manualPagination: true,
		manualSorting: true,
		columns: [
			{
				accessorKey: 'first_name',
				header: 'First Name',
				footer: `Total ${waitlistData.count} people on the waitlist`
			},
			{
				accessorKey: 'last_name',
				header: 'Last Name'
			},
			{
				accessorKey: 'email',
				header: 'Email',
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () =>
								`<p class="max-w-[25ch] break-words whitespace-break-spaces">${value()}</p>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'phone_number',
				header: 'Phone Number'
			},
			{
				accessorKey: 'status',
				header: 'Status'
			},
			{
				accessorKey: 'date_of_birth',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Date of Birth',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () => {
								const date = dayjs(getValue());
								const age = dayjs().diff(date, 'years');
								return `<p class="${age < 16 ? 'text-red-800' : ''}">${date.format('DD/MM/YYYY')} (Age ${age})</p>`;
							}
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'initial_registration_date',
				header: ({ column }) =>
					renderComponent(SortHeader, {
						onclick: () => column.toggleSorting(column.getIsSorted() === 'asc'),
						header: 'Initial Registration Date',
						class: 'p-2',
						sortDirection: column.getIsSorted()
					}),
				cell: ({ getValue }) => {
					return dayjs(getValue()).format('DD/MM/YYYY HH:mm');
				}
			},
			{
				accessorKey: 'last_contacted',
				header: 'Last Contacted'
			},
			{
				accessorKey: 'medical_conditions',
				header: 'Medical Conditions',
				cell: ({ getValue }) => {
					return renderSnippet(
						createRawSnippet((value) => ({
							render: () =>
								`<p class="max-w-[25ch] break-words whitespace-break-spaces">${value()}</p>`
						})),
						getValue()
					);
				}
			},
			{
				accessorKey: 'admin_notes',
				header: 'Admin Notes'
			}
		],
		get data() {
			return waitlistData.data ?? [];
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
		state: {
			get pagination() {
				return {
					pageIndex: currentPage,
					pageSize
				} as PaginationState;
			},
			get sorting() {
				return sortingState;
			}
		},
		rowCount: waitlistData?.count ?? 0,
		getCoreRowModel: getCoreRowModel(),
		getPaginationRowModel: getPaginationRowModel(),
		getSortedRowModel: getSortedRowModel()
	});
	const table = createSvelteTable(tableOptions);
</script>

<h1 class="prose prose-h1 text-xl ml-2">Beginners Workshop Waitlist</h1>
<div class="rounded-md border min-h-96 m-10 p-2">
	<div class="overflow-y-auto h-[75vh]">
		<Table.Root class="table-fixed w-full">
			<Table.Header class="sticky top-0 z-10 bg-white">
				{#each table.getHeaderGroups() as headerGroup (headerGroup.id)}
					{#each headerGroup.headers as header (header.id)}
						<Table.Head class="text-black prose prose-p  text-sm font-medium">
							<FlexRender content={header.column.columnDef.header} context={header.getContext()} />
						</Table.Head>
					{/each}
				{/each}
			</Table.Header>
			<Table.Body>
				{#each table.getRowModel().rows as row (row.id)}
					<Table.Row>
						{#each row.getVisibleCells() as cell (cell.id)}
							<Table.Cell class="whitespace-nowrap py-4 px-3 text-sm prose prose-p">
								<FlexRender content={cell.column.columnDef.cell} context={cell.getContext()} />
							</Table.Cell>
						{/each}
					</Table.Row>
				{/each}
			</Table.Body>
			<Table.Footer class="sticky bottom-0 z-10 bg-white">
				{#each table.getFooterGroups() as footerGroup}
					<Table.Row>
						{#each footerGroup.headers as header}
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
	<div class="flex items-start justify-end space-x-2 py-4 mr-4">
		<div class="flex items-center gap-2 mr-auto ml-4">
			<p class="prose">Elements per page</p>
			<Select.Root
				type="single"
				value={pageSize.toString()}
				onValueChange={(value) => onPaginationChange({ pageSize: Number(value) })}
			>
				<Select.Trigger class="w-16">{pageSize}</Select.Trigger>
				<Select.Content>
					{#each pageSizeOptions as pageSizeOption}
						<Select.Item value={pageSizeOption.toString()}>
							{pageSizeOption}
						</Select.Item>
					{/each}
				</Select.Content>
			</Select.Root>
		</div>
		<Pagination.Root
			count={waitlistData?.count ?? 0}
			perPage={pageSize}
			page={currentPage + 1}
			onPageChange={(page) => table.setPageIndex(page - 1)}
			class="m-0 w-auto"
		>
			{#snippet children({ pages, currentPage })}
				<Pagination.Content>
					<Pagination.Item>
						<Pagination.PrevButton />
					</Pagination.Item>
					{#each pages as page (page.key)}
						{#if page.type === 'ellipsis'}
							<Pagination.Item>
								<Pagination.Ellipsis />
							</Pagination.Item>
						{:else}
							<Pagination.Item>
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
