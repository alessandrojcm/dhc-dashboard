<!--
	ALE-378: the Capacity / fee / cutoff dialog for one scheduled workshop.
	Phoenix decides what may change (the cutoff before the start, the
	contact-from date until Batch 1); `contactFromEditable` only hides a
	field Phoenix would refuse.
-->
<script lang="ts">
import type { BeginnersWorkshop } from "@dhc/api-client";
import { parseDate, type DateValue } from "@internationalized/date";
import { toast } from "svelte-sonner";
import { Button } from "#lib/components/ui/button/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import {
	feeInEuro,
	formatCivilDate,
} from "#lib/beginners-workshops/presentation.js";
import { workshopSettingsSchema } from "#lib/schemas/beginnersWorkshop.js";
import { updateWorkshopSettings } from "./workshops.remote";

let {
	workshop,
	open = $bindable(false),
}: { workshop: BeginnersWorkshop; open?: boolean } = $props();

const form = $derived(updateWorkshopSettings.for(workshop.id));
let formError = $state<string | null>(null);

type DateKey = "paymentCutoffDate" | "contactFromDate";

function pickerValue(key: DateKey): DateValue | undefined {
	const value = form.fields[key].value() || workshop[key];
	try {
		return parseDate(value);
	} catch {
		return undefined;
	}
}

function setDate(key: DateKey, value: DateValue | undefined) {
	if (value) form.fields[key].set(value.toString());
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-lg">
		<Dialog.Header>
			<Dialog.Title>Capacity, fee and cutoff</Dialog.Title>
			<Dialog.Description>
				{formatCivilDate(workshop.date)} at {workshop.startTime}, {workshop.venue}.
				Nothing is emailed when you save.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(workshopSettingsSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success("Workshop settings saved");
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-5"
			aria-label="Workshop settings"
		>
			<input {...form.fields.id.as("hidden", workshop.id)} />

			<Field.Group class="grid gap-4 sm:grid-cols-3">
				<Field.Field>
					{@const props = form.fields.capacity.as("number", workshop.capacity)}
					<Field.Label for={props.name}>Capacity</Field.Label>
					<Input {...props} id={props.name} min="1" step="1" />
					{#each form.fields.capacity.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = form.fields.fee.as(
						"number",
						feeInEuro(workshop.feeCents),
					)}
					<Field.Label for={props.name}>Fee (€)</Field.Label>
					<Input {...props} id={props.name} min="0.01" step="0.01" />
					{#each form.fields.fee.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = form.fields.paymentWindowDays.as(
						"number",
						workshop.paymentWindowDays,
					)}
					<Field.Label for={props.name}>Payment window (days)</Field.Label>
					<Input {...props} id={props.name} min="1" step="1" />
					<Field.Description>Applies to later Batches.</Field.Description>
					{#each form.fields.paymentWindowDays.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			<Field.Group class="grid gap-4 sm:grid-cols-[1fr_8rem]">
				<Field.Field>
					{@const { value: _cutoff, ...props } =
						form.fields.paymentCutoffDate.as(
							"text",
							workshop.paymentCutoffDate,
						)}
					<Field.Label for={props.name}>Payment Cutoff date</Field.Label>
					<DatePicker
						{...props}
						id={props.name}
						label="Payment Cutoff date"
						value={pickerValue("paymentCutoffDate")}
						onValueChange={(value) => setDate("paymentCutoffDate", value)}
					/>
					{#each form.fields.paymentCutoffDate.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = form.fields.paymentCutoffTime.as(
						"time",
						workshop.paymentCutoffTime,
					)}
					<Field.Label for={props.name}>Cutoff time</Field.Label>
					<Input {...props} id={props.name} />
					{#each form.fields.paymentCutoffTime.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			{#if workshop.contactFromEditable}
				<Field.Field>
					{@const { value: _contact, ...props } =
						form.fields.contactFromDate.as("text", workshop.contactFromDate)}
					<Field.Label for={props.name}>Contact from</Field.Label>
					<DatePicker
						{...props}
						id={props.name}
						label="Contact from"
						value={pickerValue("contactFromDate")}
						onValueChange={(value) => setDate("contactFromDate", value)}
					/>
					<Field.Description
						>Batch 1 goes out at 10:00 on this date.</Field.Description
					>
					{#each form.fields.contactFromDate.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			{/if}

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Cancel</Button
				>
				<Button type="submit" disabled={!!form.pending}>Save</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
