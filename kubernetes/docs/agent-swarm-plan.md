# Multi-Host Agent Swarm — Fleet Architecture Plan

## The Fleet (15 models, 4 hosts, 1 LiteLLM proxy)

```
                         ┌─────────────────────────────────┐
                         │     LiteLLM Proxy (k8s)         │
                         │  litellm.${SECRET_DOMAIN}       │
                         │  OpenAI-compatible API          │
                         │  15 models, unified routing     │
                         └───────────┬─────────────────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
     ┌────────▼────────┐  ┌─────────▼────────┐  ┌──────────▼──────────┐
     │  Agent Layer     │  │  RAG Pipeline    │  │  Scheduling Layer   │
     │  (Goose/pi-swarm)│  │  (embed+rerank)  │  │  (Hermes + cron)    │
     └────────┬────────┘  └──────────────────┘  └─────────────────────┘
              │
     ┌────────▼────────────────────────────────────────────────┐
     │              MODEL ROUTING (by task tier)               │
     │                                                         │
     │  TIER 1 — Planner/CEO:    gpt-oss-120b (cerberus)       │
     │  TIER 2 — Team Lead:      qwen3-coder-next-80b (HIP)    │
     │  TIER 3 — Fast Workers:   gpt-oss-20b, ornith-9b        │
     │  TIER 4 — Specialists:    deepseek-r1, vision models    │
     │  TIER 5 — Overnight:     qwen3-235b-overnight           │
     └─────────────────────────────────────────────────────────┘
```

---

## 1. Model Routing Strategy

Each model has a "best role" based on its speed, intelligence, and capabilities:

| Role | Model | Host | tok/s | Why |
|---|---|---|---|---|
| **CEO/Planner** | gpt-oss-120b | cerberus | 57 | Highest intelligence, reasoning_effort=high, 65k ctx |
| **Team Lead (coding)** | qwen3-coder-next-80b | cerberus | 49 | HIP backend, 131k ctx, terse agentic coder, resident |
| **Fast Coder** | ornith-35b | talos | 324 | MoE+MTP, agentic coding, 262k ctx, default on talos |
| **Fastest Coder** | gpt-oss-20b | talos | 350 | Fastest in fleet, 131k ctx, long-prompt/short-answer |
| **Agentic Coder** | devstral-24b | talos | 96 | Purpose-built for multi-file agentic coding |
| **Small Fast Coder** | ornith-9b | hephaestus | 136 | DFlash spec-decode, fast, fully VRAM-resident |
| **Vision (small)** | gemma-4-12b | hephaestus | 136 | MTP+vision, fast, default on hephaestus |
| **Vision (mid)** | mistral-small-3.2-24b-vision | delphi | 47.5 | Q3+mmproj, 16k ctx |
| **Generalist** | mistral-small-3.2-24b | delphi | ~45 | Q4_K_M, strong general chat, default on delphi |
| **Reasoning** | deepseek-r1-14b | delphi | 48.7 | Math/logic, thinking trace, 32k ctx |
| **Vision (large)** | gemma-4-26b-a4b | cerberus | 104 | MoE A4B+MTP+vision, coexists with coder |
| **Overnight Max-Q** | qwen3-235b-overnight | cerberus | 17.5 | 235B MoE, perfect 5/5 quality, 32k ctx |
| **Embeddings** | qwen3-embed | hephaestus | 2.9 docs/s | CPU, always-on, 1024-dim |
| **Reranker** | bge-reranker-v2-m3 | delphi | 97 docs/s | Persistent, warmup at startup |

---

## 2. LiteLLM Model Aliases (Virtual Routing)

Create **virtual model names** in LiteLLM so agents reference roles, not specific models. This lets you hot-swap models without changing agent code:

