<script lang="ts">
import type {
	InventoryOperatorItemValues,
	InventoryPropertyDefinition,
} from "@dhc/api-client";
import {
	archiveItem,
	changeItemCategory,
	createItem,
	deleteItem,
	endItemMaintenance,
	moveItem,
	restoreItem,
	startItemMaintenance,
	updateItem,
} from "./data.remote";
import {
	ARCHIVE_FILTERS,
	AVAILABILITY_FILTERS,
	availabilityLabel,
	createItemWorkbench,
	type DraftTarget,
} from "./item-workbench.svelte.js";
import {
	BOOLEAN_CHOICES,
	draftInput,
	formatPropertyValues,
} from "#lib/inventory/property-values.js";
import {
	archiveItemSchema,
	changeItemCategorySchema,
	createItemSchema,
	deleteItemSchema,
	endItemMaintenanceSchema,
	moveItemSchema,
	restoreItemSchema,
	startItemMaintenanceSchema,
	updateItemSchema,
} from "#lib/schemas/inventoryItem.js";
import { Alert, AlertDescription } from "#lib/components/ui/alert/index.js";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import { Button, buttonVariants } from "#lib/components/ui/button/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import * as Select from "#lib/components/ui/select/index.js";
import * as Sheet from "#lib/components/ui/sheet/index.js";
import * as Tabs from "#lib/components/ui/tabs/index.js";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import InventoryPageHeader from "#lib/components/inventory/InventoryPageHeader.svelte";
import SubmitButton from "#lib/components/ui/submit-button.svelte";
import { apiErrorMessage } from "#lib/api-error.js";
import {
	Archive,
	ArrowLeft,
	LoaderCircle,
	MapPin,
	NotebookPen,
	PackageSearch,
	PackagePlus,
	RefreshCw,
	RotateCcw,
	SlidersHorizontal,
	Tags,
	Trash2,
} from "@lucide/svelte";

const workbench = createItemWorkbench();

let mobileFiltersOpen = $state(false);

type FormIssue = NonNullable<
	ReturnType<typeof createItem.fields.allIssues>
>[number];

/** Form-level issues; property value issues render under the properties. */
function formIssues(issues: FormIssue[] | undefined) {
	return (issues ?? []).filter((issue) => issue.path[0] !== "values");
}

function booleanLabel(input: string) {
	return (
		BOOLEAN_CHOICES.find((choice) => choice.value === input)?.label ?? "Not set"
	);
}
</script>

