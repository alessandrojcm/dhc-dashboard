<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import dayjs from 'dayjs';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { memberSignupSchema } from '$lib/schemas/membersSignup';
	import { parsePhoneNumberFromString } from 'libphonenumber-js/min';
	import { Checkbox } from '$lib/components/ui/checkbox';
	import { AlertTriangle, ArrowRightIcon, Info } from 'lucide-svelte';
	import {
		loadStripe,
		type StripeElements,
		type StripeElementsOptions,
		type StripePaymentElement
	} from '@stripe/stripe-js';
	import { PUBLIC_STRIPE_KEY } from '$env/static/public';
	import { Skeleton } from '$lib/components/ui/skeleton';
	import * as Card from '$lib/components/ui/card';
	import { TooltipProvider, TooltipTrigger, TooltipContent } from '$lib/components/ui/tooltip';
	import * as Accordion from '$lib/components/ui/accordion';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import Dinero from 'dinero.js';
	import { toast } from 'svelte-sonner';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import * as Alert from '$lib/components/ui/alert';
	import PhoneInput from '$lib/components/ui/phone-input.svelte';
	import { createMutation, createQuery } from '@tanstack/svelte-query';
	import type { PlanPricing } from '$lib/types.js';

	const { data } = $props();
	const { streamed, nextMonthlyBillingDate, nextAnnualBillingDate } = data;
	let stripe: Awaited<ReturnType<typeof loadStripe>> | null = $state(null);
	let elements: StripeElements | null | undefined = $state(null);
	let paymentElement: StripePaymentElement | null | undefined = $state(null);
	let showThanks = $state(false);
	// Initialize coupon code state, will be set inside await block from resolved data
	let couponCode = $state('');

	const stripeElementsOptions: StripeElementsOptions = {
		mode: 'setup',
		payment_method_types: ['sepa_debit'],
		currency: 'eur',
		paymentMethodCreation: 'manual',
		appearance: {
			theme: 'flat',
			variables: {
				colorPrimary: '221.2 83.2% 53.3%',
				borderRadius: '.5rem',
				fontFamily: 'Inter, sans-serif',
				fontSizeBase: '1rem',
				fontSizeSm: '0.875rem'
			},
			rules: {
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
			}
		}
	};

	const form = superForm(data.form, {
		validators: valibotClient(memberSignupSchema),
		invalidateAll: false,
		resetForm: false,
		validationMethod: 'onblur',
		scrollToError: 'smooth',
		onSubmit: async function({ cancel, customRequest }) {
			const { valid } = await form.validateForm({ focusOnError: true, update: true });
			if (!valid) {
				scrollTo({ top: 0, behavior: 'smooth' });
				cancel();
			}
			if (!stripe || !elements) {
				toast.error('Payment system not initialized');
				cancel();
				return;
			}

			const { error: elementsError } = await elements.submit();
			if (elementsError?.message) {
				toast.error(elementsError.message);
				cancel();
				return;
			}
			// Create the payment method directly
			const { error: paymentMethodError, confirmationToken } = await stripe.createConfirmationToken(
				{
					elements,
					params: {
						return_url: window.location.href + '/members/signup'
					}
				}
			);

			if (paymentMethodError?.message) {
				toast.error(paymentMethodError.message);
				return;
			}
			$formData.stripeConfirmationToken = JSON.stringify(confirmationToken);
			customRequest(({ controller, action, formData }) => {
				formData.set('stripeConfirmationToken', JSON.stringify(confirmationToken));
				return fetch(action, {
					signal: controller.signal,
					method: 'POST',
					body: formData
				});
			});
		},
		onResult: async ({ result }) => {
			if (result.type === 'error') {
				toast.error(result.error.message);
				return;
			}

			if (result.type === 'failure') {
				if (result.data?.paymentFailed) {
					toast.error(result.data.errorMessage || 'Payment failed');
					return;
				}
				toast.error(
					'Something has gone wrong with your payment, we have been notified and are working on it.'
				);
			}

			if (result.type === 'success') {
				showThanks = true;
			}
		}
	});
	const { form: formData, enhance, submitting } = form;
	const formatedPhone = $derived.by(() => parsePhoneNumberFromString(data.userData.phoneNumber!));

	// Keep planData query for coupon updates, but initial display uses streamed data
	const planData = createQuery(() => ({
		queryKey: ['plan-pricing', couponCode],
		queryFn: async () => {
			const res = await fetch(`/api/signup/plan-pricing?coupon=${couponCode}`);
			if (!res.ok) {
				throw new Error('Failed to fetch pricing');
			}
			return (await res.json()) as PlanPricing;
		},
		enabled: couponCode !== '' // Only enable if a coupon is entered
	}));

	const applyCoupon = createMutation(() => ({
		mutationFn: (code: string) =>
			fetch('/api/signup/coupon', { method: 'POST', body: JSON.stringify({ code }) }).then(
				async (res) => {
					const { message } = (await res.json()) as unknown as { message: string };
					if (res.status >= 400) {
						throw new Error(message, {
							cause: message
						});
					}
					return message;
				}
			),
		onSuccess: () => {
			planData.refetch();
		}
	}));

	onMount(() => {
		loadStripe(PUBLIC_STRIPE_KEY).then((result) => {
			stripe = result;
			elements = stripe?.elements(stripeElementsOptions);
			paymentElement = elements?.create('payment', {
				defaultValues: {
					billingDetails: {
						name: `${data.userData.firstName} ${data.userData.lastName}`,
						email: data.userData.email,
						phone: data.userData.phoneNumber
					}
				}
			});
			streamed.pricingData.then(() => {
				paymentElement?.mount('#payment-element');
			});
		});
	});
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
				<p class="text-sm text-gray-600">{formatedPhone?.formatInternational()}</p>
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
						<PhoneInput
							placeholder="Enter your next of kin's phone number"
							{...props}
							bind:phoneNumber={$formData.nextOfKinNumber}
						/>
					{/snippet}
				</Form.Control>
				<Form.FieldErrors />
			</Form.Field>
			<p class="prose text-lg text-black">Payment details</p>

			{#await streamed.pricingData}
				<!-- Pending state -->
				<Card.Root class="bg-muted">
					<Card.Content class="pt-6">
						<div class="flex items-center justify-center h-48">
							<LoaderCircle class="text-primary animate-spin" />
							<span class="ml-2">Loading pricing information...</span>
						</div>
					</Card.Content>
				</Card.Root>
			{:then planPricing}
				<!-- Resolved state -->
				{@const proratedPriceDinero = Dinero(planPricing.proratedPrice)}
				{@const monthlyFeeDinero = Dinero(planPricing.monthlyFee)}
				{@const annualFeeDinero = Dinero(planPricing.annualFee)}
				{@const discountedMonthlyFeeDinero = planPricing.discountedMonthlyFee
					? Dinero(planPricing.discountedMonthlyFee)
					: null}
				{@const discountedAnnualFeeDinero = planPricing.discountedAnnualFee
					? Dinero(planPricing.discountedAnnualFee)
					: null}
				{@const discountPercentage = planPricing.discountPercentage}

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
												This is the initial amount charged today, covering the rest of the current
												month and the annual fee.
											</TooltipContent>
										</Tooltip.Root>
									</Tooltip.Provider>
								</div>
								<span class="font-semibold">{proratedPriceDinero.toFormat()}</span>
							</div>
							<div class="flex justify-between items-center">
								<div class="flex items-center gap-2">
									<span>Monthly membership fee</span>
									<Tooltip.Provider>
										<Tooltip.Root>
											<TooltipTrigger>
												<Info class="h-4 w-4" />
											</TooltipTrigger>
											<TooltipContent>Regular monthly payment starting next month</TooltipContent>
										</Tooltip.Root>
									</Tooltip.Provider>
								</div>
								<div class="flex flex-col items-end">
									{#if discountedMonthlyFeeDinero}
										<span class="font-semibold text-green-600"
										>{discountedMonthlyFeeDinero.toFormat()}</span
										>
										<span class="text-sm line-through text-muted-foreground"
										>{monthlyFeeDinero.toFormat()}</span
										>
									{:else}
										<span class="font-semibold">{monthlyFeeDinero.toFormat()}</span>
									{/if}
								</div>
							</div>
							<div class="flex justify-between items-center">
								<div class="flex items-center gap-2">
									<span>Annual membership fee</span>
									<Tooltip.Provider>
										<Tooltip.Root>
											<TooltipTrigger>
												<Info class="h-4 w-4" />
											</TooltipTrigger>
											<TooltipContent>Yearly fee charged every January 7th</TooltipContent>
										</Tooltip.Root>
									</Tooltip.Provider>
								</div>
								<div class="flex flex-col items-end">
									{#if discountedAnnualFeeDinero}
										<span class="font-semibold text-green-600"
										>{discountedAnnualFeeDinero.toFormat()}</span
										>
										<span class="text-sm line-through text-muted-foreground"
										>{annualFeeDinero.toFormat()}</span
										>
									{:else}
										<span class="font-semibold">{annualFeeDinero.toFormat()}</span>
									{/if}
								</div>
							</div>
							{#if discountPercentage}
								<div class="mt-2 p-2 bg-green-50 text-green-700 rounded-md text-sm">
									<span class="font-semibold">Discount applied: {discountPercentage}% off</span>
									{#if discountedMonthlyFeeDinero === null && discountedAnnualFeeDinero === null}
										<span class="block text-xs mt-1">(Applies to first payment only)</span>
									{:else}
										<span class="block text-xs mt-1">(Applies to all future payments)</span>
									{/if}
								</div>
							{/if}
							{#if couponCode && applyCoupon.isSuccess}
								<small class="text-sm text-green-600">Code {couponCode} applied</small>
							{/if}

							<Accordion.Root class="mt-2" type="single">
								<Accordion.Item value="promo-code">
									<Accordion.Trigger>Have a promotional code?</Accordion.Trigger>
									<Accordion.Content>
										<div class="pt-2 px-2">
											<Input
												type="text"
												placeholder="Enter promotional code"
												class={applyCoupon.status === 'error'
													? 'border-red-500 w-full bg-white'
													: 'w-full bg-white'}
												bind:value={couponCode}
											/>
											{#if applyCoupon.status === 'error'}
												<p class="text-red-500">{applyCoupon.error.message}</p>
											{/if}
											<Button
												disabled={couponCode === '' || applyCoupon.isPending}
												variant="outline"
												class="mt-2 w-full bg-white"
												type="button"
												onclick={() => applyCoupon.mutate(couponCode)}
											>Apply Code
												{#if applyCoupon.isPending}
													<LoaderCircle class="animate-spin ml-2 h-4 w-4" />
												{/if}
											</Button>
										</div>
									</Accordion.Content>
								</Accordion.Item>
							</Accordion.Root>
							<div class="pt-4 space-y-2">
								<div class="flex justify-between items-center text-sm text-muted-foreground">
									<span>Next monthly payment</span>
									<span>{dayjs(nextMonthlyBillingDate).format('D MMMM YYYY')}</span>
								</div>
								<div class="flex justify-between items-center text-sm text-muted-foreground">
									<span>Next annual payment</span>
									<span>{dayjs(nextAnnualBillingDate).format('D MMMM YYYY')}</span>
								</div>
							</div>
						</div>
					</Card.Content>
				</Card.Root>

				{#if !stripe}
					<Skeleton class="h-96" />
				{:else}
					<!-- Stripe Elements mounting div inside the :then block -->
					<div class="mt-4" id="payment-element"></div>
				{/if}
			{:catch error}
				<!-- Error state -->
				<Card.Root class="bg-destructive/10 border-destructive">
					<Card.Content class="pt-6">
						<div class="flex flex-col items-center justify-center h-48 text-destructive">
							<AlertTriangle class="h-8 w-8 mb-2" />
							<span class="font-semibold">Error loading pricing information</span>
							<span class="text-sm mt-1">{error.message}</span>
							<span class="text-xs mt-2">Please try refreshing the page or contact support.</span>
						</div>
					</Card.Content>
				</Card.Root>
			{/await}
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
