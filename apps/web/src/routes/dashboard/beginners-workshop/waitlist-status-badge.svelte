<!--
	The Waitlist table's Status cell: the standing text, re-read when the
	page's Carried Fee statuses arrive (ALE-388), which a static table cell
	would miss.
-->
<script lang="ts">
import { Badge } from "#lib/components/ui/badge/index.js";

let { removed, text }: { removed: boolean; text: () => string } = $props();
</script>

<Badge variant={removed ? "outline" : "secondary"} class="h-8 whitespace-nowrap"
	><span>{text()}</span></Badge
>
