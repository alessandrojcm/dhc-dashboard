<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import type {
	WorkshopAttendee,
	WorkshopRefund,
	WorkshopSummary,
} from "@dhc/api-client";
import {
	workshopsRefundRegistrationMutation,
	workshopsUpdateAttendanceMutation,
} from "@dhc/api-client";
import {
	TriangleAlert,
	Check,
	CheckCheck,
	CircleCheckBig,
	Clock3,
	DollarSign,
	LoaderCircle,
	Search,
	User,
	Users,
	X,
} from "@lucide/svelte";
import dayjs from "dayjs";
import { toast } from "svelte-sonner";
import * as AlertDialog from "$lib/components/ui/alert-dialog";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Checkbox } from "$lib/components/ui/checkbox";
import { Input } from "$lib/components/ui/input";
import { checkRefundEligibility } from "$lib/utils/refund-eligibility";

interface Props {
	attendees: WorkshopAttendee[];
	refunds: WorkshopRefund[];
	workshop: WorkshopSummary;
	workshopId?: string;
	onAttendanceUpdated?: () => void;
	onRefundProcessed?: () => void;
}

type AttendedUpdate = {
	registrationId: string;
	attendanceStatus: "attended";
	notes: string;
};

type AttendanceFilter = "all" | WorkshopAttendee["attendanceStatus"];

const attendanceFilters: { label: string; value: AttendanceFilter }[] = [
	{ label: "All", value: "all" },
	{ label: "Awaiting", value: "pending" },
	{ label: "Checked in", value: "attended" },
	{ label: "No show", value: "noShow" },
	{ label: "Excused", value: "excused" },
];

const touchCheckboxClass =
	"relative size-11 cursor-pointer touch-manipulation rounded-lg border-transparent bg-transparent shadow-none transition-colors hover:bg-primary/5 before:pointer-events-none before:absolute before:size-5 before:rounded-[4px] before:border-2 before:border-primary/50 before:bg-background before:shadow-xs before:content-[''] data-[state=checked]:border-transparent data-[state=checked]:bg-transparent data-[state=checked]:text-primary-foreground data-[state=checked]:before:border-primary data-[state=checked]:before:bg-primary [&_[data-slot=checkbox-indicator]]:relative [&_[data-slot=checkbox-indicator]]:z-10";

let {
	attendees,
	refunds,
	workshop,
	workshopId,
	onAttendanceUpdated,
	onRefundProcessed,
}: Props = $props();

let bulkCheckInOpen = $state(false);
let refundDialogOpen = $state(false);
let refundAttendee = $state.raw<WorkshopAttendee | undefined>(undefined);
let search = $state("");
let statusFilter = $state<AttendanceFilter>("all");
let selectedAttendees = $state<string[]>([]);

const filteredAttendees = $derived.by(() => {
	const query = search.trim().toLocaleLowerCase();

	return attendees.filter((attendee) => {
		const matchesFilter =
			statusFilter === "all" || attendee.attendanceStatus === statusFilter;
		const matchesSearch =
			query.length === 0 ||
			attendee.participant.displayName.toLocaleLowerCase().includes(query) ||
			attendee.participant.email?.toLocaleLowerCase().includes(query);

		return matchesFilter && matchesSearch;
	});
});

const visibleAwaitingAttendees = $derived(
	filteredAttendees.filter(
		(attendee) => attendee.attendanceStatus === "pending",
	),
);
const selectedVisibleCount = $derived(
	visibleAwaitingAttendees.filter((attendee) =>
		selectedAttendees.includes(attendee.id),
	).length,
);
const allVisibleSelected = $derived(
	visibleAwaitingAttendees.length > 0 &&
		selectedVisibleCount === visibleAwaitingAttendees.length,
);
const someVisibleSelected = $derived(
	selectedVisibleCount > 0 && !allVisibleSelected,
);
const selectedRefundEligibility = $derived(
	refundAttendee ? getRefundEligibility(refundAttendee) : null,
);

const markAttendedMutation = createMutation(() => ({
	...workshopsUpdateAttendanceMutation(),
	onSuccess: () => {
		selectedAttendees = [];
		onAttendanceUpdated?.();
		toast.success("Attendance updated");
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to update attendance");
	},
}));

