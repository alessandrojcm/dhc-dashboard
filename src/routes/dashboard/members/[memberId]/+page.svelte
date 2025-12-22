<script lang="ts">
	import { page } from "$app/state";
	import { Button } from "$lib/components/ui/button";
	import * as Card from "$lib/components/ui/card";
	import dayjs from "dayjs";
	import DatePicker from "$lib/components/ui/date-picker.svelte";
	import * as Field from "$lib/components/ui/field";
	import { Input } from "$lib/components/ui/input";
	import PhoneInput from "$lib/components/ui/phone-input.svelte";
	import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
	import * as RadioGroup from "$lib/components/ui/radio-group/index.js";
	import * as Select from "$lib/components/ui/select";
	import { Textarea } from "$lib/components/ui/textarea";
	import { fromDate, getLocalTimeZone } from "@internationalized/date";
	import { createMutation } from "@tanstack/svelte-query";
	import { ExternalLink } from "lucide-svelte";
	import { toast } from "svelte-sonner";
	import { Badge } from "$lib/components/ui/badge";
	import PauseSubscriptionModal from "$lib/components/ui/pause-subscription-modal.svelte";
	import type Stripe from "stripe";
	import * as ButtonGroup from "$lib/components/ui/button-group";
	import { updateProfile } from "./data.remote";
	import { Label } from "$lib/components/ui/label";
	import { initForm } from "$lib/utils/init-form.svelte";
	import { whyThisField } from "$lib/components/ui/why-this-field.svelte";
    import FormDebug from "$lib/components/form-debug.svelte";
    import { memberProfileClientSchema } from "$lib/schemas/membersSignup";

	const { data } = $props();

	initForm(updateProfile, () => ({
		firstName: data.profileData.firstName ?? "",
		lastName: data.profileData.lastName ?? "",
		email: data.profileData.email ?? "",
		phoneNumber: data.profileData.phoneNumber ?? "",
		dateOfBirth: data.profileData.dateOfBirth ?? "",
		pronouns: data.profileData.pronouns ?? "",
		gender: data.profileData.gender ?? "",
		medicalConditions: data.profileData.medicalConditions ?? "",
		nextOfKin: data.profileData.nextOfKin ?? "",
		nextOfKinNumber: data.profileData.nextOfKinNumber ?? "",
		weapon: data.profileData.weapon ?? [],
		insuranceFormSubmitted:
			data.profileData.insuranceFormSubmitted ?? false,
		socialMediaConsent: data.profileData.socialMediaConsent,
	}));

	// Handle success/error from form submission
	$effect(() => {
		const result = updateProfile.result;
		if (result?.success) {
			toast.success(result.success, { position: "top-right" });
		} else if(result?.error){
			toast.error(result.error, { position: "top-right" });
		}
	});

	// Reactive form field values
	const dateOfBirth = $derived(
		updateProfile.fields.dateOfBirth.value() ?? "",
	);
	const gender = $derived(updateProfile.fields.gender.value() ?? "");
	const weapon = $derived(updateProfile.fields.weapon.value() ?? []);
	const socialMediaConsent = $derived(
		updateProfile.fields.socialMediaConsent.value(),
	);

	// Date picker value conversion
	const dobValue = $derived.by(() => {
		if (!dateOfBirth || !dayjs(dateOfBirth).isValid()) {
			return undefined;
		}
		return fromDate(dayjs(dateOfBirth).toDate(), getLocalTimeZone());
	});

	let pausedUntil: dayjs.Dayjs | null = $derived(
		data.member.subscription_paused_until
			? dayjs(data.member.subscription_paused_until)
			: null,
	);

	const openBillingPortal = createMutation(() => ({
		mutationFn: () =>
			fetch(`/dashboard/members/${page.params.memberId}`, {
				method: "POST",
			}).then((res) => res.json()) as Promise<{ portalURL: string }>,
		onSuccess: (portalData: { portalURL: string }) => {
			window.open(portalData.portalURL, "_blank");
		},
	}));

	let showPauseModal = $state(false);

	const pauseMutation = createMutation(() => ({
		mutationFn: async (pauseData: { pauseUntil: string }) => {
			const response = await fetch(
				`/api/members/${page.params.memberId}/subscription/pause`,
				{
					method: "POST",
					headers: { "Content-Type": "application/json" },
					body: JSON.stringify(pauseData),
				},
			);

			const responseData: {
				subscription: Stripe.Response<Stripe.Subscription>;
				error?: string;
			} = await response.json();

			if (!response.ok) {
				throw new Error(
					responseData?.error ||
						`HTTP error! status: ${response.status}`,
				);
			}
			return responseData as {
				subscription: Stripe.Response<Stripe.Subscription>;
			};
		},
		onSuccess: ({
			subscription,
		}: {
			subscription: Stripe.Response<Stripe.Subscription>;
		}) => {
			showPauseModal = false;
			pausedUntil = dayjs.unix(
				subscription.pause_collection!.resumes_at!,
			);
		},
		onError: (error) => {
			toast.error(`Failed to pause subscription: ${error.message}`);
		},
	}));

	const resumeMutation = createMutation(() => ({
		mutationFn: () =>
			fetch(`/api/members/${page.params.memberId}/subscription/pause`, {
				method: "DELETE",
			})
				.then((r) => {
					if (!r.ok) {
						throw new Error(`HTTP error! status: ${r.status}`);
					}
					return r;
				})
				.then((r) => r.json()),
		onSuccess: () => {
			pausedUntil = null;
		},
		onError: (error) => {
			toast.error(`Failed to resume subscription: ${error.message}`);
		},
	}));
