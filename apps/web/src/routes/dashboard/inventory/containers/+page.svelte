<script lang="ts">
import { createMutation, createQuery } from "@tanstack/svelte-query";
import {
	type InventoryContainer,
	inventoryContainersArchiveMutation,
	inventoryContainersCreateMutation,
	inventoryContainersDeleteMutation,
	inventoryContainersIndexOptions,
	inventoryContainersRestoreMutation,
	inventoryContainersUpdateMutation,
} from "@dhc/api-client";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import * as Select from "$lib/components/ui/select";
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
const createContainer = createMutation(() => ({
	...inventoryContainersCreateMutation(),
	onSuccess: () => {
		toast.success("Container created");
		reset();
		refresh();
	},
	onError: (e) => toast.error(apiErrorMessage(e, "Could not create container")),
}));
const updateContainer = createMutation(() => ({
	...inventoryContainersUpdateMutation(),
	onSuccess: () => {
		toast.success("Container updated");
		reset();
		refresh();
	},
	onError: (e) => toast.error(apiErrorMessage(e, "Could not update container")),
}));
const isSaving = $derived(
	createContainer.isPending || updateContainer.isPending,
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
function submit(event: SubmitEvent) {
	event.preventDefault();
	const body = {
		name: draft.name.trim(),
		description: draft.description.trim() || null,
		parentContainerId: draft.parentId || null,
	};
	if (!body.name) return;
	if (editing) updateContainer.mutate({ path: { id: editing.id }, body });
	else createContainer.mutate({ body });
}
function startEdit(container: InventoryContainer) {
	editing = container;
	draft = {
		name: container.name,
		description: container.description ?? "",
		parentId: container.parentContainerId ?? "",
	};
}
</script>

<svelte:head>
	<title>Inventory containers | Dublin HEMA Club</title>
</svelte:head>
<div
	class="inventory-page xl:flex xl:h-[calc(100svh-2.8125rem)] xl:flex-col xl:overflow-hidden"
>
	<InventoryPageHeader
		eyebrow="Operator inventory"
		title="Containers"
		icon={FolderTree}
		class="xl:items-center xl:pb-3"
	/>
	{#if containersQuery.isError}
		<Alert variant="destructive">
			<AlertDescription class="flex items-center justify-between">
				<span>
					{apiErrorMessage(containersQuery.error, "Could not load containers")}
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
			class="inventory-panel space-y-5 p-5 lg:sticky lg:top-6 xl:static xl:h-full xl:min-h-0 xl:overflow-y-auto xl:overscroll-contain xl:[scrollbar-gutter:stable]"
			onsubmit={submit}
		>
			<div class="flex items-center gap-3 border-b pb-4">
				<div
					class="grid size-10 place-items-center rounded-xl bg-secondary/20 text-primary"
				>
					{#if editing}<Pencil class="size-5" aria-hidden="true" />{:else}<Plus
							class="size-5"
							aria-hidden="true"
						/>{/if}
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
			<div class="space-y-2">
				<Label for="container-name">Name</Label>
				<Input
					id="container-name"
					class="h-11"
					maxlength={100}
					placeholder="e.g. Main equipment room"
					required
					bind:value={draft.name}
				/>
			</div>
			<div class="space-y-2">
				<Label for="container-description">Description</Label>
				<Input
					id="container-description"
					class="h-11"
					maxlength={500}
					placeholder="Optional location note"
					bind:value={draft.description}
				/>
			</div>
			<div class="space-y-2">
				<Label for="container-parent">Parent</Label>
				<Select.Root type="single" bind:value={draft.parentId}>
					<Select.Trigger
						id="container-parent"
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
				class="sticky top-0 z-10 flex items-end justify-between gap-3 border-b bg-background/95 pb-3 backdrop-blur-sm"
			>
				<div>
					<p
						class="text-xs font-semibold uppercase tracking-[0.16em] text-primary"
					>
						Storage map
					</p>
					<h2 class="mt-1 font-heading text-xl font-bold">Storage hierarchy</h2>
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
</div>
