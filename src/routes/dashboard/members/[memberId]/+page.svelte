<script lang="ts">
import { fromDate, getLocalTimeZone } from "@internationalized/date";
import { createMutation } from "@tanstack/svelte-query";
import dayjs from "dayjs";
import type Stripe from "stripe";
import { toast } from "svelte-sonner";
import { dateProxy, superForm } from "sveltekit-superforms";
import { valibotClient } from "sveltekit-superforms/adapters";
import { page } from "$app/state";
import signupSchema from "$lib/schemas/membersSignup";

const { data } = $props();

const form = superForm(data.form, {
	validators: valibotClient(signupSchema),
	validationMethod: "onblur",
	resetForm: false,
});
const { form: formData, enhance, submitting, message } = form;
const _dobProxy = dateProxy(form, "dateOfBirth", { format: `date` });
const _dobValue = $derived.by(() => {
	if (
		!dayjs($formData.dateOfBirth).isValid() ||
		dayjs($formData.dateOfBirth).isSame(dayjs())
	) {
		return undefined;
	}
	return fromDate(dayjs($formData.dateOfBirth).toDate(), getLocalTimeZone());
});
let _pausedUntil: dayjs.Dayjs | null = $derived(
	data.member.subscription_paused_until
		? dayjs(data.member.subscription_paused_until)
		: null,
);
const _openBillingPortal = createMutation(() => ({
	mutationFn: () =>
		fetch(`/dashboard/members/${page.params.memberId}`, {
			method: "POST",
		}).then((res) => res.json()) as Promise<{ portalURL: string }>,
	onSuccess: (data: { portalURL: string }) => {
		window.open(data.portalURL, "_blank");
	},
}));

let _showPauseModal = $state(false);

const _pauseMutation = createMutation(() => ({
	mutationFn: async (pauseData: { pauseUntil: string }) => {
		const response = await fetch(
			`/api/members/${page.params.memberId}/subscription/pause`,
			{
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify(pauseData),
			},
		);

		const data: {
			subscription: Stripe.Response<Stripe.Subscription>;
			error?: string;
		} = await response.json();

		if (!response.ok) {
			throw new Error(data?.error || `HTTP error! status: ${response.status}`);
		}
		return data as { subscription: Stripe.Response<Stripe.Subscription> };
	},
	onSuccess: ({
		subscription,
	}: {
		subscription: Stripe.Response<Stripe.Subscription>;
	}) => {
		_showPauseModal = false;
		_pausedUntil = dayjs.unix(subscription.pause_collection?.resumes_at!);
	},
	onError: (error) => {
		toast.error(`Failed to pause subscription: ${error.message}`);
	},
}));

const _resumeMutation = createMutation(() => ({
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
		_pausedUntil = null;
	},
	onError: (error) => {
		toast.error(`Failed to resume subscription: ${error.message}`);
	},
}));

$effect(() => {
	const sub = message.subscribe((m) => {
		if (m?.success) {
			toast.success(m.success, { position: "top-right" });
		}
		if (m?.failure) {
			toast.error(m.failure, { position: "top-right" });
		}
	});

	return sub;
});
</script>

