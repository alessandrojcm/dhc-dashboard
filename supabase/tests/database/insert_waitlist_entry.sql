BEGIN;
select plan(2);

select isnt(
               (select waitlist_id
                from public.insert_waitlist_entry(
                        'John',
                        'Doe',
                        'john@doe.com',
                        '11-05-1996',
                        '1234567',
                        'he/him',
                        'man (cis)',
                        'N/A'
                     )), null, 'Insert waitlist entry should work');
-- Forbid duplicated entries
select throws_ok(
               $$select waitlist_id
                from public.insert_waitlist_entry(
                        'John',
                        'Doe',
                        'john@doe.com',
                        '11-05-1996',
                        '1234567',
                        'he/him',
                        'man (cis)',
                        'N/A'
                     )$$, '23505');

select *
from finish();
rollback;
