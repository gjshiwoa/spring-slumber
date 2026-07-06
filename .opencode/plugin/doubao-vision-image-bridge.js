// 图片桥接插件：当用户在 TUI 粘贴/拖入本地图片时，opencode 会把它作为
// { type:"file", url:"data:image/png;base64,..." } 形式的 Part 放进消息。
// 纯文本模型看不到这种 part，因此无法识别图片、也不会调用 describe_image。
//
// 本插件仅在「当前会话模型不支持图片输入」时，才把图片 part 转成文本提示：
//   - data URI → 存为临时文件，文本给出绝对路径
//   - http(s) URL → 文本直接给出 URL
// 并引导模型调用 describe_image 工具来"看"图。
// 视觉模型（支持图片输入）则保留原图不动，让它直接看图。
//
// 判断依据：chat.message 钩子拿到 sessionID + model{providerID,modelID}，
// 通过 client 查询 v2 模型能力（capabilities.input 含 "image" 即支持），
// 缓存 sessionID → 是否支持图片。transform 钩子按消息里的 sessionID 查表。
// 查不到能力信息时保守起见「转换」（确保纯文本模型可用）。

import { existsSync, mkdirSync, writeFileSync } from "node:fs"
import { createHash } from "node:crypto"
import path from "node:path"

const TMP_DIR_NAME = ".opencode/mcp/doubao-vision/tmp"
// sessionID -> 是否支持图片输入。true=支持(跳过转换)；false=不支持(转换)；undefined=未知(保守转换)
const sessionSupportsImage = new Map()
// providerID/modelID -> 是否支持图片（模型能力缓存，避免重复查询）
const modelCapabilityCache = new Map()
let modelsFetchPromise = null

function log(msg) {
  process.stderr.write("[image-bridge] " + msg + "\n")
}

function extFromMime(mime) {
  const m = (mime || "").toLowerCase()
  if (m.includes("png")) return "png"
  if (m.includes("jpeg") || m.includes("jpg")) return "jpg"
  if (m.includes("gif")) return "gif"
  if (m.includes("webp")) return "webp"
  if (m.includes("bmp")) return "bmp"
  if (m.includes("avif")) return "avif"
  return "png"
}

function parseDataUri(uri) {
  const m = /^data:([^;]+);base64,(.+)$/i.exec(uri)
  if (!m) return
  try {
    return { mime: m[1], bytes: Buffer.from(m[2], "base64") }
  } catch {
    return
  }
}

