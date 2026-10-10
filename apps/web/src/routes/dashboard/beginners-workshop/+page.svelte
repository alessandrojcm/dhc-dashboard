<script lang="ts">
import { createMutation } from "@tanstack/svelte-query";
import { Lock, LockOpen } from "@lucide/svelte";
import { toast } from "svelte-sonner";
import { goto, invalidate } from "$app/navigation";
import { page } from "$app/state";
import * as AlertDialog from "#lib/components/ui/alert-dialog/index.js";
import Button from "#lib/components/ui/button/button.svelte";
import LoaderCircle from "#lib/components/ui/loader-circle.svelte";
import * as Select from "#lib/components/ui/select/index.js";
import { Content, List, Root, Trigger } from "#lib/components/ui/tabs/index.js";
import IntakeEmailTemplates from "#lib/components/beginners-workshops/intake-email-templates.svelte";
import InvitableTab from "./invitable-tab.svelte";
import WaitlistTable from "./waitlist-table.svelte";
import Analytics from "./workshop-analytics.svelte";
import WorkshopsTab from "./workshops-tab.svelte";
import { waitlistUpdateStatusMutation } from "@dhc/api-client";
import { SvelteURLSearchParams } from "svelte/reactivity";

const { data } = $props();
let dialogOpen = $state(false);
// ALE-378: the section opens on Workshops for those who manage them.
const defaultTab = $derived(
	data.canManageWorkshops ? "workshops" : "dashboard",
);
let value = $derived(page.url.searchParams.get("tab") || defaultTab);

const toggleWaitlistMutation = createMutation(() => ({
	...waitlistUpdateStatusMutation(),
	onSuccess: () => {
		invalidate("wailist:status");
		toast.success("Waitlist status updated", { position: "top-center" });
		dialogOpen = false;
	},
	onError: (error) => {
		toast.error(error.errors?.detail ?? "Error updating waitlist status", {
			position: "top-center",
		});
		dialogOpen = false;
	},
}));

function onTabChange(value: string) {
	const newParams = new SvelteURLSearchParams(page.url.search);
	newParams.set("tab", value);
	const url = `/dashboard/beginners-workshop?${newParams.toString()}`;
	goto(url);
}
const views = $derived([
	{
		id: "dashboard",
		label: "Dashboard",
	},
	{
		id: "waitlist",
		label: "Waitlist",
	},
	...(data.canManageWorkshops
		? [
				{ id: "workshops", label: "Workshops" },
				{ id: "email-templates", label: "Email templates" },
			]
		: []),
	...(data.invitable ? [{ id: "invitable", label: "Invitable" }] : []),
]);
let viewLabel = $derived(
	views.find((view) => view.id === value)?.label || "Dashboard",
);
</script>

{#snippet waitlistToggleDialog()}
	{#if data.canToggleWaitlist}
		{#await data.isWaitlistOpen then isOpen}
			<AlertDialog.Root bind:open={dialogOpen}>
				<AlertDialog.Trigger class="fixed right-4 top-20 z-30">
					{#snippet child({ props })}
						<Button
							variant="outline"
							{...props}
							onclick={() => (dialogOpen = true)}
						>
							{#if isOpen}
								<LockOpen class="w-4 h-4" />
								<p class="hidden md:block">Close Waitlist</p>
							{:else}
								<Lock class="w-4 h-4" />
								<p class="hidden md:block">Open Waitlist</p>
							{/if}
						</Button>
					{/snippet}
				</AlertDialog.Trigger>
				<AlertDialog.Content>
					<AlertDialog.Header>
						<AlertDialog.Title
							>{isOpen ? "Close" : "Open"} waitlist</AlertDialog.Title
						>
						<AlertDialog.Description>
							Are you sure you want to {isOpen ? "close" : "open"} the waitlist? This
							action will affect new registrations.
						</AlertDialog.Description>
					</AlertDialog.Header>
					<AlertDialog.Footer>
						<AlertDialog.Cancel onclick={() => (dialogOpen = false)}
							>Cancel</AlertDialog.Cancel
						>
						<AlertDialog.Action
							onclick={() =>
								toggleWaitlistMutation.mutate({ body: { isOpen: !isOpen } })}
							data-testid="action"
							>{isOpen ? "Close" : "Open"}</AlertDialog.Action
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
				<Select.Trigger
					class="md:hidden flex w-fit"
					size="sm"
					id="view-selector"
				>
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
				{#if data.canManageWorkshops}
					<Trigger value="workshops">Workshops</Trigger>
					<Trigger value="email-templates">Email templates</Trigger>
				{/if}
				{#if data.invitable}
					<Trigger value="invitable">Invitable</Trigger>
				{/if}
			</List>
		</div>

		<Content value="dashboard">
			<Analytics />
		</Content>
		<Content value="waitlist">
			<WaitlistTable />
		</Content>
		{#if data.workshops}
			<Content value="workshops">
				<WorkshopsTab
					workshops={data.workshops}
					candidates={data.staffCandidates}
				/>
			</Content>
		{/if}
		{#if data.canManageWorkshops}
			<Content value="email-templates">
				<IntakeEmailTemplates />
			</Content>
		{/if}
		{#if data.invitable}
			<Content value="invitable">
				<InvitableTab people={data.invitable} />
			</Content>
		{/if}
	</Root>
</div>
