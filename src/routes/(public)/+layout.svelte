<script lang="ts">
<<<<<<< HEAD
import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";
const { children } = $props();
=======
	import DHCLogo from "/src/assets/images/dhc-logo.png?enhanced";
	const { children } = $props();
>>>>>>> d5cb40b (feat: migrated auth and waitlist form to svelte form action)
</script>

<svelte:head>
	<title>Dublin Hema Club - Join</title>
</svelte:head>

<div class="flex flex-col md:flex-row h-[100vh]">
	<div
		class="hidden md:flex flex-1 md:basis-1/4 bg-blue-500 px-2 items-center justify-center"
	>
		<enhanced:img
			src={DHCLogo}
			alt="Dublin Hema Club Logo"
			class="max-w-full h-auto"
		/>
	</div>
	<div
		class="flex-1 flex items-center justify-center md:basis-3/4 p-4 md:p-0"
	>
		{@render children()}
	</div>
</div>
