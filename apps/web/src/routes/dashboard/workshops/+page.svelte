<script lang="ts">
import { goto } from "$app/navigation";
import { resolve } from "$app/paths";
import { Button } from "$lib/components/ui/button";
import { Alert, AlertDescription } from "$lib/components/ui/alert";
import * as Tabs from "$lib/components/ui/tabs";
import WorkshopCalendar from "$lib/components/workshops/workshop-calendar.svelte";
import WorkshopManagementList from "$lib/components/workshops/workshop-management-list.svelte";
import QuickCreateWorkshop from "$lib/components/workshops/quick-create-workshop.svelte";
import {
	workshopsCalendarOptions,
	type WorkshopCalendarItem,
} from "@dhc/api-client";
import { createQuery } from "@tanstack/svelte-query";
import {
	CalendarDays,
	CircleDotDashed,
	ClipboardCheck,
	ListChecks,
	Plus,
	Radio,
	Users,
} from "@lucide/svelte";

let { data } = $props();
const workshopsQuery = createQuery(() => ({
	...workshopsCalendarOptions(),
	select: (response) => {
		return response.data.workshops;
	},
}));

const workshops = $derived(workshopsQuery.data ?? []);
const upcomingCount = $derived(
	workshops.filter(
		(workshop) =>
			workshop.status !== "cancelled" &&
			new Date(workshop.endDate).getTime() >= Date.now(),
	).length,
);
const plannedCount = $derived(
	workshops.filter((workshop) => workshop.status === "planned").length,
);
const publishedCount = $derived(
	workshops.filter((workshop) => workshop.status === "published").length,
);
const registrationCount = $derived(
	workshops.reduce((total, workshop) => total + workshop.registrationCount, 0),
);

function handleCreate() {
	goto(resolve("/dashboard/workshops/create"));
}

function handleEdit(workshop: WorkshopCalendarItem) {
	goto(resolve("/dashboard/workshops/[id]/edit", { id: workshop.id }));
}
</script>

<svelte:head>
	<title>Manage workshops | Dublin HEMA Club</title>
</svelte:head>

<div
	class="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-6 sm:px-6 lg:px-8 lg:py-10"
>
	<header
		class="order-1 flex flex-col gap-5 border-b border-border/80 pb-6 sm:flex-row sm:items-end sm:justify-between"
	>
		<div class="max-w-2xl space-y-2">
			<p class="text-xs font-bold tracking-[0.18em] text-primary uppercase">
				Workshops
			</p>
			<h1 class="text-3xl font-bold tracking-tight sm:text-4xl">
				Manage workshops
			</h1>
			<p class="text-base leading-7 text-muted-foreground">
				Create workshops, open registration, and manage attendance.
			</p>
		</div>

		<div class="grid w-full grid-cols-1 gap-2 sm:flex sm:w-auto">
			<QuickCreateWorkshop />
			<Button onclick={handleCreate} class="w-full sm:w-auto">
				<Plus aria-hidden="true" />
				Create workshop
			</Button>
		</div>
	</header>

	{#if workshopsQuery.error?.errors}
		<Alert variant="destructive" class="order-2">
			<AlertDescription>{workshopsQuery.error.errors?.detail}</AlertDescription>
		</Alert>
	{/if}

	<section
		aria-label="Workshop overview"
		class="order-4 grid grid-cols-2 gap-3 sm:order-3 lg:grid-cols-4"
	>
		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">Upcoming</p>
				<CalendarDays aria-hidden="true" class="size-5 text-primary" />
			</div>
			<p class="mt-2 text-2xl font-bold">{upcomingCount}</p>
		</div>
		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">
					Needs publishing
				</p>
				<CircleDotDashed aria-hidden="true" class="size-5 text-primary" />
			</div>
			<p class="mt-2 text-2xl font-bold">{plannedCount}</p>
		</div>
		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">Published</p>
				<Radio aria-hidden="true" class="size-5 text-primary" />
			</div>
			<p class="mt-2 text-2xl font-bold">{publishedCount}</p>
		</div>
		<div class="rounded-2xl border border-border/80 bg-card p-4 sm:p-5">
			<div class="flex items-center justify-between gap-3">
				<p class="text-sm font-medium text-muted-foreground">Registrations</p>
				<Users aria-hidden="true" class="size-5 text-primary" />
			</div>
			<p class="mt-2 text-2xl font-bold">{registrationCount}</p>
		</div>
	</section>

	<Tabs.Root value="manage" class="order-3 gap-5 sm:order-4">
		<Tabs.List
			class="hidden h-12 w-fit p-1 sm:inline-flex"
			aria-label="Workshop views"
		>
			<Tabs.Trigger value="manage" class="min-h-10 px-4 sm:min-w-36">
				<ListChecks aria-hidden="true" />
				Manage
			</Tabs.Trigger>
			<Tabs.Trigger value="calendar" class="min-h-10 px-4 sm:min-w-36">
				<ClipboardCheck aria-hidden="true" />
				Calendar
			</Tabs.Trigger>
		</Tabs.List>

		<Tabs.Content value="manage">
			<WorkshopManagementList
				{handleEdit}
				isLoading={workshopsQuery.isLoading}
				{workshops}
				userId={data.user!.id}
			/>
		</Tabs.Content>

		<Tabs.Content value="calendar" class="max-sm:hidden">
			<div class="space-y-3">
				<div>
					<h2 class="text-xl font-bold">Calendar overview</h2>
					<p class="mt-1 text-sm text-muted-foreground">
						Scan the month, then select a workshop to inspect registration
						health and actions.
					</p>
				</div>
				<WorkshopCalendar
					{handleEdit}
					isLoading={workshopsQuery.isLoading}
					{workshops}
					userId={data.user!.id}
				/>
			</div>
		</Tabs.Content>
	</Tabs.Root>
</div>
