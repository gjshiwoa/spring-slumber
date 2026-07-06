#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const readline = require("readline");

// ─── 配置 ────────────────────────────────────────────────────
function readDotEnvValue(name) {
  const files = [
    path.join(process.cwd(), ".opencode/mcp/doubao-vision/.env"),
    path.join(process.cwd(), ".env"),
  ];
  for (const file of files) {
    if (!fs.existsSync(file)) continue;
    const lines = fs.readFileSync(file, "utf8").split(/\r?\n/);
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const i = trimmed.indexOf("=");
      if (i < 0) continue;
      const key = trimmed.slice(0, i).trim();
      if (key !== name) continue;
      let value = trimmed.slice(i + 1).trim();
      if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
        value = value.slice(1, -1);
      }
      return value;
    }
  }
}

function loadApiKey() {
  const envValue = process.env.ARK_API_KEY || "";
  if (envValue && !/^\{env:[A-Z0-9_]+\}$/i.test(envValue)) return envValue;
  return readDotEnvValue("ARK_API_KEY") || "";
}

const API_KEY = loadApiKey();
const BASE_URL =
  process.env.DOUBAO_BASE_URL || "https://ark.cn-beijing.volces.com/api/v3";
const MODEL = process.env.DOUBAO_MODEL || "doubao-seed-2-1-pro";
const DEFAULT_PROMPT =
  process.env.DESCRIBE_IMAGE_PROMPT ||
  "请详细描述这张图片的内容，包括画面主体、场景背景、可见文字、颜色、构图与布局等细节，力求全面准确。";

const SERVER_NAME = "doubao-vision";
const SERVER_VERSION = "1.0.0";
const FALLBACK_PROTOCOL_VERSION = "2024-11-05";

if (!API_KEY) {
  console.error(
    "[doubao-vision] 警告：缺少 ARK_API_KEY。MCP 将继续启动，但 describe_image 调用会失败。可在 shell 中导出 ARK_API_KEY，或写入 .opencode/mcp/doubao-vision/.env。"
  );
}

// ─── 工具函数 ────────────────────────────────────────────────
const MIME_BY_EXT = {
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  bmp: "image/bmp",
};

function resolveImageSource(image) {
  if (/^https?:\/\//i.test(image)) return image;
  if (/^data:image\/[a-z+]+;base64,/i.test(image)) return image;
  const abs = path.isAbsolute(image) ? image : path.join(process.cwd(), image);
  if (!fs.existsSync(abs)) throw new Error("图片文件未找到: " + image);
  const buf = fs.readFileSync(abs);
  const ext = path.extname(abs).slice(1).toLowerCase();
  const mime = MIME_BY_EXT[ext] || "image/png";
  return "data:" + mime + ";base64," + buf.toString("base64");
}

async function describeImage(args) {
  if (!API_KEY) {
    throw new Error("缺少 ARK_API_KEY。请设置环境变量 ARK_API_KEY，或创建 .opencode/mcp/doubao-vision/.env 并写入 ARK_API_KEY=你的密钥，然后重启 opencode。");
  }
  const url = resolveImageSource(args.image);
  const body = {
    model: MODEL,
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: args.prompt || DEFAULT_PROMPT },
          {
            type: "image_url",
            image_url: { url: url, detail: args.detail || "auto" },
          },
        ],
      },
    ],
    temperature: args.temperature == null ? 1 : args.temperature,
    max_tokens: args.max_tokens == null ? 4096 : args.max_tokens,
    stream: false,
    thinking: { type: "disabled" },
  };

  const res = await fetch(BASE_URL + "/chat/completions", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + API_KEY,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(1800000),
  });

  if (!res.ok) {
    const txt = await res.text();
    throw new Error("Ark API 错误 (" + res.status + "): " + txt);
  }

  const data = await res.json();
  return {
    content: (data.choices && data.choices[0] && data.choices[0].message && data.choices[0].message.content) || "",
    usage: data.usage || null,
    model: data.model || MODEL,
  };
}

