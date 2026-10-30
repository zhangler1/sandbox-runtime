import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import {
  checkWindowsSandboxStatusAsync,
  installWindowsSandboxAsync,
  resolveSrtWin,
  uninstallWindowsSandbox,
} from '@anthropic-ai/sandbox-runtime';
import { writeVerifiedHelper } from './runner.mjs';

async function withHelper(operation) {
  if (process.platform !== 'win32') throw new Error('Windows setup requires Windows');
  const dir = await mkdtemp(join(tmpdir(), 'srt-cli-setup-'));
  try {
    const helper = join(dir, 'srt-win.exe');
    await writeVerifiedHelper(helper);
    return await operation(resolveSrtWin({ path: helper }));
  } finally {
    await rm(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 500 });
  }
}

function summary(state) {
  return {
    cancelled: Boolean(state.cancelled),
    userProvisioned: Boolean(state.user?.provisioned),
    wfpState: state.wfp?.state ?? null,
    wfpFilters: state.wfp?.filters ?? null,
    portRange: state.wfp?.portRange ?? null,
    profileGrantApplied: state.profileGrant?.applied ?? null,
  };
}

export async function installSandbox() {
  return withHelper(async (srtWin) => summary(await installWindowsSandboxAsync({
    srtWin,
    skipProfileGrant: true,
  })));
}

export async function getSandboxStatus() {
  return withHelper(async (srtWin) => summary(await checkWindowsSandboxStatusAsync({ srtWin })));
}

export async function uninstallSandbox() {
  return withHelper(async (srtWin) => {
    const result = uninstallWindowsSandbox({ srtWin });
    return { cancelled: Boolean(result.cancelled), removed: !result.cancelled };
  });
}