```yaml
# Add to LiteLLM helmrelease model_list:

# ── Virtual aliases (role-based routing) ──
- model_name: planner          # CEO/strategist
  litellm_params:
    model: openai/gpt-oss-120b
    api_base: http://10.10.10.218:8080/v1
    api_key: os.environ/CERBERUS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: coder-fast       # Fast execution (talos)
  litellm_params:
    model: openai/gpt-oss-20b
    api_base: http://10.10.10.81:8080/v1
    api_key: os.environ/TALOS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: coder-quality    # High-quality coding (talos MoE)
  litellm_params:
    model: openai/ornith-35b
    api_base: http://10.10.10.81:8080/v1
    api_key: os.environ/TALOS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: coder-agentic    # Multi-file agentic coding (talos)
  litellm_params:
    model: openai/devstral-24b
    api_base: http://10.10.10.81:8080/v1
    api_key: os.environ/TALOS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: coder-small      # Quick tasks (hephaestus)
  litellm_params:
    model: openai/ornith-9b
    api_base: http://10.10.10.65:8080/v1
    api_key: os.environ/HEPHAESTUS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: reasoning        # Math/logic (delphi)
  litellm_params:
    model: openai/deepseek-r1-14b
    api_base: http://10.10.10.18:8080/v1
    api_key: os.environ/DELPHI_LLAMASWAP_API_KEY
    timeout: 600

- model_name: general          # General chat (delphi)
  litellm_params:
    model: openai/mistral-small-3.2-24b
    api_base: http://10.10.10.18:8080/v1
    api_key: os.environ/DELPHI_LLAMASWAP_API_KEY
    timeout: 600

- model_name: vision           # Image understanding (hephaestus fast)
  litellm_params:
    model: openai/gemma-4-12b
    api_base: http://10.10.10.65:8080/v1
    api_key: os.environ/HEPHAESTUS_LLAMASWAP_API_KEY
    timeout: 600

- model_name: overnight        # Max quality batch (cerberus 235B)
  litellm_params:
    model: openai/qwen3-235b-overnight
    api_base: http://10.10.10.218:8080/v1
    api_key: os.environ/CERBERUS_LLAMASWAP_API_KEY
    timeout: 1200
```

Agents now reference `model: planner`, `model: coder-fast`, etc. — LiteLLM routes to the right host.

---

## 3. Agent Swarm Topology (pi-swarm)

Using **pi-swarm** (hierarchical, built on pi.dev) with per-tier model assignment:

```
                    ┌─────────────────────┐
                    │   ORCHESTRATOR      │
                    │   model: planner    │  ← gpt-oss-120b (cerberus)
                    │   (strategic CEO)   │
                    └──┬──┬──┬──┬──┬─────┘
                       │  │  │  │  │
            ┌──────────┘  │  │  │  └──────────┐
            │      ┌──────┘  │  └──────┐      │
     ┌──────▼──┐ ┌─▼─────┐ ┌─▼──────┐ ┌▼──────┐ ┌▼──────┐
     │ Dev Lead│ │Plan   │ │Review  │ │Docs   │ │Over-  │
     │coder-   │ │reason-│ │coder-  │ │general│ │night  │
     │quality  │ │ing    │ │fast    │ │       │ │       │
     └──┬──┬──┘ └───────┘ └───────┘ └───────┘ └───────┘
        │  │
    ┌───▼┐ ┌▼────┐ ┌──────────┐ ┌──────────┐
    │Impl│ │Test │ │Refactor  │ │Debug     │
    │coder-│ │coder-│ │coder-  │ │reasoning │
    │fast│ │small│ │agentic  │ │          │
    └────┘ └────┘ └──────────┘ └──────────┘
```

### pi-swarm configuration (custom teams for coding)

```typescript
import { Swarm } from "pi-swarm";

const swarm = new Swarm({
  name: "Homelab Fleet",

  // CEO: highest intelligence (cerberus gpt-oss-120b)
  orchestratorModel: {
    provider: "openai",
    model: "planner",
    apiBase: "https://litellm.${SECRET_DOMAIN}/v1",
    apiKey: process.env.LITELLM_MASTER_KEY,
  },

  // Team leads: quality coding (cerberus coder, HIP backend)
  teamLeadModel: {
    provider: "openai",
    model: "coder-quality",
    apiBase: "https://litellm.${SECRET_DOMAIN}/v1",
    apiKey: process.env.LITELLM_MASTER_KEY,
  },

  // Workers: fast execution (talos gpt-oss-20b / hephaestus ornith-9b)
  workerModel: {
    provider: "openai",
    model: "coder-fast",
    apiBase: "https://litellm.${SECRET_DOMAIN}/v1",
    apiKey: process.env.LITELLM_MASTER_KEY,
  },

  costBudget: 0,        // local models = free
  maxConcurrentAgents: 3, // 3 hosts can serve in parallel (talos + hephaestus + delphi)
  config: {
    teams: [
      {
        lead: { id: "dev-lead", name: "Dev Lead", role: "cto",
          systemPrompt: "Break coding tasks into implementation + tests + review. Delegate to workers.",
          model: { provider: "openai", model: "coder-quality" } },
        workers: [
          { id: "impl", name: "Implementer", role: "backend",
            systemPrompt: "Write clean, tested code. Use coder-fast for speed.",
            model: { provider: "openai", model: "coder-fast" } },
          { id: "test", name: "Tester", role: "qa",
            systemPrompt: "Write tests and verify edge cases. Use coder-small.",
            model: { provider: "openai", model: "coder-small" } },
          { id: "review", name: "Reviewer", role: "security",
            systemPrompt: "Review code for bugs, security, and style. Use reasoning for complex logic.",
            model: { provider: "openai", model: "reasoning" } },
        ],
      },
      {
        lead: { id: "plan-lead", name: "Planning Lead", role: "cpo",
          systemPrompt: "Plan architecture and break down complex projects. Use reasoning model.",
          model: { provider: "openai", model: "reasoning" } },
        workers: [
          { id: "architect", name: "Architect", role: "pm",
            systemPrompt: "Design system architecture. Consider tradeoffs.",
            model: { provider: "openai", model: "planner" } },
          { id: "writer", name: "Tech Writer", role: "tech_writer",
            systemPrompt: "Write clear documentation and READMEs.",
            model: { provider: "openai", model: "general" } },
        ],
      },
    ],
  },
});

// Run a task
const result = await swarm.run("Build a REST API for inventory management with auth, tests, and docs");
```

