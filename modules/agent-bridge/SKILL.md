---
name: agent-bridge
description: "Use only for explicit legacy cross-agent channel open/connect/send/read/close workflows under Super Brain; normal subagent execution, review, testing, and verification use the single-agent workflow instead."
---

# Agent Bridge

Legacy/manual-only Agent Bridge compatibility: not the default workflow for subagent execution, review, verification, testing, or evidence.

`agent-bridge` is a legacy/manual-only compatibility protocol for explicit cross-agent channel commands under Super Brain command. It is not the default workflow for subagent execution, review, verification, testing, or evidence.

## Default Replacement

For normal requests such as letting a subagent inspect, modify, test, audit, verify, or produce evidence inside one agent host, use `references/single-agent-subagent-workflow.md`. Channel/inbox/wait/ack/target-mode is reserved for explicit cross-agent channel communication.

## Purpose

Use this skill only when the user explicitly asks for multi-agent coordination, agent-to-agent relay, failover, or a selected agent/brain mode. It is not part of the cold-start path and must not wake for ordinary chat, ordinary `继续`, normal task status, or single-agent coding.

## Isolation Rule

Agent Bridge must not pollute Super Brain's durable shared memory or primary task state.

Default bridge state lives only under:

```text
memory/workspace/agent-bridge/
```

Do not write `memory/shared`, `graph.jsonl`, ADRs, accepted constraints, status-card, project baselines, or primary task checkpoint from bridge messages unless the user explicitly asks Super Brain to adopt/commit a bridge result. Candidate agent outputs remain advisory until Commander/Super Brain reviews and admits a compact verified summary through governed scripts.

## Communication Model

Agents do not free-chat through long shared transcripts. They exchange compact protocol packets through Super Brain:

```text
User → Super Brain Commander → agent-bridge session → agent task packet
Agent result card → Super Brain review/relay → next agent or user
```

Each packet should include:

```json
{
  "bridgeId": "bridge-...",
  "taskId": "task-...",
  "sender": "super-brain|agent-a",
  "receiver": "agent-b|user|super-brain",
  "intent": "assign|reply|verify|handoff|failover|close",
  "summary": "compact task/result summary",
  "evidence": ["short evidence paths or ids"],
  "blockers": ["short blockers"],
  "nextAction": "next concrete action",
  "status": "open|waiting|done|blocked|failed"
}
```

## Stability and Failover

Every bridge session must persist enough state for interruption recovery:

- bridge id and task id
- commander and selected brain/lead agent
- participant list and permissions
- current owner
- task brief
- message cards
- heartbeat times
- failed/stale agents
- failover history
- next action

If an agent goes stale or fails, Super Brain may create a failover packet for another agent or a new conversation. The failover packet must include the compact task brief, completed work, evidence, blockers, constraints, and next action. Never require raw old chat replay for failover.

## Modes

- `commander`: Super Brain is the total brain and all agent communication routes through it.
- `delegate`: user selects a lead agent; Super Brain routes and audits.
- `roundtable`: multiple agents contribute cards; Super Brain summarizes and decides.

The user chooses the mode. If unclear, ask a short choice question instead of starting agent dialogue.

## Safety

- Read-only by default for other agents.
- Only Super Brain/Commander may mark a bridge result as authoritative.
- No direct code edit authority is granted by bridge packets.
- No secrets or raw long transcripts in bridge messages.
- Use locks and atomic JSON writes through package helpers.
- Bridge packets are evidence/advisory until explicitly adopted.

## Typical Use

```text
Open bridge session → send assignment → receive agent card → relay/verify → failover if stale → dispatch a handoff packet to another agent/new session → close/adopt result if approved
```

## Channel Mode

