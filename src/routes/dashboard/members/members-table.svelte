<script lang="ts">
import {
	type Member,
	type MembersListSortField,
	membersList,
} from "@dhc/api-client";
import { createQuery, keepPreviousData } from "@tanstack/svelte-query";
import {
	getCoreRowModel,
	getExpandedRowModel,
	getSortedRowModel,
	type SortingState,
	type TableOptions,
} from "@tanstack/table-core";
import dayjs from "dayjs";
import { createRawSnippet } from "svelte";
import { SvelteURLSearchParams } from "svelte/reactivity";
import { Cross2 } from "svelte-radix";
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { page } from "$app/state";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
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
import SortHeader from "$lib/components/ui/table/sort-header.svelte";
import MemberActions from "./member-actions.svelte";

type MemberTableRow = {
	id: string;
	first_name: string;
	last_name: string;
	email: string;
	phone_number: string | null;
	gender: string | null;
	pronouns: string | null;
	is_active: boolean;
	preferred_weapon: string[];
	membership_start_date: string | null;
	membership_end_date: string | null;
	last_payment_date: string | null;
	insurance_form_submitted: boolean;
	age: number | null;
	social_media_consent: "no" | "yes_recognizable" | "yes_unrecognizable";
	next_of_kin_name: string | null;
	next_of_kin_phone: string | null;
	guardian_first_name: string | null;
	guardian_last_name: string | null;
	guardian_phone_number: string | null;
	medical_conditions: string | null;
	subscription_paused_until: string | null;
	membership_status: "active" | "inactive" | "paused";
};

type MemberTableQueryParams = {
	searchQuery: string;
	sort: MemberTableSortField;
	direction: "asc" | "desc";
	pageSize: (typeof pageSizeOptions)[number];
	membershipStatus: readonly MemberStatusFilter[] | null;
	cursor: string | null;
};

