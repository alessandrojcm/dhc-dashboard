<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import { Lock, LockOpen } from "lucide-svelte";
import { toast } from "svelte-sonner";
import { goto, invalidate } from "$app/navigation";
import { resolve } from "$app/paths";
import { page } from "$app/state";
import * as AlertDialog from "$lib/components/ui/alert-dialog/index.js";
import Button from "$lib/components/ui/button/button.svelte";
import LoaderCircle from "$lib/components/ui/loader-circle.svelte";
import * as Select from "$lib/components/ui/select";
import { Content, List, Root, Trigger } from "$lib/components/ui/tabs/index.js";
import WaitlistTable from "./waitlist-table.svelte";
import Analytics from "./workshop-analytics.svelte";

const { data } = $props();
const supabase = data.supabase;
let dialogOpen = $state(false);
let value = $derived(page.url.searchParams.get("tab") || "dashboard");

const toggleWaitlistMutation = createMutation(() => ({
	mutationFn: async () => {
		const response = await fetch("/dashboard/beginners-workshop", {
			method: "POST",
		});
		const result = (await response.json()) as {
			success: boolean;
			error?: string;
		};
		if (!result.success) {
			throw new Error(result.error || "Failed to toggle waitlist");
		}
		return result;
	},
	onSuccess: () => {
		invalidate("wailist:status");
		toast.success("Waitlist status updated", { position: "top-center" });
		dialogOpen = false;
	},
	onError: (error) => {
		toast.error(error.message || "Error updating waitlist status", {
			position: "top-center",
		});
		dialogOpen = false;
	},
}));

type BeginnersWorkshopUrl = `/dashboard/beginners-workshop?${string}`;

function onTabChange(value: string) {
	// eslint-disable-next-line svelte/prefer-svelte-reactivity
	const newParams = new URLSearchParams(page.url.searchParams);
	newParams.set("tab", value);
	const url =
		`/dashboard/beginners-workshop?${newParams.toString()}` as BeginnersWorkshopUrl;
	goto(resolve(url));
}
let views = [
	{
		id: "dashboard",
		label: "Dashboard",
	},
	{
		id: "waitlist",
		label: "Waitlist",
	},
];
let viewLabel = $derived(
	views.find((view) => view.id === value)?.label || "Dashboard",
);
</script>

{#snippet waitlistToggleDialog()}
	{#if data.canToggleWaitlist}
		{#await data.isWaitlistOpen then isOpen}
			<AlertDialog.Root bind:open={dialogOpen}>
				<AlertDialog.Trigger class="fixed right-4 top-4">
					<Button variant="outline" onclick={() => (dialogOpen = true)}>
						{#if isOpen}
							<LockOpen class="w-4 h-4" />
							<p class="hidden md:block">Close Waitlist</p>
						{:else}
							<Lock class="w-4 h-4" />
							<p class="hidden md:block">Open Waitlist</p>
						{/if}
					</Button>
				</AlertDialog.Trigger>
				<AlertDialog.Content>
					<AlertDialog.Header>
						<AlertDialog.Title>{isOpen ? 'Close' : 'Open'} waitlist</AlertDialog.Title>
						<AlertDialog.Description>
							Are you sure you want to {isOpen ? 'close' : 'open'} the waitlist? This action will affect
							new registrations.
						</AlertDialog.Description>
					</AlertDialog.Header>
					<AlertDialog.Footer>
						<AlertDialog.Cancel onclick={() => (dialogOpen = false)}>Cancel</AlertDialog.Cancel>
						<AlertDialog.Action onclick={() => toggleWaitlistMutation.mutate()} data-testid="action"
							>{isOpen ? 'Close' : 'Open'}</AlertDialog.Action
						>
					</AlertDialog.Footer>
				</AlertDialog.Content>
			</AlertDialog.Root>
		{:catch}
			<Button disabled class="ml-auto">
				<LoaderCircle class="w-4 h-4 mr-1" />
				Loading...
			</Button>
		{/await}
	{/if}
{/snippet}
<div class="relative">
	{@render waitlistToggleDialog()}
	<Root {value} class="p-2 min-h-96 mr-2" onValueChange={onTabChange}>
		<div class="inline-flex w-full">
			<Select.Root {value} type="single" onValueChange={onTabChange}>
				<Select.Trigger class="md:hidden flex w-fit" size="sm" id="view-selector">
					{viewLabel}
				</Select.Trigger>
				<Select.Content>
					{#each views as view (view.id)}
						<Select.Item value={view.id}>{view.label}</Select.Item>
					{/each}
				</Select.Content>
			</Select.Root>
			<List class="md:flex hidden">
				<Trigger value="dashboard">Dashboard</Trigger>
				<Trigger value="waitlist">Waitlist</Trigger>
			</List>
		</div>

		<Content value="dashboard">
			<Analytics />
		</Content>
		<Content value="waitlist">
			<WaitlistTable {supabase} />
		</Content>
	</Root>
</div>
