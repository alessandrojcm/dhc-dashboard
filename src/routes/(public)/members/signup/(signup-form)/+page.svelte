<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import dayjs from 'dayjs';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { memberSignupSchema } from '$lib/schemas/membersSignup';
	import { AsYouType } from 'libphonenumber-js/min';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { ArrowRightIcon, Info } from 'lucide-svelte';
	import { loadStripe, type StripeElements } from '@stripe/stripe-js';
	import { PUBLIC_STRIPE_KEY } from '$env/static/public';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import { Elements, PaymentElement } from 'svelte-stripe';
	import * as Card from '$lib/components/ui/card';
	import { TooltipProvider, TooltipTrigger, TooltipContent } from '$lib/components/ui/tooltip';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import Dinero from 'dinero.js';
	import { toast } from 'svelte-sonner';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import * as Alert from '$lib/components/ui/alert';

	const { data } = $props();
	let stripe: Awaited<ReturnType<typeof loadStripe>> | null = $state(null);
	let elements: StripeElements | null | undefined = $state(null);
	let showThanks = $state(false);

	const { subscriptionAmount, proratedPrice, nextBillingDate } = data;
	const subscriptionAmountDinero = Dinero(subscriptionAmount);
	const proratedPriceDinero = Dinero(proratedPrice);

	const form = superForm(data.form, {
		validators: valibotClient(memberSignupSchema),
		validationMethod: 'onblur',
		invalidateAll: false,
		resetForm: false,
		onSubmit: async ({ customRequest }) => {
			await elements!.submit();
			const { error, confirmationToken } = await stripe!.createConfirmationToken({
				elements: elements!
			});
			if (error) {
				toast.error(
					'There was an error with your payment. We have been notified. Please try again later.'
				);
				return;
			}
			$formData.stripeConfirmationToken = JSON.stringify(confirmationToken);
			customRequest(({ controller, action, formData }) => {
				formData.set('stripeConfirmationToken', confirmationToken.id);
				return fetch(action, {
					signal: controller.signal,
					method: 'POST',
					body: formData
				});
			});
		}
	});
	const { form: formData, enhance, submitting, errors, message } = form;
	const formatedPhone = $derived.by(() => new AsYouType('IE').input(data.userData.phoneNumber!));
	const formatedNextOfKinPhone = $derived.by(() =>
		new AsYouType('IE').input($formData.nextOfKinNumber)
	);

	onMount(() => {
		loadStripe(PUBLIC_STRIPE_KEY).then((result) => {
			stripe = result;
		});
		const unsub = message.subscribe(async (m) => {
			if (m?.paymentFailed === true) {
				toast.error(
					m.errorMessage || 'There was an error with your payment. We have been notified. Please try again later.'
				);
			} else if (m?.requiresAction === true) {
				const response = await stripe?.handleNextAction({
					clientSecret: data.clientSecret!
				});

				if (response?.error) {
					toast.error(
						'There was an error processing your payment action. Please try again.'
					);
				} else {
					showThanks = true;
				}
			} else if (m?.paymentFailed === false) {
				showThanks = true;
			}
		});

		return () => {
			unsub();
		};
	});

	$effect(() => {
		if (elements) {
			elements.update({
				payment_method_types: ['sepa_debit']
			});
		}
	});

	$inspect($formData.paymentIntentId);
</script>

