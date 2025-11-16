<script lang="ts">
import type { LayoutProps } from "./$types";

const { children, data }: LayoutProps = $props();
</script>

<div class="flex h-full">
	<!-- Main Content -->
	<div class="flex-1 overflow-auto">
		{@render children()}
	</div>
</div>
