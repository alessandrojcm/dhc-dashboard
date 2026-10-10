<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import IntakeEmailTemplates from "./intake-email-templates.svelte";

let { queryClient }: { queryClient: QueryClient } = $props();
</script>

<QueryClientProvider client={queryClient}>
	<IntakeEmailTemplates />
</QueryClientProvider>
