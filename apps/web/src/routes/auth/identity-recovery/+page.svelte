<script lang="ts">
import * as Alert from "$lib/components/ui/alert/index.js";
import { Button } from "$lib/components/ui/button";
import { Card } from "$lib/components/ui/card";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();
</script>

<svelte:head>
	<title>Discord identity recovery — Dublin Hema Club</title>
</svelte:head>

<Card
	class="flex h-auto min-h-80 w-[90%] max-w-md flex-col items-center justify-center gap-6 p-6 sm:w-[80%]"
>
	<h2 class="prose prose-h2 text-center text-2xl font-bold">
		Discord identity recovery
	</h2>

	<Alert.Root variant={data.success ? "success" : "destructive"}>
		<Alert.Title
			>{data.success ? "Proof received" : "Recovery link failed"}</Alert.Title
		>
		<Alert.Description>{data.message}</Alert.Description>
	</Alert.Root>

	{#if data.caseReference}
		<p class="text-center text-sm text-muted-foreground">
			Recovery case <code>{data.caseReference}</code>
		</p>
	{/if}

	<p class="text-center text-sm text-muted-foreground">
		Recovery never signs you in. After an administrator confirms completion, use
		a fresh normal sign-in proof.
	</p>

	<Button href="/auth">Return to sign in</Button>
</Card>
