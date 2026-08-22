<script lang="ts">
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import { Label } from "$lib/components/ui/label";
import * as Alert from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import * as RadioGroup from "$lib/components/ui/radio-group/index.js";
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
import { untrack } from "svelte";
import type {
	MembershipReactivateAnnualFeeMode,
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

// ALE-253: how the annual membership fee begins — charged prorated now, or
// deferred to next January's anchor behind a free trial.
type AnnualFeeMode = MembershipReactivateAnnualFeeMode;

function isAnnualFeeMode(value: string): value is AnnualFeeMode {
	return value === "prorated_now" || value === "deferred_next_year";
}

type Props = {
	open: boolean;
	onConfirm: ({
		startDate,
		annualFeeMode,
	}: {
		startDate: string;
		annualFeeMode: AnnualFeeMode;
	}) => void;
	isPending: boolean;
	savedPaymentMethod?: SavedPaymentMethod | null;
	isLoadingPreview?: boolean;
	/** The saved-method preview itself failed to load (e.g. Stripe 502). */
	previewError?: boolean;
	errorDetail?: string | null;
	paymentMethodUnavailable?: boolean;
	onOpenBillingPortal?: () => void;
	/** Stripe-computed reactivation amounts; hidden on failure. */
	amounts?: ReactivationAmounts | null;
	isLoadingAmounts?: boolean;
	/** Optional initial selection when the caller already has a requested date. */
	initialStartDate?: DateValue;
	/** Reports start date + annual fee mode so the container can fetch amounts. */
	onSelectionChange?: (selection: {
		startDate: string;
		annualFeeMode: AnnualFeeMode;
	}) => void;
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
	initialStartDate,
	onSelectionChange,
}: Props = $props();

// The server accepts today up to one year ahead (Membership's
// @max_start_date_days_ahead); the picker enforces the same window.
const MAX_START_DAYS_AHEAD = 366;

const minDate = $derived(today(getLocalTimeZone()));
const maxDate = $derived(minDate.add({ days: MAX_START_DAYS_AHEAD }));
// Fresh per mount: the page mounts the modal inside {#if} only while open.
let selectedDate = $state<DateValue>(
	untrack(() => initialStartDate ?? today(getLocalTimeZone())),
);
// ALE-253: default keeps the initial-release semantics (annual charged
// prorated for the remainder of this year).
let annualFeeMode = $state<AnnualFeeMode>("prorated_now");

const startDateIso = $derived(toCalendarDate(selectedDate).toString());
const deferredAnnual = $derived(annualFeeMode === "deferred_next_year");
const futureStart = $derived(dayjs(startDateIso).isAfter(dayjs(), "day"));
const formattedStartDate = $derived(dayjs(startDateIso).format("D MMM YYYY"));
const nextMonthlyBillingDate = $derived(
	dayjs(startDateIso).add(1, "month").startOf("month").format("D MMM YYYY"),
);
const nextAnnualBillingDate = $derived.by(() => {
	const now = dayjs();
	const thisJanuary = dayjs(`${now.year()}-01-07`);
	return (
		thisJanuary.isAfter(now, "day") ? thisJanuary : thisJanuary.add(1, "year")
	).format("D MMM YYYY");
});
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
	onConfirm({ startDate: startDateIso, annualFeeMode });
}

// The container fetches Stripe-computed amounts for the selection; the query
// key changes with either field, so this fires on mount and on every change.
$effect(() => {
	onSelectionChange?.({ startDate: startDateIso, annualFeeMode });
});

