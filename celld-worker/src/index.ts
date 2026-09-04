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
					timestamp TEXT,
					verified BOOLEAN,
					fingerprint TEXT
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
			"SELECT content, author, verified, fingerprint FROM (SELECT id, content, author, verified, fingerprint FROM messages ORDER BY id DESC LIMIT 30) ORDER BY id ASC"
		);
		const history = [...cursor].map((row: any) => { return {
				author: row.author,
				content: row.content,
				verified: row.verified,
				fingerprint: row.fingerprint
		}});

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
		const attachment = ws.deserializeAttachment() as Attachments | null;
		const author = attachment?.name || "unknown";
		const data = JSON.parse(message as string);

		if (data.type == "register") {
			await this.register(ws, author, data);
		} else if (data.type == "message") {
			await this.processMsg(ws, attachment ?? {name: author}, data);
		}
	}

	async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
		ws.close(code, reason);
	}

	async processMsg(ws: WebSocket, data: Attachments, message: MessageReq) {
		const verified = await this.verifyMessage(message, data);
		const fingerprint = verified ? data.fingerprint : undefined;
		this.ctx.storage.sql.exec(
			"INSERT INTO messages (content, author, timestamp, verified, fingerprint) VALUES (?, ?, ?, ?, ?)",
			message.msg,
			data.name,
			new Date().toISOString(),
			verified,
			fingerprint
		);

		const msg = JSON.stringify(
			{
				type: "message",
				content: message.msg,
				author: data.name,
				verified: verified,
				fingerprint: fingerprint
			}
		);
		const msgAck = JSON.stringify(
			{
				type: "ack",
				content: message.msg,
				verified: verified,
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

	async register(ws: WebSocket, author: string, message: RegisterReq) {
		const pubString = JSON.stringify(message.pubJwk);

		const hashBuffer = await crypto.subtle.digest(
			"SHA-256",
			new TextEncoder().encode(pubString)
		);
		const computedFingerprint = Array.from(new Uint8Array(hashBuffer))
			.map(b => b.toString(16).padStart(2, '0'))
			.join('')
			.slice(0, 8);
		if (computedFingerprint !== message.fingerprint) {
			ws.send(JSON.stringify({ type: "error", message: "Fingerprint mismatch" }));
			return;
		}

		const effectiveAuthor = message.username || author;

		ws.serializeAttachment({
			name: effectiveAuthor,
			fingerprint: computedFingerprint,
			pubJwk: pubString
		});

		ws.send(JSON.stringify({
			type: "register_ack",
			author: effectiveAuthor,
			fingerprint: computedFingerprint
		}));
	}

	async verifyMessage(msg: MessageReq, data: Attachments): Promise<boolean> {
		if (!data.pubJwk || !data.fingerprint) return false;
		// TODO: we prolly shouldn't parse that on every msg
		const pubJwk = JSON.parse(data.pubJwk);
		const cryptoKey = await crypto.subtle.importKey(
			"jwk",
			pubJwk,
			{ name: "ECDSA", namedCurve: "P-256" },
			false,
			["verify"]
		);

		const encoder = new TextEncoder();
		const dataToVerify = encoder.encode(JSON.stringify({
			msg: msg.msg,
			timestamp: msg.timestamp,
		}));
		const signatureBytes = Uint8Array.from(
			atob(msg.signature),
			c => c.charCodeAt(0)
		);

		const isValid = await crypto.subtle.verify(
			{ name: "ECDSA", hash: "SHA-256" },
			cryptoKey,
			signatureBytes,
			dataToVerify
		);
		return isValid;
	}
}

interface MessageReq {
	type: "message",
	signature: string,
	msg: string,
	timestamp: string,
}

interface RegisterReq {
	type: "register",
	fingerprint: string,
	pubJwk: JsonWebKey,
	username: string | undefined,
}

interface Attachments {
	name: string,
	pubJwk?: string,
	fingerprint?: string,
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
