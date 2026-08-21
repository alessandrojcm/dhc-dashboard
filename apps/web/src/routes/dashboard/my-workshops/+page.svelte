<script lang="ts">
import {
	createMutation,
	createQuery,
	useQueryClient,
} from "@tanstack/svelte-query";
import WorkshopList from "$lib/components/workshops/workshop-list.svelte";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import { Badge } from "$lib/components/ui/badge";
import { Button } from "$lib/components/ui/button";
import { Skeleton } from "$lib/components/ui/skeleton";
import * as Tabs from "$lib/components/ui/tabs";
import { toast } from "svelte-sonner";
import { CalendarCheck2, Heart, RefreshCw, TicketCheck } from "@lucide/svelte";
import {
	workshopsListOptions,
	workshopsListQueryKey,
	workshopsToggleInterestMutation,
	type Workshop,
} from "@dhc/api-client";

const queryClient = useQueryClient();
let activeTab = $state("bookable");

const plannedWorkshopsQuery = createQuery(() => ({
	...workshopsListOptions({ query: { status: "planned" } }),
	select: (response) => response.data.workshops,
}));

const publishedWorkshopsQuery = createQuery(() => ({
	...workshopsListOptions({ query: { status: "published" } }),
	select: (response) => response.data.workshops,
}));

const publishedWorkshops = $derived(publishedWorkshopsQuery.data ?? []);
const plannedWorkshops = $derived(plannedWorkshopsQuery.data ?? []);
const bookedCount = $derived(
	publishedWorkshops.filter(hasActiveRegistration).length,
);
const openCount = $derived(
	publishedWorkshops.filter(
		(workshop) => !hasActiveRegistration(workshop) && !workshop.isAtCapacity,
	).length,
);
const interestedCount = $derived(
	plannedWorkshops.filter((workshop) => workshop.currentUserInterest).length,
);

const interestMutation = createMutation(() => ({
	...workshopsToggleInterestMutation(),
	onSuccess: (data) => {
		queryClient.invalidateQueries({
			queryKey: workshopsListQueryKey({ query: { status: "planned" } }),
		});
		toast.success(data.data.message);
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Failed to manage interest");
	},
}));

function hasActiveRegistration(workshop: Workshop) {
	return ["pending", "confirmed"].includes(
		workshop.currentUserRegistration?.status ?? "",
	);
}

function handleInterestToggle(workshopId: string) {
	interestMutation.mutate({ path: { workshopId } });
}
</script>

<svelte:head>
	<title>My workshops | Dublin HEMA Club</title>
</svelte:head>

<div
	class="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-10"
