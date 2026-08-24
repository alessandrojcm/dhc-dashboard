<script lang="ts">
import { page } from "$app/state";
import { invalidate } from "$app/navigation";
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
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import {
	ArrowLeft,
	Check,
	CreditCard,
	ExternalLink,
	HeartPulse,
	LockKeyhole,
	RotateCcw,
	Swords,
	UserRound,
} from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { Badge } from "$lib/components/ui/badge";
import PauseSubscriptionModal from "$lib/components/ui/pause-subscription-modal.svelte";
import * as ButtonGroup from "$lib/components/ui/button-group";
import { updateProfile } from "./data.remote";
import { Label } from "$lib/components/ui/label";
import { initForm } from "$lib/utils/init-form.svelte";
import { whyThisField } from "$lib/components/ui/why-this-field.svelte";
import FormDebug from "$lib/components/form-debug.svelte";
import { memberProfileClientSchema } from "$lib/schemas/membersSignup";
import { dev } from "$app/environment";
import { untrack } from "svelte";
import { DiscordLogo } from "svelte-radix";
import { publicApiUrl } from "$lib/api-client";
import * as v from "valibot";
import {
	membershipBillingPortalMutation,
	membershipPauseMutation,
	membershipResumeMutation,
	membersAnalyticsQueryKey,
	membersListQueryKey,
	membersMeQueryKey,
	membersShowQueryKey,
} from "@dhc/api-client";
import ReactivateMemberDialog from "$lib/components/ui/reactivate-member-dialog.svelte";
import { SocialMediaConsent } from "$lib/types";

const { data } = $props();
const queryClient = useQueryClient();
const discordLinkUrl = publicApiUrl("/auth/discord/link");
const isOwnProfile = $derived(
	page.data.session?.principal.id === page.params.memberId,
);
const profileName = $derived(
	[data.profileData.firstName, data.profileData.lastName]
		.filter(Boolean)
		.join(" ") || "Member",
);
const pageTitle = $derived(isOwnProfile ? "My profile" : `Edit ${profileName}`);

function detailDependency(memberId: string): string {
	return `member:detail:${memberId}`;
}

async function reconcileProfileMutation(memberId: string) {
	await Promise.all([
		queryClient.invalidateQueries({ queryKey: membersListQueryKey() }),
		queryClient.invalidateQueries({
			queryKey: membersShowQueryKey({ path: { memberId } }),
		}),
		isOwnProfile
			? queryClient.invalidateQueries({ queryKey: membersMeQueryKey() })
			: Promise.resolve(),
		invalidate(detailDependency(memberId)),
	]);
}

async function reconcileMembershipMutation(memberId: string) {
	await Promise.all([
		queryClient.invalidateQueries({ queryKey: membersListQueryKey() }),
		queryClient.invalidateQueries({
			queryKey: membersShowQueryKey({ path: { memberId } }),
		}),
		queryClient.invalidateQueries({ queryKey: membersAnalyticsQueryKey() }),
		isOwnProfile
			? queryClient.invalidateQueries({ queryKey: membersMeQueryKey() })
			: Promise.resolve(),
		invalidate(detailDependency(memberId)),
	]);
}

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
	insuranceFormSubmitted: data.profileData.insuranceFormSubmitted ?? false,
	socialMediaConsent: data.profileData.socialMediaConsent,
}));

let profileResultHandled = false;

// Handle each completed form submission once. Targeted detail invalidation
// updates this page's data while the remote form result remains available.
$effect(() => {
	if (updateProfile.pending) {
		profileResultHandled = false;
		return;
	}
	const result = updateProfile.result;
	if (!result || profileResultHandled) return;
	profileResultHandled = true;
	if (result?.success) {
		void reconcileProfileMutation(requireMemberId());
		toast.success(result.success, { position: "top-right" });
	} else if (result?.error) {
		toast.error(result.error, { position: "top-right" });
	}
});

