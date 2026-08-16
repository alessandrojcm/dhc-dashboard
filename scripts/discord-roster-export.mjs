// THROWAWAY MIGRATION SCRIPT: run once to export the Discord roster, then delete it.
// Keep roster.json restricted and delete it after the staged-assignment review window.

import { chmod, writeFile } from 'node:fs/promises';
import { REST } from '@discordjs/rest';
import { Routes } from 'discord-api-types/v10';

const PAGE_SIZE = 1000;
const OUTPUT_PATH = 'roster.json';

const token = requiredEnv('DISCORD_BOT_TOKEN');
const guildId = requiredEnv('DISCORD_GUILD_ID');
const discord = new REST({ version: '10' }).setToken(token);

if (!/^\d+$/.test(guildId)) {
  throw new Error('DISCORD_GUILD_ID must be a Discord snowflake');
}

const roster = [];
const seenIds = new Set();
let after;

while (true) {
  const members = await fetchPage(after);

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
}

await writeFile(OUTPUT_PATH, `${JSON.stringify(roster, null, 2)}\n`, {
  encoding: 'utf8',
  mode: 0o600,
});
await chmod(OUTPUT_PATH, 0o600);

console.log(`Wrote ${roster.length} members to ${OUTPUT_PATH}`);

async function fetchPage(cursor) {
  const query = new URLSearchParams({ limit: String(PAGE_SIZE) });

  if (cursor) {
    query.set('after', cursor);
  }

  const members = await discord.get(Routes.guildMembers(guildId), { query });

  if (!Array.isArray(members)) {
    throw new Error('Discord member-list response must be an array');
  }

  return members;
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
