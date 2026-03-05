const Redis = require("ioredis");
const mysql = require("mysql2/promise");
const express = require("express");

const redisUrl = process.env.REDIS_URL || "redis://localhost:6379/0";
const redis = new Redis(redisUrl);

const healthApp = express();
let healthy = false;

healthApp.get("/health", (_req, res) => {
  if (healthy) return res.json({ status: "ok", service: "worker" });
  res.status(503).json({ status: "starting" });
});
healthApp.listen(3000);

async function getPool() {
  return mysql.createPool({
    host: process.env.MYSQL_HOST || "localhost",
    user: process.env.MYSQL_USER || "app",
    password: process.env.MYSQL_PASSWORD || "apppass",
    database: process.env.MYSQL_DATABASE || "testdb",
    waitForConnections: true,
    connectionLimit: 5,
  });
}

async function processJob(pool, job) {
  const data = JSON.parse(job);
  console.log(`Processing item ${data.item_id}: ${data.name}`);

  // Simulate some work
  await new Promise((r) => setTimeout(r, 500));

  await pool.execute("UPDATE items SET processed = TRUE WHERE id = ?", [
    data.item_id,
  ]);
  console.log(`Completed item ${data.item_id}`);
}

async function main() {
  const pool = await getPool();
  healthy = true;
  console.log("Worker started, waiting for jobs on jobs:process...");

  while (true) {
    try {
      // BRPOP blocks until a job is available (5s timeout to allow health checks)
      const result = await redis.brpop("jobs:process", 5);
      if (result) {
        const [, job] = result;
        await processJob(pool, job);
      }
    } catch (err) {
      console.error("Error processing job:", err.message);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

main().catch((err) => {
  console.error("Worker fatal error:", err);
  process.exit(1);
});
