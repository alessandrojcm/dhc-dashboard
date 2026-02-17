<script lang="ts">
import {
	Card,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Textarea } from "$lib/components/ui/textarea";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
} from "$lib/components/ui/select";
import * as Field from "$lib/components/ui/field";
import { ArrowLeft, FolderOpen } from "lucide-svelte";
import type { InventoryContainer } from "$lib/types";
import { createContainer } from "../data.remote";
import { onMount } from "svelte";

interface ContainerWithChildren extends InventoryContainer {
	children: ContainerWithChildren[];
}

interface HierarchicalContainer extends ContainerWithChildren {
	displayName: string;
	level: number;
}

let { data } = $props();

onMount(() => {
	createContainer.fields.set({
		name: "",
		description: "",
		parent_container_id: "",
	});
});

const parentContainerId = $derived(
	createContainer.fields.parent_container_id.value() ?? "",
);

// Build hierarchy display for parent selection
const buildHierarchyDisplay = (
	containers: InventoryContainer[],
): HierarchicalContainer[] => {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const containerMap = new Map<string, ContainerWithChildren>();
	const rootContainers: ContainerWithChildren[] = [];

	// First pass: create all containers with empty children arrays
	containers.forEach((container) => {
		containerMap.set(container.id, { ...container, children: [] });
	});

	// Second pass: build the hierarchy
	containers.forEach((container) => {
		if (container.parent_container_id) {
			const parent = containerMap.get(container.parent_container_id);
			const child = containerMap.get(container.id);
			if (parent && child) {
				parent.children.push(child);
			}
		} else {
			const rootContainer = containerMap.get(container.id);
			if (rootContainer) {
				rootContainers.push(rootContainer);
			}
		}
	});

	// Flatten with indentation for display
	const flattenWithIndent = (
		containers: ContainerWithChildren[],
		level = 0,
	): HierarchicalContainer[] => {
		const result: HierarchicalContainer[] = [];
		containers.forEach((container) => {
			result.push({
				...container,
				displayName: "  ".repeat(level) + container.name,
				level,
			});
			if (container.children.length > 0) {
				result.push(...flattenWithIndent(container.children, level + 1));
			}
		});
		return result;
	};

	return flattenWithIndent(rootContainers);
};

const hierarchicalContainers = buildHierarchyDisplay(data.containers);

// Find the selected container for display
const selectedContainer = $derived.by(() => {
	if (!parentContainerId) return null;
	return hierarchicalContainers.find((c) => c.id === parentContainerId);
});
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/containers" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">Create Container</h1>
		</div>
		<p class="text-muted-foreground">Add a new storage container to organize your inventory</p>
	</div>

	<div class="max-w-2xl">
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<FolderOpen class="h-5 w-5" />
					Container Details
				</CardTitle>
				<CardDescription>
					Provide information about the new container. You can organize containers hierarchically by
					selecting a parent container.
				</CardDescription>
			</CardHeader>
			<CardContent>
				<form {...createContainer} class="space-y-6">
					<Field.Field>
						{@const fieldProps = createContainer.fields.name.as('text')}
						<Field.Label for={fieldProps.name}>Container Name *</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="e.g., Main Storage Room, Black Duffel Bag #1"
						/>
						{#each createContainer.fields.name.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = createContainer.fields.description.as('text')}
						<Field.Label for={fieldProps.name}>Description</Field.Label>
						<Textarea
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Optional description of the container and its purpose"
							rows={3}
						/>
						{#each createContainer.fields.description.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						<Field.Label>Parent Container</Field.Label>
						<Select
							type="single"
							value={parentContainerId}
							onValueChange={(v) => createContainer.fields.parent_container_id.set(v)}
							name="parent_container_id"
						>
							<SelectTrigger>
								{selectedContainer
									? selectedContainer.displayName
									: 'No parent container (root level)'}
							</SelectTrigger>
							<SelectContent>
								<SelectItem value="">No parent container (root level)</SelectItem>
								{#each hierarchicalContainers as container (container.id)}
									<SelectItem value={container.id}>
										{container.displayName}
									</SelectItem>
								{/each}
							</SelectContent>
						</Select>
						<Field.Description>
							Choose a parent container to create a hierarchy. Leave empty to create a root-level
							container.
						</Field.Description>
						{#each createContainer.fields.parent_container_id.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<div class="flex gap-3 pt-4">
						<Button type="submit" disabled={!!createContainer.pending}>
							{createContainer.pending ? 'Creating...' : 'Create Container'}
						</Button>
						<Button href="/dashboard/inventory/containers" variant="outline">Cancel</Button>
					</div>
				</form>
			</CardContent>
		</Card>
	</div>
</div>
