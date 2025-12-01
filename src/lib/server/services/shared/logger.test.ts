import { describe, expect, it, vi, beforeEach } from 'vitest';
import { consoleLogger, sentryLogger } from './logger';
import type { Logger } from './logger';

describe('Logger', () => {
	describe('consoleLogger', () => {
		beforeEach(() => {
			// Clear all mocks before each test
			vi.clearAllMocks();
		});

		it('should log info messages to console', () => {
			const consoleInfoSpy = vi.spyOn(console, 'info').mockImplementation(() => {});

			consoleLogger.info('Test message', { key: 'value' });

			expect(consoleInfoSpy).toHaveBeenCalledWith('Test message', {
				key: 'value'
			});

			consoleInfoSpy.mockRestore();
		});

		it('should log error messages to console', () => {
			const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});

			consoleLogger.error('Error message', { error: 'details' });

			expect(consoleErrorSpy).toHaveBeenCalledWith('Error message', {
				error: 'details'
			});

			consoleErrorSpy.mockRestore();
		});

		it('should log warning messages to console', () => {
			const consoleWarnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});

			consoleLogger.warn('Warning message', { warning: 'details' });

			expect(consoleWarnSpy).toHaveBeenCalledWith('Warning message', {
				warning: 'details'
			});

			consoleWarnSpy.mockRestore();
		});

		it('should log debug messages to console', () => {
			const consoleDebugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {});

			consoleLogger.debug('Debug message', { debug: 'details' });

			expect(consoleDebugSpy).toHaveBeenCalledWith('Debug message', {
				debug: 'details'
			});

			consoleDebugSpy.mockRestore();
		});
	});

	describe('Logger interface compliance', () => {
		it('consoleLogger should implement Logger interface', () => {
			const logger: Logger = consoleLogger;

			expect(logger.info).toBeDefined();
			expect(logger.error).toBeDefined();
			expect(logger.warn).toBeDefined();
			expect(logger.debug).toBeDefined();
		});

		it('sentryLogger should implement Logger interface', () => {
			const logger: Logger = sentryLogger;

			expect(logger.info).toBeDefined();
			expect(logger.error).toBeDefined();
			expect(logger.warn).toBeDefined();
			expect(logger.debug).toBeDefined();
		});
	});
});
