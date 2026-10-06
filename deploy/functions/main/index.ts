// Platform entrypoint.
// Routes:
//   /object/...                -> Supabase Storage API shim (files table)
//   anything else              -> status echo
//
// Storage contract (Caddy strips /storage/v1):
//   POST   /object/<bucket>/<path>        -> upload (user JWT, RLS owns the row)
//   GET    /object/public/<bucket>/<path> -> serve raw bytes (public)
//   DELETE /object/<bucket>/<path>        -> delete (user JWT, RLS owner-scoped)

const POSTGREST = Deno.env.get("SUPABASE_URL") || "http://postgrest:3000";
const SERVICE_KEY = Deno.env.get("SERVICE_KEY") || "";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

function parseStorage(pathname: string): { bucket: string; path: string; isPublic: boolean } | null {
  const m = pathname.match(/object\/(public\/)?([^/]+)\/(.+)$/);
  if (!m) return null;
  return { isPublic: Boolean(m[1]), bucket: m[2], path: decodeURIComponent(m[3]) };
}

async function findFile(key: string): Promise<{ id: string; mime_type: string } | null> {
  const r = await fetch(
    `${POSTGREST}/files?name=eq.${encodeURIComponent(key)}&select=id,mime_type`,
    { headers: { Authorization: `Bearer ${SERVICE_KEY}` } },
  );
  if (!r.ok) return null;
  const rows = await r.json();
  return rows[0] ?? null;
}

async function handleStorage(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const target = parseStorage(url.pathname);
  if (!target) return json({ error: "not found" }, 404);
  const key = `${target.bucket}/${target.path}`;

  if (req.method === "GET" && target.isPublic) {
    const file = await findFile(key);
    if (!file) return json({ error: "not found" }, 404);
    const r = await fetch(`${POSTGREST}/rpc/download_file?fid=${file.id}`, {
      headers: { Authorization: `Bearer ${SERVICE_KEY}`, Accept: "application/octet-stream" },
    });
    if (!r.ok) return json({ error: "not found" }, 404);
    return new Response(await r.arrayBuffer(), {
      headers: {
        "Content-Type": file.mime_type || "application/octet-stream",
        "Cache-Control": "public, max-age=3600",
      },
    });
  }

  const auth = req.headers.get("Authorization") || "";
  if (!auth) return json({ error: "unauthorized" }, 401);

  if (req.method === "POST") {
    const mime = req.headers.get("Content-Type") || "application/octet-stream";
    const up = await fetch(`${POSTGREST}/rpc/upload_binary`, {
      method: "POST",
      headers: { Authorization: auth, "Content-Type": "application/octet-stream" },
      body: await req.arrayBuffer(),
    });
    if (!up.ok) return json({ error: "upload failed", detail: await up.text() }, up.status);
    const row = await up.json();
    const patch = await fetch(`${POSTGREST}/files?id=eq.${row.id}`, {
      method: "PATCH",
      headers: { Authorization: auth, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({ name: key, mime_type: mime }),
    });
    if (!patch.ok) return json({ error: "patch failed" }, 500);
    return json({ Key: key });
  }

  if (req.method === "DELETE") {
    const file = await findFile(key);
    if (!file) return json({ error: "not found" }, 404);
    const del = await fetch(`${POSTGREST}/files?id=eq.${file.id}`, {
      method: "DELETE",
      headers: { Authorization: auth, Prefer: "return=minimal" },
    });
    if (!del.ok) return json({ error: "delete failed" }, del.status);
    return json({ message: "deleted" });
  }

  return json({ error: "method not allowed" }, 405);
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  if (parseStorage(url.pathname)) return handleStorage(req);
  return json({
    ok: true,
    service: "edge-runtime",
    path: url.pathname,
    method: req.method,
    timestamp: new Date().toISOString(),
  });
});
