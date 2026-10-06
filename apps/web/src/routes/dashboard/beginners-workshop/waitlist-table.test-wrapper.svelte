<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import * as Tooltip from "#lib/components/ui/tooltip/index.js";
import WaitlistTable from "./waitlist-table.svelte";
import type { WaitlistTableDeps } from "./waitlist-table.svelte.js";

let {
	queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	}),
	deps,
}: { queryClient?: QueryClient; deps: WaitlistTableDeps } = $props();
</script>

<QueryClientProvider client={queryClient}>
	<Tooltip.Provider>
		<WaitlistTable {deps} />
	</Tooltip.Provider>
</QueryClientProvider>