function handleModeChange(value: string) {
	if (isAnnualFeeMode(value)) {
		annualFeeMode = value;
	}
}

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
	<!-- ALE-253 grew this dialog taller than some viewports: keep the whole
	     content scrollable so the confirm footer stays reachable. -->
	<Dialog.Content class="max-h-[85vh] overflow-y-auto">
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
						Billing starts on this date. The first monthly charge is prorated
						from this date to the first of the following month, then full months
						bill from there.
						{deferredAnnual
							? "The annual fee isn’t charged today; annual billing begins next January."
							: "The annual fee is charged prorated for the rest of this year."}
						Allowed window: {dayjs().format("MMM D, YYYY")} to {dayjs()
							.add(MAX_START_DAYS_AHEAD, "day")
							.format("MMM D, YYYY")}.
					</p>
				</div>

				<fieldset class="space-y-2">
					<legend class="text-sm font-medium">Annual fee</legend>
					<RadioGroup.Root
						name="annualFeeMode"
						class="grid gap-2"
						value={annualFeeMode}
						onValueChange={handleModeChange}
					>
						<Label
							for="annual-fee-prorated-now"
							class="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-border/80 p-3 transition-colors hover:bg-muted/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
						>
							<RadioGroup.Item
								value="prorated_now"
								id="annual-fee-prorated-now"
								class="mt-0.5"
							/>
							<span>
								<span class="block font-medium">Charge now, prorated</span>
								<span
									class="mt-0.5 block text-sm font-normal text-muted-foreground"
								>
									The annual fee is charged prorated for the rest of this year,
									then renews each January.
								</span>
							</span>
						</Label>
						<Label
							for="annual-fee-deferred"
							class="flex min-h-12 cursor-pointer items-start gap-3 rounded-xl border border-border/80 p-3 transition-colors hover:bg-muted/50 has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5"
						>
							<RadioGroup.Item
								value="deferred_next_year"
								id="annual-fee-deferred"
								class="mt-0.5"
							/>
							<span>
								<span class="block font-medium">Defer until next January</span>
								<span
									class="mt-0.5 block text-sm font-normal text-muted-foreground"
								>
									Nothing is charged today. Annual billing begins next January.
								</span>
							</span>
						</Label>
					</RadioGroup.Root>
				</fieldset>

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
							<div class="space-y-4">
								<div class="flex items-start justify-between gap-4">
									<div>
										<p class="font-semibold">Due today</p>
										{#if futureStart}
											<p class="mt-1 text-xs leading-5 text-muted-foreground">
												{formatMoney(amounts.proratedAnnualPrice)} for this year
											</p>
										{:else}
											<p class="mt-1 text-xs leading-5 text-muted-foreground">
												{formatMoney(amounts.proratedMonthlyPrice)} for this month
												+
												{formatMoney(amounts.proratedAnnualPrice)} for this year
											</p>
										{/if}
									</div>
									<span class="text-lg font-bold"
										>{formatMoney(amounts.dueToday)}</span
									>
								</div>

								{#if futureStart}
									<div
										class="flex items-start justify-between gap-4 border-t border-border/70 pt-4"
									>
										<div>
											<p class="text-sm font-medium">
												Due on {formattedStartDate}
											</p>
											<p class="mt-1 text-xs text-muted-foreground">
												First prorated monthly charge
											</p>
										</div>
										<span class="font-semibold"
											>{formatMoney(amounts.proratedMonthlyPrice)}</span
										>
									</div>
								{/if}

								<div
									class="grid gap-3 border-t border-border/70 pt-4 sm:grid-cols-2"
								>
									<div>
										<p class="text-sm font-medium">Then monthly</p>
										<p class="mt-1 font-semibold">
											{formatMoney(amounts.monthlyFee)}
										</p>
										<p class="mt-1 text-xs text-muted-foreground">
											From {nextMonthlyBillingDate}
										</p>
									</div>
									<div>
										<p class="text-sm font-medium">Then annually</p>
										<p class="mt-1 font-semibold">
											{formatMoney(amounts.annualFee)}
										</p>
										<p class="mt-1 text-xs text-muted-foreground">
											From {nextAnnualBillingDate}
										</p>
									</div>
								</div>
							</div>
							<p class="mt-2 text-xs leading-4 text-muted-foreground">
								Computed by Stripe: monthly billing is prorated from the
								selected start date to the first of the following month, then
								renews on the first of each month;
								{deferredAnnual
									? "the annual fee first bills at next January’s renewal date and renews each year after."
									: "the annual fee is charged prorated for the rest of this year and renews each January."}
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
