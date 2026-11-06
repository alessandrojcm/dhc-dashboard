import { Plugin } from "@opencode/plugin";
import { preEditHooks } from "../lib/entire-brain.ts";

// Separate from entire.ts: `entire enable` regenerates that tracking plugin.
export default Plugin.define({
  id: "entire-brain",
  async setup(ctx) {
    const hooks = preEditHooks(ctx.location.directory);
    await ctx.permission.hook("evaluate", hooks.beforeEdit);
    await ctx.session.hook("context", hooks.context);
    return hooks.dispose;
  },
});
