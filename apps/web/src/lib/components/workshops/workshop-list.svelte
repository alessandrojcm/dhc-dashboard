<script lang="ts">
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import WorkshopExpressCheckout from "./workshop-express-checkout.svelte";
import WorkshopCancellationDialog from "./workshop-cancellation-dialog.svelte";
import dayjs from "dayjs";
import Dinero from "dinero.js";
import { useQueryClient } from "@tanstack/svelte-query";
import type { UserData } from "$lib/types";
import {
	CalendarCheck2,
	Check,
	Clock3,
	Heart,
	MapPin,
	RotateCcw,
	TicketCheck,
	Users,
} from "@lucide/svelte";
import { workshopsListQueryKey, type Workshop } from "@dhc/api-client";

type WorkshopView = "bookable" | "planned";

interface Props {
	workshops: Workshop[];
	view: WorkshopView;
	onInterestToggle?: (workshopId: string) => void;
	isLoading?: boolean;
}

let { workshops, view, onInterestToggle, isLoading = false }: Props = $props();

let checkoutWorkshop: Workshop | null = $state(null);
let cancellationWorkshop: Workshop | null = $state(null);
let selectedRegistration: { id: string; status: string } | null = $state(null);
let registrationDialogOpen = $state(false);
let cancellationDialogOpen = $state(false);

const queryClient = useQueryClient();
const userData = queryClient.getQueryData<UserData>(["logged_in_user_data"]);

const sortedWorkshops = $derived(
	[...workshops].sort(
		(first, second) =>
			dayjs(first.startDate).valueOf() - dayjs(second.startDate).valueOf(),
	),
);

const workshopGroups = $derived.by(() => {
	if (view === "planned") {
		return [
			{
				id: "coming-soon",
				title: "Help shape what comes next",
				description:
					"Save your interest so coordinators can see which ideas members want most.",
				workshops: sortedWorkshops,
			},
		];
	}

	const booked = sortedWorkshops.filter(hasActiveRegistration);
	const open = sortedWorkshops.filter(
		(workshop) => !hasActiveRegistration(workshop) && !isAtCapacity(workshop),
	);
	const full = sortedWorkshops.filter(
		(workshop) => !hasActiveRegistration(workshop) && isAtCapacity(workshop),
	);

	return [
		{
			id: "booked",
			title: "You’re going",
			description: "Your confirmed and pending workshop registrations.",
			workshops: booked,
		},
		{
			id: "open",
			title: "Open for booking",
			description: "Choose your next session and secure your place.",
			workshops: open,
		},
		{
			id: "full",
			title: "Fully booked",
			description: "These sessions may reopen if another member cancels.",
			workshops: full,
		},
	].filter((group) => group.workshops.length > 0);
});

function hasActiveRegistration(workshop: Workshop) {
	return ["pending", "confirmed"].includes(
		workshop.currentUserRegistration?.status ?? "",
	);
}

function registrationCount(workshop: Workshop) {
	return (
		workshop.pendingRegistrationCount + workshop.confirmedRegistrationCount
	);
}

function availablePlaces(workshop: Workshop) {
	return Math.max(0, workshop.maxCapacity - registrationCount(workshop));
}

function isAtCapacity(workshop: Workshop) {
	return (
		workshop.maxCapacity > 0 &&
		registrationCount(workshop) >= workshop.maxCapacity
	);
}

function formatPrice(price: number) {
	return Dinero({ amount: price, currency: "EUR" }).toFormat();
}

function formatWorkshopTime(workshop: Workshop) {
	const start = dayjs(workshop.startDate);
	const end = dayjs(workshop.endDate);

	if (start.isSame(end, "day")) {
		return `${start.format("ddd, D MMM · h:mm A")}–${end.format("h:mm A")}`;
	}

	return `${start.format("D MMM · h:mm A")}–${end.format("D MMM · h:mm A")}`;
}

function getMemberState(workshop: Workshop) {
	const status = workshop.currentUserRegistration?.status;

	if (status === "confirmed") return "You’re going";
	if (status === "pending") return "Registration pending";
	if (status === "refunded") return "Refunded";
	if (status === "cancelled") return "Cancelled";
	if (workshop.currentUserInterest) return "Interested";
	if (isAtCapacity(workshop)) return "Fully booked";
	return view === "planned" ? "In planning" : "Open";
}

