<script lang="ts">
import { resolve } from "$app/paths";
import { Button, buttonVariants } from "$lib/components/ui/button";
import { Badge } from "$lib/components/ui/badge";
import * as Dialog from "$lib/components/ui/dialog";
import * as Popover from "$lib/components/ui/popover";
import { Progress } from "$lib/components/ui/progress";
import {
	Calendar,
	Clock3,
	Users,
	MapPin,
	Copy,
	LoaderCircle,
	TriangleAlert,
	CircleCheckBig,
	Pencil,
	X,
} from "@lucide/svelte";
import { createMutation, useQueryClient } from "@tanstack/svelte-query";
import { toast } from "svelte-sonner";
import dayjs from "dayjs";
import type { WorkshopCalendarEvent } from "$lib/types";
import Dinero from "dinero.js";
import {
	workshopsCalendarQueryKey,
	workshopsCancelMutation,
	workshopsDeleteMutation,
	workshopsPublishMutation,
} from "@dhc/api-client";

let {
	calendarEvent: event,
	onClose,
}: {
	calendarEvent: WorkshopCalendarEvent;
	onInterestToggle?: (workshopId: string) => void;
	onClose?: () => void;
} = $props();

const queryClient = useQueryClient();
const workshop = $derived(event.workshop);
const registrationCount = $derived(workshop.registrationCount);
const capacityRemaining = $derived(workshop.placesRemaining);
const capacityPercentage = $derived(
	workshop.isAtCapacity
		? 100
		: workshop.maxCapacity
			? Math.min(
					100,
					Math.round((registrationCount / workshop.maxCapacity) * 100),
				)
			: 0,
);
const canViewAttendees = $derived(
	workshop.status === "published" ||
		workshop.status === "finished" ||
		(workshop.status === "cancelled" && registrationCount > 0),
);
const publicRegisterPath = $derived(
	resolve(`/workshops/${workshop.id}/register`),
);

function getStatusVariant(status: typeof workshop.status) {
	if (status === "planned") return "secondary" as const;
	if (status === "cancelled") return "destructive" as const;
	if (status === "finished") return "outline" as const;
	return "default" as const;
}

const deleteMutation = createMutation(() => ({
	...workshopsDeleteMutation(),
	onSuccess: () => {
		queryClient.invalidateQueries({ queryKey: workshopsCalendarQueryKey() });
		toast.success("Workshop deleted successfully");
		onClose?.();
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to delete workshop");
	},
}));

const publishMutation = createMutation(() => ({
	...workshopsPublishMutation(),
	onSuccess: () => {
		queryClient.invalidateQueries({ queryKey: workshopsCalendarQueryKey() });
		toast.success("Workshop published successfully");
		onClose?.();
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to publish workshop");
	},
}));

const cancelMutation = createMutation(() => ({
	...workshopsCancelMutation(),
	onSuccess: () => {
		queryClient.invalidateQueries({ queryKey: workshopsCalendarQueryKey() });
		toast.success("Workshop cancelled successfully");
		onClose?.();
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to cancel workshop");
	},
}));

function formatPrice(price: number) {
	return Dinero({ amount: price, currency: "EUR" }).toFormat();
}

function formatDuration() {
	const minutes = dayjs(workshop.endDate).diff(
		dayjs(workshop.startDate),
		"minute",
	);
	const hours = Math.floor(minutes / 60);
	const remainingMinutes = minutes % 60;

	if (hours === 0) return `${remainingMinutes} min`;
	if (remainingMinutes === 0) return `${hours} hr`;
	return `${hours} hr ${remainingMinutes} min`;
}

function getStatusDescription(status: typeof workshop.status) {
	if (status === "planned") {
		return "Review the workshop details before opening registration.";
	}
	if (status === "published") {
		return "Registration is open and attendees can book places.";
	}
	if (status === "finished") {
		return "This workshop has finished. Attendance records remain available.";
	}
	return "This workshop is cancelled and no longer accepting registrations.";
}

function getAnnouncementLabel() {
	if (workshop.announceEmail && workshop.announceDiscord) {
		return "Email and Discord";
	}
	if (workshop.announceEmail) return "Email";
	if (workshop.announceDiscord) return "Discord";
	return "Not configured";
}

function handleEdit() {
	event.handleEdit?.(workshop);
	onClose?.();
}

function handlePublish() {
	publishMutation.mutate({ path: { workshopId: workshop.id } });
}

function handleCancel() {
	cancelMutation.mutate({ path: { workshopId: workshop.id } });
}

function handleDelete() {
	deleteMutation.mutate({ path: { workshopId: workshop.id } });
}

