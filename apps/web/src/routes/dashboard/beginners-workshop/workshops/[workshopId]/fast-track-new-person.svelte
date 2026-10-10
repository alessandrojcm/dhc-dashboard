<!--
	ALE-384: "Not on the Waitlist? Add them" inside the Fast-track dialog. The
	public registration form, sent through the staff "add a new person" path
	(works while registration is closed; priority = today), then the same
	Fast-track in one Phoenix transaction. A refused email (already on the
	Waitlist, a Member's, or with a pending Invitation) shows under Email.
-->
<script lang="ts">
import { CalendarDate, type DateValue } from "@internationalized/date";
import dayjs from "dayjs";
import * as v from "valibot";
import { Button } from "#lib/components/ui/button/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import * as Field from "#lib/components/ui/field/index.js";
import { Input } from "#lib/components/ui/input/index.js";
import * as NativeSelect from "#lib/components/ui/native-select/index.js";
import PhoneInput from "#lib/components/ui/phone-input.svelte";
import { Textarea } from "#lib/components/ui/textarea/index.js";
import { isMinor } from "#lib/schemas/beginnersWaitlist.js";
import { fastTrackNewPersonSchema } from "#lib/schemas/beginnersWorkshop.js";
import { fastTrackNewPerson } from "./console.remote";

let {
	workshopId,
	genders,
	onBack,
	onDone,
}: {
	workshopId: string;
	genders: string[];
	onBack: () => void;
	onDone: (firstName: string) => void;
} = $props();

const form = $derived(fastTrackNewPerson.for(workshopId));
let formError = $state<string | null>(null);

const dateOfBirthValue = $derived.by(() => {
	const parsed = v.safeParse(v.string(), form.fields.dateOfBirth.value());
	return parsed.success ? parsed.output : "";
});
// A bare ISO date parses as local midnight, so the civil day never shifts.
const dateOfBirthDay = $derived(
	dateOfBirthValue ? dayjs(dateOfBirthValue) : undefined,
);
const minor = $derived(
	dateOfBirthDay?.isValid() ? isMinor(dateOfBirthValue) : false,
);
const dobPickerValue = $derived(
	dateOfBirthDay?.isValid()
		? new CalendarDate(
				dateOfBirthDay.year(),
				dateOfBirthDay.month() + 1,
				dateOfBirthDay.date(),
			)
		: undefined,
);

function setDateOfBirth(date: DateValue | undefined) {
	if (date instanceof CalendarDate)
		form.fields.dateOfBirth.set(date.toString());
}
</script>

<form
	{...form.preflight(fastTrackNewPersonSchema).enhance(async (instance) => {
		formError = null;
		const firstName = String(form.fields.firstName.value() ?? "");
		if (!(await instance.submit())) return;
		const result = instance.result;
		if (result?.ok) onDone(firstName);
		else if (result) formError = result.error;
	})}
	class="grid gap-4"
	aria-label="Add a new person"
>
	<input {...form.fields.id.as("hidden", workshopId)} />
	<p class="text-xs text-muted-foreground">
		Staff-only registration: works even when the public Waitlist is closed.
		Their place in the queue is today.
	</p>

	<div class="grid gap-4 sm:grid-cols-2">
		<Field.Field>
			{@const props = form.fields.firstName.as("text")}
			<Field.Label for="ft-first-name">First name</Field.Label>
			<Input {...props} id="ft-first-name" />
			{#each form.fields.firstName.issues() ?? [] as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
		<Field.Field>
			{@const props = form.fields.lastName.as("text")}
			<Field.Label for="ft-last-name">Last name</Field.Label>
			<Input {...props} id="ft-last-name" />
			{#each form.fields.lastName.issues() ?? [] as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
	</div>

	<Field.Field>
		{@const props = form.fields.email.as("email")}
		<Field.Label for="ft-email">Email</Field.Label>
		<Input {...props} id="ft-email" />
		{#each form.fields.email.issues() ?? [] as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	<Field.Field>
		{@const props = form.fields.phoneNumber.as("tel")}
		<Field.Label for="ft-phone">Phone number</Field.Label>
		<PhoneInput
			{...props}
			id="ft-phone"
			onChange={(value) => form.fields.phoneNumber.set(String(value))}
		/>
		{#each form.fields.phoneNumber.issues() ?? [] as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	<div class="grid gap-4 sm:grid-cols-2">
		<Field.Field>
			{@const props = form.fields.gender.as("select")}
			<Field.Label for="ft-gender">Gender</Field.Label>
			<NativeSelect.Root {...props} id="ft-gender">
				<NativeSelect.Option value="">Select a gender</NativeSelect.Option>
				{#each genders as gender (gender)}
					<NativeSelect.Option value={gender}>{gender}</NativeSelect.Option>
				{/each}
			</NativeSelect.Root>
			{#each form.fields.gender.issues() ?? [] as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
		<Field.Field>
			{@const props = form.fields.pronouns.as("text")}
			<Field.Label for="ft-pronouns">Pronouns (optional)</Field.Label>
			<Input {...props} id="ft-pronouns" placeholder="they/them" />
			{#each form.fields.pronouns.issues() ?? [] as issue (issue.message)}
				<Field.Error>{issue.message}</Field.Error>
			{/each}
		</Field.Field>
	</div>

	<Field.Field>
		{@const { value: _value, ...props } = form.fields.dateOfBirth.as("text")}
		<Field.Label for="ft-dob">Date of birth</Field.Label>
		<DatePicker
			{...props}
			id="ft-dob"
			label="Date of birth"
			value={dobPickerValue}
			onValueChange={setDateOfBirth}
		/>
		{#each form.fields.dateOfBirth.issues() ?? [] as issue (issue.message)}
			<Field.Error>{issue.message}</Field.Error>
		{/each}
	</Field.Field>

	<Field.Field>
		{@const props = form.fields.medicalConditions.as("text")}
		<Field.Label for="ft-medical">Any medical condition?</Field.Label>
		<Textarea {...props} id="ft-medical" rows={2} />
	</Field.Field>

	{#if minor}
		<Field.Set class="rounded-md border p-4">
			<Field.Legend>Guardian (required for under 18s)</Field.Legend>
			<div class="grid gap-4 sm:grid-cols-2">
				<Field.Field>
					{@const props = form.fields.guardianFirstName.as("text")}
					<Field.Label for="ft-guardian-first">Guardian first name</Field.Label>
					<Input {...props} id="ft-guardian-first" />
					{#each form.fields.guardianFirstName.issues() ?? [] as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
				<Field.Field>
					{@const props = form.fields.guardianLastName.as("text")}
					<Field.Label for="ft-guardian-last">Guardian last name</Field.Label>
					<Input {...props} id="ft-guardian-last" />
					{#each form.fields.guardianLastName.issues() ?? [] as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</div>
			<Field.Field>
				{@const props = form.fields.guardianPhoneNumber.as("tel")}
				<Field.Label for="ft-guardian-phone">Guardian phone number</Field.Label>
				<PhoneInput
					{...props}
					id="ft-guardian-phone"
					onChange={(value) =>
						form.fields.guardianPhoneNumber.set(String(value))}
				/>
				{#each form.fields.guardianPhoneNumber.issues() ?? [] as issue (issue.message)}
					<Field.Error>{issue.message}</Field.Error>
				{/each}
			</Field.Field>
		</Field.Set>
	{/if}

	{#if formError}
		<p class="text-sm text-destructive" role="alert">{formError}</p>
	{/if}

	<Dialog.Footer>
		<Button type="button" variant="outline" onclick={onBack}>Back</Button>
		<Button type="submit" disabled={!!form.pending}>Add and fast-track</Button>
	</Dialog.Footer>
</form>