function getMemberStateVariant(workshop: Workshop) {
	const state = getMemberState(workshop);

	if (state === "You’re going" || state === "Interested") {
		return "default" as const;
	}
	if (state === "Registration pending" || state === "In planning") {
		return "secondary" as const;
	}
	return "outline" as const;
}

function openRegistration(workshop: Workshop) {
	checkoutWorkshop = workshop;
	registrationDialogOpen = true;
}

function handleRegistrationDialogChange(open: boolean) {
	registrationDialogOpen = open;
	if (!open) checkoutWorkshop = null;
}

function openCancellation(workshop: Workshop) {
	if (!workshop.currentUserRegistration) return;

	cancellationWorkshop = workshop;
	selectedRegistration = workshop.currentUserRegistration;
	cancellationDialogOpen = true;
}

function handleCancellationDialogChange(open: boolean) {
	cancellationDialogOpen = open;
	if (!open) {
		cancellationWorkshop = null;
		selectedRegistration = null;
	}
}

function handleRegistrationSuccess() {
	queryClient.invalidateQueries({
		queryKey: workshopsListQueryKey({ query: { status: "published" } }),
	});
	registrationDialogOpen = false;
	checkoutWorkshop = null;
}
</script>

{#if workshops.length === 0}
	<div
		class="rounded-2xl border border-dashed border-border bg-card px-5 py-12 text-center sm:px-8"
	>
		{#if view === "planned"}
			<Heart aria-hidden="true" class="mx-auto size-10 text-primary" />
			<h2 class="mt-4 text-xl font-bold">Nothing in planning right now</h2>
			<p class="mx-auto mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				New workshop ideas will appear here first. Check back soon to help shape
				what the club runs next.
			</p>
		{:else}
			<TicketCheck aria-hidden="true" class="mx-auto size-10 text-primary" />
			<h2 class="mt-4 text-xl font-bold">No workshops open yet</h2>
			<p class="mx-auto mt-2 max-w-md text-sm leading-6 text-muted-foreground">
				There are no workshops available to book right now. New sessions will
				appear here when registration opens.
			</p>
		{/if}
	</div>
{:else}
	<div class="space-y-8">
		{#each workshopGroups as group (group.id)}
			<section class="space-y-3" aria-labelledby={`workshop-group-${group.id}`}>
				<div
					class="flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between"
				>
					<div>
						<h2 id={`workshop-group-${group.id}`} class="text-xl font-bold">
							{group.title}
						</h2>
						<p class="mt-1 text-sm text-muted-foreground">
							{group.description}
						</p>
					</div>
					<p class="text-sm font-medium text-muted-foreground">
						{group.workshops.length}
						{group.workshops.length === 1 ? "workshop" : "workshops"}
					</p>
				</div>

				<div class="space-y-3">
					{#each group.workshops as workshop (workshop.id)}
						<article
							class="grid gap-4 rounded-2xl border border-border/80 bg-card p-4 shadow-sm transition-[border-color,box-shadow] duration-200 hover:border-primary/40 hover:shadow-md sm:p-5 lg:grid-cols-[4.5rem_minmax(0,1fr)_minmax(12rem,auto)] lg:items-center lg:gap-5"
						>
							<div
								class="flex h-16 w-16 shrink-0 flex-col items-center justify-center rounded-xl border border-primary/20 bg-primary/5 text-primary lg:h-[4.5rem] lg:w-[4.5rem]"
								aria-hidden="true"
							>
								<span
									class="text-[0.65rem] font-bold tracking-[0.16em] uppercase"
								>
									{dayjs(workshop.startDate).format("MMM")}
								</span>
								<span class="text-2xl font-bold leading-none">
									{dayjs(workshop.startDate).format("D")}
								</span>
								<span class="mt-0.5 text-[0.6rem] font-semibold uppercase">
									{dayjs(workshop.startDate).format("ddd")}
								</span>
							</div>

							<div class="min-w-0">
								<div class="flex flex-wrap items-center gap-2">
									<Badge variant={getMemberStateVariant(workshop)}>
										{#if getMemberState(workshop) === "You’re going"}
											<Check aria-hidden="true" />
										{/if}
										{getMemberState(workshop)}
									</Badge>
									{#if workshop.isPublic}
										<Badge variant="outline">Open to non-members</Badge>
									{/if}
								</div>

								<h3
									class="mt-2 text-lg font-bold leading-snug text-foreground sm:text-xl"
								>
									{workshop.title}
								</h3>
								{#if workshop.description}
									<p
										class="mt-1 line-clamp-2 text-sm leading-6 text-muted-foreground"
									>
										{workshop.description}
									</p>
								{/if}

								<div
									class="mt-3 grid gap-x-5 gap-y-2 text-sm text-muted-foreground sm:grid-cols-2"
								>
									<span class="flex min-w-0 items-center gap-2">
										<Clock3
											aria-hidden="true"
											class="size-4 shrink-0 text-primary"
										/>
										<span>{formatWorkshopTime(workshop)}</span>
									</span>
									<span class="flex min-w-0 items-center gap-2">
										<MapPin
											aria-hidden="true"
											class="size-4 shrink-0 text-primary"
										/>
										<span class="truncate">{workshop.location}</span>
									</span>
								</div>
							</div>

							<div
								class="grid gap-3 border-t border-border/70 pt-4 sm:grid-cols-[1fr_auto] sm:items-end lg:block lg:border-t-0 lg:border-l lg:pt-0 lg:pl-5"
							>
								<div>
									{#if view === "planned"}
										<p
											class="flex items-center gap-2 text-sm font-bold text-foreground"
										>
											<Users aria-hidden="true" class="size-4 text-primary" />
											{workshop.interestCount}
											{workshop.interestCount === 1 ? "member" : "members"}
											interested
										</p>
										<p class="mt-1 text-xs text-muted-foreground">
											No payment or commitment yet
										</p>
									{:else}
										<p class="text-xl font-bold text-foreground">
											{formatPrice(workshop.priceMember)}
										</p>
										<p class="mt-1 text-xs text-muted-foreground">
											{#if isAtCapacity(workshop)}
												Fully booked
											{:else}
												{availablePlaces(workshop)}
												{availablePlaces(workshop) === 1 ? "place" : "places"}
												left
											{/if}
										</p>
									{/if}
								</div>

								<div class="sm:min-w-44 lg:mt-4">
									{#if view === "planned" && onInterestToggle}
										<Button
											variant={workshop.currentUserInterest
												? "secondary"
												: "default"}
											class="min-h-11 w-full"
											onclick={() => onInterestToggle(workshop.id)}
											disabled={isLoading}
										>
											{#if workshop.currentUserInterest}
												<RotateCcw aria-hidden="true" />
												Withdraw interest
											{:else}
												<Heart aria-hidden="true" />
												I’m interested
											{/if}
										</Button>
									{:else if hasActiveRegistration(workshop)}
										<Button
											variant="outline"
											class="min-h-11 w-full"
											onclick={() => openCancellation(workshop)}
										>
											<CalendarCheck2 aria-hidden="true" />
											Manage booking
										</Button>
									{:else}
										<Button
											class="min-h-11 w-full"
											onclick={() => openRegistration(workshop)}
											disabled={isAtCapacity(workshop)}
										>
											<TicketCheck aria-hidden="true" />
											{isAtCapacity(workshop) ? "Fully booked" : "Register"}
										</Button>
									{/if}
								</div>
							</div>
						</article>
					{/each}
				</div>
			</section>
		{/each}
	</div>
{/if}

<Dialog.Root
	open={registrationDialogOpen}
	onOpenChange={handleRegistrationDialogChange}
>
	<Dialog.Content class="max-h-[calc(100dvh-2rem)] overflow-y-auto sm:max-w-lg">
		{#if checkoutWorkshop}
			<Dialog.Header>
				<Dialog.Title>Workshop registration</Dialog.Title>
				<Dialog.Description>
					Complete your registration for {checkoutWorkshop.title}.
				</Dialog.Description>
			</Dialog.Header>
			<WorkshopExpressCheckout
				workshopId={checkoutWorkshop.id}
				workshopTitle={checkoutWorkshop.title}
				amount={checkoutWorkshop.priceMember}
				customerId={userData?.customerId}
				onSuccess={handleRegistrationSuccess}
				onCancel={() => handleRegistrationDialogChange(false)}
			/>
		{/if}
	</Dialog.Content>
</Dialog.Root>

{#if cancellationWorkshop && selectedRegistration}
	<WorkshopCancellationDialog
		workshop={cancellationWorkshop}
		registrationId={selectedRegistration.id}
		registrationStatus={selectedRegistration.status}
		open={cancellationDialogOpen}
		onOpenChange={handleCancellationDialogChange}
		onSuccess={handleRegistrationSuccess}
	/>
{/if}
