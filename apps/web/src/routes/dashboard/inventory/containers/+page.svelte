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
import { apiErrorMessage } from "$lib/api-error";
import {
	Archive,
	FolderTree,
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
<div class="mx-auto max-w-6xl space-y-6 px-4 py-8 sm:px-6">
	<header>
		<p class="text-xs font-bold tracking-[0.14em] text-primary uppercase">
			Operator inventory
		</p>
		<h1 class="font-heading text-3xl font-bold">Containers</h1>
		<p class="mt-2 text-sm text-muted-foreground">
			A flat viewer rebuilt as a hierarchy. Children and items are always
			handled explicitly before archive or delete.
		</p>
	</header>
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
	<div class="grid gap-6 lg:grid-cols-[22rem_1fr]">
		<form class="space-y-4 rounded-2xl border bg-card p-5" onsubmit={submit}>
			<h2 class="text-lg font-semibold">
				{editing ? "Edit container" : "Add container"}
			</h2>
			<div>
				<Label for="container-name">Name</Label>
				<Input
					id="container-name"
					maxlength={100}
					required
					bind:value={draft.name}
				/>
			</div>
			<div>
				<Label for="container-description">Description</Label>
				<Input
					id="container-description"
					maxlength={500}
					bind:value={draft.description}
				/>
			</div>
			<div>
				<Label for="container-parent">Parent</Label>
				<select
					id="container-parent"
					class="h-10 w-full rounded-md border bg-background px-3"
					bind:value={draft.parentId}
				>
					<option value="">Root</option>
					{#each parentOptions as candidate (candidate.id)}
						<option value={candidate.id}>{candidate.name}</option>
					{/each}
				</select>
			</div>
			<div class="flex gap-2">
				<Button type="submit" disabled={isSaving}>
					{editing ? "Save changes" : "Add container"}
				</Button>
				{#if editing}
					<Button
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
		<section class="space-y-3">
			<h2 class="text-lg font-semibold">Storage hierarchy</h2>
			{#each containers as container (container.id)}
				<article
					class="rounded-2xl border bg-card p-4 shadow-sm {container.archivedAt
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
								Edit / move
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
