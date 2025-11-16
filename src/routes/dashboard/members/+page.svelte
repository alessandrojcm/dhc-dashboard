<script lang="ts">
import { goto } from "$app/navigation";
import { page } from "$app/state";

const { data } = $props();
const value = $derived(page.url.searchParams.get("tab") || "dashboard");

function _onTabChange(value: string) {
	const newParams = new URLSearchParams(page.url.searchParams);
	newParams.set("tab", value);
	goto(`/dashboard/members?${newParams.toString()}`);
}
const views = [
	{
		id: "dashboard",
		label: "Dashboard",
	},
	{
		id: "members",
		label: "Members list",
	},
	{
		id: "invitations",
		label: "Invitations",
	},
];
const _viewLabel = $derived(
	views.find((view) => view.id === value)?.label || "Dashboard",
);
</script>

<div class="relative">
	{#if data.canEditSettings}
		{#await data.form}
			<div class="fixed right-4 top-4">
				<LoaderCircle />
			</div>
		{:then form}
			<SettingsSheet {form} />
		{/await}
	{/if}

	<Root {value} onValueChange={onTabChange} class="p-2 min-h-96 mr-2">
		<div class="flex justify-between items-center mb-2">
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
				<Trigger value="members">Members list</Trigger>
				<Trigger value="invitations">Invitations</Trigger>
			</List>

			{#if data.canEditSettings}
				<InviteDrawer supabase={data.supabase} />
			{/if}
		</div>
		<Content value="dashboard">
			<Analytics supabase={data.supabase} />
		</Content>
		<Content value="members">
			<MembersTable supabase={data.supabase} />
		</Content>
		<Content value="invitations">
			<InvitationsTable supabase={data.supabase} />
		</Content>
	</Root>
</div>