{#snippet thanksAlert()}
	<Alert.Root variant="success" class="w-full">
		<Alert.Title>Thank You for Joining!</Alert.Title>
		<Alert.Description>
			Your membership has been successfully processed. Welcome to Dublin Hema Club! You will receive
			a Discord invite by email shortly.
		</Alert.Description>
		<Button onclick={() => goto('/dashboard')} class="mt-2">Go to Dashboard</Button>
	</Alert.Root>
{/snippet}

{#if showThanks}
	{@render thanksAlert()}
{:else}
	<form method="POST" class="space-y-6" use:enhance>
		<div class="grid grid-cols-2 gap-4">
			<div>
				<p>First Name</p>
				<p class="text-sm text-gray-600">{data.userData.firstName}</p>
			</div>
			<div>
				<p>Last Name</p>
				<p class="text-sm text-gray-600">{data.userData.lastName}</p>
			</div>
			<div>
				<p>Email</p>
				<p class="text-sm text-gray-600">{data.userData.email}</p>
			</div>
			<div>
				<p>Date of Birth</p>
				<p class="text-sm text-gray-600">
					{dayjs(data.userData.dateOfBirth).format('DD/MM/YYYY')}
				</p>
			</div>
			<div>
				<p>Gender</p>
				<p class="text-sm text-gray-600 capitalize">{data.userData.gender}</p>
			</div>
			<div>
				<p>Pronouns</p>
				<p class="text-sm text-gray-600 capitalize">{data.userData.pronouns}</p>
			</div>
			<div>
				<p>Phone Number</p>
				<p class="text-sm text-gray-600">{formatedPhone}</p>
			</div>
			<div>
				<p>Medical Conditions</p>
				<p class="text-sm text-gray-600">
					{!data.userData.medicalConditions ? 'N/A' : data.userData.medicalConditions}
				</p>
			</div>
		</div>
		<div class="space-y-4">
			<Form.Field {form} name="nextOfKin">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Next of Kin</Form.Label>
						<Input
							{...props}
							bind:value={$formData.nextOfKin}
							placeholder="Full name of your next of kin"
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>

			<Form.Field {form} name="nextOfKinNumber">
				<Form.Control>
					{#snippet children({ props })}
						<Form.Label required>Next of Kin Phone Number</Form.Label>
						<Input
							type="tel"
							{...props}
							placeholder="Enter your next of kin's phone number"
							value={formatedNextOfKinPhone}
							onchange={(event) => {
								$formData.nextOfKinNumber = event.target.value;
							}}
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
			<p class="prose text-lg text-black">Payment details</p>
			<Card.Root class="bg-muted">
				<Card.Content class="pt-6">
					<div class="space-y-4">
						<div class="flex justify-between items-center">
							<div class="flex items-center gap-2">
								<span>Pro-rated amount (first payment)</span>
								<Tooltip.Provider>
									<Tooltip.Root>
										<TooltipTrigger>
											<Info class="h-4 w-4" />
										</TooltipTrigger>
										<TooltipContent>
											This is the calculated amount for the remainder of this month
										</TooltipContent>
									</Tooltip.Root>
								</Tooltip.Provider>
							</div>
							<span class="font-semibold">{proratedPriceDinero.toFormat()}</span>
						</div>
						<div class="flex justify-between items-center">
							<div class="flex items-center gap-2">
								<span>Monthly subscription</span>
								<TooltipProvider>
									<Tooltip.Root>
										<TooltipTrigger>
											<Info class="h-4 w-4" />
										</TooltipTrigger>
										<TooltipContent>Regular monthly payment starting next month</TooltipContent>
									</Tooltip.Root>
								</TooltipProvider>
							</div>
							<span class="font-semibold">{subscriptionAmountDinero.toFormat()}</span>
						</div>
						<div class="flex justify-between items-center text-sm text-muted-foreground">
							<span>Next billing date</span>
							<span>{dayjs(nextBillingDate).format('D MMMM YYYY')}</span>
						</div>
					</div>
				</Card.Content>
			</Card.Root>
			{#if stripe}
				<Elements
					{stripe}
					mode="subscription"
					amount={proratedPriceDinero.getAmount()}
					currency="eur"
					theme="flat"
					locale="en"
					variables={{
						colorPrimary: '221.2 83.2% 53.3%',
						borderRadius: '1rem',
						fontFamily: 'Inter, sans-serif',
						fontSizeBase: '1rem',
						fontSizeSm: '0.875rem'
					}}
					rules={{
						'.Label': {
							fontWeight: '500'
						},
						'.Input': {
							marginTop: '.5rem',
							backgroundColor: 'transparent',
							border: 'hsl(214.3 31.8% 91.4%) 1px solid',
							borderRadius: 'calc(var(--borderRadius) - 2px)',
							fontSize: 'var(--fontSizeSm)',
							padding: '0.5rem 0.75rem'
						}
					}}
					bind:elements
				>
					<PaymentElement
						options={{
							defaultValues: {
								billingDetails: {
									email: data.userData.email,
									name: `${data.userData.firstName} ${data.userData.lastName}`
								}
							},
							business: { name: 'Dublin Hema Club' }
						}}
					/>
				</Elements>
			{:else}
				<Skeleton class="h-96" />
			{/if}

			<Form.Field {form} name="insuranceFormSubmitted" class="flex items-center gap-2">
				<Form.Control>
					{#snippet children({ props })}
						<Checkbox {...props} bind:checked={$formData.insuranceFormSubmitted} />
						<Form.Label
							style="margin-top: 0 !important"
							class={$errors?.insuranceFormSubmitted ? 'text-red-500' : ''}
							>Please make sure you have submitted HEMA Ireland's
							{#await data.insuranceFormLink}
								<span class="text-blue-500 underline cursor-pointer">insurance form</span>
							{:then insuranceFormLink}
								<a class="text-blue-500 underline" href={insuranceFormLink} target="_blank"
									>insurance form</a
								>
							{/await}
						</Form.Label>
					{/snippet}
				</Form.Control>
			</Form.Field>
			<Form.Field {form} name="paymentIntentId">
				<Form.Control>
					{#snippet children({ props })}
						<input
							id="paymentIntentId"
							name={props.name}
							readonly
							value={$formData.paymentIntentId}
							hidden
						/>
					{/snippet}
				</Form.Control>
			</Form.Field>
		</div>
		<div class="flex justify-between">
			<Button type="submit" class="ml-auto" disabled={$submitting}>
				{#if $submitting}
					<LoaderCircle />
				{:else}
					Sign up
					<ArrowRightIcon class="ml-2 h-4 w-4" />
				{/if}
			</Button>
		</div>
	</form>
{/if}
