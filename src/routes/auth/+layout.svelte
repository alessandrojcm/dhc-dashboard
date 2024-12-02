<script lang="ts">
	let { children } = $props();
</script>

<svelte:head>
	<title>Dublin Hema Club - Login</title>
</svelte:head>

<div class="flex h-[100vh]">
	<div class="hidden md:block flex-1 basis-1/4 bg-primary"></div>
	<div class="flex-1 flex items-center justify-center basis-3/4">
		{@render children()}
	</div>
</div>
