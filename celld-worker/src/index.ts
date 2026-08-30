import { DurableObject } from "cloudflare:workers";

export interface Env {
	CHAT_ROOM: DurableObjectNamespace;
}

export default {
	async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/ws") {
			const id = env.CHAT_ROOM.idFromName("global-chat");
			const stub = env.CHAT_ROOM.get(id);
			return stub.fetch(request);
		}
		return new Response("Not found", { status: 404 });
	}
} satisfies ExportedHandler<Env>;

export class ChatRoom extends DurableObject {
	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);

		this.ctx.blockConcurrencyWhile(async () => {
			this.ctx.storage.sql.exec(`
				CREATE TABLE IF NOT EXISTS messages (
					id INTEGER PRIMARY KEY AUTOINCREMENT,
					content TEXT,
					author TEXT,
					timestamp TEXT
				)
			`);
		});
	}

	async fetch(request: Request): Promise<Response> {
		const upgradeHeader = request.headers.get("Upgrade");
		if (upgradeHeader !== "websocket") {
			return new Response("Expected Upgrade: websocket", { status: 426 });
		}

		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);

		this.ctx.acceptWebSocket(server);
		const cursor = this.ctx.storage.sql.exec(
			"SELECT content FROM messages ORDER BY id ASC LIMIT 30"
		);
		const history = [...cursor].map((row: any) => row.content);

		server.send(
			JSON.stringify(
				{ type: "history", messages: history }
			)
		);


		return new Response(null, {
			status: 101,
			webSocket: client,
		});
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
	   this.ctx.storage.sql.exec(
		   "INSERT INTO messages (content, author, timestamp) VALUES (?, ?, ?)",
		   message,
		   "unknown",
		   new Date().toISOString()
	   );

	   const msg = JSON.stringify(
		   {
			   type: "message",
			   content: message,
			   author: "unknown",
		   }
	   );
	   const msgAck = JSON.stringify(
		   {
			   type: "ack",
			   content: message,
		   }
	   );


	   const sockets = this.ctx.getWebSockets();
	   for (const socket of sockets) {
		   if (socket == ws) {
			   socket.send(msgAck);
			   continue;
		   }
		   socket.send(msg);
	   }
	}

	async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
		ws.close(code, reason);
	}
}