// ─── 工具定义 ────────────────────────────────────────────────
const TOOL = {
  name: "describe_image",
  description: [
    "使用豆包 Seed 2.1 Pro 视觉模型获取图片的详细文字描述。",
    "当当前对话模型不支持图片输入时调用本工具：传入本地图片路径或图片 URL，即可得到图片内容的详细描述，从而让纯文本模型也能“看懂”图片。",
    "支持 png/jpg/jpeg/gif/webp/bmp 格式；可选 prompt 指定关注重点。",
  ].join(""),
  inputSchema: {
    type: "object",
    properties: {
      image: {
        type: "string",
        description:
          "图片来源：本地文件路径（如 C:/path/to/img.png）或图片 URL（https://...）",
      },
      prompt: {
        type: "string",
        description: "对图片的描述指令；留空则默认返回图片的全面详细描述。",
      },
      detail: {
        type: "string",
        enum: ["auto", "low", "high"],
        default: "auto",
        description: "图片精度，需要精细分析时用 high",
      },
      max_tokens: {
        type: "number",
        default: 4096,
        description: "最大输出 token 数",
      },
      temperature: {
        type: "number",
        default: 1,
        description: "采样温度（0~2）",
      },
    },
    required: ["image"],
  },
};

// ─── MCP stdio JSON-RPC ──────────────────────────────────────
function send(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function ok(id, result) {
  send({ jsonrpc: "2.0", id: id, result: result });
}

function rpcError(id, code, message) {
  send({ jsonrpc: "2.0", id: id, error: { code: code, message: message } });
}

async function handleRequest(msg) {
  const id = msg.id;
  const method = msg.method;
  const params = msg.params || {};

  try {
    if (method === "initialize") {
      ok(id, {
        protocolVersion: params.protocolVersion || FALLBACK_PROTOCOL_VERSION,
        capabilities: { tools: {} },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
      });
      return;
    }

    if (method === "tools/list") {
      ok(id, { tools: [TOOL] });
      return;
    }

    if (method === "tools/call") {
      const name = params.name;
      const args = params.arguments || {};
      if (name !== "describe_image") {
        ok(id, {
          content: [{ type: "text", text: "未知工具: " + name }],
          isError: true,
        });
        return;
      }
      if (!args.image) {
        ok(id, {
          content: [{ type: "text", text: "缺少必填参数 image" }],
          isError: true,
        });
        return;
      }
      const r = await describeImage({
        image: args.image,
        prompt: args.prompt,
        detail: args.detail,
        max_tokens: args.max_tokens,
        temperature: args.temperature,
      });
      let text = r.content || "(模型未返回内容)";
      if (r.usage) {
        text +=
          "\n\n---\n_⚡ " +
          (r.usage.prompt_tokens == null ? "?" : r.usage.prompt_tokens) +
          " in → " +
          (r.usage.completion_tokens == null ? "?" : r.usage.completion_tokens) +
          " out (model: " +
          r.model +
          ")_";
      }
      ok(id, { content: [{ type: "text", text: text }] });
      return;
    }

    rpcError(id, -32601, "未支持的方法: " + method);
  } catch (e) {
    if (method === "tools/call" && id !== undefined) {
      ok(id, { content: [{ type: "text", text: "❌ " + e.message }], isError: true });
    } else {
      rpcError(id, -32603, e.message || String(e));
    }
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on("line", function (line) {
  const trimmed = line.trim();
  if (!trimmed) return;
  let msg;
  try {
    msg = JSON.parse(trimmed);
  } catch (e) {
    return; // 忽略非 JSON 行
  }
  // 通知（无 id）无需响应
  if (msg.id === undefined && msg.method) {
    return;
  }
  handleRequest(msg);
});

console.error("[doubao-vision] 就绪 (model: " + MODEL + ")");
