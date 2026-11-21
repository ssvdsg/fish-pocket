// Make OpenCode Go the first-run provider and the default model, once per install.
//
// The row goes into the profile's own patch (the layer 设置 writes), not
// ios.patch.yml: an overlay config would sit above the settings layer and the
// model/provider editor would refuse to change it. A marker records that this
// ran; anything the user already configured is left alone.
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { loadProfile } from '@deepseek-ai/dsh-app-boot';
import { writeFileAtomic } from '@deepseek-ai/dsh-atomic-write';
import { isSeq, parseDocument } from 'yaml';

export const PROVIDER = 'opencode-go';
export const MODEL = 'deepseek-v4.1-flash';
export const KEY_REF = 'OPENCODE_API_KEY';

/**
 * Seed the OpenCode Go provider and default model unless the profile already
 * has settings for either.
 * @param {object} options
 * @param {string} options.home - DSH_HOME.
 * @param {string} options.marker - the file that records this ran.
 * @param {string} options.installAnchor - the dsh package's package.json, where profile bundles resolve from.
 * @returns {Promise<'seeded' | 'kept' | 'done'>}
 */
export async function seedOpenCodeDefault({ home, marker, installAnchor }) {
  if (existsSync(marker)) return 'done';
  const profile = loadProfile('dsh', 'web', installAnchor, home);
  const hasProvider = profile.patches.some((row) => row.id === 'llm-pi-ai' && row.insert === undefined);
  const hasDefault = profile.patches.some((row) => row.id === 'agent-default-model' && row.insert === undefined);
  let outcome = 'kept';
  if (!hasProvider && !hasDefault) {
    await append(profile.patchPath, [
      {
        id: 'llm-pi-ai',
        config: { providers: { [PROVIDER]: { apiKeyEnv: KEY_REF } } },
      },
      {
        id: 'agent-default-model',
        config: { provider: PROVIDER, model: MODEL },
      },
    ]);
    outcome = 'seeded';
  }
  await writeFileAtomic(marker, `${outcome}\n`, { mode: 0o600 });
  return outcome;
}

/** Add rows to a patch file, keeping what is there (comments and `!!js` tags included). */
async function append(file, rows) {
  let text;
  try {
    text = await readFile(file, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    text = '[]\n';
  }
  const document = parseDocument(text, {
    customTags: [{ tag: 'tag:yaml.org,2002:js', resolve: (value) => value }],
  });
  if (document.errors[0] !== undefined) throw document.errors[0];
  if (document.contents === null) document.contents = document.createNode([]);
  if (!isSeq(document.contents)) throw new Error(`${file}: a profile patch must be a YAML sequence`);
  document.contents.flow = false;
  for (const row of rows) document.add(document.createNode(row));
  await writeFileAtomic(file, String(document), { mode: 0o600 });
}
