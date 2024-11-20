<script lang="ts">
	let {children} = $props();
</script>

<div class="flex flex-col h-full pl-2">
	{@render children()}
</div>
