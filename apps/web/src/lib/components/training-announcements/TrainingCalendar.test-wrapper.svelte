<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import TrainingCalendar from "./TrainingCalendar.svelte";

let {
	today,
	initialDate,
	queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	}),
}: {
	today: string;
	initialDate?: string;
	queryClient?: QueryClient;
} = $props();
</script>

<QueryClientProvider client={queryClient}>
	<TrainingCalendar {today} {initialDate} />
</QueryClientProvider>
