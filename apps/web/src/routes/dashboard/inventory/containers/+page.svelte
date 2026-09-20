<script lang="ts">
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryContainer,
	inventoryContainersArchiveMutation,
	inventoryContainersDeleteMutation,
	inventoryContainersIndexOptions,
	inventoryContainersRestoreMutation,
} from "@dhc/api-client";
import { saveContainer } from "./data.remote";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Select from "$lib/components/ui/select";
import * as Sheet from "$lib/components/ui/sheet";
import InventoryPageHeader from "$lib/components/inventory/InventoryPageHeader.svelte";
import { apiErrorMessage } from "$lib/api-error";
import {
	Archive,
	FolderTree,
	Pencil,
	Plus,
	RefreshCw,
	RotateCcw,
	Trash2,
} from "@lucide/svelte";
import { SvelteSet } from "svelte/reactivity";
import { toast } from "svelte-sonner";

let editing = $state<InventoryContainer | undefined>();
let draft = $state({ name: "", description: "", parentId: "" });
let editorOpen = $state(false);
let editorTrigger = $state<HTMLButtonElement | HTMLAnchorElement>();
const desktopContainerForm = saveContainer.for("desktop");
const mobileContainerForm = saveContainer.for("mobile");
const containersQuery = createQuery(() => ({
	...inventoryContainersIndexOptions(),
	select: (response) => response.data.containers,
}));
const containers = $derived(containersQuery.data ?? []);
const hierarchyRows = $derived.by(() => {
	const rows: Array<{ container: InventoryContainer; depth: number }> = [];
	const append = (parentId: string | null, depth: number) => {
		for (const container of containers
			.filter((candidate) => candidate.parentContainerId === parentId)
			.toSorted((a, b) => a.name.localeCompare(b.name))) {
			rows.push({ container, depth });
			append(container.id, depth + 1);
		}
	};
	append(null, 0);
	return rows;
});

function descendantsOf(id: string): Set<string> {
	const result = new SvelteSet<string>();
	const visit = (parent: string) => {
		for (const child of containers) {
			if (child.parentContainerId === parent && !result.has(child.id)) {
				result.add(child.id);
				visit(child.id);
			}
		}
	};
	visit(id);
	return result;
}

const excludedParentIds = $derived(
	editing ? descendantsOf(editing.id) : undefined,
);
const parentOptions = $derived(
	containers.filter(
		(candidate) =>
			!candidate.archivedAt &&
			candidate.id !== editing?.id &&
			!excludedParentIds?.has(candidate.id),
	),
);
const selectedParentLabel = $derived(
	parentOptions.find((candidate) => candidate.id === draft.parentId)?.name ??
		"Root",
);
function refresh() {
	void containersQuery.refetch();
}
function reset() {
	editing = undefined;
	draft = { name: "", description: "", parentId: "" };
}
const isSaving = $derived(
	desktopContainerForm.pending > 0 || mobileContainerForm.pending > 0,
);
const archiveContainer = createMutation(() => ({
	...inventoryContainersArchiveMutation(),
	onSuccess: () => {
		toast.success("Container archived");
		refresh();
	},
	onError: (e) =>
		toast.error(apiErrorMessage(e, "Move its active children and items first")),
}));
const restoreContainer = createMutation(() => ({
	...inventoryContainersRestoreMutation(),
	onSuccess: () => {
		toast.success("Container restored");
		refresh();
	},
	onError: (e) =>
		toast.error(apiErrorMessage(e, "Restore its parent chain first")),
}));
const deleteContainer = createMutation(() => ({
	...inventoryContainersDeleteMutation(),
	onSuccess: () => {
		toast.success("Container deleted");
		refresh();
	},
	onError: (e) =>
		toast.error(
			apiErrorMessage(e, "Handle children and items explicitly first"),
		),
}));
function handleSave(result: typeof saveContainer.result) {
	if (!result) return;
	if (!result.ok) {
		toast.error(result.error);
		return;
	}
	toast.success(result.created ? "Container created" : "Container updated");
	editorOpen = false;
	reset();
	refresh();
}
function startEdit(container: InventoryContainer) {
	editing = container;
	draft = {
		name: container.name,
		description: container.description ?? "",
		parentId: container.parentContainerId ?? "",
	};
}
function openCreate(trigger: HTMLButtonElement | HTMLAnchorElement) {
	reset();
	editorTrigger = trigger;
	editorOpen = true;
}
function openEdit(
	container: InventoryContainer,
	trigger: HTMLButtonElement | HTMLAnchorElement,
) {
	startEdit(container);
	editorTrigger = trigger;
	editorOpen = true;
}
</script>

