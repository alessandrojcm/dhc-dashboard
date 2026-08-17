<script lang="ts">
import { resolve } from "$app/paths";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import * as Dialog from "$lib/components/ui/dialog";
import { Input } from "$lib/components/ui/input";
import { Progress } from "$lib/components/ui/progress";
import { Skeleton } from "$lib/components/ui/skeleton";
import type { WorkshopCalendarEvent } from "$lib/types";
import type { WorkshopCalendarItem } from "@dhc/api-client";
import {
	CalendarDays,
	Clock3,
	MapPin,
	Pencil,
	Search,
	Settings2,
	UserRoundCheck,
	Users,
} from "@lucide/svelte";
import dayjs from "dayjs";
import WorkshopEventModal from "./workshop-event-modal.svelte";

type StatusFilter = "all" | WorkshopCalendarItem["status"];

let {
	workshops = [],
	userId,
	isLoading = false,
	handleEdit,
}: {
	workshops: WorkshopCalendarItem[];
	userId?: string;
	isLoading?: boolean;
	handleEdit?: (workshop: WorkshopCalendarItem) => void;
} = $props();

const statusFilters: { label: string; value: StatusFilter }[] = [
	{ label: "All", value: "all" },
	{ label: "Planned", value: "planned" },
	{ label: "Published", value: "published" },
	{ label: "Finished", value: "finished" },
	{ label: "Cancelled", value: "cancelled" },
];

let search = $state("");
let statusFilter = $state<StatusFilter>("all");
let selectedEvent = $state<WorkshopCalendarEvent | null>(null);
let dialogOpen = $state(false);

const filteredWorkshops = $derived.by(() => {
	const query = search.trim().toLocaleLowerCase();

	return [...workshops]
		.filter((workshop) => {
			const matchesStatus =
				statusFilter === "all" || workshop.status === statusFilter;
			const matchesSearch =
				query.length === 0 ||
				workshop.title.toLocaleLowerCase().includes(query) ||
				workshop.location?.toLocaleLowerCase().includes(query);

			return matchesStatus && matchesSearch;
		})
		.sort((first, second) => {
			const firstIsPast = dayjs(first.endDate).isBefore(dayjs());
			const secondIsPast = dayjs(second.endDate).isBefore(dayjs());

			if (firstIsPast !== secondIsPast) return firstIsPast ? 1 : -1;
			return (
				dayjs(first.startDate).valueOf() - dayjs(second.startDate).valueOf()
			);
		});
});

function getRegistrationCount(workshop: WorkshopCalendarItem) {
	return (
		workshop.pendingRegistrationCount + workshop.confirmedRegistrationCount
	);
}

function getCapacityPercentage(workshop: WorkshopCalendarItem) {
	if (!workshop.maxCapacity) return 0;
	return Math.min(
		100,
		Math.round((getRegistrationCount(workshop) / workshop.maxCapacity) * 100),
	);
}

function getStatusVariant(status: WorkshopCalendarItem["status"]) {
	if (status === "planned") return "secondary" as const;
	if (status === "cancelled") return "destructive" as const;
	if (status === "finished") return "outline" as const;
	return "default" as const;
}

function openManager(workshop: WorkshopCalendarItem) {
	selectedEvent = {
		id: workshop.id,
		title: workshop.title,
		start: workshop.startDate,
		end: workshop.endDate,
		workshop,
		isInterested: false,
		isLoading,
		userId: userId ?? "",
		handleEdit,
	};
	dialogOpen = true;
}

function clearFilters() {
	search = "";
	statusFilter = "all";
}
</script>

