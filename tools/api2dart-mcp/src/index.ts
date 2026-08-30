#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { existsSync } from "node:fs";
import path from "node:path";
import { z } from "zod";

import {
  inspectEndpoints,
  listLogs,
  matchesFilter,
  readLogFile,
  resolveInvocation,
  type EndpointReport,
} from "./api2dart.js";
import { redactMarkdown, redactJson, truncateArrays } from "./redact.js";
import { ToolError, apidogToken, capOutput, resolveInsideProject, run } from "./safety.js";

/**
 * Project root. The server only ever touches files inside it.
 * Defaults to the working directory the client launched it from.
 */
const PROJECT_ROOT = path.resolve(process.env.API2DART_PROJECT_ROOT ?? process.cwd());

/** Default output root, matching the CLI's own default. */
const OUTPUT_ROOT = "api2dart";

const SOURCES = ["apidog", "postman", "openapi", "file"] as const;

const server = new McpServer({ name: "api2dart", version: "0.1.0" });

/** Wraps a handler so every failure returns a readable message, not a stack. */
async function guard(fn: () => Promise<string>) {
  try {
    return { content: [{ type: "text" as const, text: capOutput(await fn()) }] };
  } catch (error) {
    const message = error instanceof ToolError ? error.message : (error as Error).message;
    return { content: [{ type: "text" as const, text: `Error: ${message}` }], isError: true };
  }
}

/** Resolves and validates the source spec path. */
async function specPath(config: string): Promise<string> {
  const resolved = await resolveInsideProject(PROJECT_ROOT, config);
  if (!existsSync(resolved)) {
    throw new ToolError(`Config file not found: ${config}`);
  }
  return resolved;
}

/** Injects the Apidog token only when the source actually needs it. */
async function tokenFor(source: string, provided?: string): Promise<string | undefined> {
  if (provided) return provided;
  if (source !== "apidog") return undefined;
  try {
    return await apidogToken();
  } catch {
    // An Apidog *export file* needs no token; only live fetching does. Let the
    // run proceed and fail with the CLI's own message if a token was required.
    return undefined;
  }
}

// ---------------------------------------------------------------------------
// api2dart_list - cheap exploration
// ---------------------------------------------------------------------------
server.registerTool(
  "api2dart_list",
  {
    title: "List API endpoints",
    description:
      "List every endpoint in an API source (method, path, name) without " +
      "fetching any response. Cheap and fast - use this to orient, then " +
      "api2dart_inspect on the few endpoints you actually need.",
    inputSchema: {
      source: z.enum(SOURCES).describe("Source type of the spec file."),
      config: z.string().describe("Path to the collection/spec file, inside the project."),
      filter: z.string().optional().describe("Case-insensitive substring match on path or name."),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ source, config, filter }) =>
    guard(async () => {
      const spec = await specPath(config);
      // No base URL: without one the CLI cannot fetch, so this stays offline.
      const { endpoints } = await inspectEndpoints(PROJECT_ROOT, {
        source,
        config: spec,
        token: await tokenFor(source),
      });

      const matched = endpoints.filter((e) => matchesFilter(e, filter));
      if (matched.length === 0) {
        return renderNoMatch(endpoints, filter);
      }

      const rows = matched.map(
        (e) => `${e.method.padEnd(6)} ${e.path}${e.name ? `  - ${e.name}` : ""}`,
      );
      return `${matched.length} endpoint(s)${filter ? ` matching "${filter}"` : ""}:\n\n${rows.join("\n")}`;
    }),
);

