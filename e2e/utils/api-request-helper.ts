import type { APIRequestContext, BrowserContext } from '@playwright/test';

/**
 * Helper function to make authenticated API requests using cookies
 */
export async function makeAuthenticatedRequest(
  request: APIRequestContext,
  context: BrowserContext,
  method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE',
  url: string,
  options: {
    data?: any;
    params?: Record<string, string>;
    headers?: Record<string, string>;
  } = {}
) {
  const cookies = await context
    .cookies()
    .then((cookies) => cookies.map((c) => `${c.name}=${c.value}`).join('; '));

  const headers = {
    'Content-Type': 'application/json',
    cookie: cookies,
    ...options.headers
  };

  const requestOptions: any = {
    headers
  };

  if (options.data) {
    requestOptions.data = options.data;
  }

  if (options.params) {
    const urlWithParams = new URL(url, 'http://localhost');
    Object.entries(options.params).forEach(([key, value]) => {
      urlWithParams.searchParams.set(key, value);
    });
    url = urlWithParams.pathname + urlWithParams.search;
  }

  switch (method) {
    case 'GET':
      return request.get(url, requestOptions);
    case 'POST':
      return request.post(url, requestOptions);
    case 'PATCH':
      return request.patch(url, requestOptions);
    case 'PUT':
      return request.put(url, requestOptions);
    case 'DELETE':
      return request.delete(url, requestOptions);
    default:
      throw new Error(`Unsupported HTTP method: ${method}`);
  }
}

/**
 * Shorthand helpers for common HTTP methods
 */
export const apiRequest = {
  get: (request: APIRequestContext, context: BrowserContext, url: string, options = {}) =>
    makeAuthenticatedRequest(request, context, 'GET', url, options),
  
  post: (request: APIRequestContext, context: BrowserContext, url: string, options = {}) =>
    makeAuthenticatedRequest(request, context, 'POST', url, options),
  
  patch: (request: APIRequestContext, context: BrowserContext, url: string, options = {}) =>
    makeAuthenticatedRequest(request, context, 'PATCH', url, options),
  
  put: (request: APIRequestContext, context: BrowserContext, url: string, options = {}) =>
    makeAuthenticatedRequest(request, context, 'PUT', url, options),
  
  delete: (request: APIRequestContext, context: BrowserContext, url: string, options = {}) =>
    makeAuthenticatedRequest(request, context, 'DELETE', url, options)
};