const refundMutation = createMutation(() => ({
	...workshopsRefundRegistrationMutation(),
	onSuccess: () => {
		refundDialogOpen = false;
		onRefundProcessed?.();
		toast.success("Refund request processed");
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to process refund");
	},
}));

function toggleSelectAllVisible() {
	const visibleIds = visibleAwaitingAttendees.map((attendee) => attendee.id);

	if (allVisibleSelected) {
		selectedAttendees = selectedAttendees.filter(
			(attendeeId) => !visibleIds.includes(attendeeId),
		);
		return;
	}

	selectedAttendees = [...new Set([...selectedAttendees, ...visibleIds])];
}

function toggleAttendee(id: string) {
	if (selectedAttendees.includes(id)) {
		selectedAttendees = selectedAttendees.filter(
			(attendeeId) => attendeeId !== id,
		);
		return;
	}

	selectedAttendees = [...selectedAttendees, id];
}

function setStatusFilter(filter: AttendanceFilter) {
	statusFilter = filter;
	selectedAttendees = [];
}

function clearFilters() {
	search = "";
	statusFilter = "all";
	selectedAttendees = [];
}

function getAttendanceBadgeVariant(status: string | null | undefined) {
	if (status === "attended") return "default" as const;
	if (status === "noShow") return "destructive" as const;
	if (status === "excused") return "secondary" as const;
	return "outline" as const;
}

function getAttendanceStatusLabel(status: string | null | undefined) {
	if (status === "attended") return "Checked in";
	if (status === "noShow") return "No show";
	if (status === "excused") return "Excused";
	return "Awaiting check-in";
}

function getPaymentBadgeVariant(
	registrationStatus: string | null | undefined,
	refund?: WorkshopRefund,
) {
	if (refund?.status === "failed") return "destructive" as const;
	if (
		refund?.status === "completed" ||
		refund?.status === "processing" ||
		refund?.status === "pending"
	) {
		return "secondary" as const;
	}
	if (registrationStatus === "confirmed") return "outline" as const;
	return "secondary" as const;
}

function getPaymentStatusLabel(
	registrationStatus: string | null | undefined,
	refund?: WorkshopRefund,
) {
	if (refund?.status === "completed") {
		return `Refunded ${formatCurrency(refund.refundAmount, "EUR")}`;
	}
	if (refund?.status === "processing" || refund?.status === "pending") {
		return "Refund processing";
	}
	if (refund?.status === "failed") return "Refund failed";
	if (refund?.status === "cancelled") return "Refund cancelled";
	if (registrationStatus === "confirmed") return "Paid";
	return "Payment pending";
}

function getRefund(attendeeId: string) {
	return refunds.find((refund) => refund.registrationId === attendeeId);
}

function formatCurrency(amountInCents: number, currency: string | null) {
	return new Intl.NumberFormat("en-IE", {
		style: "currency",
		currency: currency ?? "EUR",
	}).format(amountInCents / 100);
}

function getRefundEligibility(attendee: WorkshopAttendee) {
	return checkRefundEligibility(
		workshop.startDate,
		workshop.refundDays,
		workshop.status,
		attendee.status,
	);
}

function confirmRefund() {
	if (!workshopId || !refundAttendee) return;
	refundMutation.mutate({
		path: { workshopId, registrationId: refundAttendee.id },
		body: { reason: "Requested by user" },
	});
}

function markAttended(registrationIds: string[]) {
	if (!workshopId || registrationIds.length === 0) return;

	const updates = registrationIds.map(
		(registrationId): AttendedUpdate => ({
			registrationId,
			attendanceStatus: "attended",
			notes: "",
		}),
	);

	markAttendedMutation.mutate({
		path: { workshopId },
		body: { updates },
	});
}
</script>

