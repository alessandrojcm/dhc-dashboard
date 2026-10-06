<script lang="ts">
import {
	invitationsCreateMutation,
	invitationsResendMutation,
	type InvitationsCreateData,
	type Options,
	type WaitlistEntriesResponse2,
	type WaitlistEntry,
	type WaitlistStatus,
	waitlistEntriesOptions,
	waitlistEntriesQueryKey,
	waitlistUpdateEntryMutation,
} from "@dhc/api-client";
import {
	createMutation,
	createQuery,
	keepPreviousData,
	useQueryClient,
} from "@tanstack/svelte-query";
import {
	getCoreRowModel,
	getExpandedRowModel,
	getPaginationRowModel,
	getSortedRowModel,
	type RowSelectionState,
	type TableOptions,
} from "@tanstack/table-core";
import dayjs from "dayjs";
import { LoaderCircle, SendIcon } from "@lucide/svelte";
import { createRawSnippet } from "svelte";
import { Cross2 } from "svelte-radix";
import { toast } from "svelte-sonner";
import * as v from "valibot";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button } from "#lib/components/ui/button/index.js";
import * as Checkbox from "#lib/components/ui/checkbox/index.js";
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
import { PAGE_SIZE_OPTIONS } from "#lib/cursor-query.js";
import { createCursorTableUrl } from "#lib/cursor-table-url.svelte.js";
import ActionButtons from "./actions-buttons.svelte";
import WaitlistStatusSelect from "./waitlist-status-select.svelte";

type WaitlistTablePage = {
	data: WaitlistEntry[];
	count: number;
	nextCursor: string | null;
	previousCursor: string | null;
};

type InvitationsCreateOptions = Options<InvitationsCreateData>;

// Column ids are the API sort names, so the URL `sort` param is one too.
const waitlistUrl = createCursorTableUrl({
	sort: {
		fields: {
			position: "position",
			fullName: "fullName",
			status: "status",
			age: "age",
			initialRegistrationDate: "initialRegistrationDate",
			lastContacted: "lastContacted",
			lastStatusChange: "lastStatusChange",
		},
		default: "position",
	},
});

const waitlistRequestOptions = $derived({ query: waitlistUrl.request });
const waitlistQueryKey = $derived(
	waitlistEntriesQueryKey(waitlistRequestOptions),
);
const waitlistQuery = createQuery(() => ({
	...waitlistEntriesOptions(waitlistRequestOptions),
	placeholderData: keepPreviousData,
	select: (response): WaitlistTablePage => {
		const result = response.data;
		return {
			data: result.entries,
			count: result.totalCount,
			nextCursor: result.nextCursor,
			previousCursor: result.previousCursor,
		};
	},
}));
const queryClient = useQueryClient();

function getWaitlistIds(options: InvitationsCreateOptions) {
	return options.body.invites.flatMap((invite) => {
		const parsed = v.safeParse(v.string(), invite);
		return parsed.success ? [parsed.output] : [];
	});
}

const inviteMember = createMutation(() => ({
	...invitationsCreateMutation(),
	onMutate: (options) => {
		const waitlistIds = getWaitlistIds(options);
		const oldData = queryClient.getQueryData(waitlistQueryKey);
		queryClient.setQueryData(
			waitlistQueryKey,
			(oldData: WaitlistEntriesResponse2 | undefined) => {
				if (!oldData) return oldData;
				return {
					...oldData,
					data: {
						...oldData.data,
						entries: oldData.data.entries.map((entry) =>
							waitlistIds.includes(entry.id)
								? { ...entry, status: "invited" }
								: entry,
						),
					},
				};
			},
		);
		return { oldData };
	},
	onSuccess: () => {
		selectedState = {};
		toast.success("Invitations are being processed in the background.");
	},
	onError: (_error, _options, context) => {
		toast.error("Something has gone wrong inviting members.");
		queryClient.setQueryData(waitlistQueryKey, context?.oldData);
	},
}));

function inviteWaitlistMembers(waitlistIds: string[]) {
	inviteMember.mutate({ body: { invites: waitlistIds } });
}

