<script lang="ts" generics="TContext extends object">
import type { ColumnDefTemplate } from "@tanstack/table-core";

import {
	RenderComponentConfig,
	RenderSnippetConfig,
} from "./render-helpers.js";
type Props = {
	/** The cell or header field of the current cell's column definition. */
	content?: ColumnDefTemplate<TContext>;
	/** The result of the `getContext()` function of the header or cell */
	context: TContext;
};

let { content, context }: Props = $props();
</script>

{#if content instanceof Function}
	{@const result = content(context)}
	{#if result instanceof RenderComponentConfig}
		{@const { component: Component, props } = result}
		<Component {...props} />
	{:else if result instanceof RenderSnippetConfig}
		{@const { snippet, params } = result}
		{@render snippet(params)}
	{:else}
		{result}
	{/if}
{:else}
	{content}
{/if}
