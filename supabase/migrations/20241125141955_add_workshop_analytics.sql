-- Update enum type
ALTER TYPE waitlist_status ADD VALUE IF NOT EXISTS 'joined';

-- Updated conversion metrics function
CREATE OR REPLACE FUNCTION get_conversion_metrics(
    start_date timestamp,
    end_date timestamp
)
    RETURNS TABLE
            (
                cohort_date              timestamp,
                total_signups            integer,
                workshop_completions     integer,
                club_joins               integer,
                workshop_conversion_rate numeric,
                join_conversion_rate     numeric,
                avg_time_to_join         interval
            )
AS
$$
BEGIN
    RETURN QUERY
        WITH cohort_metrics AS (SELECT date_trunc('month', initial_registration_date) as cohort_date,
                                       COUNT(*)                                       as total_signups,
                                       COUNT(*) FILTER (WHERE status = 'completed')   as workshop_completions,
                                       COUNT(*) FILTER (WHERE status = 'joined')      as club_joins,
                                       AVG(
                                               CASE
                                                   WHEN status = 'joined'
                                                       THEN last_status_change - initial_registration_date
                                                   END
                                       )                                              as avg_time_to_join
                                FROM waitlist
                                WHERE initial_registration_date BETWEEN start_date AND end_date
                                GROUP BY 1)
        SELECT m.cohort_date,
               m.total_signups,
               m.workshop_completions,
               m.club_joins,
               ROUND((m.workshop_completions::numeric / m.total_signups::numeric * 100), 2) as workshop_conversion_rate,
               ROUND((m.club_joins::numeric / m.workshop_completions::numeric * 100), 2)    as join_conversion_rate,
               m.avg_time_to_join
        FROM cohort_metrics m
        ORDER BY m.cohort_date;
END;
$$ LANGUAGE plpgsql;
