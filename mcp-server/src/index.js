import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execSync } from "child_process";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const CORE_SCRIPT = join(__dirname, "..", "..", "scripts", "lab-manager.ps1");

// Input guards — reject shell-dangerous characters before they reach the command
// string. Valid GitHub URLs / env names / regions pass through unchanged.
const SAFE_REPO_URL = /^https:\/\/[A-Za-z0-9._\/-]+$/;
const SAFE_TOKEN = /^[A-Za-z0-9._-]+$/;
function assertSafe(value, pattern, label) {
  if (value === undefined || value === null) return;
  if (typeof value !== "string" || !pattern.test(value)) {
    throw new Error(`Invalid ${label}: contains disallowed characters`);
  }
}

const server = new Server(
  { name: "lab-lifecycle", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

// Tool definitions
const TOOLS = [
  {
    name: "doctor",
    description: "Validate all prerequisites for lab deployment (Azure CLI, azd, extensions, login status, RBAC)",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "analyze_lab",
    description: "Inspect a lab GitHub repo and report its deployment requirements, structure, and readiness",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
      },
      required: ["repo_url"],
    },
  },
  {
    name: "prepare_lab",
    description: "Check a lab repo's deployment readiness: detects missing azure.yaml, infra/, Docker issues, and provides step-by-step remediation guidance",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
      },
      required: ["repo_url"],
    },
  },
  {
    name: "outline_lab",
    description: "Break a lab's instructions into ordered modules/chapters. Returns each module's title, kind (deploy/configure/verify/cleanup), runnable commands, and the manual verification steps a presenter must perform by hand. Use this to drive a guided, module-by-module walkthrough with verification gates between modules.",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
      },
      required: ["repo_url"],
    },
  },
  {
    name: "deploy_lab",
    description: "Clone, configure, provision, and deploy a Build or Ignite lab to Azure (event auto-detected from the repo URL)",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
        env_name: { type: "string", description: "Optional azd environment name" },
        location: { type: "string", description: "Azure region (default: eastus2)" },
      },
      required: ["repo_url"],
    },
  },
  {
    name: "destroy_lab",
    description: "Tear down all Azure resources for a deployed lab (requires confirmation)",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
        env_name: { type: "string", description: "Optional azd environment name" },
        force: { type: "boolean", description: "Skip confirmation (default: false)" },
      },
      required: ["repo_url"],
    },
  },
  {
    name: "list_labs",
    description: "Show all tracked lab deployments and their current status",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "get_lab_status",
    description: "Check the current deployment status of a specific lab",
    inputSchema: {
      type: "object",
      properties: {
        repo_url: { type: "string", description: "GitHub URL of the lab repository" },
      },
      required: ["repo_url"],
    },
  },
];

// List tools
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

// Execute tools
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  let action, psArgs;

  try {
    assertSafe(args?.repo_url, SAFE_REPO_URL, "repo_url");
    assertSafe(args?.env_name, SAFE_TOKEN, "env_name");
    assertSafe(args?.location, SAFE_TOKEN, "location");
  } catch (error) {
    return { content: [{ type: "text", text: `Error: ${error.message}` }], isError: true };
  }

  switch (name) {
    case "doctor":
      action = "doctor";
      psArgs = "";
      break;
    case "analyze_lab":
      action = "analyze";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      break;
    case "prepare_lab":
      action = "prepare";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      break;
    case "outline_lab":
      action = "outline";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      break;
    case "deploy_lab":
      action = "deploy";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      if (args.env_name) psArgs += ` -EnvName "${args.env_name}"`;
      if (args.location) psArgs += ` -Location "${args.location}"`;
      break;
    case "destroy_lab":
      action = "destroy";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      if (args.env_name) psArgs += ` -EnvName "${args.env_name}"`;
      if (args.force) psArgs += " -Force";
      break;
    case "list_labs":
      action = "list";
      psArgs = "";
      break;
    case "get_lab_status":
      action = "status";
      psArgs = `-RepoUrl "${args.repo_url}"`;
      break;
    default:
      return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
  }

  const cmd = `pwsh -NoProfile -NonInteractive -Command "& '${CORE_SCRIPT}' -Action ${action} ${psArgs}"`;

  try {
    const output = execSync(cmd, {
      encoding: "utf-8",
      timeout: 600000, // 10 min timeout for deploys
      env: { ...process.env, PATH: `${process.env.LOCALAPPDATA}\\Programs\\Azure Dev CLI;${process.env.PATH}` },
    });
    return { content: [{ type: "text", text: output }] };
  } catch (error) {
    const output = error.stdout || error.stderr || error.message;
    return { content: [{ type: "text", text: `Error: ${output}` }], isError: true };
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(console.error);
