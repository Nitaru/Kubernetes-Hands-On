const crypto = require("crypto");
const express = require("express");
const { createClient } = require("redis");
const metrics = require("./metrics");

const PORT = Number(process.env.PORT || 3000);
const PAYMENT_FAILURE_RATE = Number(process.env.PAYMENT_FAILURE_RATE || 0.03);
const PRODUCTS = { keyboard: 49, mouse: 19, monitor: 199, headset: 79 };

const redis = createClient({ url: process.env.REDIS_URL || "redis://redis:6379" });
redis.on("error", (err) => log("error", "redis error", { error: err.message }));
new metrics.client.Gauge({
  name: "shop_redis_up",
  help: "1 when the Redis client is connected and ready, 0 otherwise",
  registers: [metrics.register],
  collect() { this.set(redis.isReady ? 1 : 0); },
});

const app = express();
app.use(express.json());
app.use(metrics.middleware);

let shuttingDown = false;

function log(level, msg, extra = {}) {
  console.log(JSON.stringify({ time: new Date().toISOString(), level, msg, ...extra }));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Liveness: the process is up and the event loop answers. Never depends on Redis,
// otherwise a Redis outage would make Kubernetes restart healthy pods.
app.get("/health", (req, res) => res.json({ status: "ok" }));

// Readiness: only receive traffic while we are not shutting down. Redis is deliberately NOT part of this check.
// Only /api/orders needs Redis, and it already answers 503 on its own when Redis is down. If readiness also failed,
// a Redis outage would take every pod out of the Service and break /api/products, which never touches Redis
// (chaos experiment 3b: docs/chaos-experiments.md). Redis health is reported in the body and in shop_redis_up.
app.get("/ready", (req, res) => {
  if (shuttingDown) return res.status(503).json({ status: "shutting down" });
  res.json({ status: "ready", redis: redis.isReady ? "up" : "down" });
});

app.get("/metrics", async (req, res) => {
  res.set("Content-Type", metrics.register.contentType);
  res.send(await metrics.register.metrics());
});

app.get("/api/products", async (req, res) => {
  await sleep(Math.random() * 50);
  res.json(PRODUCTS);
});

// CPU-bound endpoint so the HorizontalPodAutoscaler has something real to react to.
app.get("/api/compute", (req, res) => {
  const ms = Math.min(Math.max(Number(req.query.ms) || 50, 1), 500);
  const end = Date.now() + ms;
  let digest = "x";
  while (Date.now() < end) digest = crypto.createHash("sha256").update(digest).digest("hex");
  res.json({ burnedMs: ms, digest: digest.slice(0, 16) });
});

app.post("/api/orders", async (req, res) => {
  const product = req.body.product;
  if (!PRODUCTS[product]) {
    return res.status(400).json({ error: "unknown product" });
  }
  if (!redis.isReady) {
    return res.status(503).json({ error: "order store unavailable" });
  }
  // Simulate some work and an occasional slow or failing payment provider
  await sleep(Math.random() < 0.05 ? 400 + Math.random() * 600 : Math.random() * 80);
  if (Math.random() < PAYMENT_FAILURE_RATE) {
    metrics.paymentFailures.inc();
    log("warn", "payment failed", { product });
    return res.status(502).json({ error: "payment failed" });
  }

  const quantity = Math.max(1, Number(req.body.quantity) || 1);
  const total = PRODUCTS[product] * quantity;
  const id = await redis.incr("orders:next_id");
  await redis.multi()
    .hIncrBy("orders:by_product", product, 1)
    .incrByFloat("orders:revenue", total)
    .lPush("orders:pending", String(id))
    .exec();

  metrics.ordersCreated.inc({ product });
  metrics.orderValue.observe(total);
  log("info", "order created", { id, product, quantity, total });
  res.status(201).json({ id, product, quantity, total });
});

// Background "worker" that fulfils pending orders at a limited pace
async function fulfilOrders() {
  if (!redis.isReady) return;
  try {
    const id = await redis.rPop("orders:pending");
    if (id) await redis.incr("orders:fulfilled");
  } catch (err) {
    log("error", "fulfilment failed", { error: err.message });
  }
}

app.use((err, req, res, next) => {
  log("error", "unhandled error", { error: err.message });
  res.status(500).json({ error: "internal server error" });
});

// Listen first and connect to Redis in the background: the pod is alive immediately and
// becomes ready when Redis answers, instead of crashing while Redis is still starting.
const server = app.listen(PORT, () => log("info", "shop-api listening", { port: PORT }));
redis.connect().catch((err) => log("error", "initial redis connect failed", { error: err.message }));
const fulfilTimer = setInterval(fulfilOrders, 300);

// Graceful shutdown: on SIGTERM stop being ready, finish in-flight requests, then exit.
// Kubernetes sends SIGTERM and waits terminationGracePeriodSeconds before SIGKILL.
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log("info", "shutting down", { signal });
  clearInterval(fulfilTimer);
  server.close(async () => {
    await redis.quit().catch(() => {});
    log("info", "shutdown complete");
    process.exit(0);
  });
  setTimeout(() => process.exit(1), 25000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
