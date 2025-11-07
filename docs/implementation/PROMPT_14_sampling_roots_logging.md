# PROMPT_14: Sampling, Roots, and Logging Modules

**Goal:** Implement remaining MCP feature modules.

**Duration:** ~45 minutes | **Dependencies:** PROMPT_01-10

---

## 1. MCPClient.Sampling

**File:** `lib/mcp_client/sampling.ex`

**API:** `create_message/3` - Request LLM completion from server

**Structs:**
- `SamplingRequest` - {messages, modelPreferences, systemPrompt, temperature, maxTokens, ...}
- `SamplingResult` - {role, content, model, stopReason}

---

## 2. MCPClient.Roots

**File:** `lib/mcp_client/roots.ex`

**API:** `list/2` - List client's filesystem roots

**Struct:** `Root` - {uri, name}

**Note:** Roots are typically configured at connection start, this module queries configured roots.

---

## 3. MCPClient.Logging

**File:** `lib/mcp_client/logging.ex`

**API:** `set_level/3` - Set minimum server log level

**Struct:** `LogMessage` - {level, logger, data}

**Note:** Log messages arrive via notifications (handled by NotificationRouter).

---

## Tests

**Files:**
- `test/mcp_client/sampling_test.exs`
- `test/mcp_client/roots_test.exs`
- `test/mcp_client/logging_test.exs`

---

**Next:** PROMPT_15 - Integration tests for all features
