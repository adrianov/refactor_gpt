/**
 * omp extension: quality stop pipeline (adapter over the Cursor Ruby hook).
 *
 * Fires on session_stop, converts the session branch into a Cursor-style
 * transcript (see quality/transcript.ts), spawns hooks/quality.rb in the
 * background (quality/hook-run.ts), and delivers its followup_message as a
 * follow-up user message.
 *
 * Layout note: conversion and process-running live in quality/ submodules;
 * this entry file only wires omp events. It must stay at extensions/*.ts for
 * auto-discovery.
 */
import { existsSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

import {
	extractFollowup,
	resolveRuby,
	startHookRun,
	type HookRun,
	type ScanOutcome,
} from "./quality/hook-run";
import {
	convertBranchToTranscript,
	lastAssistantAborted,
	type TranscriptMessage,
} from "./quality/transcript";

const DEFAULT_HOOK_RB = join(homedir(), "ruby/refactor_gpt/hooks/quality.rb");

/** Structural slice of the omp stop-handler context this extension touches. */
interface StopCtx {
	cwd: string;
	ui: { setStatus(name: string, value: string): void };
	sessionManager: {
		getBranch(): unknown[];
		getSessionId(): string;
	};
}

/** One scan at a time per extension instance. */
interface RunState {
	active: HookRun | null;
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

function setQualityStatus(ctx: StopCtx, value: string): void {
	try {
		ctx.ui.setStatus("quality", value);
	} catch {
		/* headless / session may be gone */
	}
}

/** QUALITY_HOOK_RB override, else the canonical hook location when present. */
function resolveHookPath(): string | null {
	const fromEnv = process.env.QUALITY_HOOK_RB?.trim();
	if (fromEnv && fromEnv.length > 0) return fromEnv;
	return existsSync(DEFAULT_HOOK_RB) ? DEFAULT_HOOK_RB : null;
}

/** Persist the converted branch next to nothing else in tmp. */
async function writeTranscript(
	sessionId: string,
	transcript: TranscriptMessage[],
): Promise<string> {
	const path = join(tmpdir(), `quality-omp-${sessionId}.jsonl`);
	await Bun.write(path, transcript.map((m) => JSON.stringify(m)).join("\n") + "\n");
	return path;
}

function buildPayload(
	sessionId: string,
	transcriptPath: string,
	cwd: string,
	chained: boolean,
): Record<string, unknown> {
	return {
		status: "completed",
		conversation_id: sessionId,
		transcript_path: transcriptPath,
		workspace_roots: [cwd],
		loop_count: chained ? 1 : 0,
	};
}

/// Consume a finished run: clear state/status, then relay the followup.
async function settleRun(
	pi: ExtensionAPI,
	ctx: StopCtx,
	state: RunState,
	run: HookRun,
	outcome: ScanOutcome,
): Promise<void> {
	if (state.active === run) state.active = null;
	setQualityStatus(ctx, "");
	if (outcome.timedOut) {
		logExtension(pi, "pipeline timed out; dropping results");
		return;
	}
	const followup = extractFollowup(outcome.stdout);
	logExtension(pi, `pipeline finished: exit=${outcome.exitCode} stderr=${outcome.stderr.length}b followup=${followup ? "yes" : "no"}`);
	if (outcome.stderr.trim()) logExtension(pi, outcome.stderr.trim());
	if (!followup) return;
	logExtension(pi, `followup: ${followup.slice(0, 120)}`);
	await pi.sendUserMessage(followup, { deliverAs: "followUp" });
}

/// Spawn the pipeline for this stop and wire its settlement callbacks.
async function beginStop(
	pi: ExtensionAPI,
	ctx: StopCtx,
	state: RunState,
	hookPath: string,
	entries: unknown[],
	chained: boolean,
): Promise<void> {
	const sessionId = ctx.sessionManager.getSessionId();
	const transcriptPath = await writeTranscript(
		sessionId,
		convertBranchToTranscript(entries, ctx.cwd),
	);
	logExtension(pi, `session ${sessionId}: chain=${chained} (background)`);
	setQualityStatus(ctx, "running");

	const run = startHookRun(
		resolveRuby(),
		hookPath,
		buildPayload(sessionId, transcriptPath, ctx.cwd, chained),
	);
	state.active = run;

	void run.done.then(
		(outcome) => settleRun(pi, ctx, state, run, outcome),
		(error) => {
			if (state.active === run) state.active = null;
			logExtension(pi, `pipeline crashed: ${error instanceof Error ? error.message : String(error)}`);
		},
	);
}

export default function qualityExtension(pi: ExtensionAPI): void {
	const state: RunState = { active: null };

	pi.on("session_shutdown", () => {
		if (state.active) logExtension(pi, "session shutdown: killing running pipeline");
		state.active?.kill();
		state.active = null;
	});

	// One scan per extension instance: overlapping stops are dropped until
	// the running pipeline settles.
	pi.on("session_stop", async (event, ctx) => {
		const stopCtx = ctx as StopCtx;
		const hookPath = resolveHookPath();
		if (!hookPath) return undefined;

		const entries = stopCtx.sessionManager.getBranch() as unknown[];
		if (entries.length === 0 || lastAssistantAborted(entries)) return undefined;
		if (state.active) {
			logExtension(pi, "previous pipeline still running; skipping this stop");
			return undefined;
		}

		const chained = "stop_hook_active" in event && event.stop_hook_active === true;
		await beginStop(pi, stopCtx, state, hookPath, entries, chained);
		return undefined; // settle immediately; results arrive as a follow-up message
	});
}