// ---------------------------------------------------------------------------
// api2dart_inspect - the primary tool
// ---------------------------------------------------------------------------
server.registerTool(
  "api2dart_inspect",
  {
    title: "Inspect endpoint shape",
    description:
      "Fetch the real shape of one or more endpoints - params, response schema, " +
      "a redacted sample and inferred Dart types - without writing any files. " +
      "Returns JSON and schema, deliberately not generated Dart: you write the " +
      "model yourself against your project's conventions. Includes notes[] " +
      "flagging shapes that naive models get wrong.",
    inputSchema: {
      source: z.enum(SOURCES).describe("Source type of the spec file."),
      config: z.string().describe("Path to the collection/spec file, inside the project."),
      base_url: z.string().optional().describe("Base URL, to fetch a live response sample."),
      filter: z
        .string()
        .optional()
        .describe(
          "Case-insensitive substring match on path or name. Narrow this - inspecting everything is slow.",
        ),
    },
    annotations: { readOnlyHint: true, openWorldHint: true },
  },
  async ({ source, config, base_url, filter }) =>
    guard(async () => {
      const spec = await specPath(config);
      const { endpoints } = await inspectEndpoints(PROJECT_ROOT, {
        source,
        config: spec,
        baseUrl: base_url,
        token: await tokenFor(source),
      });

      const matched = endpoints.filter((e) => matchesFilter(e, filter));
      if (matched.length === 0) {
        return renderNoMatch(endpoints, filter);
      }

      // The CLI redacts and truncates already; re-applying here keeps this
      // server correct on its own terms rather than trusting its input.
      const safe = matched.map((e) => truncateArrays(redactJson(e)));
      return JSON.stringify({ endpoint_count: safe.length, endpoints: safe }, null, 2);
    }),
);

// ---------------------------------------------------------------------------
// api2dart_read_log - safe reading of past captures
// ---------------------------------------------------------------------------
server.registerTool(
  "api2dart_read_log",
  {
    title: "Read a captured request log",
    description:
      "Read a previously captured request/response log. Prefer this over " +
      "`cat`: the raw files contain live tokens, and this path redacts them. " +
      "Omit `name` to list what is available.",
    inputSchema: {
      date: z.string().optional().describe('Dated folder, e.g. "2026-08-30". Defaults to the newest.'),
      name: z.string().optional().describe("Substring of the log name. Omit to list names only."),
      output: z.string().optional().describe(`Output root. Defaults to "${OUTPUT_ROOT}".`),
    },
    annotations: { readOnlyHint: true, openWorldHint: false },
  },
  async ({ date, name, output }) =>
    guard(async () => {
      const logs = await listLogs(PROJECT_ROOT, output ?? OUTPUT_ROOT, date);
      if (logs.length === 0) {
        return `No logs found under ${output ?? OUTPUT_ROOT}/${date ? `${date}/` : ""}logs. Run a generate first.`;
      }

      if (!name) {
        const rows = logs.map((l) => `${l.date}  ${l.name}`);
        return `${logs.length} log(s):\n\n${rows.join("\n")}\n\nPass "name" to read one.`;
      }

      const needle = name.toLowerCase();
      const hits = logs.filter((l) => l.name.toLowerCase().includes(needle));
      if (hits.length === 0) {
        return `No log matching "${name}".\n\nAvailable:\n${logs.map((l) => `  ${l.date}  ${l.name}`).join("\n")}`;
      }

      const chosen = hits[0];
      const raw = await readLogFile(chosen);
      const safe = redactMarkdown(raw);
      const extra = hits.length > 1 ? `\n\n(${hits.length} matched; showing "${chosen.name}".)` : "";
      return `# ${chosen.name} (${chosen.date})\n\n${safe}${extra}`;
    }),
);

