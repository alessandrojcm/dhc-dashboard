<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import { Toaster } from "svelte-sonner";
import { Button } from "#lib/components/ui/button/index.js";
import ReactivateMemberDialog from "./reactivate-member-dialog.svelte";

/** Mounts the dialog the way the member pages do: per member, while open. */
let {
	members,
	queryClient,
	onSettled,
}: {
	members: string[];
	queryClient: QueryClient;
	onSettled: (memberId: string) => void;
} = $props();

let reactivating = $state<string | null>(null);
</script>

<QueryClientProvider client={queryClient}>
	{#each members as member (member)}
		<Button
			type="button"
			onclick={() => {
				reactivating = member;
			}}
		>
			Reactivate {member}
		</Button>
	{/each}

	{#if reactivating}
		{#key reactivating}
			<ReactivateMemberDialog
				memberId={reactivating}
				onClose={() => {
					reactivating = null;
				}}
				{onSettled}
			/>
		{/key}
	{/if}
	<Toaster />
</QueryClientProvider>
