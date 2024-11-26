BEGIN;
SELECT plan(1);


select ok(
           (SELECT EXISTS(select 1 from public.get_gender_options()))
       );

SELECT * from finish()
