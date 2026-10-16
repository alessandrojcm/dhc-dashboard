<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import * as Tooltip from "#lib/components/ui/tooltip/index.js";
import SectionShell from "./section-shell.svelte";
import InvitableTab from "./invitable-tab.svelte";
import WaitlistTable from "./waitlist-table.svelte";
import type { WaitlistTableDeps } from "./waitlist-table.svelte.js";
import type { BeginnersWorkshopInvitable } from "@dhc/api-client";

let {
	deps,
	invitable = false,
	people = [],
}: {
	deps: WaitlistTableDeps;
	invitable?: boolean;
	people?: BeginnersWorkshopInvitable[];
} = $props();
const client = new QueryClient({
	defaultOptions: { queries: { retry: false } },
});
const data = {
	canToggleWaitlist: true,
	canManageWorkshops: true,
	canInvite: true,
	isWaitlistOpen: true,
};
</script>

<!-- A constrained dashboard viewport, including the two-line phone breadcrumb. -->
<main class="flex h-dvh flex-col overflow-y-auto" aria-label="Workshop section">
	<div class="h-20 shrink-0">Dashboard / Beginners Workshop / Waitlist</div>
	<div class="min-h-0 flex-1">
		<QueryClientProvider {client}>
			<Tooltip.Provider>
				<SectionShell
					{data}
					pathname={`/dashboard/beginners-workshop/${invitable ? "invitable" : "waitlist"}`}
				>
					{#if invitable}
						<InvitableTab {people} />
					{:else}
						<WaitlistTable {deps} />
					{/if}
				</SectionShell>
			</Tooltip.Provider>
		</QueryClientProvider>
	</div>
</main>
