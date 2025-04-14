<script lang="ts">
	import DHCLogo from '/src/assets/images/dhc-logo.png?enhanced';
	let { children } = $props();
</script>

<svelte:head>
	<title>Dublin Hema Club - Login</title>
</svelte:head>

<div class="flex h-[100vh]">
	<div class="hidden md:flex flex-1 basis-1/4 bg-blue-700 flex-row items-center">
		<enhanced:img src={DHCLogo} alt="Dublin Hema Club Logo" />
	</div>
	<div class="flex-1 flex items-center justify-center basis-3/4">
		{@render children()}
	</div>
</div>
