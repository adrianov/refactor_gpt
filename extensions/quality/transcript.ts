//! omp session branch → Cursor-style transcript conversion for the Ruby
//! quality hook: tool-name mapping, anchored-edit flattening, and message
//! shaping shared by the stop pipeline.

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
export interface TranscriptMessage {
	role: "user" | "assistant";
	message: { content: ContentItem[] };
}

function asObject(value: unknown): Record<string, unknown> | null {
	return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

function normalizeToolUse(name: string, rawInput: unknown, cwd: string): ToolUse {
	const raw = asObject(rawInput) ?? {};
	// The harness wraps some tools (edit) as { i, input: { …real params… } };
	// the Ruby hook reads path-ish keys from the top level, so flatten.
	const input: Record<string, unknown> = { ...raw, ...asObject(raw.input) };
	if ((TOOL_NAME_MAP[name] ?? name) === "Shell") {
		fillShellCwd(input, cwd);
	}
	return anchoredEditOrMapped(name, input);
}

/** Shell records carry the launch cwd so relative paths resolve later. */
function fillShellCwd(input: Record<string, unknown>, cwd: string): void {
	if (input.working_directory == null || input.working_directory === "") {
		input.working_directory =
			typeof input.cwd === "string" && input.cwd.length > 0 ? input.cwd : cwd;
	}
}

/**
 * The edit tool carries its changes as one anchored-edit string
 * ("[app/models/x.rb#A1B2] …"). Translate the section headers into the
 * Cursor patch markers the Ruby hook scans for file paths.
 */
function anchoredEditOrMapped(name: string, input: Record<string, unknown>): ToolUse {
	if (name !== "edit" || typeof input.input !== "string") {
		return { type: "tool_use", name: TOOL_NAME_MAP[name] ?? name, input };
	}
	const paths = [...input.input.matchAll(/^\[([^\]\n]+?)#[^\]\n]*\]/gm)].map((m) => m[1]);
	if (paths.length > 0) {
		return { type: "tool_use", name: "edit", input: paths.map((p) => `*** Update File: ${p}`).join("\n") };
	}
	return { type: "tool_use", name: TOOL_NAME_MAP[name] ?? name, input };
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
export function lastAssistantAborted(entries: ReadonlyArray<unknown>): boolean {
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

/** Loose object guard shared by transcript parsing and stdout decoding. */
export function asObject(value: unknown): Record<string, unknown> | null {
	return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}
