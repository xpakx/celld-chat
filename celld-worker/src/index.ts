import { DurableObject } from "cloudflare:workers";

export interface Env {
	CHAT_ROOM: DurableObjectNamespace;
}

export default {
	async fetch(request: Request, env: Env, _ctx: ExecutionContext): Promise<Response> {
		const requestUrl = new URL(request.url);

		if (requestUrl.pathname === "/ws") {
			const roomName = requestUrl.searchParams.get("room") || "global-chat";
			const roomId = env.CHAT_ROOM.idFromName(roomName);
			const stub = env.CHAT_ROOM.get(roomId);
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
					timestamp INT,
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

		const subprotocolHeader = request.headers.get("Sec-WebSocket-Protocol");


		const pair = new WebSocketPair();
		const [client, server] = Object.values(pair);

		this.ctx.acceptWebSocket(server);


		const authorName = extractNameFromSubprotocols(subprotocolHeader) ?? generateAnonymousName();

		server.serializeAttachment({ name: authorName });

		const cursor = this.ctx.storage.sql.exec(
			"SELECT * FROM (SELECT * FROM messages ORDER BY id DESC LIMIT 30) ORDER BY id ASC"
		);
		const messageHistory = [...cursor].map((row: any) => { return {
				id: row.id,
				author: row.author,
				content: row.content,
				verified: row.verified ? true : false,
				fingerprint: row.fingerprint,
				timestamp: row.timestamp,
		}});

		server.send(
			JSON.stringify({
				type: "history",
				messages: messageHistory,
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
		const currentUser = attachment?.name || "unknown";
		const userNameData = attachment ?? {name: currentUser};
		const request = JSON.parse(message as string);

		if (request.type == "register") {
			await this.register(ws, currentUser, request);
		} else if (request.type == "message") {
			await this.processMsg(ws, userNameData, request);
		} else if (request.type == "delete") {
			await this.deleteMsg(ws, userNameData, request);
		} else if (request.type == "edit") {
			await this.editMsg(ws, userNameData, request);
		}
	}

	async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
		ws.close(code, reason);
	}

	verifyTime(timestamp: number): boolean {
		const currentTime = Date.now();
		const messageTime = new Date(timestamp).getTime();
		const maxTimeDeltaMs = 5000;
		return !(isNaN(messageTime) || Math.abs(currentTime - messageTime) > maxTimeDeltaMs);
	}

	async processMsg(ws: WebSocket, data: Attachments, message: MessageReq) {
		const correctTime = this.verifyTime(message.timestamp);
		if (!correctTime) {
			ws.send(JSON.stringify({ type: "error", message: "Timestamp expired or invalid" }));
			return;
		}

		const verified = await this.verifyMessage(message, data);
		const fingerprint = verified ? data.fingerprint : undefined;
		const timestamp = new Date(message.timestamp).getTime();
		const result = this.ctx.storage.sql.exec(
			"INSERT INTO messages (content, author, timestamp, verified, fingerprint) VALUES (?, ?, ?, ?, ?) RETURNING id",
			message.msg,
			data.name,
			timestamp,
			verified,
			fingerprint
		);
		const row = result.one();
		const newId = row.id;

		const msg = JSON.stringify(
			{
				type: "message",
				content: message.msg,
				author: data.name,
				verified: verified,
				fingerprint: fingerprint,
				timestamp: timestamp,
				id: newId,
			}
		);
		const msgAck = JSON.stringify(
			{
				type: "ack",
				content: message.msg,
				verified: verified,
				timestamp: timestamp,
				id: newId,
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

	async verifyPayload(dataToVerify: ArrayBuffer | Uint8Array<ArrayBufferLike>, pubJwkStr: string, signature: string): Promise<boolean> {
		// TODO: we prolly shouldn't parse that on every msg
		const pubJwk = JSON.parse(pubJwkStr);
		const cryptoKey = await crypto.subtle.importKey(
			"jwk",
			pubJwk,
			{ name: "ECDSA", namedCurve: "P-256" },
			false,
			["verify"]
		);

		const signatureBytes = Uint8Array.from(
			atob(signature),
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

	async verifyMessage(msg: MessageReq, data: Attachments): Promise<boolean> {
		if (!data.pubJwk || !data.fingerprint) return false;
		const encoder = new TextEncoder();
		const dataToVerify = encoder.encode(JSON.stringify({
			msg: msg.msg,
			timestamp: msg.timestamp,
		}));
		return await this.verifyPayload(dataToVerify, data.pubJwk, msg.signature);
	}

	async deleteMsg(ws: WebSocket, data: Attachments, message: DeleteReq) {
		const correctTime = this.verifyTime(message.timestamp);
		if (!correctTime) {
			ws.send(JSON.stringify({ type: "error", message: "Timestamp expired or invalid" }));
			return;
		}
		if (!data.fingerprint) {
			ws.send(JSON.stringify({ type: "error", message: "Non-verified user" }));
			return;
		}
		const rows = this.ctx.storage.sql.exec(
			"SELECT fingerprint FROM messages WHERE id = ?",
				message.id
		).toArray();
		const found = rows[0];
		if (!found) {
			ws.send(JSON.stringify({ type: "error", message: "No such message" }));
			return;
		}
		const msgFingerprint = found.fingerprint;
		if (!msgFingerprint) {
			ws.send(JSON.stringify({ type: "error", message: "Wrong user" }));
			return;
		}

		const verified = await this.verifyDeletion(message, data, msgFingerprint as string);
		if (!verified) {
			ws.send(JSON.stringify({ type: "error", message: "Wrong user" }));
			return;
		}

		this.ctx.storage.sql.exec(
			"DELETE FROM messages WHERE id = ?",
				message.id
		);

		const resp = JSON.stringify({ type: "deleted", id: message.id });

		const sockets = this.ctx.getWebSockets();
		for (const socket of sockets) {
			socket.send(resp);
		}
	}

	async verifyDeletion(msg: DeleteReq, data: Attachments, fingerprint: string): Promise<boolean> {
		if (!data.pubJwk || !data.fingerprint) return false;
		if (data.fingerprint != fingerprint) return false;

		const encoder = new TextEncoder();
		const dataToVerify = encoder.encode(JSON.stringify({
			msg: msg.id,
			timestamp: msg.timestamp,
			action: "DELETE",
		}));
		return await this.verifyPayload(dataToVerify, data.pubJwk, msg.signature);
	}

	async editMsg(ws: WebSocket, data: Attachments, message: EditReq) {
		const correctTime = this.verifyTime(message.timestamp);
		if (!correctTime) {
			ws.send(JSON.stringify({ type: "error", message: "Timestamp expired or invalid" }));
			return;
		}
		if (!data.fingerprint) {
			ws.send(JSON.stringify({ type: "error", message: "Non-verified user" }));
			return;
		}
		const rows = this.ctx.storage.sql.exec(
			"SELECT fingerprint FROM messages WHERE id = ?",
			message.id
		).toArray();
		const found = rows[0];
		if (!found) {
			ws.send(JSON.stringify({ type: "error", message: "No such message" }));
			return;
		}
		const msgFingerprint = found.fingerprint;
		if (!msgFingerprint) {
			ws.send(JSON.stringify({ type: "error", message: "Wrong user" }));
			return;
		}

		const verified = await this.verifyEdit(message, data, msgFingerprint as string);
		if (!verified) {
			ws.send(JSON.stringify({ type: "error", message: "Wrong user" }));
			return;
		}

		this.ctx.storage.sql.exec(
			"UPDATE messages SET content = ? WHERE id = ?",
			message.newMsg,
			message.id
		);

		const resp = JSON.stringify({ type: "edited", id: message.id, content: message.newMsg });

		const sockets = this.ctx.getWebSockets();
		for (const socket of sockets) {
			socket.send(resp);
		}
	}

	async verifyEdit(msg: EditReq, data: Attachments, fingerprint: string): Promise<boolean> {
		if (!data.pubJwk || !data.fingerprint) return false;
		if (data.fingerprint != fingerprint) return false;

		const encoder = new TextEncoder();
		const dataToVerify = encoder.encode(JSON.stringify({
			msg: msg.id,
			timestamp: msg.timestamp,
			content: msg.newMsg,
			action: "EDIT",
		}));
		return await this.verifyPayload(dataToVerify, data.pubJwk, msg.signature);
	}
}

interface MessageReq {
	type: "message",
	signature: string,
	msg: string,
	timestamp: number,
}

interface DeleteReq {
	type: "delete",
	signature: string,
	timestamp: number,
	id: number,
}

interface EditReq {
	type: "edit",
	signature: string,
	timestamp: number,
	id: number,
	newMsg: string,
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
