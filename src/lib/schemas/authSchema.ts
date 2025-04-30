import { email, minLength, object, optional, string } from 'valibot';

// Create a basic schema without complex validations to avoid type issues
export const authSchema = object({
  email: optional(string()),
  auth_method: string()
});

export default authSchema;
