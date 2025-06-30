import * as v from 'valibot';
import dayjs from 'dayjs';

export const workshopCreateSchema = v.object({
  workshop_date: v.pipe(
    v.string(),
    v.nonEmpty('Date required'),
    v.check((val) => dayjs(val, undefined, true).isValid(), 'Invalid date'),
    v.check((val) => dayjs(val).isAfter(dayjs().subtract(1, 'minute')), 'Date cannot be in the past')
  ),
  location: v.pipe(v.string(), v.nonEmpty('Location required')),
  coach_id: v.pipe(v.string(), v.nonEmpty('Coach required')),
  capacity: v.pipe(v.optional(v.number(), 16), v.minValue(1, 'Capacity must be at least 1')),
  notes_md: v.optional(v.string())
}); 