export default {
  async fetch(request, env) {
    const cors = {
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    };
    const json = (status, body) => new Response(JSON.stringify(body), { status, headers: cors });
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method !== "POST") return json(405, { error: "Use POST." });
    if (!env.AURELIA_GATEWAY_TOKEN || !env.OPENAI_API_KEY) {
      return json(503, { error: "AI gateway is not configured by the administrator." });
    }
    const auth = request.headers.get("Authorization") || "";
    const supplied = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    if (!supplied || supplied.length !== env.AURELIA_GATEWAY_TOKEN.length ||
        !constantTimeEqual(supplied, env.AURELIA_GATEWAY_TOKEN)) {
      return json(401, { error: "Unauthorized." });
    }
    const contentLength = Number(request.headers.get("Content-Length") || 0);
    if (contentLength > 8192) return json(413, { error: "Request too large." });
    let body;
    try { body = await request.json(); } catch (_) { return json(400, { error: "Invalid JSON." }); }
    const question = typeof body?.question === "string" ? body.question.trim() : "";
    if (!question || question.length > 500) return json(400, { error: "Question must contain 1–500 characters." });
    const model = env.OPENAI_MODEL || "gpt-4.1-mini";
    let upstream;
    try {
      upstream = await fetch("https://api.openai.com/v1/responses", {
        method: "POST",
        headers: {
          "Authorization": "Bearer " + env.OPENAI_API_KEY,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          max_output_tokens: 800,
          store: false,
          input: [
            {
              role: "system",
              content: [{
                type: "input_text",
                text: "You are Aurelia Assist, an operational copilot for a hotel PMS and separate restaurant POS. Give precise, cautious, actionable guidance. Hotel guest/room data and restaurant menu/orders/bills are separate entities; only food items may be posted through guest room billing. Never claim you inspected the local database, changed records, repaired a defect, or ran a test unless the app explicitly supplies verified evidence. Do not invent app capabilities. Do not ask for or request guest identity numbers, passwords, payment credentials, or private guest records. Treat all advice as suggestions: never authorize a payment, delete records, alter a bill, or perform a destructive operation. For errors, propose diagnosis and safe steps; recommend a backup before risky changes."
              }]
            },
            { role: "user", content: [{ type: "input_text", text: question }] }
          ]
        }),
      });
    } catch (_) {
      return json(502, { error: "AI provider is unreachable. The app should fall back to offline guidance." });
    }
    if (!upstream.ok) {
      // Do not relay upstream body; it may contain provider details.
      return json(502, { error: "AI provider request failed (HTTP " + upstream.status + ")." });
    }
    let result;
    try { result = await upstream.json(); } catch (_) { return json(502, { error: "AI provider returned invalid JSON." }); }
    let answer = typeof result.output_text === "string" ? result.output_text.trim() : "";
    if (!answer && Array.isArray(result.output)) {
      answer = result.output.flatMap(item => Array.isArray(item.content) ? item.content : [])
        .filter(part => part.type === "output_text" && typeof part.text === "string")
        .map(part => part.text).join("\n").trim();
    }
    if (!answer) return json(502, { error: "AI provider returned no text answer." });
    return json(200, { answer, model, mode: "online-ai", disclaimer: "Advice only; verify before changing PMS records." });
  }
};

function constantTimeEqual(a, b) {
  let diff = 0;
  const length = Math.max(a.length, b.length);
  for (let i = 0; i < length; i++) diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  return diff === 0;
}
