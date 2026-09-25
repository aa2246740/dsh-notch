import Schema from "@deepseek-ai/schemastery";
import { createWriteStream, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { randomBytes, randomUUID } from "node:crypto";
import { resolveDshHome } from "@deepseek-ai/dsh-home-paths";
//#region desktop/notch-lifecycle.mjs
/** PID alone is not ownership: require both executable and process start time. */
function processIdentity(pid) {
	if (!Number.isSafeInteger(pid) || pid <= 1) return { state: "dead" };
	try {
		const text = execFileSync("/bin/ps", [
			"-p",
			String(pid),
			"-o",
			"lstart=",
			"-o",
			"comm="
		], {
			encoding: "utf8",
			env: {
				...process.env,
				LC_ALL: "C"
			},
			timeout: 1e3
		}).trim();
		const match = /^(.{24})\s+(.+)$/.exec(text);
		if (match) return {
			state: "alive",
			stamp: match[1],
			command: match[2]
		};
	} catch {}
	try {
		process.kill(pid, 0);
	} catch (error) {
		if (error.code === "ESRCH") return { state: "dead" };
	}
	return { state: "unknown" };
}
function processLiveness(pid) {
	if (!Number.isSafeInteger(pid) || pid <= 1) return "dead";
	try {
		process.kill(pid, 0);
		return "alive";
	} catch (error) {
		return error.code === "ESRCH" ? "dead" : "unknown";
	}
}
/** The desktop owns an adopted helper too. If it exits during adoption, retry. */
function superviseNotch({ bin, pidPath, log, interval = 250, env = process.env, probe = processIdentity, alive = processLiveness, launch = spawn, signal = process.kill.bind(process) }) {
	let current, pending, timer, stopped = false;
	const starts = [];
	const note = (text) => log.write(`[notch] ${text}\n`);
	const storedPID = () => {
		try {
			return Number(readFileSync(pidPath, "utf8").trim());
		} catch {
			return 0;
		}
	};
	const owned = (pid) => {
		const identity = probe(pid);
		return identity.state === "alive" && resolve(identity.command) === resolve(bin) ? {
			pid,
			...identity,
			checkedAt: Date.now()
		} : void 0;
	};
	const schedule = () => {
		clearTimeout(timer);
		if (!stopped) {
			timer = setTimeout(reconcile, interval);
			timer.unref?.();
		}
	};
	function reconcile() {
		if (stopped) return;
		if (pending) {
			schedule();
			return;
		}
		try {
			if (Date.now() - statSync(`${pidPath}.updating`).mtimeMs < 6e4) {
				schedule();
				return;
			}
		} catch {}
		if (current) {
			const state = alive(current.pid);
			if (state === "unknown" || state === "alive" && Date.now() - current.checkedAt < 5e3) {
				schedule();
				return;
			}
			const live = probe(current.pid);
			if (live.state === "unknown" || live.state === "alive" && live.stamp === current.stamp && live.command === current.command) {
				current.checkedAt = Date.now();
				schedule();
				return;
			}
			current = void 0;
		}
		const pid = storedPID();
		if (probe(pid).state === "unknown") {
			schedule();
			return;
		}
		current = owned(pid);
		if (current) {
			note(`adopt ${current.pid}`);
			schedule();
			return;
		}
		while (starts.length && Date.now() - starts[0] > 1e4) starts.shift();
		if (starts.length >= 3) {
			note("helper repeatedly exited; retry paused");
			stopped = true;
			return;
		}
		starts.push(Date.now());
		const child = launch(bin, [], {
			stdio: [
				"ignore",
				"pipe",
				"pipe"
			],
			detached: false,
			env
		});
		pending = child;
		child.stdout?.pipe(log, { end: false });
		child.stderr?.pipe(log, { end: false });
		child.once("spawn", () => {
			if (pending !== child) return;
			pending = void 0;
			if (stopped) {
				child.kill("SIGTERM");
				return;
			}
			current = owned(child.pid);
			if (!current) {
				child.kill("SIGTERM");
				schedule();
				return;
			}
			mkdirSync(dirname(pidPath), { recursive: true });
			const stage = `${pidPath}.${process.pid}.tmp`;
			writeFileSync(stage, `${child.pid}\n`);
			renameSync(stage, pidPath);
			note(`spawn ${child.pid}`);
			schedule();
		});
		child.once("error", (error) => {
			if (pending === child) pending = void 0;
			note(`spawn error: ${error.message}`);
			schedule();
		});
		child.once("exit", () => {
			if (pending === child) pending = void 0;
			if (current?.pid === child.pid) current = void 0;
			schedule();
		});
		schedule();
	}
	const stop = () => {
		stopped = true;
		clearTimeout(timer);
		pending?.kill("SIGTERM");
		const candidates = [current, owned(storedPID())].filter(Boolean);
		const seen = /* @__PURE__ */ new Set();
		for (const item of candidates) {
			if (seen.has(item.pid)) continue;
			seen.add(item.pid);
			const live = owned(item.pid);
			if (!live || live.stamp !== item.stamp) continue;
			try {
				signal(item.pid, "SIGTERM");
				note(`stop ${item.pid}`);
			} catch (error) {
				if (error.code !== "ESRCH") note(`stop failed: ${error.message}`);
			}
			if (storedPID() === item.pid) try {
				unlinkSync(pidPath);
			} catch {}
		}
		current = void 0;
	};
	reconcile();
	return {
		get pid() {
			return current?.pid ?? pending?.pid;
		},
		stop,
		kill: stop
	};
}
//#endregion
//#region src/session-state.ts
const FAILED = /* @__PURE__ */ new Set([
	"error",
	"blocked",
	"max-tokens"
]);
function foldSession(session) {
	let busy = false;
	let lastTurn;
	for (const event of session.snapshotEvents()) {
		if (event.type === "turn/start") {
			busy = true;
			lastTurn = void 0;
			continue;
		}
		if (event.type === "turn/end") {
			busy = false;
			const kind = event.data.reason.kind;
			lastTurn = {
				at: event.time,
				kind,
				failed: FAILED.has(kind)
			};
		}
	}
	return {
		busy,
		lastTurn
	};
}
function isChildSession(session) {
	return session.header.origin === "subagent";
}
/** Follow only delegation edges; user forks remain separate conversations. */
function conversationOwner(session, sessions) {
	let current = session;
	const visited = /* @__PURE__ */ new Set();
	while (current && isChildSession(current)) {
		if (visited.has(current.id)) return void 0;
		visited.add(current.id);
		current = current.header.parentSession === void 0 ? void 0 : sessions.get(current.header.parentSession);
	}
	return current;
}
//#endregion
//#region src/store.ts
const DIR = join(resolveDshHome(), "dsh-notch");
const RUNTIME = join(DIR, "runtime.json");
const SEEN = join(DIR, "seen.json");
function ensureDir() {
	mkdirSync(DIR, {
		recursive: true,
		mode: 448
	});
}
function readJson(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return;
	}
}
function loadOrCreateToken() {
	const existing = readJson(RUNTIME);
	if (existing?.token && existing.token.length >= 16) return existing.token;
	return randomBytes(24).toString("hex");
}
function writeRuntime(file) {
	ensureDir();
	writeFileSync(RUNTIME, `${JSON.stringify(file, null, 2)}\n`, {
		encoding: "utf8",
		mode: 384
	});
}
function loadSeen() {
	const value = readJson(SEEN);
	if (!value || typeof value !== "object") return {};
	return value;
}
function saveSeen(map) {
	ensureDir();
	writeFileSync(SEEN, `${JSON.stringify(map)}\n`, {
		encoding: "utf8",
		mode: 384
	});
}
//#endregion
//#region src/board.ts
var Board = class {
	ctx;
	sidebar;
	instance = randomUUID();
	traces = [];
	lastMirrorTrace = "";
	lastRowTrace = "";
	/** Bounded, content-free diagnostics for state-source races. */
	diagnostics() {
		return {
			stateRevision: 4,
			instance: this.instance,
			sidebar: this.sidebar && {
				clientId: this.sidebar.clientId,
				at: this.sidebar.at,
				focused: this.sidebar.focused
			},
			traces: this.traces
		};
	}
	trace(event, value) {
		this.traces.push({
			at: Date.now(),
			event,
			...value
		});
		if (this.traces.length > 160) this.traces.shift();
	}
	syncSidebar(input) {
		if (!input || typeof input !== "object") return false;
		const data = input;
		if (typeof data.clientId !== "string" || !Array.isArray(data.rows) || data.rows.length > 1e3) return false;
		const rows = [];
		for (const row of data.rows) {
			if (!row || typeof row.id !== "string" || !row.id.startsWith("session-") || typeof row.title !== "string" || typeof row.completed !== "boolean" || typeof row.running !== "boolean") return false;
			rows.push({
				id: row.id,
				title: row.title.slice(0, 512),
				completed: row.completed,
				running: row.running,
				...typeof row.updatedAt === "number" && Number.isFinite(row.updatedAt) ? { updatedAt: row.updatedAt } : {}
			});
		}
		const sessions = new Map(this.ctx.sessions.list().map((session) => [session.id, session]));
		for (const row of rows) {
			if (!row.completed || row.running) continue;
			const session = sessions.get(row.id);
			if (session && (isChildSession(session) || this.isBusy(session))) continue;
			const turn = session ? foldSession(session).lastTurn : void 0;
			const seen = this.seen[row.id];
			const completedAt = turn?.at ?? row.updatedAt;
			if (seen !== void 0 && (completedAt === void 0 || seen >= completedAt)) continue;
			this.browserCompletions.set(row.id, row);
		}
		const viewed = data.viewed;
		if (data.projectionVersion === 3 && data.focused === true && viewed && typeof viewed.id === "string" && typeof viewed.at === "number" && Number.isFinite(viewed.at) && rows.some((row) => row.id === viewed.id && !row.running)) {
			const session = sessions.get(viewed.id);
			if (!session || !isChildSession(session) && !this.conversationBusy(session, sessions)) this.readThrough(viewed.id, Math.min(viewed.at, Date.now()));
		}
		if (data.projectionVersion !== 3 && data.focused === true && this.sidebar?.clientId === data.clientId) for (const previous of this.sidebar.rows) {
			if (!previous.completed || rows.some((row) => row.id === previous.id && row.completed)) continue;
			const session = sessions.get(previous.id);
			const at = session ? foldSession(session).lastTurn?.at : Date.now();
			if (at !== void 0 && (!session || !this.conversationBusy(session, sessions))) this.readThrough(previous.id, at);
		}
		if (this.sidebar && this.sidebar.clientId !== data.clientId && data.focused !== true && Date.now() - this.sidebar.at < 5e3) {
			this.bump();
			return true;
		}
		this.sidebar = {
			clientId: data.clientId,
			at: Date.now(),
			focused: data.focused === true,
			rows,
			...data.projectionVersion === 2 || data.projectionVersion === 3 ? { projectionVersion: data.projectionVersion } : {}
		};
		const mirrorTrace = {
			clientId: data.clientId,
			focused: data.focused === true,
			rows: rows.map(({ id, running, completed }) => ({
				id,
				running,
				completed
			}))
		};
		const signature = JSON.stringify(mirrorTrace);
		if (signature !== this.lastMirrorTrace) {
			this.lastMirrorTrace = signature;
			this.trace("sidebar", mirrorTrace);
		}
		this.bump();
		return true;
	}
	sidebarRows() {
		return this.sidebar && Date.now() - this.sidebar.at < 5e3 ? this.sidebar.rows : void 0;
	}
	pending = /* @__PURE__ */ new Map();
	seen = loadSeen();
	running = /* @__PURE__ */ new Set();
	pendingUnread = /* @__PURE__ */ new Set();
	browserCompletions = /* @__PURE__ */ new Map();
	listeners = /* @__PURE__ */ new Set();
	focus = null;
	constructor(ctx) {
		this.ctx = ctx;
	}
	onChange(fn) {
		this.listeners.add(fn);
		return () => {
			this.listeners.delete(fn);
		};
	}
	notify() {
		this.bump();
	}
	bump() {
		for (const fn of this.listeners) try {
			fn();
		} catch (error) {
			this.ctx.logger.warn("dsh-notch: subscriber failed: %s", String(error));
		}
	}
	snapshot(origin) {
		const rows = [];
		const sessions = this.ctx.sessions.list();
		const byId = new Map(sessions.map((session) => [session.id, session]));
		const groups = /* @__PURE__ */ new Map();
		for (const session of sessions) {
			const owner = conversationOwner(session, byId);
			if (!owner) {
				const ids = /* @__PURE__ */ new Set([session.id]);
				const approval = this.heldApproval(ids);
				const ask = this.heldAsk(ids);
				if (approval || ask) rows.push({
					id: session.id,
					title: this.titleOf(session),
					child: true,
					busy: false,
					unread: false,
					...approval ? { approval } : {},
					...ask ? { ask } : {}
				});
				continue;
			}
			const members = groups.get(owner) ?? [];
			members.push(session);
			groups.set(owner, members);
		}
		for (const [owner, members] of groups) {
			const row = this.rowFor(owner, members);
			if (row) rows.push(row);
		}
		const freshSidebar = this.sidebarRows();
		const coldRows = new Map(this.browserCompletions);
		for (const source of freshSidebar ?? []) if (source.running) coldRows.set(source.id, source);
		for (const source of coldRows.values()) {
			if (byId.has(source.id) || !source.completed && !source.running) continue;
			if (source.running && !freshSidebar) continue;
			const seen = this.seen[source.id];
			if (source.completed && seen !== void 0 && (source.updatedAt === void 0 || seen >= source.updatedAt)) continue;
			rows.push({
				id: source.id,
				title: source.title,
				child: false,
				busy: source.running,
				unread: source.completed
			});
		}
		rows.sort((a, b) => Number(Boolean(b.approval || b.ask)) - Number(Boolean(a.approval || a.ask)) || Number(b.busy) - Number(a.busy) || Number(b.unread) - Number(a.unread) || (b.lastTurn?.at ?? 0) - (a.lastTurn?.at ?? 0));
		this.running = new Set(sessions.filter((session) => this.isBusy(session)).map((session) => session.id));
		const stateRows = rows.map((row) => ({
			id: row.id,
			busy: row.busy,
			unread: row.unread,
			turnAt: row.lastTurn?.at,
			action: Boolean(row.ask || row.approval)
		}));
		const rowSignature = JSON.stringify(stateRows);
		if (rowSignature !== this.lastRowTrace) {
			this.lastRowTrace = rowSignature;
			this.trace("snapshot", {
				rows: stateRows,
				clientId: this.sidebar?.clientId,
				mirrorAt: this.sidebar?.at,
				running: [...this.running],
				pendingUnread: [...this.pendingUnread]
			});
		}
		return {
			ok: true,
			stateRevision: 4,
			generatedAt: Date.now(),
			origin,
			rows,
			sidebarSyncedAt: freshSidebar ? this.sidebar?.at : void 0,
			sidebarProjectionVersion: freshSidebar ? this.sidebar?.projectionVersion : void 0
		};
	}
	markSeen(sessionId) {
		this.pendingUnread.delete(sessionId);
		this.browserCompletions.delete(sessionId);
		this.seen[sessionId] = Date.now();
		saveSeen(this.seen);
		this.bump();
	}
	markAllSeen() {
		this.pendingUnread.clear();
		const now = Date.now();
		for (const id of this.browserCompletions.keys()) this.seen[id] = now;
		this.browserCompletions.clear();
		for (const session of this.ctx.sessions.list()) this.seen[session.id] = now;
		saveSeen(this.seen);
		this.bump();
	}
	readThrough(sessionId, at) {
		const seen = this.seen[sessionId];
		if ((seen ?? -Infinity) >= at) return;
		const session = this.ctx.sessions.list().find((item) => item.id === sessionId);
		const completedAt = (session && foldSession(session).lastTurn)?.at ?? this.browserCompletions.get(sessionId)?.updatedAt;
		if (seen !== void 0 && (completedAt === void 0 || seen >= completedAt)) return;
		this.seen[sessionId] = at;
		if (completedAt === void 0 || completedAt <= at) {
			this.pendingUnread.delete(sessionId);
			this.browserCompletions.delete(sessionId);
		}
		saveSeen(this.seen);
		this.trace("read", {
			sessionId,
			through: at
		});
	}
	noteTurnEnd(session, at = foldSession(session).lastTurn?.at) {
		if (isChildSession(session)) return;
		if (at !== void 0 && (this.seen[session.id] ?? -Infinity) < at) this.pendingUnread.add(session.id);
	}
	/**
	* Record a "show this session in a DSH UI" wish from the native helper.
	* Returns false for unknown sessions. The wish expires after 60s; every
	* open DSH page consumes it idempotently, so no per-client cursor is kept.
	*/
	requestFocus(sessionId) {
		const known = this.ctx.sessions.list().some((session) => session.id === sessionId);
		const mirrored = this.browserCompletions.has(sessionId) || this.sidebarRows()?.some((row) => row.id === sessionId);
		if (!known && !mirrored) return false;
		this.focus = {
			sessionId,
			at: Date.now()
		};
		this.bump();
		return true;
	}
	peekFocus() {
		if (this.focus === null) return null;
		if (Date.now() - this.focus.at > 6e4) {
			this.focus = null;
			return null;
		}
		return this.focus;
	}
	decideApproval(id, outcome) {
		const held = this.pending.get(id);
		if (!held || held.kind !== "approval") return false;
		this.pending.delete(id);
		this.seen[held.sessionId] = Date.now();
		saveSeen(this.seen);
		held.resolve(outcome);
		this.bump();
		return true;
	}
	answerAsk(id, answers) {
		const held = this.pending.get(id);
		if (!held || held.kind !== "ask") return false;
		this.pending.delete(id);
		this.seen[held.sessionId] = Date.now();
		saveSeen(this.seen);
		held.resolve({ answers });
		this.bump();
		return true;
	}
	holdApproval(request, next) {
		const sessionId = String(request.agent.id);
		const id = randomUUID();
		const fromNotch = new Promise((resolve) => {
			const held = {
				kind: "approval",
				id,
				sessionId,
				toolName: request.toolName,
				resolve
			};
			if (request.reason) held.reason = request.reason;
			this.pending.set(id, held);
			this.bump();
			request.signal?.addEventListener("abort", () => {
				if (!this.pending.delete(id)) return;
				this.bump();
			}, { once: true });
		});
		return Promise.race([fromNotch, next()]).finally(() => {
			if (this.pending.delete(id)) this.bump();
		});
	}
	holdAsk(request, next) {
		const sessionId = request.agent ? String(request.agent.id) : "";
		if (!sessionId) return next();
		const originalSignal = request.signal;
		const downstream = new AbortController();
		request.signal = originalSignal ? AbortSignal.any([originalSignal, downstream.signal]) : downstream.signal;
		const id = randomUUID();
		const questions = request.questions.map((item) => ({
			id: item.id,
			question: item.question,
			...item.detail === void 0 ? {} : { detail: item.detail },
			...item.header === void 0 ? {} : { header: item.header },
			...item.options === void 0 ? {} : { options: item.options },
			...item.multiSelect === void 0 ? {} : { multiSelect: item.multiSelect },
			...item.intent === void 0 ? {} : { intent: item.intent }
		}));
		const fromNotch = new Promise((resolve) => {
			this.pending.set(id, {
				kind: "ask",
				id,
				sessionId,
				questions,
				resolve
			});
			this.bump();
			request.signal?.addEventListener("abort", () => {
				if (!this.pending.delete(id)) return;
				this.bump();
			}, { once: true });
		});
		return Promise.race([fromNotch, Promise.resolve().then(next)]).finally(() => {
			downstream.abort(/* @__PURE__ */ new Error("Question settled through another answerer"));
			if (originalSignal === void 0) delete request.signal;
			else request.signal = originalSignal;
			if (this.pending.delete(id)) this.bump();
		});
	}
	isBusy(session) {
		return this.ctx.agents.get(session.id)?.status === "running";
	}
	conversationBusy(owner, sessions) {
		for (const member of sessions.values()) if (conversationOwner(member, sessions)?.id === owner.id && (this.isBusy(member) || this.hasSubagentJob(member))) return true;
		return false;
	}
	hasSubagentJob(session) {
		const agent = this.ctx.agents.get(session.id);
		if (!agent) return false;
		return this.ctx.get("jobs")?.list(agent.id).some((job) => job.owner === session.id && job.kind === "subagent" && (job.status === "running" || job.status === "stopping")) ?? false;
	}
	rowFor(session, members) {
		const folded = foldSession(session);
		const child = isChildSession(session);
		const lastSeen = this.seen[session.id];
		const busy = members.some((member) => this.isBusy(member) || this.hasSubagentJob(member));
		if (folded.busy) this.pendingUnread.delete(session.id);
		else if (this.running.has(session.id) && folded.lastTurn) this.pendingUnread.add(session.id);
		const unread = !(lastSeen !== void 0 && (folded.lastTurn === void 0 || lastSeen >= folded.lastTurn.at)) && !busy && (this.pendingUnread.has(session.id) || this.browserCompletions.has(session.id));
		const memberIds = new Set(members.map((member) => member.id));
		const approval = this.heldApproval(memberIds);
		const ask = this.heldAsk(memberIds);
		if (!busy && !unread && !approval && !ask) return void 0;
		const title = this.titleOf(session);
		const row = {
			id: session.id,
			title,
			child,
			busy,
			unread
		};
		if (folded.lastTurn && !busy) row.lastTurn = folded.lastTurn;
		if (approval) row.approval = approval;
		if (ask) row.ask = ask;
		return row;
	}
	heldApproval(sessionIds) {
		for (const held of this.pending.values()) if (held.kind === "approval" && sessionIds.has(held.sessionId)) return {
			id: held.id,
			toolName: held.toolName,
			...held.reason === void 0 ? {} : { reason: held.reason }
		};
	}
	heldAsk(sessionIds) {
		for (const held of this.pending.values()) if (held.kind === "ask" && sessionIds.has(held.sessionId)) return {
			id: held.id,
			questions: held.questions
		};
	}
	titleOf(session) {
		const title = this.ctx.get("sessionTitle")?.get(session)?.title?.trim();
		if (title) return title;
		return session.id.slice(0, 8);
	}
};
//#endregion
//#region src/http.ts
const PREFIX = "/dsh-notch";
function isLoopback(req) {
	const ip = req.socket.remoteAddress ?? "";
	return ip === "127.0.0.1" || ip === "::1" || ip === ":ffff:127.0.0.1" || ip === "::ffff:127.0.0.1";
}
function authorized(req, token) {
	if (req.headers.authorization === `Bearer ${token}`) return true;
	try {
		return new URL(req.url ?? "/", "http://127.0.0.1").searchParams.get("token") === token;
	} catch {
		return false;
	}
}
/**
* Browser-side trust for pages served by this same Host: loopback remote,
* never cross-site, and a matching Origin when one is present. Same rule the
* shipped workspace file panel uses — no secret ever lands in page JS.
*/
function browserTrusted(req) {
	if (!isLoopback(req)) return false;
	if (req.headers["sec-fetch-site"] === "cross-site") return false;
	const host = req.headers.host;
	if (host === void 0) return false;
	const origin = req.headers.origin;
	if (origin === void 0) return true;
	try {
		return new URL(origin).host === new URL(`http://${host}`).host;
	} catch {
		return false;
	}
}
function send(res, status, body) {
	const json = JSON.stringify(body);
	res.writeHead(status, {
		"content-type": "application/json; charset=utf-8",
		"cache-control": "no-store"
	});
	res.end(json);
}
function readBody(req, limit = 64 * 1024) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		let size = 0;
		req.on("data", (chunk) => {
			size += chunk.length;
			if (size > limit) {
				reject(/* @__PURE__ */ new Error("body too large"));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
		req.on("error", reject);
	});
}
function attachHttp(ctx, board, token, origin) {
	const streams = /* @__PURE__ */ new Map();
	const push = () => {
		const payload = `data: ${JSON.stringify(board.snapshot(origin))}\n\n`;
		for (const [id, res] of streams) try {
			res.write(payload);
		} catch {
			streams.delete(id);
		}
	};
	const stopListen = board.onChange(push);
	const handler = async (req, res) => {
		const path = new URL(req.url ?? "/", "http://127.0.0.1").pathname;
		const method = req.method ?? "GET";
		if (method === "GET" && path === `${PREFIX}/pending-focus`) {
			if (!browserTrusted(req)) {
				send(res, 403, {
					ok: false,
					error: "forbidden"
				});
				return;
			}
			send(res, 200, {
				ok: true,
				focus: board.peekFocus()
			});
			return;
		}
		if (method === "POST" && path === `${PREFIX}/sidebar`) {
			if (!browserTrusted(req) || !req.headers.origin || !req.headers["content-type"]?.startsWith("application/json")) {
				send(res, 403, {
					ok: false,
					error: "forbidden"
				});
				return;
			}
			const ok = board.syncSidebar(JSON.parse(await readBody(req, 512 * 1024)));
			send(res, ok ? 200 : 400, { ok });
			return;
		}
		if (!isLoopback(req) || !authorized(req, token)) {
			send(res, 403, {
				ok: false,
				error: "forbidden"
			});
			return;
		}
		if (method === "GET" && path === `${PREFIX}/status`) {
			send(res, 200, board.snapshot(origin));
			return;
		}
		if (method === "GET" && path === `${PREFIX}/diagnostics`) {
			send(res, 200, board.diagnostics());
			return;
		}
		if (method === "GET" && path === `${PREFIX}/events`) {
			const id = randomUUID();
			res.writeHead(200, {
				"content-type": "text/event-stream",
				"cache-control": "no-cache",
				connection: "keep-alive"
			});
			streams.set(id, res);
			res.write(`data: ${JSON.stringify(board.snapshot(origin))}\n\n`);
			req.on("close", () => {
				streams.delete(id);
			});
			return;
		}
		if (method === "POST" && path === `${PREFIX}/seen`) {
			const body = JSON.parse(await readBody(req));
			if (body.all) {
				board.markAllSeen();
				send(res, 200, { ok: true });
				return;
			}
			if (!body.sessionId) {
				send(res, 400, {
					ok: false,
					error: "sessionId required"
				});
				return;
			}
			board.markSeen(body.sessionId);
			send(res, 200, { ok: true });
			return;
		}
		if (method === "POST" && path === `${PREFIX}/approve`) {
			const body = JSON.parse(await readBody(req));
			if (!body.id || body.outcome !== "allowed-once" && body.outcome !== "rejected") {
				send(res, 400, {
					ok: false,
					error: "id and outcome required"
				});
				return;
			}
			if (!board.decideApproval(body.id, body.outcome)) {
				send(res, 404, {
					ok: false,
					error: "not pending"
				});
				return;
			}
			send(res, 200, { ok: true });
			return;
		}
		if (method === "POST" && path === `${PREFIX}/answer`) {
			const body = JSON.parse(await readBody(req));
			if (!body.id || !Array.isArray(body.answers)) {
				send(res, 400, {
					ok: false,
					error: "id and answers required"
				});
				return;
			}
			if (!board.answerAsk(body.id, body.answers)) {
				send(res, 404, {
					ok: false,
					error: "not pending"
				});
				return;
			}
			send(res, 200, { ok: true });
			return;
		}
		if (method === "POST" && path === `${PREFIX}/focus`) {
			const body = JSON.parse(await readBody(req));
			if (!body.sessionId) {
				send(res, 400, {
					ok: false,
					error: "sessionId required"
				});
				return;
			}
			if (!board.requestFocus(body.sessionId)) {
				send(res, 404, {
					ok: false,
					error: "unknown session"
				});
				return;
			}
			send(res, 200, { ok: true });
			return;
		}
		send(res, 404, {
			ok: false,
			error: "not found"
		});
	};
	const disposeRoute = ctx.webServer.register({
		kind: "prefix",
		path: PREFIX,
		handler: (req, res) => {
			handler(req, res).catch((error) => {
				if (!res.headersSent) send(res, 400, {
					ok: false,
					error: String(error)
				});
			});
		}
	});
	return () => {
		stopListen();
		for (const res of streams.values()) try {
			res.end();
		} catch {}
		streams.clear();
		disposeRoute();
	};
}
//#endregion
//#region src/dsh-notch.ts
const name = "dsh-notch";
const inject = [
	"sessions",
	"webServer",
	"approval",
	"userQuestions",
	"agents"
];
const Config = Schema.object({ helperPath: Schema.string().default("").description("Optional installed native Notch executable; managed for this Host lifetime.") });
function apply(ctx, config = {}) {
	console.log("[my-plugins/dsh-notch] loaded");
	const board = new Board(ctx);
	const token = loadOrCreateToken();
	const origin = `http://${ctx.webServer.host}:${String(ctx.webServer.port)}`;
	writeRuntime({
		origin,
		token,
		pid: process.pid,
		writtenAt: Date.now()
	});
	if (config.helperPath) {
		if (!existsSync(config.helperPath)) throw new Error("Configured Notch helper does not exist");
		ctx.effect(() => {
			const log = createWriteStream(join(DIR, "helper.log"), {
				flags: "a",
				mode: 384
			});
			const helper = superviseNotch({
				bin: config.helperPath,
				pidPath: join(DIR, "helper.pid"),
				log,
				env: {
					...process.env,
					DSH_NOTCH_RUNTIME_FILE: RUNTIME
				}
			});
			return () => {
				helper.stop();
				log.end();
			};
		}, "dsh-notch: native helper");
	}
	ctx.effect(() => attachHttp(ctx, board, token, origin), "dsh-notch: http");
	const notify = debounce(() => board.notify(), 80);
	ctx.effect(() => notify.dispose, "dsh-notch: notification timer");
	ctx.effect(() => ctx.on("session/created", notify), "dsh-notch: created");
	ctx.effect(() => ctx.on("session/disposed", notify), "dsh-notch: disposed");
	ctx.effect(() => ctx.on("session/event", (session, event) => {
		const type = String(event.type);
		if (type === "turn/end") board.noteTurnEnd(session, event.time);
		if (type === "turn/start" || type === "turn/end" || type === "session/title") notify();
		if (type === "turn/start" || type === "user/message" && event.data?.source === "user") board.markSeen(session.id);
	}), "dsh-notch: events");
	ctx.effect(() => ctx.on("agent/status", notify), "dsh-notch: agent-status");
	ctx.on("user-questions/request", (request, next) => board.holdAsk(request, next), { prepend: true });
}
function debounce(fn, ms) {
	let timer;
	const notify = () => {
		if (timer) clearTimeout(timer);
		timer = setTimeout(() => {
			timer = void 0;
			fn();
		}, ms);
	};
	return Object.assign(notify, { dispose: () => {
		if (timer) clearTimeout(timer);
		timer = void 0;
	} });
}
//#endregion
export { Config, apply, inject, name };

//# sourceMappingURL=index.mjs.map