### Goose alternative (orchestration mode)

Goose is better for **interactive, file-level coding** (it has a desktop CLI, file editing, terminal access). Use Goose when you want hands-on coding with model switching:

```yaml
# ~/.config/goose/config.yaml
GOOSE_PROVIDER: openai
GOOSE_MODEL: coder-quality         # default execution model
GOOSE_PLANNER_MODEL: planner       # strategic planning
GOOSE_PLANNER_PROVIDER: openai

# Set base URL to LiteLLM
OPENAI_BASE_URL: https://litellm.${SECRET_DOMAIN}/v1
OPENAI_API_KEY: ${LITELLM_MASTER_KEY}
```

Then in a Goose session:
```
# Goose uses planner (gpt-oss-120b) for strategy, coder-quality for execution
> Plan: refactor the auth module into a service pattern, then implement

# Switch models mid-session for specific tasks
> /model coder-fast      # switch to gpt-oss-20b for quick edits
> /model reasoning       # switch to deepseek-r1 for a tricky bug
> /model vision          # switch to gemma-4-12b to analyze a screenshot
```

**Goose orchestration** (parallel subagents):
```
> Research the codebase in parallel:
  - Summarize the project structure and dependencies (use coder-small)
  - Find all API endpoints and their auth patterns (use coder-fast)
  - Identify TODO comments and known issues (use coder-small)
Then: implement the new auth service (use coder-agentic)
Finally: write tests and do a security review in parallel (use coder-small + reasoning)
```

---

## 4. RAG Pipeline (Context Retrieval)

For codebase-aware agents, use the fleet's embedding + rerank endpoints:

```
User Query
    │
    ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ qwen3-embed     │────▶│ bge-reranker     │────▶│ Chat Model      │
│ (hephaestus)    │     │ (delphi)         │     │ (any host)      │
│ 1024-dim        │     │ 97 docs/s        │     │ + retrieved ctx │
│ CPU, always-on  │     │ persistent       │     │                 │
└─────────────────┘     └──────────────────┘     └─────────────────┘
```

### Implementation (LiteLLM as unified RAG endpoint)

All endpoints are already in LiteLLM:
- `POST /v1/embeddings` with `model: qwen3-embed` → hephaestus
- `POST /rerank` with `model: bge-reranker-v2-m3` → delphi
- `POST /v1/chat/completions` with any model → routed to best host

```python
# RAG pipeline (pseudocode)
import openai

client = openai.OpenAI(
    base_url="https://litellm.${SECRET_DOMAIN}/v1",
    api_key=os.environ["LITELLM_MASTER_KEY"]
)

# 1. Embed the query
query_embedding = client.embeddings.create(
    model="qwen3-embed",
    input=user_query
).data[0].embedding

# 2. Vector search (use your vector DB: Qdrant, pgvector, etc.)
# Retrieve top-50 chunks, then rerank
candidates = vector_db.search(query_embedding, top_k=50)

# 3. Rerank (delphi bge-reranker)
rerank_response = httpx.post(
    f"{LITELLM_BASE}/rerank",
    json={"model": "bge-reranker-v2-m3", "query": user_query, "documents": candidates}
)
ranked = sorted(rerank_response.json()["results"], key=lambda x: x["relevance_score"], reverse=True)
top_context = [candidates[r["index"]] for r in ranked[:10]]

# 4. Generate with context (routed to best model for the task)
response = client.chat.completions.create(
    model="coder-quality",  # or planner, reasoning, etc.
    messages=[
        {"role": "system", "content": f"Context:\n{top_context}"},
        {"role": "user", "content": user_query}
    ]
)
```