For user-approved cross-agent conversation, use `agent-bridge-channel.ps1` instead of UI/session injection. A channel binds participants and optional target session ids under `memory/workspace/agent-bridge/channels/<channelId>.json`; the controlled/sub-agent should `Open` first, report the channel id once with `waiting_connect`, then use `WaitConnect` so it reports `connected` once after the main/operator agent connects. After that the sub-agent should use `WaitInbox` as a bounded silent wait: no repeated waiting output, no infinite watch loop, and no `Close` unless the main/user explicitly asks. If `WaitConnect` or `WaitInbox` returns an idle wait status such as `idle_waiting_connect` or `idle_waiting_message`, treat it as quiet idle state, not blocked, failed, completed, or a reason to post another progress update. The main/operator agent `Connect`s once with an alias/name, and `active-agent-bridge-channel.json` remembers the active channel until the user explicitly closes it. Later user wording such as `向子agent发送信息：你好` should resolve the active alias and use `SendAndWait` so the main agent sends, waits for a bounded reply, and reports the reply or timeout without making the user ask separately. Channel messages are advisory and isolated; they do not become durable shared memory or code authority unless Commander explicitly adopts a result. Channel target mode uses bounded waits only; no infinite watch loop is allowed.

## Short-command Protocol

User short commands must be enough; do not ask the user to paste long target-mode instructions. In this protocol, `子agent` / `sub-agent` means the current controlled target conversation itself, not a request to launch another nested agent, worker, explorer, goal, or helper. The controlled session must run `agent-bridge-channel.ps1` locally; never create a Tesla/worker/subagent inside the sub-agent session just to open the channel.

- `开启子agent通道` / `打开子agent通道`: in the current controlled/sub-agent session, run `Open` locally as a fresh-channel command (do not resolve or reuse an existing active/last channel unless the user explicitly supplied that channel id; do not launch a nested agent/worker/helper), report only `channelId` plus `status=waiting_connect`, and treat Open success as a persistent target-mode wait state, not completion. Then continue with `WaitConnect` and `WaitInbox`. If the wait returns `idle_waiting_connect` or `idle_waiting_message`, remain quiet and do not mark the goal blocked, paused, failed, or complete; do not emit repeated status messages. Do not `Close` after reporting the channel id, after a timeout/idle wait, after no messages, or after the visible reply ends.
- `连接子agent通道：<channelId>，别名 <alias>`: in the main/operator session, run `Connect`, write active alias state, and keep the channel open.
- `向<alias>发送信息：<message>` / `给<alias>发消息：<message>`: in the main/operator session, resolve the active alias and run `SendAndWait` with bounded waiting.
- `读取<alias>通道回复`: run `WaitReply` against the active channel.
- `关闭<alias>通道`: only this explicit close wording may run `Close` and clear active state.

Open success is not completion; it is a persistent target-mode wait state. 开启成功不等于任务完成；开启成功后必须保持目标模式等待，不得自动关闭。

Message reply is not completion either: after the sub-agent receives one message and sends one reply, it must not say `Goal completed`, `目标完成`, or equivalent completion text, and must not end/close target mode. It should stay in Agent Bridge target mode and continue `WaitInbox` until the main/user explicitly sends a close command.

## Helper Scripts

- `agent-bridge.ps1`: isolated session state, cards, heartbeat, failover, adopt, close.
- `agent-bridge-channel.ps1`: shared channel conversations with Open/Connect/WaitConnect/Send/Inbox/WaitInbox/Ack/WaitReply/SendAndWait/Active/Close/Status, target-session routing, compact evidence cards, same-channel replies, and silent subordinate wait states.
- `agent-bridge-dispatch.ps1`: generates target-agent/new-session startup prompts and compact handoff/failover packets; it does not send externally by default.
- `agent-bridge-permissions.ps1`: manages role permissions (`reader`, `advisor`, `code-suggester`, `adopt-requester`, `commander`) and operation checks.
- `agent-bridge-queue.ps1`: lightweight non-real-time queue with Enqueue/Poll/Ack/Status/Clear under `memory/workspace/agent-bridge/`.
