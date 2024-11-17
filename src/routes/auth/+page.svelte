<script lang="ts">
	import { page } from '$app/stores';
	const hash = $page.url.hash.split('#')[1] as string;
	const errorMessage = new URLSearchParams(hash).get('error_description');

	export const prerender = true;
</script>

<form method="POST">
	{#if errorMessage}
		<p>{errorMessage}</p>
	{/if}
	<button type="submit">Login with discord</button>
</form>