---

## 5. Overnight Batch Processing

Use the **qwen3-235b-overnight** (cerberus, 17.5 t/s, 5/5 quality) for complex tasks that don't need real-time latency:

### Hermes cron scheduling (already running on cerberus)

```
# Hermes cron + Kanban board for overnight tasks

Schedule (cron):
  - 02:00 daily: "Review yesterday's commits, write a changelog summary"
    → model: overnight (235B)
    → post result to Discord #general via Hermes

  - 03:00 weekly (Sunday): "Plan next week's architecture goals based on
    the current codebase state and recent issues"
    → model: planner (120B) for analysis
    → model: overnight (235B) for the detailed plan
    → create Kanban cards in Hermes

  - On-demand via Discord: "@hermes plan: <complex task>"
    → Hermes queues on Kanban board
    → Executes overnight with 235B
    → Posts result to Discord when done
```

### Overnight workflow (pi-swarm batch mode)

```typescript
// overnight-plan.ts — runs via cron at 02:00
const swarm = new Swarm({
  orchestratorModel: { provider: "openai", model: "overnight" },  // 235B
  teamLeadModel:     { provider: "openai", model: "planner" },    // 120B
  workerModel:       { provider: "openai", model: "coder-quality" }, // 80B
  maxConcurrentAgents: 1,  // serial — overnight doesn't need parallel
  config: { /* custom planning team */ },
});

const result = await swarm.run(
  `Analyze the home-ops repository. Identify 3 architectural improvements ` +
  `that would improve reliability. For each, write a detailed implementation ` +
  `plan with specific files to change. Output as markdown.`
);

// Post to Discord via Hermes
await hermes.send("discord", "general", result.summary);
```

---

## 6. Hermes Integration (Messaging + Scheduling)

Hermes (on cerberus) is the **human interface** — it connects Discord/Telegram to the agent fleet:

```
Discord/Telegram/User
        │
        ▼
┌───────────────────┐
│  Hermes Gateway   │  (cerberus, already running)
│  - Discord #general│
│  - Cron scheduler  │
│  - Kanban board    │
│  - Hooks           │
└───────┬───────────┘
        │
        ▼
┌───────────────────┐
│  Agent Router     │  (decides which model/agent to use)
│  - Simple Q?      │→ coder-small (hephaestus ornith-9b, 136 t/s)
│  - Code task?     │→ coder-fast (talos gpt-oss-20b, 350 t/s)
│  - Complex plan?  │→ planner (cerberus gpt-oss-120b, 57 t/s)
│  - Math/logic?    │→ reasoning (delphi deepseek-r1-14b, 48.7 t/s)
│  - Image?         │→ vision (hephaestus gemma-4-12b, 136 t/s)
│  - Overnight?     │→ overnight (cerberus 235B, 17.5 t/s)
│  - General chat?  │→ general (delphi mistral-small-3.2-24b)
└───────────────────┘
```

### Hermes hook example (auto-route by task type)

```python
# ~/.hermes/hooks/route_to_model.py
import re

def route_model(message: str) -> str:
    msg = message.lower()
    if any(w in msg for w in ["plan", "architect", "design", "strategy"]):
        return "planner"           # gpt-oss-120b
    elif any(w in msg for w in ["debug", "solve", "calculate", "prove"]):
        return "reasoning"         # deepseek-r1-14b
    elif any(w in msg for w in ["image", "screenshot", "diagram"]):
        return "vision"            # gemma-4-12b
    elif any(w in msg for w in ["overnight", "batch", "deep analysis"]):
        return "overnight"         # 235B
    elif any(w in msg for w in ["code", "implement", "refactor", "function"]):
        return "coder-fast"        # gpt-oss-20b
    else:
        return "general"           # mistral-small-3.2-24b
```

---

## 7. Concurrency Model (Key Constraint)

**Each host serves ONE model at a time** (llama-swap). The fleet's parallel capacity:

| Parallel agents | Strategy |
|---|---|
| **1 agent** | Any model, full speed |
| **2 parallel** | talos (coder) + hephaestus (coder/vision) — different hosts |
| **3 parallel** | talos + hephaestus + delphi — max independent parallelism |
| **4 parallel** | All 4 hosts — but cerberus switches between its 4 models |
| **Overnight** | cerberus 235B alone (evicts everything, 17.5 t/s) |

**Rule: reads can be parallel (different hosts), writes should be sequential (same host).**

Use Goose's orchestration or pi-swarm's `maxConcurrentAgents: 3` to respect this:
- Worker A → talos (coder-fast)
- Worker B → hephaestus (coder-small)
- Worker C → delphi (reasoning or general)
- CEO → cerberus (planner, only when workers report back)