async function handleCopyPublicRegisterLink() {
	const publicRegisterUrl = new URL(
		publicRegisterPath,
		window.location.origin,
	).toString();

	try {
		isCopyingLink = true;
		hasCopyError = false;
		await navigator.clipboard.writeText(publicRegisterUrl);
		hasCopiedLink = true;

		window.setTimeout(() => {
			hasCopiedLink = false;
		}, 2000);
	} catch {
		hasCopyError = true;
		window.setTimeout(() => {
			hasCopyError = false;
		}, 2000);
	} finally {
		isCopyingLink = false;
	}
}

// State for popover controls
let deletePopoverOpen = $state(false);
let cancelPopoverOpen = $state(false);
let isCopyingLink = $state(false);
let hasCopiedLink = $state(false);
let hasCopyError = $state(false);

// Check if actions are actually provided
const hasEditAction = $derived(!!event.handleEdit);
</script>

<div class="flex max-h-[calc(100dvh-2rem)] w-full flex-col">
	<Dialog.Close
		class="absolute top-2 right-2 z-10 inline-flex size-11 items-center justify-center rounded-lg text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:outline-none"
	>
		<X aria-hidden="true" class="size-5" />
		<span class="sr-only">Close workshop details</span>
	</Dialog.Close>

	<header
		class="shrink-0 border-b border-border/80 px-5 py-5 pr-12 sm:px-6 sm:py-6 sm:pr-14"
	>
		<div class="flex flex-wrap items-center gap-2">
			<Badge variant={getStatusVariant(workshop.status)} class="capitalize">
				{workshop.status}
			</Badge>
			<Badge variant="outline"
				>{workshop.isPublic ? "Public" : "Members only"}</Badge
			>
		</div>
		<Dialog.Title class="mt-3 text-xl font-bold leading-tight sm:text-2xl">
			{workshop.title}
		</Dialog.Title>
		<Dialog.Description class="mt-1.5 text-sm leading-6 text-muted-foreground">
			{getStatusDescription(workshop.status)}
		</Dialog.Description>
	</header>

	<div
		class="min-h-0 flex-1 space-y-6 overflow-y-auto px-5 py-5 sm:px-6 sm:py-6"
	>
		<section aria-labelledby="schedule-heading">
			<h3 id="schedule-heading" class="text-sm font-bold">Schedule</h3>
			<dl class="mt-3 grid gap-3 sm:grid-cols-2">
				<div
					class="flex gap-3 rounded-xl border border-border/70 bg-muted/20 p-3.5"
				>
					<Calendar
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-primary"
					/>
					<div>
						<dt class="text-xs font-medium text-muted-foreground">Date</dt>
						<dd class="mt-0.5 text-sm font-bold">
							{dayjs(workshop.startDate).format("dddd, D MMMM YYYY")}
						</dd>
					</div>
				</div>
				<div
					class="flex gap-3 rounded-xl border border-border/70 bg-muted/20 p-3.5"
				>
					<Clock3
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-primary"
					/>
					<div>
						<dt class="text-xs font-medium text-muted-foreground">Time</dt>
						<dd class="mt-0.5 text-sm font-bold">
							{dayjs(workshop.startDate).format("h:mm A")}–{dayjs(
								workshop.endDate,
							).format("h:mm A")}
							<span class="font-normal text-muted-foreground">
								· {formatDuration()}</span
							>
						</dd>
					</div>
				</div>
				<div
					class="flex gap-3 rounded-xl border border-border/70 bg-muted/20 p-3.5 sm:col-span-2"
				>
					<MapPin
						aria-hidden="true"
						class="mt-0.5 size-5 shrink-0 text-primary"
					/>
					<div>
						<dt class="text-xs font-medium text-muted-foreground">Location</dt>
						<dd class="mt-0.5 text-sm font-bold">
							{workshop.location || "Location not set"}
						</dd>
					</div>
				</div>
			</dl>
		</section>

		<section
			aria-labelledby="registration-heading"
			class="rounded-2xl border border-border/80 p-4 sm:p-5"
		>
			<div class="flex items-start justify-between gap-4">
				<div>
					<h3 id="registration-heading" class="text-sm font-bold">
						{workshop.status === "planned"
							? "Audience interest"
							: "Registration snapshot"}
					</h3>
					<p class="mt-1 text-xs text-muted-foreground">
						{workshop.status === "planned"
							? "Interest collected before registration opens."
							: "Current confirmed and pending bookings."}
					</p>
				</div>
				<Users aria-hidden="true" class="size-5 shrink-0 text-primary" />
			</div>

			{#if workshop.status === "planned"}
				<div class="mt-4 flex items-end justify-between gap-4">
					<div>
						<p class="text-3xl font-bold">{workshop.interestCount}</p>
						<p class="text-sm text-muted-foreground">
							{workshop.interestCount === 1
								? "person interested"
								: "people interested"}
						</p>
					</div>
					<p class="text-right text-sm">
						<span class="block text-xs text-muted-foreground">Capacity</span>
						<span class="font-bold">{workshop.maxCapacity ?? "No limit"}</span>
					</p>
				</div>
			{:else}
				<div class="mt-4 flex items-end justify-between gap-4">
					<div>
						<p class="text-3xl font-bold">
							{registrationCount}{workshop.maxCapacity
								? ` / ${workshop.maxCapacity}`
								: ""}
						</p>
						<p class="text-sm text-muted-foreground">places registered</p>
					</div>
					{#if capacityRemaining !== null}
						<p class="text-right text-sm">
							<span class="block text-xs text-muted-foreground">Remaining</span>
							<span class="font-bold">{capacityRemaining}</span>
						</p>
					{/if}
				</div>
				{#if workshop.maxCapacity}
					<Progress
						value={capacityPercentage}
						class="mt-4"
						aria-label={`${registrationCount} of ${workshop.maxCapacity} places registered`}
					/>
				{/if}
				<dl class="mt-4 grid grid-cols-2 gap-2">
					<div class="rounded-xl bg-muted/40 p-3">
						<dt class="text-xs text-muted-foreground">Confirmed</dt>
						<dd class="mt-1 text-lg font-bold">
							{workshop.confirmedRegistrationCount}
						</dd>
					</div>
					<div class="rounded-xl bg-muted/40 p-3">
						<dt class="text-xs text-muted-foreground">Pending</dt>
						<dd class="mt-1 text-lg font-bold">
							{workshop.pendingRegistrationCount}
						</dd>
					</div>
				</dl>
			{/if}
		</section>

		{#if workshop.isPublic && workshop.status === "published"}
			<section
				aria-labelledby="sharing-heading"
				class="rounded-xl border border-primary/20 bg-primary/5 p-4"
			>
				<div
					class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
				>
					<div class="min-w-0">
						<h3 id="sharing-heading" class="text-sm font-bold">
							Public registration link
						</h3>
						<p class="mt-1 truncate font-mono text-xs text-muted-foreground">
							{publicRegisterPath}
						</p>
					</div>
					<Button
						variant="outline"
						onclick={handleCopyPublicRegisterLink}
						disabled={isCopyingLink}
						class="min-h-11 w-full shrink-0 bg-background sm:w-auto"
					>
						{#if isCopyingLink}
							<LoaderCircle class="animate-spin" />
							Copying…
						{:else if hasCopiedLink}
							<CircleCheckBig />
							Copied
						{:else if hasCopyError}
							<TriangleAlert />
							Couldn’t copy
						{:else}
							<Copy />
							Copy link
						{/if}
					</Button>
				</div>
			</section>
		{/if}

		<section aria-labelledby="details-heading">
			<h3 id="details-heading" class="text-sm font-bold">Workshop details</h3>
			{#if workshop.description}
				<p class="mt-3 text-sm leading-6 text-muted-foreground">
					{workshop.description}
				</p>
			{/if}
			<dl
				class="mt-4 grid grid-cols-2 gap-x-4 gap-y-4 rounded-xl border border-border/70 p-4 sm:grid-cols-4"
			>
				<div>
					<dt class="text-xs text-muted-foreground">Member price</dt>
					<dd class="mt-1 text-sm font-bold">
						{formatPrice(workshop.priceMember ?? 0)}
					</dd>
				</div>
				{#if workshop.isPublic}
					<div>
						<dt class="text-xs text-muted-foreground">Public price</dt>
						<dd class="mt-1 text-sm font-bold">
							{formatPrice(workshop.priceNonMember ?? 0)}
						</dd>
					</div>
				{/if}
				<div>
					<dt class="text-xs text-muted-foreground">Refund window</dt>
					<dd class="mt-1 text-sm font-bold">
						{workshop.refundDays === null
							? "Not configured"
							: `${workshop.refundDays} days`}
					</dd>
				</div>
				<div>
					<dt class="text-xs text-muted-foreground">Announcements</dt>
					<dd class="mt-1 text-sm font-bold">{getAnnouncementLabel()}</dd>
				</div>
			</dl>
		</section>
	</div>

	<footer
		class="shrink-0 border-t border-border/80 bg-muted/20 px-5 py-4 sm:px-6"
	>
		<div class="flex flex-col gap-2 sm:flex-row sm:flex-wrap">
			{#if workshop.status === "planned"}
				<Button
					onclick={handlePublish}
					disabled={publishMutation.isPending}
					class="min-h-11 w-full sm:w-auto"
				>
					{#if publishMutation.isPending}
						<LoaderCircle class="animate-spin" />
					{:else}
						<CircleCheckBig />
					{/if}
					Publish workshop
				</Button>
			{:else if canViewAttendees}
				<Button
					href={resolve("/dashboard/workshops/[id]/attendees", {
						id: workshop.id,
					})}
					class="min-h-11 w-full sm:w-auto"
				>
					<Users aria-hidden="true" />
					{workshop.status === "published"
						? "Manage attendees"
						: "View attendees"}
				</Button>
			{/if}

			{#if hasEditAction}
				<Button
					variant="outline"
					onclick={handleEdit}
					data-testid="edit-workshop-button"
					class="min-h-11 w-full bg-background sm:w-auto"
				>
					<Pencil aria-hidden="true" />
					Edit workshop
				</Button>
			{/if}
		</div>

		{#if workshop.status === "published" || workshop.status === "planned"}
			<div
				class="mt-4 flex flex-col gap-3 border-t border-border/70 pt-4 sm:flex-row sm:items-center sm:justify-between"
			>
				<div>
					<p class="text-xs font-bold">Danger zone</p>
					<p class="text-xs text-muted-foreground">
						{workshop.status === "published"
							? "Stop registration and cancel this workshop."
							: "Permanently remove this planned workshop."}
					</p>
				</div>

				{#if workshop.status === "published"}
					<Popover.Root bind:open={cancelPopoverOpen}>
						<Popover.Trigger
							class={`${buttonVariants({ variant: "destructive" })} min-h-11 w-full sm:w-auto`}
							disabled={cancelMutation.isPending}
						>
							{#if cancelMutation.isPending}
								<LoaderCircle class="animate-spin" />
							{:else}
								<TriangleAlert />
							{/if}
							Cancel workshop
						</Popover.Trigger>
						<Popover.Content class="w-[calc(100vw-2rem)] max-w-80">
							<div class="space-y-3">
								<div class="space-y-2">
									<h4 class="font-medium">Cancel workshop</h4>
									<p class="text-sm text-muted-foreground">
										Are you sure you want to cancel “{workshop.title}”? This
										action cannot be undone.
									</p>
								</div>
								<div class="grid grid-cols-2 gap-2">
									<Button
										variant="outline"
										onclick={() => (cancelPopoverOpen = false)}
										>Keep workshop</Button
									>
									<Button
										variant="destructive"
										onclick={() => {
											handleCancel();
											cancelPopoverOpen = false;
										}}
										disabled={cancelMutation.isPending}
									>
										{#if cancelMutation.isPending}<LoaderCircle
												class="animate-spin"
											/>{/if}
										Cancel workshop
									</Button>
								</div>
							</div>
						</Popover.Content>
					</Popover.Root>
				{:else}
					<Popover.Root bind:open={deletePopoverOpen}>
						<Popover.Trigger
							class={`${buttonVariants({ variant: "destructive" })} min-h-11 w-full sm:w-auto`}
							disabled={deleteMutation.isPending}
						>
							{#if deleteMutation.isPending}
								<LoaderCircle class="animate-spin" />
							{:else}
								<TriangleAlert />
							{/if}
							Delete workshop
						</Popover.Trigger>
						<Popover.Content class="w-[calc(100vw-2rem)] max-w-80 bg-popover">
							<div class="space-y-3">
								<div class="space-y-2">
									<h4 class="font-medium">Delete workshop</h4>
									<p class="text-sm text-muted-foreground">
										Are you sure you want to permanently delete “{workshop.title}”?
										This action cannot be undone.
									</p>
								</div>
								<div class="grid grid-cols-2 gap-2">
									<Button
										variant="outline"
										onclick={() => (deletePopoverOpen = false)}
										>Keep workshop</Button
									>
									<Button
										variant="destructive"
										onclick={() => {
											handleDelete();
											deletePopoverOpen = false;
										}}
										disabled={deleteMutation.isPending}
									>
										{#if deleteMutation.isPending}<LoaderCircle
												class="animate-spin"
											/>{/if}
										Delete workshop
									</Button>
								</div>
							</div>
						</Popover.Content>
					</Popover.Root>
				{/if}
			</div>
		{/if}
	</footer>
</div>
