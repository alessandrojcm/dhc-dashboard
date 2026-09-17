<script lang="ts">
import type {
	InventoryCatalogRequestLoanData,
	InventoryCatalogRequestLoanResponse,
} from "@dhc/api-client";
import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
import MemberEquipmentItem from "./MemberEquipmentItem.svelte";

let {
	slug,
	queryClient = new QueryClient({
		defaultOptions: {
			queries: { retry: false },
			mutations: { retry: false },
		},
	}),
	requestLoan,
}: {
	slug: string;
	queryClient?: QueryClient;
	requestLoan?: (
		vars: Pick<InventoryCatalogRequestLoanData, "body" | "path">,
	) => Promise<InventoryCatalogRequestLoanResponse>;
} = $props();
</script>

<QueryClientProvider client={queryClient}>
	<MemberEquipmentItem {slug} {requestLoan} />
</QueryClientProvider>
