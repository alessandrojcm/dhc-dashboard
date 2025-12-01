<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { Plus, Trash2, Settings } from 'lucide-svelte';
	import type { SuperForm } from 'sveltekit-superforms/client';
	import type { AttributeDefinition, CategorySchema } from '$lib/schemas/inventory';
	import * as Form from '$lib/components/ui/form';

	let {
		form
	}: {
		form: SuperForm<CategorySchema>;
	} = $props();
	const { form: formData } = form;
	const attributeCount = $derived($formData.available_attributes.length);
	const hasAttributes = $derived(attributeCount > 0);

	let newAttribute = $state<AttributeDefinition>({
		type: 'text',
		label: '',
		required: false
	});

	const addAttribute = () => {
		if (!newAttribute.label) return;
		$formData.available_attributes = [
			...$formData.available_attributes,
			{
				...newAttribute,
				...(newAttribute.type === 'select' && { options: [] }),
				name: newAttribute.label.toLowerCase().replaceAll(/ /g, '-')
			}
		];
		// Reset form
		newAttribute = {
			type: 'text',
			label: '',
			required: false,
			name: ''
		};
	};
</script>

<div class="space-y-6">
	<!-- Add New Attribute -->
	<Card>
		<CardHeader>
			<CardTitle class="flex items-center gap-2">
				<Plus class="h-5 w-5" />
				Add New Attribute
			</CardTitle>
		</CardHeader>
		<CardContent class="space-y-4">
			<div class="space-y-2">
				<Label for="attr-label">Display Label</Label>
				<Input
					id="attr-label"
					bind:value={newAttribute.label}
					placeholder="e.g., Brand, Size, Color"
				/>
			</div>

			<div class="grid grid-cols-2 gap-4">
				<div class="space-y-2">
					<Label for="attr-type">Attribute Type</Label>
					<Select type="single" bind:value={newAttribute.type}>
						<SelectTrigger id="attr-type" class="capitalize">
							{newAttribute.type}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value="text">Text Input</SelectItem>
							<SelectItem value="select">Dropdown Select</SelectItem>
							<SelectItem value="number">Number Input</SelectItem>
							<SelectItem value="boolean">Checkbox</SelectItem>
						</SelectContent>
					</Select>
				</div>
				<div class="flex items-center space-x-2 pt-6">
					<Checkbox bind:checked={newAttribute.required} id="attr-required" />
					<Label for="attr-required">Required field</Label>
				</div>
			</div>

			<Button onclick={addAttribute} disabled={!newAttribute.label}>
				<Plus class="mr-2 h-4 w-4" />
				Add Attribute
			</Button>
		</CardContent>
	</Card>

	<!-- Existing Attributes -->
	{#if hasAttributes}
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Settings class="h-5 w-5" />
					Category Attributes ({attributeCount})
				</CardTitle>
			</CardHeader>
			<CardContent class="space-y-4">
				{#each $formData.available_attributes as attr, index (attr.name ?? '' + index)}
					<div class="border rounded-lg p-4 space-y-4">
						<div class="flex items-center justify-between">
							<div class="flex items-center gap-2">
								<h3 class="font-medium">{attr.label}</h3>
								<Badge variant="secondary" class="text-xs">{attr.type}</Badge>
								{#if attr.required}
									<Badge variant="destructive" class="text-xs">Required</Badge>
								{/if}
							</div>
							<Button
								variant="ghost"
								size="sm"
								onclick={() =>
									($formData.available_attributes = $formData.available_attributes.filter(
										(_, i) => i !== index
									))}
								class="text-destructive hover:text-destructive"
							>
								<Trash2 class="h-4 w-4" />
							</Button>
						</div>
						<Form.Field {form} name="available_attributes[{index}].label">
							<Form.Control>
								{#snippet children({ props })}
									<Form.Label>Display Label</Form.Label>
									<Input {...props} bind:value={$formData.available_attributes[index].label} />
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>
						<Form.Field {form} name="available_attributes[{index}].required">
							<Form.Control>
								{#snippet children({ props })}
									<div class="flex items-center space-x-2 pt-6">
										<Checkbox
											{...props}
											bind:checked={$formData.available_attributes[index].required}
										/>
										<Form.Label>Required field</Form.Label>
									</div>
								{/snippet}
							</Form.Control>
							<Form.FieldErrors />
						</Form.Field>

						{#if attr.type === 'select' && attr.options}
							<Form.Field {form} name="available_attributes[{index}].options">
								<Form.Control>
									{#snippet children({ props })}
										<input
											type="hidden"
											{...props}
											bind:value={$formData.available_attributes[index].options}
										/>
										<Form.Label>Options</Form.Label>
										<div class="space-y-2">
											{#each attr.options ?? [] as value, i (value + i)}
												{#if $formData.available_attributes[index].options}
													<Form.Field {form} name="available_attributes[{index}].options[{i}]">
														<Form.Control>
															{#snippet children({ props })}
																<Form.Label>Option {i + 1}</Form.Label>
																<Input
																	{...props}
																	placeholder="Option value"
																	bind:value={$formData.available_attributes[index].options[i]}
																/>
																<Button
																	variant="ghost"
																	size="sm"
																	aria-label={`Remove option ${value}`}
																	onclick={() =>
																		($formData.available_attributes[index].options =
																			attr.options?.filter((v) => v !== value))}
																>
																	<Trash2 class="h-4 w-4" />
																</Button>
															{/snippet}
														</Form.Control>
														<Form.FieldErrors />
													</Form.Field>
												{/if}
											{/each}
											<Button
												variant="outline"
												size="sm"
												onclick={() =>
													($formData.available_attributes[index].options = [
														...(attr.options ?? []),
														''
													])}
											>
												<Plus class="mr-2 h-4 w-4" />
												Add Option
											</Button>
										</div>
									{/snippet}
								</Form.Control>
								<Form.FieldErrors />
							</Form.Field>
						{/if}
					</div>
				{/each}
			</CardContent>
		</Card>
	{/if}
</div>
