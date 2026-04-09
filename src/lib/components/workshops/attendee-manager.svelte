<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import { Button } from "$lib/components/ui/button";
import { Badge } from "$lib/components/ui/badge";
import { Checkbox } from "$lib/components/ui/checkbox";
import * as Popover from "$lib/components/ui/popover";
import { toast } from "svelte-sonner";
import { Check, DollarSign, User, CheckCheck } from "lucide-svelte";
import { checkRefundEligibility } from "$lib/utils/refund-eligibility";
import {
	updateAttendance,
	processRefund,
} from "$lib/functions/workshops.remote";

interface Props {
	attendees: any[]; // eslint-disable-line @typescript-eslint/no-explicit-any
	refunds: any[]; // eslint-disable-line @typescript-eslint/no-explicit-any
	workshop: any; // eslint-disable-line @typescript-eslint/no-explicit-any
	workshopId?: string;
	onAttendanceUpdated?: () => void;
	onRefundProcessed?: () => void;
}

let {
	attendees,
	refunds,
	workshop,
	workshopId,
	onAttendanceUpdated,
	onRefundProcessed,
}: Props = $props();

let refundPopoverOpen = $state(false);
let attendeeIdForRefund = $state("");
let selectedAttendees = $state<string[]>([]);

const unattendedAttendees = $derived(
	attendees.filter((a) => a.attendance_status !== "attended"),
);

const allSelected = $derived(
	unattendedAttendees.length > 0 &&
		unattendedAttendees.every((a) => selectedAttendees.includes(a.id)),
);

function toggleSelectAll() {
	if (allSelected) {
		selectedAttendees = [];
	} else {
		selectedAttendees = unattendedAttendees.map((a) => a.id);
	}
}

function toggleAttendee(id: string) {
	if (selectedAttendees.includes(id)) {
		selectedAttendees = selectedAttendees.filter((sid) => sid !== id);
	} else {
		selectedAttendees = [...selectedAttendees, id];
	}
}

const markAttendedMutation = createMutation(() => ({
	mutationFn: async (registrationIds: string[]) => {
		if (!workshopId) throw new Error("Workshop ID is required");
		return updateAttendance({
			workshopId,
			attendance_updates: registrationIds.map((id) => ({
				registration_id: id,
				attendance_status: "attended" as const,
				notes: "",
			})),
		});
	},
	onSuccess: () => {
		selectedAttendees = [];
		onAttendanceUpdated?.();
		toast.success("Marked as checked in");
	},
	onError: (error: Error) => {
		toast.error(error.message);
	},
}));

