<!--
	ALE-378: Schedule one or several Beginners' Workshops in one go. The
	dates share a venue, start time, capacity, fee and payment window; each
	date may override its Payment Cutoff date and contact-from date. Phoenix
	applies every default and rule — this form only collects values.
-->
<script lang="ts">
import { CalendarPlus, Plus, Trash2 } from "@lucide/svelte";
import { parseDate, type DateValue } from "@internationalized/date";
import { toast } from "svelte-sonner";
import { Button } from "#lib/components/ui/button/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import {
	MAX_SCHEDULED_AT_ONCE,
	scheduleWorkshopsSchema,
	VENUE_MAX,
} from "#lib/schemas/beginnersWorkshop.js";
import { scheduleWorkshops } from "./workshops.remote";

let { open = $bindable(false) }: { open?: boolean } = $props();

const form = scheduleWorkshops;
const fields = form.fields;
let dateCount = $state(1);
let formError = $state<string | null>(null);

type DateKey = "date" | "paymentCutoffDate" | "contactFromDate";

function pickerValue(index: number, key: DateKey): DateValue | undefined {
	const value = fields.workshops[index]?.[key].value();
	if (!value) return undefined;
	try {
		return parseDate(value);
	} catch {
		return undefined;
	}
}

function setDate(index: number, key: DateKey, value: DateValue | undefined) {
	if (value) fields.workshops[index]?.[key].set(value.toString());
}

function addDate() {
	if (dateCount < MAX_SCHEDULED_AT_ONCE) dateCount += 1;
}

function removeDate(index: number) {
	const rows = fields.workshops.value() ?? [];
	fields.workshops.set(rows.filter((_, row) => row !== index));
	dateCount = Math.max(1, dateCount - 1);
}

function reset() {
	dateCount = 1;
	formError = null;
}
</script>

<Dialog.Root
	bind:open
	onOpenChange={(next) => {
		if (!next) reset();
	}}
>
	<Dialog.Content class="max-h-[90dvh] overflow-y-auto sm:max-w-2xl">
		<Dialog.Header>
			<Dialog.Title>Schedule Beginners' Workshops</Dialog.Title>
			<Dialog.Description>
				One or several dates at the same venue and time. Nothing is emailed when
				you schedule; Batches go out from the contact-from date.
			</Dialog.Description>
		</Dialog.Header>

		<form
			{...form.preflight(scheduleWorkshopsSchema).enhance(async (instance) => {
				formError = null;
				if (!(await instance.submit())) return;
				const result = instance.result;
				if (result?.ok) {
					toast.success(
						result.data.length === 1
							? "Scheduled 1 Beginners' Workshop"
							: `Scheduled ${result.data.length} Beginners' Workshops`,
					);
					instance.element.reset();
					reset();
					open = false;
				} else if (result) {
					formError = result.error;
				}
			})}
			class="grid gap-5"
			aria-label="Schedule Beginners' Workshops"
		>
			<Field.Group class="grid gap-4 sm:grid-cols-[1fr_8rem]">
				<Field.Field>
					{@const props = fields.venue.as("text")}
					<Field.Label for={props.name}>Venue</Field.Label>
					<Input {...props} id={props.name} maxlength={VENUE_MAX} />
					{#each fields.venue.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = fields.startTime.as("time", "18:30")}
					<Field.Label for={props.name}>Start time</Field.Label>
					<Input {...props} id={props.name} />
					{#each fields.startTime.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			<Field.Group class="grid gap-4 sm:grid-cols-3">
				<Field.Field>
					{@const props = fields.capacity.as("number", 16)}
					<Field.Label for={props.name}>Capacity</Field.Label>
					<Input {...props} id={props.name} min="1" step="1" />
					{#each fields.capacity.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = fields.fee.as("number", 40)}
					<Field.Label for={props.name}>Fee (€)</Field.Label>
					<Input {...props} id={props.name} min="0.01" step="0.01" />
					{#each fields.fee.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = fields.paymentWindowDays.as("number", 7)}
					<Field.Label for={props.name}>Payment window (days)</Field.Label>
					<Input {...props} id={props.name} min="1" step="1" />
					{#each fields.paymentWindowDays.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			<fieldset class="grid gap-3">
				<legend class="mb-2 text-sm font-medium">Dates</legend>
				<p class="text-xs text-muted-foreground">
					Leave the cutoff blank for 3 days before the start, and contact-from
					blank to start contacting from today.
				</p>
				{#each { length: dateCount }, index (index)}
					{@const row = fields.workshops[index]}
					<div
						class="grid items-start gap-3 rounded-lg border p-3 sm:grid-cols-[1fr_1fr_1fr_auto]"
						data-testid="schedule-date-row"
					>
						<Field.Field>
							{@const { value: _date, ...props } = row.date.as("text")}
							<Field.Label for={props.name}>Workshop date</Field.Label>
							<DatePicker
								{...props}
								id={props.name}
								label={`Workshop date ${index + 1}`}
								value={pickerValue(index, "date")}
								onValueChange={(value) => setDate(index, "date", value)}
							/>
							{#each row.date.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
						<Field.Field>
							{@const { value: _cutoff, ...props } =
								row.paymentCutoffDate.as("text")}
							<Field.Label for={props.name}>Payment Cutoff</Field.Label>
							<DatePicker
								{...props}
								id={props.name}
								label={`Payment Cutoff ${index + 1}`}
								value={pickerValue(index, "paymentCutoffDate")}
								onValueChange={(value) =>
									setDate(index, "paymentCutoffDate", value)}
							/>
							{#each row.paymentCutoffDate.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
						<Field.Field>
							{@const { value: _contact, ...props } =
								row.contactFromDate.as("text")}
							<Field.Label for={props.name}>Contact from</Field.Label>
							<DatePicker
								{...props}
								id={props.name}
								label={`Contact from ${index + 1}`}
								value={pickerValue(index, "contactFromDate")}
								onValueChange={(value) =>
									setDate(index, "contactFromDate", value)}
							/>
							{#each row.contactFromDate.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
						<Button
							type="button"
							variant="ghost"
							size="icon"
							class="sm:mt-7"
							aria-label={`Remove date ${index + 1}`}
							disabled={dateCount === 1}
							onclick={() => removeDate(index)}
						>
							<Trash2 />
						</Button>
					</div>
				{/each}
				{#each fields.workshops.issues() as issue (issue.message)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
				<Button
					type="button"
					variant="outline"
					class="justify-self-start"
					disabled={dateCount >= MAX_SCHEDULED_AT_ONCE}
					onclick={addDate}
				>
					<Plus /> Add another date
				</Button>
			</fieldset>

			{#if formError}
				<p class="text-sm text-destructive" role="alert">{formError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="outline" onclick={() => (open = false)}
					>Cancel</Button
				>
				<Button type="submit" disabled={!!form.pending}>
					<CalendarPlus />
					{dateCount === 1
						? "Schedule workshop"
						: `Schedule ${dateCount} workshops`}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
