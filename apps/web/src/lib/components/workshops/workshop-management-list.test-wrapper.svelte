<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import type { WorkshopCalendarItem } from "@dhc/api-client";
import WorkshopManagementList from "./workshop-management-list.svelte";

let { workshops }: { workshops: WorkshopCalendarItem[] } = $props();

const queryClient = new QueryClient();
</script>

<QueryClientProvider client={queryClient}>
	<WorkshopManagementList {workshops} />
</QueryClientProvider>
