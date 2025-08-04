<script lang="ts">
	import { superForm } from 'sveltekit-superforms';
	import { valibot } from 'sveltekit-superforms/adapters';
	import { containerSchema } from '$lib/schemas/inventory';
	import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Textarea } from '$lib/components/ui/textarea';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { AlertCircleIcon, ArrowLeft, FolderOpen, Trash2 } from 'lucide-svelte';
	import { enhance } from '$app/forms';
	import type { Database } from '$database';
	import * as Alert from '$lib/components/ui/alert';

	type Container = Database['public']['Tables']['containers']['Row'];

	interface ContainerWithChildren extends Container {
		children: ContainerWithChildren[];
	}

	interface HierarchicalContainer extends ContainerWithChildren {
		displayName: string;
		level: number;
	}

	let { data } = $props();

	const { form, errors, enhance: formEnhance, submitting, message } = superForm(data.form, {
		validators: valibot(containerSchema)
	});

	// Build hierarchy display for parent selection
	const buildHierarchyDisplay = (containers: Container[]): HierarchicalContainer[] => {
		const containerMap = new Map<string, ContainerWithChildren>();
		const rootContainers: ContainerWithChildren[] = [];

		// First pass: create all containers with empty children arrays
		containers.forEach(container => {
			containerMap.set(container.id, { ...container, children: [] });
		});

		// Second pass: build the hierarchy
		containers.forEach(container => {
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
		const flattenWithIndent = (containers: ContainerWithChildren[], level = 0): HierarchicalContainer[] => {
			const result: HierarchicalContainer[] = [];
			containers.forEach(container => {
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

	// Filter out the current container and its descendants to prevent circular references
	const getDescendantIds = (containerId: string, containers: Container[]): Set<string> => {
		const descendants = new Set<string>();
		descendants.add(containerId);

		const addDescendants = (parentId: string) => {
			containers.forEach(container => {
				if (container.parent_container_id === parentId && !descendants.has(container.id)) {
					descendants.add(container.id);
					addDescendants(container.id);
				}
			});
		};

		addDescendants(containerId);
		return descendants;
	};

	const excludedIds = getDescendantIds(data.container.id, data.containers);
	const availableContainers = data.containers.filter(c => !excludedIds.has(c.id));
	const hierarchicalContainers = buildHierarchyDisplay(availableContainers);
	const selectedContainer = $derived(hierarchicalContainers.find(container => container.id === $form.parent_container_id));

	let showDeleteConfirm = $state(false);
</script>

<div class="p-6">
	<div class="mb-6">
		<div class="flex items-center gap-2 mb-2">
			<Button href="/dashboard/inventory/containers/{data.container.id}" variant="ghost" size="sm">
				<ArrowLeft class="h-4 w-4" />
			</Button>
			<h1 class="text-3xl font-bold">Edit Container</h1>
		</div>
		<p class="text-muted-foreground">Update container information and organization</p>
	</div>
	{#if $message}
		<Alert.Root variant="destructive" class="p-4">
			<AlertCircleIcon />
			<Alert.Title>{$message}</Alert.Title>
		</Alert.Root>
	{/if}

	<div class="max-w-2xl">
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<FolderOpen class="h-5 w-5" />
					Container Details
				</CardTitle>
				<CardDescription>
					Update the container information. Be careful when changing the parent container as it affects the hierarchy.
				</CardDescription>
			</CardHeader>
			<CardContent>
				<form method="POST" action="?/update" use:formEnhance class="space-y-6">
					<div class="space-y-2">
						<Label for="name">Container Name *</Label>
						<Input
							id="name"
							name="name"
							bind:value={$form.name}
							placeholder="e.g., Main Storage Room, Black Duffel Bag #1"
							class={$errors.name ? 'border-destructive' : ''}
						/>
						{#if $errors.name}
							<p class="text-sm text-destructive">{$errors.name}</p>
						{/if}
					</div>

					<div class="space-y-2">
						<Label for="description">Description</Label>
						<Textarea
							id="description"
							name="description"
							bind:value={$form.description}
							placeholder="Optional description of the container and its purpose"
							rows={3}
							class={$errors.description ? 'border-destructive' : ''}
						/>
						{#if $errors.description}
							<p class="text-sm text-destructive">{$errors.description}</p>
						{/if}
					</div>

					<div class="space-y-2">
						<Label for="parent_container_id">Parent Container</Label>
						<Select type="single" bind:value={$form.parent_container_id} name="parent_container_id">
							<SelectTrigger>
								{selectedContainer ? selectedContainer.displayName : 'Select a parent container (optional)'}
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
						{#if $errors.parent_container_id}
							<p class="text-sm text-destructive">{$errors.parent_container_id}</p>
						{/if}
						<p class="text-sm text-muted-foreground">
							Choose a parent container to create a hierarchy. Leave empty to create a root-level container.
						</p>
					</div>

					<div class="flex gap-3 pt-4">
						<Button type="submit" disabled={$submitting}>
							{$submitting ? 'Updating...' : 'Update Container'}
						</Button>
						<Button href="/dashboard/inventory/containers/{data.container.id}" variant="outline">
							Cancel
						</Button>
					</div>
				</form>
			</CardContent>
		</Card>

		<!-- Delete Section -->
		<Card class="mt-6 border-destructive">
			<CardHeader>
				<CardTitle class="text-destructive flex items-center gap-2">
					<Trash2 class="h-5 w-5" />
					Danger Zone
				</CardTitle>
				<CardDescription>
					Permanently delete this container. This action cannot be undone.
				</CardDescription>
			</CardHeader>
			<CardContent>
				{#if !showDeleteConfirm}
					<Button
						variant="destructive"
						onclick={() => showDeleteConfirm = true}
					>
						Delete Container
					</Button>
				{:else}
					<div class="space-y-4">
						<p class="text-sm text-muted-foreground">
							Are you sure you want to delete this container? This will also delete all child containers and move any
							items to the parent container or root level.
						</p>
						<div class="flex gap-3">
							<form method="POST" action="?/delete" use:enhance>
								<Button type="submit" variant="destructive">
									Yes, Delete Container
								</Button>
							</form>
							<Button
								variant="outline"
								onclick={() => showDeleteConfirm = false}
							>
								Cancel
							</Button>
						</div>
					</div>
				{/if}
			</CardContent>
		</Card>
	</div>
</div>
