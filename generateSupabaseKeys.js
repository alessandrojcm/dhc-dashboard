import crypto from 'node:crypto';

// URL-safe base64 encoding (no external package)
function base64UrlEncode(input) {
	return Buffer.from(input)
		.toString('base64')
		.replace(/=/g, '')
		.replace(/\+/g, '-')
		.replace(/\//g, '_');
}

function generateSupabaseKey(role, jwtSecret) {
	// Create the header
	const header = {
		alg: 'HS256',
		typ: 'JWT'
	};

	// Create the payload with required claims
	const now = Math.floor(Date.now() / 1000);
	const payload = {
		role: role,
		iss: 'supabase',
		iat: now,
		exp: now + 60 * 60 * 24 * 365 * 5 // 5 years expiration
	};

	// Base64Url encode the header and payload
	const encodedHeader = base64UrlEncode(JSON.stringify(header));
	const encodedPayload = base64UrlEncode(JSON.stringify(payload));

	// Create the content to be signed
	const signatureContent = `${encodedHeader}.${encodedPayload}`;

	// Create the signature
	const signature = crypto.createHmac('sha256', jwtSecret).update(signatureContent).digest();

	// Base64Url encode the signature
	const encodedSignature = base64UrlEncode(signature);

	// Combine to create the JWT token
	return `${signatureContent}.${encodedSignature}`;
}

// Example usage
const JWT_SECRET = process.env.SUPABASE_JWT_SECRET || 'your-jwt-secret-here';

const serviceRoleKey = generateSupabaseKey('service_role', JWT_SECRET);
const anonKey = generateSupabaseKey('anon', JWT_SECRET);

console.log('SERVICE_ROLE Key:');
console.log(serviceRoleKey);
console.log('\nANON Key:');
console.log(anonKey);