type MemberTablePage = {
	data: MemberTableRow[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};

const pageSizeOptions = [10, 25, 50, 100] as const;

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

const memberSortMap: Record<MemberTableSortField, MembersListSortField> = {
	first_name: "firstName",
	last_name: "lastName",
	email: "email",
	phone_number: "phoneNumber",
	age: "age",
	membership_start_date: "membershipStartDate",
	last_payment_date: "lastPaymentDate",
	subscription_paused_until: "subscriptionPausedUntil",
	is_active: "isActive",
};

const statusOptions = ["active", "inactive", "paused"] as const;
type MemberStatusFilter = (typeof statusOptions)[number];

type MembersUrl = `/dashboard/members?${string}`;

function navigateToMembers(searchParams: URLSearchParams) {
	const url = `/dashboard/members?${searchParams.toString()}` as MembersUrl;
	goto(resolve(url), { keepFocus: true, noScroll: true });
}

const pageSize = $derived.by(() => {
	const requestedPageSize = Number(page.url.searchParams.get("pageSize")) || 10;
	return pageSizeOptions.includes(requestedPageSize as 10 | 25 | 50 | 100)
		? requestedPageSize
		: 10;
});
const searchQuery = $derived(page.url.searchParams.get("q") || "");
const cursor = $derived(page.url.searchParams.get("cursor"));
const membershipStatusFilter = $derived.by(() => {
	const raw = page.url.searchParams.get("membershipStatus") || "";
	const selected = raw
		.split(",")
		.map((status) => status.trim())
		.filter(
			(status): status is MemberStatusFilter =>
				status === "active" || status === "inactive" || status === "paused",
		);
	if (selected.length === 0) {
		return null;
	}
	return statusOptions.filter((status) => selected.includes(status));
});
const activeSort = $derived.by(() => {
	const requestedSortColumn = page.url.searchParams.get("sort");
	const sortColumn = memberSortFields.includes(
		requestedSortColumn as (typeof memberSortFields)[number],
	)
		? requestedSortColumn!
		: "last_name";
	const sortDirection = page.url.searchParams.get("direction");

	return {
		sort: sortColumn as MemberTableSortField,
		direction: sortDirection === "desc" ? "desc" : "asc",
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

const membersQueryParams = $derived<MemberTableQueryParams>({
	searchQuery,
	sort: activeSort.sort,
	direction: activeSort.direction,
	pageSize: pageSize as (typeof pageSizeOptions)[number],
	membershipStatus: membershipStatusFilter,
	cursor,
});

async function loadMembersTablePage(
	params: MemberTableQueryParams,
): Promise<MemberTablePage> {
	const response = await membersList({
		query: {
			limit: params.pageSize,
			cursor: params.cursor ?? undefined,
			q: params.searchQuery || undefined,
			membershipStatus:
				params.membershipStatus && params.membershipStatus.length > 0
					? params.membershipStatus.join(",")
					: undefined,
			sort: memberSortMap[params.sort],
			direction: params.direction,
		},
	});

	if (response.error) {
		throw new Error("Failed to load members. Please try again later.");
	}

	const result = response.data.data;

	return {
		data: result.members.map(toTableRow),
		count: result.totalCount,
		nextCursor: result.nextCursor,
		previousCursor: result.previousCursor,
	};
}

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

const membersQueryKey = $derived(["members", membersQueryParams]);
const membersQuery = createQuery<MemberTablePage>(() => ({
	queryKey: membersQueryKey,
	placeholderData: keepPreviousData,
	queryFn: ({ signal, queryKey }) => {
		signal.throwIfAborted();
		return loadMembersTablePage(queryKey[1] as MemberTableQueryParams);
	},
}));

function onPaginationChange(newPageSize: number) {
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("pageSize", newPageSize.toString());
	newParams.delete("cursor");
	navigateToMembers(newParams);
}

function onCursorChange(newCursor: string | null | undefined) {
	if (!newCursor) return;
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("cursor", newCursor);
	navigateToMembers(newParams);
}

function onSortingChange(newSorting: SortingState) {
	const [sortingState] = newSorting;
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("sort", sortingState.id);
	newParams.set("direction", sortingState.desc ? "desc" : "asc");
	newParams.delete("cursor");
	navigateToMembers(newParams);
}

function onSearchChange(newSearch: string) {
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	newParams.set("q", newSearch);
	newParams.delete("cursor");
	navigateToMembers(newParams);
}

function onStatusFilterChange(
	status: MemberStatusFilter,
	checked: boolean | "indeterminate",
) {
	const current = membershipStatusFilter ?? [...statusOptions];
	const next = checked
		? statusOptions.filter(
				(value) => value === status || current.includes(value),
			)
		: current.filter((value) => value !== status);
	const newParams = new SvelteURLSearchParams(page.url.searchParams);
	if (next.length === 0 || next.length === statusOptions.length) {
		newParams.delete("membershipStatus");
	} else {
		newParams.set("membershipStatus", next.join(","));
	}
	newParams.delete("cursor");
	navigateToMembers(newParams);
}

// State for expanded rows
let expandedState = $state({});

const tableOptions = $state<TableOptions<MemberTableRow>>({
	autoResetPageIndex: false,
	manualPagination: true,
	manualSorting: true,
	getExpandedRowModel: getExpandedRowModel(),
	columns: [
		{
			id: "actions",
			header: "Actions",
			cell: ({ row }) => {
				return renderComponent(MemberActions, {
					memberId: row.original.id,
					isExpanded: row.getIsExpanded(),
					onToggleExpand: () => row.toggleExpanded(),
				});
			},
		},
		{
			accessorKey: "first_name",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "First Name",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
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
			accessorKey: "last_name",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Last Name",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
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
			accessorKey: "phone_number",
			header: "Phone Number",
			cell: ({ getValue }) => {
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () => `<div class="w-[120px]">${value() ?? "N/A"}</div>`,
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "is_active",
			header: "Status",
			cell: ({ row, getValue }) => {
				if (row.original.membership_status === "paused") {
					return renderComponent(Badge, {
						variant: "secondary",
						class: "h-6",
						children: createRawSnippet(() => ({
							render: () => "Paused",
						})),
					});
				}

				return renderComponent(Badge, {
					variant: getValue() ? "default" : "destructive",
					class: "h-6",
					children: createRawSnippet(() => ({
						render: () =>
							`<p class="capitalize">${getValue() ? "Active" : "Inactive"}</p>`,
					})),
				});
			},
		},
		{
			accessorKey: "subscription_paused_until",
			header: "Subscription",
			cell: ({ row }) => {
				const pausedUntil = row.original.subscription_paused_until;
				const isActive = row.original.is_active;

				if (!isActive) {
					return renderComponent(Badge, {
						variant: "destructive",
						class: "h-6",
						children: createRawSnippet(() => ({ render: () => "Inactive" })),
					});
				}

				if (pausedUntil && dayjs(pausedUntil).isAfter(dayjs())) {
					return renderComponent(Badge, {
						variant: "secondary",
						class: "h-6",
						children: createRawSnippet(() => ({
							render: () =>
								`Paused until ${dayjs(pausedUntil).format("MMM D, YYYY")}`,
						})),
					});
				}

				return renderComponent(Badge, {
					variant: "default",
					class: "h-6",
					children: createRawSnippet(() => ({ render: () => "Active" })),
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
							const age = value();
							return `<div class="w-[120px] ${age !== null && age < 18 ? "text-red-800" : ""}">${age === null ? "N/A" : age < 18 ? age + "(👶)" : age}</div>`;
						},
					})),
					getValue(),
				);
			},
		},
		{
			accessorKey: "social_media_consent",
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
			accessorKey: "preferred_weapon",
			header: "Weapons",
			cell: ({ getValue }) => {
				const weapons = getValue() as string[];
				return renderSnippet(
					createRawSnippet(() => ({
						render: () =>
							`<div class="flex gap-1 flex-wrap">${weapons
								.map(
									(w) =>
										`<span class="bg-primary/10 text-primary rounded px-2 py-1 text-sm first-letter:capitalize">${w.replace(
											/[-_]/g,
											" ",
										)}</span>`,
								)
								.join("")}</div>`,
					})),
					weapons,
				);
			},
		},
		{
			accessorKey: "membership_start_date",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Member Since",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ getValue }) => {
				const date = getValue() as string | null;
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () =>
							`<p>${value() ? dayjs(value()).format("MMM D, YYYY") : "Never"}</p>`,
					})),
					date,
				);
			},
		},
		{
			accessorKey: "last_payment_date",
			header: ({ column }) =>
				renderComponent(SortHeader, {
					onclick: () => column.toggleSorting(column.getIsSorted() === "asc"),
					header: "Last Payment",
					class: "p-2",
					sortDirection: column.getIsSorted(),
				}),
			cell: ({ getValue }) => {
				const date = getValue() as string | null;
				return renderSnippet(
					createRawSnippet((value) => ({
						render: () =>
							`<p>${value() ? dayjs(value()).format("MMM D, YYYY") : "Never"}</p>`,
					})),
					date,
				);
			},
		},
	],
	get data() {
		return membersQuery?.data?.data ?? [];
	},
	onSortingChange: (updater) => {
		if (typeof updater === "function") {
			onSortingChange(updater(sortingState));
		} else {
			onSortingChange(updater);
		}
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
		if (typeof updater === "function") {
			expandedState = updater(expandedState);
		} else {
			expandedState = updater;
		}
	},
	getCoreRowModel: getCoreRowModel(),
	getSortedRowModel: getSortedRowModel(),
});