<Card.Root class="w-full max-w-4xl mx-auto">
    <Card.Header>
        <Card.Title>Member Information</Card.Title>
        <Card.Description>View and edit your membership details</Card.Description>
    </Card.Header>
    <Card.Content class="min-h-96 max-h-[73dvh] overflow-y-auto">
        <form method="POST" action="?/update-profile" use:enhance class="space-y-8">
            <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="space-y-6">
                    <Form.Field {form} name="firstName">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="firstName">First name</Form.Label>
                                <Input {...props} bind:value={$formData.firstName}/>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="lastName">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="lastName">Last name</Form.Label>
                                <Input {...props} bind:value={$formData.lastName}/>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="email">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="email">Email</Form.Label>
                                <Input
                                        class="cursor-not-allowed bg-gray-300/50"
                                        readonly
                                        {...props}
                                        type="email"
                                        bind:value={$formData.email}
                                />
                            {/snippet}
                        </Form.Control>
                        <Form.FormDescription>
                            Please contact us if you need to change your email.
                        </Form.FormDescription>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="phoneNumber">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label>Phone Number</Form.Label>
                                <PhoneInput
                                        placeholder="Enter your phone number"
                                        {...props}
                                        bind:phoneNumber={
										() => $formData.phoneNumber,
										(v) => {
											$formData.phoneNumber = v;
										}
									}
                                />
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="dateOfBirth">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="dateOfBirth">Date of Birth</Form.Label>
                                <DatePicker
                                        {...props}
                                        value={dobValue}
                                        onDateChange={(date) => {
										if (!date) {
											return;
										}
										$formData.dateOfBirth = date;
									}}
                                />
                                <input id="dobInput" type="date" hidden value={$dobProxy} name={props.name}/>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    {#if data.canUpdate}
                        <Button
                                disabled={openBillingPortal.isPending}
                                variant="outline"
                                type="button"
                                onclick={() => openBillingPortal.mutate()}
                                class="w-full"
                        >
                            {#if openBillingPortal.isPending}
                                <LoaderCircle class="ml-2 h-4 w-4"/>
                            {/if}
                            Manage payment settings
                            <ExternalLink class="ml-2 h-4 w-4"/>
                        </Button>

                        <div class="space-y-4 grid-cols-2 grid-rows-2">
                            <div class="flex items-center justify-between">
                                <span class="text-sm font-medium">Subscription Status:</span>
                                {#if pausedUntil?.isAfter(dayjs())}
                                    <Badge variant="secondary">
                                        Paused until {pausedUntil.format('MMM D, YYYY')}
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
                                        {resumeMutation.isPending ? 'Resuming...' : 'Resume Subscription'}
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
                    <Form.Field {form} name="gender">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="gender">Gender</Form.Label>
                                <Select.Root type="single" bind:value={$formData.gender} name={props.name}>
                                    {#await data.genders}
                                        <Select.Trigger class="w-full capitalize" {...props}>
                                            {$formData.gender ? $formData.gender : 'Select your gender'}
                                        </Select.Trigger>
                                    {:then genders}
                                        <Select.Trigger class="w-full" {...props}>
                                            {$formData.gender ? $formData.gender : 'Select your gender'}
                                        </Select.Trigger>
                                        <Select.Content>
                                            {#each genders as gender}
                                                <Select.Item value={gender} class="capitalize">{gender}</Select.Item>
                                            {/each}
                                        </Select.Content>
                                    {/await}
                                </Select.Root>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="pronouns">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="pronouns">Pronouns</Form.Label>
                                <Input
                                        class="capitalize"
                                        {...props}
                                        bind:value={$formData.pronouns}
                                        placeholder="e.g. she/her, they/them"
                                />
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="weapon">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="weapon">Preferred Weapon</Form.Label>
                                <Select.Root type="multiple" bind:value={$formData.weapon} name={props.name}>
                                    {#await data.weapons}
                                        <Select.Trigger class="capitalize" {...props}>
                                            {$formData.weapon?.length > 0
                                                ? $formData.weapon.join(', ')
                                                : 'Select your preferred weapon(s)'}
                                        </Select.Trigger>
                                    {:then weapons}
                                        <Select.Trigger class="capitalize" {...props}>
                                            {$formData.weapon
                                                ? $formData.weapon.join(', ').replace(/[_-]/g, ' ')
                                                : 'Select your preferred weapon(s)'}
                                        </Select.Trigger>
                                        <Select.Content>
                                            {#each weapons as weapon}
                                                <Select.Item class="capitalize" value={weapon}
                                                >{weapon.replace(/[_-]/g, ' ')}</Select.Item
                                                >
                                            {/each}
                                        </Select.Content>
                                    {/await}
                                </Select.Root>
                            {/snippet}
                        </Form.Control>
                        <Form.FormDescription>You can select more than one</Form.FormDescription>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Fieldset {form} name="socialMediaConsent">
						<span class="flex items-center gap-2">
							<p class="text-sm font-medium">Social media consent</p>
                            {@render whyThisField(
                                'We sometimes take pictures for our social media, please indicate if you are comfortable with this'
                            )}
						</span>
                        <RadioGroup.Root
                                name="socialMediaConsent"
                                class="flex justify-start"
                                bind:value={$formData.socialMediaConsent}
                        >
                            <div class="flex items-center space-x-3 space-y-0">
                                <Form.Control>
                                    {#snippet children({props})}
                                        <RadioGroup.Item value="no" {...props}/>
                                        <Form.Label class="font-normal">No</Form.Label>
                                    {/snippet}
                                </Form.Control>
                            </div>
                            <div class="flex items-center space-x-3 space-y-0">
                                <Form.Control>
                                    {#snippet children({props})}
                                        <RadioGroup.Item value="yes_unrecognizable" {...props}/>
                                        <Form.Label class="font-normal"
                                        >If not recognizable (wearing a mask)
                                        </Form.Label>
                                    {/snippet}
                                </Form.Control>
                            </div>
                            <div class="flex items-center space-x-3 space-y-0">
                                <Form.Control>
                                    {#snippet children({props})}
                                        <RadioGroup.Item value="yes_recognizable" {...props}/>
                                        <Form.Label class="font-normal">Yes</Form.Label>
                                    {/snippet}
                                </Form.Control>
                            </div>
                        </RadioGroup.Root>
                        <Form.FieldErrors/>
                    </Form.Fieldset>
                    <Form.Field {form} name="medicalConditions">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="medicalConditions">Medical Conditions</Form.Label>
                                <Textarea
                                        {...props}
                                        bind:value={$formData.medicalConditions}
                                        placeholder="Please list any medical conditions or allergies you have. If none, leave blank."
                                        class="min-h-[100px]"
                                />
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                </div>
            </div>
            <div class="space-y-6">
                <h3 class="text-lg font-semibold">Emergency Contact</h3>
                <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                    <Form.Field {form} name="nextOfKin">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label for="nextOfKin">Next of Kin</Form.Label>
                                <Input {...props} bind:value={$formData.nextOfKin}/>
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                    <Form.Field {form} name="nextOfKinNumber">
                        <Form.Control>
                            {#snippet children({props})}
                                <Form.Label>Next of Kin Phone Number</Form.Label>
                                <PhoneInput
                                        placeholder="Enter your next of kin's phone number"
                                        {...props}
                                        bind:phoneNumber={$formData.nextOfKinNumber}
                                />
                            {/snippet}
                        </Form.Control>
                        <Form.FieldErrors/>
                    </Form.Field>
                </div>
            </div>
            {#if import.meta.env.DEV}
                <SuperDebug data={formData}/>
            {/if}
            <Button type="submit" class="w-full" disabled={$submitting}>
                {$submitting ? 'Saving...' : 'Save Changes'}
            </Button>
        </form>
    </Card.Content>
</Card.Root>

{#if showPauseModal}
    <PauseSubscriptionModal
            bind:open={showPauseModal}
            onConfirm={(data) => {
			pauseMutation.mutate(data);
		}}
            isPending={pauseMutation.isPending}
            extend={pausedUntil?.isAfter(dayjs())}
            pausedUntil={pausedUntil ?? undefined}
    />
{/if}
