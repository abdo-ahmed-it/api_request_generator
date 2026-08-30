import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import path from "node:path";

/** Hard cap on any tool's payload, applied after redaction and truncation. */
export const MAX_OUTPUT_BYTES = 100_000;

/** Wall-clock limit for one CLI invocation. `resend` hits the network. */
export const TIMEOUT_MS = 60_000;

export class ToolError extends Error {}

/**
 * Resolves `candidate` against the project root and refuses anything outside
 * it. Symlinks are followed first, so a link pointing out of the project is
 * rejected on its real location rather than its name.
 */
export async function resolveInsideProject(
  projectRoot: string,
  candidate: string,
): Promise<string> {
  const rootReal = await realpath(projectRoot);
  const absolute = path.resolve(rootReal, candidate);

  // Resolve the deepest existing ancestor: the target itself may not exist yet
  // (an output dir), but its parent chain must still live inside the project.
  let probe = absolute;
  for (;;) {
    try {
      probe = await realpath(probe);
      break;
    } catch {
      const parent = path.dirname(probe);
      if (parent === probe) break;
      probe = parent;
    }
  }

  const resolved = probe === absolute ? absolute : path.join(probe, path.relative(probe, absolute));
  const rel = path.relative(rootReal, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new ToolError(
      `Path escapes the project: ${candidate}. Paths must stay inside ${rootReal}.`,
    );
  }
  return resolved;
}

/**
 * Reads the Apidog token from the environment, then the macOS keychain.
 *
 * `.api2dart/config.yaml` is deliberately NOT consulted: it stores the token
 * in clear text on disk, and silently falling back to it would defeat the
 * point of moving the secret out.
 */
export async function apidogToken(): Promise<string> {
  const fromEnv = process.env.APIDOG_TOKEN?.trim();
  if (fromEnv) return fromEnv;

  try {
    const { stdout } = await run("security", [
      "find-generic-password",
      "-s",
      "api2dart-apidog-token",
      "-w",
    ], { timeoutMs: 5_000 });
    const token = stdout.trim();
    if (token) return token;
  } catch {
    // fall through to the explicit error below
  }

  throw new ToolError(
    "No Apidog token found.\n" +
      "Set APIDOG_TOKEN in the server's env, or store it in the keychain:\n" +
      `  security add-generic-password -s api2dart-apidog-token -a "$USER" -w '<TOKEN>'\n` +
      "The server never reads the token from .api2dart/config.yaml.",
  );
}

export interface RunResult {
  stdout: string;
  stderr: string;
  code: number;
}

/**
 * Runs a command with an argument array — never a shell string, so user input
 * (a filter, a path) can never be interpreted as shell syntax.
 */
export function run(
  command: string,
  args: string[],
  opts: { cwd?: string; timeoutMs?: number; env?: NodeJS.ProcessEnv } = {},
): Promise<RunResult> {
  return new Promise((resolve, reject) => {
    execFile(
      command,
      args,
      {
        cwd: opts.cwd,
        timeout: opts.timeoutMs ?? TIMEOUT_MS,
        maxBuffer: 32 * 1024 * 1024,
        env: opts.env ?? process.env,
        shell: false,
      },
      (error, stdout, stderr) => {
        const err = error as (NodeJS.ErrnoException & { killed?: boolean }) | null;
        if (err?.killed) {
          reject(
            new ToolError(
              `Timed out after ${(opts.timeoutMs ?? TIMEOUT_MS) / 1000}s: ${command}. ` +
                "The endpoint may be slow or unreachable.",
            ),
          );
          return;
        }
        resolve({
          stdout: stdout.toString(),
          stderr: stderr.toString(),
          code: err?.code === undefined ? 0 : Number(err.code) || 0,
        });
      },
    );
  });
}

/** Enforces the payload cap, appending an explicit notice when it trims. */
export function capOutput(text: string): string {
  const bytes = Buffer.byteLength(text, "utf8");
  if (bytes <= MAX_OUTPUT_BYTES) return text;
  const slice = Buffer.from(text, "utf8").subarray(0, MAX_OUTPUT_BYTES).toString("utf8");
  return (
    slice +
    `\n\n[TRUNCATED] Output exceeded ${MAX_OUTPUT_BYTES} bytes ` +
    `(was ${bytes}). Narrow the request with a filter.`
  );
}
