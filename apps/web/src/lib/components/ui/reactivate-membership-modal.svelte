<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import { Label } from "$lib/components/ui/label";
import * as Alert from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import DatePicker from "$lib/components/ui/date-picker.svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import CreditCard from "@lucide/svelte/icons/credit-card";
import ExternalLink from "@lucide/svelte/icons/external-link";
import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
import {
	type DateValue,
	fromDate,
	getLocalTimeZone,
	today,
	toCalendarDate,
} from "@internationalized/date";
import dayjs from "dayjs";
import Dinero from "dinero.js";
import type {
	MembershipReactivationPreviewAmountsResponse,
	MembershipReactivationPreviewResponse,
} from "@dhc/api-client";

// Mirrors the savedPaymentMethod summary projected by
// GET /members/{memberId}/membership/reactivation-preview.
type SavedPaymentMethod = NonNullable<
	MembershipReactivationPreviewResponse["data"]["savedPaymentMethod"]
>;

// Mirrors the Stripe-computed amounts projected by
// GET /members/{memberId}/membership/reactivation-preview/amounts (ALE-254).
type ReactivationAmounts = MembershipReactivationPreviewAmountsResponse["data"];

type Props = {
	open: boolean;
	onConfirm: ({ startDate }: { startDate: string }) => void;
	isPending: boolean;
	savedPaymentMethod?: SavedPaymentMethod | null;
	isLoadingPreview?: boolean;
	/** The saved-method preview itself failed to load (e.g. Stripe 502). */
	previewError?: boolean;
	errorDetail?: string | null;
	paymentMethodUnavailable?: boolean;
	onOpenBillingPortal?: () => void;
	/** Stripe-computed amounts for the selected start date; hidden on failure. */
	amounts?: ReactivationAmounts | null;
	isLoadingAmounts?: boolean;
	/** Reports the selected start date up to the container so it can fetch amounts. */
	onStartDateChange?: (startDateIso: string) => void;
};

let {
	open = $bindable(false),
	onConfirm,
	isPending,
	savedPaymentMethod,
	isLoadingPreview = false,
	previewError = false,
	errorDetail = null,
	paymentMethodUnavailable = false,
	onOpenBillingPortal,
	amounts = null,
	isLoadingAmounts = false,
	onStartDateChange,
}: Props = $props();

// The server accepts today up to one year ahead (Membership's
// @max_start_date_days_ahead); the picker enforces the same window.
const MAX_START_DAYS_AHEAD = 366;

const minDate = $derived(today(getLocalTimeZone()));
const maxDate = $derived(minDate.add({ days: MAX_START_DAYS_AHEAD }));
// Fresh per mount: the page mounts the modal inside {#if} only while open.
let selectedDate = $state<DateValue>(today(getLocalTimeZone()));

const startDateIso = $derived(toCalendarDate(selectedDate).toString());
// Distinguishes "Stripe says there is nothing to charge" (fallback applies)
// from "the preview lookup itself failed" (plain error, retry by reopening).
const methodUnavailable = $derived(
	paymentMethodUnavailable ||
		(!isLoadingPreview &&
			!previewError &&
			(savedPaymentMethod ?? null) === null),
);

function handleConfirm(event: Event) {
	event.preventDefault();
	event.stopPropagation();
	if (!selectedDate || isPending || methodUnavailable) return;
	onConfirm({ startDate: startDateIso });
}

// The container fetches Stripe-computed amounts for the selected date; the
// query key changes with it, so this fires on mount and every date change.
$effect(() => {
	onStartDateChange?.(startDateIso);
});

function formatMoney(money: ReactivationAmounts["dueToday"]) {
	// SAFETY: dinero.js narrows currency to an ISO-4217 literal union while
	// the API type keeps `string`; the server pins the currency to EUR, so
	// every value reaching here satisfies the narrower union.
	return Dinero(money as Dinero.DineroObject).toFormat();
}

function handleDateChange(date: Date) {
	selectedDate = toCalendarDate(fromDate(date, getLocalTimeZone()));
}
</script>

