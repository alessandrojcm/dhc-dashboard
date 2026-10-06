<script lang="ts" generics="T extends RemoteFormInput">
import type { RemoteFormInput, RemoteForm } from "$app/server";

const { form }: { form: RemoteForm<T, unknown> } = $props();

const fields = $derived(form.fields);
</script>

<pre
	class="mt-4 max-h-96 overflow-auto rounded-lg bg-gray-900 p-4 text-sm wrap-break-word whitespace-pre-wrap text-green-300">
{JSON.stringify(
		{
			values: fields.value(),
			issues: fields.allIssues(),
		},
		null,
		2,
	)}
</pre>
