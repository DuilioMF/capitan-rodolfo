const express = require("express");
const sql = require("mssql");

const app = express();
const allowedOrigins = new Set([
  "https://capitan-rodolfo.revalsoftia.chatgpt.site",
  "https://rodolfo.doinglio.com.ar",
  "https://doinglio.com.ar",
  "https://doinglio.revalsoftia.chatgpt.site",
  "https://doinglio.revalsoftia.com.ar",
]);

app.use((req, res, next) => {
  const origin = req.headers.origin;
  if (origin && allowedOrigins.has(origin)) res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Vary", "Origin");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  res.setHeader("Access-Control-Allow-Private-Network", "true");
  if (req.method === "OPTIONS") return res.sendStatus(204);
  next();
});
app.use(express.json({ limit: "24kb" }));

function connectionConfig(body) {
  const rawServer = String(body.server || "").trim();
  const username = String(body.username || "").trim();
  const password = String(body.password || "");
  if (!rawServer || !username || !password) throw new Error("Completá servidor, usuario y contraseña.");

  const [server, instanceName] = rawServer.split("\\", 2);
  return {
    server,
    user: username,
    password,
    database: body.database ? String(body.database).trim() : undefined,
    options: {
      encrypt: true,
      trustServerCertificate: true,
      enableArithAbort: true,
      ...(instanceName ? { instanceName } : {}),
    },
    pool: { max: 3, min: 0, idleTimeoutMillis: 5000 },
    connectionTimeout: 10000,
    requestTimeout: 15000,
  };
}

async function query(config, statement) {
  const pool = new sql.ConnectionPool(config);
  await pool.connect();
  try { return await pool.request().query(statement); }
  finally { await pool.close(); }
}

app.post("/api/sql", async (req, res) => {
  try {
    const action = req.body.action;
    const config = connectionConfig(req.body);
    if (action === "databases") {
      const result = await query(config, `SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' AND HAS_DBACCESS(name) = 1 ORDER BY name`);
      return res.json({ databases: result.recordset.map((row) => row.name) });
    }
    if (action === "tables") {
      if (!config.database) throw new Error("Elegí una base de datos.");
      const result = await query(config, `SELECT TABLE_SCHEMA + '.' + TABLE_NAME AS name FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_SCHEMA, TABLE_NAME`);
      return res.json({ tables: result.recordset.map((row) => row.name) });
    }
    throw new Error("Acción SQL no válida.");
  } catch (error) {
    res.status(400).json({ error: error instanceof Error ? error.message : "No se pudo conectar a SQL Server." });
  }
});

app.listen(34721, "127.0.0.1", () => {
  console.log("Conector SQL de DoingLio listo. Dejá esta ventana abierta.");
});
