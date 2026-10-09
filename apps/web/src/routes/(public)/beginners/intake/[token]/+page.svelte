<script lang="ts">
import IntakePage from "./intake-page.svelte";
import type { PageProps } from "./$types";

let { data }: PageProps = $props();
</script>

<svelte:head>
	<title>Your Beginners' Workshop place · Dublin HEMA Club</title>
	<!-- The link is a capability: never send it as a referrer. -->
	<meta name="referrer" content="no-referrer" />
	<meta name="robots" content="noindex" />
</svelte:head>

<div class="flex justify-center">
	<IntakePage page={data.page} token={data.token} />
</div>