>
	<header class="border-b border-border/80 pb-6">
		<div class="max-w-3xl space-y-2">
			<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
				Member workshops
			</p>
			<h1 class="text-3xl font-bold tracking-tight sm:text-4xl">
				My workshops
			</h1>
			<p class="text-base leading-7 text-muted-foreground">
				Book training sessions, manage your registrations, and help shape what
				the club runs next.
			</p>
		</div>
	</header>

	<section
		aria-label="My workshop overview"
		class="grid grid-cols-1 gap-3 sm:grid-cols-3"
	>
		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">Booked</p>
				<CalendarCheck2 aria-hidden="true" class="size-5 text-primary" />
			</div>
			{#if publishedWorkshopsQuery.isLoading}
				<Skeleton class="mt-3 h-8 w-12" />
			{:else}
				<p class="mt-2 text-2xl font-bold">{bookedCount}</p>
			{/if}
			<p class="mt-1 text-xs text-muted-foreground">
				Sessions you’re attending
			</p>
		</div>

		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">
					Open for booking
				</p>
				<TicketCheck aria-hidden="true" class="size-5 text-primary" />
			</div>
			{#if publishedWorkshopsQuery.isLoading}
				<Skeleton class="mt-3 h-8 w-12" />
			{:else}
				<p class="mt-2 text-2xl font-bold">{openCount}</p>
			{/if}
			<p class="mt-1 text-xs text-muted-foreground">
				Sessions with places left
			</p>
		</div>

		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">Interested</p>
				<Heart aria-hidden="true" class="size-5 text-primary" />
			</div>
			{#if plannedWorkshopsQuery.isLoading}
				<Skeleton class="mt-3 h-8 w-12" />
			{:else}
				<p class="mt-2 text-2xl font-bold">{interestedCount}</p>
			{/if}
			<p class="mt-1 text-xs text-muted-foreground">
				Ideas you want to see run
			</p>
		</div>
	</section>

	<Tabs.Root bind:value={activeTab} class="gap-5">
		<Tabs.List
			class="grid h-auto w-full grid-cols-2 p-1 sm:inline-grid sm:w-auto sm:min-w-[24rem]"
			aria-label="Member workshop views"
		>
			<Tabs.Trigger value="bookable" class="min-h-11 gap-2 px-3 sm:px-5">
				<TicketCheck aria-hidden="true" />
				Book now
				{#if !publishedWorkshopsQuery.isLoading}
					<Badge variant="secondary" class="ml-1 min-w-6 justify-center px-1.5">
						{publishedWorkshops.length}
					</Badge>
				{/if}
			</Tabs.Trigger>
			<Tabs.Trigger value="planned" class="min-h-11 gap-2 px-3 sm:px-5">
				<Heart aria-hidden="true" />
				Coming soon
				{#if !plannedWorkshopsQuery.isLoading}
					<Badge variant="secondary" class="ml-1 min-w-6 justify-center px-1.5">
						{plannedWorkshops.length}
					</Badge>
				{/if}
			</Tabs.Trigger>
		</Tabs.List>

		<Tabs.Content value="bookable">
			{#if publishedWorkshopsQuery.isLoading}
				<div class="space-y-3" aria-label="Loading workshops">
					{#each { length: 3 } as _, index (index)}
						<div class="rounded-2xl border border-border/80 bg-card p-5">
							<div class="flex gap-4">
								<Skeleton class="size-16 shrink-0 rounded-xl" />
								<div class="flex-1 space-y-3">
									<Skeleton class="h-5 w-2/3" />
									<Skeleton class="h-4 w-full max-w-xl" />
									<Skeleton class="h-4 w-1/2" />
								</div>
							</div>
						</div>
					{/each}
				</div>
			{:else if publishedWorkshopsQuery.error}
				<Alert variant="destructive">
					<AlertDescription
						class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
					>
						<span>
							{publishedWorkshopsQuery.error.errors?.detail ??
								"We couldn’t load the workshops open for booking."}
						</span>
						<Button
							variant="outline"
							size="sm"
							class="min-h-10"
							onclick={() => publishedWorkshopsQuery.refetch()}
						>
							<RefreshCw aria-hidden="true" />
							Try again
						</Button>
					</AlertDescription>
				</Alert>
			{:else}
				<WorkshopList workshops={publishedWorkshops} view="bookable" />
			{/if}
		</Tabs.Content>

		<Tabs.Content value="planned">
			{#if plannedWorkshopsQuery.isLoading}
				<div class="space-y-3" aria-label="Loading planned workshops">
					{#each { length: 2 } as _, index (index)}
						<div class="rounded-2xl border border-border/80 bg-card p-5">
							<div class="flex gap-4">
								<Skeleton class="size-16 shrink-0 rounded-xl" />
								<div class="flex-1 space-y-3">
									<Skeleton class="h-5 w-2/3" />
									<Skeleton class="h-4 w-full max-w-xl" />
									<Skeleton class="h-4 w-1/2" />
								</div>
							</div>
						</div>
					{/each}
				</div>
			{:else if plannedWorkshopsQuery.error}
				<Alert variant="destructive">
					<AlertDescription
						class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"
					>
						<span>
							{plannedWorkshopsQuery.error.errors?.detail ??
								"We couldn’t load the workshops being planned."}
						</span>
						<Button
							variant="outline"
							size="sm"
							class="min-h-10"
							onclick={() => plannedWorkshopsQuery.refetch()}
						>
							<RefreshCw aria-hidden="true" />
							Try again
						</Button>
					</AlertDescription>
				</Alert>
			{:else}
				<WorkshopList
					workshops={plannedWorkshops}
					view="planned"
					onInterestToggle={handleInterestToggle}
					isLoading={interestMutation.isPending}
				/>
			{/if}
		</Tabs.Content>
	</Tabs.Root>
</div>
