<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { containerSchema } from '$lib/schemas/inventory';
	import {
		Card,
		CardContent,
		CardDescription,
		CardHeader,
		CardTitle
	} from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import * as Form from '$lib/components/ui/form';
	import { ArrowLeft, FolderOpen } from 'lucide-svelte';
    import type {InventoryContainer} from "$lib/types";


	interface ContainerWithChildren extends InventoryContainer {
		children: ContainerWithChildren[];
	}

	interface HierarchicalContainer extends ContainerWithChildren {
		displayName: string;
		level: number;
	}

	let { data } = $props();

	const form = superForm(data.form, {
		validators: valibot(containerSchema),
		resetForm: true
	});

	const { form: formData, enhance, submitting } = form;

	// Build hierarchy display for parent selection
	const buildHierarchyDisplay = (containers: InventoryContainer[]): HierarchicalContainer[] => {
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
			level = 0
		): HierarchicalContainer[] => {
			const result: HierarchicalContainer[] = [];
			containers.forEach((container) => {
				result.push({
					...container,
					displayName: '  '.repeat(level) + container.name,
					level
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
		if (!$formData.parent_container_id) return null;
		return hierarchicalContainers.find((c) => c.id === $formData.parent_container_id);
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
				<form method="POST" use:enhance class="space-y-6">
					<Form.Field {form} name="name">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>Container Name *</Form.Label>
								<Input
									{...props}
									bind:value={$formData.name}
									placeholder="e.g., Main Storage Room, Black Duffel Bag #1"
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="description">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>Description</Form.Label>
								<Textarea
									{...props}
									bind:value={$formData.description}
									placeholder="Optional description of the container and its purpose"
									rows={3}
								/>
							{/snippet}
						</Form.Control>
						<Form.FieldErrors />
					</Form.Field>

					<Form.Field {form} name="parent_container_id">
						<Form.Control>
							{#snippet children({ props })}
								<Form.Label>Parent Container</Form.Label>
								<Select type="single" bind:value={$formData.parent_container_id} name={props.name}>
									<SelectTrigger {...props}>
										{selectedContainer
											? selectedContainer.displayName
											: 'No parent container (root level)'}
									</SelectTrigger>
									<SelectContent>
										<SelectItem value="">No parent container (root level)</SelectItem>
										{#each hierarchicalContainers as container}
											<SelectItem value={container.id}>
												{container.displayName}
											</SelectItem>
										{/each}
									</SelectContent>
								</Select>
							{/snippet}
						</Form.Control>
						<Form.Description>
							Choose a parent container to create a hierarchy. Leave empty to create a root-level
							container.
						</Form.Description>
						<Form.FieldErrors />
					</Form.Field>

					<div class="flex gap-3 pt-4">
						<Form.Button type="submit" disabled={$submitting}>
							{$submitting ? 'Creating...' : 'Create Container'}
						</Form.Button>
						<Button href="/dashboard/inventory/containers" variant="outline">Cancel</Button>
					</div>
				</form>
			</CardContent>
		</Card>
	</div>
</div>