const resendInvitationLink = createMutation(() => ({
	...invitationsResendMutation(),
	onMutate: (options) => {
		const emails = options.body.emails;
		const oldData = queryClient.getQueryData(waitlistQueryKey);
		queryClient.setQueryData(
			waitlistQueryKey,
			(oldData: WaitlistEntriesResponse2 | undefined) => {
				if (!oldData) return oldData;
				return {
					...oldData,
					data: {
						...oldData.data,
						entries: oldData.data.entries.map((entry) =>
							emails.includes(entry.email)
								? { ...entry, status: "invited" }
								: entry,
						),
					},
				};
			},
		);
		return { oldData };
	},
	onSuccess: () => {
		toast.success("Invitation link resent.");
	},
	onError: (_error, _options, context) => {
		toast.error("Something has gone wrong inviting members.");
		queryClient.setQueryData(waitlistQueryKey, context?.oldData);
	},
}));

const updateWaitlistEntry = createMutation(() => ({
	...waitlistUpdateEntryMutation(),
	onSuccess: () => {
		toast.success("Waitlist entry updated.");
		waitlistQuery.refetch();
	},
	onError: () => {
		toast.error("Failed to update waitlist entry.");
	},
	onSettled: () => {
		waitlistQuery.refetch();
	},
}));

