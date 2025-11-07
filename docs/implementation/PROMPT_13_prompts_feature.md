# PROMPT_13: Prompts Feature Module

**Goal:** Implement `MCPClient.Prompts` for listing and retrieving prompt templates.

**Duration:** ~30 minutes | **Dependencies:** PROMPT_01-10

---

## Implementation

**File:** `lib/mcp_client/prompts.ex`

**API:**
- `list/2` - List available prompts
- `get/4` - Get prompt with arguments

**Structs:**
- `Prompt` - {name, description, arguments}
- `PromptArgument` - {name, description, required}
- `GetPromptResult` - {description, messages}
- `PromptMessage` - {role, content}

**Reference:** CLIENT_FEATURES.md § MCPClient.Prompts

---

## Tests

**File:** `test/mcp_client/prompts_test.exs`

---

**Next:** PROMPT_14 - Sampling, Roots, Logging modules
