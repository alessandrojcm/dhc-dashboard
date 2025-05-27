<script lang="ts">
	import * as Form from '$lib/components/ui/form';
	import dayjs from 'dayjs';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { superForm } from 'sveltekit-superforms';
	import { valibotClient } from 'sveltekit-superforms/adapters';
	import { memberSignupSchema } from '$lib/schemas/membersSignup';
	import { parsePhoneNumberFromString } from 'libphonenumber-js/min';
	import { ArrowRightIcon } from 'lucide-svelte';
	import {
		loadStripe,
		type StripeElements,
		type StripeElementsOptions,
		type StripePaymentElement
	} from '@stripe/stripe-js';
	import { PUBLIC_STRIPE_KEY } from '$env/static/public';
	import { toast } from 'svelte-sonner';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import * as Alert from '$lib/components/ui/alert';
	import PhoneInput from '$lib/components/ui/phone-input.svelte';
	import {
		createMutation,
		createQuery,
		keepPreviousData
	} from '@tanstack/svelte-query';
	import type { PlanPricing } from '$lib/types.js';
	import PricingDisplay from './pricing-display.svelte';
	import type { PageServerData } from './$types';
	import { page } from '$app/state';

	const props: PageServerData = $props();

	const { nextMonthlyBillingDate, nextAnnualBillingDate } = props;
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

	const form = superForm(props.form, {
		validators: valibotClient(memberSignupSchema),
		invalidateAll: false,
		resetForm: false,
		validationMethod: 'onblur',
		scrollToError: true,
		autoFocusOnError: true,
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
	const formatedPhone = $derived.by(() => parsePhoneNumberFromString(props.userData.phoneNumber!));
	const queryKey = $derived(['plan-pricing', couponCode]);

	// Keep planData query for coupon updates, but initial display uses streamed data
	const planData = createQuery(() => ({
		queryKey,
		refetchOnMount: true,
		placeholderData: keepPreviousData,
		refetchOnWindowFocus: false,
		queryFn: async () => {
			const res = await fetch(`/api/signup/plan-pricing/${page.params.invitationId}`);
			if (!res.ok) {
				throw new Error('Failed to fetch pricing');
			}
			return (await res.json()) as PlanPricing;
		}
	}));

	const applyCoupon = createMutation(() => ({
		mutationFn: (code: string) =>
			fetch(`/api/signup/coupon/${props.paymentSessionId}`, { method: 'POST', body: JSON.stringify({ code }) }).then(
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
						name: `${props.userData.firstName} ${props.userData.lastName}`,
						email: props.userData.email,
						phone: props.userData.phoneNumber
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
		<Button onclick={() => goto('/dashboard')} class="mt-2 fit-content">Go to Dashboard</Button>
	</Alert.Root>
{/snippet}
{#if showThanks}
	{@render thanksAlert()}
{:else}
	<form method="POST" class="space-y-6" use:enhance>
		<div class="grid grid-cols-2 gap-4">
			<div>
				<p>First Name</p>
				<p class="text-sm text-gray-600">{props.userData.firstName}</p>
			</div>
			<div>
				<p>Last Name</p>
				<p class="text-sm text-gray-600">{props.userData.lastName}</p>
			</div>
			<div>
				<p>Email</p>
				<p class="text-sm text-gray-600 break-words">{props.userData.email}</p>
			</div>
			<div>
				<p>Date of Birth</p>
				<p class="text-sm text-gray-600">
					{dayjs(props.userData.dateOfBirth).format('DD/MM/YYYY')}
				</p>
			</div>
			<div>
				<p>Gender</p>
				<p class="text-sm text-gray-600 capitalize">{props.userData.gender}</p>
			</div>
			<div>
				<p>Pronouns</p>
				<p class="text-sm text-gray-600 capitalize">{props.userData.pronouns}</p>
			</div>
			<div>
				<p>Phone Number</p>
				<p class="text-sm text-gray-600">{formatedPhone?.formatInternational()}</p>
			</div>
			<div>
				<p>Medical Conditions</p>
				<p class="text-sm text-gray-600">
					{!props.userData.medicalConditions ? 'N/A' : props.userData.medicalConditions}
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

			<script>
				import PricingDisplay from './pricing-display.svelte';
			</script>

			<PricingDisplay
				planPricingData={planData}
				{couponCode}
				{applyCoupon}
				{nextMonthlyBillingDate}
				{nextAnnualBillingDate}
			/>
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