const table = createSvelteTable(tableOptions);
</script>

<div class="flex w-full items-center gap-2 mb-2 p-2 flex-wrap">
	<Input
		value={searchQuery}
		oninput={(t: Event & { currentTarget: EventTarget & HTMLInputElement }) =>
			onSearchChange(t.currentTarget.value)}
		placeholder="Search members"
		class="max-w-md"
	/>

	<div class="flex items-center gap-3 rounded-md border px-3 py-2">
		<p class="text-sm text-muted-foreground">Status</p>
		{#each statusOptions as status (status)}
			<label class="flex items-center gap-2 text-sm capitalize">
				<Checkbox
					checked={(membershipStatusFilter ?? [...statusOptions]).includes(status)}
					onCheckedChange={(checked) => onStatusFilterChange(status, checked)}
				/>
				{status}
			</label>
		{/each}
	</div>

	{#if searchQuery !== ''}
		<Button variant="ghost" type="button" aria-label="Clear search" onclick={() => onSearchChange('')}>
			<Cross2 />
		</Button>
	{/if}
	{#if membersQuery.isFetching}
		<LoaderCircle />
	{/if}
</div>

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
				{#if row.getIsExpanded()}
					<Table.Row>
						<Table.Cell colspan={row.getVisibleCells().length} class="p-4 bg-muted/20">
							<div class="grid grid-cols-1 md:grid-cols-3 gap-4">
								<!-- Next of Kin Information -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Next of Kin Information</h3>
									<div class="grid grid-cols-3 gap-2">
										<div class="text-xs font-medium text-muted-foreground">Name</div>
										<div class="col-span-2 text-xs">
											{row.original.next_of_kin_name || 'N/A'}
										</div>

										<div class="text-xs font-medium text-muted-foreground">Phone</div>
										<div class="col-span-2 text-xs">
											{row.original.next_of_kin_phone || 'N/A'}
										</div>
									</div>
								</div>

								<!-- Guardian Information -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
									{#if row.original.guardian_first_name || row.original.guardian_last_name || row.original.guardian_phone_number}
										<div class="grid grid-cols-3 gap-2">
											<div class="text-xs font-medium text-muted-foreground">Name</div>
											<div class="col-span-2 text-xs">
												{row.original.guardian_first_name || ''}
												{row.original.guardian_last_name || ''}
											</div>

											<div class="text-xs font-medium text-muted-foreground">Phone</div>
											<div class="col-span-2 text-xs">
												{row.original.guardian_phone_number || 'N/A'}
											</div>
										</div>
									{:else}
										<p class="text-xs text-muted-foreground">No guardian information available</p>
									{/if}
								</div>

								<!-- Medical Conditions -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
									<p class="text-xs">
										{row.original.medical_conditions || 'None reported'}
									</p>
								</div>
							</div>
						</Table.Cell>
					</Table.Row>
				{/if}
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
				<!-- Name and Actions Row -->
				<div class="flex justify-between items-center mb-3">
					<div class="font-medium text-base">
						{row.original.first_name}
						{row.original.last_name}
					</div>
					<div>
						<MemberActions
							memberId={row.original.id}
							isExpanded={row.getIsExpanded()}
							onToggleExpand={() => row.toggleExpanded()}
						/>
					</div>
				</div>

				<!-- Email -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Email</div>
					<div class="col-span-2 text-sm break-words">{row.original.email}</div>
				</div>

				<!-- Phone -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Phone</div>
					<div class="col-span-2 text-sm">{row.original.phone_number || 'N/A'}</div>
				</div>

				<!-- Gender -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Gender</div>
					<div class="col-span-2 text-sm capitalize">{row.original.gender || 'N/A'}</div>
				</div>

				<!-- Age -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Age</div>
					<div class="col-span-2 text-sm">{row.original.age ?? 'N/A'}</div>
				</div>

				<!-- Social Media Consent -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Social Consent</div>
					<div class="col-span-2">
						<Badge
							variant={row.original.social_media_consent === 'yes_recognizable' ||
							row.original.social_media_consent === 'yes_unrecognizable'
								? 'default'
								: 'destructive'}
							class="h-6"
						>
							<p class="capitalize">
								{row.original.social_media_consent?.replace('_', ' ') ?? 'Unknown'}
							</p>
						</Badge>
					</div>
				</div>

				<!-- Subscription Status -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Subscription</div>
					<div class="col-span-2">
						{#if !row.original.is_active}
							<Badge variant="destructive" class="h-6">
								<p>Inactive</p>
							</Badge>
						{:else if row.original.subscription_paused_until && dayjs(row.original.subscription_paused_until).isAfter(dayjs())}
							<Badge variant="secondary" class="h-6">
								<p>
									Paused until {dayjs(row.original.subscription_paused_until).format('MMM D, YYYY')}
								</p>
							</Badge>
						{:else}
							<Badge variant="default" class="h-6">
								<p>Active</p>
							</Badge>
						{/if}
					</div>
				</div>

				<!-- Preferred Weapon -->
				<div class="grid grid-cols-3 py-1 border-b">
					<div class="text-sm font-medium text-muted-foreground">Weapons</div>
					<div class="col-span-2 text-sm">
						{#if row.original.preferred_weapon}
							{#each row.original.preferred_weapon as weapon (weapon)}
								<Badge variant="outline" class="mr-1 mb-1 capitalize">
									{weapon.replace(/_/g, ' ')}
								</Badge>
							{/each}
						{:else}
							None specified
						{/if}
					</div>
				</div>

				<!-- Member Since -->
				<div class="grid grid-cols-3 py-1">
					<div class="text-sm font-medium text-muted-foreground">Member Since</div>
					<div class="col-span-2 text-sm">
						{#if row.original.membership_start_date}
							{dayjs(row.original.membership_start_date).format('MMM D, YYYY')}
						{:else}
							Never
						{/if}
					</div>
				</div>

				<!-- Expanded Content -->
				{#if row.getIsExpanded()}
					<div class="mt-4 pt-4 border-t border-muted">
						<!-- Next of Kin Information -->
						<div class="mb-4">
							<h3 class="text-sm font-medium mb-2">Next of Kin Information</h3>
							<div class="grid grid-cols-3 gap-2">
								<div class="text-xs font-medium text-muted-foreground">Name</div>
								<div class="col-span-2 text-xs">
									{row.original.next_of_kin_name || 'N/A'}
								</div>

								<div class="text-xs font-medium text-muted-foreground">Phone</div>
								<div class="col-span-2 text-xs">
									{row.original.next_of_kin_phone || 'N/A'}
								</div>
							</div>
						</div>

						<!-- Guardian Information -->
						<div class="mb-4">
							<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
							{#if row.original.guardian_first_name || row.original.guardian_last_name || row.original.guardian_phone_number}
								<div class="grid grid-cols-3 gap-2">
									<div class="text-xs font-medium text-muted-foreground">Name</div>
									<div class="col-span-2 text-xs">
										{row.original.guardian_first_name || ''}
										{row.original.guardian_last_name || ''}
									</div>

									<div class="text-xs font-medium text-muted-foreground">Phone</div>
									<div class="col-span-2 text-xs">
										{row.original.guardian_phone_number || 'N/A'}
									</div>
								</div>
							{:else}
								<p class="text-xs text-muted-foreground">No guardian information available</p>
							{/if}
						</div>

						<!-- Medical Conditions -->
						<div>
							<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
							<p class="text-xs">
								{row.original.medical_conditions || 'None reported'}
							</p>
						</div>
					</div>
				{/if}
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
			onValueChange={(value) => onPaginationChange(Number(value))}
		>
			<Select.Trigger class="w-16 h-8" aria-label="Members elements per page">
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
			disabled={!membersQuery?.data?.previousCursor || membersQuery.isFetching}
			onclick={() => onCursorChange(membersQuery?.data?.previousCursor)}
		>
			Previous
		</Button>
		<p class="text-sm text-muted-foreground">
			{membersQuery?.data?.count ?? 0} total
		</p>
		<Button
			variant="outline"
			disabled={!membersQuery?.data?.nextCursor || membersQuery.isFetching}
			onclick={() => onCursorChange(membersQuery?.data?.nextCursor)}
		>
			Next
		</Button>
	</div>
</div>