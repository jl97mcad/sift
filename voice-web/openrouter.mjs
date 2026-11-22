// Every OpenRouter chat completion Sift makes goes through here, so each one names the upstream
// providers it may run on and OpenRouter can't route it anywhere else.
import { key } from "./speech.mjs";

export const CHAT_URL = "https://openrouter.ai/api/v1/chat/completions";

/**
 * Allowed providers (OpenRouter provider slugs) by model id or by the model's maker (the part before "/").
 * config.openrouterProviders replaces this whole map. Defaults: each default model's first-party provider.
 */
export const DEFAULT_PROVIDERS = { deepseek: ["deepseek"], anthropic: ["anthropic"] };

/** The provider restriction for one model; throws when none is configured, so nothing goes out unrestricted. */
export function providerFor(config, model) {
  const map = config?.openrouterProviders ?? DEFAULT_PROVIDERS;
  const id = String(model ?? "");
  const list = map[id] ?? map[id.split("/")[0]];
  const only = Array.isArray(list) ? list.map((p) => String(p).trim()).filter(Boolean) : [];
  if (!id || !only.length) throw new Error(`No allowed OpenRouter provider for model "${id}": add it to openrouterProviders in config.json.`);
  return { only };
}

/** The request body with its provider restriction. */
export const chatBody = (config, body) => ({ ...body, provider: providerFor(config, body.model) });

/** POST one chat completion; the body is checked before the key is read or anything is sent. */
export async function chat(config, body, { title, timeout }) {
  const json = JSON.stringify(chatBody(config, body));
  return fetch(CHAT_URL, {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", ...(title ? { "X-Title": title } : {}) },
    body: json,
    signal: AbortSignal.timeout(timeout),
  });
}
