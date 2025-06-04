<script lang="ts">
	import Dinero from 'dinero.js';
	import type { PlanPricing } from '$lib/types.js';
	import * as Card from '$lib/components/ui/card';
	import * as Tooltip from '$lib/components/ui/tooltip';
	import * as Accordion from '$lib/components/ui/accordion';
	import { Input } from '$lib/components/ui/input';
	import { Button } from '$lib/components/ui/button';
	import { Info, AlertTriangle } from 'lucide-svelte';
	import LoaderCircle from '$lib/components/ui/loader-circle.svelte';
	import dayjs from 'dayjs';
	import type { CreateMutationResult, CreateQueryResult } from '@tanstack/svelte-query';

	let {
		planPricingData,
		couponCode = $bindable(''),
		applyCoupon,
		nextMonthlyBillingDate,
		nextAnnualBillingDate
	}: {
		planPricingData: CreateQueryResult<PlanPricing, Error>;
		couponCode: string | undefined;
		applyCoupon: CreateMutationResult<string, Error, string>;
		nextMonthlyBillingDate: Date;
		nextAnnualBillingDate: Date;
	} = $props();

	let stripeClass = $derived(`mt-4 ${planPricingData.isLoading ? 'hidden' : ''}`);
</script>

{#if planPricingData.isLoading}
	<!-- Loading state -->
	<Card.Root class="bg-muted">
		<Card.Content class="pt-6">
			<div class="flex items-center justify-center h-48">
				<LoaderCircle class="text-primary animate-spin" />
				<span class="ml-2">Loading pricing information...</span>
			</div>
		</Card.Content>
	</Card.Root>
{:else if !(planPricingData as CreateQueryResult<PlanPricing, Error>).isError}
	<!-- Handle QueryResult -->
	{@const planPricing = (planPricingData as CreateQueryResult<PlanPricing, Error>).data!}
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

	<!-- Calculate the visual display price for 'once' coupons -->
	{@const displayProratedPriceDinero =
		Boolean(discountPercentage) &&
		discountedMonthlyFeeDinero === null &&
		discountedAnnualFeeDinero === null
			? Dinero({
					amount: Math.round(
						(proratedPriceDinero.getAmount() * (100 - (discountPercentage ?? 0))) / 100
					),
					currency: proratedPriceDinero.getCurrency()
				})
			: proratedPriceDinero}

	<Card.Root class="bg-muted">
		<Card.Content class="pt-6">
			<div class="space-y-4">
				<div class="flex justify-between items-center">
					<div class="flex items-center gap-2">
						<span>Pro-rated amount (first payment)</span>
						<Tooltip.Provider>
							<Tooltip.Root>
								<Tooltip.Trigger>
									<Info class="h-4 w-4" />
								</Tooltip.Trigger>
								<Tooltip.Content>
									This is the initial amount charged today, covering the rest of the current month
									and the annual fee.
								</Tooltip.Content>
							</Tooltip.Root>
						</Tooltip.Provider>
					</div>
					<span class="font-semibold">{displayProratedPriceDinero.toFormat()}</span>
				</div>
				<div class="flex justify-between items-center">
					<div class="flex items-center gap-2">
						<span>Monthly membership fee</span>
						<Tooltip.Provider>
							<Tooltip.Root>
								<Tooltip.Trigger>
									<Info class="h-4 w-4" />
								</Tooltip.Trigger>
								<Tooltip.Content>Regular monthly payment starting next month</Tooltip.Content>
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
								<Tooltip.Trigger>
									<Info class="h-4 w-4" />
								</Tooltip.Trigger>
								<Tooltip.Content>Yearly fee charged every January 7th</Tooltip.Content>
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
{:else if (planPricingData as CreateQueryResult<PlanPricing, Error>).isLoading}
	<!-- Loading state for QueryResult -->
	<Card.Root class="bg-muted">
		<Card.Content class="pt-6">
			<div class="flex items-center justify-center h-48">
				<LoaderCircle class="text-primary animate-spin" />
				<span class="ml-2">Loading pricing information...</span>
			</div>
		</Card.Content>
	</Card.Root>
{:else if (planPricingData as CreateQueryResult<PlanPricing, Error>).isError}
	<!-- Error state for QueryResult -->
	<Card.Root class="bg-destructive/10 border-destructive">
		<Card.Content class="pt-6">
			<div class="flex flex-col items-center justify-center h-48 text-destructive">
				<AlertTriangle class="h-8 w-8 mb-2" />
				<span class="font-semibold">Error loading pricing information</span>
				<span class="text-sm mt-1">{planPricingData?.error?.message}</span>
				<span class="text-xs mt-2">Please try refreshing the page.</span>
			</div>
		</Card.Content>
	</Card.Root>
{:else}
	<!-- Fallback for other cases -->
	<Card.Root class="bg-muted">
		<Card.Content class="pt-6">
			<div class="flex items-center justify-center h-48">
				<span>No pricing information available</span>
			</div>
		</Card.Content>
	</Card.Root>
{/if}
<div class={stripeClass} id="payment-element"></div>