// State for expanded rows
let expandedState = $state({});
let selectedState = $state<RowSelectionState>({});
let inviteCount = $derived(Object.values(selectedState).filter(Boolean).length);

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
	onRowSelectionChange: (updater) => {
		if (updater instanceof Function) {
			selectedState = updater(selectedState);
		} else {
			selectedState = updater;
		}
	},
	columns: [
		{
			header: "",
			id: "selection",
			cell: ({ row }) => {
				return renderComponent(Checkbox.Checkbox, {
					checked: row.getIsSelected(),
					onCheckedChange: (value: boolean | "indeterminate") =>
						row.toggleSelected(!!value),
					disabled: row.original.status === "invited",
				});
			},
		},
		{
			header: "Actions",
			cell: ({ row }) => {
				return renderComponent(ActionButtons, {
					adminNotes: row.original.adminNotes ?? "N/A",
					isExpanded: row.getIsExpanded(),
					onToggleExpand: () => row.toggleExpanded(),
					inviteMember: () => {
						if (row.original.status !== "invited") {
							inviteWaitlistMembers([row.original.id]);
						} else {
							resendInvitationLink.mutate({
								body: { emails: [row.original.email] },
							});
						}
					},
					onEdit(newValue) {
						updateWaitlistEntry.mutate({
							path: { id: row.original.id },
							body: { adminNotes: newValue },
						});
					},
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
				`Total ${table.getRowCount() ?? 0} people on the waitlist`,
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
				return renderComponent(WaitlistStatusSelect, {
					status: row.original.status,
					disabled: updateWaitlistEntry.isPending,
					onChange: (status: WaitlistStatus) => {
						if (status === row.original.status) return;
						updateWaitlistEntry.mutate({
							path: { id: row.original.id },
							body: { status },
						});
					},
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
		return waitlistQuery?.data?.data ?? [];
	},
	onPaginationChange: waitlistUrl.table.onPaginationChange,
	onSortingChange: waitlistUrl.table.onSortingChange,
	get rowCount() {
		return waitlistQuery?.data?.count ?? 0;
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
		{#if waitlistQuery.isFetching}
			<LoaderCircle />
		{/if}
	</span>

	<Button
		class="md:ml-auto"
		disabled={inviteCount === 0 || inviteMember.isPending}
		onclick={() => inviteWaitlistMembers(Object.keys(selectedState))}
	>
		{#if inviteMember.isPending}
			<LoaderCircle class="mr-2 h-4 w-4 animate-spin" />
		{:else}
			<SendIcon class="mr-2 h-4 w-4" />
		{/if}
		Invite {inviteCount} members
	</Button>
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
							<div class="grid grid-cols-1 md:grid-cols-2 gap-4">
								<!-- Guardian Information -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
									{#if row.original.guardianFirstName || row.original.guardianLastName || row.original.guardianPhoneNumber}
										<div class="grid grid-cols-3 gap-2">
											<div class="text-xs font-medium text-muted-foreground">
												Name
											</div>
											<div class="col-span-2 text-xs">
												{row.original.guardianFirstName || ""}
												{row.original.guardianLastName || ""}
											</div>

											<div class="text-xs font-medium text-muted-foreground">
												Phone
											</div>
											<div class="col-span-2 text-xs">
												{row.original.guardianPhoneNumber || "N/A"}
											</div>
										</div>
									{:else}
										<p class="text-xs text-muted-foreground">
											No guardian information available
										</p>
									{/if}
								</div>

								<!-- Medical Conditions -->
								<div class="bg-card rounded-lg border p-4">
									<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
									<p class="text-xs">
										{row.original.medicalConditions || "None reported"}
									</p>
								</div>
							</div>
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
	<div class="space-y-4">
		{#if table.getRowCount() === 0}
			<p class="text-foreground">No results found</p>
		{/if}
		{#each table.getRowModel().rows as row (row.id)}
			<div class="bg-card text-card-foreground rounded-lg border shadow-sm p-4">
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
							inviteMember={() => {
								if (row.original.status !== "invited") {
									inviteWaitlistMembers([row.original.id]);
								} else {
									resendInvitationLink.mutate({
										body: { emails: [row.original.email] },
									});
								}
							}}
							adminNotes={row.original.adminNotes ?? "N/A"}
							isExpanded={row.getIsExpanded()}
							onToggleExpand={() => row.toggleExpanded()}
							onEdit={(newValue) => {
								if (row.original.email) {
									updateWaitlistEntry.mutate({
										path: { id: row.original.id },
										body: { adminNotes: newValue },
									});
								}
							}}
						/>
					</div>
				</div>

				<!-- Status -->
				<div class="mb-3">
					<WaitlistStatusSelect
						status={row.original.status}
						disabled={updateWaitlistEntry.isPending}
						onChange={(status) => {
							if (status === row.original.status) return;
							updateWaitlistEntry.mutate({
								path: { id: row.original.id },
								body: { status },
							});
						}}
					/>
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
						<!-- Guardian Information -->
						<div class="mb-4">
							<h3 class="text-sm font-medium mb-2">Guardian Information</h3>
							{#if row.original.guardianFirstName || row.original.guardianLastName || row.original.guardianPhoneNumber}
								<div class="grid grid-cols-3 gap-2">
									<div class="text-xs font-medium text-muted-foreground">
										Name
									</div>
									<div class="col-span-2 text-xs">
										{row.original.guardianFirstName || ""}
										{row.original.guardianLastName || ""}
									</div>

									<div class="text-xs font-medium text-muted-foreground">
										Phone
									</div>
									<div class="col-span-2 text-xs">
										{row.original.guardianPhoneNumber || "N/A"}
									</div>
								</div>
							{:else}
								<p class="text-xs text-muted-foreground">
									No guardian information available
								</p>
							{/if}
						</div>

						<!-- Medical Conditions -->
						<div>
							<h3 class="text-sm font-medium mb-2">Medical Conditions</h3>
							<p class="text-xs">
								{row.original.medicalConditions || "None reported"}
							</p>
						</div>
					</div>
				{/if}
			</div>
		{/each}
	</div>
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
			disabled={!waitlistQuery?.data?.previousCursor ||
				waitlistQuery.isFetching}
			onclick={() => waitlistUrl.goTo(waitlistQuery?.data?.previousCursor)}
		>
			Previous
		</Button>
		<p class="text-sm text-muted-foreground">
			{waitlistQuery?.data?.count ?? 0} total
		</p>
		<Button
			variant="outline"
			disabled={!waitlistQuery?.data?.nextCursor || waitlistQuery.isFetching}
			onclick={() => waitlistUrl.goTo(waitlistQuery?.data?.nextCursor)}
		>
			Next
		</Button>
	</div>
</div>
