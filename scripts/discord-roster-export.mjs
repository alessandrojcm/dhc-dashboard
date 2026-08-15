// THROWAWAY MIGRATION SCRIPT: run once to export the Discord roster, then delete it.
// Keep roster.json restricted and delete it after the staged-assignment review window.

import { chmod, writeFile } from 'node:fs/promises';

const API_BASE_URL = 'https://discord.com/api/v10';
const PAGE_SIZE = 1000;
const OUTPUT_PATH = 'roster.json';

const token = requiredEnv('DISCORD_BOT_TOKEN');
const guildId = requiredEnv('DISCORD_GUILD_ID');

if (!/^\d+$/.test(guildId)) {
  throw new Error('DISCORD_GUILD_ID must be a Discord snowflake');
}

const roster = [];
const seenIds = new Set();
let after;

while (true) {
  const { members, resetAfterMs } = await fetchPage(after);

  for (const member of members) {
    const exported = exportMember(member);

    if (seenIds.has(exported.id)) {
      throw new Error(`Discord returned duplicate member id ${exported.id}`);
    }

    seenIds.add(exported.id);
    roster.push(exported);
  }

  if (members.length < PAGE_SIZE) {
    break;
  }

  const nextAfter = members.at(-1).user.id;

  if (nextAfter === after) {
    throw new Error('Discord member pagination cursor did not advance');
  }

  after = nextAfter;

  if (resetAfterMs > 0) {
    await sleep(resetAfterMs);
  }
}

await writeFile(OUTPUT_PATH, `${JSON.stringify(roster, null, 2)}\n`, {
  encoding: 'utf8',
  mode: 0o600,
});
await chmod(OUTPUT_PATH, 0o600);

console.log(`Wrote ${roster.length} members to ${OUTPUT_PATH}`);

async function fetchPage(cursor) {
  const url = new URL(`${API_BASE_URL}/guilds/${guildId}/members`);
  url.searchParams.set('limit', String(PAGE_SIZE));

  if (cursor) {
    url.searchParams.set('after', cursor);
  }

  while (true) {
    const response = await fetch(url, {
      headers: { Authorization: `Bot ${token}` },
    });

    if (response.status === 429) {
      const retryAfterMs = await rateLimitDelay(response);
      await sleep(retryAfterMs);
      continue;
    }

    if (!response.ok) {
      throw new Error(`Discord member export failed with HTTP ${response.status}`);
    }

    let members;

    try {
      members = await response.json();
    } catch {
      throw new Error('Discord returned malformed JSON for the member list');
    }

    if (!Array.isArray(members)) {
      throw new Error('Discord member-list response must be an array');
    }

    const remaining = Number(response.headers.get('x-ratelimit-remaining'));
    const resetAfterSeconds = Number(response.headers.get('x-ratelimit-reset-after'));
    const resetAfterMs = remaining === 0 && Number.isFinite(resetAfterSeconds)
      ? Math.max(0, Math.ceil(resetAfterSeconds * 1000))
      : 0;

    return { members, resetAfterMs };
  }
}

async function rateLimitDelay(response) {
  const retryAfterValue = response.headers.get('retry-after');
  const retryAfterHeader = retryAfterValue == null ? Number.NaN : Number(retryAfterValue);
  let body;

  try {
    body = await response.json();
  } catch {
    body = null;
  }

  const retryAfterSeconds = Number.isFinite(retryAfterHeader) && retryAfterHeader >= 0
    ? retryAfterHeader
    : Number(body?.retry_after);

  if (!Number.isFinite(retryAfterSeconds) || retryAfterSeconds < 0) {
    throw new Error('Discord rate-limit response did not include a valid retry delay');
  }

  return Math.max(1, Math.ceil(retryAfterSeconds * 1000));
}

function exportMember(member) {
  if (!member || typeof member !== 'object' || !member.user || typeof member.user !== 'object') {
    throw new Error('Discord returned a malformed guild member');
  }

  const { id, username, global_name: globalName } = member.user;
  const nickname = member.nick;

  if (typeof id !== 'string' || !/^\d+$/.test(id) || typeof username !== 'string' || !username) {
    throw new Error('Discord returned a guild member without a valid id and username');
  }

  if (globalName != null && typeof globalName !== 'string') {
    throw new Error(`Discord returned an invalid global name for member ${id}`);
  }

  if (nickname != null && typeof nickname !== 'string') {
    throw new Error(`Discord returned an invalid nickname for member ${id}`);
  }

  return {
    id,
    username,
    global_name: globalName ?? null,
    nickname: nickname ?? null,
  };
}

function requiredEnv(name) {
  const value = process.env[name];

  if (!value) {
    throw new Error(`${name} is required`);
  }

  return value;
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
