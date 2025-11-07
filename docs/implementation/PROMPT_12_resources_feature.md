# PROMPT_12: Resources Feature Module

**Goal:** Implement `McpClient.Resources` for reading/subscribing to server resources.

**Duration:** ~45 minutes | **Dependencies:** PROMPT_01-10

---

## Implementation

**File:** `lib/mcp_client/resources.ex`

**API:**
- `list/2` - List available resources
- `read/3` - Read resource contents
- `subscribe/3` - Subscribe to resource updates
- `unsubscribe/3` - Unsubscribe from resource
- `list_templates/2` - List resource URI templates

**Structs:**
- `Resource` - {uri, name, description, mimeType}
- `ResourceContents` - {contents, uri}
- `ResourceTemplate` - {uriTemplate, name, description, mimeType}

**Reference:** CLIENT_FEATURES.md § McpClient.Resources, PROTOCOL_DETAILS.md § resources/*

---

## Tests

**File:** `test/mcp_client/resources_test.exs`

Test all five functions with success/error cases, validation, and notification handling.

---

## Success Criteria

✅ All tests pass | ✅ No warnings | ✅ Format/Credo clean

---

**Next:** PROMPT_13 - Prompts feature
