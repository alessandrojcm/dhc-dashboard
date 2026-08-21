<script lang="ts">
import { fromDate, getLocalTimeZone } from "@internationalized/date";
import dayjs from "dayjs";
import { submitWaitlist } from "./data.remote";
import {
	beginnersWaitlistClientSchema,
	isMinor,
} from "$lib/schemas/beginnersWaitlist";

import { Button } from "$lib/components/ui/button";
import { Input } from "$lib/components/ui/input";
import { Textarea } from "$lib/components/ui/textarea";
import * as Card from "$lib/components/ui/card";
import * as Alert from "$lib/components/ui/alert";
import * as Field from "$lib/components/ui/field";
import * as Select from "$lib/components/ui/select";
import * as RadioGroup from "$lib/components/ui/radio-group";
import { CheckCircled } from "svelte-radix";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import PhoneInput from "$lib/components/ui/phone-input.svelte";
import { SocialMediaConsent } from "$lib/types";
import * as v from "valibot";

let { data } = $props();

const dateOfBirthValue = $derived.by(() => {
	const parsed = v.safeParse(
		v.string(),
		submitWaitlist.fields.dateOfBirth.value(),
	);
	return parsed.success ? parsed.output : "";
});
const isUnderAge = $derived.by(() => {
	if (!dateOfBirthValue) {
		return false;
	}
	const date = new Date(dateOfBirthValue);
	if (!dayjs(date).isValid()) {
		return false;
	}
	return isMinor(date);
});

const dobPickerValue = $derived.by(() => {
	if (!dateOfBirthValue) {
		return undefined;
	}
	const date = new Date(dateOfBirthValue);
	if (!dayjs(date).isValid()) {
		return undefined;
	}
	return fromDate(date, getLocalTimeZone());
});

function isSocialMediaConsent(value: string): value is SocialMediaConsent {
	return Object.values(SocialMediaConsent).some((consent) => consent === value);
}
</script>

