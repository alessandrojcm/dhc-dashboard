<script lang="ts">
import { Button } from "#lib/components/ui/button/index.js";
import * as Dialog from "#lib/components/ui/dialog/index.js";
import { Label } from "#lib/components/ui/label/index.js";
import * as Alert from "#lib/components/ui/alert/index.js";
import { Badge } from "#lib/components/ui/badge/index.js";
import * as RadioGroup from "#lib/components/ui/radio-group/index.js";
import DatePicker from "#lib/components/ui/date-picker.svelte";
import LoaderCircle from "#lib/components/ui/loader-circle.svelte";
import CreditCard from "@lucide/svelte/icons/credit-card";
import ExternalLink from "@lucide/svelte/icons/external-link";
import TriangleAlert from "@lucide/svelte/icons/triangle-alert";
import type { DateValue } from "@internationalized/date";
import {
	civilCalendarDate,
	civilIsoDate,
	formatCivilDate,
} from "#lib/club-calendar.js";
import {
	isFutureStart,
	reactivationStartWindow,
	type ReactivationStartWindow,
} from "#lib/membership/reactivation-start-window.js";
import type {
	AnnualFeeMode,
	ReactivationSelection,
	ReactivationView,
} from "#lib/membership/reactivation-machine.js";
import Dinero from "dinero.js";
import { untrack } from "svelte";
import type { MembershipReactivationPreviewAmountsResponse } from "@dhc/api-client";

/**
 * Presentational reactivation dialog (ALE-450). It renders one phase of
 * `reactivationMachine` (through `reactivationView`) and reports the
 * operator's intents; the machine owns the protocol and the selection.
 * Mounted only while the dialog is open.
 */

// Mirrors the Stripe-computed amounts projected by
// GET /members/{memberId}/membership/reactivation-preview/amounts (ALE-254).
type ReactivationAmounts = MembershipReactivationPreviewAmountsResponse["data"];

function isAnnualFeeMode(value: string): value is AnnualFeeMode {
	return value === "prorated_now" || value === "deferred_next_year";
}

type Props = {
	view: ReactivationView;
	/** Start date + annual fee mode, owned by the machine. */
	selection: ReactivationSelection;
	/** The start dates to offer; read once by the host for the machine too. */
	startWindow?: ReactivationStartWindow;
	/** Stripe-computed reactivation amounts; hidden on failure. */
	amounts?: ReactivationAmounts | null;
	isLoadingAmounts?: boolean;
	onSelect: (selection: ReactivationSelection) => void;
	onConfirm: () => void;
	onOpenBillingPortal: () => void;
	/** The operator asked to dismiss the dialog. */
	onClose: () => void;
};

let {
	view,
	selection,
	startWindow = untrack(() => reactivationStartWindow()),
	amounts = null,
	isLoadingAmounts = false,
	onSelect,
	onConfirm,
	onOpenBillingPortal,
	onClose,
}: Props = $props();

// Phoenix accepts a start date from its (UTC) today up to 366 days ahead;
// the window module reconciles that with Dublin's today.
const minDate = $derived(startWindow.earliest);
const maxDate = $derived(startWindow.latest);
const selectedDate = $derived<DateValue>(
	civilCalendarDate(selection.startDate) ?? startWindow.earliest,
);

const membershipCoverage = $derived(view.coverage);
const isPending = $derived(view.phase === "ready" && view.submitting);
const startDateIso = $derived(civilIsoDate(selectedDate));
const deferredAnnual = $derived(
	selection.annualFeeMode === "deferred_next_year",
);
const monthlyActive = $derived(membershipCoverage.monthly === "active");
const annualActive = $derived(membershipCoverage.annual === "active");
const completeCoverage = $derived(monthlyActive && annualActive);
const futureStart = $derived(isFutureStart(startDateIso));
const formattedStartDate = $derived(formatCivilDate(startDateIso));

function handleConfirm(event: Event) {
	event.preventDefault();
	event.stopPropagation();
	onConfirm();
}

function handleModeChange(value: string) {
	if (isAnnualFeeMode(value)) {
		onSelect({ startDate: selection.startDate, annualFeeMode: value });
	}
}

function formatMoney(money: ReactivationAmounts["dueToday"]) {
	// SAFETY: dinero.js narrows currency to an ISO-4217 literal union while
	// the API type keeps `string`; the server pins the currency to EUR, so
	// every value reaching here satisfies the narrower union.
	return Dinero(money as Dinero.DineroObject).toFormat();
}

function handleDateChange(date: DateValue | undefined) {
	if (date)
		onSelect({
			startDate: civilIsoDate(date),
			annualFeeMode: selection.annualFeeMode,
		});
}
</script>

<!-- Open for as long as the host mounts it; a dismissal is a request the
     machine may refuse (while a charge is being submitted). -->
<Dialog.Root
	bind:open={
		() => true,
		(open) => {
			if (!open) onClose();
		}
	}