// Reactive form field values
const dateOfBirth = $derived(updateProfile.fields.dateOfBirth.value() ?? "");
const gender = $derived(updateProfile.fields.gender.value() ?? "");
const weapon = $derived.by(() => {
	const parsed = v.safeParse(
		v.array(v.string()),
		updateProfile.fields.weapon.value(),
	);
	return parsed.success ? parsed.output : [];
});
const socialMediaConsent = $derived(
	updateProfile.fields.socialMediaConsent.value(),
);
const socialMediaConsentSchema = v.picklist([
	SocialMediaConsent.no,
	SocialMediaConsent.yes_unrecognizable,
	SocialMediaConsent.yes_recognizable,
]);

function requireMemberId(): string {
	const memberId = page.params.memberId;
	if (!memberId) throw new Error("Member ID is required");
	return memberId;
}

// Date picker value conversion
const dobValue = $derived.by(() => {
	if (!dateOfBirth || !dayjs(dateOfBirth).isValid()) {
		return undefined;
	}
	return fromDate(dayjs(dateOfBirth).toDate(), getLocalTimeZone());
});

let pausedUntil: dayjs.Dayjs | null = $state(
	untrack(() =>
		data.member.subscription_paused_until
			? dayjs(data.member.subscription_paused_until)
			: null,
	),
);

const openBillingPortal = createMutation(() => ({
	...membershipBillingPortalMutation(),
	onSuccess: (response) => {
		window.open(response.data.url, "_blank", "noopener,noreferrer");
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to open billing portal");
	},
}));

let showPauseModal = $state(false);

const pauseMutation = createMutation(() => ({
	...membershipPauseMutation(),
	onSuccess: async ({ data: member }) => {
		showPauseModal = false;
		pausedUntil = member.subscriptionPausedUntil
			? dayjs(member.subscriptionPausedUntil)
			: null;
		await reconcileMembershipMutation(requireMemberId());
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to pause subscription");
	},
}));

const resumeMutation = createMutation(() => ({
	...membershipResumeMutation(),
	onSuccess: async () => {
		pausedUntil = null;
		await reconcileMembershipMutation(requireMemberId());
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to resume subscription");
	},
}));

// ALE-252: reactivation is offered only for inactive members, and only to
// the four billing-authority roles mirrored from the `:membership_minting_api`
// pipeline (the server enforces 403 for everyone else).
const memberIsInactive = $derived(data.member.membership_status === "inactive");
const canReactivate = $derived(Boolean(data.canReactivate) && memberIsInactive);

let showReactivateModal = $state(false);
</script>

<svelte:head>
	<title>{pageTitle} | Dublin HEMA Club</title>
</svelte:head>

