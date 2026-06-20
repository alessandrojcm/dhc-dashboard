<script lang="ts">
import {
	createQuery,
	createMutation,
	useQueryClient,
} from "@tanstack/svelte-query";
import WorkshopList from "$lib/components/workshops/workshop-list.svelte";
import {
	Card,
	CardContent,
	CardDescription,
	CardHeader,
	CardTitle,
} from "$lib/components/ui/card";
import { Skeleton } from "$lib/components/ui/skeleton";
import {
	Tabs,
	TabsContent,
	TabsList,
	TabsTrigger,
} from "$lib/components/ui/tabs/index.js";
import { toast } from "svelte-sonner";
import { CalendarDays } from "lucide-svelte";
import { workshopsList } from "@dhc/api-client";
import { toggleInterest } from "./registration.remote";

const queryClient = useQueryClient();
let activeTab = $state("published");

async function loadWorkshops(
	status: "planned" | "published",
	signal: AbortSignal,
) {
	const response = await workshopsList({
		query: { status },
		signal,
	});

	if (response.error) {
		throw new Error("Failed to load workshops. Please try again later.");
	}

	return response.data.data.workshops;
}

const workshopsQuery = createQuery(() => ({
	queryKey: ["workshops", "planned"],
	queryFn: ({ signal }) => loadWorkshops("planned", signal),
}));

const publishedWorkshopsQuery = createQuery(() => ({
	queryKey: ["workshops", "published"],
	queryFn: ({ signal }) => loadWorkshops("published", signal),
}));

const interestMutation = createMutation(() => ({
	mutationFn: async (workshopId: string) => {
		return await toggleInterest(workshopId);
	},
	onSuccess: (data) => {
		queryClient.invalidateQueries({ queryKey: ["workshops", "planned"] });
		queryClient.invalidateQueries({ queryKey: ["workshops", "published"] });
		toast.success(data.message);
	},
	onError: (error) => {
		toast.error(
			error instanceof Error ? error.message : "Failed to manage interest",
		);
	},
}));

const handleInterestToggle = (workshopId: string) => {
	interestMutation.mutate(workshopId);
};
</script>

<div class="container mx-auto p-6 space-y-6">
	<div class="flex items-center gap-2">
		<CalendarDays class="w-6 h-6" />
		<h1 class="text-2xl font-bold">My Workshops</h1>
	</div>

	<Tabs bind:value={activeTab}>
		<TabsList>
			<TabsTrigger value="published">Upcoming</TabsTrigger>
			<TabsTrigger value="planned">Planned</TabsTrigger>
		</TabsList>

		<TabsContent value="published">
			{#if publishedWorkshopsQuery.isLoading}
				<div class="space-y-4">
					<!-- eslint-disable-next-line @typescript-eslint/no-unused-vars -->
					{#each Array(3) as _, index (index)}
						<Skeleton class="h-32 w-full" />
					{/each}
				</div>
			{:else if publishedWorkshopsQuery.error}
				<Card>
					<CardContent class="pt-6">
						<p class="text-destructive">
							Error loading workshops: {publishedWorkshopsQuery.error.message}
						</p>
					</CardContent>
				</Card>
			{:else}
				<Card>
					<CardHeader>
						<CardTitle>Upcoming Workshops</CardTitle>
						<CardDescription>View upcoming workshops and sign up for them</CardDescription>
					</CardHeader>
					<CardContent>
						<WorkshopList
							workshops={publishedWorkshopsQuery.data ?? []}
							onInterestToggle={handleInterestToggle}
							isLoading={interestMutation.isPending}
						/>
					</CardContent>
				</Card>
			{/if}
		</TabsContent>

		<TabsContent value="planned">
			{#if workshopsQuery.isLoading}
				<div class="space-y-4">
					<!-- eslint-disable-next-line @typescript-eslint/no-unused-vars -->
					{#each Array(3) as _, index (index)}
						<Skeleton class="h-32 w-full" />
					{/each}
				</div>
			{:else if workshopsQuery.error}
				<Card>
					<CardContent class="pt-6">
						<p class="text-destructive">Error loading workshops: {workshopsQuery.error.message}</p>
					</CardContent>
				</Card>
			{:else}
				<Card>
					<CardHeader>
						<CardTitle>Planned Workshops</CardTitle>
						<CardDescription>View planned workshops and express your interest</CardDescription>
					</CardHeader>
					<CardContent>
						<WorkshopList
							workshops={workshopsQuery.data ?? []}
							onInterestToggle={handleInterestToggle}
							isLoading={interestMutation.isPending}
						/>
					</CardContent>
				</Card>
			{/if}
		</TabsContent>
	</Tabs>
</div>
