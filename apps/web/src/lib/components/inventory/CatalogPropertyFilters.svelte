<script lang="ts">
import type { InventoryPropertyDefinition } from "@dhc/api-client";
import { Input } from "$lib/components/ui/input";
import { Label } from "$lib/components/ui/label";
import {
	Select,
	SelectContent,
	SelectItem,
	SelectTrigger,
} from "$lib/components/ui/select";

const ANY_VALUE = "any";

let {
	definitions,
	values = $bindable(),
	onChange,
}: {
	definitions: InventoryPropertyDefinition[];
	values: Record<string, string>;
	onChange?: () => void;
} = $props();

const liveDefinitions = $derived(
	definitions.filter((definition) => !definition.retiredAt),
);

function setValue(definitionId: string, value: string) {
	const next = { ...values };
	if (value && value !== ANY_VALUE) next[definitionId] = value;
	else delete next[definitionId];
	values = next;
	onChange?.();
}
</script>

{#if liveDefinitions.length > 0}
	<div
		class="mt-3 grid grid-cols-1 gap-3 border-t pt-3 sm:grid-cols-2"
		data-testid="property-filter"
	>
		{#each liveDefinitions as definition (definition.id)}
			<div class="min-w-0 space-y-1.5">
				<Label class="text-xs font-medium" for={`property-${definition.id}`}>
					{definition.label}
				</Label>
				{#if definition.valueType === "boolean"}
					<Select
						type="single"
						value={values[definition.id] ?? ANY_VALUE}
						onValueChange={(value) =>
							setValue(definition.id, value ?? ANY_VALUE)}
					>
						<SelectTrigger
							id={`property-${definition.id}`}
							class="min-h-11 w-full"
						>
							{values[definition.id] === "true"
								? "Yes"
								: values[definition.id] === "false"
									? "No"
									: "Any"}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value={ANY_VALUE} label="Any">Any</SelectItem>
							<SelectItem value="true" label="Yes">Yes</SelectItem>
							<SelectItem value="false" label="No">No</SelectItem>
						</SelectContent>
					</Select>
				{:else if definition.valueType === "single_select"}
					{@const activeOptions = definition.options.filter(
						(option) => !option.retiredAt,
					)}
					<Select
						type="single"
						value={values[definition.id] ?? ANY_VALUE}
						onValueChange={(value) =>
							setValue(definition.id, value ?? ANY_VALUE)}
					>
						<SelectTrigger
							id={`property-${definition.id}`}
							class="min-h-11 w-full"
						>
							{activeOptions.find(
								(option) => option.id === values[definition.id],
							)?.label ?? "Any"}
						</SelectTrigger>
						<SelectContent>
							<SelectItem value={ANY_VALUE} label="Any">Any</SelectItem>
							{#each activeOptions as option (option.id)}
								<SelectItem value={option.id} label={option.label}>
									{option.label}
								</SelectItem>
							{/each}
						</SelectContent>
					</Select>
				{:else}
					<Input
						id={`property-${definition.id}`}
						type={definition.valueType === "decimal" ? "number" : "text"}
						step={definition.valueType === "decimal" ? "any" : undefined}
						class="min-h-11"
						value={values[definition.id] ?? ""}
						oninput={(event) =>
							setValue(definition.id, event.currentTarget.value)}
					/>
				{/if}
			</div>
		{/each}
	</div>
{/if}