{#snippet fields(
	definitions: InventoryPropertyDefinition[],
	draft: InventoryOperatorItemValues,
	target: DraftTarget,
	valueIssues: FormIssue[] | undefined,
)}
	{#each definitions.filter((definition) => !definition.retiredAt) as definition (definition.id)}
		{@const input = draftInput(draft, definition.id)}
		<div>
			<Label for={`${target}-${definition.id}`} class="mb-2.5">
				{definition.label}{#if definition.required}<span
						class="ml-1 text-xs font-normal text-muted-foreground"
						>(required)</span
					>{/if}
			</Label>
			{#if definition.valueType === "boolean"}
				<Select.Root
					type="single"
					bind:value={
						() => input,
						(value) => workbench.setValue(target, definition, value)
					}
					required={definition.required}
				>
					<Select.Trigger
						id={`${target}-${definition.id}`}
						class="w-full data-[size=default]:h-11"
					>
						{booleanLabel(input)}
					</Select.Trigger>
					<Select.Content portalProps={{ disabled: true }}>
						{#each BOOLEAN_CHOICES as choice (choice.value)}
							<Select.Item value={choice.value} label={choice.label}>
								{choice.label}
							</Select.Item>
						{/each}
					</Select.Content>
				</Select.Root>
			{:else if definition.valueType === "single_select"}
				{@const activeOptions = definition.options.filter(
					(option) => !option.retiredAt,
				)}
				<Select.Root
					type="single"
					bind:value={
						() => input,
						(value) => workbench.setValue(target, definition, value)
					}
					required={definition.required}
				>
					<Select.Trigger
						id={`${target}-${definition.id}`}
						class="w-full data-[size=default]:h-11"
					>
						{activeOptions.find((option) => option.id === input)?.label ??
							"Choose"}
					</Select.Trigger>
					<Select.Content portalProps={{ disabled: true }}>
						{#each activeOptions as option (option.id)}
							<Select.Item value={option.id} label={option.label}>
								{option.label}
							</Select.Item>
						{/each}
					</Select.Content>
				</Select.Root>
			{:else}
				<Input
					id={`${target}-${definition.id}`}
					type={definition.valueType === "decimal" ? "number" : "text"}
					step={definition.valueType === "decimal" ? "any" : undefined}
					value={input}
					oninput={(event) =>
						workbench.setValue(target, definition, event.currentTarget.value)}
					required={definition.required}
				/>
			{/if}
		</div>
	{/each}
	<Field.Error errors={valueIssues} />
{/snippet}

<svelte:head>
	<title
		>{workbench.creating
			? "Add inventory item"
			: workbench.selected?.label
				? `${workbench.selected.label} | Inventory items`
				: "Inventory items"} | Dublin HEMA Club</title
	>
</svelte:head>

{#snippet createAction()}
	<Button href={workbench.newItemHref}>
		<PackagePlus aria-hidden="true" />New item
	</Button>
{/snippet}

<div
	class="inventory-page {workbench.routed && !workbench.creating
		? 'space-y-4 xl:py-4'
		: 'xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:space-y-4 xl:overflow-hidden xl:py-4'} {workbench.routed
		? 'max-lg:max-w-none max-lg:space-y-0 max-lg:px-0 max-lg:py-0'
		: ''}"
>
	<InventoryPageHeader
		eyebrow="Quartermaster"
		title="Items"
		icon={PackageSearch}
		actions={workbench.routed ? undefined : createAction}
		class="flex-row items-end justify-between xl:pb-3 {workbench.routed
			? 'max-lg:hidden'
			: ''}"
	/>
	{#if workbench.list.isError}<Alert variant="destructive"
			><AlertDescription class="flex items-center justify-between"
				><span
					>{apiErrorMessage(workbench.list.error, "Could not load items")}</span
				><Button
					variant="outline"
					size="sm"
					onclick={() => workbench.list.refetch()}
					><RefreshCw />Try again</Button
				></AlertDescription
			></Alert
		>{/if}
	<div class="min-h-0 xl:flex-1">
		{#if workbench.creating}
			<section
				class="mx-auto flex h-full min-h-0 max-w-4xl flex-col overflow-hidden rounded-2xl border bg-background shadow-sm max-lg:min-h-[calc(100svh-2.8125rem)] max-lg:rounded-none max-lg:border-x-0 max-lg:shadow-none max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-right-4 max-lg:duration-200 max-lg:motion-reduce:animate-none"
			>
				<div class="shrink-0 border-b px-3 py-2 sm:px-5">
					<Button
						href={workbench.listHref}
						variant="ghost"
						class="min-h-11 px-2"
					>
						<ArrowLeft aria-hidden="true" />All items
					</Button>
				</div>
				<form
					{...createItem
						.preflight(createItemSchema)
						.enhance(workbench.enhance.create)}
					aria-busy={createItem.pending > 0}
					class="flex min-h-0 flex-1 flex-col"
				>
					<input
						{...createItem.fields.categoryId.as(
							"hidden",
							workbench.create.categoryId,
						)}
					/>
					<input
						{...createItem.fields.containerId.as(
							"hidden",
							workbench.create.containerId,
						)}
					/>
					<input
						{...createItem.fields.values.as("hidden", workbench.encoded.create)}
					/>
					{#each formIssues(createItem.fields.allIssues()) as issue, index (`${issue.message}-${index}`)}<p
							role="alert"
							class="mx-5 mt-4 text-sm text-destructive sm:mx-8"
						>
							{issue.message}
						</p>{/each}
					{#if createItem.result && !createItem.result.ok}<p
							role="alert"
							class="mx-5 mt-4 text-sm text-destructive sm:mx-8"
						>
							{createItem.result.error}
						</p>{/if}
					<div
						class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
					>
						<div class="flex items-start gap-3">
							<div
								class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
							>
								<PackagePlus class="size-5" aria-hidden="true" />
							</div>
							<div>
								<p
									class="text-[0.68rem] font-bold tracking-[0.16em] text-primary uppercase"
								>
									New item
								</p>
								<h2 class="font-heading text-2xl font-bold">Add item</h2>
								<p class="mt-1 text-sm leading-relaxed text-muted-foreground">
									The label and permanent item code are generated for you.
								</p>
							</div>
						</div>
					</div>

					<div
						class="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain bg-muted/20 p-5 sm:p-8"
					>
						<fieldset
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm sm:p-6"
						>
							<legend class="sr-only">What and where</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>1</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">What and where</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Choose what it is and where it's stored.
									</p>
								</div>
							</div>
							<div class="grid gap-5 sm:grid-cols-2 sm:gap-6">
								<div>
									<Label
										for="item-category"
										class="mb-2.5 flex items-center gap-1.5"
										><Tags
											class="size-3.5 text-primary"
											aria-hidden="true"
										/>Category</Label
									>
									<span class="mb-2 block text-xs text-muted-foreground"
										>Required</span
									>
									<Select.Root
										type="single"
										items={workbench.categoryOptions}
										bind:value={
											() => workbench.create.categoryId,
											(value) => workbench.chooseCreateCategory(value)
										}
										required
									>
										<Select.Trigger
											id="item-category"
											class="w-full data-[size=default]:h-11"
										>
											{workbench.categoryOptions.find(
												(option) =>
													option.value === workbench.create.categoryId,
											)?.label ?? "Choose category"}
										</Select.Trigger>
										<Select.Content portalProps={{ disabled: true }}>
											{#each workbench.categoryOptions as option (option.value)}
												<Select.Item value={option.value} label={option.label}>
													{option.label}
												</Select.Item>
											{/each}
										</Select.Content>
									</Select.Root>
								</div>
								<div>
									<Label
										for="item-container"
										class="mb-2.5 flex items-center gap-1.5"
										><MapPin
											class="size-3.5 text-primary"
											aria-hidden="true"
										/>Container</Label
									>
									<span class="mb-2 block text-xs text-muted-foreground"
										>Required</span
									>
									<Select.Root
										type="single"
										items={workbench.containerOptions}
										bind:value={workbench.create.containerId}
										required
									>
										<Select.Trigger
											id="item-container"
											class="w-full data-[size=default]:h-11"
										>
											{workbench.containerOptions.find(
												(option) =>
													option.value === workbench.create.containerId,
											)?.label ?? "Choose container"}
										</Select.Trigger>
										<Select.Content portalProps={{ disabled: true }}>
											{#each workbench.containerOptions as option (option.value)}
												<Select.Item value={option.value} label={option.label}>
													{option.label}
												</Select.Item>
											{/each}
										</Select.Content>
									</Select.Root>
								</div>
							</div>
						</fieldset>

						<fieldset
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm sm:p-6"
						>
							<legend class="sr-only">Details</legend>
							<div class="flex items-start gap-3 border-b pb-4">
								<span
									class="grid size-8 shrink-0 place-items-center rounded-full bg-secondary text-sm font-bold text-secondary-foreground"
									>2</span
								>
								<div>
									<h3 class="font-heading text-lg font-bold">Details</h3>
									<p class="mt-0.5 text-sm text-muted-foreground">
										Record size, condition, and any notes.
									</p>
								</div>
							</div>
							{#if workbench.create.categoryId && workbench.createDefinitions.isPending}
								<div
									class="flex items-center gap-2 rounded-xl border border-dashed bg-muted/35 p-3 text-sm text-muted-foreground"
									aria-live="polite"
								>
									<LoaderCircle
										class="size-4 animate-spin motion-reduce:animate-none"
										aria-hidden="true"
									/>
									Loading category details…
								</div>
							{:else if workbench.create.categoryId}
								{@render fields(
									workbench.createDefinitions.data ?? [],
									workbench.create.values,
									"create",
									createItem.fields.values.issues(),
								)}
							{:else}
								<p
									class="rounded-xl border border-dashed bg-muted/35 p-3 text-xs leading-relaxed text-muted-foreground"
								>
									Choose a category to reveal its specific properties.
								</p>
							{/if}
							<div>
								<Label for="item-notes" class="mb-2.5 flex items-center gap-1.5"
									><NotebookPen
										class="size-3.5 text-primary"
										aria-hidden="true"
									/>Notes</Label
								><Textarea
									id="item-notes"
									name={createItem.fields.notes.as("text").name}
									bind:value={workbench.create.notes}
								/>
								<p class="mt-1.5 text-xs text-muted-foreground">
									Optional notes for whoever handles this next.
								</p>
							</div>
						</fieldset>
					</div>

					<div
						class="shrink-0 border-t bg-background p-4 sm:flex-row sm:justify-between sm:px-6"
					>
						<div
							class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-between"
						>
							<Button href={workbench.listHref} variant="outline">Cancel</Button
							>
							<SubmitButton
								type="submit"
								class="min-h-11 sm:min-w-36"
								disabled={!workbench.canCreate || createItem.pending > 0}
								pending={createItem.pending > 0}
								succeeded={workbench.succeeded("create")}
								pendingLabel="Adding item…"
								successLabel="Added"
							>
								<PackagePlus />Add item
							</SubmitButton>
						</div>
					</div>
				</form>
			</section>
		{:else if !workbench.routed}
			<section class="min-h-0 space-y-3 xl:flex xl:h-full xl:flex-col">
				<div class="flex items-center justify-between gap-3 lg:hidden">
					<div class="flex min-w-0 items-baseline gap-2">
						<h2 class="font-heading text-xl font-bold">All items</h2>
						<span class="text-sm text-muted-foreground"
							>{workbench.totalCount} items</span
						>
					</div>
				</div>
				<div
					class="sticky top-[2.8125rem] z-10 -mx-4 flex gap-2 border-y border-border/70 bg-background/95 px-4 py-3 shadow-sm backdrop-blur-md sm:-mx-6 sm:px-6 lg:hidden"
				>
					<Label for="mobile-item-search" class="sr-only">Search items</Label>
					<Input
						id="mobile-item-search"
						type="search"
						class="h-11 flex-1 border-border bg-background shadow-xs"
						placeholder="Search code, name, location or notes"
						value={workbench.search}
						oninput={(event) => workbench.setSearch(event.currentTarget.value)}
					/>
					<Button
						variant="outline"
						size="icon"
						class="relative size-11 shrink-0"
						aria-label={workbench.activeFilterCount > 0
							? `Filters, ${workbench.activeFilterCount} active`
							: "Filters"}
						onclick={() => {
							mobileFiltersOpen = true;
						}}
					>
						<SlidersHorizontal aria-hidden="true" />
						{#if workbench.activeFilterCount > 0}
							<span
								class="absolute -right-1.5 -top-1.5 grid size-5 place-items-center rounded-full bg-secondary text-[0.6875rem] font-bold text-secondary-foreground"
								aria-hidden="true"
							>
								{workbench.activeFilterCount}
							</span>
						{/if}
					</Button>
				</div>
				<div
					class="inventory-panel hidden flex-wrap items-end justify-between gap-4 p-4 lg:flex"
				>
					<div>
						<h2 class="text-lg font-semibold">All items</h2>
						<p class="text-sm text-muted-foreground">
							{workbench.totalCount} items
						</p>
					</div>
					<div class="flex flex-1 flex-wrap items-end justify-end gap-3">
						<div class="min-w-56 flex-1 sm:max-w-md">
							<Label for="item-search" class="mb-2 text-xs font-semibold"
								>Search</Label
							>
							<Input
								id="item-search"
								type="search"
								class="h-11 border-border bg-background shadow-xs"
								placeholder="Code, name, location or notes"
								value={workbench.search}
								oninput={(event) =>
									workbench.setSearch(event.currentTarget.value)}
							/>
						</div>
						<div>
							<Label
								for="availability-filter"
								class="mb-2 text-xs font-semibold">Availability</Label
							>
							<Select.Root
								type="single"
								items={AVAILABILITY_FILTERS}
								bind:value={
									() => workbench.availability,
									(value) => workbench.setAvailability(value)
								}
							>
								<Select.Trigger
									id="availability-filter"
									class="min-w-36 data-[size=default]:h-11"
								>
									{AVAILABILITY_FILTERS.find(
										(option) => option.value === workbench.availability,
									)?.label}
								</Select.Trigger>
								<Select.Content>
									{#each AVAILABILITY_FILTERS as option (option.value)}
										<Select.Item value={option.value} label={option.label}>
											{option.label}
										</Select.Item>
									{/each}
								</Select.Content>
							</Select.Root>
						</div>
						<div>
							<Label for="archive-filter" class="mb-2 text-xs font-semibold"
								>Archive filter</Label
							>
							<Select.Root
								type="single"
								items={ARCHIVE_FILTERS}
								bind:value={
									() => workbench.archived,
									(value) => workbench.setArchived(value)
								}
							>
								<Select.Trigger
									id="archive-filter"
									class="min-w-32 data-[size=default]:h-11"
								>
									{ARCHIVE_FILTERS.find(
										(option) => option.value === workbench.archived,
									)?.label}
								</Select.Trigger>
								<Select.Content>
									{#each ARCHIVE_FILTERS as option (option.value)}
										<Select.Item value={option.value} label={option.label}>
											{option.label}
										</Select.Item>
									{/each}
								</Select.Content>
							</Select.Root>
						</div>
					</div>
				</div>
				<div
					class="space-y-3 xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:pr-2 xl:[scrollbar-gutter:stable]"
				>
					{#each workbench.items as item (item.id)}<article
							class="inventory-card p-4 {item.archivedAt ? 'opacity-65' : ''}"
						>
							<div class="flex flex-wrap items-start justify-between gap-3">
								<div>
									<div class="flex flex-wrap items-center gap-2">
										<h3 class="font-semibold">{item.label}</h3>
										<Badge variant="outline">{item.slug}</Badge><Badge
											variant={item.availability.available
												? "secondary"
												: "outline"}
											>{availabilityLabel(item.availability.status)}</Badge
										>
									</div>
									<p class="mt-1 text-sm text-muted-foreground">
										{item.category?.name} · {item.container?.name ??
											"No container"}
									</p>
									{#if item.values.length}<p class="mt-1 text-sm">
											{formatPropertyValues(item.values)}
										</p>{/if}{#if item.notes}<p class="mt-1 text-sm">
											{item.notes}
										</p>{/if}
								</div>
								<Button
									size="sm"
									variant="outline"
									href={workbench.itemHref(item.slug)}>Manage</Button
								>
							</div>
						</article>{:else}<div
							class="rounded-2xl border bg-card p-10 text-center"
						>
							<h2 class="font-semibold">No items found</h2>
							<p class="text-sm text-muted-foreground">
								{workbench.searching
									? "Try another search or change the filters."
									: "Add an item or change the archive filter."}
							</p>
						</div>{/each}
					{#if workbench.paged}
						<div class="flex items-center justify-between gap-2">
							{#if workbench.previousCursor}
								<Button
									variant="outline"
									size="sm"
									class="min-h-11"
									data-testid="items-previous-page"
									onclick={() => workbench.previousPage()}
								>
									Previous
								</Button>
							{:else}
								<span></span>
							{/if}
							{#if workbench.nextCursor}
								<Button
									variant="outline"
									size="sm"
									class="min-h-11"
									data-testid="items-next-page"
									onclick={() => workbench.nextPage()}
								>
									Next
								</Button>
							{/if}
						</div>
					{/if}
				</div>
			</section>
		{:else if workbench.routedItem.isError}
			<Alert variant="destructive" class="mx-auto max-w-5xl">
				<AlertDescription class="flex items-center justify-between gap-4">
					<span
						>{apiErrorMessage(
							workbench.routedItem.error,
							"Could not load item",
						)}</span
					>
					<Button
						variant="outline"
						size="sm"
						onclick={() => workbench.routedItem.refetch()}
					>
						<RefreshCw />Try again
					</Button>
				</AlertDescription>
			</Alert>
		{:else if workbench.routedItem.isPending}
			<div
				class="mx-auto grid min-h-64 max-w-5xl place-items-center"
				aria-live="polite"
			>
				<p class="text-sm text-muted-foreground">Loading item…</p>
			</div>
		{/if}
	</div>
</div>

<Sheet.Root bind:open={mobileFiltersOpen}>
	<Sheet.Content
		side="bottom"
		class="max-h-[calc(100svh-1rem)] gap-0 overflow-hidden rounded-t-2xl p-0 lg:hidden"
	>
		<Sheet.Header class="shrink-0 border-b px-5 py-5 pr-16 text-left">
			<div class="flex items-center gap-3">
				<div
					class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary"
				>
					<SlidersHorizontal class="size-5" aria-hidden="true" />
				</div>
				<div>
					<Sheet.Title class="font-heading text-xl font-bold">
						Filter items
					</Sheet.Title>
					<Sheet.Description class="mt-0.5">
						Narrow the list by availability or archive status.
					</Sheet.Description>
				</div>
			</div>
		</Sheet.Header>

		<div class="min-h-0 flex-1 overflow-y-auto p-5">
			<fieldset class="space-y-4">
				<legend class="font-heading text-lg font-bold">List filters</legend>
				<div>
					<Label
						for="mobile-availability-filter"
						class="mb-2 text-sm font-semibold">Availability</Label
					>
					<Select.Root
						type="single"
						items={AVAILABILITY_FILTERS}
						bind:value={
							() => workbench.availability,
							(value) => workbench.setAvailability(value)
						}
					>
						<Select.Trigger
							id="mobile-availability-filter"
							class="w-full data-[size=default]:h-11"
						>
							{AVAILABILITY_FILTERS.find(
								(option) => option.value === workbench.availability,
							)?.label}
						</Select.Trigger>
						<Select.Content>
							{#each AVAILABILITY_FILTERS as option (option.value)}
								<Select.Item value={option.value} label={option.label}>
									{option.label}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
				<div>
					<Label for="mobile-archive-filter" class="mb-2 text-sm font-semibold"
						>Archive filter</Label
					>
					<Select.Root
						type="single"
						items={ARCHIVE_FILTERS}
						bind:value={
							() => workbench.archived, (value) => workbench.setArchived(value)
						}
					>
						<Select.Trigger
							id="mobile-archive-filter"
							class="w-full data-[size=default]:h-11"
						>
							{ARCHIVE_FILTERS.find(
								(option) => option.value === workbench.archived,
							)?.label}
						</Select.Trigger>
						<Select.Content>
							{#each ARCHIVE_FILTERS as option (option.value)}
								<Select.Item value={option.value} label={option.label}>
									{option.label}
								</Select.Item>
							{/each}
						</Select.Content>
					</Select.Root>
				</div>
			</fieldset>
		</div>

		<Sheet.Footer
			class="shrink-0 flex-row justify-between border-t bg-background p-4 pb-[max(1rem,env(safe-area-inset-bottom))]"
		>
			<Button
				variant="ghost"
				disabled={workbench.activeFilterCount === 0}
				onclick={() => workbench.clearFilters()}>Clear filters</Button
			>
			<Sheet.Close class={buttonVariants()}>Show items</Sheet.Close>
		</Sheet.Footer>
	</Sheet.Content>
</Sheet.Root>

{#if workbench.selected && workbench.drafts}
	{@const selected = workbench.selected}
	{@const drafts = workbench.drafts}
	<section
		class="inventory-page !pt-0 max-lg:max-w-none max-lg:px-0 max-lg:pb-0 max-lg:animate-in max-lg:fade-in-0 max-lg:slide-in-from-right-4 max-lg:duration-200 max-lg:motion-reduce:animate-none"
	>
		<div
			class="mx-auto flex min-h-[calc(100svh-12rem)] w-full max-w-5xl flex-col overflow-hidden rounded-2xl border bg-background shadow-sm max-lg:min-h-[calc(100svh-2.8125rem)] max-lg:rounded-none max-lg:border-x-0 max-lg:shadow-none"
		>
			<div class="shrink-0 border-b px-3 py-2 sm:px-5">
				<Button href={workbench.listHref} variant="ghost" class="min-h-11 px-2">
					<ArrowLeft aria-hidden="true" />All items
				</Button>
			</div>
			<div
				class="shrink-0 border-b bg-primary/7 px-5 pt-[max(1.25rem,env(safe-area-inset-top))] pr-16 pb-5 text-left sm:px-6 sm:pt-6"
			>
				<div class="flex items-start gap-3">
					<div
						class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
					>
						<PackageSearch class="size-5" aria-hidden="true" />
					</div>
					<div class="min-w-0">
						<div class="flex flex-wrap items-center gap-2">
							<h2 class="font-heading text-2xl font-bold">
								{selected.label}
							</h2>
							<Badge
								variant={selected.availability.available
									? "secondary"
									: "outline"}
							>
								{availabilityLabel(selected.availability.status)}
							</Badge>
						</div>
						<p class="mt-1 font-mono text-sm text-muted-foreground">
							{selected.slug}
						</p>
					</div>
				</div>
			</div>

			<Tabs.Root
				bind:value={workbench.managementTab}
				class="min-h-0 flex-1 gap-0"
			>
				<div class="shrink-0 border-b bg-background px-5 py-3 sm:px-6">
					<Tabs.List class="grid h-11 w-full grid-cols-3">
						<Tabs.Trigger value="details">Details</Tabs.Trigger>
						<Tabs.Trigger value="placement">Placement</Tabs.Trigger>
						<Tabs.Trigger value="maintenance">Maintenance</Tabs.Trigger>
					</Tabs.List>
				</div>

				<Tabs.Content value="details" class="min-h-0 overflow-hidden">
					<div class="flex h-full min-h-0 flex-col">
						<div
							class="min-h-0 flex-1 space-y-6 overflow-y-auto bg-muted/20 p-5 sm:p-6"
						>
							<!-- The Save button sits in the sticky footer, outside this form. -->
							<form
								id="item-details-form"
								{...updateItem
									.preflight(updateItemSchema)
									.enhance(workbench.enhance.update)}
								aria-busy={updateItem.pending > 0}
								class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
							>
								<input
									{...updateItem.fields.slugOrId.as("hidden", selected.slug)}
								/>
								<input
									{...updateItem.fields.values.as(
										"hidden",
										workbench.encoded.details,
									)}
								/>
								<div class="border-b pb-4">
									<h3 class="font-heading text-lg font-bold">Details</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Update properties and notes.
									</p>
								</div>
								{#each formIssues(updateItem.fields.allIssues()) as issue, index (`${issue.message}-${index}`)}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{issue.message}
									</p>{/each}
								{#if updateItem.result && !updateItem.result.ok}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{updateItem.result.error}
									</p>{/if}
								{#if workbench.detailsDefinitions.isPending}
									<p class="text-sm text-muted-foreground" aria-live="polite">
										Loading item details…
									</p>
								{:else}
									{@render fields(
										workbench.detailsDefinitions.data ?? [],
										drafts.values,
										"details",
										updateItem.fields.values.issues(),
									)}
								{/if}
								<div>
									<Label for="edit-notes" class="mb-2.5">Notes</Label>
									<Textarea
										id="edit-notes"
										name={updateItem.fields.notes.as("text").name}
										bind:value={drafts.notes}
									/>
								</div>
							</form>

							<section
								class="space-y-4 rounded-2xl border border-destructive/25 bg-destructive/3 p-5 shadow-sm"
							>
								<div>
									<h3 class="font-heading text-lg font-bold">
										Archive or delete
									</h3>
									<p class="mt-1 text-sm text-muted-foreground">
										Archive items you still need a record of. Delete only items
										with no history.
									</p>
								</div>
								{#if selected.archivedAt}
									<form
										{...restoreItem
											.preflight(restoreItemSchema)
											.enhance(workbench.enhance.restore)}
										aria-busy={restoreItem.pending > 0}
									>
										<input
											{...restoreItem.fields.slugOrId.as(
												"hidden",
												selected.slug,
											)}
										/>
										<Button
											type="submit"
											variant="outline"
											disabled={restoreItem.pending > 0}
										>
											<RotateCcw />{restoreItem.pending > 0
												? "Restoring…"
												: "Restore item"}
										</Button>
									</form>
								{:else}
									<form
										{...archiveItem
											.preflight(archiveItemSchema)
											.enhance(workbench.enhance.archive)}
										aria-busy={archiveItem.pending > 0}
										class="space-y-4"
									>
										<input
											{...archiveItem.fields.slugOrId.as(
												"hidden",
												selected.slug,
											)}
										/>
										<div>
											<Label for="archive-reason" class="mb-2.5"
												>Archive note <span
													class="font-normal text-muted-foreground"
													>(optional)</span
												></Label
											>
											<Input
												id="archive-reason"
												name={archiveItem.fields.reason.as("text").name}
												aria-invalid={archiveItem.fields.reason.issues()?.length
													? true
													: undefined}
												bind:value={drafts.archiveReason}
											/>
											<Field.Error
												errors={archiveItem.fields.reason.issues()}
											/>
										</div>
										<div class="flex flex-wrap gap-2 border-t pt-4">
											<Button
												type="submit"
												variant="outline"
												disabled={archiveItem.pending > 0}
											>
												<Archive />{archiveItem.pending > 0
													? "Archiving…"
													: "Archive item"}
											</Button>
											<Button
												type="button"
												variant="destructive"
												disabled={archiveItem.pending > 0}
												onclick={() => {
													workbench.deleteConfirmOpen = true;
												}}
											>
												<Trash2 />Delete item
											</Button>
										</div>
									</form>
								{/if}
							</section>
						</div>
						<div
							class="shrink-0 border-t bg-background p-4 sm:flex sm:justify-end sm:px-6"
						>
							<SubmitButton
								type="submit"
								form="item-details-form"
								class="w-full sm:w-auto"
								disabled={!workbench.dirty.details || updateItem.pending > 0}
								pending={updateItem.pending > 0}
								succeeded={workbench.succeeded("details")}
								pendingLabel="Saving…"
								successLabel="Saved"
							>
								Save changes
							</SubmitButton>
						</div>
					</div>
				</Tabs.Content>

				<Tabs.Content
					value="placement"
					class="min-h-0 overflow-y-auto bg-muted/20 p-5 sm:p-6"
				>
					<div class="space-y-6">
						<form
							{...moveItem
								.preflight(moveItemSchema)
								.enhance(workbench.enhance.move)}
							aria-busy={moveItem.pending > 0}
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
						>
							<input
								{...moveItem.fields.slugOrId.as("hidden", selected.slug)}
							/>
							<input
								{...moveItem.fields.containerId.as(
									"hidden",
									drafts.containerId,
								)}
							/>
							{#each moveItem.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{issue.message}
								</p>{/each}
							{#if moveItem.result && !moveItem.result.ok}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{moveItem.result.error}
								</p>{/if}
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Move item</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Move it to a different container.
								</p>
							</div>
							<div>
								<Label for="move-container" class="mb-2.5"
									>Move to container</Label
								>
								<Select.Root
									type="single"
									items={workbench.containerOptions}
									bind:value={drafts.containerId}
									required
								>
									<Select.Trigger
										id="move-container"
										class="w-full data-[size=default]:h-11"
									>
										{workbench.containerOptions.find(
											(option) => option.value === drafts.containerId,
										)?.label ?? "Choose container"}
									</Select.Trigger>
									<Select.Content portalProps={{ disabled: true }}>
										{#each workbench.containerOptions as option (option.value)}
											<Select.Item value={option.value} label={option.label}>
												{option.label}
											</Select.Item>
										{/each}
									</Select.Content>
								</Select.Root>
								<p class="mt-2 text-xs text-muted-foreground">
									Current location: {selected.container?.name ?? "No container"}
								</p>
							</div>
							<SubmitButton
								type="submit"
								disabled={!workbench.dirty.placement || moveItem.pending > 0}
								pending={moveItem.pending > 0}
								succeeded={workbench.succeeded("placement")}
								pendingLabel="Moving…"
								successLabel="Moved"
							>
								Move item
							</SubmitButton>
						</form>

						<form
							{...changeItemCategory
								.preflight(changeItemCategorySchema)
								.enhance(workbench.enhance.changeCategory)}
							aria-busy={changeItemCategory.pending > 0}
							class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm"
						>
							<input
								{...changeItemCategory.fields.slugOrId.as(
									"hidden",
									selected.slug,
								)}
							/>
							<input
								{...changeItemCategory.fields.categoryId.as(
									"hidden",
									drafts.categoryId,
								)}
							/>
							<input
								{...changeItemCategory.fields.values.as(
									"hidden",
									workbench.encoded.category,
								)}
							/>
							{#each formIssues(changeItemCategory.fields.allIssues()) as issue, index (`${issue.message}-${index}`)}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{issue.message}
								</p>{/each}
							{#if changeItemCategory.result && !changeItemCategory.result.ok}<p
									role="alert"
									class="text-sm text-destructive"
								>
									{changeItemCategory.result.error}
								</p>{/if}
							<div class="border-b pb-4">
								<h3 class="font-heading text-lg font-bold">Change category</h3>
								<p class="mt-1 text-sm text-muted-foreground">
									Changing category replaces the details below.
								</p>
							</div>
							<div>
								<Label for="new-category" class="mb-2.5">New category</Label>
								<Select.Root
									type="single"
									items={workbench.categoryOptions}
									bind:value={
										() => drafts.categoryId,
										(value) => workbench.chooseNewCategory(value)
									}
									required
								>
									<Select.Trigger
										id="new-category"
										class="w-full data-[size=default]:h-11"
									>
										{workbench.categoryOptions.find(
											(option) => option.value === drafts.categoryId,
										)?.label ?? "Choose category"}
									</Select.Trigger>
									<Select.Content portalProps={{ disabled: true }}>
										{#each workbench.categoryOptions as option (option.value)}
											<Select.Item value={option.value} label={option.label}>
												{option.label}
											</Select.Item>
										{/each}
									</Select.Content>
								</Select.Root>
							</div>
							{#if workbench.categoryDefinitions.isPending}
								<p class="text-sm text-muted-foreground" aria-live="polite">
									Loading category details…
								</p>
							{:else}
								{@render fields(
									workbench.categoryDefinitions.data ?? [],
									drafts.categoryValues,
									"category",
									changeItemCategory.fields.values.issues(),
								)}
							{/if}
							<SubmitButton
								type="submit"
								disabled={!workbench.dirty.category ||
									workbench.categoryDefinitions.isPending ||
									changeItemCategory.pending > 0}
								pending={changeItemCategory.pending > 0}
								succeeded={workbench.succeeded("category")}
								pendingLabel="Saving category…"
								successLabel="Saved"
							>
								Save category
							</SubmitButton>
						</form>
					</div>
				</Tabs.Content>

				<Tabs.Content
					value="maintenance"
					class="min-h-0 overflow-y-auto bg-muted/20 p-5 sm:p-6"
				>
					<section class="space-y-5 rounded-2xl border bg-card p-5 shadow-sm">
						<div class="border-b pb-4">
							<h3 class="font-heading text-lg font-bold">Maintenance</h3>
							<p class="mt-1 text-sm text-muted-foreground">
								Take the item out of circulation or return it when work is
								complete.
							</p>
						</div>
						{#if selected.availability.status === "maintenance"}
							<form
								{...endItemMaintenance
									.preflight(endItemMaintenanceSchema)
									.enhance(workbench.enhance.endMaintenance)}
								class="space-y-4"
								aria-busy={endItemMaintenance.pending > 0}
							>
								<input
									{...endItemMaintenance.fields.slugOrId.as(
										"hidden",
										selected.slug,
									)}
								/>
								{#each endItemMaintenance.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{issue.message}
									</p>{/each}
								{#if endItemMaintenance.result && !endItemMaintenance.result.ok}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{endItemMaintenance.result.error}
									</p>{/if}
								<div>
									<Label for="maintenance-end-note" class="mb-2.5"
										>Maintenance end note</Label
									>
									<Textarea
										id="maintenance-end-note"
										name={endItemMaintenance.fields.endNote.as("text").name}
										bind:value={drafts.maintenanceEndNote}
									/>
								</div>
								<SubmitButton
									type="submit"
									disabled={endItemMaintenance.pending > 0}
									pending={endItemMaintenance.pending > 0}
									succeeded={workbench.succeeded("maintenance")}
									pendingLabel="Ending maintenance…"
									successLabel="Ended"
								>
									End maintenance
								</SubmitButton>
							</form>
						{:else}
							<form
								{...startItemMaintenance
									.preflight(startItemMaintenanceSchema)
									.enhance(workbench.enhance.startMaintenance)}
								class="space-y-4"
								aria-busy={startItemMaintenance.pending > 0}
							>
								<input
									{...startItemMaintenance.fields.slugOrId.as(
										"hidden",
										selected.slug,
									)}
								/>
								{#each startItemMaintenance.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{issue.message}
									</p>{/each}
								{#if startItemMaintenance.result && !startItemMaintenance.result.ok}<p
										role="alert"
										class="text-sm text-destructive"
									>
										{startItemMaintenance.result.error}
									</p>{/if}
								<div>
									<Label for="maintenance-reason" class="mb-2.5"
										>Maintenance reason <span
											class="font-normal text-muted-foreground">(required)</span
										></Label
									>
									<Textarea
										id="maintenance-reason"
										name={startItemMaintenance.fields.reason.as("text").name}
										bind:value={drafts.maintenanceReason}
									/>
								</div>
								<SubmitButton
									type="submit"
									disabled={!drafts.maintenanceReason.trim() ||
										startItemMaintenance.pending > 0}
									pending={startItemMaintenance.pending > 0}
									succeeded={workbench.succeeded("maintenance")}
									pendingLabel="Starting maintenance…"
									successLabel="Started"
								>
									Start maintenance
								</SubmitButton>
							</form>
						{/if}

						<div class="space-y-3 border-t pt-5">
							<h4 class="font-semibold">Maintenance history</h4>
							{#each workbench.maintenance.data ?? [] as period (period.id)}
								<div class="rounded-xl bg-muted/45 p-3 text-sm">
									<div class="font-medium">{period.startReason}</div>
									<div class="mt-1 text-muted-foreground">
										{new Date(period.startedAt).toLocaleString()} · {period.open
											? "Open"
											: "Ended"}
									</div>
									{#if period.endNote}<div class="mt-2">
											{period.endNote}
										</div>{/if}
								</div>
							{:else}
								<p class="text-sm text-muted-foreground">
									No maintenance history.
								</p>
							{/each}
						</div>
					</section>
				</Tabs.Content>
			</Tabs.Root>
		</div>
	</section>

	<AlertDialog.Root bind:open={workbench.deleteConfirmOpen}>
		<AlertDialog.Content>
			<form
				{...deleteItem
					.preflight(deleteItemSchema)
					.enhance(workbench.enhance.delete)}
				aria-busy={deleteItem.pending > 0}
				class="contents"
			>
				<input {...deleteItem.fields.slugOrId.as("hidden", selected.slug)} />
				<AlertDialog.Header>
					<AlertDialog.Title>Delete {selected.label}?</AlertDialog.Title>
					<AlertDialog.Description>
						This permanently removes the item. Items with retained history must
						be archived instead.
					</AlertDialog.Description>
				</AlertDialog.Header>
				<AlertDialog.Footer>
					<AlertDialog.Cancel type="button">Cancel</AlertDialog.Cancel>
					<Button
						type="submit"
						variant="destructive"
						disabled={deleteItem.pending > 0}
					>
						Delete permanently
					</Button>
				</AlertDialog.Footer>
			</form>
		</AlertDialog.Content>
	</AlertDialog.Root>
{/if}