<section class="space-y-5" aria-labelledby="workshop-management-heading">
	<div class="space-y-4 rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
		<div
			class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between"
		>
			<div>
				<h2 id="workshop-management-heading" class="text-xl font-bold">
					Workshop management
				</h2>
				<p class="mt-1 text-sm text-muted-foreground">
					Find a workshop and jump straight to the next task.
				</p>
			</div>
			<p class="text-sm font-medium text-muted-foreground" aria-live="polite">
				{filteredWorkshops.length}
				{filteredWorkshops.length === 1 ? "workshop" : "workshops"}
			</p>
		</div>

		<div class="grid gap-3 lg:grid-cols-[minmax(16rem,1fr)_auto]">
			<div class="relative">
				<label for="workshop-search" class="sr-only">Search workshops</label>
				<Search
					aria-hidden="true"
					class="pointer-events-none absolute top-1/2 left-3.5 size-4 -translate-y-1/2 text-muted-foreground"
				/>
				<Input
					id="workshop-search"
					bind:value={search}
					placeholder="Search by title or location"
					class="h-11 pl-10"
					autocomplete="off"
				/>
			</div>

			<div
				class="-mx-1 flex gap-2 overflow-x-auto px-1 pb-1 lg:justify-end"
				aria-label="Filter workshops by status"
			>
				{#each statusFilters as filter (filter.value)}
					<Button
						variant={statusFilter === filter.value ? "secondary" : "outline"}
						size="sm"
						class="min-h-11 shrink-0"
						aria-pressed={statusFilter === filter.value}
						onclick={() => (statusFilter = filter.value)}
					>
						{filter.label}
					</Button>
				{/each}
			</div>
		</div>
	</div>

	{#if isLoading}
		<div class="space-y-3" aria-label="Loading workshops">
			{#each { length: 3 } as _, index (index)}
				<div class="rounded-2xl border border-border/80 bg-card p-5">
					<div class="flex gap-4">
						<Skeleton class="h-16 w-16 shrink-0 rounded-xl" />
						<div class="flex-1 space-y-3">
							<Skeleton class="h-5 w-2/3" />
							<Skeleton class="h-4 w-1/2" />
							<Skeleton class="h-10 w-full" />
						</div>
					</div>
				</div>
			{/each}
		</div>
	{:else if filteredWorkshops.length === 0}
		<div
			class="rounded-2xl border border-dashed border-border bg-card px-6 py-12 text-center"
		>
			<CalendarDays
				aria-hidden="true"
				class="mx-auto size-10 text-muted-foreground"
			/>
			<h3 class="mt-4 text-lg font-bold">No matching workshops</h3>
			<p class="mx-auto mt-2 max-w-md text-sm text-muted-foreground">
				Try another title, location, or status to find the workshop you need.
			</p>
			<Button variant="outline" class="mt-5" onclick={clearFilters}>
				Clear filters
			</Button>
		</div>
	{:else}
		<div class="space-y-3">
			{#each filteredWorkshops as workshop (workshop.id)}
				{@const registrationCount = getRegistrationCount(workshop)}
				{@const isPast = dayjs(workshop.endDate).isBefore(dayjs())}
				<article
					class="grid gap-5 rounded-2xl border border-border/80 bg-card p-4 shadow-sm transition-[border-color,box-shadow] duration-200 hover:border-primary/40 hover:shadow-md sm:p-5 lg:grid-cols-[minmax(0,1.35fr)_minmax(15rem,0.7fr)_auto] lg:items-center"
				>
					<div class="flex min-w-0 items-start gap-3 sm:gap-4">
						<div
							class="flex h-16 w-16 shrink-0 flex-col items-center justify-center rounded-xl border border-primary/20 bg-primary/5 text-primary"
							aria-hidden="true"
						>
							<span class="text-[0.65rem] font-bold tracking-wider uppercase">
								{dayjs(workshop.startDate).format("MMM")}
							</span>
							<span class="text-2xl font-bold leading-none">
								{dayjs(workshop.startDate).format("D")}
							</span>
						</div>

						<div class="min-w-0 flex-1">
							<div class="flex flex-wrap items-center gap-2">
								<Badge
									variant={getStatusVariant(workshop.status)}
									class="capitalize"
								>
									{workshop.status}
								</Badge>
								{#if workshop.isPublic}
									<Badge variant="outline">Public</Badge>
								{/if}
								{#if isPast}
									<Badge variant="outline" class="text-muted-foreground"
										>Past</Badge
									>
								{/if}
							</div>
							<h3 class="mt-2 text-lg font-bold leading-snug text-foreground">
								{workshop.title}
							</h3>
							<div
								class="mt-3 grid gap-x-4 gap-y-2 text-sm text-muted-foreground sm:grid-cols-2"
							>
								<span class="flex min-w-0 items-center gap-2">
									<Clock3 aria-hidden="true" class="size-4 shrink-0" />
									<span>
										{dayjs(workshop.startDate).format("ddd, D MMM · h:mm A")}
									</span>
								</span>
								<span class="flex min-w-0 items-center gap-2">
									<MapPin aria-hidden="true" class="size-4 shrink-0" />
									<span class="truncate"
										>{workshop.location || "Location not set"}</span
									>
								</span>
							</div>
						</div>
					</div>

					<div class="rounded-xl border border-border/70 bg-muted/25 p-3.5">
						{#if workshop.status === "planned"}
							<div class="flex items-center gap-3">
								<Users aria-hidden="true" class="size-5 text-primary" />
								<div>
									<p class="font-bold text-foreground">
										{workshop.interestCount} interested
									</p>
									<p class="text-xs text-muted-foreground">Before publishing</p>
								</div>
							</div>
						{:else}
							<div class="flex items-center justify-between gap-3">
								<span class="flex items-center gap-2 text-sm font-bold">
									<UserRoundCheck
										aria-hidden="true"
										class="size-5 text-primary"
									/>
									Registrations
								</span>
								<span class="text-sm font-bold">
									{registrationCount}{workshop.maxCapacity
										? ` / ${workshop.maxCapacity}`
										: ""}
								</span>
							</div>
							{#if workshop.maxCapacity}
								<Progress
									value={getCapacityPercentage(workshop)}
									class="mt-3"
									aria-label={`${registrationCount} of ${workshop.maxCapacity} places registered`}
								/>
							{/if}
						{/if}
					</div>

					<div class="grid grid-cols-2 gap-2 sm:flex lg:justify-end">
						{#if workshop.status === "published"}
							<Button
								href={resolve("/dashboard/workshops/[id]/attendees", {
									id: workshop.id,
								})}
								class="col-span-2 min-h-11 sm:col-span-1"
							>
								<UserRoundCheck aria-hidden="true" />
								Attendees
							</Button>
						{/if}
						<Button
							variant={workshop.status === "published" ? "outline" : "default"}
							onclick={() => openManager(workshop)}
							class="min-h-11"
						>
							<Settings2 aria-hidden="true" />
							Manage
						</Button>
						<Button
							variant="outline"
							href={resolve("/dashboard/workshops/[id]/edit", {
								id: workshop.id,
							})}
							class="min-h-11"
						>
							<Pencil aria-hidden="true" />
							Edit
						</Button>
					</div>
				</article>
			{/each}
		</div>
	{/if}
</section>

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content
		class="max-h-[calc(100dvh-2rem)] max-w-2xl gap-0 overflow-hidden p-0 sm:max-w-2xl"
		showCloseButton={false}
	>
		{#if selectedEvent}
			<WorkshopEventModal
				calendarEvent={selectedEvent}
				onClose={() => (dialogOpen = false)}
			/>
		{/if}
	</Dialog.Content>
</Dialog.Root>
