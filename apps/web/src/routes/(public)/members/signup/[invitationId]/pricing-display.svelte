<script lang="ts">
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import Dinero from "dinero.js";
import * as Alert from "$lib/components/ui/alert";
import * as Accordion from "$lib/components/ui/accordion";
import { Button } from "$lib/components/ui/button";
import * as Card from "$lib/components/ui/card";
import { Input } from "$lib/components/ui/input";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { getPricingDetail } from "./pricing.remote";

dayjs.extend(advancedFormat);

let {
	currentCoupon = $bindable(""),
	invitationId,
	nextMonthlyBillingDate,
	nextAnnualBillingDate,
}: {
	invitationId: string;
	currentCoupon: string | undefined;
	nextMonthlyBillingDate: Date;
	nextAnnualBillingDate: Date;
} = $props();
let applyCouponError: string | null = $state(null);
let couponCode = $state(currentCoupon ?? "");
let applyingCoupon = $state(false);

async function handleApplyCoupon() {
	applyCouponError = null;
	applyingCoupon = true;

	try {
		const code = couponCode.trim();
		await getPricingDetail({ invitationId, code });
		currentCoupon = code;
	} catch (error) {
		applyCouponError =
			error instanceof Error ? error.message : "Could not apply promotion code";
	} finally {
		applyingCoupon = false;
	}
}
</script>

{#await getPricingDetail({ invitationId, code: currentCoupon })}
	<!-- Loading state -->
	<Card.Root class="bg-muted">
		<Card.Content class="py-8">
			<div class="flex items-center justify-center">
				<LoaderCircle class="text-primary animate-spin" />
				<span class="ml-2">Loading pricing information...</span>
			</div>
		</Card.Content>
	</Card.Root>
{:then planPricing}
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
	{@const proratedMonthlyPrice = Dinero(planPricing.proratedMonthlyPrice)}
	{@const proratedAnnualPrice = Dinero(planPricing.proratedAnnualPrice)}

	<Card.Root class="bg-muted">
		<Card.Content class="py-5">
			<div class="space-y-4">
				<div class="flex items-start justify-between gap-4">
					<div>
						<p class="font-semibold">Due today</p>
						<p class="mt-1 text-xs leading-5 text-muted-foreground">
							{proratedMonthlyPrice.toFormat()} for this month +
							{proratedAnnualPrice.toFormat()} for this year
						</p>
					</div>
					<span class="text-lg font-bold">{proratedPriceDinero.toFormat()}</span
					>
				</div>

				<div class="grid gap-3 border-t border-border/70 pt-4 sm:grid-cols-2">
					<div>
						<p class="text-sm font-medium">Then monthly</p>
						<div class="mt-1 flex items-baseline gap-2">
							{#if discountedMonthlyFeeDinero}
								<span class="font-semibold text-green-600"
									>{discountedMonthlyFeeDinero.toFormat()}</span
								>
								<span class="text-xs text-muted-foreground line-through"
									>{monthlyFeeDinero.toFormat()}</span
								>
							{:else}
								<span class="font-semibold">{monthlyFeeDinero.toFormat()}</span>
							{/if}
						</div>
						<p class="mt-1 text-xs text-muted-foreground">
							From {dayjs(nextMonthlyBillingDate).format("D MMM YYYY")}
						</p>
					</div>
					<div>
						<p class="text-sm font-medium">Then annually</p>
						<div class="mt-1 flex items-baseline gap-2">
							{#if discountedAnnualFeeDinero}
								<span class="font-semibold text-green-600"
									>{discountedAnnualFeeDinero.toFormat()}</span
								>
								<span class="text-xs text-muted-foreground line-through"
									>{annualFeeDinero.toFormat()}</span
								>
							{:else}
								<span class="font-semibold">{annualFeeDinero.toFormat()}</span>
							{/if}
						</div>
						<p class="mt-1 text-xs text-muted-foreground">
							From {dayjs(nextAnnualBillingDate).format("D MMM YYYY")}
						</p>
					</div>
				</div>
				{#if discountPercentage}
					<div class="mt-2 p-2 bg-green-50 text-green-700 rounded-md text-sm">
						<span class="font-semibold"
							>Discount applied: {discountPercentage}% off</span
						>
						{#if discountedMonthlyFeeDinero === null && discountedAnnualFeeDinero === null}
							<span class="block text-xs mt-1"
								>(Applies to first payment only)</span
							>
						{:else}
							<span class="block text-xs mt-1"
								>(Applies to all future payments)</span
							>
						{/if}
					</div>
				{/if}
				{#if currentCoupon}
					<small class="text-sm text-green-600"
						>Code {currentCoupon} applied</small
					>
				{/if}

				<Accordion.Root class="mt-2" type="single">
					<Accordion.Item value="promo-code">
						<Accordion.Trigger>Have a promotional code?</Accordion.Trigger>
						<Accordion.Content>
							<div class="pt-2 px-2">
								<Input
									type="text"
									placeholder="Enter promotional code"
									class={applyCouponError
										? "border-red-500 w-full bg-white"
										: "w-full bg-white"}
									bind:value={couponCode}
								/>
								{#if applyCouponError}
									<p class="text-red-500">
										{applyCouponError}
									</p>
								{/if}
								<Button
									disabled={couponCode.trim() === "" || applyingCoupon}
									variant="outline"
									class="mt-2 w-full bg-white"
									type="button"
									onclick={handleApplyCoupon}
									>Apply Code
									{#if applyingCoupon}
										<LoaderCircle class="animate-spin ml-2 h-4 w-4" />
									{/if}
								</Button>
							</div>
						</Accordion.Content>
					</Accordion.Item>
				</Accordion.Root>
			</div>
		</Card.Content>
	</Card.Root>
{/await}
<div class="mt-4" id="payment-element"></div>