>
	<!-- ALE-253 grew this dialog taller than some viewports: keep the whole
	     content scrollable so the confirm footer stays reachable. -->
	<Dialog.Content class="max-h-[85vh] overflow-y-auto">
		<Dialog.Header>
			<Dialog.Title>Reactivate membership</Dialog.Title>
			<Dialog.Description>
				{#if completeCoverage}
					Stripe already reports both membership subscriptions as active.
					Nothing will be recreated or charged.
				{:else if monthlyActive}
					Keeps the active monthly subscription unchanged and reactivates only
					the annual subscription using the member’s saved SEPA payment method.
				{:else if annualActive}
					Keeps the active annual subscription unchanged and reactivates only
					the monthly subscription using the member’s saved SEPA payment method.
				{:else}
					Starts new monthly and annual membership subscriptions, charged
					automatically to the member’s saved SEPA payment method. They don’t
					need to enter their bank details again.
				{/if}
			</Dialog.Description>
		</Dialog.Header>

		{#if view.phase === "lookingUp"}
			<div class="flex items-center gap-2 text-sm text-muted-foreground">
				<LoaderCircle class="size-4 animate-spin" />
				Checking saved payment method…
			</div>
		{:else if view.phase === "lookupFailed"}
			<Alert.Root variant="destructive">
				<TriangleAlert />
				<Alert.Title>Could not check the saved payment method</Alert.Title>
				<Alert.Description>
					The saved payment method could not be loaded. Close this dialog and
					try again; nothing has been charged.
				</Alert.Description>
			</Alert.Root>
		{:else if view.phase === "noSavedMethod"}
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
			<Button
				variant="outline"
				class="w-full"
				disabled={view.openingPortal}
				onclick={onOpenBillingPortal}
			>
				Open billing portal
				<ExternalLink class="size-4" aria-hidden="true" />
			</Button>
		{:else if view.phase === "ready"}
			{@const savedPaymentMethod = view.method}
			<div class="space-y-4">
				<div class="grid gap-2 sm:grid-cols-2" aria-label="Membership coverage">
					<div
						class="rounded-xl border border-border/80 p-3"
						data-testid="monthly-coverage"
					>
						<p class="text-sm font-medium">Monthly subscription</p>
						<p class="mt-1 text-xs text-muted-foreground">
							{monthlyActive
								? "Already active, kept unchanged"
								: "Will be reactivated"}
						</p>
					</div>
					<div
						class="rounded-xl border border-border/80 p-3"
						data-testid="annual-coverage"
					>
						<p class="text-sm font-medium">Annual subscription</p>
						<p class="mt-1 text-xs text-muted-foreground">
							{annualActive
								? "Already active, kept unchanged"
								: "Will be reactivated"}
						</p>
					</div>
				</div>

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
						onValueChange={handleDateChange}
					/>
					<p class="text-xs leading-4 text-muted-foreground">
						Billing starts on this date.
						{#if !monthlyActive}
							The first monthly charge is prorated from this date to the first
							of the following month, then full months bill from there.
						{/if}
						{#if !annualActive}
							{deferredAnnual
								? "The annual fee isn’t charged today; annual billing begins next January."
								: "The annual fee is charged prorated for the rest of this year."}
						{/if}
						Allowed window: {formatCivilDate(minDate.toString())} to {formatCivilDate(
							maxDate.toString(),
						)}.
					</p>
				</div>

				{#if !annualActive}
					<fieldset class="space-y-2">
						<legend class="text-sm font-medium">Annual fee</legend>
						<RadioGroup.Root
							name="annualFeeMode"
							class="grid gap-2"
							value={selection.annualFeeMode}
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
										The annual fee is charged prorated for the rest of this
										year, then renews each January.
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
									<span class="block font-medium">Defer until next January</span
									>
									<span
										class="mt-0.5 block text-sm font-normal text-muted-foreground"
									>
										Nothing is charged today. Annual billing begins next
										January.
									</span>
								</span>
							</Label>
						</RadioGroup.Root>
					</fieldset>
				{/if}

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
										{#if monthlyActive}
											<p class="mt-1 text-xs leading-5 text-muted-foreground">
												{formatMoney(amounts.proratedAnnualPrice)} for this year
											</p>
										{:else if annualActive}
											<p class="mt-1 text-xs leading-5 text-muted-foreground">
												{futureStart
													? "Monthly billing begins on the selected start date"
													: `${formatMoney(amounts.proratedMonthlyPrice)} for this month`}
											</p>
										{:else if futureStart}
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

								{#if futureStart && !monthlyActive}
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
									{#if !monthlyActive}
										<div>
											<p class="text-sm font-medium">Then monthly</p>
											<p class="mt-1 font-semibold">
												{formatMoney(amounts.monthlyFee)}
											</p>
											<p class="mt-1 text-xs text-muted-foreground">
												From {formatCivilDate(amounts.monthlyBillingStart)}
											</p>
										</div>
									{/if}
									{#if !annualActive}
										<div>
											<p class="text-sm font-medium">Then annually</p>
											<p class="mt-1 font-semibold">
												{formatMoney(amounts.annualFee)}
											</p>
											<p class="mt-1 text-xs text-muted-foreground">
												From {formatCivilDate(amounts.annualBillingStart)}
											</p>
										</div>
									{/if}
								</div>
							</div>
							<p class="mt-2 text-xs leading-4 text-muted-foreground">
								Computed by Stripe for the subscription{monthlyActive ||
								annualActive
									? ""
									: "s"} being reactivated.
								{#if !monthlyActive}
									Monthly billing is prorated from the selected start date to
									the first of the following month, then renews on the first of
									each month.
								{/if}
								{#if !annualActive}
									{deferredAnnual
										? "The annual fee first bills at next January’s renewal date and renews each year after."
										: "The annual fee is charged prorated for the rest of this year and renews each January."}
								{/if}
							</p>
						{/if}
					</div>
				{/if}

				{#if view.problem}
					<Alert.Root variant="destructive">
						<TriangleAlert />
						<Alert.Title>Reactivation failed</Alert.Title>
						<Alert.Description>{view.problem}</Alert.Description>
					</Alert.Root>
				{/if}
			</div>
		{/if}

		<Dialog.Footer>
			<Button
				type="button"
				variant="outline"
				onclick={onClose}
				disabled={isPending}
			>
				Cancel
			</Button>
			<Button
				type="button"
				onclick={handleConfirm}
				disabled={view.phase !== "ready" || isPending || completeCoverage}
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
