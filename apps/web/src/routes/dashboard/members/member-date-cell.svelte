<script lang="ts">
import dayjs from "dayjs";

type Props = {
	date: string | null;
	emptyLabel?: string;
};

const { date, emptyLabel = "Not recorded" }: Props = $props();

const formattedDate = $derived(
	date && dayjs(date).isValid() ? dayjs(date).format("D MMM YYYY") : emptyLabel,
);
</script>

<span class="text-sm tabular-nums text-foreground">{formattedDate}</span>