---

## 8. Implementation Roadmap

### Phase 1: LiteLLM aliases (1 hour)
- Add the 9 virtual model aliases (planner, coder-fast, coder-quality, etc.) to the helmrelease
- Commit, push, Flux reconciles
- Test: `curl https://litellm.${SECRET_DOMAIN}/v1/chat/completions -d '{"model":"planner",...}'`

### Phase 2: Goose setup (30 min)
- Install Goose on your workstation
- Configure `~/.config/goose/config.yaml` with LiteLLM base URL
- Set planner model = planner, default = coder-quality
- Test: `goose session` → ask it to plan + implement a feature

### Phase 3: pi-swarm setup (1 hour)
- Clone pi-swarm, npm install, build
- Configure `.env` with `OPENAI_API_KEY` = LiteLLM master key, `OPENAI_BASE_URL` = LiteLLM URL
- Create custom teams (dev team + planning team) as shown above
- Test: `npx tsx examples/custom-team.ts "Build a REST API"`

### Phase 4: RAG pipeline (2 hours)
- Deploy a vector DB (Qdrant or pgvector — you already have cloudnative-pg)
- Index your codebase: embed all files via `qwen3-embed` → store in vector DB
- Add rerank step via `bge-reranker-v2-m3`
- Connect to Goose/pi-swarm as a tool (retrieval before generation)

### Phase 5: Hermes integration (2 hours)
- Add a Hermes hook that routes Discord messages to the right model via LiteLLM
- Set up cron jobs for overnight 235B tasks
- Use the Kanban board to track multi-step agent tasks
- Test: `@hermes plan: review our k8s manifests for security issues` → routes to planner

### Phase 6: Overnight automation (1 hour)
- Write a pi-swarm overnight script (235B for planning, 120B for analysis)
- Schedule via Hermes cron at 02:00
- Post results to Discord #general
- Create Kanban cards for actionable items

---

## 9. Recommended Tool Stack

| Layer | Tool | Why |
|---|---|---|
| **API gateway** | LiteLLM (already deployed) | Unified OpenAI-compatible API, 15 models |
| **Interactive coding** | Goose (Block/AAIF) | Desktop CLI, file editing, multi-model switching, orchestration |
| **Batch orchestration** | pi-swarm | Hierarchical CEO→Lead→Worker, per-tier models, custom teams |
| **Agent toolkit** | Pi.dev (already using!) | Unified LLM API, CLI, TUI, skills, extensions |
| **RAG: embeddings** | qwen3-embed (hephaestus) | Always-on, CPU, 1024-dim |
| **RAG: rerank** | bge-reranker-v2-m3 (delphi) | Persistent, 97 docs/s, warmup at startup |
| **Vector DB** | pgvector (on existing cloudnative-pg) | No new infra, SQL-queryable |
| **Messaging/scheduling** | Hermes (already on cerberus) | Discord, cron, Kanban, hooks |
| **Remote terminal** | Termix (already in k8s) | Guacamole-based, browser access to hosts |
| **Overnight quality** | qwen3-235b-overnight (cerberus) | 5/5 quality, 17.5 t/s, runs while you sleep |

---

## 10. The "Dream Workflow" Example

```
You (Discord): "@hermes Plan and implement a health-check endpoint
                for all llama-swap hosts, with Prometheus metrics"

Hermes:
  1. Routes to planner (gpt-oss-120b, cerberus)
     → Analyzes the request, creates a 5-step plan
     → Posts plan to Discord, creates Kanban cards

  2. You approve: "@hermes go"

Hermes spawns pi-swarm:
  Orchestrator (planner/120b):
    → Delegates to Dev Lead (coder-quality/80b, cerberus HIP)
      → Worker: Implementer (coder-fast/20b, talos)
         → Writes the health-check endpoint code
      → Worker: Tester (coder-small/9b, hephaestus)
         → Writes unit tests
    → Delegates to Review Lead (reasoning/r1-14b, delphi)
      → Reviews code for edge cases
    → Delegates to Docs Lead (general/mistral-24b, delphi)
      → Writes README updates

  3. Results posted to Discord, Kanban cards updated

  4. Overnight: cron triggers 235B to do a deep security review
     of the new code → posts findings to Discord at 06:00
```

**Total elapsed: ~5 minutes (interactive) + overnight (235B review)**
**Cost: $0 (all local)**
**Models used: 7 of 15 (planner, coder-quality, coder-fast, coder-small, reasoning, general, overnight)**
