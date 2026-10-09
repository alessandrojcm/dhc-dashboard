<script lang="ts">
import type {
	BeginnersWorkshop,
	BeginnersWorkshopFastTrackCandidate,
} from "@dhc/api-client";
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import FastTrackDialog from "./fast-track-dialog.svelte";

let {
	workshop,
	fastTrackOpen,
	searchCandidates,
}: {
	workshop: BeginnersWorkshop;
	fastTrackOpen: boolean;
	searchCandidates: (
		query: string,
	) => Promise<BeginnersWorkshopFastTrackCandidate[]>;
} = $props();

const queryClient = new QueryClient({
	defaultOptions: { queries: { retry: false } },
});
</script>

<QueryClientProvider client={queryClient}>
	<FastTrackDialog
		{workshop}
		{fastTrackOpen}
		genders={["woman (cis)", "man (cis)", "non-binary"]}
		open={true}
		{searchCandidates}
	/>
</QueryClientProvider>
