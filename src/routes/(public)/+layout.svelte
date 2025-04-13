<script lang="ts">
	import DHCLogo from '$lib/components/dhc-logo.svelte';

	const { children } = $props();
</script>

<div class="flex h-[100vh]">
	<div class="hidden md:flex flex-1 basis-1/4 bg-blue-700 flex-row items-center">
		<DHCLogo />
	</div>
	<div class="flex-1 flex items-center justify-center basis-3/4">
		{@render children()}
	</div>
</div>