function extractImageSource(part) {
  if (!part || typeof part !== "object") return
  const mime = part.mime || part.mediaType || part.mimeType
  if (part.type === "file") {
    if (mime && !/^image\//i.test(mime)) return
    const src = part.url ?? part.uri
    if (typeof src === "string" && (/^data:image\//i.test(src) || /^https?:\/\//i.test(src))) return src
  }
  if (part.type === "image") {
    const src = typeof part.image === "string" ? part.image : part.image?.url
    if (typeof src === "string") return src
  }
  if (typeof part.url === "string" && /^data:image\//i.test(part.url)) return part.url
}

function buildTextPartForImage(src, directory, index) {
  if (/^https?:\/\//i.test(src)) {
    return {
      type: "text",
      text:
        "[用户上传了图片 " + index + "，URL：" + src + "]\n" +
        "如需了解这张图片的内容，请调用 describe_image 工具，image 参数传入该 URL。",
    }
  }
  const data = parseDataUri(src)
  if (!data) return
  const tmpDir = path.join(directory, TMP_DIR_NAME)
  try {
    if (!existsSync(tmpDir)) mkdirSync(tmpDir, { recursive: true })
  } catch {
    return
  }
  const hash = createHash("sha1").update(data.bytes).digest("hex").slice(0, 16)
  const abs = path.join(tmpDir, "img_" + hash + "." + extFromMime(data.mime))
  try {
    if (!existsSync(abs)) writeFileSync(abs, data.bytes)
  } catch (e) {
    log("写入临时文件失败: " + String(e))
    return
  }
  return {
    type: "text",
    text:
      "[用户上传了图片 " + index + "（" + data.mime + "），已保存到本地：" + abs + "]\n" +
      "如需了解这张图片的内容，请调用 describe_image 工具，image 参数传入上述路径。",
  }
}

function transformMessages(messages, directory, shouldTransform) {
  if (!Array.isArray(messages) || !shouldTransform) return 0
  let replaced = 0
  for (const entry of messages) {
    if (!entry || typeof entry !== "object") continue
    const parts = entry.parts
    if (!Array.isArray(parts)) continue
    let imgIdx = 0
    for (let i = 0; i < parts.length; i++) {
      const src = extractImageSource(parts[i])
      if (!src) continue
      imgIdx++
      const textPart = buildTextPartForImage(src, directory, imgIdx)
      if (textPart) {
        parts[i] = textPart
        replaced++
      }
    }
  }
  return replaced
}

// 从 output.messages 里取出 sessionID（取最近一条 user 消息的 info.sessionID）
function pickSessionId(messages) {
  if (!Array.isArray(messages)) return
  for (let i = messages.length - 1; i >= 0; i--) {
    const entry = messages[i]
    const sid = entry?.info?.sessionID
    if (typeof sid === "string" && sid) return sid
  }
}

// 拉取全部 v2 模型，构建 providerID/modelID -> 是否支持图片 的缓存
async function refreshModelCapabilities(client, directory) {
  try {
    const res = await client.model.list({ query: { location: { directory } } })
    const models = res?.data ?? res ?? []
    for (const m of models) {
      if (!m || typeof m.id !== "string" || typeof m.providerID !== "string") continue
      const inputs = m.capabilities?.input ?? m.modalities?.input
      const supports = Array.isArray(inputs) && inputs.some((x) => String(x).toLowerCase() === "image")
      modelCapabilityCache.set(m.providerID + "/" + m.id, !!supports)
    }
    log("已加载 " + modelCapabilityCache.size + " 个模型的能力信息")
  } catch (e) {
    log("查询模型能力失败: " + String(e))
  }
}

function modelSupportsImage(providerID, modelID) {
  if (!providerID || !modelID) return undefined
  return modelCapabilityCache.get(providerID + "/" + modelID)
}

export default async function imageBridgePlugin(input) {
  const directory = input?.directory ?? process.cwd()
  const client = input?.client

  // 首次加载模型能力表；失败不阻塞，transform 时按未知处理
  if (client) {
    modelsFetchPromise = refreshModelCapabilities(client, directory).catch(() => {})
  }

  return {
    // 每条消息到来时，记录该 session 当前模型是否支持图片
    "chat.message": async function (msgInput) {
      try {
        const sid = msgInput?.sessionID
        const model = msgInput?.model
        if (!sid || !model) return
        const key = model.providerID + "/" + model.modelID
        let supports = modelCapabilityCache.get(key)
        if (supports === undefined && client) {
          await (modelsFetchPromise ?? (modelsFetchPromise = refreshModelCapabilities(client, directory).catch(() => {})))
          supports = modelSupportsImage(model.providerID, model.modelID)
        }
        sessionSupportsImage.set(sid, supports === true)
        if (supports === true) log("会话 " + sid.slice(0, 8) + " 模型支持图片，保留原图")
        else log("会话 " + sid.slice(0, 8) + " 模型不支持图片，将转换图片为文本提示")
      } catch (e) {
        log("chat.message 出错: " + String(e))
      }
    },

    "experimental.chat.messages.transform": async function (_input, output) {
      try {
        const messages = output?.messages
        const sid = pickSessionId(messages)
        // supports===true 才跳过；false 或 undefined(未知) 都转换（保守，确保纯文本模型可用）
        const supports = sid ? sessionSupportsImage.get(sid) : undefined
        if (supports === true) return
        const n = transformMessages(messages, directory, true)
        if (n > 0) log("已将 " + n + " 张图片转为文本提示（sessionID=" + (sid ? sid.slice(0, 8) : "?") + "）")
      } catch (e) {
        log("transform 出错: " + String(e))
      }
    },
  }
}
