<script lang="ts">
import { resolve } from "$app/paths";
import { Alert, AlertDescription, AlertTitle } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import AttendeeManager from "$lib/components/workshops/attendee-manager.svelte";
import {
	workshopsAttendeesOptions,
	workshopsAttendeesQueryKey,
	type WorkshopSummary,
} from "@dhc/api-client";
import {
	TriangleAlert,
	ArrowLeft,
	CalendarDays,
	Clock3,
	MapPin,
	UserCheck,
	Users,
} from "@lucide/svelte";
import { createQuery, useQueryClient } from "@tanstack/svelte-query";
import dayjs from "dayjs";

let { data } = $props();
const workshopId = $derived(data.attendeesResponse.data.workshop.id);
const queryClient = useQueryClient();

// Single Phoenix read (`GET /api/workshops/{id}/attendees`) via the generated
// TanStack Query options. The Supabase JWT is attached by `configureClient`'s
// `getAuthToken` hook; authz is enforced by Phoenix's `workshop_management_api`
// pipeline, so no SvelteKit `authorize()` gate is needed. Replaces the two
// browser-side PostgREST joins over `club_activity_registrations` /
// `club_activity_refunds` with the normalized combined DTO (`participant.type`
// / `displayName` / `email` instead of `user_profiles` / `external_users`
// join shapes). `initialData` is the SSR envelope from `+page.server.ts`.
const attendeesQuery = createQuery(() => ({
	...workshopsAttendeesOptions({ path: { id: workshopId } }),
	initialData: data.attendeesResponse,
}));

const payload = $derived(attendeesQuery.data?.data);
const attendees = $derived(payload?.attendees ?? []);
const refunds = $derived(payload?.refunds ?? []);
const workshop = $derived(payload?.workshop);
const checkedInCount = $derived(
	attendees.filter((attendee) => attendee.attendanceStatus === "attended")
		.length,
);
const awaitingCount = $derived(
	attendees.filter((attendee) => attendee.attendanceStatus === "pending")
		.length,
);

function invalidateAttendees() {
	queryClient.invalidateQueries({
		queryKey: workshopsAttendeesQueryKey({ path: { id: workshopId } }),
	});
}

function getStatusVariant(status: WorkshopSummary["status"]) {
	if (status === "planned") return "secondary" as const;
	if (status === "cancelled") return "destructive" as const;
	if (status === "finished") return "outline" as const;
	return "default" as const;
}

function formatWorkshopDate(startDate?: string | null) {
	if (!startDate) return "Date not set";
	return dayjs(startDate).format("ddd, D MMM YYYY · h:mm A");
}
</script>

<svelte:head>
	<title>{workshop?.title ?? "Workshop"} attendance | Dublin HEMA Club</title>
</svelte:head>

<div
	class="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-10"
>
	<Button
		href={resolve("/dashboard/workshops")}
		variant="ghost"
		class="-ml-3 w-fit text-muted-foreground hover:text-foreground"
	>
		<ArrowLeft aria-hidden="true" />
		Back to workshops
	</Button>

	{#if attendeesQuery.isLoading}
		<div class="space-y-6" aria-label="Loading attendance desk">
			<div class="space-y-3 border-b border-border/80 pb-6">
				<Skeleton class="h-4 w-36" />
				<Skeleton class="h-10 w-2/3 max-w-xl" />
				<Skeleton class="h-5 w-full max-w-2xl" />
			</div>
			<div class="grid gap-3 sm:grid-cols-3">
				{#each { length: 3 } as _, index (index)}
					<Skeleton class="h-28 rounded-2xl" />
				{/each}
			</div>
			<Skeleton class="h-80 rounded-2xl" />
		</div>
	{:else if attendeesQuery.error}
		<Alert variant="destructive">
			<TriangleAlert aria-hidden="true" />
			<AlertTitle>Attendance data could not be loaded</AlertTitle>
			<AlertDescription>
				Refresh the page to try again. If the problem continues, check the
				workshop service before using the attendance desk.
			</AlertDescription>
		</Alert>
	{:else if workshop}
		<header
			class="flex flex-col gap-5 border-b border-border/80 pb-6 lg:flex-row lg:items-end lg:justify-between"
		>
			<div class="max-w-3xl">
				<div class="flex flex-wrap items-center gap-2">
					<p
						class="mr-1 text-xs font-bold tracking-[0.18em] text-primary uppercase"
					>
						Workshop attendance
					</p>
					<Badge variant={getStatusVariant(workshop.status)} class="capitalize">
						{workshop.status}
					</Badge>
					<Badge variant="outline">
						{workshop.isPublic ? "Public" : "Members only"}
					</Badge>
				</div>
				<h1 class="mt-3 text-3xl font-bold tracking-tight sm:text-4xl">
					{workshop.title}
				</h1>
				<p class="mt-2 text-base leading-7 text-muted-foreground">
					Check in participants and manage registration issues.
				</p>
			</div>

			<div
				class="grid gap-2 text-sm text-muted-foreground sm:grid-cols-2 lg:max-w-md lg:grid-cols-1"
			>
				<p class="flex items-start gap-2">
					<CalendarDays
						aria-hidden="true"
						class="mt-0.5 size-4 shrink-0 text-primary"
					/>
					<span>{formatWorkshopDate(workshop.startDate)}</span>
				</p>
				<p class="flex items-start gap-2">
					<MapPin
						aria-hidden="true"
						class="mt-0.5 size-4 shrink-0 text-primary"
					/>
					<span>{workshop.location || "Location not set"}</span>
				</p>
			</div>
		</header>

		<section class="grid gap-3 sm:grid-cols-3" aria-label="Attendance overview">
			<div
				role="group"
				aria-label="Registration capacity"
				class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5"
			>
				<div class="flex items-center justify-between gap-3">
					<p class="text-sm font-medium text-muted-foreground">Registered</p>
					<Users aria-hidden="true" class="size-5 text-primary" />
				</div>
				<p class="mt-2 text-2xl font-bold tabular-nums">
					{workshop.registrationCount}
				</p>
				<p class="mt-1 text-xs text-muted-foreground">
					{workshop.placesRemaining === null
						? "No capacity limit"
						: `${workshop.placesRemaining} places remaining`}
				</p>
			</div>

			<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
				<div class="flex items-center justify-between gap-3">
					<p class="text-sm font-medium text-muted-foreground">Checked in</p>
					<UserCheck aria-hidden="true" class="size-5 text-primary" />
				</div>
				<p class="mt-2 text-2xl font-bold tabular-nums">{checkedInCount}</p>
				<p class="mt-1 text-xs text-muted-foreground">Attendance confirmed</p>
			</div>

			<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
				<div class="flex items-center justify-between gap-3">
					<p class="text-sm font-medium text-muted-foreground">Awaiting</p>
					<Clock3 aria-hidden="true" class="size-5 text-primary" />
				</div>
				<p class="mt-2 text-2xl font-bold tabular-nums">{awaitingCount}</p>
				<p class="mt-1 text-xs text-muted-foreground">Ready to check in</p>
			</div>
		</section>

		<AttendeeManager
			{attendees}
			{refunds}
			{workshop}
			{workshopId}
			onAttendanceUpdated={invalidateAttendees}
			onRefundProcessed={invalidateAttendees}
		/>
	{/if}
</div>
