import { describe, it, expect } from 'vitest';
import { MemberService } from './member.service';
import { MemberUpdateSchema } from './member.service';
import * as v from 'valibot';

describe('MemberService', () => {
	describe('MemberUpdateSchema', () => {
		it('should validate valid member update data', () => {
			const validData = {
				firstName: 'John',
				lastName: 'Doe',
				phoneNumber: '+353123456789',
				dateOfBirth: new Date('1990-01-01'),
				pronouns: 'he/him',
				gender: 'male',
				medicalConditions: 'None',
				nextOfKin: 'Jane Doe',
				nextOfKinNumber: '+353987654321',
				preferredWeapon: ['longsword'],
				insuranceFormSubmitted: true,
				socialMediaConsent: 'yes'
			};

			const result = v.safeParse(MemberUpdateSchema, validData);
			expect(result.success).toBe(true);
		});

		it('should reject invalid first name', () => {
			const invalidData = {
				firstName: '',
				lastName: 'Doe',
				dateOfBirth: new Date('1990-01-01')
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should reject invalid last name', () => {
			const invalidData = {
				firstName: 'John',
				lastName: '',
				dateOfBirth: new Date('1990-01-01')
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should reject future date of birth', () => {
			const futureDate = new Date();
			futureDate.setFullYear(futureDate.getFullYear() + 1);

			const invalidData = {
				firstName: 'John',
				lastName: 'Doe',
				dateOfBirth: futureDate
			};

			const result = v.safeParse(MemberUpdateSchema, invalidData);
			expect(result.success).toBe(false);
		});
	});

	describe('Service methods', () => {
		it('should have findById method', () => {
			expect(MemberService.prototype.findById).toBeDefined();
			expect(typeof MemberService.prototype.findById).toBe('function');
		});

		it('should have update method', () => {
			expect(MemberService.prototype.update).toBeDefined();
			expect(typeof MemberService.prototype.update).toBe('function');
		});

		it('should have findByIdWithSubscription method', () => {
			expect(MemberService.prototype.findByIdWithSubscription).toBeDefined();
			expect(typeof MemberService.prototype.findByIdWithSubscription).toBe('function');
		});

		it('should have getMembershipInfo method', () => {
			expect(MemberService.prototype.getMembershipInfo).toBeDefined();
			expect(typeof MemberService.prototype.getMembershipInfo).toBe('function');
		});

		it('should have updateWithArgs method', () => {
			expect(MemberService.prototype.updateWithArgs).toBeDefined();
			expect(typeof MemberService.prototype.updateWithArgs).toBe('function');
		});
	});
});