<section class="space-y-4" aria-labelledby="attendee-roster-heading">
	<div class="space-y-4 rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
		<div
			class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between"
		>
			<div>
				<h2 id="attendee-roster-heading" class="text-xl font-bold">
					Check-in roster
				</h2>
				<p class="mt-1 text-sm leading-6 text-muted-foreground">
					Search for participants and update their attendance.
				</p>
			</div>
			<p class="text-sm font-semibold text-muted-foreground" aria-live="polite">
				{filteredAttendees.length}
				{filteredAttendees.length === 1 ? "participant" : "participants"}
			</p>
		</div>

		<div class="grid gap-3 lg:grid-cols-[minmax(16rem,1fr)_auto]">
			<div class="relative">
				<label for="attendee-search" class="sr-only">Search participants</label>
				<Search
					aria-hidden="true"
					class="pointer-events-none absolute top-1/2 left-3.5 size-4 -translate-y-1/2 text-muted-foreground"
				/>
				<Input
					id="attendee-search"
					bind:value={search}
					class="h-11 pl-10"
					placeholder="Search by name or email"
					autocomplete="off"
					oninput={() => (selectedAttendees = [])}
				/>
			</div>

			<div
				class="flex flex-wrap gap-2 lg:justify-end"
				aria-label="Filter participants by attendance status"
			>
				{#each attendanceFilters as filter (filter.value)}
					<Button
						variant={statusFilter === filter.value ? "secondary" : "outline"}
						size="sm"
						class="min-h-11 shrink-0"
						aria-pressed={statusFilter === filter.value}
						onclick={() => setStatusFilter(filter.value)}
					>
						{filter.label}
					</Button>
				{/each}
			</div>
		</div>
	</div>

	{#if visibleAwaitingAttendees.length > 0}
		<div
			class="flex flex-col gap-4 rounded-2xl border border-primary/25 bg-primary/5 p-4 sm:flex-row sm:items-center sm:justify-between"
			aria-label="Bulk attendance actions"
		>
			<div class="flex min-w-0 items-center gap-3">
				<Checkbox
					id="select-visible-attendees"
					checked={allVisibleSelected}
					indeterminate={someVisibleSelected}
					onCheckedChange={toggleSelectAllVisible}
					aria-label="Select all visible participants awaiting check-in"
					class={touchCheckboxClass}
				/>
				<div>
					<p class="text-sm font-bold">
						{#if selectedAttendees.length > 0}
							{selectedAttendees.length} selected
						{:else}
							Select all visible
						{/if}
					</p>
					<p class="text-xs leading-5 text-muted-foreground">
						{visibleAwaitingAttendees.length} visible awaiting check-in
					</p>
				</div>
			</div>

			<div
				class="grid w-full gap-2 sm:flex sm:w-auto sm:flex-wrap sm:justify-end"
			>
				<Button
					variant="outline"
					class="w-full sm:w-auto"
					onclick={() => (bulkCheckInOpen = true)}
					disabled={markAttendedMutation.isPending}
				>
					<Users aria-hidden="true" />
					Check in all visible
				</Button>
				<Button
					class="w-full sm:w-auto"
					onclick={() => markAttended([...selectedAttendees])}
					disabled={markAttendedMutation.isPending ||
						selectedAttendees.length === 0}
				>
					{#if markAttendedMutation.isPending}
						<LoaderCircle aria-hidden="true" class="animate-spin" />
						Updating…
					{:else}
						<CheckCheck aria-hidden="true" />
						Check in selected
					{/if}
				</Button>
			</div>
		</div>
	{/if}

	{#if filteredAttendees.length === 0 && attendees.length > 0}
		<div
			class="rounded-2xl border border-dashed border-border bg-card px-6 py-12 text-center"
		>
			<Search
				aria-hidden="true"
				class="mx-auto size-10 text-muted-foreground"
			/>
			<h3 class="mt-4 text-lg font-bold">No matching participants</h3>
			<p class="mx-auto mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				Try another name, email, or attendance status.
			</p>
			<Button variant="outline" class="mt-5" onclick={clearFilters}>
				<X aria-hidden="true" />
				Clear filters
			</Button>
		</div>
	{:else if attendees.length === 0}
		<div
			class="rounded-2xl border border-dashed border-border bg-card px-6 py-12 text-center"
		>
			<Users aria-hidden="true" class="mx-auto size-10 text-muted-foreground" />
			<h3 class="mt-4 text-lg font-bold">No registrations yet</h3>
			<p class="mx-auto mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				Participants will appear here as soon as they register for the workshop.
			</p>
		</div>
	{:else}
		<div class="space-y-3">
			{#each filteredAttendees as attendee (attendee.id)}
				{@const refund = getRefund(attendee.id)}
				<article
					class={[
						"grid gap-4 rounded-2xl border bg-card p-4 shadow-sm transition-[border-color,box-shadow] duration-200 hover:shadow-md sm:p-5 lg:grid-cols-[minmax(0,1.25fr)_minmax(12rem,0.6fr)_auto] lg:items-center",
						attendee.attendanceStatus === "attended"
							? "border-l-4 border-l-primary"
							: attendee.attendanceStatus === "noShow"
								? "border-l-4 border-l-destructive"
								: "border-border/80",
					]}
					aria-label={`${attendee.participant.displayName}, ${getAttendanceStatusLabel(attendee.attendanceStatus)}`}
				>
					<div class="flex min-w-0 items-start gap-3">
						{#if attendee.attendanceStatus === "pending"}
							<Checkbox
								id={`attendee-${attendee.id}`}
								checked={selectedAttendees.includes(attendee.id)}
								onCheckedChange={() => toggleAttendee(attendee.id)}
								aria-label={`Select ${attendee.participant.displayName}`}
								class={touchCheckboxClass}
							/>
						{:else}
							<div
								class="flex size-11 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary"
								aria-hidden="true"
							>
								{#if attendee.attendanceStatus === "attended"}
									<CircleCheckBig class="size-5" />
								{:else}
									<User class="size-5" />
								{/if}
							</div>
						{/if}

						<div class="min-w-0 flex-1 pt-1">
							<div class="flex flex-wrap items-center gap-2">
								<h3 class="text-base font-bold leading-tight">
									{attendee.participant.displayName}
								</h3>
								{#if attendee.participant.type === "external"}
									<Badge variant="outline" class="uppercase tracking-wide">
										External
									</Badge>
								{/if}
							</div>
							{#if attendee.participant.email}
								<a
									href={`mailto:${attendee.participant.email}`}
									class="mt-1 block truncate text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline focus-visible:rounded-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
								>
									{attendee.participant.email}
								</a>
							{/if}
							<div
								class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-xs text-muted-foreground"
							>
								<span class="flex items-center gap-1.5">
									<Clock3 aria-hidden="true" class="size-3.5" />
									Registered {dayjs(attendee.registeredAt).format("D MMM YYYY")}
								</span>
								{#if attendee.amountPaid !== null}
									<span class="flex items-center gap-1.5 tabular-nums">
										<DollarSign aria-hidden="true" class="size-3.5" />
										{formatCurrency(attendee.amountPaid, attendee.currency)} paid
									</span>
								{/if}
							</div>
						</div>
					</div>

					<div class="flex flex-wrap items-center gap-2 lg:justify-start">
						<Badge
							variant={getAttendanceBadgeVariant(attendee.attendanceStatus)}
						>
							{#if attendee.attendanceStatus === "attended"}
								<Check aria-hidden="true" />
							{/if}
							{getAttendanceStatusLabel(attendee.attendanceStatus)}
						</Badge>
						<Badge variant={getPaymentBadgeVariant(attendee.status, refund)}>
							{getPaymentStatusLabel(attendee.status, refund)}
						</Badge>
					</div>

					<div
						class="grid w-full grid-cols-1 gap-2 sm:flex sm:w-auto sm:justify-end"
					>
						{#if attendee.attendanceStatus !== "attended"}
							<Button
								variant="outline"
								class="w-full sm:w-auto"
								onclick={() => markAttended([attendee.id])}
								disabled={markAttendedMutation.isPending}
							>
								<Check aria-hidden="true" />
								Check in
							</Button>
						{/if}

						{#if !refund}
							<Button
								variant="outline"
								class="w-full sm:w-auto"
								onclick={() => {
									refundAttendee = attendee;
									refundDialogOpen = true;
								}}
								disabled={refundMutation.isPending}
							>
								<DollarSign aria-hidden="true" />
								Refund
							</Button>
						{/if}
					</div>
				</article>
			{/each}
		</div>
	{/if}
</section>

<AlertDialog.Root
	open={bulkCheckInOpen}
	onOpenChange={(open) => (bulkCheckInOpen = open)}
>
	<AlertDialog.Content class="rounded-2xl border-border/80 sm:max-w-md">
		<AlertDialog.Header>
			<div
				class="mb-1 flex size-11 items-center justify-center rounded-xl bg-primary/10 text-primary"
				aria-hidden="true"
			>
				<CheckCheck class="size-5" />
			</div>
			<AlertDialog.Title>Check in everyone visible?</AlertDialog.Title>
			<AlertDialog.Description class="leading-6">
				This will mark {visibleAwaitingAttendees.length}
				{visibleAwaitingAttendees.length === 1 ? "participant" : "participants"}
				as attended. Existing checked-in records will not change.
			</AlertDialog.Description>
		</AlertDialog.Header>
		<AlertDialog.Footer>
			<AlertDialog.Cancel disabled={markAttendedMutation.isPending}>
				Cancel
			</AlertDialog.Cancel>
			<AlertDialog.Action
				disabled={markAttendedMutation.isPending}
				onclick={() =>
					markAttended(visibleAwaitingAttendees.map((attendee) => attendee.id))}
			>
				<CheckCheck aria-hidden="true" />
				Confirm check-in
			</AlertDialog.Action>
		</AlertDialog.Footer>
	</AlertDialog.Content>
</AlertDialog.Root>

<AlertDialog.Root
	open={refundDialogOpen}
	onOpenChange={(open) => (refundDialogOpen = open)}
>
	{#if refundAttendee && selectedRefundEligibility}
		<AlertDialog.Content class="rounded-2xl border-border/80 sm:max-w-lg">
			<AlertDialog.Header>
				<div
					class="mb-1 flex size-11 items-center justify-center rounded-xl bg-destructive/10 text-destructive"
					aria-hidden="true"
				>
					<DollarSign class="size-5" />
				</div>
				<AlertDialog.Title>
					Refund {refundAttendee.participant.displayName}?
				</AlertDialog.Title>
				<AlertDialog.Description class="leading-6">
					Review the outcome before changing this registration. This action
					cannot be undone from the attendance desk.
				</AlertDialog.Description>
			</AlertDialog.Header>

			<div class="rounded-xl border border-border/70 bg-muted/25 p-4">
				<div class="flex items-center justify-between gap-4">
					<span class="text-sm text-muted-foreground">Original payment</span>
					<strong class="text-base tabular-nums">
						{refundAttendee.amountPaid === null
							? "Not recorded"
							: formatCurrency(
									refundAttendee.amountPaid,
									refundAttendee.currency,
								)}
					</strong>
				</div>
			</div>

			{#if selectedRefundEligibility.isEligible}
				<div
					class="flex gap-3 rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm"
				>
					<CircleCheckBig
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-primary"
					/>
					<div>
						<p class="font-bold">Eligible for a full refund</p>
						<p class="mt-1 leading-6 text-muted-foreground">
							The payment will be returned to the original payment method and
							the participant will be removed from the workshop.
						</p>
					</div>
				</div>
			{:else}
				<div
					class="flex gap-3 rounded-xl border border-secondary/50 bg-secondary/10 p-4 text-sm"
				>
					<TriangleAlert
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-foreground"
					/>
					<div>
						<p class="font-bold">Outside the refund policy</p>
						<p class="mt-1 leading-6 text-muted-foreground">
							{selectedRefundEligibility.reason}. The participant will be
							removed without returning the payment.
						</p>
					</div>
				</div>
			{/if}

			<AlertDialog.Footer>
				<AlertDialog.Cancel disabled={refundMutation.isPending}>
					Keep registration
				</AlertDialog.Cancel>
				<Button
					variant="destructive"
					disabled={refundMutation.isPending}
					onclick={confirmRefund}
				>
					{#if refundMutation.isPending}
						<LoaderCircle aria-hidden="true" class="animate-spin" />
						Processing…
					{:else if selectedRefundEligibility.isEligible}
						<DollarSign aria-hidden="true" />
						Confirm refund
					{:else}
						<User aria-hidden="true" />
						Remove registration
					{/if}
				</Button>
			</AlertDialog.Footer>
		</AlertDialog.Content>
	{/if}
</AlertDialog.Root>