<svelte:head>
	<title>Inventory containers | Dublin HEMA Club</title>
</svelte:head>

{#snippet editorFields(prefix: string)}
	{@const remoteForm = prefix.startsWith("desktop")
		? desktopContainerForm
		: mobileContainerForm}
	<input
		type="hidden"
		name={remoteForm.fields.id.as("hidden", editing?.id ?? "").name}
		value={editing?.id ?? ""}
	/>
	<input
		type="hidden"
		name={remoteForm.fields.parentContainerId.as("hidden", draft.parentId).name}
		value={draft.parentId}
	/>
	{#each remoteForm.fields.allIssues() as issue, index (`${issue.message}-${index}`)}<p
			role="alert"
			class="text-sm text-destructive"
		>
			{issue.message}
		</p>{/each}
	{#if remoteForm.result && !remoteForm.result.ok}<p
			role="alert"
			class="text-sm text-destructive"
		>
			{remoteForm.result.error}
		</p>{/if}
	<div class="space-y-2">
		<Label for={`${prefix}-name`}>Name</Label>
		<Input
			id={`${prefix}-name`}
			class="h-11"
			maxlength={100}
			placeholder="e.g. Main equipment room"
			required
			name={remoteForm.fields.name.as("text").name}
			bind:value={draft.name}
		/>
		{#each remoteForm.fields.name.issues() as issue}<p
				class="text-sm text-destructive"
			>
				{issue.message}
			</p>{/each}
	</div>
	<div class="space-y-2">
		<Label for={`${prefix}-description`}>Description</Label>
		<Input
			id={`${prefix}-description`}
			class="h-11"
			maxlength={500}
			placeholder="Optional location note"
			name={remoteForm.fields.description.as("text").name}
			bind:value={draft.description}
		/>
	</div>
	<div class="space-y-2">
		<Label for={`${prefix}-parent`}>Parent</Label>
		<Select.Root type="single" bind:value={draft.parentId}>
			<Select.Trigger
				id={`${prefix}-parent`}
				class="w-full data-[size=default]:h-11"
			>
				{selectedParentLabel}
			</Select.Trigger>
			<Select.Content>
				<Select.Item value="" label="Root">Root</Select.Item>
				{#each parentOptions as candidate (candidate.id)}
					<Select.Item value={candidate.id} label={candidate.name}
						>{candidate.name}</Select.Item
					>
				{/each}
			</Select.Content>
		</Select.Root>
		<p class="text-xs leading-relaxed text-muted-foreground">
			Choose Root for a top-level room or area.
		</p>
	</div>
{/snippet}

<Sheet.Root
	bind:open={editorOpen}
	onOpenChangeComplete={(open) => {
		if (!open) {
			reset();
		}
	}}
>
	<div
		class="inventory-page xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:overflow-hidden"
	>
		<header
			class="sticky top-[2.8125rem] z-10 -mx-4 flex items-center justify-between gap-4 border-y border-border/80 bg-background/95 px-4 py-3 backdrop-blur-md lg:hidden"
		>
			<div class="min-w-0">
				<p
					class="text-[0.68rem] font-bold tracking-[0.14em] text-primary uppercase"
				>
					Quartermaster
				</p>
				<h1 class="truncate font-heading text-xl leading-tight font-bold">
					Containers
				</h1>
			</div>
			<Button
				size="sm"
				class="min-h-11"
				onclick={(event) => openCreate(event.currentTarget)}
			>
				<Plus aria-hidden="true" />New location
			</Button>
		</header>
		<InventoryPageHeader
			eyebrow="Quartermaster"
			title="Containers"
			icon={FolderTree}
			class="hidden lg:flex xl:items-center xl:pb-3"
		/>
		{#if containersQuery.isError}
			<Alert variant="destructive">
				<AlertDescription class="flex items-center justify-between">
					<span>
						{apiErrorMessage(
							containersQuery.error,
							"Could not load containers",
						)}
					</span>
					<Button
						variant="outline"
						size="sm"
						onclick={() => containersQuery.refetch()}
					>
						<RefreshCw />Try again
					</Button>
				</AlertDescription>
			</Alert>
		{/if}
		<div
			class="grid min-h-0 items-start gap-6 lg:grid-cols-[21rem_minmax(0,1fr)] xl:flex-1 xl:items-stretch"
		>
			<form
				{...desktopContainerForm.enhance(async (form) => {
					if (await form.submit()) handleSave(form.result);
				})}
				class="inventory-panel hidden space-y-5 p-5 lg:sticky lg:top-6 lg:block xl:static xl:h-full xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:[scrollbar-gutter:stable]"
			>
				<div class="flex items-center gap-3 border-b pb-4">
					<div
						class="grid size-10 place-items-center rounded-xl bg-secondary/20 text-primary"
					>
						{#if editing}<Pencil
								class="size-5"
								aria-hidden="true"
							/>{:else}<Plus class="size-5" aria-hidden="true" />{/if}
					</div>
					<div>
						<p class="text-xs font-bold tracking-wide text-primary uppercase">
							{editing ? "Selected location" : "New location"}
						</p>
						<h2 class="text-lg font-semibold">
							{editing ? "Edit container" : "Add container"}
						</h2>
					</div>
				</div>
				{@render editorFields("desktop-container")}
				<div class="flex gap-2 border-t pt-4">
					<Button class="flex-1" type="submit" disabled={isSaving}>
						{editing ? "Save changes" : "Add container"}
					</Button>
					{#if editing}
						<Button
							class="flex-1"
							type="button"
							variant="outline"
							disabled={isSaving}
							onclick={reset}
						>
							Cancel
						</Button>
					{/if}
				</div>
			</form>
			<section
				class="min-w-0 space-y-3 xl:h-full xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:pr-1 xl:[scrollbar-gutter:stable]"
			>
				<div
					class="flex items-end justify-between gap-3 border-b bg-background/95 pb-3 backdrop-blur-sm xl:sticky xl:top-0 xl:z-10"
				>
					<div>
						<p
							class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
						>
							Storage map
						</p>
						<h2 class="mt-1 font-heading text-xl font-bold">
							Storage hierarchy
						</h2>
						<p class="text-sm text-muted-foreground">
							{containers.length} location{containers.length === 1 ? "" : "s"} · indented
							by parent
						</p>
					</div>
				</div>
				{#each hierarchyRows as { container, depth } (container.id)}
					<div
						class="relative"
						style:padding-left={`${Math.min(depth, 4) * 1.25}rem`}
					>
						{#if depth > 0}<span
								class="absolute top-0 bottom-0 left-2 border-l border-dashed border-primary/30"
								aria-hidden="true"
							></span>{/if}
						<article
							class="inventory-card p-4 transition-colors hover:border-primary/30 {container.archivedAt
								? 'opacity-65'
								: ''}"
						>
							<div class="flex flex-wrap items-start justify-between gap-3">
								<div class="flex gap-3">
									<div
										class="grid size-10 place-items-center rounded-lg bg-secondary/20 text-primary"
									>
										<FolderTree class="size-5" aria-hidden="true" />
									</div>
									<div>
										<div class="flex flex-wrap items-center gap-2">
											<h3 class="font-semibold">{container.name}</h3>
											{#if container.archivedAt}
												<Badge variant="outline">Archived</Badge>
											{/if}
										</div>
										<p class="text-sm text-muted-foreground">
											{container.parentContainer
												? `Inside ${container.parentContainer.name}`
												: "Root container"} · {container.itemCount} direct items
										</p>
										{#if container.description}
											<p class="mt-1 text-sm">
												{container.description}
											</p>
										{/if}
									</div>
								</div>
								<div class="flex flex-wrap gap-2">
									<Button
										size="sm"
										variant="outline"
										class="min-h-11 lg:hidden"
										disabled={isSaving}
										onclick={(event) =>
											openEdit(container, event.currentTarget)}
									>
										<Pencil />Edit / move
									</Button>
									<Button
										size="sm"
										variant="outline"
										class="hidden lg:inline-flex"
										disabled={isSaving}
										onclick={() => startEdit(container)}
									>
										<Pencil />Edit / move
									</Button>
									{#if container.archivedAt}
										<Button
											size="sm"
											variant="outline"
											disabled={restoreContainer.isPending}
											onclick={() =>
												restoreContainer.mutate({ path: { id: container.id } })}
										>
											<RotateCcw />Restore
										</Button>
									{:else}
										<Button
											size="sm"
											variant="outline"
											disabled={archiveContainer.isPending}
											onclick={() =>
												archiveContainer.mutate({ path: { id: container.id } })}
										>
											<Archive />Archive
										</Button>
										<Button
											size="sm"
											variant="ghost"
											class="text-destructive"
											disabled={deleteContainer.isPending}
											aria-label="Delete {container.name}"
											onclick={() =>
												deleteContainer.mutate({ path: { id: container.id } })}
										>
											<Trash2 />
										</Button>
									{/if}
								</div>
							</div>
						</article>
					</div>
				{:else}
					<div class="rounded-2xl border bg-card p-10 text-center">
						<FolderTree class="mx-auto mb-3 size-10 text-muted-foreground" />
						<h2 class="font-semibold">No containers yet</h2>
						<p class="text-sm text-muted-foreground">
							Create a root storage location to begin.
						</p>
					</div>
				{/each}
			</section>
		</div>

		<Sheet.Content
			side="bottom"
			class="max-h-[min(42rem,calc(100svh-2rem))] gap-0 overflow-hidden rounded-t-3xl border-x p-0 lg:hidden"
			onCloseAutoFocus={(event) => {
				event.preventDefault();
				editorTrigger?.focus();
			}}
		>
			<form
				{...mobileContainerForm.enhance(async (form) => {
					if (await form.submit()) handleSave(form.result);
				})}
				class="flex min-h-0 flex-1 flex-col"
			>
				<Sheet.Header
					class="shrink-0 border-b bg-primary/7 px-5 pt-5 pr-16 pb-4 text-left"
				>
					<div class="flex items-start gap-3">
						<div
							class="grid size-11 shrink-0 place-items-center rounded-xl bg-primary text-primary-foreground shadow-sm"
						>
							{#if editing}<Pencil
									class="size-5"
									aria-hidden="true"
								/>{:else}<Plus class="size-5" aria-hidden="true" />{/if}
						</div>
						<div>
							<p
								class="text-[0.68rem] font-bold tracking-[0.16em] text-primary uppercase"
							>
								{editing ? "Selected location" : "New location"}
							</p>
							<Sheet.Title class="font-heading text-2xl font-bold">
								{editing ? "Edit container" : "Add container"}
							</Sheet.Title>
							<Sheet.Description class="mt-1 text-sm leading-relaxed">
								Name the location and choose where it sits in the storage map.
							</Sheet.Description>
						</div>
					</div>
				</Sheet.Header>
				<div class="min-h-0 flex-1 space-y-5 overflow-y-auto bg-muted/20 p-5">
					{@render editorFields("mobile-container")}
				</div>
				<Sheet.Footer
					class="shrink-0 flex-row gap-2 border-t bg-background px-5 pt-4 pb-[max(1rem,env(safe-area-inset-bottom))]"
				>
					<Button
						class="flex-1"
						type="button"
						variant="outline"
						disabled={isSaving}
						onclick={() => (editorOpen = false)}
					>
						Cancel
					</Button>
					<Button class="flex-1" type="submit" disabled={isSaving}>
						{editing ? "Save changes" : "Add container"}
					</Button>
				</Sheet.Footer>
			</form>
		</Sheet.Content>
	</div>
</Sheet.Root>
