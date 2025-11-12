# Under-age Waitlist (16–17) – Guardian Support (Approach 2)

The goal is **not** to touch the existing Postgres function `insert_waitlist_entry`.  
Instead we wrap it in a Kysely transaction and insert the guardian data in a new
`waitlist_guardians` table. Everything is TypeScript-typed and resides entirely
in the SvelteKit layer.

---

## 1. Database migration

Create a new migration (e.g. `20250503_add_waitlist_guardians.sql`).

```sql
-- `waitlist_guardians` – one row per guardian, linked to a waitlist entry
CREATE TABLE public.waitlist_guardians (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    waitlist_id    uuid NOT NULL REFERENCES public.waitlist(id) ON DELETE CASCADE,
    first_name     text NOT NULL,
    last_name      text NOT NULL,
    phone_number   text NOT NULL,
    created_at     timestamptz DEFAULT now()
);

-- (Optional) helper index if we are going to query by waitlist_id often
CREATE INDEX ON public.waitlist_guardians(waitlist_id);
```

Run the migration with the usual Supabase CLI workflow:

```bash
supabase db:reset
```

---

## 2. Kysely setup (if not already present)

Dependencies:

```bash
pnpm add kysely pg @types/pg
```

Create `src/lib/server/db.ts`:

```ts
import { Kysely, PostgresDialect } from 'kysely';
import pg from 'pg';

export interface DB {
	waitlist: {
		id: string;
		email: string;
		created_at: string;
	};
	waitlist_guardians: {
		id: string;
		waitlist_id: string;
		first_name: string;
		last_name: string;
		phone_number: string;
		created_at: string;
	};
	// …other tables we might need later
}

export const db = new Kysely<DB>({
	dialect: new PostgresDialect({
		pool: new pg.Pool({ connectionString: process.env.DATABASE_URL })
	})
});
```

Load `DATABASE_URL` from Supabase service key env (`.env` already present on the
server side in SvelteKit; **never** expose it to the client!).

---

## 3. Extend validation schema `beginnersWaitlist`

Using valibot conditional rules:

```ts
import { object, string, minLength, when } from 'valibot';

export const beginnersWaitlist = object({
	/* existing fields */
	guardianFirstName: when((data) => age(data.dateOfBirth) < 18, string([minLength(1, 'Required')])),
	guardianLastName: when((data) => age(data.dateOfBirth) < 18, string([minLength(1, 'Required')])),
	guardianPhoneNumber: when(
		(data) => age(data.dateOfBirth) < 18,
		string([minLength(6, 'Required')])
	)
});
```

Helper `age()` can live in a util file.

---

## 4. Update the waitlist Svelte form

1. Add a derived store `isUnderAge`:
   ```ts
   const isUnderAge = $derived.by(() => dayjs().diff($formData.dateOfBirth, 'year') < 18);
   ```
2. Wrap the new inputs in `{#if isUnderAge}`:
   ```svelte
   <Form.Field {form} name="guardianFirstName">
   	<!-- same pattern as others -->
   </Form.Field>
   <Form.Field {form} name="guardianLastName">…</Form.Field>
   <Form.Field {form} name="guardianPhoneNumber">…</Form.Field>
   ```
3. Ensure the new fields are **not** sent for adults (they will be empty strings
   after validation stripping).

---

## 5. Server-side action (`+page.server.ts`)

```ts
import { db } from '$lib/server/db';
import { sql } from 'kysely';

export const actions: Actions = {
	default: async (event) => {
		const form = await superValidate(event, valibot(beginnersWaitlist));
		if (!form.valid) return fail(422, { form });

		const data = form.data;
		const age = dayjs().diff(data.dateOfBirth, 'year');

		if (age >= 16 && age < 18) {
			// ----- under-age path (transaction) -----
			try {
				await db.transaction().execute(async (trx) => {
					// 1. call existing function and capture the waitlist row
					const [row] = await trx.executeQuery(
						sql`select * from insert_waitlist_entry(
                    ${data.firstName},
                    ${data.lastName},
                    ${data.email},
                    ${data.dateOfBirth.toISOString()},
                    ${data.phoneNumber},
                    ${data.pronouns.toLowerCase()},
                    ${data.gender},
                    ${data.medicalConditions},
                    ${data.socialMediaConsent}
                  )`.compile()
					);

					const waitlistId = row.waitlist_id as string;

					// 2. insert guardian row
					await trx
						.insertInto('waitlist_guardians')
						.values({
							waitlist_id: waitlistId,
							first_name: data.guardianFirstName!,
							last_name: data.guardianLastName!,
							phone_number: data.guardianPhoneNumber!
						})
						.execute();
				});
			} catch (err) {
				console.error(err);
				return message(
					form,
					{ error: 'Something has gone wrong, please try again later.' },
					{ status: 500 }
				);
			}
		} else {
			// ----- adult path: keep old RPC call -----
			const { error } = await supabaseServiceClient.rpc('insert_waitlist_entry', {
				first_name: data.firstName,
				last_name: data.lastName,
				email: data.email,
				date_of_birth: data.dateOfBirth.toISOString(),
				phone_number: data.phoneNumber,
				pronouns: data.pronouns.toLowerCase(),
				gender: data.gender,
				medical_conditions: data.medicalConditions,
				social_media_consent: data.socialMediaConsent
			});
			if (error?.code === '23505')
				return setError(form, 'email', 'You are already on the waitlist!');
			if (error)
				return message(
					form,
					{ error: 'Something has gone wrong, please try again later.' },
					{ status: 500 }
				);
		}

		return message(form, {
			success: 'You have been added to the waitlist, we will be in contact soon!'
		});
	}
};
```

Key points:

- `trx.executeQuery(sql\`…\`)` allows invoking the existing Postgres function
  inside the same transaction.
- Any error inside the callback automatically rolls back.

---

## 6. Types & generated SQL helpers (optional)

If you use the Supabase Type Generator you can import column types directly into
Kysely’s `DB` interface above for stronger typing.

---

## 7. Tests

- Add unit test for the validation logic (age gating & required guardian
  fields).
- Add an integration test that mocks the DB and checks both adult and under-age
  paths.

---

## 8. Rollback strategy

If issues arise, simply drop the `waitlist_guardians` table and revert the UI
changes – the original flow remains untouched.

---

That’s it – fully backward-compatible guardian support with transactional safety
and no modification to the existing database function.
