<script lang="ts">
<<<<<<< HEAD
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

let { data } = $props();

const dateOfBirthValue = $derived(
	submitWaitlist.fields.dateOfBirth.value() as string,
);
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
=======
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

	let { data } = $props();

	const dateOfBirthValue = $derived(
		submitWaitlist.fields.dateOfBirth.value() as string,
	);
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
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

{#snippet whyThisField(text: string)}
	<p class="text-muted-foreground text-xs">{text}</p>
{/snippet}

<svelte:head>
	<title>Dublin Hema Club - Waitlist Registration</title>
</svelte:head>

<Card.Root class="self-center">
	<Card.Header>
		<Card.Title class="prose prose-h1 text-xl">Waitlist Form</Card.Title>
		<Card.Description class="prose">
			Thanks for your interest in Dublin Hema Club! Please sign up for our
			waitlist, we will contact you once a spot for our beginners workshop
			opens
		</Card.Description>
	</Card.Header>
	<Card.Content class="overflow-auto max-h-[85svh]">
		{#if submitWaitlist.result?.success}
			<Alert.Root variant="success">
				<CheckCircled class="h-4 w-4" />
				<Alert.Description
					>{submitWaitlist.result.success}</Alert.Description
				>
			</Alert.Root>
		{:else}
			<form
				{...submitWaitlist.preflight(beginnersWaitlistClientSchema)}
				class="flex flex-col gap-4 items-stretch"
			>
				<Field.Group>
					<div class="flex gap-4 w-full justify-stretch">
						<Field.Field class="flex-1">
<<<<<<< HEAD
							{@const fieldProps =
								submitWaitlist.fields.firstName.as("text")}
							<Field.Label for={fieldProps.name}
								>First name</Field.Label
							>
=======
							{@const fieldProps = submitWaitlist.fields.firstName.as("text")}
							<Field.Label for={fieldProps.name}>First name</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
							<Input
								{...fieldProps}
								id={fieldProps.name}
								placeholder="Enter your first name"
							/>
							{#each submitWaitlist.fields.firstName.issues() as issue}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>

						<Field.Field class="flex-1">
<<<<<<< HEAD
							{@const fieldProps =
								submitWaitlist.fields.lastName.as("text")}
							<Field.Label for={fieldProps.name}
								>Last name</Field.Label
							>
=======
							{@const fieldProps = submitWaitlist.fields.lastName.as("text")}
							<Field.Label for={fieldProps.name}>Last name</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
							<Input
								{...fieldProps}
								id={fieldProps.name}
								placeholder="Enter your last name"
							/>
							{#each submitWaitlist.fields.lastName.issues() as issue}
								<Field.Error>{issue.message}</Field.Error>
							{/each}
						</Field.Field>
					</div>

					<Field.Field>
<<<<<<< HEAD
						{@const fieldProps =
							submitWaitlist.fields.email.as("email")}
=======
						{@const fieldProps = submitWaitlist.fields.email.as("email")}
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						<Field.Label for={fieldProps.name}>Email</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your email"
						/>
						{#each submitWaitlist.fields.email.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
<<<<<<< HEAD
						{@const fieldProps =
							submitWaitlist.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Phone number</Field.Label
						>
=======
						{@const fieldProps = submitWaitlist.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}>Phone number</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						<PhoneInput
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your phone number"
<<<<<<< HEAD
							onChange={(value) =>
								submitWaitlist.fields.phoneNumber.set(
									String(value),
								)}
=======
							onChange={(value) => submitWaitlist.fields.phoneNumber.set(String(value))}
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						/>
						{#each submitWaitlist.fields.phoneNumber.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
<<<<<<< HEAD
						{@const fieldProps =
							submitWaitlist.fields.gender.as("select")}
=======
						{@const fieldProps = submitWaitlist.fields.gender.as("select")}
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						<Field.Label for={fieldProps.name}>Gender</Field.Label>
						{@render whyThisField(
							"This helps us maintain a balanced and inclusive training environment",
						)}
						<Select.Root
							type="single"
							value={submitWaitlist.fields.gender.value() as string}
<<<<<<< HEAD
							onValueChange={(v) =>
								submitWaitlist.fields.gender.set(v)}
						>
							<Select.Trigger id={fieldProps.name}>
								{#if submitWaitlist.fields.gender.value()}
									<p class="capitalize">
										{submitWaitlist.fields.gender.value()}
									</p>
=======
							onValueChange={(v) => submitWaitlist.fields.gender.set(v)}
						>
							<Select.Trigger id={fieldProps.name}>
								{#if submitWaitlist.fields.gender.value()}
									<p class="capitalize">{submitWaitlist.fields.gender.value()}</p>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
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
						{#each submitWaitlist.fields.gender.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
					<Field.Field>
<<<<<<< HEAD
						{@const fieldProps =
							submitWaitlist.fields.pronouns.as("text")}
						<Field.Label for={fieldProps.name}>Pronouns</Field.Label
						>
=======
						{@const fieldProps = submitWaitlist.fields.pronouns.as("text")}
						<Field.Label for={fieldProps.name}>Pronouns</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						{@render whyThisField(
							"This helps us maintain a balanced and inclusive training environment",
						)}
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your pronouns"
						/>
<<<<<<< HEAD
						<Field.Description
							>Please separate with slashes (e.g. they/them).</Field.Description
						>
=======
						<Field.Description>Please separate with slashes (e.g. they/them).</Field.Description>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						{#each submitWaitlist.fields.pronouns.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
<<<<<<< HEAD
						{@const { value, ...fieldProps } =
							submitWaitlist.fields.dateOfBirth.as("date")}
						<Field.Label for={fieldProps.name}
							>Date of birth</Field.Label
						>
=======
						{@const { value, ...fieldProps } = submitWaitlist.fields.dateOfBirth.as("date")}
						<Field.Label for={fieldProps.name}>Date of birth</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						{@render whyThisField(
							"For insurance reasons, HEMA practitioners need to be at least 16 years old",
						)}
						<DatePicker
							{...fieldProps}
							id={fieldProps.name}
							value={dobPickerValue}
							onDateChange={(date) => {
								if (date) {
<<<<<<< HEAD
									submitWaitlist.fields.dateOfBirth.set(
										date.toISOString(),
									);
=======
									submitWaitlist.fields.dateOfBirth.set(date.toISOString());
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
								}
							}}
						/>
						{#each submitWaitlist.fields.dateOfBirth.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
					<Field.Field>
<<<<<<< HEAD
						{@const fieldProps =
							submitWaitlist.fields.medicalConditions.as("text")}
						<Field.Label for={fieldProps.name}
							>Any medical condition?</Field.Label
						>
=======
						{@const fieldProps = submitWaitlist.fields.medicalConditions.as("text")}
						<Field.Label for={fieldProps.name}>Any medical condition?</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						<Textarea
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter any medical conditions"
						/>
						{#each submitWaitlist.fields.medicalConditions.issues() as issue}
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
<<<<<<< HEAD
						value={submitWaitlist.fields.socialMediaConsent.value() as SocialMediaConsent}
						onValueChange={(v) =>
							submitWaitlist.fields.socialMediaConsent.set(
								v as SocialMediaConsent,
							)}
						class="flex justify-start"
					>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item
								{...submitWaitlist.fields.socialMediaConsent.as(
									"button",
								)}
								value={submitWaitlist.fields.socialMediaConsent
									.as("button")
									.toString()}
								id={"no"}
							/>
							<Field.Label for="no">No</Field.Label>
						</div>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item
								{...submitWaitlist.fields.socialMediaConsent.as(
									"button",
								)}
								value={submitWaitlist.fields.socialMediaConsent
									.as("button")
									.toString()}
								id={"yes_unrecognizable"}
							/>
=======
						value={submitWaitlist.fields.socialMediaConsent.value() as
							| string
							| undefined}
						onValueChange={(v) =>
							submitWaitlist.fields.socialMediaConsent.set(v)}
						class="flex justify-start"
					>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item value="no" id="no" />
							<Field.Label for="no">No</Field.Label>
						</div>
						<div class="flex items-center space-x-3">
							<RadioGroup.Item id="yes_unrecognizable" value="yes_unrecognizable" />
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
							<Field.Label for="yes_unrecognizable"
								>If not recognizable (wearing a mask)</Field.Label
							>
						</div>
						<div class="flex items-center space-x-3">
<<<<<<< HEAD
							<RadioGroup.Item
								{...submitWaitlist.fields.socialMediaConsent.as(
									"button",
								)}
								value={submitWaitlist.fields.socialMediaConsent
									.as("button")
									.toString()}
								id={"yes_recognizable"}
							/>
							<Field.Label for="yes_recognizable">Yes</Field.Label
							>
=======
							<RadioGroup.Item id="yes_recognizable" value="yes_recognizable" />
							<Field.Label for="yes_recognizable">Yes</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
						</div>
					</RadioGroup.Root>
					{#each submitWaitlist.fields.socialMediaConsent.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Set>

				{#if isUnderAge}
<<<<<<< HEAD
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
										submitWaitlist.fields.guardianFirstName.as(
											"text",
										)}
									<Field.Label for={fieldProps.name}
										>Guardian First Name</Field.Label
									>
=======
					<Field.Set class="mt-4 p-4 bg-gray-50 rounded-md border border-gray-200">
						<Field.Legend>Guardian Information (Required for under 18)</Field.Legend>
						<Field.Group>
							<div class="flex gap-4 w-full justify-stretch">
								<Field.Field class="flex-1">
									{@const fieldProps = submitWaitlist.fields.guardianFirstName.as("text")}
									<Field.Label for={fieldProps.name}>Guardian First Name</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
									<Input
										{...fieldProps}
										id={fieldProps.name}
										placeholder="Enter guardian's first name"
									/>
									{#each submitWaitlist.fields.guardianFirstName.issues() as issue}
<<<<<<< HEAD
										<Field.Error
											>{issue.message}</Field.Error
										>
=======
										<Field.Error>{issue.message}</Field.Error>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
									{/each}
								</Field.Field>

								<Field.Field class="flex-1">
<<<<<<< HEAD
									{@const fieldProps =
										submitWaitlist.fields.guardianLastName.as(
											"text",
										)}
									<Field.Label for={fieldProps.name}
										>Guardian Last Name</Field.Label
									>
=======
									{@const fieldProps = submitWaitlist.fields.guardianLastName.as("text")}
									<Field.Label for={fieldProps.name}>Guardian Last Name</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
									<Input
										{...fieldProps}
										id={fieldProps.name}
										placeholder="Enter guardian's last name"
									/>
									{#each submitWaitlist.fields.guardianLastName.issues() as issue}
<<<<<<< HEAD
										<Field.Error
											>{issue.message}</Field.Error
										>
=======
										<Field.Error>{issue.message}</Field.Error>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
									{/each}
								</Field.Field>
							</div>

							<Field.Field>
<<<<<<< HEAD
								{@const fieldProps =
									submitWaitlist.fields.guardianPhoneNumber.as(
										"tel",
									)}
								<Field.Label for={fieldProps.name}
									>Guardian Phone Number</Field.Label
								>
=======
								{@const fieldProps = submitWaitlist.fields.guardianPhoneNumber.as("tel")}
								<Field.Label for={fieldProps.name}>Guardian Phone Number</Field.Label>
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
								<PhoneInput
									{...fieldProps}
									id={fieldProps.name}
									placeholder="Enter guardian's phone number"
									onChange={(value) =>
<<<<<<< HEAD
										submitWaitlist.fields.guardianPhoneNumber.set(
											String(value),
										)}
=======
										submitWaitlist.fields.guardianPhoneNumber.set(String(value))}
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
								/>
								{#each submitWaitlist.fields.guardianPhoneNumber.issues() as issue}
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
