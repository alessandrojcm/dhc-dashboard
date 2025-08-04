<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
	import { Badge } from '$lib/components/ui/badge';
	import { Plus, Trash2, Settings } from 'lucide-svelte';

	interface AttributeDefinition {
		type: 'text' | 'select' | 'number' | 'boolean';
		label: string;
		required?: boolean;
		options?: string[];
		default_value?: any;
	}

	let {
		attributes = $bindable({}),
		errors = {}
	}: {
		attributes: Record<string, AttributeDefinition>;
		errors?: Record<string, string>;
	} = $props();

	let newAttribute = $state<AttributeDefinition>({
		type: 'text',
		label: '',
		required: false
	});

	// Auto-generate key from display label
	const generateKey = (label: string): string => {
		return label
			.toLowerCase()
			.replace(/[^a-z0-9\s]/g, '') // Remove special characters
			.replace(/\s+/g, '') // Remove spaces
			.replace(/^([a-z])/, (match, p1) => p1.toLowerCase()) // Ensure first letter is lowercase
			.replace(/\s([a-z])/g, (match, p1) => p1.toUpperCase()); // Convert to camelCase
	};

	const addAttribute = () => {
		if (!newAttribute.label) return;

		const key = generateKey(newAttribute.label);
		// Ensure key is unique
		let finalKey = key;
		let counter = 1;
		while (attributes[finalKey]) {
			finalKey = `${key}${counter}`;
			counter++;
		}

		attributes[finalKey] = { ...newAttribute };

		// Reset form
		newAttribute = {
			type: 'text',
			label: '',
			required: false
		};
	};

	const removeAttribute = (key: string) => {
		delete attributes[key];
		attributes = { ...attributes };
	};

	const updateAttribute = (key: string, updates: Partial<AttributeDefinition>) => {
		attributes[key] = { ...attributes[key], ...updates };
		attributes = { ...attributes };
	};

	const addOption = (key: string) => {
		if (!attributes[key].options) {
			attributes[key].options = [];
		}
		attributes[key].options!.push('');
		attributes = { ...attributes };
	};

	const updateOption = (key: string, index: number, value: string) => {
		if (attributes[key].options) {
			attributes[key].options[index] = value;
			attributes = { ...attributes };
		}
	};

	const removeOption = (key: string, index: number) => {
		if (attributes[key].options) {
			attributes[key].options.splice(index, 1);
			attributes = { ...attributes };
		}
	};

	// Derive error messages from the errors object
	const errorMessage = $derived(() => {
		if (!errors || Object.keys(errors).length === 0) return '';
		
		const messages: string[] = [];
		
		// Handle available_attributes errors
		if (errors.available_attributes) {
			const attrErrors = errors.available_attributes;
			for (const [attrKey, attrError] of Object.entries(attrErrors)) {
				if (typeof attrError === 'object' && attrError !== null) {
					// Handle nested errors (like label errors)
					for (const [field, fieldErrors] of Object.entries(attrError)) {
						if (Array.isArray(fieldErrors)) {
							messages.push(...fieldErrors.map(err => `${attrKey}.${field}: ${err}`));
						}
					}
				} else if (typeof attrError === 'string') {
					messages.push(`${attrKey}: ${attrError}`);
				}
			}
		}
		
		// Handle any other top-level errors
		for (const [key, value] of Object.entries(errors)) {
			if (key !== 'available_attributes' && typeof value === 'string') {
				messages.push(`${key}: ${value}`);
			}
		}
		
		return messages.join(', ');
	});
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
				{#if newAttribute.label}
					<p class="text-sm text-muted-foreground">
						Key will be: <code class="bg-muted px-1 py-0.5 rounded text-xs">{generateKey(newAttribute.label)}</code>
					</p>
				{/if}
			</div>

			<div class="grid grid-cols-2 gap-4">
				<div class="space-y-2">
					<Label for="attr-type">Attribute Type</Label>
					<Select type="single" bind:value={newAttribute.type}>
						<SelectTrigger class="capitalize">
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
	{#if Object.keys(attributes).length > 0}
		<Card>
			<CardHeader>
				<CardTitle class="flex items-center gap-2">
					<Settings class="h-5 w-5" />
					Category Attributes ({Object.keys(attributes).length})
				</CardTitle>
			</CardHeader>
			<CardContent class="space-y-4">
				{#each Object.entries(attributes) as [key, attr]}
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
								onclick={() => removeAttribute(key)}
								class="text-destructive hover:text-destructive"
							>
								<Trash2 class="h-4 w-4" />
							</Button>
						</div>

						<div class="grid grid-cols-2 gap-4">
							<div class="space-y-2">
								<Label>Display Label</Label>
								<Input
									bind:value={attr.label}
									onchange={() => updateAttribute(key, { label: attr.label })}
								/>
							</div>
							<div class="flex items-center space-x-2 pt-6">
								<Checkbox
									bind:checked={attr.required}
									onchange={() => updateAttribute(key, { required: attr.required })}
								/>
								<Label>Required field</Label>
							</div>
						</div>

						{#if attr.type === 'select'}
							<div class="space-y-2">
								<Label>Options</Label>
								<div class="space-y-2">
									{#each attr.options || [] as option, index}
										<div class="flex gap-2">
											<Input
												bind:value={attr.options[index]}
												onchange={() => updateOption(key, index, option)}
												placeholder="Option value"
											/>
											<Button
												variant="ghost"
												size="sm"
												onclick={() => removeOption(key, index)}
											>
												<Trash2 class="h-4 w-4" />
											</Button>
										</div>
									{/each}
									<Button
										variant="outline"
										size="sm"
										onclick={() => addOption(key)}
									>
										<Plus class="mr-2 h-4 w-4" />
										Add Option
									</Button>
								</div>
							</div>
						{/if}
					</div>
				{/each}
			</CardContent>
		</Card>
	{/if}

	{#if errorMessage()}
		<p class="text-sm text-destructive">{errorMessage()}</p>
	{/if}
</div>
