<script>
	import { LoaderCircle } from 'lucide-svelte';

	const { class: className } = $props();
</script>

<LoaderCircle class="animate-spin text:currentColor {className}" />
