// QuickPoll API — Node 22, sans framework
const http = require("node:http");
const fs = require("node:fs");
const { Pool } = require("pg");
const { createClient } = require("redis");

const VERSION = process.env.APP_VERSION || "v1";
const BROKEN = process.env.BREAK_HEALTH === "true"; // v3 volontairement cassée
const PORT = 3000;

// Le mot de passe peut venir d'une variable OU d'un fichier (docker secret)
function dbPassword() {
  if (process.env.DB_PASSWORD_FILE) {
    return fs.readFileSync(process.env.DB_PASSWORD_FILE, "utf8").trim();
  }
  return process.env.DB_PASSWORD;
}

const pool = new Pool({
  host: process.env.DB_HOST || "postgres",
  user: process.env.DB_USER || "quickpoll",
  database: process.env.DB_NAME || "quickpoll",
  password: dbPassword(),
});
const redis = createClient({ url: process.env.REDIS_URL || "redis://redis:6379" });

const OPTIONS = ["swarm", "kubernetes", "nomad"];

const MAX_ATTEMPTS = 8;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function init() {
  // Retry avec backoff exponentiel (0.5s, 1s, 2s, 4s, 8s, 15s...) : Postgres
  // peut démarrer après l'API. Après MAX_ATTEMPTS on abandonne et Swarm relance.
  for (let attempt = 1; ; attempt++) {
    try {
      await pool.query(`CREATE TABLE IF NOT EXISTS votes (
        id SERIAL PRIMARY KEY,
        vote_id TEXT UNIQUE NOT NULL,
        option TEXT NOT NULL,
        created_at TIMESTAMPTZ DEFAULT now()
      )`);
      break;
    } catch (err) {
      if (attempt >= MAX_ATTEMPTS) throw err;
      const delay = Math.min(500 * 2 ** (attempt - 1), 15000);
      console.error(`postgres indisponible (${err.message}), essai ${attempt}/${MAX_ATTEMPTS}, retry dans ${delay} ms`);
      await sleep(delay);
    }
  }
  await redis.connect();
}

function send(res, code, body) {
  res.writeHead(code, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.url === "/api/health") {
      if (BROKEN) return send(res, 500, { status: "ko" });
      await pool.query("SELECT 1");
      return send(res, 200, { status: "ok" });
    }
    if (req.url === "/api/version") {
      return send(res, 200, { version: VERSION, host: require("node:os").hostname() });
    }
    if (req.url === "/api/results" && req.method === "GET") {
      const { rows } = await pool.query(
        "SELECT option, COUNT(*)::int AS count FROM votes GROUP BY option ORDER BY option"
      );
      return send(res, 200, { version: VERSION, results: rows });
    }
    if (req.url === "/api/vote" && req.method === "POST") {
      let raw = "";
      for await (const chunk of req) raw += chunk;
      const { option } = JSON.parse(raw || "{}");
      if (!OPTIONS.includes(option)) return send(res, 400, { error: "option inconnue" });
      const vote = { vote_id: crypto.randomUUID(), option };
      await redis.lPush("votes", JSON.stringify(vote));
      return send(res, 202, { queued: vote.vote_id });
    }
    send(res, 404, { error: "not found" });
  } catch (err) {
    console.error(err);
    send(res, 500, { error: err.message });
  }
});

init()
  .then(() => server.listen(PORT, () => console.log(`api ${VERSION} listening on ${PORT}`)))
  .catch((err) => {
    console.error("init failed:", err.message);
    process.exit(1);
  });

process.on("SIGTERM", () => server.close(() => process.exit(0)));
