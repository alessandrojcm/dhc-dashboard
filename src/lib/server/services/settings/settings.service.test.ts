import { describe, it, expect } from 'vitest';
import { SettingsService } from './settings.service';
import { InsuranceFormLinkSchema } from './settings.service';
import * as v from 'valibot';

describe('SettingsService', () => {
	describe('InsuranceFormLinkSchema', () => {
		it('should validate valid insurance form link', () => {
			const validData = {
				insuranceFormLink: 'https://example.com/insurance-form'
			};

			const result = v.safeParse(InsuranceFormLinkSchema, validData);
			expect(result.success).toBe(true);
		});

		it('should reject empty insurance form link', () => {
			const invalidData = {
				insuranceFormLink: ''
			};

			const result = v.safeParse(InsuranceFormLinkSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should reject invalid URL', () => {
			const invalidData = {
				insuranceFormLink: 'not-a-valid-url'
			};

			const result = v.safeParse(InsuranceFormLinkSchema, invalidData);
			expect(result.success).toBe(false);
		});

		it('should accept https URL', () => {
			const validData = {
				insuranceFormLink: 'https://forms.google.com/insurance'
			};

			const result = v.safeParse(InsuranceFormLinkSchema, validData);
			expect(result.success).toBe(true);
		});

		it('should accept http URL', () => {
			const validData = {
				insuranceFormLink: 'http://example.com/form'
			};

			const result = v.safeParse(InsuranceFormLinkSchema, validData);
			expect(result.success).toBe(true);
		});
	});

	describe('Service methods', () => {
		it('should have findByKey method', () => {
			expect(SettingsService.prototype.findByKey).toBeDefined();
			expect(typeof SettingsService.prototype.findByKey).toBe('function');
		});

		it('should have findMany method', () => {
			expect(SettingsService.prototype.findMany).toBeDefined();
			expect(typeof SettingsService.prototype.findMany).toBe('function');
		});

		it('should have update method', () => {
			expect(SettingsService.prototype.update).toBeDefined();
			expect(typeof SettingsService.prototype.update).toBe('function');
		});

		it('should have updateInsuranceFormLink method', () => {
			expect(SettingsService.prototype.updateInsuranceFormLink).toBeDefined();
			expect(typeof SettingsService.prototype.updateInsuranceFormLink).toBe('function');
		});

		it('should have toggle method', () => {
			expect(SettingsService.prototype.toggle).toBeDefined();
			expect(typeof SettingsService.prototype.toggle).toBe('function');
		});

		it('should have toggleWaitlist method', () => {
			expect(SettingsService.prototype.toggleWaitlist).toBeDefined();
			expect(typeof SettingsService.prototype.toggleWaitlist).toBe('function');
		});

		it('should have isWaitlistOpen method', () => {
			expect(SettingsService.prototype.isWaitlistOpen).toBeDefined();
			expect(typeof SettingsService.prototype.isWaitlistOpen).toBe('function');
		});

		it('should have _update private method', () => {
			expect(SettingsService.prototype._update).toBeDefined();
			expect(typeof SettingsService.prototype._update).toBe('function');
		});
	});
});
