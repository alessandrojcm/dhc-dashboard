<script lang="ts">
import type { ButtonProps } from "$lib/components/ui/button/index.js";

const { ref = $bindable(null), ...restProps }: ButtonProps = $props();
</script>

<Button bind:ref type="submit" {...restProps} />