<div class="mx-auto w-full max-w-6xl">
	<header class="mb-7">
		{#if !isOwnProfile}
			<Button
				href="/dashboard/members/directory"
				variant="ghost"
				size="sm"
				class="mb-4 -ml-3"
			>
				<ArrowLeft aria-hidden="true" />
				Back to members
			</Button>
		{/if}

		<p class="mb-2 text-xs font-bold uppercase tracking-[0.18em] text-primary">
			{isOwnProfile ? "Account & membership" : "Member administration"}
		</p>
		<h1 class="font-heading text-3xl text-foreground sm:text-4xl">
			{pageTitle}
		</h1>
		<p
			class="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground sm:text-base"
		>
			{isOwnProfile
				? "Keep your contact, training, and safety details up to date."
				: "Update this member’s club profile, safety details, and membership settings."}
		</p>
	</header>

	<form
		id="member-profile-form"
		{...updateProfile.preflight(memberProfileClientSchema)}
		class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]"
	>
		<div class="min-w-0 space-y-6">
			<Card.Root>
				<Card.Header class="border-b border-border/70 pb-5">
					<div class="flex items-start gap-3">
						<div class="rounded-xl bg-primary/10 p-2.5 text-primary">
							<UserRound class="size-5" aria-hidden="true" />
						</div>
						<div>
							<h2 class="text-lg font-semibold">Personal details</h2>
							<p class="mt-1 text-sm leading-5 text-muted-foreground">
								How the club can identify and contact {isOwnProfile
									? "you"
									: "this member"}.
							</p>
						</div>
					</div>
				</Card.Header>
				<Card.Content class="grid gap-5 sm:grid-cols-2">
					<Field.Field>
						{@const fieldProps = updateProfile.fields.firstName.as("text")}
						<Field.Label for={fieldProps.name}>First name</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							autocomplete="given-name"
						/>
						{#each updateProfile.fields.firstName.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.lastName.as("text")}
						<Field.Label for={fieldProps.name}>Last name</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							autocomplete="family-name"
						/>
						{#each updateProfile.fields.lastName.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.email.as("email")}
						<div class="flex items-center gap-2">
							<Field.Label for={fieldProps.name}>Email</Field.Label>
							<LockKeyhole
								class="size-3.5 text-muted-foreground"
								aria-hidden="true"
							/>
						</div>
						<Input
							class="cursor-default bg-muted/60 text-muted-foreground"
							readonly
							{...fieldProps}
							id={fieldProps.name}
							autocomplete="email"
							aria-describedby="email-help"
						/>
						<Field.Description id="email-help">
							Email changes are handled by the club team.
						</Field.Description>
						{#each updateProfile.fields.email.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.phoneNumber.as("tel")}
						<Field.Label for={fieldProps.name}>Phone number</Field.Label>
						<PhoneInput
							{...fieldProps}
							onChange={(val) => updateProfile.fields.phoneNumber.set(val)}
							id={fieldProps.name}
							placeholder="Enter your phone number"
							autocomplete="tel"
						/>
						{#each updateProfile.fields.phoneNumber.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						<div class="flex items-center gap-2">
							<Field.Label>Date of birth</Field.Label>
							{@render whyThisField(
								"For insurance reasons, HEMA practitioners need to be at least 16 years old",
							)}
						</div>
						<DatePicker
							label="Date of birth"
							value={dobValue}
							onDateChange={(date) => {
								if (!date) return;
								updateProfile.fields.dateOfBirth.set(
									dayjs(date).format("YYYY-MM-DD"),
								);
							}}
						/>
						<input type="hidden" name="dateOfBirth" value={dateOfBirth} />
						{#each updateProfile.fields.dateOfBirth.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</Card.Content>
			</Card.Root>

			<Card.Root>
				<Card.Header class="border-b border-border/70 pb-5">
					<div class="flex items-start gap-3">
						<div
							class="rounded-xl bg-secondary/20 p-2.5 text-secondary-foreground"
						>
							<Swords class="size-5" aria-hidden="true" />
						</div>
						<div>
							<h2 class="text-lg font-semibold">Training preferences</h2>
							<p class="mt-1 text-sm leading-5 text-muted-foreground">
								Preferences that help coaches plan an inclusive training
								environment.
							</p>
						</div>
					</div>
				</Card.Header>
				<Card.Content class="grid gap-5 sm:grid-cols-2">
					<Field.Field>
						<div class="flex items-center gap-2">
							<Field.Label for="gender">Gender</Field.Label>
							{@render whyThisField(
								"This helps us maintain a balanced and inclusive training environment",
							)}
						</div>
						<Select.Root
							type="single"
							value={gender}
							onValueChange={(value) => updateProfile.fields.gender.set(value)}
							name="gender"
						>
							<Select.Trigger id="gender" class="w-full capitalize">
								{gender || "Select your gender"}
							</Select.Trigger>
							<Select.Content>
								{#each data.genders as option (option)}
									<Select.Item value={option} class="capitalize">
										{option}
									</Select.Item>
								{/each}
							</Select.Content>
						</Select.Root>
						{#each updateProfile.fields.gender.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.pronouns.as("text")}
						<div class="flex items-center gap-2">
							<Field.Label for={fieldProps.name}>
								Pronouns (optional)
							</Field.Label>
							{@render whyThisField(
								"This helps us maintain a balanced and inclusive training environment",
							)}
						</div>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="e.g. she/her, they/them"
						/>
						{#each updateProfile.fields.pronouns.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field class="sm:col-span-2">
						{@const fieldProps =
							updateProfile.fields.weapon.as("select multiple")}
						<Field.Label for={fieldProps.name}>Preferred weapons</Field.Label>
						<Select.Root
							type="multiple"
							value={weapon}
							onValueChange={(value) => updateProfile.fields.weapon.set(value)}
						>
							<Select.Trigger
								id={fieldProps.name}
								name={fieldProps.name}
								class="w-full"
							>
								{weapon.length > 0
									? `${weapon.length} selected`
									: "Select preferred weapons"}
							</Select.Trigger>
							<Select.Content>
								{#each data.weapons as option (option)}
									<Select.Item class="capitalize" value={option}>
										{option.replace(/[_-]/g, " ")}
									</Select.Item>
								{/each}
							</Select.Content>
						</Select.Root>
						<Field.Description>Select all that apply.</Field.Description>
						{#if weapon.length > 0}
							<div class="flex flex-wrap gap-2" aria-label="Selected weapons">
								{#each weapon as selectedWeapon (selectedWeapon)}
									<Badge variant="secondary" class="capitalize">
										<Check class="size-3" aria-hidden="true" />
										{selectedWeapon.replace(/[_-]/g, " ")}
									</Badge>
								{/each}
							</div>
						{/if}
						{#each updateProfile.fields.weapon.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
						{#each weapon as selectedWeapon, index (selectedWeapon)}
							<input
								{...updateProfile.fields.weapon[index].as(
									"hidden",
									selectedWeapon,
								)}
							/>
						{/each}
					</Field.Field>

					<fieldset class="space-y-3 sm:col-span-2">
						<legend class="text-sm font-medium">Social media consent</legend>
						<p class="text-sm leading-5 text-muted-foreground">
							Choose how club photos may be used on social media.
						</p>
						<RadioGroup.Root
							name="socialMediaConsent"
							class="grid gap-2"
							value={socialMediaConsent}
							onValueChange={(value) => {
								const parsed = v.safeParse(socialMediaConsentSchema, value);
								if (parsed.success) {
									updateProfile.fields.socialMediaConsent.set(parsed.output);
								}
							}}
						>
							<Label
								for="consent-no"
								class="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-border/80 p-3 transition-colors hover:bg-muted/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
							>
								<RadioGroup.Item value="no" id="consent-no" class="mt-0.5" />
								<span>
									<span class="block font-medium">No photos</span>
									<span
										class="mt-0.5 block text-sm font-normal text-muted-foreground"
									>
										Do not use photos of me.
									</span>
								</span>
							</Label>
							<Label
								for="consent-unrecognizable"
								class="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-border/80 p-3 transition-colors hover:bg-muted/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
							>
								<RadioGroup.Item
									value="yes_unrecognizable"
									id="consent-unrecognizable"
									class="mt-0.5"
								/>
								<span>
									<span class="block font-medium"
										>Only when I’m not recognizable</span
									>
									<span
										class="mt-0.5 block text-sm font-normal text-muted-foreground"
									>
										For example, while wearing a fencing mask.
									</span>
								</span>
							</Label>
							<Label
								for="consent-yes"
								class="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-border/80 p-3 transition-colors hover:bg-muted/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
							>
								<RadioGroup.Item
									value="yes_recognizable"
									id="consent-yes"
									class="mt-0.5"
								/>
								<span>
									<span class="block font-medium">Photos are okay</span>
									<span
										class="mt-0.5 block text-sm font-normal text-muted-foreground"
									>
										Photos may show me clearly.
									</span>
								</span>
							</Label>
						</RadioGroup.Root>
						{#each updateProfile.fields.socialMediaConsent.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</fieldset>
				</Card.Content>
			</Card.Root>

			<Card.Root>
				<Card.Header class="border-b border-border/70 pb-5">
					<div class="flex items-start gap-3">
						<div class="rounded-xl bg-accent/10 p-2.5 text-accent">
							<HeartPulse class="size-5" aria-hidden="true" />
						</div>
						<div>
							<h2 class="text-lg font-semibold">Health & emergency</h2>
							<p class="mt-1 text-sm leading-5 text-muted-foreground">
								Safety information coaches may need during training.
							</p>
						</div>
					</div>
				</Card.Header>
				<Card.Content class="grid gap-5 sm:grid-cols-2">
					<Field.Field class="sm:col-span-2">
						{@const fieldProps =
							updateProfile.fields.medicalConditions.as("text")}
						<Field.Label for={fieldProps.name}
							>Medical conditions or allergies</Field.Label
						>
						<Textarea
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Add anything coaches should know, or leave blank."
							class="min-h-28"
						/>
						{#each updateProfile.fields.medicalConditions.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.nextOfKin.as("text")}
						<Field.Label for={fieldProps.name}>Emergency contact</Field.Label>
						<Input
							{...fieldProps}
							id={fieldProps.name}
							placeholder="Full name"
						/>
						{#each updateProfile.fields.nextOfKin.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>

					<Field.Field>
						{@const fieldProps = updateProfile.fields.nextOfKinNumber.as("tel")}
						<Field.Label for={fieldProps.name}
							>Emergency contact phone</Field.Label
						>
						<PhoneInput
							{...fieldProps}
							onChange={(val) => updateProfile.fields.nextOfKinNumber.set(val)}
							id={fieldProps.name}
							placeholder="Enter their phone number"
						/>
						{#each updateProfile.fields.nextOfKinNumber.issues() as issue (issue.message)}
							<Field.Error>{issue.message}</Field.Error>
						{/each}
					</Field.Field>
				</Card.Content>
			</Card.Root>
		</div>

		<aside
			class="space-y-6 lg:sticky lg:top-6 lg:self-start"
			aria-label="Membership settings"
		>
			<Card.Root>
				<Card.Header class="border-b border-border/70 pb-5">
					<div class="flex items-start gap-3">
						<div class="rounded-xl bg-primary/10 p-2.5 text-primary">
							<CreditCard class="size-5" aria-hidden="true" />
						</div>
						<div>
							<h2 class="text-lg font-semibold">Membership</h2>
							<p class="mt-1 text-sm leading-5 text-muted-foreground">
								Billing and subscription controls.
							</p>
						</div>
					</div>
				</Card.Header>
				<Card.Content class="space-y-4">
					<div class="flex items-center justify-between gap-3">
						<span class="text-sm font-medium">Subscription</span>
						{#if pausedUntil?.isAfter(dayjs())}
							<Badge variant="secondary">
								Paused until {pausedUntil.format("MMM D, YYYY")}
							</Badge>
						{:else}
							<Badge variant="default">Active</Badge>
						{/if}
					</div>

					{#if data.canUpdate}
						<Button
							disabled={openBillingPortal.isPending}
							variant="outline"
							type="button"
							onclick={() =>
								openBillingPortal.mutate({
									path: { memberId: requireMemberId() },
									body: { returnUrl: window.location.href },
								})}
							class="w-full"
						>
							{#if openBillingPortal.isPending}
								<LoaderCircle class="size-4" />
							{/if}
							Manage billing
							<ExternalLink class="size-4" aria-hidden="true" />
						</Button>

						{#if pausedUntil?.isAfter(dayjs())}
							<ButtonGroup.Root class="w-full">
								<Button
									variant="default"
									onclick={() => (showPauseModal = true)}
									disabled={resumeMutation.isPending}
									type="button"
									class="min-w-0 flex-1 px-3"
								>
									Extend pause
								</Button>
								<Button
									variant="outline"
									onclick={() =>
										resumeMutation.mutate({
											path: { memberId: requireMemberId() },
										})}
									disabled={resumeMutation.isPending}
									type="button"
									class="min-w-0 flex-1 px-3"
								>
									{resumeMutation.isPending ? "Resuming…" : "Resume"}
								</Button>
							</ButtonGroup.Root>
						{:else}
							<Button
								variant="outline"
								onclick={() => (showPauseModal = true)}
								type="button"
								class="w-full"
							>
								Pause subscription
							</Button>
						{/if}
					{/if}

					{#if canReactivate && memberIsInactive}
						<div class="border-t border-border/70 pt-4">
							<Button
								variant="default"
								type="button"
								class="w-full"
								onclick={() => {
									showReactivateModal = true;
								}}
							>
								<RotateCcw class="size-4" aria-hidden="true" />
								Reactivate membership
							</Button>
							<p class="mt-2 text-xs leading-4 text-muted-foreground">
								Starts fresh monthly and annual subscriptions charged to the
								saved SEPA payment method.
							</p>
						</div>
					{/if}

					{#if isOwnProfile}
						<div class="border-t border-border/70 pt-4">
							{#if data.member.discordIdentity}
								<div class="rounded-xl border border-border/80 bg-muted/40 p-3">
									<div class="flex items-center gap-3">
										{#if data.member.discordIdentity.avatarUrl}
											<img
												src={data.member.discordIdentity.avatarUrl}
												alt=""
												width="40"
												height="40"
												referrerpolicy="no-referrer"
												class="size-10 rounded-full bg-background object-cover"
											/>
										{:else}
											<div
												class="grid size-10 shrink-0 place-items-center rounded-full bg-[#5865f2]/10 text-[#5865f2]"
											>
												<DiscordLogo class="size-5" aria-hidden="true" />
											</div>
										{/if}
										<div class="min-w-0 flex-1">
											<div class="flex flex-wrap items-center gap-2">
												<span class="text-sm font-semibold">Discord</span>
												<Badge variant="secondary">Connected</Badge>
											</div>
											<p class="mt-0.5 truncate text-sm text-muted-foreground">
												{data.member.discordIdentity.username
													? `@${data.member.discordIdentity.username}`
													: "Discord account linked"}
											</p>
										</div>
									</div>
								</div>
								<p class="mt-2 text-sm leading-5 text-muted-foreground">
									You can use this Discord account to sign in.
								</p>
							{:else}
								<Button href={discordLinkUrl} variant="outline" class="w-full">
									<DiscordLogo class="size-4" aria-hidden="true" />
									Link Discord account
								</Button>
								<p class="mt-2 text-sm leading-5 text-muted-foreground">
									Connect Discord so you can use it to sign in.
								</p>
							{/if}
						</div>
					{/if}
				</Card.Content>
			</Card.Root>
		</aside>

		<div
			class="sticky bottom-3 z-10 col-span-full flex flex-col gap-3 rounded-2xl border border-border/80 bg-card/95 p-3 shadow-lg backdrop-blur sm:flex-row sm:items-center sm:justify-between sm:px-4"
		>
			<div class="hidden sm:block">
				<p class="text-sm font-semibold">Ready to save?</p>
				<p class="text-sm text-muted-foreground">
					Your changes apply to {isOwnProfile ? "your profile" : profileName}.
				</p>
			</div>
			<Button
				type="submit"
				class="w-full sm:w-auto sm:min-w-40"
				disabled={!!updateProfile.pending}
			>
				{#if updateProfile.pending}
					<LoaderCircle class="size-4" />
				{/if}
				{updateProfile.pending ? "Saving…" : "Save changes"}
			</Button>
			<span class="sr-only" aria-live="polite">
				{updateProfile.pending ? "Saving profile changes" : ""}
			</span>
		</div>
	</form>
</div>

{#if dev}
	<FormDebug form={updateProfile} />
{/if}

{#if showPauseModal}
	<PauseSubscriptionModal
		bind:open={showPauseModal}
		onConfirm={(pauseData) => {
			pauseMutation.mutate({
				path: { memberId: requireMemberId() },
				body: { pauseUntil: pauseData.pauseUntil },
			});
		}}
		isPending={pauseMutation.isPending}
		extend={pausedUntil?.isAfter(dayjs())}
		pausedUntil={pausedUntil ?? undefined}
	/>
{/if}

{#if showReactivateModal}
	<ReactivateMemberDialog
		bind:open={showReactivateModal}
		memberId={requireMemberId()}
		onSettled={() => invalidate(detailDependency(requireMemberId()))}
	/>
{/if}