<Dialog.Root bind:open>
	<Dialog.Content>
		<Dialog.Header>
			<Dialog.Title>Reactivate membership</Dialog.Title>
			<Dialog.Description>
				Starts new monthly and annual membership subscriptions, charged
				automatically to the member’s saved SEPA payment method. They don’t need
				to enter their bank details again.
			</Dialog.Description>
		</Dialog.Header>

		{#if isLoadingPreview}
			<div class="flex items-center gap-2 text-sm text-muted-foreground">
				<LoaderCircle class="size-4 animate-spin" />
				Checking saved payment method…
			</div>
		{:else if previewError}
			<Alert.Root variant="destructive">
				<TriangleAlert />
				<Alert.Title>Could not check the saved payment method</Alert.Title>
				<Alert.Description>
					The saved payment method could not be loaded. Close this dialog and
					try again; nothing has been charged.
				</Alert.Description>
			</Alert.Root>
		{:else if methodUnavailable}
			<Alert.Root>
				<TriangleAlert />
				<Alert.Title>No saved payment method</Alert.Title>
				<Alert.Description>
					This member has no saved SEPA payment details to charge, so the
					subscriptions can’t be started here. Open the Stripe billing portal
					instead: the member enters their bank details and restarts the
					subscription themselves.
				</Alert.Description>
			</Alert.Root>
			{#if onOpenBillingPortal}
				<Button variant="outline" class="w-full" onclick={onOpenBillingPortal}>
					Open billing portal
					<ExternalLink class="size-4" aria-hidden="true" />
				</Button>
			{/if}
		{:else if savedPaymentMethod}
			<div class="space-y-4">
				<div
					class="flex items-center gap-3 rounded-xl border border-border/80 bg-muted/40 p-3"
					data-slot="saved-payment-method"
				>
					<div
						class="grid size-10 shrink-0 place-items-center rounded-full bg-primary/10 text-primary"
					>
						<CreditCard class="size-5" aria-hidden="true" />
					</div>
					<div class="min-w-0 flex-1">
						<p class="text-sm font-semibold">Saved SEPA Direct Debit</p>
						<p class="mt-0.5 text-sm text-muted-foreground">
							Ending in {savedPaymentMethod.last4}
						</p>
					</div>
					{#if savedPaymentMethod.country || savedPaymentMethod.bankCode}
						<Badge variant="secondary">
							{[savedPaymentMethod.country, savedPaymentMethod.bankCode]
								.filter(Boolean)
								.join(" · ")}
						</Badge>
					{/if}
				</div>

				<div class="space-y-2">
					<Label for="reactivation-start-date">Start date</Label>
					<DatePicker
						id="reactivation-start-date"
						name="startDate"
						value={selectedDate}
						minValue={minDate}
						maxValue={maxDate}
						onDateChange={handleDateChange}
					/>
					<p class="text-xs leading-4 text-muted-foreground">
						Billing starts on this date: the first invoice covers only the days
						up to it (prorated), then full months bill from there. The annual
						fee is charged prorated for the rest of this year either way.
						Allowed window: {dayjs().format("MMM D, YYYY")} – {dayjs()
							.add(MAX_START_DAYS_AHEAD, "day")
							.format("MMM D, YYYY")}.
					</p>
				</div>

				{#if amounts || isLoadingAmounts}
					<div
						class="rounded-xl border border-border/80 bg-muted/40 p-3"
						data-slot="reactivation-amounts"
						data-testid="reactivation-amounts"
					>
						{#if !amounts}
							<p
								class="flex items-center gap-2 text-sm text-muted-foreground"
								role="status"
							>
								<LoaderCircle class="size-4 animate-spin" />
								Calculating what this reactivation will charge…
							</p>
						{:else}
							<dl class="space-y-1.5 text-sm">
								<div class="flex items-baseline justify-between gap-3">
									<dt class="font-semibold">Due today</dt>
									<dd class="font-semibold">{formatMoney(amounts.dueToday)}</dd>
								</div>
								<div class="flex items-baseline justify-between gap-3">
									<dt class="text-muted-foreground">Monthly membership</dt>
									<dd>{formatMoney(amounts.monthlyFee)}</dd>
								</div>
								<div class="flex items-baseline justify-between gap-3">
									<dt class="text-muted-foreground">Annual membership</dt>
									<dd>{formatMoney(amounts.annualFee)}</dd>
								</div>
							</dl>
							<p class="mt-2 text-xs leading-4 text-muted-foreground">
								Computed by Stripe for the selected start date: the monthly fee
								starts prorated on that day, the annual fee is charged prorated
								for the rest of this year and renews each January.
							</p>
						{/if}
					</div>
				{/if}

				{#if errorDetail}
					<Alert.Root variant="destructive">
						<TriangleAlert />
						<Alert.Title>Reactivation failed</Alert.Title>
						<Alert.Description>{errorDetail}</Alert.Description>
					</Alert.Root>
				{/if}
			</div>
		{/if}

		<Dialog.Footer>
			<Button
				type="button"
				variant="outline"
				onclick={() => (open = false)}
				disabled={isPending}
			>
				Cancel
			</Button>
			<Button
				type="button"
				onclick={handleConfirm}
				disabled={isPending ||
					isLoadingPreview ||
					previewError ||
					methodUnavailable}
			>
				{#if isPending}
					<LoaderCircle class="size-4" />
				{/if}
				{isPending ? "Confirming…" : "Reactivate membership"}
			</Button>
		</Dialog.Footer>

		<p class="text-xs leading-4 text-muted-foreground" aria-live="polite">
			{#if isPending}
				Submitting the SEPA charge, awaiting bank confirmation. This usually
				takes a few business days; the membership becomes active once the bank
				confirms.
			{/if}
		</p>
	</Dialog.Content>
</Dialog.Root>
