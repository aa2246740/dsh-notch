window.__ModuleLoader__.load({
	id: "dsh-notch",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		//#region src/client/index.ts
		const name = "dsh-notch-client";
		const inject = [
			"sessions",
			"uiWorkspace",
			"uiSession"
		];
		const POLL_MS = 400;
		function apply(ctx) {
			const sessions = ctx.get("sessions");
			const clientId = crypto.randomUUID();
			let lastAt = 0;
			let armed = false;
			let stopped = false;
			const controller = new AbortController();
			const open = async (sessionId) => {
				try {
					ctx.uiWorkspace.openSession(sessionId);
					return;
				} catch {}
				try {
					await sessions.refresh();
					if (stopped) return;
					ctx.uiWorkspace.openSession(sessionId);
				} catch {}
			};
			const poll = async () => {
				try {
					const snapshot = sessions.list.getSnapshot();
					if (snapshot.phase === "ready") {
						const rows = snapshot.ids.map((id) => snapshot.byId[id]).filter((row) => row && row.origin !== "subagent").map((row) => ({
							id: row.id,
							title: row.displayTitle,
							completed: ctx.uiSession.sessionStatus.getSnapshot().get(row.id)?.completionUnread === true,
							running: row.running,
							updatedAt: row.updatedAt
						}));
						const focused = document.hasFocus();
						const current = rows.find((row) => row.id === Object.values(snapshot.byId).find((item) => (item.retainedBy?.mainView ?? 0) > 0)?.id);
						const viewed = focused && current && !current.running ? {
							id: current.id,
							at: Date.now()
						} : void 0;
						await fetch("/dsh-notch/sidebar", {
							signal: controller.signal,
							method: "POST",
							headers: {
								"content-type": "application/json",
								"x-dsh-notch-client": "1"
							},
							body: JSON.stringify({
								clientId,
								projectionVersion: 3,
								focused,
								viewed,
								rows
							})
						});
					}
					if (stopped) return;
					const response = await fetch("/dsh-notch/pending-focus", {
						cache: "no-store",
						signal: controller.signal
					});
					if (!response.ok) return;
					const data = await response.json();
					if (stopped) return;
					const focus = data.focus;
					if (!armed) {
						armed = true;
						if (focus && typeof focus.at === "number") lastAt = focus.at;
						return;
					}
					if (!focus || typeof focus.at !== "number" || focus.at <= lastAt) return;
					if (typeof focus.sessionId !== "string" || focus.sessionId === "") return;
					lastAt = focus.at;
					await open(focus.sessionId);
					try {
						if (stopped) return;
						window.focus();
					} catch {}
				} catch {}
			};
			const tick = () => {
				if (stopped) return;
				poll().finally(() => {
					if (!stopped) timer = window.setTimeout(tick, POLL_MS);
				});
			};
			let timer;
			tick();
			ctx.effect(() => () => {
				stopped = true;
				if (timer !== void 0) window.clearTimeout(timer);
				controller.abort();
			}, "dsh-notch: client sync");
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		exports.name = name;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map