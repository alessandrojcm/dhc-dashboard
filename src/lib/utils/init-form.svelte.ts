import type { RemoteForm, RemoteFormInput } from "@sveltejs/kit";

export function initForm<T extends RemoteFormInput, R = unknown>(
  form: RemoteForm<T, R>,
  getter: () => Parameters<typeof form.fields.set>[0]
) {
  let hydrated = false;
  form.fields.set(getter());
  $effect(() => {
    const values = getter();
    if (!hydrated) return void (hydrated = true);
    form.fields.set(values);
  });
};