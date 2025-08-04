<script lang="ts">
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { Select, SelectContent, SelectItem, SelectTrigger } from '$lib/components/ui/select';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import type { CategorySchema } from '$lib/schemas/inventory';

	interface AttributeDefinition {
		type: 'text' | 'select' | 'number' | 'boolean';
		label: string;
		required?: boolean;
		options?: string[];
		default_value?: any;
	}

	let {
		category,
		attributes = $bindable({}),
		errors = {}
	}: {
		category: CategorySchema;
		attributes: Record<string, AttributeDefinition>;
		errors?: Record<string, string>;
	} = $props();

	const categoryAttributes = category?.available_attributes || {};

	// Initialize attributes with default values
	$effect(() => {
		if (category) {
			Object.entries(categoryAttributes).forEach(([key, attr]) => {
				if (attributes[key] === undefined && attr.default_value !== undefined) {
					attributes[key] = attr.default_value;
				}
			});
		}
	});
</script>

{#if Object.keys(categoryAttributes).length > 0}
	<div class="space-y-4">
		<h3 class="text-lg font-medium">Item Attributes</h3>
		<div class="grid gap-4 md:grid-cols-2">
			{#each Object.entries(categoryAttributes) as [key, attr]}
				<div class="space-y-2">
					<Label for={key}>
						{attr.label}
						{#if attr.required}
							<span class="text-destructive">*</span>
						{/if}
					</Label>

					{#if attr.type === 'text'}
						<Input
							id={key}
							name="attributes.{key}"
							bind:value={attributes[key]}
							placeholder={attr.label}
							class={errors[`attributes.${key}`] ? 'border-destructive' : ''}
						/>
					{:else if attr.type === 'number'}
						<Input
							id={key}
							name="attributes.{key}"
							type="number"
							bind:value={attributes[key]}
							placeholder={attr.label}
							class={errors[`attributes.${key}`] ? 'border-destructive' : ''}
						/>
					{:else if attr.type === 'select' && attr.options}
						<Select type="single" bind:value={attributes[key]} name="attributes.{key}">
							<SelectTrigger class={errors[`attributes.${key}`] ? 'border-destructive' : ''}>
								Select&nbsp;{attr.label.toLowerCase()}
							</SelectTrigger>
							<SelectContent>
								{#each attr.options as option}
									<SelectItem value={option}>{option}</SelectItem>
								{/each}
							</SelectContent>
						</Select>
					{:else if attr.type === 'boolean'}
						<div class="flex items-center space-x-2">
							<Checkbox
								id={key}
								name="attributes.{key}"
								bind:checked={attributes[key]}
							/>
							<Label for={key} class="text-sm font-normal">
								{attr.label}
							</Label>
						</div>
					{/if}

					{#if errors[`attributes.${key}`]}
						<p class="text-sm text-destructive">{errors[`attributes.${key}`]}</p>
					{/if}
				</div>
			{/each}
		</div>
	</div>
{:else}
	<div class="text-center py-8 text-muted-foreground">
		<p>This category has no custom attributes defined.</p>
	</div>
{/if}
