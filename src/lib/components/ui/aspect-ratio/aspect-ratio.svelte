<script lang="ts">
import type { AspectRatio as AspectRatioPrimitive } from "bits-ui";

const { ref = $bindable(null), ...restProps }: AspectRatioPrimitive.RootProps =
	$props();
</script>

<AspectRatioPrimitive.Root bind:ref data-slot="aspect-ratio" {...restProps} />
