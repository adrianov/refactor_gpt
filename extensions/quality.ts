/**
 * omp extension: quality stop pipeline (adapter over the Cursor Ruby hook).
 *
 * At session_stop it converts the current omp session branch into the
 * transcript shape ~/ruby/refactor_gpt/hooks/quality.rb expects and launches
 * that pipeline in the background (omp caps event handlers at a hardcoded
 * 30s; the Ruby pipeline runs for minutes). When the pipeline finishes, its
 * followup_message is delivered as a queued follow-up message so the agent
 * keeps working (Cursor's followup_message equivalent).
 *
 * Env (portable across machines — same file works on macOS and Linux):
 *   QUALITY_HOOK_RB — absolute path to quality.rb. Default:
 *     $HOME/ruby/refactor_gpt/hooks/quality.rb (same layout on both machines).
 *   QUALITY_RUBY — ruby interpreter override; otherwise auto-detected
 *     (rbenv shim → Homebrew (macOS/Linux) → system ruby).
 *   QUALITY_OWN_GITHUB — GitHub owner treated as "own"; defaults to
 *     "adrianov" (mirrors ~/.cursor/hooks.json) when unset. Set it explicitly
 *     (even to an empty string = off) to override.
 *
 * Everything else (QUALITY_RUBOCOP_DOCKER*, QUALITY_LOCAL) is inherited by
 * the Ruby process unchanged.
 */
import { existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const DEFAULT_HOOK_RB = join(homedir(), "ruby/refactor_gpt/hooks/quality.rb");
/** Cursor parity: ~/.cursor/hooks.json launches the hook with QUALITY_OWN_GITHUB=adrianov. */
const DEFAULT_OWN_GITHUB = "adrianov";
/** Watchdog: kill a hung pipeline run after this long; its results are dropped. */
const RUN_TIMEOUT_MS = 10 * 60 * 1000;
/** Grace between SIGTERM and SIGKILL when terminating a run. */
const KILL_GRACE_MS = 5_000;

/** omp tool name → name in the transcript the Ruby hook understands. */
const TOOL_NAME_MAP: Record<string, string> = {
	bash: "Shell",
	read: "Read",
	glob: "Glob",
	grep: "Grep",
	ast_grep: "SemanticSearch",
	web_search: "WebSearch",
	todo: "TodoWrite",
	task: "Task",
	ask: "AskQuestion",
	lsp: "ReadLints",
};

interface ToolUse {
	type: "tool_use";
	name: string;
	input: Record<string, unknown>;
}
type ContentItem = { type: "text"; text: string } | ToolUse;
interface TranscriptMessage {
	role: "user" | "assistant";
	message: { content: ContentItem[] };
}

function asObject(value: unknown): Record<string, unknown> | null {
	return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

/** Map an omp tool call to the Ruby hook's vocabulary. */
function normalizeToolUse(name: string, rawInput: unknown, cwd: string): ToolUse {
	const raw = asObject(rawInput) ?? {};
	const input: Record<string, unknown> = { ...raw };
	// The harness wraps some tools (edit) as { i, input: { …real params… } };
	// the Ruby hook reads path-ish keys from the top level, so flatten.
	const inner = asObject(raw.input);
	if (inner) Object.assign(input, inner);
	let mapped = TOOL_NAME_MAP[name] ?? name;
	if (mapped === "Shell") {
		if (input.working_directory == null || input.working_directory === "") {
			input.working_directory =
				typeof input.cwd === "string" && input.cwd.length > 0 ? input.cwd : cwd;
		}
	}
	// The edit tool carries its changes as one anchored-edit string
	// ("[app/models/x.rb#A1B2] …"). Translate the section headers into the
	// Cursor patch markers the Ruby hook scans for file paths.
	if (name === "edit" && typeof input.input === "string") {
		const paths = [...input.input.matchAll(/^\[([^\]\n]+?)#[^\]\n]*\]/gm)].map((m) => m[1]);
		if (paths.length > 0) return { type: "tool_use", name: "edit", input: paths.map((p) => `*** Update File: ${p}`).join("\n") };
	}
	return { type: "tool_use", name: mapped, input };
}

function textItemsFromUser(content: unknown): ContentItem[] {
	if (typeof content === "string") return [{ type: "text", text: content }];
	const items: ContentItem[] = [];
	for (const block of Array.isArray(content) ? content : []) {
		const b = asObject(block);
		if (!b || b.type !== "text" || typeof b.text !== "string") continue;
		items.push({ type: "text", text: b.text });
	}
	return items;
}

function itemsFromAssistant(content: unknown, cwd: string): ContentItem[] {
	const items: ContentItem[] = [];
	for (const block of Array.isArray(content) ? content : []) {
		const b = asObject(block);
		if (!b) continue;
		if (b.type === "text" && typeof b.text === "string") {
			items.push({ type: "text", text: b.text });
		} else if ((b.type === "toolCall" || b.type === "tool_use") && typeof b.name === "string") {
			items.push(normalizeToolUse(b.name, b.arguments ?? b.input, cwd));
		}
	}
	return items;
}

/** Convert omp session entries into Cursor-style transcript messages. */
export function convertBranchToTranscript(
	entries: ReadonlyArray<unknown>,
	cwd: string,
): TranscriptMessage[] {
	const messages: TranscriptMessage[] = [];
	for (const entry of entries) {
		const e = asObject(entry);
		if (!e || e.type !== "message") continue;
		const m = asObject(e.message);
		if (!m) continue;
		if (m.role === "user") {
			const items = textItemsFromUser(m.content);
			if (items.length > 0) messages.push({ role: "user", message: { content: items } });
		} else if (m.role === "assistant") {
			const items = itemsFromAssistant(m.content, cwd);
			if (items.length > 0) messages.push({ role: "assistant", message: { content: items } });
		}
	}
	return messages;
}

/** True when the turn ended in a user abort — do not fight the interrupt. */
function lastAssistantAborted(entries: ReadonlyArray<unknown>): boolean {
	for (let i = entries.length - 1; i >= 0; i--) {
		const e = asObject(entries[i]);
		if (!e || e.type !== "message") continue;
		const m = asObject(e.message);
		if (!m) return false;
		if (m.role !== "assistant") return false;
		return m.stopReason === "aborted";
	}
	return false;
}

/** Pull followup_message out of the Ruby hook's stdout (last JSON line wins). */
function extractFollowup(stdout: string): string | null {
	let followup: string | null = null;
	for (const line of stdout.split("\n")) {
		const trimmed = line.trim();
		if (!trimmed.startsWith("{")) continue;
		let parsed: unknown;
		try {
			parsed = JSON.parse(trimmed);
		} catch {
			continue;
		}
		const obj = asObject(parsed);
		if (obj && typeof obj.followup_message === "string" && obj.followup_message.length > 0) {
			followup = obj.followup_message;
		}
	}
	return followup;
}

/** A quality pipeline run: kill() aborts the Ruby process; done settles when it exits. */
interface HookRun {
	kill(): void;
	done: Promise<{ stdout: string; stderr: string; timedOut: boolean; exitCode: number | null }>;
}

/**
 * Spawn the Ruby pipeline without awaiting it. omp caps extension handlers at
 * 30s (EXTENSION_HANDLER_TIMEOUT_MS, not configurable), far below what the
 * pipeline needs, so the caller returns immediately and consumes `done` later.
 * Payload is well under the pipe buffer, so writing stdin before draining
 * stdout cannot deadlock.
 */
function startHookRun(rubyBin: string, hookPath: string, payload: unknown): HookRun {
	const proc = Bun.spawn([rubyBin, hookPath], {
		stdin: "pipe",
		stdout: "pipe",
		stderr: "pipe",
		env: { ...process.env, QUALITY_OWN_GITHUB: process.env.QUALITY_OWN_GITHUB ?? DEFAULT_OWN_GITHUB },
	});
	let timedOut = false;
	// TERM first; a hook stuck in a git subprocess is KILLed after the grace period.
	const killProc = () => {
		try {
			proc.kill();
		} catch {
			return;
		}
		setTimeout(() => {
			try {
				proc.kill("SIGKILL");
			} catch {
				// already exited
			}
		}, KILL_GRACE_MS);
	};
	const timer = setTimeout(() => {
		timedOut = true;
		killProc();
	}, RUN_TIMEOUT_MS);
	const stdinDone = (async () => {
		try {
			proc.stdin.write(JSON.stringify(payload));
			await proc.stdin.end();
		} catch {
			// stdin closed early (hook crashed) — nothing to feed anymore
		}
	})();
	const done = Promise.all([
		new Response(proc.stdout).text(),
		new Response(proc.stderr).text(),
		stdinDone,
	]).then(async ([stdout, stderr]) => {
		await proc.exited;
		clearTimeout(timer);
		return { stdout, stderr, timedOut, exitCode: proc.exitCode };
	});
	return {
		kill: killProc,
		done,
	};
}

/** Toolchain preference: QUALITY_RUBY env, rbenv shim, Homebrew (macOS/Linux), system. */
function resolveRuby(): string {
	const override = process.env.QUALITY_RUBY;
	if (override != null && override.trim() !== "") return override;
	const candidates = [
		join(homedir(), ".rbenv/shims/ruby"),
		"/opt/homebrew/opt/ruby/bin/ruby", // macOS (Apple silicon)
		"/usr/local/opt/ruby/bin/ruby", // macOS (Intel)
		"/home/linuxbrew/.linuxbrew/opt/ruby/bin/ruby", // Linux
		"/usr/bin/ruby",
	];
	for (const candidate of candidates) if (existsSync(candidate)) return candidate;
	return "ruby";
}
function logExtension(pi: ExtensionAPI, message: string): void {
	try {
		const logger = pi.logger;
		if (logger && typeof logger === "object" && "info" in logger && typeof logger.info === "function") {
			logger.info(`[quality-omp] ${message}`);
		}
	} catch {
		// logging must never break settle
	}
}

export default function qualityExtension(pi: ExtensionAPI): void {
	let active: HookRun | null = null;

	pi.on("session_shutdown", () => {
		if (active) logExtension(pi, "session shutdown: killing running pipeline");
		active?.kill();
		active = null;
	});

	pi.on("session_stop", async (event, ctx) => {
		const fromEnv = process.env.QUALITY_HOOK_RB?.trim();
		const hookPath = fromEnv && fromEnv.length > 0 ? fromEnv : DEFAULT_HOOK_RB;
		if (!existsSync(hookPath)) return undefined;

		const entries = ctx.sessionManager.getBranch() as ReadonlyArray<unknown>;
		if (entries.length === 0 || lastAssistantAborted(entries)) return undefined;
		if (active) {
			logExtension(pi, "previous pipeline still running; skipping this stop");
			return undefined;
		}

		const cwd = ctx.cwd;
		const sessionId = ctx.sessionManager.getSessionId();
		const transcriptPath = join(tmpdir(), `quality-omp-${sessionId}.jsonl`);
		const transcript = convertBranchToTranscript(entries, cwd);
		await Bun.write(transcriptPath, transcript.map((m) => JSON.stringify(m)).join("\n") + "\n");

		const chained = "stop_hook_active" in event && event.stop_hook_active === true;
		const payload = {
			status: "completed",
			conversation_id: sessionId,
			transcript_path: transcriptPath,
			workspace_roots: [cwd],
			loop_count: chained ? 1 : 0,
		};

		logExtension(pi, `session ${sessionId}: ${transcript.length} msgs, chain=${chained} (background)`);
		try {
			ctx.ui.setStatus("quality", "running");
		} catch {
			/* headless */
		}
		const run = startHookRun(resolveRuby(), hookPath, payload);
		active = run;
		void run.done
			.then(
				async ({ stdout, stderr, timedOut, exitCode }) => {
					if (active === run) active = null;
					try {
						ctx.ui.setStatus("quality", "");
					} catch {
						/* session may be gone */
					}
					if (timedOut) {
						logExtension(pi, "pipeline timed out; dropping results");
						return;
					}
					const followup = extractFollowup(stdout);
					logExtension(pi, `pipeline finished: exit=${exitCode} stderr=${stderr.length}b followup=${followup ? "yes" : "no"}`);
					if (stderr.trim()) logExtension(pi, stderr.trim());
					if (!followup) return;
					logExtension(pi, `followup: ${followup.slice(0, 120)}`);
					await pi.sendUserMessage(followup, { deliverAs: "followUp" });
				},
				(error) => {
					if (active === run) active = null;
					logExtension(pi, `pipeline crashed: ${error instanceof Error ? error.message : String(error)}`);
				},
			)
			.catch((error: unknown) => {
				logExtension(pi, `post-pipeline error: ${error instanceof Error ? error.message : String(error)}`);
			});
		return undefined; // settle immediately; results arrive as a follow-up message
	});
}
