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
	let stripe: Awaited<ReturnType<typeof loadStripe>> | null = $state(null);
	let elements: StripeElements | null | undefined = $state(null);
	let paymentElement: StripePaymentElement | null | undefined = $state(null);
	let showThanks = $state(false);
	let couponCode = $state('');

	const { planPricing, nextMonthlyBillingDate, nextAnnualBillingDate } = data;

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
		// customerSessionClientSecret: customerSessionId!
	};

	const form = superForm(data.form, {
		validators: valibotClient(memberSignupSchema),
		invalidateAll: false,
		resetForm: false,
		validationMethod: 'onblur',
		scrollToError: 'smooth',
		onSubmit: async function ({ cancel, customRequest }) {
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
	const { form: formData, enhance, submitting, errors } = form;
	const formatedPhone = $derived.by(() => new AsYouType('IE').input(data.userData.phoneNumber!));
	const planData = createQuery(() => ({
		queryKey: ['plan-pricing'],
		queryFn: ({ signal }) =>
			fetch('/api/signup/plan-pricing', { signal }).then(
				(res) => res.json() as unknown as PlanPricing
			),
		initialData: planPricing,
		refetchOnMount: false
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
	const proratedPriceDinero = $derived(Dinero(planData.data!.proratedPrice));
	const monthlyFeeDinero = $derived(Dinero(planData.data!.monthlyFee));
	const annualFeeDinero = $derived(Dinero(planData.data!.annualFee));

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
			paymentElement?.mount('#payment-element');
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
											This is the combined prorated amount for your first month's membership and
											annual fee
										</TooltipContent>
									</Tooltip.Root>
								</Tooltip.Provider>
							</div>
							<span class="font-semibold">{proratedPriceDinero.toFormat()}</span>
						</div>
						<div class="flex justify-between items-center">
							<div class="flex items-center gap-2">
								<span>Monthly membership fee</span>
								<TooltipProvider>
									<Tooltip.Root>
										<TooltipTrigger>
											<Info class="h-4 w-4" />
										</TooltipTrigger>
										<TooltipContent>Regular monthly payment starting next month</TooltipContent>
									</Tooltip.Root>
								</TooltipProvider>
							</div>
							<span class="font-semibold">{monthlyFeeDinero.toFormat()}</span>
						</div>
						<div class="flex justify-between items-center">
							<div class="flex items-center gap-2">
								<span>Annual membership fee</span>
								<TooltipProvider>
									<Tooltip.Root>
										<TooltipTrigger>
											<Info class="h-4 w-4" />
										</TooltipTrigger>
										<TooltipContent>Yearly fee charged every January 7th</TooltipContent>
									</Tooltip.Root>
								</TooltipProvider>
							</div>
							<span class="font-semibold">{annualFeeDinero.toFormat()}</span>
						</div>

						<Accordion.Root class="mt-2" type="single">
							<Accordion.Item value="promo-code">
								<Accordion.Trigger>Have a promotional code?</Accordion.Trigger>
								<Accordion.Content>
									<div class="pt-2 px-2">
										<Input
											type="text"
											placeholder="Enter promotional code"
											class={applyCoupon.status === 'error' ? 'border-red-500 w-full bg-white' : 'w-full bg-white'}
											bind:value={couponCode}
										/>
										{#if applyCoupon.status === 'error'}
											<p class="text-red-500">{applyCoupon.error.message}</p>
										{/if}
										<Button
											disabled={couponCode === ''}
											variant="outline"
											class="mt-2 w-full bg-white"
											type="button"
											onclick={() => applyCoupon.mutate(couponCode)}
											>Apply Code
											{#if applyCoupon.status === 'pending'}
												<LoaderCircle />
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
			<div id="payment-element"></div>
			{#if !stripe}
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