// ---------------------------------------------------------------------------
// api2dart_resend - mutating
// ---------------------------------------------------------------------------
server.registerTool(
  "api2dart_resend",
  {
    title: "Resend a captured request",
    description:
      "Re-run a saved request to see whether its shape changed. WRITES TO " +
      "DISK: it overwrites the log file in place. Requires explicit approval.",
    inputSchema: {
      name: z.string().describe("Substring of the log name to resend."),
      date: z.string().optional().describe('Dated folder, e.g. "2026-08-30". Defaults to the newest.'),
      output: z.string().optional().describe(`Output root. Defaults to "${OUTPUT_ROOT}".`),
    },
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true },
  },
  async ({ name, date, output }) =>
    guard(async () => {
      const logs = await listLogs(PROJECT_ROOT, output ?? OUTPUT_ROOT, date);
      const needle = name.toLowerCase();
      const hits = logs.filter((l) => l.name.toLowerCase().includes(needle));
      if (hits.length === 0) {
        throw new ToolError(
          `No log matching "${name}".` +
            (logs.length
              ? `\n\nAvailable:\n${logs.map((l) => `  ${l.date}  ${l.name}`).join("\n")}`
              : ""),
        );
      }

      const chosen = hits[0];
      const before = await readLogFile(chosen);
      const { command, baseArgs } = resolveInvocation(PROJECT_ROOT);
      const { stderr, code } = await run(
        command,
        [...baseArgs, "resend", chosen.absolutePath],
        { cwd: PROJECT_ROOT },
      );

      const after = await readLogFile(chosen);
      const changed = statusOf(before) !== statusOf(after);
      return (
        `Resent "${chosen.name}" (exit ${code}).\n` +
        `Status: ${statusOf(before) ?? "?"} -> ${statusOf(after) ?? "?"}` +
        `${changed ? "  [changed]" : ""}\n\n` +
        redactMarkdown(after) +
        (code !== 0 ? `\n\n[stderr]\n${stderr.trim().split("\n").slice(-8).join("\n")}` : "")
      );
    }),
);

// ---------------------------------------------------------------------------
// api2dart_generate - mutating, rare
// ---------------------------------------------------------------------------
server.registerTool(
  "api2dart_generate",
  {
    title: "Generate Dart files",
    description:
      "Generate Dart action/response files on disk. Rare - prefer " +
      "api2dart_inspect and write the model yourself. WRITES TO DISK: " +
      "requires explicit approval. Output is a scratch draft, not final code.",
    inputSchema: {
      source: z.enum(SOURCES).describe("Source type of the spec file."),
      config: z.string().describe("Path to the collection/spec file, inside the project."),
      base_url: z.string().optional().describe("Base URL, to fetch live responses."),
      mode: z.enum(["auto", "action", "response-only"]).optional().describe('Defaults to "auto".'),
      output: z.string().optional().describe(`Output root. Defaults to "${OUTPUT_ROOT}" (gitignored).`),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
  },
  async ({ source, config, base_url, mode, output }) =>
    guard(async () => {
      const spec = await specPath(config);
      // Keep output inside the project so it stays covered by .gitignore.
      const outputRoot = output ?? OUTPUT_ROOT;
      await resolveInsideProject(PROJECT_ROOT, outputRoot);

      const { command, baseArgs } = resolveInvocation(PROJECT_ROOT);
      const args = [
        ...baseArgs,
        "generate",
        "-s", source,
        "-c", spec,
        "--no-interactive",
        "-o", outputRoot,
      ];
      if (base_url) args.push("-b", base_url);
      if (mode) args.push("-m", mode);
      const token = await tokenFor(source);
      if (token) args.push("-t", token);

      const { stdout, stderr, code } = await run(command, args, { cwd: PROJECT_ROOT });
      const log = [stdout, stderr].join("\n").trim().split("\n").slice(-25).join("\n");

      return (
        `api2dart generate finished (exit ${code}).\n\n${stripAnsi(log)}\n\n` +
        "WARNING: scratch draft, not final code. Before moving anything into " +
        "lib/: prefix the class names (bare `Response`/`User` collide), replace " +
        "raw casts with your Json.* helpers, drop unused toJson(), and apply " +
        "the localized-twin rule."
      );
    }),
);

function renderNoMatch(endpoints: EndpointReport[], filter?: string): string {
  const available = endpoints.map((e) => `  ${e.method.padEnd(6)} ${e.path}`).join("\n");
  return (
    `No endpoint matched ${filter ? `"${filter}"` : "the request"}.\n\n` +
    `${endpoints.length} available:\n${available}`
  );
}

function statusOf(markdown: string): string | undefined {
  return /\*\*Status:\*\*\s*\S*\s*`([^`]+)`/.exec(markdown)?.[1];
}

/** Strips ANSI colour codes so CLI log boxes read cleanly in a transcript. */
function stripAnsi(text: string): string {
  return text.replace(/\u001B\[[0-9;]*m/g, "");
}

const transport = new StdioServerTransport();
await server.connect(transport);
