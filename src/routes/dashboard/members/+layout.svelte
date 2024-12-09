<script lang="ts">
	let {children} = $props();
</script>

<div class="pl-2 h-[calc(100vh-5rem)] overflow-hidden">
	<div class="h-full overflow-y-auto pb-4">
		{@render children()}
	</div>
</div>
