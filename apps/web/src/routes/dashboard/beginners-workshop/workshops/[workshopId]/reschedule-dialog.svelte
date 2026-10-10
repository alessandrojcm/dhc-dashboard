<!--
	ALE-394: the Reschedule dialog — date, start time and venue, the Payment
	Cutoff and (while Batch 1 hasn't gone out) the contact-from date, both
	prefilled with the offsets Phoenix keeps and following a new date or time
	until edited. It says how many people the reschedule emails before saving.
	Phoenix decides: it is refused only after finalisation or cancellation.
-->
<script lang="ts">
import type { BeginnersWorkshop } from "@dhc/api-client";
import { AlertTriangle } from "@lucide/svelte";
import { parseDate, type DateValue } from "@internationalized/date";
import { toast } from "svelte-sonner";
import { formatCivilDate } from "#lib/beginners-workshops/presentation.js";
import {
	dublinToday,
	keptContactFrom,
	keptCutoff,
	rescheduleWarning,
} from "#lib/beginners-workshops/reschedule.js";
import { Button } from "#lib/components/ui/button/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import {
	rescheduleWorkshopSchema,
	VENUE_MAX,
} from "#lib/schemas/beginnersWorkshop.js";
import { rescheduleWorkshop } from "./console.remote";

let {
	workshop,
	recipients,
	open = $bindable(false),
	today = dublinToday(),
}: {
	workshop: BeginnersWorkshop;
	recipients: number;
	open?: boolean;
	/** Dublin today (`YYYY-MM-DD`); injectable for tests. */
	today?: string;
} = $props();

const form = $derived(rescheduleWorkshop.for(workshop.id));
let formError = $state<string | null>(null);
// Once edited, a field no longer follows the new date and time.
let cutoffEdited = $state(false);
let contactFromEdited = $state(false);

const warning = $derived(rescheduleWarning(recipients));

type DateKey = "date" | "paymentCutoffDate" | "contactFromDate";

function current(key: "date" | "startTime"): string {
	return form.fields[key].value() || workshop[key];
}

function pickerValue(key: DateKey, fallback: string): DateValue | undefined {
	try {
		return parseDate(form.fields[key].value() || fallback);
	} catch {
		return undefined;
	}
}

// The kept offsets for the date and start time now in the form.
function follow(date: string, startTime: string) {
	const cutoff = keptCutoff(workshop, date, startTime);
	if (!cutoffEdited) {
		form.fields.paymentCutoffDate.set(cutoff.date);
		form.fields.paymentCutoffTime.set(cutoff.time);
	}
	if (workshop.contactFromEditable && !contactFromEdited) {
		const cutoffDate = form.fields.paymentCutoffDate.value() || cutoff.date;
		form.fields.contactFromDate.set(
			keptContactFrom(workshop, date, cutoffDate, today),
		);
	}
}

function setWorkshopDate(value: DateValue | undefined) {
	if (!value) return;
	form.fields.date.set(value.toString());
	follow(value.toString(), current("startTime"));
}

function setCutoffDate(value: DateValue | undefined) {
	if (!value) return;
	cutoffEdited = true;
	form.fields.paymentCutoffDate.set(value.toString());
}

function setContactFrom(value: DateValue | undefined) {
	if (!value) return;
	contactFromEdited = true;
	form.fields.contactFromDate.set(value.toString());
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-lg">
		<Dialog.Header>
			<Dialog.Title>Reschedule {formatCivilDate(workshop.date)}</Dialog.Title>
			<Dialog.Description>
				Same workshop: every Intake carries on and nobody reconfirms. Seats and
				chances to pay are unchanged.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(rescheduleWorkshopSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success("Workshop rescheduled");
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-5"
			aria-label="Reschedule workshop"
		>
			<input {...form.fields.id.as("hidden", workshop.id)} />

			<Field.Group class="grid gap-4 sm:grid-cols-[1fr_8rem]">
				<Field.Field>
					{@const { value: _date, ...props } = form.fields.date.as(
						"text",
						workshop.date,
					)}
					<Field.Label for={props.name}>New date</Field.Label>
					<DatePicker
						{...props}
						id={props.name}
						label="New date"
						value={pickerValue("date", workshop.date)}
						onValueChange={setWorkshopDate}
					/>
					{#each form.fields.date.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = form.fields.startTime.as("time", workshop.startTime)}
					<Field.Label for={props.name}>Start</Field.Label>
					<Input
						{...props}
						id={props.name}
						oninput={(event) =>
							follow(current("date"), event.currentTarget.value)}
					/>
					{#each form.fields.startTime.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			<Field.Field>
				{@const props = form.fields.venue.as("text", workshop.venue)}
				<Field.Label for={props.name}>Venue</Field.Label>
				<Input {...props} id={props.name} maxlength={VENUE_MAX} />
				{#each form.fields.venue.issues() as issue (issue.message)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</Field.Field>

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
						value={pickerValue("paymentCutoffDate", workshop.paymentCutoffDate)}
						onValueChange={setCutoffDate}
					/>
					<Field.Description
						>Keeps its offset before the start.</Field.Description
					>
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
					<Input
						{...props}
						id={props.name}
						oninput={() => (cutoffEdited = true)}
					/>
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
						value={pickerValue("contactFromDate", workshop.contactFromDate)}
						onValueChange={setContactFrom}
					/>
					<Field.Description
						>Batch 1 goes out at 10:00 on this date.</Field.Description
					>
					{#each form.fields.contactFromDate.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			{/if}

			<p
				class="flex items-center gap-2 rounded-lg border border-amber-500 bg-amber-50 p-2.5 text-sm text-amber-900"
				role="status"
				data-testid="reschedule-warning"
			>
				<AlertTriangle class="size-4 shrink-0" />
				{warning}
			</p>

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Keep current date</Button
				>
				<Button type="submit" disabled={!!form.pending}
					>{recipients > 0
						? `Reschedule and email ${recipients}`
						: "Reschedule"}</Button
				>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
