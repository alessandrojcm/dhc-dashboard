<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import type { Workshop } from "@dhc/api-client";
import WorkshopList from "./workshop-list.svelte";

interface Props {
	workshops: Workshop[];
}

let { workshops }: Props = $props();

const queryClient = new QueryClient();
</script>

<QueryClientProvider client={queryClient}>
	<WorkshopList {workshops} view="bookable" />
</QueryClientProvider>
