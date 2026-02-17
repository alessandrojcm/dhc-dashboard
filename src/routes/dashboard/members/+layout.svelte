<script lang="ts">
const { children } = $props();
</script>

<div class="px-2 h-[100dvh] overflow-hidden">
	<div class="h-full overflow-y-auto pb-4">
		{@render children()}
	</div>
</div>