{#snippet whyThisField(text: string)}
	<p class="text-muted-foreground text-xs">{text}</p>
{/snippet}

<svelte:head>
	<title>Dublin HEMA Club - Waiting list</title>
</svelte:head>

<Card.Root class="self-center">
	<Card.Header>
		<Card.Title class="prose prose-h1 text-xl"
			>Beginners waiting list</Card.Title
		>
		<Card.Description class="prose">
			Join the waiting list for our next beginners course. We will contact you
			when a place becomes available.
		</Card.Description>
	</Card.Header>
	<Card.Content class="overflow-auto max-h-[85svh]">
		{#if submitWaitlist.result?.success}
			<Alert.Root variant="success">
				<CheckCircled class="h-4 w-4" />
				<Alert.Description>{submitWaitlist.result.success}</Alert.Description>
			</Alert.Root>
		{:else}
			<form
				{...submitWaitlist.preflight(beginnersWaitlistClientSchema)}
				class="flex flex-col gap-4 items-stretch"
			>
				<Field.Group>
					<div class="flex gap-4 w-full justify-stretch">
						<Field.Field class="flex-1">
							{@const fieldProps = submitWaitlist.fields.firstName.as("text")}
							<Field.Label for={fieldProps.name}>First name</Field.Label>
							<Input
								{...fieldProps}
								id={fieldProps.name}
								placeholder="Enter your first name"
							/>
							{#each submitWaitlist.fields.firstName.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>

						<Field.Field class="flex-1">
							{@const fieldProps = submitWaitlist.fields.lastName.as("text")}
							<Field.Label for={fieldProps.name}>Last name</Field.Label>
							<Input
								{...fieldProps}
								id={fieldProps.name}
								placeholder="Enter your last name"
							/>
							{#each submitWaitlist.fields.lastName.issues() as issue (issue.message)}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
					</div>

					<Field.Field>
						{@const fieldProps = submitWaitlist.fields.email.as("email")}
						<Field.Label for={fieldProps.name}>Email</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your email"
						/>
						{#each submitWaitlist.fields.email.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = submitWaitlist.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}>Phone number</Field.Label>
						<PhoneInput
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your phone number"
							onChange={(value) =>
								submitWaitlist.fields.phoneNumber.set(String(value))}
						/>
						{#each submitWaitlist.fields.phoneNumber.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = submitWaitlist.fields.gender.as("select")}
						<Field.Label for={fieldProps.name}>Gender</Field.Label>
						{@render whyThisField(
							"We use this information to understand the makeup of the waiting list",
						)}
						<Select.Root
							type="single"
							value={submitWaitlist.fields.gender.value() ?? ""}
							onValueChange={(v) => submitWaitlist.fields.gender.set(v)}
						>
							<Select.Trigger id={fieldProps.name} aria-label="Gender">
								{#if submitWaitlist.fields.gender.value()}
									<p class="capitalize">
										{submitWaitlist.fields.gender.value()}
									</p>
								{:else}
									Select your gender
								{/if}
							</Select.Trigger>
							<Select.Content>
								{#each data.genders as gender (gender)}
									<Select.Item
										class="capitalize"
										value={gender}
										label={gender}
									/>
								{/each}
							</Select.Content>
						</Select.Root>
						<input
							type="hidden"
							name={fieldProps.name}
							value={submitWaitlist.fields.gender.value() ?? ""}
						/>
						{#each submitWaitlist.fields.gender.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
					<Field.Field>
						{@const fieldProps = submitWaitlist.fields.pronouns.as("text")}
						<Field.Label for={fieldProps.name}>Pronouns</Field.Label>
						{@render whyThisField(
							"We share this with instructors so they know how to address you",
						)}
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your pronouns"
						/>
						<Field.Description
							>Please separate with slashes (e.g. they/them).</Field.Description
						>
						{#each submitWaitlist.fields.pronouns.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const { value, ...fieldProps } =
							submitWaitlist.fields.dateOfBirth.as("text")}
						<Field.Label for={fieldProps.name}>Date of birth</Field.Label>
						{@render whyThisField(
							"For insurance reasons, HEMA practitioners need to be at least 16 years old",
						)}
						<DatePicker
							{...fieldProps}
							id={fieldProps.name}
							label="Date of birth"
							value={dobPickerValue}
							onDateChange={(date) => {
								if (date) {
									submitWaitlist.fields.dateOfBirth.set(date.toISOString());
								}
							}}
						/>
						{#each submitWaitlist.fields.dateOfBirth.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
					<Field.Field>
						{@const fieldProps =
							submitWaitlist.fields.medicalConditions.as("text")}
						<Field.Label for={fieldProps.name}
							>Any medical condition?</Field.Label
						>
						<Textarea
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter any medical conditions"
						/>
						{#each submitWaitlist.fields.medicalConditions.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</Field.Group>

				<Field.Set>
					<span class="flex items-center gap-2">
						<Field.Legend>Social media consent</Field.Legend>
						{@render whyThisField(
							"We sometimes take pictures for our social media",
						)}
					</span>
					<RadioGroup.Root
						name="socialMediaConsent"
						value={submitWaitlist.fields.socialMediaConsent.value()}
						onValueChange={(value) => {
							if (isSocialMediaConsent(value)) {
								submitWaitlist.fields.socialMediaConsent.set(value);
							}
						}}
						class="flex justify-start"
					>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item value="no" id="no" />
							<Field.Label for="no">No</Field.Label>
						</div>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item
								value="yes_unrecognizable"
								id="yes_unrecognizable"
							/>
							<Field.Label for="yes_unrecognizable"
								>If not recognizable (wearing a mask)</Field.Label
							>
						</div>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item value="yes_recognizable" id="yes_recognizable" />
							<Field.Label for="yes_recognizable">Yes</Field.Label>
						</div>
					</RadioGroup.Root>
					{#each submitWaitlist.fields.socialMediaConsent.issues() as issue (issue.message)}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Set>

				{#if isUnderAge}
					<Field.Set
						class="mt-4 p-4 bg-gray-50 rounded-md border border-gray-200"
					>
						<Field.Legend
							>Guardian Information (Required for under 18)</Field.Legend
						>
						<Field.Group>
							<div class="flex gap-4 w-full justify-stretch">
								<Field.Field class="flex-1">
									{@const fieldProps =
										submitWaitlist.fields.guardianFirstName.as("text")}
									<Field.Label for={fieldProps.name}
										>Guardian First Name</Field.Label
									>
									<Input
										{...fieldProps}
										id={fieldProps.name}
										placeholder="Enter guardian's first name"
									/>
									{#each submitWaitlist.fields.guardianFirstName.issues() as issue (issue.message)}
										<Field.Error>{issue.message}</Field.Error>
									{/each}
								</Field.Field>

								<Field.Field class="flex-1">
									{@const fieldProps =
										submitWaitlist.fields.guardianLastName.as("text")}
									<Field.Label for={fieldProps.name}
										>Guardian Last Name</Field.Label
									>
									<Input
										{...fieldProps}
										id={fieldProps.name}
										placeholder="Enter guardian's last name"
									/>
									{#each submitWaitlist.fields.guardianLastName.issues() as issue (issue.message)}
										<Field.Error>{issue.message}</Field.Error>
									{/each}
								</Field.Field>
							</div>

							<Field.Field>
								{@const fieldProps =
									submitWaitlist.fields.guardianPhoneNumber.as("tel")}
								<Field.Label for={fieldProps.name}
									>Guardian Phone Number</Field.Label
								>
								<PhoneInput
									{...fieldProps}
									id={fieldProps.name}
									placeholder="Enter guardian's phone number"
									onChange={(value) =>
										submitWaitlist.fields.guardianPhoneNumber.set(
											String(value),
										)}
								/>
								{#each submitWaitlist.fields.guardianPhoneNumber.issues() as issue (issue.message)}
									<Field.Error>{issue.message}</Field.Error>
								{/each}
							</Field.Field>
						</Field.Group>
					</Field.Set>
				{/if}

				<Button type="submit">Submit</Button>
			</form>
		{/if}
	</Card.Content>
</Card.Root>
