export default {
	async fetch(request: Request, _env: Env, _ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/ws") {
			const upgradeHeader = request.headers.get("Upgrade");
			if (upgradeHeader !== "websocket") {
				return new Response("Expected Upgrade: websocket", { status: 426 });
			}

			const pair = new WebSocketPair();
			const [client, server] = Object.values(pair);

			server.accept();

			server.addEventListener("message", (event) => {
				server.send(`Echo: ${event.data}`);
			});

			return new Response(null, {
				status: 101,
				webSocket: client,
			});
		}

		return new Response("Not found", { status: 404 });
	},
} satisfies ExportedHandler<Env>;
