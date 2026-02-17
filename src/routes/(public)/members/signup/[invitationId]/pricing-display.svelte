<script lang="ts">
import dayjs from "dayjs";
import advancedFormat from "dayjs/plugin/advancedFormat";
import Dinero from "dinero.js";
import { AlertTriangle } from "lucide-svelte";
import * as Accordion from "$lib/components/ui/accordion";
import { Button } from "$lib/components/ui/button";
import * as Card from "$lib/components/ui/card";
import { Input } from "$lib/components/ui/input";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import { applyCoupon, getPricingDetail } from "./pricing.remote";

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
</script>

{#await getPricingDetail({invitationId, code: currentCoupon})}
    <!-- Loading state -->
    <Card.Root class="bg-muted">
        <Card.Content class="pt-6">
            <div class="flex items-center justify-center h-48">
                <LoaderCircle class="text-primary animate-spin"/>
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

    <!-- Calculate the visual display price for 'once' coupons -->
    {@const displayProratedPriceDinero =
        Boolean(discountPercentage) &&
        discountedMonthlyFeeDinero === null &&
        discountedAnnualFeeDinero === null
            ? Dinero({
                amount: Math.round(
                    (proratedPriceDinero.getAmount() *
                        (100 - (discountPercentage ?? 0))) /
                    100,
                ),
                currency: proratedPriceDinero.getCurrency(),
            })
            : proratedPriceDinero}

    <Card.Root class="bg-muted">
        <Card.Content class="pt-6">
            <div class="space-y-4">
                <div class="flex justify-between items-center">
                    <div class="flex flex-col items-start">
                        <span>Monthly membership fee</span>
                        <small class="text-sm text-gray-500"
                        >Regular monthly payment starting next {dayjs(
                            nextMonthlyBillingDate,
                        ).format("MMMM [the] Do, YYYY")}</small
                        >
                    </div>
                    <div class="flex flex-col items-end">
                        {#if discountedMonthlyFeeDinero}
							<span class="font-semibold text-green-600"
                            >{discountedMonthlyFeeDinero.toFormat()}</span
                            >
                            <span
                                    class="text-sm line-through text-muted-foreground"
                            >{monthlyFeeDinero.toFormat()}</span
                            >
                        {:else}
							<span class="font-semibold"
                            >{monthlyFeeDinero.toFormat()}</span
                            >
                        {/if}
                    </div>
                </div>
                <div class="flex justify-between items-center">
                    <div class="flex flex-col items-start">
                        <span>Annual membership fee</span>
                        <small class="text-sm text-gray-500"
                        >Fee charged every year, starting next {dayjs(
                            nextAnnualBillingDate,
                        ).format("MMMM [the] Do, YYYY")}</small
                        >
                    </div>
                    <div class="flex flex-col items-end">
                        {#if discountedAnnualFeeDinero}
							<span class="font-semibold text-green-600"
                            >{discountedAnnualFeeDinero.toFormat()}</span
                            >
                            <span
                                    class="text-sm line-through text-muted-foreground"
                            >{annualFeeDinero.toFormat()}</span
                            >
                        {:else}
							<span class="font-semibold"
                            >{annualFeeDinero.toFormat()}</span
                            >
                        {/if}
                    </div>
                </div>
                <div class="flex justify-between items-center m-0">
                    <div class="flex items-start flex-col">
                        <span>First payment</span>
                        <small class="text-sm text-gray-500">
                            This is the initial amount charged today, covering
                            the rest of the current month and the annual fee.</small
                        >
                    </div>
                </div>
                <div class="flex justify-between items-center p-4 text-sm m-0">
                    <div class="flex items-start flex-col mr-4">
                        <span>Pro-rated monthly fee</span>
                        <small class="text-xs text-gray-500">
                            This is the pro-rated monthly fee covering from
                            today to the rest of the month</small
                        >
                    </div>
                    <span class="font-semibold text-sm"
                    >{proratedMonthlyPrice.toFormat()}</span
                    >
                </div>
                <div class="flex justify-between items-center p-4 text-sm m-0">
                    <div class="flex items-start flex-col mr-4">
                        <span>Pro-rated annual fee</span>
                        <small class="text-xs text-gray-500">
                            This is the pro-rated annual fee covering from today
                            to the rest of the year</small
                        >
                    </div>
                    <span class="font-semibold text-sm"
                    >{proratedAnnualPrice.toFormat()}</span
                    >
                </div>
                <div class="flex justify-between items-center p-4 text-sm m-0">
                    <div class="flex items-start flex-col mr-4">
                        <span>Total</span>
                    </div>
                    <span class="font-semibold text-sm"
                    >{displayProratedPriceDinero.toFormat()}</span
                    >
                </div>
                {#if discountPercentage}
                    <div
                            class="mt-2 p-2 bg-green-50 text-green-700 rounded-md text-sm"
                    >
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
                {#if currentCoupon && !applyCoupon.pending}
                    <small class="text-sm text-green-600"
                    >Code {currentCoupon} applied</small
                    >
                {/if}

                <Accordion.Root class="mt-2" type="single">
                    <Accordion.Item value="promo-code">
                        <Accordion.Trigger
                        >Have a promotional code?
                        </Accordion.Trigger
                        >
                        <Accordion.Content>
                            <div class="pt-2 px-2">
                                <Input
                                        type="text"
                                        placeholder="Enter promotional code"
                                        class={applyCouponError
										? "border-red-500 w-full bg-white"
										: "w-full bg-white"}
                                        bind:value={currentCoupon}
                                />
                                {#if applyCouponError}
                                    <p class="text-red-500">
                                        {applyCouponError}
                                    </p>
                                {/if}
                                <Button
                                        disabled={currentCoupon === "" ||
										!!applyCoupon.pending}
                                        variant="outline"
                                        class="mt-2 w-full bg-white"
                                        type="button"
                                        onclick={() =>
										{
                                            applyCouponError = null;
                                            applyCoupon({invitationId, code: currentCoupon}).catch(err => (applyCouponError = err.message))
										}}
                                >Apply Code
                                    {#if !!applyCoupon.pending}
                                        <LoaderCircle
                                                class="animate-spin ml-2 h-4 w-4"
                                        />
                                    {/if}
                                </Button>
                            </div>
                        </Accordion.Content>
                    </Accordion.Item>
                </Accordion.Root>
            </div>
        </Card.Content>
    </Card.Root>
{:catch error}
    <Card.Root class="bg-destructive/10 border-destructive">
        <Card.Content class="pt-6">
            <div
                    class="flex flex-col items-center justify-center h-48 text-destructive"
            >
                <AlertTriangle class="h-8 w-8 mb-2"/>
                <span class="font-semibold"
                >Error loading pricing information</span
                >
                <span class="text-sm mt-1"
                >{error?.message}</span
                >
                <span class="text-xs mt-2">Please try refreshing the page.</span
                >
            </div>
        </Card.Content>
    </Card.Root>
{/await}
<div class={'mt-4'} id="payment-element"></div>
