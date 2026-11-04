// QuickPoll API 1.0 — Node 22, sans framework.
// Les votes sont écrits directement dans Postgres (service "db").
//
//   GET  /api/health  vivacité du processus seulement (ne dépend PAS de la base)
//   GET  /api/info    version, conteneur, état de la base (ne plante pas si la base est absente)
//   GET  /api/poll    total et répartition des votes
//   POST /api/vote    {"option": "swarm" | "kubernetes" | "nomad"}
const http = require("node:http");
const fs = require("node:fs");
const os = require("node:os");
const { Pool } = require("pg");

const VERSION = process.env.APP_VERSION || "1.0";
const PORT = 3000;
const OPTIONS = ["swarm", "kubernetes", "nomad"];

function dbPassword() {
  if (process.env.DB_PASSWORD_FILE) {
    return fs.readFileSync(process.env.DB_PASSWORD_FILE, "utf8").trim();
  }
  return process.env.DB_PASSWORD;
}

const pool = new Pool({
  host: process.env.DB_HOST || "db",
  user: process.env.DB_USER || "quickpoll",
  database: process.env.DB_NAME || "quickpoll",
  password: dbPassword(),
  connectionTimeoutMillis: 2000, // base injoignable => erreur rapide, pas de requête pendue
  query_timeout: 3000,
  max: 5,
});
pool.on("error", (err) => console.error("pg pool:", err.message)); // connexion coupée par la base

const UNDEFINED_TABLE = "42P01";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Création du schéma au démarrage, en tâche de fond : l'API écoute tout de suite,
// même si la base n'est pas encore là (elle répond alors 503 sur /api/poll et /api/vote).
async function ensureSchema() {
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query(`CREATE TABLE IF NOT EXISTS votes (
        id SERIAL PRIMARY KEY,
        option TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now()
      )`);
      console.log("schema ok");
      return;
    } catch (err) {
      const delay = Math.min(500 * 2 ** (attempt - 1), 10000);
      console.error(`db indisponible (${err.message}), essai ${attempt}, retry dans ${delay} ms`);
      await sleep(delay);
    }
  }
}

function send(res, code, body) {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

async function poll() {
  try {
    const { rows } = await pool.query(
      "SELECT option, COUNT(*)::int AS count FROM votes GROUP BY option ORDER BY option"
    );
    return { total: rows.reduce((s, r) => s + r.count, 0), results: rows };
  } catch (err) {
    // base neuve (vide) : la table n'existe pas encore => 0 vote
    if (err.code === UNDEFINED_TABLE) return { total: 0, results: [], schema: "missing" };
    throw err;
  }
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/api/health") return send(res, 200, { status: "ok" });

    if (req.url === "/api/info") {
      const info = { version: VERSION, host: os.hostname(), time: new Date().toISOString() };
      const t0 = Date.now();
      try {
        const { rows } = await pool.query("SELECT inet_server_addr()::text AS addr");
        Object.assign(info, { db: "up", db_addr: rows[0].addr, db_ms: Date.now() - t0 });
      } catch (err) {
        Object.assign(info, { db: "down", db_error: err.message });
      }
      return send(res, 200, info);
    }

    if (req.url === "/api/poll" && req.method === "GET") {
      return send(res, 200, { version: VERSION, ...(await poll()) });
    }

    if (req.url === "/api/vote" && req.method === "POST") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const { option } = JSON.parse(raw || "{}");
      if (!OPTIONS.includes(option)) return send(res, 400, { error: "option inconnue" });
      const { rows } = await pool.query(
        "INSERT INTO votes (option) VALUES ($1) RETURNING id",
        [option]
      );
      return send(res, 201, { id: rows[0].id, option });
    }

    send(res, 404, { error: "not found" });
  } catch (err) {
    // base absente, en cours de restauration, table supprimée... => 503
    console.error(req.method, req.url, err.message);
    send(res, 503, { error: err.message });
  }
});

server.listen(PORT, () => console.log(`api ${VERSION} listening on ${PORT}`));
ensureSchema();
process.on("SIGTERM", () => server.close(() => process.exit(0)));
