# Design: opencode-as-a-provider

**Date:** 2026-05-19  
**Status:** Validated（實驗已驗證）

## 目標

取代 ai-core 的 key-pool 機制。目前每個專案需要自己持有 API keys + SqliteAdapter 做輪換，改成所有專案統一打一個集中的 opencode server，key 管理集中在 server 端。

## 背景

- `ai-core` 現有的 `KeyPool` 管理多支 Gemini/OpenAI 等 API key，做 lease 輪換、cooldown、負載均衡
- opencode 有 `opencode serve` 模式，對外露出 REST API
- `POST /session/:id/message` 是同步 blocking endpoint，等 AI 回完才回 HTTP response
- opencode server 自己持有並管理 provider keys（支援 browser OAuth 或 API key 兩種登入方式）

## 架構

```
home-basic repo
  └── opencode container（opencode serve，port 4096）
            ↑ HTTP
  ┌─────────┼─────────┐
project-A  project-B  project-C
ai-core    ai-core    ai-core
OpencodeServerAdapter（只需 OPENCODE_URL）
```

**每個專案的設定從「一堆 keys + SQLite DB」變成「一個 OPENCODE_URL 環境變數」。**

## 元件設計

### 1. opencode container（home-basic）

`opencode serve` 跑在 Docker container，需自行 build image（opencode 沒有官方 Docker image）。

```dockerfile
FROM node:22-alpine
RUN npm config set strict-ssl false && npm install -g opencode-ai
WORKDIR /app
EXPOSE 4096 1455
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096", "--print-logs"]
```

```yaml
# docker-compose.yml
services:
  opencode:
    build: .
    ports:
      - "4096:4096"
      - "1455:1455"   # OAuth browser callback 固定走這個 port
    environment:
      - NODE_TLS_REJECT_UNAUTHORIZED=0   # 必要：公司 proxy SSL bypass
      - OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD}
    restart: unless-stopped
```

**注意：**
- port 1455 必須 expose，browser OAuth callback 固定回 `localhost:1455`
- `NODE_TLS_REJECT_UNAUTHORIZED=0` 必要，否則 opencode 呼叫外部 API 時被公司 proxy 擋住
- provider keys 透過 web UI（`http://localhost:4096`）用 browser OAuth 登入，不需在 compose 裡放明文 key

### 2. 確認的 API 格式（實驗驗證）

**建立 session：**
```
POST /session
Body: {}
Response: { id: "ses_xxx", ... }
```

**送訊息（同步）：**
```
POST /session/:id/message
Body: {
  parts: [{ type: "text", text: "..." }],
  model: { modelID: "gpt-5.5", providerID: "openai" }  // object，不是 string
}
Response: {
  info: { modelID, providerID, tokens, cost, ... },
  parts: [
    { type: "step-start", ... },
    { type: "text", text: "..." },   // 實際回應在這
    { type: "step-finish", ... }
  ]
}
```

**刪除 session：**
```
DELETE /session/:id
```

**列出可用 models：**
```
GET /api/model   // 注意：是 /api/model，不是 /model
Response: [{ id, providerID, ... }]
```

### 3. OpencodeServerAdapter（ai-core）

新增 `src/provider/adapters/opencode-server.ts`，實作 `ProviderAdapter` 介面。

**每次 generateContent 的流程：**
1. `POST /session` → 取得 session ID
2. `POST /session/:id/message` → 送 prompt，同步等回應
3. 從 `parts` 找 `type === "text"` 的 part 取出文字
4. `DELETE /session/:id` → 清理 session（fire-and-forget）
5. 回傳 `GenerateResponse`

```typescript
class OpencodeServerAdapter implements ProviderAdapter {
  constructor(
    private baseURL: string,
    private model: { modelID: string; providerID: string },
    private password?: string
  ) {}

  async generateContent(params: GenerateParams): Promise<GenerateResponse> {
    const sessionId = await this.createSession();
    try {
      const response = await this.sendMessage(sessionId, params);
      return this.parseResponse(response);
    } finally {
      this.deleteSession(sessionId).catch(() =>{}); // fire-and-forget
    }
  }

  private parseResponse(response: OpencodeMessageResponse): GenerateResponse {
    const textPart = response.parts.find(p => p.type === "text");
    return { text: textPart?.text ?? "" };
  }
}
```

**Auth：** HTTP basic auth header（username: `opencode`，password: `OPENCODE_SERVER_PASSWORD`）。

**不需要：** KeyPool、SqliteAdapter、lease/cooldown 邏輯。

### 4. 新專案接入

```typescript
import { OpencodeServerAdapter } from "@kevinsisi/ai-core/provider";

const provider = new OpencodeServerAdapter(
  process.env.OPENCODE_URL!,                    // http://opencode:4096
  { modelID: "gpt-5.5", providerID: "openai" },
  process.env.OPENCODE_PASSWORD                 // 可選
);

const result = await provider.generateContent({ prompt: "Hello" });
```

## Session 管理策略

- 每個 request 建立獨立 session（stateless，無狀態污染）
- `generateContent` 帶入完整 `history`，opencode 不需記住上下文
- session 在 finally block 刪除（fire-and-forget，不阻塞 response）

## 不在範圍內

- streaming 支援（第一版不做，opencode async endpoint 留待後續）
- session pool / 複用（過度設計，先不做）
- opencode server 的 HA / 多實例（厝基礎設施單機即可）

## 實作範圍

| Repo | 工作 |
|---|---|
| `home-basic` | 加 opencode service（Dockerfile + docker-compose），browser 登入設定 provider |
| `ai-core` | 新增 `OpencodeServerAdapter`，export 對外 |
| `provider-test` | demo 程式 + 接入驗證（Dockerfile、docker-compose 已在此 repo 實驗完成） |
