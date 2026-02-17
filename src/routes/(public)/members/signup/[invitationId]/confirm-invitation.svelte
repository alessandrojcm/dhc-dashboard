<script lang="ts">
	import * as Field from "$lib/components/ui/field";
	import { Input } from "$lib/components/ui/input";
	import { Button } from "$lib/components/ui/button";
	import { ArrowRightIcon } from "lucide-svelte";
	import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
	import { toast } from "svelte-sonner";
	import { page } from "$app/state";
	import * as Alert from "$lib/components/ui/alert";
	import { goto } from "$app/navigation";
	import { resolve } from "$app/paths";
	import dayjs from "dayjs";
	import { fromDate, getLocalTimeZone } from "@internationalized/date";
	import DatePicker from "$lib/components/ui/date-picker.svelte";
	import { validateInvitation } from "./data.remote";
	import { inviteValidationSchema } from "$lib/schemas/inviteValidationSchema";
	import { initForm } from "$lib/utils/init-form.svelte";

	const invitationId = $derived(page.params.invitationId);

	let { isVerified = $bindable(false) } = $props();
	initForm(validateInvitation, () => {
		return {
			email: page.url.searchParams.get("email") || "",
			dateOfBirth: page.url.searchParams.get("dateOfBirth") || "",
		};
	});
	// Date picker value
	const dobValue = $derived.by(() => {
		const dob = validateInvitation.fields.dateOfBirth.value();
		if (!dob || !dayjs(dob).isValid() || dayjs(dob).isSame(dayjs())) {
			return undefined;
		}
		return fromDate(dayjs(dob).toDate(), getLocalTimeZone());
	});
</script>

{#if isVerified}
	<div class="space-y-6">
		<Alert.Root variant="success" class="w-full mb-6">
			<Alert.Title>Invitation Verified!</Alert.Title>
			<Alert.Description>
				Your invitation has been successfully verified. Please complete
				your membership signup below.
			</Alert.Description>
		</Alert.Root>
	</div>
{:else}
	<div class="max-w-md mx-auto p-6">
		<h4 class="font-bold mb-6">Verify Your Invitation</h4>
		<p class="mb-6 text-gray-600">
			Please enter your email and date of birth to verify your invitation.
		</p>

		<form
			{...validateInvitation
				.preflight(inviteValidationSchema)
				.enhance(({ submit }) => {
					submit().then(() => {
						if (validateInvitation.result?.success) {
							isVerified = true;
							goto(resolve(`/members/signup/${invitationId}`), {
								replaceState: true,
							});
						}
					});
				})}
			class="space-y-6"
		>
			<Field.Group>
				<Field.Field>
					{@const fieldProps =
						validateInvitation.fields.email.as("email")}
					<Field.Label for={fieldProps.name}>Email</Field.Label>
					<Input
						{...fieldProps}
						id={fieldProps.name}
						placeholder="Enter your email address"
					/>
					{#each validateInvitation.fields.email.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>

				<Field.Field>
					{@const { value, ...fieldProps } =
						validateInvitation.fields.dateOfBirth.as("text")}
					<Field.Label for={fieldProps.name}
						>Date of birth</Field.Label
					>
					<DatePicker
						{...fieldProps}
						id={fieldProps.name}
						value={dobValue}
						onDateChange={(date) => {
							if (!date) return;
							validateInvitation.fields.dateOfBirth.set(
								dayjs(date).format("YYYY-MM-DD"),
							);
						}}
					/>
					{#each validateInvitation.fields.dateOfBirth.issues() as issue}
						<Field.Error>{issue.message}</Field.Error>
					{/each}
				</Field.Field>
			</Field.Group>

			<Button
				type="submit"
				class="w-full"
				disabled={!!validateInvitation.pending}
			>
				{#if validateInvitation.pending}
					<LoaderCircle />
				{:else}
					Verify Invitation
					<ArrowRightIcon class="ml-2 h-4 w-4" />
				{/if}
			</Button>
		</form>
	</div>
{/if}
