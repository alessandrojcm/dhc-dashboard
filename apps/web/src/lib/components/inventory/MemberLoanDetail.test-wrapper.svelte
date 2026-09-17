<script lang="ts">
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import MemberLoanDetail from "./MemberLoanDetail.svelte";

let {
	loanId,
	queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	}),
}: {
	loanId: string;
	queryClient?: QueryClient;
} = $props();
</script>

<QueryClientProvider client={queryClient}>
	<MemberLoanDetail {loanId} />
</QueryClientProvider>
