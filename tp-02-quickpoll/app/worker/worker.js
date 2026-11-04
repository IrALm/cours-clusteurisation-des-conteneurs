// QuickPoll worker — dépile les votes depuis Redis et les persiste dans Postgres
const fs = require("node:fs");
const { Pool } = require("pg");
const { createClient } = require("redis");

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

let running = true;
process.on("SIGTERM", () => { running = false; });

async function loop() {
  await redis.connect();
  console.log("worker started");
  while (running) {
    const item = await redis.brPop("votes", 2);
    if (!item) continue;
    const vote = JSON.parse(item.element);
    // ON CONFLICT : rejouer un vote déjà inséré n'a aucun effet (idempotence)
    await pool.query(
      "INSERT INTO votes (vote_id, option) VALUES ($1, $2) ON CONFLICT (vote_id) DO NOTHING",
      [vote.vote_id, vote.option]
    );
    console.log(`vote ${vote.vote_id} -> ${vote.option}`);
  }
  await redis.quit();
  await pool.end();
}

loop().catch((err) => {
  console.error("worker crashed:", err.message);
  process.exit(1);
});
