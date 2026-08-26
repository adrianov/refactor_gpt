//! Running the Ruby quality pipeline: ruby-toolchain resolution, background
//! spawn with watchdog, and followup extraction from its stdout.

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { asObject } from "./transcript";

/** Cursor parity: ~/.cursor/hooks.json launches the hook with QUALITY_OWN_GITHUB=adrianov. */
const DEFAULT_OWN_GITHUB = "adrianov";
/** Watchdog: kill a hung pipeline run after this long; its results are dropped. */
const RUN_TIMEOUT_MS = 10 * 60 * 1000;
/** Grace between SIGTERM and SIGKILL when terminating a run. */
const KILL_GRACE_MS = 5_000;

/** Everything needed to relay one finished pipeline run. */
export interface ScanOutcome {
	stdout: string;
	stderr: string;
	timedOut: boolean;
	exitCode: number | null;
}

/** A quality pipeline run: kill() aborts the Ruby process; done settles when it exits. */
export interface HookRun {
	kill(): void;
	done: Promise<ScanOutcome>;
}

/** Pull followup_message out of the Ruby hook's stdout (last JSON line wins).
 * The hook emits at most one payload per run — run_stages returns on the
 * first message — so last-wins is exact, not an ordering heuristic. */
export function extractFollowup(stdout: string): string | null {
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

/**
 * Spawn the Ruby pipeline without awaiting it. omp caps extension handlers at
 * 30s (EXTENSION_HANDLER_TIMEOUT_MS, not configurable), far below what the
 * pipeline needs, so the caller returns immediately and consumes `done` later.
 * Payload is well under the pipe buffer, so writing stdin before draining
 * stdout cannot deadlock.
 */
export function startHookRun(rubyBin: string, hookPath: string, payload: unknown): HookRun {
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
	return {
		kill: killProc,
		done: Promise.all([
			new Response(proc.stdout).text(),
			new Response(proc.stderr).text(),
			stdinDone,
		]).then(async ([stdout, stderr]) => {
			await proc.exited;
			clearTimeout(timer);
			return { stdout, stderr, timedOut, exitCode: proc.exitCode };
		}),
	};
}

/** Toolchain preference: QUALITY_RUBY env, rbenv shim, Homebrew (macOS/Linux), system. */
export function resolveRuby(): string {
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