</script>

<Card.Root class="w-full max-w-4xl mx-auto">
	<Card.Header>
		<Card.Title>Member Information</Card.Title>
		<Card.Description
			>View and edit your membership details</Card.Description
		>
	</Card.Header>
	<Card.Content class="min-h-96 max-h-[73dvh] overflow-y-auto">
		<form {...updateProfile.preflight(memberProfileClientSchema)} class="space-y-8">
			<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
				<div class="space-y-6">
					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.firstName.as("text")}
						<Field.Label for={fieldProps.name}
							>First name</Field.Label
						>
						<Input {...fieldProps} id={fieldProps.name} />
						{#each updateProfile.fields.firstName.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.lastName.as("text")}
						<Field.Label for={fieldProps.name}
							>Last name</Field.Label
						>
						<Input {...fieldProps} id={fieldProps.name} />
						{#each updateProfile.fields.lastName.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.email.as("email")}
						<Field.Label for={fieldProps.name}>Email</Field.Label>
						<Input
							class="cursor-not-allowed bg-gray-300/50"
							readonly
							{...fieldProps}
							id={fieldProps.name}
						/>
						<Field.Description>
							Please contact us if you need to change your email.
						</Field.Description>
						{#each updateProfile.fields.email.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Phone Number</Field.Label
						>
						<PhoneInput
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your phone number"
						/>
						{#each updateProfile.fields.phoneNumber.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						<Field.Label>Date of Birth</Field.Label>
						{@render whyThisField(
							"For insurance reasons, HEMA practitioners need to be at least 16 years old",
						)}
						<DatePicker
							value={dobValue}
							onDateChange={(date) => {
								if (!date) return;
								updateProfile.fields.dateOfBirth.set(
									dayjs(date).format("YYYY-MM-DD"),
								);
							}}
						/>
						<input
							type="hidden"
							name="dateOfBirth"
							value={dateOfBirth}
						/>
						{#each updateProfile.fields.dateOfBirth.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					{#if data.canUpdate}
						<Button
							disabled={openBillingPortal.isPending}
							variant="outline"
							type="button"
							onclick={() => openBillingPortal.mutate()}
							class="w-full"
						>
							{#if openBillingPortal.isPending}
								<LoaderCircle class="ml-2 h-4 w-4" />
							{/if}
							Manage payment settings
							<ExternalLink class="ml-2 h-4 w-4" />
						</Button>

						<div class="space-y-4 grid-cols-2 grid-rows-2">
							<div class="flex items-center justify-between">
								<span class="text-sm font-medium"
									>Subscription Status:</span
								>
								{#if pausedUntil?.isAfter(dayjs())}
									<Badge variant="secondary">
										Paused until {pausedUntil.format(
											"MMM D, YYYY",
										)}
									</Badge>
								{:else}
									<Badge variant="default">Active</Badge>
								{/if}
							</div>

							{#if pausedUntil?.isAfter(dayjs())}
								<ButtonGroup.Root>
									<Button
										variant="default"
										onclick={() => (showPauseModal = true)}
										disabled={resumeMutation.isPending}
										type="button"
										class="w-full"
									>
										Extend pause
									</Button>
									<Button
										variant="outline"
										onclick={() => resumeMutation.mutate()}
										disabled={resumeMutation.isPending}
										type="button"
										class="w-full"
									>
										{resumeMutation.isPending
											? "Resuming..."
											: "Resume Subscription"}
									</Button>
								</ButtonGroup.Root>
							{:else}
								<Button
									variant="outline"
									onclick={() => (showPauseModal = true)}
									type="button"
									class="w-full"
								>
									Pause Subscription
								</Button>
							{/if}
						</div>
					{/if}
				</div>

				<div class="space-y-6">
					<Field.Field>
						<Field.Label>Gender</Field.Label>
						{@render whyThisField(
							"This helps us maintain a balanced and inclusive training environment",
						)}
						<Select.Root
							type="single"
							value={gender}
							onValueChange={(v) =>
								updateProfile.fields.gender.set(v)}
							name="gender"
						>
							{#await data.genders}
								<Select.Trigger class="w-full capitalize">
									{gender || "Select your gender"}
								</Select.Trigger>
							{:then genders}
								<Select.Trigger class="w-full capitalize">
									{gender || "Select your gender"}
								</Select.Trigger>
								<Select.Content>
									{#each genders as g (g)}
										<Select.Item
											value={g}
											class="capitalize">{g}</Select.Item
										>
									{/each}
								</Select.Content>
							{/await}
						</Select.Root>
						{#each updateProfile.fields.gender.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.pronouns.as("text")}
						<Field.Label for={fieldProps.name}>Pronouns</Field.Label
						>
						{@render whyThisField(
							"This helps us maintain a balanced and inclusive training environment",
						)}
						<Input
							class="capitalize"
							{...fieldProps}
							id={fieldProps.name}
							placeholder="e.g. she/her, they/them"
						/>
						{#each updateProfile.fields.pronouns.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.weapon.as("select multiple")}
						<Field.Label for={fieldProps.name}
							>Preferred Weapon</Field.Label
						>
						<Select.Root
							type="multiple"
							value={weapon}
							onValueChange={(v) =>
								updateProfile.fields.weapon.set(v)}
						>
							{#await data.weapons}
								<Select.Trigger class="capitalize">
									{weapon?.length > 0
										? weapon.join(", ")
										: "Select your preferred weapon(s)"}
								</Select.Trigger>
							{:then weapons}
								<Select.Trigger
									id={fieldProps.name}
									name={fieldProps.name}
									class="capitalize"
								>
									{weapon
										? weapon
												.join(", ")
												.replace(/[_-]/g, " ")
										: "Select your preferred weapon(s)"}
								</Select.Trigger>
								<Select.Content>
									{#each weapons as w (w)}
										<Select.Item
											class="capitalize"
											value={w}
											>{w.replace(
												/[_-]/g,
												" ",
											)}</Select.Item
										>
									{/each}
								</Select.Content>
							{/await}
						</Select.Root>
						<Field.Description
							>You can select more than one</Field.Description
						>
						{#each updateProfile.fields.weapon.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
						<input
							type="hidden"
							name={fieldProps.name}
							value={weapon.join(", ")}
						/>
					</Field.Field>

					<Field.Field>
						<Label class="text-sm font-medium"
							>Social media consent</Label
						>
						<Field.Description>
							We sometimes take pictures for our social media,
							please indicate if you are comfortable with this
						</Field.Description>
						<RadioGroup.Root
							name="socialMediaConsent"
							class="flex justify-start"
							value={socialMediaConsent}
							onValueChange={(v) =>
								updateProfile.fields.socialMediaConsent.set(
									v as typeof socialMediaConsent,
								)}
						>
							<div class="flex items-center space-x-3 space-y-0">
								<RadioGroup.Item value="no" id="consent-no" />
								<Label for="consent-no" class="font-normal"
									>No</Label
								>
							</div>
							<div class="flex items-center space-x-3 space-y-0">
								<RadioGroup.Item
									value="yes_unrecognizable"
									id="consent-unrecognizable"
								/>
								<Label
									for="consent-unrecognizable"
									class="font-normal"
									>If not recognizable (wearing a mask)</Label
								>
							</div>
							<div class="flex items-center space-x-3 space-y-0">
								<RadioGroup.Item
									value="yes_recognizable"
									id="consent-yes"
								/>
								<Label for="consent-yes" class="font-normal"
									>Yes</Label
								>
							</div>
						</RadioGroup.Root>
						{#each updateProfile.fields.socialMediaConsent.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.medicalConditions.as("text")}
						<Field.Label for={fieldProps.name}
							>Medical Conditions</Field.Label
						>
						<Textarea
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Please list any medical conditions or allergies you have. If none, leave blank."
							class="min-h-[100px]"
						/>
						{#each updateProfile.fields.medicalConditions.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</div>
			</div>

			<div class="space-y-6">
				<h3 class="text-lg font-semibold">Emergency Contact</h3>
				<div class="grid grid-cols-1 md:grid-cols-2 gap-6">
					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.nextOfKin.as("text")}
						<Field.Label for={fieldProps.name}
							>Next of Kin</Field.Label
						>
						<Input {...fieldProps} id={fieldProps.name} />
						{#each updateProfile.fields.nextOfKin.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps =
							updateProfile.fields.nextOfKinNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Next of Kin Phone Number</Field.Label
						>
						<PhoneInput
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Enter your next of kin's phone number"
						/>
						{#each updateProfile.fields.nextOfKinNumber.issues() as issue}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</div>
			</div>

			<Button
				type="submit"
				class="w-full"
				disabled={!!updateProfile.pending}
			>
				{updateProfile.pending ? "Saving..." : "Save Changes"}
			</Button>
		</form>
	</Card.Content>
</Card.Root>

<FormDebug form={updateProfile} />

{#if showPauseModal}
	<PauseSubscriptionModal
		bind:open={showPauseModal}
		onConfirm={(pauseData) => {
			pauseMutation.mutate(pauseData);
		}}
		isPending={pauseMutation.isPending}
		extend={pausedUntil?.isAfter(dayjs())}
		pausedUntil={pausedUntil ?? undefined}
	/>
{/if}
