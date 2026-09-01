import { existsSync } from "node:fs";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

import { ToolError, run, resolveInsideProject, TIMEOUT_MS } from "./safety.js";

/**
 * How to invoke the tool. Preferring the local checkout matters: the globally
 * installed `api2dart` may be an older release without `generate --json`.
 */
export interface Api2DartInvocation {
  command: string;
  baseArgs: string[];
}

export function resolveInvocation(projectRoot: string): Api2DartInvocation {
  const localEntry = path.join(projectRoot, "bin", "api_to_dart.dart");
  if (existsSync(localEntry)) {
    return { command: "dart", baseArgs: ["run", localEntry] };
  }
  return { command: "api2dart", baseArgs: [] };
}

export interface GenerateOptions {
  source: string;
  /** Omitted for Apidog: the CLI then replays the project bound in the wizard. */
  config?: string;
  baseUrl?: string;
  token?: string;
  mode?: string;
  output?: string;
  json: boolean;
  dryRun: boolean;
}

/** Builds the argv for `generate`. Every value is a separate array element. */
export function generateArgs(opts: GenerateOptions): string[] {
  const args = ["generate", "-s", opts.source, "--no-interactive"];
  if (opts.config) args.push("-c", opts.config);
  if (opts.json) args.push("--json");
  if (opts.dryRun) args.push("--dry-run");
  if (opts.baseUrl) args.push("-b", opts.baseUrl);
  if (opts.token) args.push("-t", opts.token);
  if (opts.mode) args.push("-m", opts.mode);
  if (opts.output) args.push("-o", opts.output);
  return args;
}

export interface EndpointReport {
  name: string;
  method: string;
  path: string;
  description?: string;
  requires_auth: boolean;
  query_params: { name: string; example: string }[];
  headers: string[];
  body?: Record<string, unknown>;
  response: Record<string, unknown>;
  notes: string[];
  would_write?: string;
}

/**
 * Runs `generate --json` and parses the report.
 *
 * stdout carries only the JSON document (the CLI routes diagnostics to stderr
 * in this mode), so a parse failure means the run itself failed — stderr is
 * surfaced rather than swallowed.
 */
export async function inspectEndpoints(
  projectRoot: string,
  opts: Omit<GenerateOptions, "json" | "dryRun">,
): Promise<{ endpoints: EndpointReport[]; stderr: string }> {
  const { command, baseArgs } = resolveInvocation(projectRoot);
  const args = [...baseArgs, ...generateArgs({ ...opts, json: true, dryRun: false })];

  const { stdout, stderr, code } = await run(command, args, {
    cwd: projectRoot,
    timeoutMs: TIMEOUT_MS,
  });

  const start = stdout.indexOf("{");
  if (start < 0) {
    throw new ToolError(
      `api2dart produced no JSON (exit ${code}).\n${tail(stderr)}`,
    );
  }

  try {
    const parsed = JSON.parse(stdout.slice(start)) as { endpoints?: EndpointReport[] };
    return { endpoints: parsed.endpoints ?? [], stderr };
  } catch (error) {
    throw new ToolError(
      `Could not parse api2dart JSON output (exit ${code}): ${(error as Error).message}\n` +
        tail(stderr),
    );
  }
}

/** Case-insensitive substring match over path and name. */
export function matchesFilter(endpoint: EndpointReport, filter?: string): boolean {
  if (!filter) return true;
  const needle = filter.toLowerCase();
  return (
    endpoint.path.toLowerCase().includes(needle) ||
    endpoint.name.toLowerCase().includes(needle)
  );
}

export interface LogFile {
  date: string;
  name: string;
  absolutePath: string;
  modified: Date;
}

/**
 * Lists log files under `<output>/<date>/logs`, newest date first. Every path
 * is validated to stay inside the project.
 */
export async function listLogs(
  projectRoot: string,
  outputRoot: string,
  date?: string,
): Promise<LogFile[]> {
  const root = await resolveInsideProject(projectRoot, outputRoot);
  if (!existsSync(root)) return [];

  const dateDirs = (await readdir(root, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .reverse();

  const wanted = date ? dateDirs.filter((d) => d === date) : dateDirs;
  const files: LogFile[] = [];

  for (const dateDir of wanted) {
    const logsDir = path.join(root, dateDir, "logs");
    if (!existsSync(logsDir)) continue;
    for (const entry of await readdir(logsDir)) {
      if (!entry.endsWith(".md")) continue;
      const absolutePath = path.join(logsDir, entry);
      files.push({
        date: dateDir,
        name: entry.replace(/\.md$/, ""),
        absolutePath,
        modified: (await stat(absolutePath)).mtime,
      });
    }
  }
  return files;
}

export async function readLogFile(file: LogFile): Promise<string> {
  return readFile(file.absolutePath, "utf8");
}

function tail(text: string, lines = 12): string {
  return text.trim().split("\n").slice(-lines).join("\n");
}
