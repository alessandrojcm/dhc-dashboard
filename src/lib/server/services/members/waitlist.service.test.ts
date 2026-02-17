import { describe, it, expect } from 'vitest';
import { WaitlistService, WaitlistEntrySchema, calculateAge, isMinor } from './waitlist.service';
import { SocialMediaConsent } from '$lib/types';
import * as v from 'valibot';
import dayjs from 'dayjs';

describe('WaitlistService', () => {
	describe('Helper functions', () => {
		describe('calculateAge', () => {
			it('should calculate age correctly', () => {
				const birthDate = new Date();
				birthDate.setFullYear(birthDate.getFullYear() - 25);
				expect(calculateAge(birthDate)).toBe(25);
			});

			it('should return 0 for current date', () => {
				const today = new Date();
				expect(calculateAge(today)).toBe(0);
			});
		});

		describe('isMinor', () => {
			it('should return true for someone under 18', () => {
				const birthDate = new Date();
				birthDate.setFullYear(birthDate.getFullYear() - 15);
				expect(isMinor(birthDate)).toBe(true);
			});

			it('should return false for someone 18 or older', () => {
				const birthDate = new Date();
				birthDate.setFullYear(birthDate.getFullYear() - 20);
				expect(isMinor(birthDate)).toBe(false);
			});

			it('should return false for exactly 18 years old', () => {
				const birthDate = new Date();
				birthDate.setFullYear(birthDate.getFullYear() - 18);
				expect(isMinor(birthDate)).toBe(false);
			});
		});
	});

	describe('WaitlistEntrySchema', () => {
		const adultBirthDate = dayjs().subtract(25, 'years').toDate();
		const minorBirthDate = dayjs().subtract(17, 'years').toDate(); // 17 years old - still a minor but meets 16+ requirement

		it('should validate valid adult waitlist entry', () => {
			const validData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None',
				socialMediaConsent: SocialMediaConsent.yes_recognizable
			};

			const result = v.safeParse(WaitlistEntrySchema, validData);
			expect(result.success).toBe(true);
			if (result.success) {
				expect(result.output.guardianFirstName).toBeUndefined();
				expect(result.output.guardianLastName).toBeUndefined();
				expect(result.output.guardianPhoneNumber).toBeUndefined();
			}
		});

		it('should validate valid minor waitlist entry with guardian', () => {
			const validData = {
				firstName: 'Jane',
				lastName: 'Smith',
				email: 'jane.smith@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: minorBirthDate,
				pronouns: 'she/her',
				gender: 'female',
				medicalConditions: 'None',
				socialMediaConsent: SocialMediaConsent.no,
				guardianFirstName: 'Mary',
				guardianLastName: 'Smith',
				guardianPhoneNumber: '0879876543'
			};

			const result = v.safeParse(WaitlistEntrySchema, validData);
			expect(result.success).toBe(true);
			if (result.success) {
				expect(result.output.guardianFirstName).toBe('Mary');
				expect(result.output.guardianLastName).toBe('Smith');
				// Guardian phone number is not transformed since it uses optional validator
				expect(result.output.guardianPhoneNumber).toBe('0879876543');
			}
		});

		it('should reject minor without guardian first name', () => {
			const invalidData = {
				firstName: 'Jane',
				lastName: 'Smith',
				email: 'jane.smith@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: minorBirthDate,
				pronouns: 'she/her',
				gender: 'female',
				medicalConditions: 'None',
				socialMediaConsent: SocialMediaConsent.no,
				guardianLastName: 'Smith',
				guardianPhoneNumber: '0879876543'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
			if (!result.success) {
				expect(result.issues.some((issue) => issue.message.includes('Guardian first name'))).toBe(
					true
				);
			}
		});

		it('should reject minor without guardian last name', () => {
			const invalidData = {
				firstName: 'Jane',
				lastName: 'Smith',
				email: 'jane.smith@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: minorBirthDate,
				pronouns: 'she/her',
				gender: 'female',
				medicalConditions: 'None',
				socialMediaConsent: SocialMediaConsent.no,
				guardianFirstName: 'Mary',
				guardianPhoneNumber: '0879876543'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
			if (!result.success) {
				expect(result.issues.some((issue) => issue.message.includes('Guardian last name'))).toBe(
					true
				);
			}
		});

		it('should reject minor without guardian phone number', () => {
			const invalidData = {
				firstName: 'Jane',
				lastName: 'Smith',
				email: 'jane.smith@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: minorBirthDate,
				pronouns: 'she/her',
				gender: 'female',
				medicalConditions: 'None',
				socialMediaConsent: SocialMediaConsent.no,
				guardianFirstName: 'Mary',
				guardianLastName: 'Smith'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
			if (!result.success) {
				expect(result.issues.some((issue) => issue.message.includes('Guardian phone number'))).toBe(
					true
				);
			}
		});

		it('should reject empty first name', () => {
			const invalidData = {
				firstName: '',
				lastName: 'Doe',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should reject empty last name', () => {
			const invalidData = {
				firstName: 'John',
				lastName: '',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should reject invalid email', () => {
			const invalidData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'not-an-email',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should transform email to lowercase', () => {
			const validData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'JOHN.DOE@EXAMPLE.COM',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, validData);
			expect(result.success).toBe(true);
			if (result.success) {
				expect(result.output.email).toBe('john.doe@example.com');
			}
		});

		it('should reject invalid pronouns format', () => {
			const invalidData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'invalid pronouns!',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should accept valid pronouns formats', () => {
			const validPronouns = ['he/him', 'she/her', 'they/them', 'he/they'];

			for (const pronouns of validPronouns) {
				const validData = {
					firstName: 'John',
					lastName: 'Doe',
					email: 'john.doe@example.com',
					phoneNumber: '0871234567',
					dateOfBirth: adultBirthDate,
					pronouns,
					gender: 'male',
					medicalConditions: 'None'
				};

				const result = v.safeParse(WaitlistEntrySchema, validData);
				expect(result.success).toBe(true);
			}
		});

		it("should default socialMediaConsent to 'no' when not provided", () => {
			const validData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None'
			};

			const result = v.safeParse(WaitlistEntrySchema, validData);
			expect(result.success).toBe(true);
			if (result.success) {
				expect(result.output.socialMediaConsent).toBe('no');
			}
		});

		it('should strip guardian fields from adult entries', () => {
			const validData = {
				firstName: 'John',
				lastName: 'Doe',
				email: 'john.doe@example.com',
				phoneNumber: '0871234567',
				dateOfBirth: adultBirthDate,
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None',
				// These should be stripped
				guardianFirstName: 'Should',
				guardianLastName: 'BeRemoved',
				guardianPhoneNumber: '0879999999'
			};

			const result = v.safeParse(WaitlistEntrySchema, validData);
			expect(result.success).toBe(true);
			if (result.success) {
				expect(result.output.guardianFirstName).toBeUndefined();
				expect(result.output.guardianLastName).toBeUndefined();
				expect(result.output.guardianPhoneNumber).toBeUndefined();
			}
		});
	});

	describe('Service methods', () => {
		it('should have create method', () => {
			expect(WaitlistService.prototype.create).toBeDefined();
			expect(typeof WaitlistService.prototype.create).toBe('function');
		});

		it('should have _create transactional method', () => {
			expect(WaitlistService.prototype._create).toBeDefined();
			expect(typeof WaitlistService.prototype._create).toBe('function');
		});

		it('should have findByStatus method', () => {
			expect(WaitlistService.prototype.findByStatus).toBeDefined();
			expect(typeof WaitlistService.prototype.findByStatus).toBe('function');
		});

		it('should have findById method', () => {
			expect(WaitlistService.prototype.findById).toBeDefined();
			expect(typeof WaitlistService.prototype.findById).toBe('function');
		});

		it('should have updateStatus method', () => {
			expect(WaitlistService.prototype.updateStatus).toBeDefined();
			expect(typeof WaitlistService.prototype.updateStatus).toBe('function');
		});

		it('should have getGuardian method', () => {
			expect(WaitlistService.prototype.getGuardian).toBeDefined();
			expect(typeof WaitlistService.prototype.getGuardian).toBe('function');
		});
	});
});
