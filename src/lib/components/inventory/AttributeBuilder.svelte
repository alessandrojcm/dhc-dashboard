<script lang="ts">
import type { AttributeDefinition } from '$lib/schemas/inventory';
import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/ui/card';
import { Button } from '$lib/components/ui/button';
import { Input } from '$lib/components/ui/input';
import { Label } from '$lib/components/ui/label';
import { Checkbox } from '$lib/components/ui/checkbox';
import { Badge } from '$lib/components/ui/badge';
import * as Select from '$lib/components/ui/select';
import * as Field from '$lib/components/ui/field';
import { Plus, Settings, Trash2 } from 'lucide-svelte';

interface AttributeBuilderProps {
	/** Current attributes array value */
	attributes: AttributeDefinition[];
	/** Callback to update attributes */
	onAttributesChange: (attributes: AttributeDefinition[]) => void;
	/** Optional validation issues for the field */
	issues?: Array<{ message: string }>;
}

const { attributes, onAttributesChange, issues = [] }: AttributeBuilderProps = $props();

const attributeCount = $derived(attributes.length);
const hasAttributes = $derived(attributeCount > 0);

let newAttribute = $state<AttributeDefinition>({
	type: 'text',
	label: '',
	required: false
});

const addAttribute = () => {
	if (!newAttribute.label) return;
	onAttributesChange([
		...attributes,
		{
			...newAttribute,
			...(newAttribute.type === 'select' && { options: [] }),
			name: newAttribute.label.toLowerCase().replaceAll(/ /g, '-')
		}
	]);
	// Reset form
	newAttribute = {
		type: 'text',
		label: '',
		required: false,
		name: ''
	};
};

const removeAttribute = (index: number) => {
	onAttributesChange(attributes.filter((_, i) => i !== index));
};

const updateAttribute = (index: number, field: keyof AttributeDefinition, value: unknown) => {
	const updated = [...attributes];
	updated[index] = { ...updated[index], [field]: value };
	onAttributesChange(updated);
};

const addOption = (attrIndex: number) => {
	const updated = [...attributes];
	const attr = updated[attrIndex];
	updated[attrIndex] = {
		...attr,
		options: [...(attr.options ?? []), '']
	};
	onAttributesChange(updated);
};

const updateOption = (attrIndex: number, optionIndex: number, value: string) => {
	const updated = [...attributes];
	const attr = updated[attrIndex];
	const options = [...(attr.options ?? [])];
	options[optionIndex] = value;
	updated[attrIndex] = { ...attr, options };
	onAttributesChange(updated);
};

const removeOption = (attrIndex: number, optionIndex: number) => {
	const updated = [...attributes];
	const attr = updated[attrIndex];
	updated[attrIndex] = {
		...attr,
		options: attr.options?.filter((_, i) => i !== optionIndex)
	};
	onAttributesChange(updated);
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
					<Select.Root type="single" bind:value={newAttribute.type}>
						<Select.Trigger id="attr-type" class="capitalize">
							{newAttribute.type}
						</Select.Trigger>
						<Select.Content>
							<Select.Item value="text">Text Input</Select.Item>
							<Select.Item value="select">Dropdown Select</Select.Item>
							<Select.Item value="number">Number Input</Select.Item>
							<Select.Item value="boolean">Checkbox</Select.Item>
						</Select.Content>
					</Select.Root>
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
				{#each attributes as attr, index (attr.name ?? '' + index)}
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
								onclick={() => removeAttribute(index)}
								class="text-destructive hover:text-destructive"
							>
								<Trash2 class="h-4 w-4" />
							</Button>
						</div>

						<Field.Field>
							<Field.Label>Display Label</Field.Label>
							<Input
								value={attr.label}
								oninput={(e) => updateAttribute(index, 'label', e.currentTarget.value)}
								name={`available_attributes[${index}].label`}
							/>
						</Field.Field>

						<div class="flex items-center space-x-2">
							<Checkbox
								checked={attr.required ?? false}
								onCheckedChange={(checked) => updateAttribute(index, 'required', checked)}
								id={`attr-required-${index}`}
							/>
							<Label for={`attr-required-${index}`}>Required field</Label>
						</div>

						{#if attr.type === 'select'}
							<div class="space-y-2">
								<Label>Options</Label>
								{#each attr.options ?? [] as optionValue, optionIndex (optionIndex)}
									<div class="flex items-center gap-2">
										<Input
											value={optionValue}
											oninput={(e) => updateOption(index, optionIndex, e.currentTarget.value)}
											placeholder="Option value"
											name={`available_attributes[${index}].options[${optionIndex}]`}
										/>
										<Button
											variant="ghost"
											size="sm"
											aria-label={`Remove option ${optionValue}`}
											onclick={() => removeOption(index, optionIndex)}
										>
											<Trash2 class="h-4 w-4" />
										</Button>
									</div>
								{/each}
								<Button variant="outline" size="sm" onclick={() => addOption(index)}>
									<Plus class="mr-2 h-4 w-4" />
									Add Option
								</Button>
							</div>
						{/if}
					</div>
				{/each}

				<!-- Hidden inputs for form submission -->
				<input type="hidden" name="available_attributes" value={JSON.stringify(attributes)} />
			</CardContent>
		</Card>
	{/if}

	<!-- Show validation issues -->
	{#each issues as issue}
		<Field.Error>{issue.message}</Field.Error>
	{/each}
</div>
