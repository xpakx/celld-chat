import { DurableObject } from "cloudflare:workers";

export interface Env {
	CHAT_ROOM: DurableObjectNamespace;
}

export default {
	async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);

		if (url.pathname === "/ws") {
			const roomName = url.searchParams.get("room") || "global-chat";
			const id = env.CHAT_ROOM.idFromName(roomName);
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

		const header = request.headers.get("Sec-WebSocket-Protocol");


		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);

		this.ctx.acceptWebSocket(server);


		const authorName = extractNameFromSubprotocols(header) ?? generateAnonymousName();

		server.serializeAttachment({ name: authorName });

		const cursor = this.ctx.storage.sql.exec(
			"SELECT content, author FROM messages ORDER BY id ASC LIMIT 30",
		);
		const history = [...cursor].map((row: any) => {return {author: row.author, content: row.content}});

		server.send(
			JSON.stringify({
				type: "history",
				messages: history,
				name: authorName,
			})
		);


		return new Response(null, {
			status: 101,
			webSocket: client,
		});
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
		const attachment = ws.deserializeAttachment() as { name: string } | null;
		const author = attachment?.name || "unknown";

	   this.ctx.storage.sql.exec(
		   "INSERT INTO messages (content, author, timestamp) VALUES (?, ?, ?)",
		   message,
		   author,
		   new Date().toISOString()
	   );

	   const msg = JSON.stringify(
		   {
			   type: "message",
			   content: message,
			   author: author,
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

const ADJECTIVES = ["anonymous", "curious", "secret", "mysterious", "hidden", "clever"];
const ANIMALS = ["capybara", "axolotl", "chinchilla", "dingo", "iguana", "quokka", "wombat", "llama", "narwhal", "platypus"];

function generateAnonymousName(): string {
	const adj = ADJECTIVES[Math.floor(Math.random() * ADJECTIVES.length)];
	const animal = ANIMALS[Math.floor(Math.random() * ANIMALS.length)];
	return `${adj} ${animal}`;
}

function extractNameFromSubprotocols(header: string | null): string | undefined {
	if (!header) return undefined;
	const protocols = header.split(",").map((p) => p.trim());
	const bearerProtocol = protocols.find((p) => p.startsWith("bearer."));
	return bearerProtocol ? bearerProtocol.replace("bearer.", "") : undefined;
}