const refundMutation = createMutation(() => ({
	mutationFn: async (registrationId: string) => {
		return processRefund({
			registration_id: registrationId,
			reason: "Requested by user",
		});
	},
	onSuccess: () => {
		attendeeIdForRefund = "";
		refundPopoverOpen = false;
		onRefundProcessed?.();
		toast.success("Refund processed");
	},
	onError: (error: Error) => {
		toast.error(error.message);
	},
}));

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getAttendeeDisplayName(attendee: any) {
	return attendee.user_profiles?.first_name
		? `${attendee.user_profiles.first_name} ${attendee.user_profiles.last_name}`
		: `${attendee.external_users?.first_name} ${attendee.external_users?.last_name}`;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getAttendeeEmail(attendee: any) {
	return attendee.user_profiles?.email || attendee.external_users?.email;
}

function getAttendanceBadgeVariant(status: string | null | undefined) {
	switch (status) {
		case "pending":
			return "outline";
		case "attended":
			return "default";
		case "no_show":
			return "destructive";
		case "excused":
			return "secondary";
		default:
			return "outline";
	}
}

function getAttendanceStatusLabel(status: string | null | undefined) {
	switch (status) {
		case "attended":
			return "Checked In";
		case "no_show":
			return "No Show";
		case "excused":
			return "Excused";
		case "pending":
		default:
			return "Not Checked In";
	}
}

function getPaymentBadgeVariant(
	registrationStatus: string | null | undefined,
	refund?: { status?: string } | null,
) {
	if (refund?.status === "completed" || registrationStatus === "refunded") {
		return "secondary";
	}

	if (refund?.status === "failed") {
		return "destructive";
	}

	switch (registrationStatus) {
		case "confirmed":
			return "default";
		case "cancelled":
			return "destructive";
		case "pending":
			return "outline";
		default:
			return "outline";
	}
}

function getPaymentStatusLabel(
	registrationStatus: string | null | undefined,
	refund?: { status?: string; refund_amount?: number } | null,
) {
	if (refund?.status === "completed" || registrationStatus === "refunded") {
		if (typeof refund?.refund_amount === "number") {
			return `Refunded ${formatCurrency(refund.refund_amount / 100)}`;
		}

		return "Refunded";
	}

	if (refund?.status === "processing" || refund?.status === "pending") {
		return "Refund Processing";
	}

	if (refund?.status === "failed") {
		return "Refund Failed";
	}

	if (refund?.status === "cancelled") {
		return "Refund Cancelled";
	}

	switch (registrationStatus) {
		case "confirmed":
			return "Paid";
		case "pending":
			return "Payment Pending";
		case "cancelled":
			return "Cancelled";
		case "refunded":
			return "Refunded";
		default:
			return "Unknown";
	}
}

function getRefund(attendeeId: string) {
	return refunds.find((refund) => refund.registration_id === attendeeId);
}

function formatCurrency(amount: number) {
	return new Intl.NumberFormat("en-IE", {
		style: "currency",
		currency: "EUR",
	}).format(amount);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function isExternalAttendee(attendee: any) {
	return Boolean(attendee.external_user_id || attendee.external_users);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getRefundEligibility(attendee: any) {
	return checkRefundEligibility(
		workshop.start_date,
		workshop.refund_days,
		workshop.status,
		attendee.status,
	);
}

function confirmRefund() {
	refundMutation.mutate(attendeeIdForRefund);
}
</script>

<div class="space-y-3">
    {#if unattendedAttendees.length > 0}
        <div
                class="flex flex-col gap-3 rounded-lg border border-primary/20 bg-primary/5 p-3 sm:flex-row sm:items-center sm:justify-between"
        >
			<span class="text-sm font-medium">
				{#if selectedAttendees.length > 0}
					{selectedAttendees.length} attendee{selectedAttendees.length > 1 ? 's' : ''} selected
				{:else}
					Select attendees to mark as checked in
				{/if}
			</span>
            <div class="flex w-full flex-wrap gap-2 sm:w-auto sm:justify-end">
                <Button
                        size="sm"
                        class="flex-1 sm:flex-none"
                        onclick={() => {
						toggleSelectAll();
						markAttendedMutation.mutate([...selectedAttendees]);
					}}
                        disabled={markAttendedMutation.isPending || allSelected}
                >
                    <CheckCheck class="w-4 h-4"/>
                    Mark all as Checked In
                </Button>

                <Button
                        size="sm"
                        class="flex-1 sm:flex-none"
                        onclick={() => markAttendedMutation.mutate([...selectedAttendees])}
                        disabled={markAttendedMutation.isPending || selectedAttendees.length === 0}
                >
                    <Check class="w-4 h-4"/>
                    Mark as Checked In
                </Button>
            </div>
        </div>
    {/if}

    {#each attendees as attendee (attendee.id)}
        {@const refund = getRefund(attendee.id)}
        <div
                class="rounded-lg border bg-card p-4 transition-colors hover:bg-accent/50"
        >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
                <div class="flex min-w-0 flex-1 items-start gap-3">
                    {#if attendee.attendance_status !== 'attended'}
                        <Checkbox
                                id={`${getAttendeeDisplayName(attendee)}-select`}
                                checked={selectedAttendees.includes(attendee.id)}
                                onCheckedChange={() => toggleAttendee(attendee.id)}
                        />
                    {:else}
                        <div class="w-5"></div>
                    {/if}

                    <div class="flex-shrink-0">
                        <div class="w-10 h-10 rounded-full bg-muted flex items-center justify-center">
							<User class="w-5 h-5 text-muted-foreground"/>
						</div>
					</div>

					<div class="min-w-0 flex-1">
						<div class="font-medium text-sm">{getAttendeeDisplayName(attendee)}</div>
						<div class="text-xs text-muted-foreground truncate">
							{getAttendeeEmail(attendee)}
						</div>

						<div class="mt-2 flex flex-wrap items-center gap-2">
							<Badge
								variant={getAttendanceBadgeVariant(attendee.attendance_status)}
								class="text-xs"
							>
								{getAttendanceStatusLabel(attendee.attendance_status)}
							</Badge>
							<Badge
								variant={getPaymentBadgeVariant(attendee.status, refund)}
								class="text-xs"
							>
								{getPaymentStatusLabel(attendee.status, refund)}
							</Badge>

							{#if isExternalAttendee(attendee)}
								<Badge variant="outline" class="text-[10px] uppercase tracking-wide">
									External
								</Badge>
							{/if}
						</div>
					</div>
				</div>

                <div class="flex w-full flex-wrap items-center gap-2 sm:w-auto sm:justify-end">
                    {#if attendee.attendance_status !== 'attended'}
                        <Button
                                size="sm"
                                variant="outline"
                                onclick={() => markAttendedMutation.mutate([attendee.id])}
                                disabled={markAttendedMutation.isPending}
                                class="flex-1 gap-1 sm:flex-none"
                        >
                            <Check class="w-4 h-4"/>
                            Mark Checked In
                        </Button>
                    {/if}

                    {#if !refund}
                        <Popover.Root open={refundPopoverOpen}>
                            <Popover.Trigger>
                                <Button
                                        size="sm"
                                        variant="outline"
                                        onclick={() => {
										refundPopoverOpen = true;
										attendeeIdForRefund = attendee.id;
									}}
                                        disabled={refundMutation.isPending}
                                        class="w-full flex-1 gap-1 sm:w-auto sm:flex-none"
                                >
                                    <DollarSign class="w-4 h-4"/>
                                    Refund
                                </Button>
                            </Popover.Trigger>
                            <Popover.Content class="w-80">
                            {@const eligibility = getRefundEligibility(attendee)}
                            <div class="space-y-3">
                                <h4 class="font-medium">Confirm Refund</h4>
                                <p class="text-sm text-muted-foreground">
                                    {getAttendeeDisplayName(attendee)}
                                </p>

                                {#if eligibility.isEligible}
                                    <div class="text-sm">
                                        <p class="text-green-600 font-medium">✓ Eligible for refund</p>
                                        <p class="text-muted-foreground mt-1">
                                            The user will receive a full refund to their original payment method.
                                        </p>
                                    </div>
                                {:else}
                                    <div class="text-sm">
                                        <p class="text-orange-600 font-medium">⚠ Not eligible for refund</p>
                                        <p class="text-muted-foreground mt-1">
                                            {eligibility.reason}. The user will be removed from the workshop without
                                            refund.
                                        </p>
                                    </div>
                                {/if}

                                <div class="flex justify-end gap-2">
                                    <Button
                                            size="sm"
                                            variant="outline"
                                            onclick={() => {
											refundPopoverOpen = false;
											attendeeIdForRefund = '';
										}}
                                    >
                                        Cancel
                                    </Button>
                                    <Button
                                            size="sm"
                                            onclick={confirmRefund}
                                            disabled={refundMutation.isPending}
                                    >
                                        {#if refundMutation.isPending}
                                            Processing...
                                        {:else}
                                            Confirm
                                        {/if}
                                    </Button>
                                </div>
                            </div>
                            </Popover.Content>
                        </Popover.Root>
                    {/if}
                </div>
            </div>
        </div>
    {/each}

    {#if attendees.length === 0}
        <div class="text-center py-8 text-muted-foreground">No attendees registered yet</div>
    {/if}
</div>
