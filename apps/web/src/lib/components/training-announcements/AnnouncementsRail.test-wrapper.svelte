<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import AnnouncementsRail from "./AnnouncementsRail.svelte";

let {
	today,
	queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	}),
}: {
	today: string;
	queryClient?: QueryClient;
} = $props();
</script>

<QueryClientProvider client={queryClient}>
	<AnnouncementsRail {today} />
</QueryClientProvider>
