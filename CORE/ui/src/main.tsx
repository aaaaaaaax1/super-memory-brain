import "./styles.css";
import {
  Activity,
  BrainCircuit,
  ClipboardList,
  HeartHandshake,
  History,
  Lightbulb,
  MoreHorizontal,
  Orbit,
  Plus,
  Route,
  Scale,
  Search,
  Sparkles,
  StickyNote,
  Trash2,
  UserRound,
  X
} from "lucide-react";

"use strict";

(function () {
  const rawCreateElement = React.createElement;
  const { useCallback, useEffect, useMemo, useRef, useState } = React;

  function normalizeVisibleText(value) {
    return typeof value === "string" ? value
      .replace(/\u0000/g, "")
      .replace(/[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, " ")
      .replace(/\s{2,}/g, " ") : "";
  }

  function hasDisplayIntegrityIssue(value) {
    const normalized = normalizeVisibleText(value);
    const hasQuestionRun = /\?{3,}/.test(normalized);
    const hasReplacementRun = (normalized.match(/\uFFFD/g) || []).length >= 2;
    const hasMojibakeRun = /(?:Ã.|Â.|â.|æ.|å.|ç.|ä.){3,}/.test(normalized);
    return hasQuestionRun || hasReplacementRun || hasMojibakeRun;
  }

  function displayText(value) {
    const normalized = normalizeVisibleText(value);
    return hasDisplayIntegrityIssue(normalized) ? "内容编码异常，等待修复" : normalized;
  }

  function cardHasDisplayIntegrityIssue(card) {
    if (!card || typeof card !== "object") return false;
    const candidates = [card.title];
    const payload = card.payload;
    if (payload && typeof payload === "object") {
      Object.values(payload).forEach((value) => {
        if (typeof value === "string") candidates.push(value);
        if (Array.isArray(value)) candidates.push(...value.filter((item) => typeof item === "string"));
      });
    }
    return candidates.some(hasDisplayIntegrityIssue);
  }

  function sanitizeRenderChild(value) {
    if (Array.isArray(value)) return value.map(sanitizeRenderChild);
    return typeof value === "string" ? displayText(value) : value;
  }

  function h(type, props, ...children) {
    let nextProps = props;
    if (props && typeof props === "object" && typeof type === "string") {
      const cleaned = {};
      let changed = false;
      ["title", "placeholder", "aria-label", "aria-description"].forEach((key) => {
        if (typeof props[key] !== "string") return;
        const value = displayText(props[key]);
        if (value !== props[key]) {
          cleaned[key] = value;
          changed = true;
        }
      });
      if (["input", "textarea", "option"].includes(type) && typeof props.value === "string") {
        const value = displayText(props.value);
        if (value !== props.value) {
          cleaned.value = value;
          changed = true;
        }
      }
      if (changed) nextProps = Object.assign({}, props, cleaned);
    }
    return rawCreateElement(type, nextProps, ...children.map(sanitizeRenderChild));
  }

  const KINDS = {
    note: {
      label: "笔记",
      hint: "临时想法、资料和待办",
      description: "用来记录临时想法、资料摘要和待办事项。需要长期遵守的要求，请放到“偏好”或“决策”。"
    },
    preference: {
      label: "偏好",
      hint: "我该怎样配合你",
      description: "用来记录你长期确认的协作习惯，例如汇报方式、审核深度和表达风格。"
    },
    experience: {
      label: "经验",
      hint: "做对的方法和踩过的坑",
      description: "用来记录做法、结果和教训，让相同问题下次少走弯路。"
    },
    decision: {
      label: "决策",
      hint: "已经确认的方案和要求",
      description: "用来记录已经定下来的方案、完成标准和不能违背的要求，后续相关任务会优先参考。"
    },
    procedure: {
      label: "流程",
      hint: "以后可以照着做的步骤",
      description: "用来保存可复用的操作步骤，例如测试、打包、发布和验收。"
    },
    reflection: {
      label: "反思",
      hint: "发现的问题和改进想法",
      description: "用来记录还需要验证的问题或改进方案；确认有效后再转成经验、偏好或决策。"
    }
  };

  const MEMORY_CATEGORIES = [
    { key: "memory", label: "记忆", hint: "笔记、资料与待办", description: "收纳临时想法、资料摘要和需要回看的内容。", kinds: ["note"], defaultKind: "note", icon: StickyNote, color: "#9db8ff" },
    { key: "preference", label: "偏好与性格", hint: "我该怎样配合你", description: "收纳协作偏好、表达风格和长期确认的工作方式。", kinds: ["preference"], defaultKind: "preference", icon: HeartHandshake, color: "#7aabff" },
    { key: "experience", label: "经验", hint: "做对的方法与教训", description: "收纳可复用做法、结果与教训，让下次少走弯路。", kinds: ["experience"], defaultKind: "experience", icon: Sparkles, color: "#ff9060" },
    { key: "decision-procedure", label: "决策与流程", hint: "方案、要求与步骤", description: "把已确认的方案、完成标准与可复用步骤放在同一处。", kinds: ["decision", "procedure"], defaultKind: "decision", icon: Scale, color: "#b07aff" },
    { key: "learning", label: "自我学习", hint: "反思与待验证改进", description: "收纳需要验证的发现与改进想法，确认后再沉淀为经验、偏好或决策。", kinds: ["reflection"], defaultKind: "reflection", icon: Lightbulb, color: "#ffb36b" }
  ];

  const ALL_MEMORY_CATEGORY = {
    key: "all",
    label: "全部记忆",
    hint: "所有可用记忆",
    description: "从同一份本机记忆库中查找、整理和打开记录。",
    kinds: undefined,
    defaultKind: "note",
    icon: History,
    color: "#6cddff"
  };

  const memoryCategoryForKind = (kind) => MEMORY_CATEGORIES.find((category) => category.kinds.includes(kind)) || MEMORY_CATEGORIES[0];
  const memoryCategoryByKey = (key) => key === "all" ? ALL_MEMORY_CATEGORY : (MEMORY_CATEGORIES.find((category) => category.key === key) || MEMORY_CATEGORIES[0]);

  const REFLECTION_PROMOTABLE_KINDS = new Set(["preference", "experience", "procedure"]);
  const REFLECTION_NON_PROMOTABLE_KINDS = new Set(["decision", "note", "reflection"]);
  const TRIAL_VERDICT_COPY = {
    passed: { label: "本次试用通过", detail: "有完整证据，可以在你确认后整理为目标记忆。" },
    failed: { label: "本次试用未通过", detail: "这次使用没有达到预期，当前不会改变行为。" },
    inconclusive: { label: "证据不足，继续观察", detail: "目前还不能证明有效，当前不会改变行为。" }
  };

  function isSystemLearningCandidate(card) {
    const payload = card && card.payload;
    return Boolean(
      card
      && card.kind === "reflection"
      && card.authority === "system"
      && card.lifecycle === "proposed"
      && payload
      && payload.candidateState === "staged"
      && list(payload.tags).includes("系统学习候选")
    );
  }

  function learningSuggestionKind(card) {
    const tag = list(card && card.payload && card.payload.tags).find((value) => typeof value === "string" && (value.startsWith("建议：") || value.startsWith("建议:")));
    const kind = tag ? tag.replace(/^建议[：:]/, "").trim().toLowerCase() : "";
    return REFLECTION_PROMOTABLE_KINDS.has(kind) || REFLECTION_NON_PROMOTABLE_KINDS.has(kind) ? kind : "";
  }

  function reflectionTrial(card) {
    const payload = card && card.payload && typeof card.payload === "object" ? card.payload : {};
    const nested = payload.trial && typeof payload.trial === "object" ? payload.trial : {};
    const rawVerdict = card && card.trial && typeof card.trial === "object" ? card.trial.verdict : (payload.trialVerdict || nested.verdict);
    let verdict = Object.prototype.hasOwnProperty.call(TRIAL_VERDICT_COPY, rawVerdict) ? rawVerdict : "inconclusive";
    const rawState = card && card.trial && typeof card.trial === "object" ? card.trial.trialState : (payload.trialState || nested.state);
    const hasReceipt = Boolean((card && card.trial && card.trial.hasReceipt) || payload.trialReceiptHash || nested.receiptHash);
    if (verdict === "passed" && !hasReceipt) verdict = "inconclusive";
    const trialState = ["not_started", "observed", "closed"].includes(rawState) && !(verdict === "inconclusive" && rawState === "closed") ? rawState : (verdict === "inconclusive" ? "observed" : "closed");
    return { verdict, trialState, hasReceipt };
  }

  function learningSourceCardId(card) {
    const reference = list(card && card.evidenceRefs).find((value) => value.startsWith("memory-card:"));
    const match = reference && reference.match(/^memory-card:(.+)@\d+$/);
    return match ? match[1] : "";
  }

  const STARMAP_FILTERS = [
    { key: "all", label: "全部" },
  ].concat(MEMORY_CATEGORIES.map((category) => ({ key: category.key, label: category.label, kinds: category.kinds, color: category.color })));

  const STARMAP_NODE_COLORS = {
    task: "#ffd97a",
    decision: "#b07aff",
    preference: "#7aabff",
    experience: "#ff9060",
    procedure: "#60c8ff",
    note: "#9db8ff",
    reflection: "#ffb36b",
    cluster: "#64778e",
    candidate: "#d29bff",
    history_source: "#ffd97a"
  };

  const STARMAP_RELATION_COLORS = {
    source: "#ffd97a",
    explicit: "#7aabff",
    shared_tag: "#60c8ff",
    migration_source: "#b58cff",
    history_source: "#d29bff",
    cluster: "#758aa4"
  };

  const KIND_ICONS = {
    note: StickyNote,
    preference: HeartHandshake,
    experience: Sparkles,
    decision: Scale,
    procedure: Route,
    reflection: Lightbulb
  };

  function defaultPayload(kind) {
    const common = { tags: [] };
    if (kind === "note") return { schema: "super-brain.card.note.v1", body: "", tags: [], links: [], pinned: false };
    if (kind === "preference") return Object.assign(common, { schema: "super-brain.card.preference.v1", statement: "", conditions: [], confidence: 80, evidenceUses: 0, conflictState: "clear", revalidateAfter: "" });
    if (kind === "experience") return Object.assign(common, { schema: "super-brain.card.experience.v1", context: "", outcome: "", lesson: "", reuseConditions: [], trigger: "", rootCause: "", prevention: "", recurrence: 0, validationState: "candidate", revalidateAfter: "" });
    if (kind === "decision") return Object.assign(common, { schema: "super-brain.card.decision.v2", summary: "", rationale: "", consequences: [], stageKinds: [], enforcement: "advisory", completionCriteria: [], applicability: { mode: "workspace_stage", taskIds: [], taskInstanceIds: [], worklineIds: [], intentFingerprints: [] } });
    if (kind === "procedure") return Object.assign(common, { schema: "super-brain.card.procedure.v1", objective: "", preconditions: [], steps: [], verification: [] });
    return Object.assign(common, { schema: "super-brain.card.reflection.v1", observation: "", hypothesis: "", proposedAction: "", evidence: [], confidence: 70, candidateState: "candidate" });
  }

  function draftStorageKey(kind) { return `super-brain-control-center-draft-${kind}`; }

  function newDraft(kind) {
    let cardId = localStorage.getItem(draftStorageKey(kind));
    if (!cardId) {
      cardId = "card-" + crypto.randomUUID();
      localStorage.setItem(draftStorageKey(kind), cardId);
    }
    return {
      cardId: cardId,
      kind: kind,
      scope: { kind: kind === "decision" ? "workspace" : "global", key: kind === "decision" ? "workspace" : "user" },
      lifecycle: "active",
      authority: "user_confirmed",
      privacyClass: "private",
      title: "",
      payload: defaultPayload(kind),
      evidenceRefs: []
    };
  }

  const CAPTURE_DRAFT_SESSION_KEY = "super-brain-control-center-capture-draft-v1";

  function emptyCaptureDraft() {
    return { problem: "", desiredAction: "", requestId: "", requestFingerprint: "" };
  }

  function normalizedCaptureDraft(value) {
    return {
      problem: text(value && value.problem),
      desiredAction: text(value && value.desiredAction),
      requestId: text(value && value.requestId),
      requestFingerprint: text(value && value.requestFingerprint)
    };
  }

  function hasCaptureDraftContent(value) {
    return Boolean(text(value && value.problem).trim() || text(value && value.desiredAction).trim());
  }

  function captureFingerprint(problem, desiredAction) {
    return JSON.stringify({ problem: problem, desiredAction: desiredAction });
  }

  function readCaptureDraft() {
    try {
      const raw = sessionStorage.getItem(CAPTURE_DRAFT_SESSION_KEY);
      return raw ? normalizedCaptureDraft(JSON.parse(raw)) : emptyCaptureDraft();
    } catch (_) {
      return emptyCaptureDraft();
    }
  }

  function persistCaptureDraft(value) {
    try {
      if (hasCaptureDraftContent(value)) sessionStorage.setItem(CAPTURE_DRAFT_SESSION_KEY, JSON.stringify(normalizedCaptureDraft(value)));
      else sessionStorage.removeItem(CAPTURE_DRAFT_SESSION_KEY);
    } catch (_) { }
  }

  function text(value) { return typeof value === "string" ? value : ""; }
  function list(value) { return Array.isArray(value) ? value.filter((entry) => typeof entry === "string") : []; }
  function listText(value) { return list(value).join(", "); }
  function parseList(value) { return value.split(",").map((entry) => entry.trim()).filter(Boolean); }
  function linesText(value) { return list(value).join("\n"); }
  function parseLines(value) { return value.split(/\r?\n/).map((entry) => entry.trim()).filter(Boolean); }
  function asNumber(value, fallback) { return typeof value === "number" ? value : fallback; }
  function starmapHash(value) {
    let hash = 2166136261;
    const source = String(value || "");
    for (let index = 0; index < source.length; index += 1) {
      hash ^= source.charCodeAt(index);
      hash = Math.imul(hash, 16777619);
    }
    return hash >>> 0;
  }
  function starmapPosition(node, index) {
    const seed = starmapHash(node && node.nodeKey);
    const first = (seed & 0xffff) / 0xffff;
    const second = ((seed >>> 16) & 0xffff) / 0xffff;
    const angle = first * Math.PI * 2 + index * 0.36;
    if (node && node.kind === "task") {
      const radius = node.isCurrent ? 0 : 3.8 + (index % 4) * 1.1;
      return {
        x: Math.cos(angle) * radius,
        y: node.isCurrent ? 0 : (second - 0.5) * 3.8,
        z: Math.sin(angle) * radius
      };
    }
    const band = { decision: 8.5, preference: 10.5, experience: 12.5, procedure: 14.5, note: 16.5, reflection: 18.5, cluster: 22 }[node && node.kind] || 15;
    const radius = band + ((seed >>> 7) % 7) * 0.46;
    return {
      x: Math.cos(angle) * radius,
      y: (second - 0.5) * (node && node.kind === "cluster" ? 14 : 10) + Math.sin(angle * 2) * 0.55,
      z: Math.sin(angle) * radius
    };
  }
  function starmapNodeColor(node) { return STARMAP_NODE_COLORS[node && node.kind] || STARMAP_NODE_COLORS.note; }
  function starmapNodeAccent(node) {
    if (node && node.isHistorySource) return STARMAP_NODE_COLORS.history_source;
    if (node && node.isCandidate) return STARMAP_NODE_COLORS.candidate;
    return starmapNodeColor(node);
  }
  function starmapNodeHasDisplayIntegrityIssue(node) {
    if (!node || typeof node !== "object") return false;
    const tags = Array.isArray(node.tags) ? node.tags : [];
    return [node.title, node.summary].concat(tags).some(hasDisplayIntegrityIssue);
  }
  function starmapNodeDisplayTitle(node) {
    if (starmapNodeHasDisplayIntegrityIssue(node)) return "内容编码异常，等待修复";
    return displayText(text(node && node.title) || "未命名记忆").trim() || "未命名记忆";
  }
  function starmapNodeLabel(node) {
    const title = starmapNodeDisplayTitle(node);
    const characters = Array.from(title);
    return characters.length > 18 ? `${characters.slice(0, 18).join("")}…` : title;
  }
  function hasDraftContent(draft) {
    if (text(draft.title).trim()) return true;
    return Object.keys(draft.payload || {}).some((key) => key !== "schema" && JSON.stringify(draft.payload[key]) !== JSON.stringify(defaultPayload(draft.kind)[key]));
  }

  async function request(path, payload) {
    const response = await fetch(path, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload)
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok || !body.ok) throw new Error(typeof body.code === "string" ? body.code : "BRAIN_UI_REQUEST_FAILED");
    return body;
  }

  function field(label, control) {
    return h("label", { className: "field", key: label }, h("span", null, label), control);
  }

  function button(label, onClick, className, disabled, title) {
    return h("button", { type: "button", className: className || "icon-text", onClick: onClick, disabled: Boolean(disabled), title: title || label }, label);
  }

  function NoteEditor(props) {
    const { draft, locked, onChange } = props;
    const payload = draft.payload;
    const patch = (next) => onChange(Object.assign({}, draft, { payload: Object.assign({}, payload, next) }));
    return h("div", { className: "editor-form" }, [
      field("标题", h("input", { value: draft.title, disabled: locked, onChange: (event) => onChange(Object.assign({}, draft, { title: event.target.value })) })),
      h("div", { className: "editor-row", key: "scope" }, [
        field("范围", h("input", { value: draft.scope.kind, disabled: locked || !props.isNew, onChange: (event) => onChange(Object.assign({}, draft, { scope: Object.assign({}, draft.scope, { kind: event.target.value }) })) })),
        field("范围键", h("input", { value: draft.scope.key, disabled: locked || !props.isNew, onChange: (event) => onChange(Object.assign({}, draft, { scope: Object.assign({}, draft.scope, { key: event.target.value }) })) })),
        field("隐私", h("select", { value: draft.privacyClass, disabled: locked || !props.isNew, onChange: (event) => onChange(Object.assign({}, draft, { privacyClass: event.target.value })) }, [h("option", { value: "private", key: "private" }, "私有"), h("option", { value: "shared", key: "shared" }, "共享"), h("option", { value: "public", key: "public" }, "公开")]))
      ]),
      field("正文", h("textarea", { className: "note-body", value: text(payload.body), disabled: locked, onChange: (event) => patch({ body: event.target.value }) })),
      h("div", { className: "editor-row", key: "note-meta" }, [
        field("标签", h("input", { value: listText(payload.tags), disabled: locked, placeholder: "用逗号分隔", onChange: (event) => patch({ tags: parseList(event.target.value) }) })),
        field("链接", h("input", { value: listText(payload.links), disabled: locked, placeholder: "用逗号分隔", onChange: (event) => patch({ links: parseList(event.target.value) }) })),
        field("置顶", h("input", { className: "toggle", type: "checkbox", checked: payload.pinned === true, disabled: locked, onChange: (event) => patch({ pinned: event.target.checked }) }))
      ])
    ]);
  }

  function StructuredEditor(props) {
    const { draft, locked, isNew, onChange } = props;
    const [payloadText, setPayloadText] = useState(JSON.stringify(draft.payload, null, 2));
    useEffect(() => setPayloadText(JSON.stringify(draft.payload, null, 2)), [draft.cardId, draft.kind, draft.payload]);
    const applyText = (value) => {
      setPayloadText(value);
      try {
        const parsed = JSON.parse(value);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) onChange(Object.assign({}, draft, { payload: parsed }));
      } catch (_) { }
    };
    return h("div", { className: "editor-form" }, [
      field("标题", h("input", { value: draft.title, disabled: locked, onChange: (event) => onChange(Object.assign({}, draft, { title: event.target.value })) })),
      h("div", { className: "editor-row", key: "scope" }, [
        field("范围", h("input", { value: draft.scope.kind, disabled: locked || !isNew, onChange: (event) => onChange(Object.assign({}, draft, { scope: Object.assign({}, draft.scope, { kind: event.target.value }) })) })),
        field("范围键", h("input", { value: draft.scope.key, disabled: locked || !isNew, onChange: (event) => onChange(Object.assign({}, draft, { scope: Object.assign({}, draft.scope, { key: event.target.value }) })) })),
        field("隐私", h("select", { value: draft.privacyClass, disabled: locked || !isNew, onChange: (event) => onChange(Object.assign({}, draft, { privacyClass: event.target.value })) }, [h("option", { value: "private", key: "private" }, "私有"), h("option", { value: "shared", key: "shared" }, "共享"), h("option", { value: "public", key: "public" }, "公开")]))
      ]),
      field("结构化内容", h("textarea", { className: "payload-editor", value: payloadText, disabled: locked, spellCheck: false, onChange: (event) => applyText(event.target.value) })),
      h("p", { className: "form-hint", key: "hint" }, "此类型保留受控结构字段。保存时会由本地控制平面校验字段、敏感信息与版本冲突。")
    ]);
  }

  function MemoryCaptureEditor(props) {
    const { value, locked, onChange } = props;
    const update = (fieldName, nextValue) => onChange(Object.assign({}, value, { [fieldName]: nextValue, requestId: "", requestFingerprint: "" }));
    return h("div", { className: "editor-form quick-memory-capture" }, [
      h("p", { className: "quick-memory-capture-copy", key: "copy" }, "先记下就好；新内容先作为参考保存。真实使用并有证据后，才会在“自我学习”生成候选；采纳前不改变行为。"),
      field("问题是什么", h("textarea", {
        className: "quick-memory-capture-area",
        value: text(value.problem),
        disabled: locked,
        placeholder: "例如：发布前总会漏掉验收材料",
        onChange: (event) => update("problem", event.target.value)
      })),
      field("想怎么做", h("textarea", {
        className: "quick-memory-capture-area",
        value: text(value.desiredAction),
        disabled: locked,
        placeholder: "例如：下次准备发布时提醒我核对验收材料",
        onChange: (event) => update("desiredAction", event.target.value)
      }))
    ]);
  }

  function SystemLearningCandidate(props) {
    const { card, busy, onOpenSource } = props;
    const suggestedKind = learningSuggestionKind(card);
    const suggestedLabel = KINDS[suggestedKind] ? KINDS[suggestedKind].label : "类型未确定";
    const trial = reflectionTrial(card);
    const trialCopy = TRIAL_VERDICT_COPY[trial.verdict] || TRIAL_VERDICT_COPY.inconclusive;
    const promotable = REFLECTION_PROMOTABLE_KINDS.has(suggestedKind);
    const targetCopy = promotable
      ? `确认后将整理为${suggestedLabel}；在你确认前不会改变当前行为。`
      : (suggestedKind === "decision"
        ? "决定必须走专门的决定回执流程；这条候选不会从这里直接变成约束。"
        : "这条内容只保留为自我学习候选，不会直接晋升为可执行记忆。");
    const sourceCardId = learningSourceCardId(card);
    return h("section", { className: "learning-candidate-detail", "aria-label": "受治理学习候选" }, [
      h("div", { className: "learning-candidate-badge", key: "badge" }, `试用结果：${trialCopy.label}`),
      h("div", { className: "learning-candidate-copy", key: "copy" }, [
        h("h3", { key: "title" }, `建议沉淀为${suggestedLabel}`),
        h("p", { key: "summary" }, trialCopy.detail),
        h("p", { className: "learning-candidate-note", key: "note" }, targetCopy),
        !trial.hasReceipt ? h("p", { className: "learning-candidate-note", key: "receipt" }, "尚无当前任务的完整试用回执；系统不会把它显示为已验证。") : null
      ]),
      sourceCardId ? h("div", { className: "learning-candidate-actions", key: "actions" }, [
        button("查看来源记忆", () => onOpenSource({ cardId: sourceCardId }), "icon-text", Boolean(busy), "查看被验证注入的来源记忆")
      ]) : null
    ]);
  }

  const CONSOLIDATION_LABELS = {
    keep_for_review: "保留待查看",
    merge_with_active: "建议合并查看",
    archive_exact_duplicate_candidate: "重复记录待确认",
    archive_stale_candidate: "过期候选待确认"
  };

  const CONSOLIDATION_COPY = {
    keep_for_review: "没有发现安全的合并目标，先保留这条记录供你查看。",
    merge_with_active: "系统发现了相近的已保存记录；请先分别查看，再决定是否编辑或合并。",
    archive_exact_duplicate_candidate: "系统发现同范围、同隐私级别的完全重复记录；不会自动移动，仍由你确认。",
    archive_stale_candidate: "这条候选已超过你设置的整理期限；不会自动移动，仍由你确认。"
  };

  function LearningConsolidationPanel(props) {
    const { model, busy, onRefresh, onOpen } = props;
    const proposals = Array.isArray(model && model.proposals) ? model.proposals : [];
    const loaded = Boolean(model && model.schema === "super-brain.memory-consolidation-plan.v1");
    return h("section", { className: "learning-consolidation", "aria-label": "记忆整理建议" }, [
      h("div", { className: "learning-consolidation-heading", key: "heading" }, [
        h("div", { key: "copy" }, [
          h("span", { className: "learning-consolidation-badge", key: "badge" }, "整理建议 · 只读"),
          h("h2", { key: "title" }, "让待学习记录保持清爽"),
          h("p", { key: "note" }, "只比对同一范围、同一隐私级别的已保存记录。不会自动合并、删除或改变任何行为。")
        ]),
        button(loaded ? "刷新建议" : "生成建议", onRefresh, "icon-text", Boolean(busy), "生成只读整理建议")
      ]),
      loaded && proposals.length ? h("div", { className: "learning-consolidation-list", key: "list" }, proposals.map((proposal) => {
        const candidate = proposal && proposal.candidate;
        const target = proposal && proposal.target;
        const kind = text(proposal && proposal.suggestedKind);
        const recommendation = text(proposal && proposal.recommendation);
        const label = CONSOLIDATION_LABELS[recommendation] || "待查看";
        return h("article", { className: "learning-consolidation-item", key: text(proposal && proposal.proposalId) || text(candidate && candidate.cardRef) }, [
          h("div", { className: "learning-consolidation-item-copy", key: "copy" }, [
            h("strong", { key: "label" }, label),
            h("p", { key: "reason" }, CONSOLIDATION_COPY[recommendation] || "这条建议需要你查看后再决定。"),
            h("small", { key: "meta" }, `${KINDS[kind] ? KINDS[kind].label : "记忆"} · 置信度 ${Math.max(0, Math.min(100, Number(proposal && proposal.confidence) || 0))}%`)
          ]),
          h("div", { className: "learning-consolidation-actions", key: "actions" }, [
            candidate && text(candidate.cardRef) ? button("查看候选", () => onOpen(candidate), "icon-text", Boolean(busy), "查看待整理的记忆") : null,
            target && text(target.cardRef) ? button("查看匹配记录", () => onOpen(target), "icon-text muted", Boolean(busy), "查看匹配的现有记忆") : null
          ])
        ]);
      })) : (loaded ? h("p", { className: "learning-consolidation-empty", key: "empty" }, "目前没有需要整理的候选。新的快速记录会先保留为参考，不会被自动改写。") : null)
    ]);
  }

  function SimpleCardEditor(props) {
    const { draft, locked, onChange } = props;
    const payload = draft.payload || defaultPayload(draft.kind);
    const patch = (next) => onChange(Object.assign({}, draft, { payload: Object.assign({}, payload, next) }));
    const area = (label, value, onValue, placeholder, className) => field(label, h("textarea", {
      className: className || "",
      value: text(value),
      disabled: locked,
      placeholder: placeholder || "",
      onChange: (event) => onValue(event.target.value)
    }));
    const lines = (label, value, onValue, placeholder) => field(label, h("textarea", {
      value: linesText(value),
      disabled: locked,
      placeholder: placeholder || "每行一项",
      onChange: (event) => onValue(parseLines(event.target.value))
    }));
    const basicTitle = field("标题", h("input", {
      value: draft.title,
      disabled: locked,
      placeholder: "给这条记忆起个名字",
      onChange: (event) => onChange(Object.assign({}, draft, { title: event.target.value }))
    }));
    const input = (label, value, onValue, placeholder, type) => field(label, h("input", {
      type: type || "text",
      value: text(value),
      disabled: locked,
      placeholder: placeholder || "",
      onChange: (event) => onValue(event.target.value)
    }));
    const select = (label, value, onValue, options) => field(label, h("select", {
      value: text(value),
      disabled: locked,
      onChange: (event) => onValue(event.target.value)
    }, options.map((option) => h("option", { key: option[0], value: option[0], disabled: option[2] === true }, option[1]))));
    const range = (label, value, onValue) => h("label", { className: "field range-field", key: label }, [
      h("span", { key: "label" }, label),
      h("div", { className: "range-control", key: "control" }, [
        h("input", {
          key: "range",
          type: "range",
          min: 0,
          max: 100,
          step: 1,
          value: asNumber(value, 0),
          disabled: locked,
          onChange: (event) => onValue(Number(event.target.value))
        }),
        h("output", { key: "value" }, `${asNumber(value, 0)}%`)
      ])
    ]);
    const toggle = (label, value, onValue, hint) => h("label", { className: "check-field", key: label }, [
      h("input", { key: "input", type: "checkbox", checked: value === true, disabled: locked, onChange: (event) => onValue(event.target.checked) }),
      h("span", { key: "label" }, label),
      hint ? h("small", { key: "hint" }, hint) : null
    ]);
    const details = (content) => h("details", { className: "editor-advanced", key: "advanced" }, [
      h("summary", { key: "summary" }, "补充信息"),
      h("div", { className: "editor-advanced-content", key: "content" }, content)
    ]);
    const tags = () => input("标签", listText(payload.tags), (value) => patch({ tags: parseList(value) }), "用逗号分开，例如：发布、验收");
    const updateStages = (stage) => {
      const current = list(payload.stageKinds);
      patch({ stageKinds: current.includes(stage) ? current.filter((entry) => entry !== stage) : current.concat(stage) });
    };
    const stagePicker = () => field("在哪些阶段应用", h("div", { className: "choice-set" }, [
      ["build", "构建"],
      ["package", "打包"],
      ["release", "发布"],
      ["deploy", "部署"],
      ["test", "测试"]
    ].map((item) => h("label", { className: "choice-chip", key: item[0] }, [
      h("input", { type: "checkbox", checked: list(payload.stageKinds).includes(item[0]), disabled: locked, onChange: () => updateStages(item[0]) }),
      h("span", null, item[1])
    ]))));
    let content = [];
    if (draft.kind === "note") {
      content = [
        area("内容", payload.body, (value) => patch({ body: value }), "直接写下你的想法或要记住的事", "note-body"),
        h("div", { className: "editor-row", key: "note-meta" }, [
          tags(),
          input("关联线索", listText(payload.links), (value) => patch({ links: parseList(value) }), "例如：相关任务、文件或关键词"),
          toggle("置顶", payload.pinned, (value) => patch({ pinned: value }), "在列表中优先显示")
        ])
      ];
    } else if (draft.kind === "preference") {
      content = [
        area("我的偏好", payload.statement, (value) => patch({ statement: value }), "例如：长任务每完成一个阶段就简要汇报进度"),
        lines("适用情况", payload.conditions, (value) => patch({ conditions: value }), "例如：长任务\n工程修改"),
        h("div", { className: "editor-row", key: "preference-core" }, [
          range("把握程度", payload.confidence, (value) => patch({ confidence: value })),
          tags()
        ]),
        details([
          select("当前状态", payload.conflictState, (value) => patch({ conflictState: value }), [["clear", "正常使用"], ["conflicted", "需要核对"], ["suppressed", "暂不采用"]]),
          input("下次确认", payload.revalidateAfter, (value) => patch({ revalidateAfter: value }), "例如：2026-12-31", "date")
        ])
      ];
    } else if (draft.kind === "experience") {
      content = [
        area("发生了什么", payload.context, (value) => patch({ context: value }), "当时的情况"),
        area("结果", payload.outcome, (value) => patch({ outcome: value }), "最后发生了什么"),
        area("以后记住什么", payload.lesson, (value) => patch({ lesson: value }), "下次可复用的经验或避免方式"),
        lines("哪些情况可以复用", payload.reuseConditions, (value) => patch({ reuseConditions: value }), "每行一项，可不填"),
        details([
          area("什么情况要想起它", payload.trigger, (value) => patch({ trigger: value }), "例如：准备发布时", ""),
          area("问题根因", payload.rootCause, (value) => patch({ rootCause: value }), "可不填", ""),
          area("下次怎么避免", payload.prevention, (value) => patch({ prevention: value }), "可不填", ""),
          h("div", { className: "editor-row", key: "experience-state" }, [
            select("当前状态", payload.validationState, (value) => patch({ validationState: value }), [["candidate", "待验证"], ["validated", "已验证"], ["adopted", "正在采用"], ["rejected", "不采用"], ["resolved", "已解决"]]),
            field("重复次数", h("input", { type: "number", min: 0, max: 10000, value: asNumber(payload.recurrence, 0), disabled: locked, onChange: (event) => patch({ recurrence: Math.max(0, Number(event.target.value || 0)) }) })),
            input("下次回顾", payload.revalidateAfter, (value) => patch({ revalidateAfter: value }), "", "date")
          ]),
          tags()
        ])
      ];
    } else if (draft.kind === "decision") {
      content = [
        area("决定", payload.summary, (value) => patch({ summary: value }), "已经确认要怎么做"),
        area("原因", payload.rationale, (value) => patch({ rationale: value }), "为什么这样决定"),
        lines("会带来什么影响", payload.consequences, (value) => patch({ consequences: value }), "每行一项，可不填"),
        stagePicker(),
        select("执行方式", payload.enforcement, (value) => patch({ enforcement: value }), [["advisory", "作为提醒"], ["completion_gate", "作为完成前必须检查的要求"]]),
        payload.enforcement === "completion_gate" ? h("p", { className: "hard-gate-hint", key: "hard-gate" }, "保存后，相关阶段在宣布完成前会核对此决策；请完整填写下面的完成条件。") : null,
        lines("完成前需要满足", payload.completionCriteria, (value) => patch({ completionCriteria: value }), payload.enforcement === "completion_gate" ? "每行一项，必须填写" : "每行一项，可不填"),
        tags()
      ];
    } else if (draft.kind === "procedure") {
      content = [
        area("要完成什么", payload.objective, (value) => patch({ objective: value }), "这套做法的目标"),
        lines("开始前准备", payload.preconditions, (value) => patch({ preconditions: value }), "每行一项，可不填"),
        lines("怎么做", payload.steps, (value) => patch({ steps: value }), "每行一个步骤"),
        lines("怎么确认做好了", payload.verification, (value) => patch({ verification: value }), "每行一项"),
        tags()
      ];
    } else {
      content = [
        area("观察到的问题", payload.observation, (value) => patch({ observation: value }), "看到了什么问题或机会"),
        area("原因猜想", payload.hypothesis, (value) => patch({ hypothesis: value }), "目前认为为什么会这样"),
        area("准备怎么改进", payload.proposedAction, (value) => patch({ proposedAction: value }), "下一步准备做什么"),
        h("div", { className: "editor-row", key: "reflection-core" }, [
          range("把握程度", payload.confidence, (value) => patch({ confidence: value })),
          select("当前状态", payload.candidateState, (value) => patch({ candidateState: value }), [["candidate", "继续观察"], ["validated", "已验证"], ["staged", "准备采纳"], ["adopted", "已完成整理", true], ["rejected", "不采用"], ["resolved", "已解决"]])
        ]),
        payload.candidateState !== "candidate" ? h("p", { className: "hard-gate-hint", key: "reflection-evidence-hint" }, payload.candidateState === "adopted" ? "这条反思已经完成整理；原反思仍保留作为依据。" : "除继续观察外，必须写下至少一条实际证据或结果。准备采纳后，可在右上角按建议类型整理。") : null,
        lines("证据或实际结果", payload.evidence, (value) => patch({ evidence: value }), "每行一项；不是猜测，而是已经看到的现象、测试或用户结果"),
        details([
          tags()
        ])
      ];
    }
    return h("div", { className: "editor-form simple-editor" }, [basicTitle].concat(content));
  }

  function TaskHistory(props) {
    const history = props.history && typeof props.history === "object" ? props.history : {};
    const items = Array.isArray(history.items) ? history.items : [];
    const settings = history.settings && typeof history.settings === "object" ? history.settings : { completedDays: 7, trashDays: 15, compactEvidenceDays: 30, revision: 1 };
    const counts = history.counts && typeof history.counts === "object" ? history.counts : { visible: 0, trashed: 0, sealed: 0, evidenceOnly: 0, needsReview: 0 };
    const completionEvidence = history.completionEvidence && typeof history.completionEvidence === "object" ? history.completionEvidence : { count: 0 };
    const [preview, setPreview] = useState(null);
    const current = items.filter((item) => item && item.retentionState === "visible" && !item.isCompleted);
    const completed = items.filter((item) => item && item.retentionState === "visible" && item.isCompleted);
    const trashed = items.filter((item) => item && item.retentionState === "trashed");
    const review = items.filter((item) => item && item.retentionState === "needs_review");
    const sections = [
      { key: "current", title: "进行中的任务", items: current, empty: "当前没有其它进行中的任务。" },
      { key: "completed", title: "已完成任务", items: completed, empty: "当前项目还没有已完成任务。" },
      { key: "trashed", title: "任务回收站", items: trashed, empty: "回收站目前为空。" },
      { key: "review", title: "待核对", items: review, empty: "没有需要核对的任务卡。" }
    ].filter((section) => section.items.length);
    const renderItem = (item, index) => {
      const date = text(item.date);
      return h("article", { className: "task-history-item", key: `${item.title || "task"}-${index}` }, [
        h("div", { className: "task-history-heading", key: "heading" }, [
          h("div", { key: "title" }, [
            h("h4", null, text(item.title) || "未命名任务"),
            h("p", { className: "task-history-date", key: "date" }, date ? `记录日期：${date.slice(0, 10)}` : "日期未记录")
          ]),
          h("div", { className: "task-history-tags", key: "tags" }, [
            h("span", { className: "task-status", key: "status" }, text(item.statusLabel) || "待核对"),
            text(item.retentionLabel) ? h("span", { className: "task-history-retention", key: "retention" }, text(item.retentionLabel)) : null
          ])
        ]),
        h("p", { className: "task-history-content", key: "content" }, text(item.content) || "暂无任务内容摘要。"),
        text(item.retentionHint) ? h("p", { className: "task-history-hint", key: "hint" }, text(item.retentionHint)) : null,
        item.canRestore ? h("div", { className: "task-history-actions", key: "actions" }, [
          h("button", { type: "button", className: "icon-text", disabled: !!props.busy, onClick: () => props.onRestore(item) }, "恢复任务卡")
        ]) : null
      ]);
    };
    const previewSettings = async (event) => {
      const form = event.currentTarget.form;
      if (!form || !props.onPreview) return;
      const values = new FormData(form);
      const result = await props.onPreview(Number(values.get("completedDays")), Number(values.get("trashDays")));
      if (result) setPreview(result);
    };
    const renderPreviewGroup = (key, title, items) => items.length ? h("div", { className: "task-retention-preview-group", key: key }, [
      h("h5", null, title),
      h("p", null, items.map((item) => text(item.title)).filter(Boolean).join("、"))
    ]) : null;
    if (history.scopeBound === false) {
      return h("section", { className: "task-history", key: "history" }, [
        h("h3", null, "任务记录"),
        h("p", { className: "form-hint" }, "暂时不能确定当前项目，所以没有显示其它项目的任务记录。")
      ]);
    }
    return h("section", { className: "task-history", key: "history" }, [
      h("div", { className: "task-history-intro", key: "intro" }, [
        h("h3", null, "任务记录"),
        h("p", null, "完成任务保留 7 天；随后在回收站保留 15 天；第 30 天起仅保留紧凑完成证据，详细任务卡退出此页面。")
      ]),
      h("div", { className: "task-retention-status", key: "status" }, [
        h("span", { key: "visible" }, `当前显示 ${Number(counts.visible || 0)}`),
        h("span", { key: "trashed" }, `回收站 ${Number(counts.trashed || 0)}`),
        Number(counts.sealed || 0) ? h("span", { key: "sealed" }, `等待压缩 ${Number(counts.sealed || 0)}`) : null,
        Number(counts.evidenceOnly || completionEvidence.count || 0) ? h("span", { key: "evidence" }, `紧凑完成证据 ${Number(completionEvidence.count || counts.evidenceOnly || 0)}`) : null,
        Number(counts.needsReview || 0) ? h("span", { className: "attention", key: "review" }, `待核对 ${Number(counts.needsReview || 0)}`) : null
      ]),
      h("div", { className: "task-history-sections", key: "sections" }, sections.length ? sections.map((section) => h("section", { className: "task-history-section", key: section.key }, [
        h("h4", null, section.title),
        h("div", { className: "task-history-list" }, section.items.map(renderItem))
      ])) : h("p", { className: "form-hint" }, "当前项目还没有可显示的任务记录。")),
      h("form", {
        className: "task-retention-settings",
        key: "settings",
        onSubmit: (event) => {
          event.preventDefault();
          const form = new FormData(event.currentTarget);
          props.onSaveSettings(Number(form.get("completedDays")), Number(form.get("trashDays")), Number(settings.revision || 1));
        }
      }, [
        h("div", { className: "task-retention-heading", key: "heading" }, [
          h("h4", null, "任务卡整理"),
          h("p", null, "完整任务卡最长保留到完成后第 30 天；之后只保留紧凑完成证据，已有决策卡不受影响。")
        ]),
        h("label", { key: "completed" }, [
          h("span", null, "完成后多少天移到回收站"),
          h("input", { type: "number", name: "completedDays", min: 1, max: 29, defaultValue: Number(settings.completedDays || 7), disabled: !!props.busy })
        ]),
        h("label", { key: "trash" }, [
          h("span", null, "在回收站保留多少天"),
          h("input", { type: "number", name: "trashDays", min: 1, max: 29, defaultValue: Number(settings.trashDays || 15), disabled: !!props.busy })
        ]),
        h("button", { type: "button", className: "icon-text", disabled: !!props.busy, onClick: previewSettings }, "查看影响"),
        h("button", { type: "submit", className: "icon-text", disabled: !!props.busy }, "保存整理设置")
      ]),
      preview && preview.scopeBound !== false ? h("section", { className: "task-retention-preview", key: "preview" }, [
        h("div", { className: "task-retention-preview-heading", key: "heading" }, [
          h("h4", null, "整理影响预览"),
          h("span", null, `回收站 ${Number(preview.counts && preview.counts.trashed || 0)} · 等待压缩 ${Number(preview.counts && preview.counts.sealed || 0)} · 紧凑证据 ${Number(preview.counts && preview.counts.evidenceOnly || 0)}`)
        ]),
        h("p", { key: "copy" }, text(preview.summary) || "这是预览，不会修改任何任务卡。"),
        renderPreviewGroup("trash", "会移入回收站", Array.isArray(preview.impacts && preview.impacts.toTrash) ? preview.impacts.toTrash : []),
        renderPreviewGroup("sealed", "会退出管理界面并等待第 30 天压缩", Array.isArray(preview.impacts && preview.impacts.sealAfterTrash) ? preview.impacts.sealAfterTrash : []),
        renderPreviewGroup("evidence", "会压缩为完成证据", Array.isArray(preview.impacts && preview.impacts.compactEvidence) ? preview.impacts.compactEvidence : []),
        renderPreviewGroup("review", "需要先核对", Array.isArray(preview.impacts && preview.impacts.needsReview) ? preview.impacts.needsReview : [])
      ]) : null
    ]);
  }

  function TaskCenter(props) {
    const model = props.model || { tasks: [], pendingOutbox: 0 };
    const task = Array.isArray(model.tasks) && model.tasks.length ? model.tasks[0] : null;
    const historyPanel = h(TaskHistory, { history: model.taskHistory, onRestore: props.onRestore, onSaveSettings: props.onSaveSettings, onPreview: props.onPreview, busy: props.busy });
    if (!task) {
      return h("div", { className: "task-center" }, [
        h("section", { className: "task-center-intro", key: "intro" }, [
          h("p", { className: "section-eyebrow", key: "eyebrow" }, "任务中心"),
          h("h3", { key: "title" }, "当前没有进行中的任务"),
          h("p", { key: "copy" }, "任务开始后，这里会显示任务内容、正在做什么，以及已完成和待完成的清单。")
        ]),
        historyPanel
      ]);
    }
    const display = task.display || {};
    const completed = Array.isArray(display.completedItems) ? display.completedItems : [];
    const active = Array.isArray(display.inProgressItems) ? display.inProgressItems : [];
    const pending = Array.isArray(display.pendingItems) ? display.pendingItems : [];
    const checklist = completed.concat(active, pending);
    const total = Number(display.totalCount || checklist.length || 0);
    const done = Number(display.completedCount || completed.length || 0);
    const inProgress = Number(display.inProgressCount || active.length || 0);
    const waiting = Number(display.pendingCount || pending.length || 0);
    const summary = text(display.summary) || "任务内容正在同步，请先按照下方清单推进。";
    return h("div", { className: "task-center" }, [
      h("section", { className: "task-center-intro", key: "intro" }, [
        h("p", { className: "section-eyebrow", key: "eyebrow" }, "任务中心"),
        h("p", { key: "copy" }, "这里只展示当前任务的内容和进度，不显示内部编号或技术记录。")
      ]),
      h("section", { className: "task-summary", key: "summary" }, [
        h("div", { className: "task-summary-header", key: "heading" }, [
          h("div", { key: "copy" }, [
            h("p", null, "当前任务"),
            h("h3", null, text(display.title) || "当前任务")
          ]),
          h("span", { className: "task-status", key: "status" }, text(display.statusLabel) || "进行中")
        ]),
        h("div", { className: "task-content", key: "content" }, [
          h("h4", null, "任务内容"),
          h("p", null, summary)
        ]),
        h("dl", { className: "task-details", key: "details" }, [
          h("div", { key: "phase" }, [h("dt", null, "当前阶段"), h("dd", null, text(display.phase) || "等待开始")]),
          h("div", { key: "step" }, [h("dt", null, "正在做"), h("dd", null, text(display.currentStep) || "等待下一步安排")]),
          h("div", { key: "next" }, [h("dt", null, "下一步"), h("dd", null, text(display.nextAction) || "暂无下一步")])
        ])
      ]),
      h("section", { className: "task-progress", key: "progress" }, [
        h("div", { className: "task-progress-heading", key: "heading" }, [h("h3", null, "任务清单"), h("strong", null, total ? `已完成 ${done} / ${total}` : "清单准备中")]),
        total ? h("div", { className: "task-counts", key: "counts" }, [
          h("span", { className: "task-count completed", key: "completed" }, `已完成 ${done}`),
          h("span", { className: "task-count active", key: "active" }, `进行中 ${inProgress}`),
          h("span", { className: "task-count pending", key: "pending" }, `待完成 ${waiting}`)
        ]) : null,
        checklist.length ? h("div", { className: "task-checklist", key: "list" }, checklist.map((item, index) => h("div", { className: `task-check ${item.status || "pending"}`, key: item.itemId || `${item.ordinal || 0}-${index}` }, [
          h("span", { className: "task-check-state", key: "state" }, text(item.statusLabel) || "待完成"),
          h("span", { className: "task-check-label", key: "label" }, text(item.label) || "未命名步骤")
        ]))) : h("p", { className: "form-hint", key: "empty" }, "任务清单正在准备中。")
      ]),
      historyPanel
    ]);
  }

  function SkillCatalog(props) {
    const items = Array.isArray(props.model && props.model.items) ? props.model.items : [];
    return h("div", { className: "skills-view" }, [
      h("section", { className: "skills-intro", key: "intro" }, [
        h("p", { className: "section-eyebrow", key: "eyebrow" }, "技能"),
        h("h3", { key: "title" }, "这些能力什么时候会帮你"),
        h("p", { key: "copy" }, "这里只说明每项能力的作用；它们会按当前任务需要启用，不会把所有规则塞进每次对话。")
      ]),
      items.length ? h("div", { className: "skills-list", key: "list" }, items.map((item) => h("section", { className: "skill-row", key: text(item.id) || text(item.title) }, [
        h("div", { key: "copy" }, [h("h4", null, text(item.title) || "未命名能力"), h("p", null, text(item.description) || "暂无说明")]),
        h("span", { className: "skill-state", key: "state" }, text(item.state) || "可用")
      ]))) : h("p", { className: "form-hint", key: "empty" }, "当前没有可显示的能力说明。")
    ]);
  }

  function HealthPanel(props) {
    const indicators = Array.isArray(props.model && props.model.indicators) ? props.model.indicators : [];
    return h("div", { className: "health-view" }, [
      h("section", { className: "health-intro", key: "intro" }, [
        h("p", { className: "section-eyebrow", key: "eyebrow" }, "运行状态"),
        h("h3", { key: "title" }, "本机记忆与任务运行情况"),
        h("p", { key: "copy" }, "这里只显示需要你了解的状态；出现需要处理的情况时会明确说明原因。")
      ]),
      h("div", { className: "health-list", key: "list" }, indicators.map((item) => h("section", { className: `health-row ${text(item.state) || "quiet"}`, key: text(item.id) || text(item.title) }, [
        h("div", { key: "copy" }, [h("h4", null, text(item.title) || "状态"), h("p", null, text(item.description) || "暂无说明")]),
        h("strong", { key: "value" }, text(item.value) || "等待检查")
      ])))
    ]);
  }

  function ProfilePanel(props) {
    const model = props.model || { total: 0, longTerm: [], currentProject: [] };
    const longTerm = Array.isArray(model.longTerm) ? model.longTerm : [];
    const currentProject = Array.isArray(model.currentProject) ? model.currentProject : [];
    const total = Number(model.total || 0);
    const renderItem = (item) => h("button", {
      type: "button",
      className: "profile-item",
      key: text(item.cardRef) || text(item.title),
      onClick: () => props.onOpen(item),
      title: `查看并编辑偏好：${text(item.title) || "未命名偏好"}`
    }, [
      h("div", { className: "profile-item-heading", key: "heading" }, [
        h("strong", { key: "title" }, text(item.title) || "未命名偏好"),
        Number.isFinite(Number(item.confidence)) ? h("span", { className: "profile-confidence", key: "confidence" }, `确认度 ${Math.max(0, Math.min(100, Number(item.confidence)))}%`) : null
      ]),
      h("p", { className: "profile-statement", key: "statement" }, text(item.statement) || "暂无偏好说明"),
      Array.isArray(item.conditions) && item.conditions.length ? h("p", { className: "profile-conditions", key: "conditions" }, item.conditions.map(text).filter(Boolean).join(" · ")) : null,
      h("span", { className: "profile-item-action", key: "action" }, "查看并编辑")
    ]);
    const renderGroup = (key, title, description, items) => h("section", { className: "profile-section", key: key }, [
      h("div", { className: "profile-section-heading", key: "heading" }, [
        h("div", { key: "copy" }, [h("h3", null, title), h("p", null, description)]),
        h("span", { className: "profile-count", key: "count" }, `${items.length} 条`)
      ]),
      items.length ? h("div", { className: "profile-list", key: "list" }, items.map(renderItem)) : h("p", { className: "profile-empty", key: "empty" }, "暂时没有已确认的内容。")
    ]);
    return h("div", { className: "profile-view" }, [
      h("section", { className: "profile-intro", key: "intro" }, [
        h("p", { className: "section-eyebrow", key: "eyebrow" }, "偏好与性格画像"),
        h("h3", { key: "title" }, "超级大脑会怎样配合你"),
        h("p", { key: "copy" }, text(model.summary) || "这里汇总已经确认的协作偏好。它们会在相关任务里被主动参考，而不是让你反复提醒。"),
        h("div", { className: "profile-intro-actions", key: "actions" }, [
          h("span", { className: "profile-total", key: "total" }, `${total} 条已确认偏好`),
          button("新建协作偏好", props.onCreate, "icon-text", false, "新建一条长期协作偏好")
        ])
      ]),
      renderGroup("long-term", "长期协作方式", "适用于大多数任务，会在真正相关时被轻量唤醒。", longTerm),
      renderGroup("current-project", "当前项目的协作方式", "只在这个项目相关的任务中优先参考。", currentProject)
    ]);
  }

  function MemoryTimeline(props) {
    const model = props.model || { items: [] };
    const items = Array.isArray(model.items) ? model.items : [];
    if (!items.length) {
      return h("div", { className: "memory-timeline" }, [
        h("section", { className: "timeline-intro", key: "intro" }, [
          h("h3", { key: "title" }, "还没有可显示的记忆"),
          h("p", { key: "copy" }, "保存笔记、偏好、经验、决策、流程或反思后，这里会按日期汇总标题、内容摘要和已验证来源。")
        ])
      ]);
    }
    const groups = items.reduce((result, item) => {
      const date = text(item.date) || "日期未记录";
      if (!result[date]) result[date] = [];
      result[date].push(item);
      return result;
    }, {});
    return h("div", { className: "memory-timeline" }, [
      h("div", { className: "timeline-groups", key: "groups" }, Object.keys(groups).map((date) => h("section", { className: "timeline-day", key: date }, [
        h("h3", { key: "date" }, date),
        h("div", { className: "timeline-list", key: "list" }, groups[date].map((item, index) => {
          const canOpen = Boolean(text(item.cardRef) || text(item.cardId));
          const title = displayText(text(item.title) || "未命名记忆");
          const summary = displayText(text(item.summary) || "暂无内容摘要");
          const kindLabel = text(item.kindLabel) || (KINDS[item.kind] && KINDS[item.kind].label) || "记忆";
          const kindColor = STARMAP_NODE_COLORS[item.kind] || STARMAP_NODE_COLORS.note;
          return h("article", {
            className: "timeline-entry",
            style: { "--timeline-kind-color": kindColor },
            key: `${date}-${index}`,
          }, [
            h("button", {
              type: "button",
              className: "timeline-entry-main",
              disabled: !canOpen || Boolean(props.busy),
              onClick: () => props.onOpen(item),
              title: `查看${kindLabel}：${title}`,
              "aria-label": `查看${kindLabel}：${title}`,
              key: "open"
            }, [
              h("span", { className: "timeline-kind-dot", "aria-hidden": "true", key: "dot" }),
              h("span", { className: "timeline-record-copy", key: "copy" }, [
                h("strong", { className: "timeline-title", key: "title" }, title),
                h("span", { className: "timeline-summary", key: "summary" }, summary)
              ])
            ]),
            h("div", { className: "timeline-entry-actions", key: "actions", "aria-label": `“${text(item.title) || "未命名记忆"}”的操作` }, [
              h("button", {
                type: "button",
                className: "timeline-trash-action",
                disabled: !canOpen || !props.onTrash || Boolean(props.busy),
                onClick: (event) => { event.stopPropagation(); props.onTrash(item); },
                title: `将“${title}”移至回收站`,
                "aria-label": `将“${title}”移至回收站`,
                key: "trash"
              }, h(Trash2, { size: 15, strokeWidth: 1.8, "aria-hidden": "true" }))
            ])
          ]);
        }))
      ])))
    ]);
  }

  function RecycleBin(props) {
    const items = Array.isArray(props.items) ? props.items : [];
    return h("div", { className: "recycle-bin" }, [
      h("section", { className: "recycle-bin-intro", key: "intro" }, [
        h("div", { key: "copy" }, [
          h("p", { className: "section-eyebrow", key: "eyebrow" }, "回收站"),
          h("h3", { key: "title" }, "已删除的记录"),
          h("p", { key: "description" }, "这里的记录不会出现在当前记忆、总览或星图中。打开后可以恢复；彻底忘记仍须经过单独的治理确认。")
        ]),
        button("刷新", props.onRefresh, "icon-text", props.busy, "刷新回收站")
      ]),
      items.length ? h("div", { className: "recycle-bin-list", key: "list", "aria-live": "polite" }, items.map((item) => h("button", {
        type: "button",
        className: "recycle-bin-item",
        key: text(item.cardId) || text(item.title),
        onClick: () => props.onOpen(item),
        title: `打开并恢复：${text(item.title) || "未命名记录"}`
      }, [
        h("span", { className: "recycle-bin-kind", key: "kind" }, KINDS[item.kind] ? KINDS[item.kind].label : "记忆"),
        h("strong", { key: "title" }, text(item.title) || "未命名记录"),
        h("span", { className: "recycle-bin-summary", key: "summary" }, text(item.summary) || "没有可显示的摘要"),
        h("span", { className: "recycle-bin-action", key: "action" }, "打开后可恢复")
      ]))) : h("section", { className: "recycle-bin-empty", key: "empty" }, [h("h3", null, "回收站是空的"), h("p", null, "已删除的记录会先放在这里，方便你恢复。")])
    ]);
  }

  function ManagedRecycleBin(props) {
    const items = Array.isArray(props.items) ? props.items : [];
    const [selectedIds, setSelectedIds] = useState(() => new Set());
    const selectableItems = items.filter((item) => text(item && item.cardId));
    const selectedItems = selectableItems.filter((item) => selectedIds.has(text(item.cardId)));
    const allSelected = selectableItems.length > 0 && selectedItems.length === selectableItems.length;

    useEffect(() => {
      const visibleIds = new Set(selectableItems.map((item) => text(item.cardId)));
      setSelectedIds((previous) => {
        const next = new Set(Array.from(previous).filter((cardId) => visibleIds.has(cardId)));
        const unchanged = next.size === previous.size && Array.from(next).every((cardId) => previous.has(cardId));
        return unchanged ? previous : next;
      });
    }, [items]);

    const toggleSelection = (item) => {
      const cardId = text(item && item.cardId);
      if (!cardId) return;
      setSelectedIds((previous) => {
        const next = new Set(previous);
        if (next.has(cardId)) next.delete(cardId); else next.add(cardId);
        return next;
      });
    };
    const toggleAll = () => setSelectedIds(allSelected ? new Set() : new Set(selectableItems.map((item) => text(item.cardId))));

    return h("div", { className: "recycle-bin managed-recycle-bin" }, [
      h("section", { className: "recycle-bin-intro", key: "intro" }, [
        h("div", { key: "copy" }, [
          h("p", { className: "section-eyebrow", key: "eyebrow" }, "回收站"),
          h("h3", { key: "title" }, "已删除的记录"),
          h("p", { key: "description" }, "这里的记录不会出现在当前记忆、总览或星图中。可查看后恢复；彻底删除会清除正文和搜索索引，并保留不可读的治理凭据。")
        ]),
        h("div", { className: "recycle-bin-toolbar", key: "toolbar" }, [
          selectableItems.length ? h("label", { className: "recycle-bin-select-all", key: "select-all" }, [
            h("input", { type: "checkbox", checked: allSelected, onChange: toggleAll, disabled: Boolean(props.busy), key: "input" }),
            h("span", { key: "label" }, allSelected ? "取消全选" : "全选")
          ]) : null,
          selectedItems.length ? button(`删除勾选的 ${selectedItems.length} 条`, () => props.onDelete && props.onDelete(selectedItems), "icon-text danger", Boolean(props.busy) || !props.onDelete, "彻底删除勾选的回收站记录") : null,
          button("刷新", props.onRefresh, "icon-text", props.busy, "刷新回收站")
        ])
      ]),
      items.length ? h("div", { className: "recycle-bin-list", key: "list", "aria-live": "polite" }, items.map((item) => {
        const cardId = text(item.cardId);
        const canOperate = Boolean(cardId) && !props.busy;
        const title = text(item.title) || "未命名记忆";
        return h("article", { className: "recycle-bin-item", key: cardId || title }, [
          h("label", { className: "recycle-bin-select", key: "select", title: `选择“${title}”` }, [
            h("input", { type: "checkbox", checked: selectedIds.has(cardId), onChange: () => toggleSelection(item), disabled: !canOperate, "aria-label": `选择“${title}”`, key: "input" })
          ]),
          h("div", { className: "recycle-bin-content", key: "content" }, [
            h("span", { className: "recycle-bin-kind", key: "kind" }, KINDS[item.kind] ? KINDS[item.kind].label : "记忆"),
            h("strong", { key: "title" }, title),
            h("span", { className: "recycle-bin-summary", key: "summary" }, text(item.summary) || "没有可显示的摘要")
          ]),
          h("div", { className: "recycle-bin-actions", key: "actions" }, [
            button("查看", () => props.onOpen(item), "icon-text", !canOperate, `打开“${title}”`),
            button("彻底删除", () => props.onDelete && props.onDelete([item]), "icon-text danger", !canOperate || !props.onDelete, `彻底删除“${title}”`)
          ])
        ]);
      })) : h("section", { className: "recycle-bin-empty", key: "empty" }, [h("h3", null, "回收站是空的"), h("p", null, "已删除的记录会先放在这里，方便你恢复。")])
    ]);
  }

  function CanvasStarmap(props) {
    const canvasRef = useRef(null);

    useEffect(() => {
      const canvas = canvasRef.current;
      if (!canvas) return undefined;
      const context = canvas.getContext("2d");
      if (!context) {
        if (props.onUnavailable) props.onUnavailable();
        return undefined;
      }

      const nodes = Array.isArray(props.nodes) ? props.nodes : [];
      const edges = Array.isArray(props.edges) ? props.edges : [];
      const nodeByKey = new Map(nodes.map((node) => [node.nodeKey, node]));
      const view = { zoom: 1, offsetX: 0, offsetY: 0, width: 0, height: 0 };
      const drag = { active: false, moved: false, pointerId: null, x: 0, y: 0 };
      let resizeObserver = null;
      let points = new Map();

      const pointFor = (node, index) => {
        const position = nodes.length === 1 ? { x: 0, y: 0, z: 0 } : starmapPosition(node, index);
        const scale = Math.max(7, Math.min(view.width, view.height) / 54) * view.zoom;
        return {
          x: view.width * .5 + (position.x * 1.16 + position.z * .42) * scale + view.offsetX,
          y: view.height * .5 + (position.y * 1.12 - position.z * .34) * scale + view.offsetY,
        };
      };

      const nodeRadius = (node) => {
        const weight = Math.max(.22, Math.min(1, Number(node && node.weight) || .45));
        return Math.max(3.5, Math.min(10, 2.4 + weight * 6 + (node && node.isCurrent ? 3 : (node && node.isPinned ? 1.7 : 0))));
      };

      const draw = () => {
        if (!view.width || !view.height) return;
        context.clearRect(0, 0, view.width, view.height);
        const gradient = context.createRadialGradient(view.width * .52, view.height * .42, 0, view.width * .52, view.height * .42, Math.max(view.width, view.height) * .72);
        gradient.addColorStop(0, "rgba(27, 57, 92, .18)");
        gradient.addColorStop(.56, "rgba(6, 14, 28, .10)");
        gradient.addColorStop(1, "rgba(1, 4, 10, .04)");
        context.fillStyle = gradient;
        context.fillRect(0, 0, view.width, view.height);

        for (let index = 0; index < 96; index += 1) {
          const seed = starmapHash(`canvas-background-${index}`);
          const x = ((seed & 0xffff) / 0xffff) * view.width;
          const y = (((seed >>> 16) & 0xffff) / 0xffff) * view.height;
          const bright = (seed % 9) === 0;
          context.fillStyle = bright ? "rgba(217, 240, 255, .58)" : "rgba(147, 205, 255, .22)";
          context.fillRect(x, y, bright ? 1.5 : 1, bright ? 1.5 : 1);
        }

        points = new Map(nodes.map((node, index) => [node.nodeKey, pointFor(node, index)]));
        edges.forEach((edge) => {
          const source = points.get(edge.source);
          const target = points.get(edge.target);
          if (!source || !target) return;
          context.save();
          context.globalAlpha = props.selectedKey && edge.source !== props.selectedKey && edge.target !== props.selectedKey ? .18 : .44;
          context.strokeStyle = STARMAP_RELATION_COLORS[edge.relation] || "#718aa4";
          context.lineWidth = Math.max(.7, Math.min(2.2, Number(edge.strength || .4) * 2));
          context.beginPath();
          context.moveTo(source.x, source.y);
          context.lineTo(target.x, target.y);
          context.stroke();
          context.restore();
        });

        nodes.forEach((node) => {
          const point = points.get(node.nodeKey);
          if (!point) return;
          const radius = nodeRadius(node);
          const focused = !props.selectedKey || node.nodeKey === props.selectedKey || node.isCurrent || node.isPinned;
          const accent = starmapNodeAccent(node);
          context.save();
          context.globalAlpha = focused ? 1 : .42;
          context.shadowBlur = node.isCurrent || node.isPinned ? 24 : 13;
          context.shadowColor = accent;
          context.fillStyle = starmapNodeColor(node);
          context.beginPath();
          if (node.isHistorySource) {
            context.moveTo(point.x, point.y - radius * 1.2);
            context.lineTo(point.x + radius * 1.2, point.y);
            context.lineTo(point.x, point.y + radius * 1.2);
            context.lineTo(point.x - radius * 1.2, point.y);
            context.closePath();
          } else {
            context.arc(point.x, point.y, radius, 0, Math.PI * 2);
          }
          context.fill();
          context.fillStyle = "rgba(248, 253, 255, .92)";
          context.beginPath();
          context.arc(point.x, point.y, Math.max(1.25, radius * .34), 0, Math.PI * 2);
          context.fill();
          if (node.isCandidate) {
            context.globalAlpha = focused ? .92 : .35;
            context.strokeStyle = accent;
            context.lineWidth = 1.25;
            context.setLineDash([3, 3]);
            context.beginPath();
            context.arc(point.x, point.y, radius + 4, 0, Math.PI * 2);
            context.stroke();
            context.setLineDash([]);
          }
          context.restore();
        });

        const labels = nodes.filter((node) => node.nodeKey === props.selectedKey || node.isCurrent || node.isPinned);
        context.font = '600 12px "Microsoft YaHei UI", "PingFang SC", sans-serif';
        context.textAlign = "center";
        context.textBaseline = "bottom";
        labels.forEach((node) => {
          const point = points.get(node.nodeKey);
          if (!point) return;
          const label = starmapNodeLabel(node);
          const y = Math.max(18, point.y - nodeRadius(node) - 9);
          context.fillStyle = "rgba(2, 8, 18, .74)";
          const width = Math.min(224, Math.max(50, context.measureText(label).width + 16));
          context.fillRect(Math.max(6, point.x - width / 2), y - 18, width, 18);
          context.fillStyle = "#eff8ff";
          context.fillText(label, Math.max(width / 2 + 6, Math.min(view.width - width / 2 - 6, point.x)), y - 4);
        });
      };

      const resize = () => {
        const bounds = canvas.getBoundingClientRect();
        view.width = Math.max(1, bounds.width);
        view.height = Math.max(1, bounds.height);
        const density = Math.min(2, window.devicePixelRatio || 1);
        canvas.width = Math.round(view.width * density);
        canvas.height = Math.round(view.height * density);
        context.setTransform(density, 0, 0, density, 0, 0);
        draw();
      };

      const pointFromEvent = (event) => {
        const bounds = canvas.getBoundingClientRect();
        return { x: event.clientX - bounds.left, y: event.clientY - bounds.top };
      };

      const selectPoint = (point) => {
        let nearest = null;
        let nearestDistance = Infinity;
        nodes.forEach((node) => {
          const candidate = points.get(node.nodeKey);
          if (!candidate) return;
          const distance = Math.hypot(candidate.x - point.x, candidate.y - point.y);
          if (distance < nearestDistance) {
            nearest = node;
            nearestDistance = distance;
          }
        });
        if (nearest && nearestDistance <= Math.max(18, nodeRadius(nearest) + 11)) props.onSelect(nearest.nodeKey);
      };

      const onPointerDown = (event) => {
        const point = pointFromEvent(event);
        drag.active = true;
        drag.moved = false;
        drag.pointerId = event.pointerId;
        drag.x = point.x;
        drag.y = point.y;
        canvas.focus();
        if (canvas.setPointerCapture) canvas.setPointerCapture(event.pointerId);
      };
      const onPointerMove = (event) => {
        if (!drag.active || drag.pointerId !== event.pointerId) return;
        const point = pointFromEvent(event);
        const x = point.x - drag.x;
        const y = point.y - drag.y;
        if (Math.abs(x) + Math.abs(y) > 2) drag.moved = true;
        view.offsetX += x;
        view.offsetY += y;
        drag.x = point.x;
        drag.y = point.y;
        draw();
      };
      const onPointerUp = (event) => {
        if (!drag.active || drag.pointerId !== event.pointerId) return;
        const point = pointFromEvent(event);
        if (!drag.moved) selectPoint(point);
        drag.active = false;
        drag.pointerId = null;
        if (canvas.releasePointerCapture) canvas.releasePointerCapture(event.pointerId);
      };
      const onWheel = (event) => {
        event.preventDefault();
        view.zoom = Math.max(.48, Math.min(2.7, view.zoom * (event.deltaY > 0 ? .9 : 1.1)));
        draw();
      };
      const onKeyDown = (event) => {
        if (event.key === "Escape") props.onSelect(null);
      };

      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(resize);
        resizeObserver.observe(canvas);
      } else {
        window.addEventListener("resize", resize);
      }
      canvas.addEventListener("pointerdown", onPointerDown);
      canvas.addEventListener("pointermove", onPointerMove);
      canvas.addEventListener("pointerup", onPointerUp);
      canvas.addEventListener("pointercancel", onPointerUp);
      canvas.addEventListener("wheel", onWheel, { passive: false });
      canvas.addEventListener("keydown", onKeyDown);
      resize();
      return () => {
        if (resizeObserver) resizeObserver.disconnect();
        else window.removeEventListener("resize", resize);
        canvas.removeEventListener("pointerdown", onPointerDown);
        canvas.removeEventListener("pointermove", onPointerMove);
        canvas.removeEventListener("pointerup", onPointerUp);
        canvas.removeEventListener("pointercancel", onPointerUp);
        canvas.removeEventListener("wheel", onWheel);
        canvas.removeEventListener("keydown", onKeyDown);
      };
    }, [props.edges, props.nodes, props.onSelect, props.onUnavailable, props.selectedKey]);

    return h("canvas", {
      ref: canvasRef,
      className: "starmap-canvas-2d",
      tabIndex: 0,
      "aria-label": "兼容模式记忆星图：可拖动、缩放并选择记忆节点"
    });
  }

  function MemoryStarmap(props) {
    const model = props.model && typeof props.model === "object" ? props.model : { nodes: [], edges: [], counts: {} };
    const allNodes = Array.isArray(model.nodes) ? model.nodes : [];
    const allEdges = Array.isArray(model.edges) ? model.edges : [];
    const counts = model.counts && typeof model.counts === "object" ? model.counts : {};
    const [rendererMode, setRendererMode] = useState("webgl");
    const [renderNotice, setRenderNotice] = useState("");
    const mountRef = useRef(null);
    const labelLayerRef = useRef(null);
    const onSelectRef = useRef(props.onSelect);
    const selectedKeyRef = useRef(props.selectedKey);
    const cameraViewRef = useRef(null);

    useEffect(() => { onSelectRef.current = props.onSelect; }, [props.onSelect]);
    useEffect(() => { selectedKeyRef.current = props.selectedKey; }, [props.selectedKey]);
    const clearStarmapSelection = useCallback(() => props.onSelect(null), [props.onSelect]);

    const graph = useMemo(() => {
      const activeFilter = STARMAP_FILTERS.find((filter) => filter.key === props.filter) || STARMAP_FILTERS[0];
      const nodeByKey = new Map(allNodes.filter((node) => node && text(node.nodeKey)).map((node) => [node.nodeKey, node]));
      const memoryKeys = new Set();
      allNodes.forEach((node) => {
        if (!node || node.kind === "task") return;
        const nodeKind = node.kind === "cluster" ? text(node.clusterKind) : node.kind;
        if (activeFilter.key === "all" || (Array.isArray(activeFilter.kinds) && activeFilter.kinds.includes(nodeKind))) memoryKeys.add(node.nodeKey);
      });
      const visibleKeys = new Set(memoryKeys);
      if (props.filter === "all") {
        allNodes.forEach((node) => { if (node && node.kind === "task") visibleKeys.add(node.nodeKey); });
      } else {
        allEdges.forEach((edge) => {
          if (!edge) return;
          const source = nodeByKey.get(edge.source);
          const target = nodeByKey.get(edge.target);
          if (memoryKeys.has(edge.source) && target && target.kind === "task") visibleKeys.add(edge.target);
          if (memoryKeys.has(edge.target) && source && source.kind === "task") visibleKeys.add(edge.source);
        });
      }
      const nodes = allNodes.filter((node) => node && visibleKeys.has(node.nodeKey));
      const edges = allEdges.filter((edge) => edge && visibleKeys.has(edge.source) && visibleKeys.has(edge.target));
      return { nodes: nodes, edges: edges, nodeByKey: new Map(nodes.map((node) => [node.nodeKey, node])) };
    }, [allEdges, allNodes, props.filter]);

    const selectedNode = props.selectedKey ? graph.nodeByKey.get(props.selectedKey) : null;
    const directRelationCount = selectedNode ? graph.edges.filter((edge) => edge.source === selectedNode.nodeKey || edge.target === selectedNode.nodeKey).length : 0;
    const source = selectedNode && selectedNode.source && typeof selectedNode.source === "object" ? selectedNode.source : {};
    const candidateCount = graph.nodes.filter((node) => node && node.isCandidate).length;
    const historySourceRecords = Math.max(0, Number(counts.historySourceRecords || 0));

    useEffect(() => {
      if (props.selectedKey && !graph.nodeByKey.has(props.selectedKey)) clearStarmapSelection();
    }, [clearStarmapSelection, graph, props.selectedKey]);

    useEffect(() => {
      if (rendererMode !== "webgl") return undefined;
      const mount = mountRef.current;
      if (!mount || !graph.nodes.length) return undefined;
      const THREE = window.THREE;
      if (!THREE) {
        setRendererMode("canvas");
        setRenderNotice("3D 星图不可用，已切换到兼容模式。");
        return undefined;
      }

      let renderer = null;
      let resizeObserver = null;
      let animationFrame = 0;
      let disposed = false;
      let paused = document.hidden;
      const cleanupListeners = [];

      try {
        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(46, 1, 0.1, 160);
        const initialAspect = mount.clientWidth / Math.max(1, mount.clientHeight);
        const compactLayoutScale = initialAspect < 1 ? 0.8 : 1;
        const savedCamera = cameraViewRef.current;
        const defaultRadius = initialAspect < 1 ? 47 : 42;
        const savedTarget = savedCamera && savedCamera.target && typeof savedCamera.target === "object" ? savedCamera.target : null;
        const cameraState = {
          radius: savedCamera && Number.isFinite(Number(savedCamera.radius)) ? Math.max(21, Math.min(68, Number(savedCamera.radius))) : defaultRadius,
          theta: savedCamera && Number.isFinite(Number(savedCamera.theta)) ? Number(savedCamera.theta) : 0.66,
          phi: savedCamera && Number.isFinite(Number(savedCamera.phi)) ? Math.max(0.24, Math.min(Math.PI - 0.24, Number(savedCamera.phi))) : 1.04,
          target: new THREE.Vector3(
            savedTarget && Number.isFinite(Number(savedTarget.x)) ? Number(savedTarget.x) : 0,
            savedTarget && Number.isFinite(Number(savedTarget.y)) ? Number(savedTarget.y) : 0,
            savedTarget && Number.isFinite(Number(savedTarget.z)) ? Number(savedTarget.z) : 0
          )
        };
        const updateCamera = () => {
          const sinPhi = Math.sin(cameraState.phi);
          camera.position.set(
            cameraState.target.x + cameraState.radius * sinPhi * Math.cos(cameraState.theta),
            cameraState.target.y + cameraState.radius * Math.cos(cameraState.phi),
            cameraState.target.z + cameraState.radius * sinPhi * Math.sin(cameraState.theta)
          );
          camera.lookAt(cameraState.target);
          cameraViewRef.current = {
            radius: cameraState.radius,
            theta: cameraState.theta,
            phi: cameraState.phi,
            target: { x: cameraState.target.x, y: cameraState.target.y, z: cameraState.target.z }
          };
        };
        updateCamera();

        renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false, powerPreference: "high-performance" });
        renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.7));
        renderer.setClearColor(0x03060d, 1);
        renderer.domElement.className = "starmap-webgl";
        renderer.domElement.setAttribute("aria-label", "记忆星图");
        renderer.domElement.setAttribute("role", "img");
        renderer.domElement.style.touchAction = "none";
        mount.replaceChildren(renderer.domElement);

        scene.add(new THREE.HemisphereLight(0xa8ddec, 0x061216, 1.65));
        const mainLight = new THREE.PointLight(0x83d6c2, 2.4, 62);
        mainLight.position.set(7, 11, 9);
        scene.add(mainLight);
        const accentLight = new THREE.PointLight(0x719eff, 1.45, 54);
        accentLight.position.set(-14, -5, -10);
        scene.add(accentLight);

        const createGlowTexture = () => {
          const textureCanvas = document.createElement("canvas");
          textureCanvas.width = 96;
          textureCanvas.height = 96;
          const textureContext = textureCanvas.getContext("2d");
          if (!textureContext) return null;
          const glow = textureContext.createRadialGradient(48, 48, 0, 48, 48, 48);
          glow.addColorStop(0, "rgba(255,255,255,1)");
          glow.addColorStop(.16, "rgba(255,255,255,.94)");
          glow.addColorStop(.42, "rgba(255,255,255,.35)");
          glow.addColorStop(1, "rgba(255,255,255,0)");
          textureContext.fillStyle = glow;
          textureContext.fillRect(0, 0, 96, 96);
          return new THREE.CanvasTexture(textureCanvas);
        };
        const glowTexture = createGlowTexture();
        const labelLayer = labelLayerRef.current;
        if (labelLayer) labelLayer.replaceChildren();
        const nodeLabels = [];
        const createStarmapNodeLabel = (node, position, size, focused) => {
          if (!labelLayer || !node || (node.kind === "task" && !node.isHistorySource)) return null;
          const label = node.isCandidate ? `候选 · ${starmapNodeLabel(node)}` : starmapNodeLabel(node);
          const element = document.createElement("span");
          element.className = "starmap-node-label";
          if (node.isCandidate) element.classList.add("candidate");
          element.textContent = label;
          labelLayer.appendChild(element);
          nodeLabels.push({
            element: element,
            focused: focused,
            position: new THREE.Vector3(position.x, position.y + size * 2.15, position.z)
          });
          return element;
        };
        const background = new THREE.Group();
        const starPositions = [];
        const starColors = [];
        const palette = [
          new THREE.Color(0x9bd9ff),
          new THREE.Color(0xe4ecff),
          new THREE.Color(0xffd97a),
          new THREE.Color(0xbf9bff),
          new THREE.Color(0xffa272)
        ];
        const clusters = [
          { x: -19, y: 18, z: -12, radius: 14 },
          { x: 17, y: -14, z: -18, radius: 11 },
          { x: -27, y: -12, z: 9, radius: 16 },
          { x: 6, y: 7, z: 22, radius: 10 },
          { x: 29, y: 13, z: 4, radius: 13 }
        ];
        const backgroundStarCount = initialAspect < 1 ? 1040 : 2460;
        for (let index = 0; index < backgroundStarCount; index += 1) {
          const seed = starmapHash(`background-${index}`);
          const useCluster = ((seed >>> 5) % 100) < 71;
          const angle = ((seed & 0xffff) / 0xffff) * Math.PI * 2;
          const polar = (((seed >>> 16) & 0xffff) / 0xffff) * Math.PI;
          const cluster = clusters[(seed >>> 7) % clusters.length];
          const radius = useCluster
            ? Math.pow(((seed >>> 12) % 1000) / 1000, 1.82) * cluster.radius
            : 34 + ((seed >>> 7) % 54);
          const baseX = useCluster ? cluster.x : 0;
          const baseY = useCluster ? cluster.y : 0;
          const baseZ = useCluster ? cluster.z : 0;
          starPositions.push(
            baseX + Math.sin(polar) * Math.cos(angle) * radius,
            baseY + Math.cos(polar) * radius * (useCluster ? .55 : 1),
            baseZ + Math.sin(polar) * Math.sin(angle) * radius
          );
          const color = palette[(seed >>> 4) % palette.length];
          const brightStar = (seed % 100) > 91;
          const brightness = brightStar ? .72 + ((seed >>> 12) % 28) / 100 : .13 + ((seed >>> 12) % 47) / 100;
          starColors.push(color.r * brightness, color.g * brightness, color.b * brightness);
        }
        const starGeometry = new THREE.BufferGeometry();
        starGeometry.setAttribute("position", new THREE.Float32BufferAttribute(starPositions, 3));
        starGeometry.setAttribute("color", new THREE.Float32BufferAttribute(starColors, 3));
        const starMaterial = new THREE.PointsMaterial({
          vertexColors: true,
          map: glowTexture || undefined,
          size: 0.32,
          transparent: true,
          opacity: .9,
          sizeAttenuation: true,
          depthWrite: false,
          blending: THREE.AdditiveBlending
        });
        background.add(new THREE.Points(starGeometry, starMaterial));
        scene.add(background);

        const positions = new Map();
        graph.nodes.forEach((node, index) => {
          // A lone memory should be inspectable, not rendered at the edge of an otherwise empty sky.
          const position = graph.nodes.length === 1 ? { x: 0, y: 0, z: 0 } : starmapPosition(node, index);
          positions.set(node.nodeKey, {
            x: position.x * compactLayoutScale,
            y: position.y * compactLayoutScale,
            z: position.z * compactLayoutScale
          });
        });
        const selectedPosition = props.selectedKey ? positions.get(props.selectedKey) : null;
        const focusTarget = new THREE.Vector3(
          selectedPosition ? selectedPosition.x : 0,
          selectedPosition ? selectedPosition.y : 0,
          selectedPosition ? selectedPosition.z : 0
        );
        const reduceMotion = Boolean(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);
        const focusKeys = new Set();
        if (props.selectedKey) {
          focusKeys.add(props.selectedKey);
          graph.edges.forEach((edge) => {
            if (edge.source === props.selectedKey) focusKeys.add(edge.target);
            if (edge.target === props.selectedKey) focusKeys.add(edge.source);
          });
        }

        graph.edges.forEach((edge) => {
          const sourcePosition = positions.get(edge.source);
          const targetPosition = positions.get(edge.target);
          if (!sourcePosition || !targetPosition) return;
          const inFocus = !props.selectedKey || edge.source === props.selectedKey || edge.target === props.selectedKey;
          const geometry = new THREE.BufferGeometry().setFromPoints([
            new THREE.Vector3(sourcePosition.x, sourcePosition.y, sourcePosition.z),
            new THREE.Vector3(targetPosition.x, targetPosition.y, targetPosition.z)
          ]);
          const material = new THREE.LineBasicMaterial({
            color: STARMAP_RELATION_COLORS[edge.relation] || "#7890a0",
            transparent: true,
            opacity: inFocus ? Math.min(0.88, 0.25 + Number(edge.strength || 0.4) * 0.64) : 0.055
          });
          scene.add(new THREE.Line(geometry, material));
        });

        const selectableMeshes = [];
        const nodeVisuals = [];
        graph.nodes.forEach((node, index) => {
          const position = positions.get(node.nodeKey);
          if (!position) return;
          const nodeIsFocused = !props.selectedKey || focusKeys.has(node.nodeKey);
          const size = node.kind === "task"
            ? (node.isCurrent ? 1.14 : 0.84)
            : Math.max(0.36, Math.min(0.82, 0.3 + Number(node.weight || 0.4) * 0.54));
          const color = new THREE.Color(starmapNodeColor(node));
          const accent = new THREE.Color(starmapNodeAccent(node));
          const haloScale = size * (node.isCurrent || node.isPinned ? 8.7 : (node.isCandidate ? 7.5 : 6.4));
          const starScale = size * (node.isCurrent || node.isPinned ? 3.8 : 2.65);
          const coreScale = Math.max(.26, size * .82);
          const halo = new THREE.Sprite(new THREE.SpriteMaterial({
            map: glowTexture || undefined,
            color: accent,
            transparent: true,
            opacity: nodeIsFocused ? (node.isCurrent || node.isPinned ? .44 : (node.isCandidate ? .34 : .25)) : .035,
            depthWrite: false,
            depthTest: false,
            blending: THREE.AdditiveBlending
          }));
          halo.position.set(position.x, position.y, position.z);
          halo.scale.setScalar(haloScale);
          scene.add(halo);
          nodeVisuals.push({ mesh: halo, node: node, baseScale: haloScale, focused: nodeIsFocused, halo: true });

          const star = new THREE.Sprite(new THREE.SpriteMaterial({
            map: glowTexture || undefined,
            color: color,
            transparent: true,
            opacity: nodeIsFocused ? (node.isCandidate ? .78 : .98) : .18,
            depthWrite: false,
            depthTest: false,
            blending: THREE.AdditiveBlending
          }));
          star.position.copy(halo.position);
          star.scale.setScalar(starScale);
          star.userData.nodeKey = node.nodeKey;
          star.userData.nodeIndex = index;
          scene.add(star);
          selectableMeshes.push(star);
          nodeVisuals.push({ mesh: star, node: node, baseScale: starScale, focused: nodeIsFocused });

          const core = new THREE.Sprite(new THREE.SpriteMaterial({
            map: glowTexture || undefined,
            color: 0xffffff,
            transparent: true,
            opacity: nodeIsFocused ? .96 : .28,
            depthWrite: false,
            depthTest: false,
            blending: THREE.AdditiveBlending
          }));
          core.position.copy(halo.position);
          core.scale.setScalar(coreScale);
          core.userData.nodeKey = node.nodeKey;
          core.userData.nodeIndex = index;
          scene.add(core);
          selectableMeshes.push(core);
          nodeVisuals.push({ mesh: core, node: node, baseScale: coreScale, focused: nodeIsFocused, core: true });

          createStarmapNodeLabel(node, position, size, nodeIsFocused);
        });

        const raycaster = new THREE.Raycaster();
        const pointer = new THREE.Vector2();
        const drag = { active: false, moved: false, pointerId: null, x: 0, y: 0 };
        const pickNode = (event) => {
          const bounds = renderer.domElement.getBoundingClientRect();
          pointer.x = ((event.clientX - bounds.left) / bounds.width) * 2 - 1;
          pointer.y = -((event.clientY - bounds.top) / bounds.height) * 2 + 1;
          raycaster.setFromCamera(pointer, camera);
          const hit = raycaster.intersectObjects(selectableMeshes, false)[0];
          if (hit && hit.object && hit.object.userData && hit.object.userData.nodeKey) {
            const nodeKey = hit.object.userData.nodeKey;
            onSelectRef.current(nodeKey === selectedKeyRef.current ? null : nodeKey);
          } else {
            onSelectRef.current(null);
          }
        };
        const onPointerDown = (event) => {
          drag.active = true;
          drag.moved = false;
          drag.pointerId = event.pointerId;
          drag.x = event.clientX;
          drag.y = event.clientY;
          try { renderer.domElement.setPointerCapture(event.pointerId); } catch (_) { }
        };
        const onPointerMove = (event) => {
          if (!drag.active || event.pointerId !== drag.pointerId) return;
          const deltaX = event.clientX - drag.x;
          const deltaY = event.clientY - drag.y;
          if (Math.abs(deltaX) + Math.abs(deltaY) > 3) drag.moved = true;
          drag.x = event.clientX;
          drag.y = event.clientY;
          if (!drag.moved) return;
          cameraState.theta -= deltaX * 0.0065;
          cameraState.phi = Math.max(0.24, Math.min(Math.PI - 0.24, cameraState.phi + deltaY * 0.0065));
          updateCamera();
        };
        const onPointerUp = (event) => {
          if (!drag.active || event.pointerId !== drag.pointerId) return;
          if (!drag.moved) pickNode(event);
          drag.active = false;
          try { renderer.domElement.releasePointerCapture(event.pointerId); } catch (_) { }
        };
        const onWheel = (event) => {
          event.preventDefault();
          cameraState.radius = Math.max(21, Math.min(68, cameraState.radius + event.deltaY * 0.018));
          updateCamera();
        };
        const onKeyDown = (event) => {
          if (event.key === "Escape" && selectedKeyRef.current) {
            event.preventDefault();
            onSelectRef.current(null);
          }
        };
        const onWebglContextLost = (event) => {
          event.preventDefault();
          if (disposed) return;
          paused = true;
          if (animationFrame) {
            window.cancelAnimationFrame(animationFrame);
            animationFrame = 0;
          }
          setRendererMode("canvas");
          setRenderNotice("3D 星图图形上下文已丢失，已切换到兼容模式。");
        };
        renderer.domElement.addEventListener("pointerdown", onPointerDown);
        renderer.domElement.addEventListener("pointermove", onPointerMove);
        renderer.domElement.addEventListener("pointerup", onPointerUp);
        renderer.domElement.addEventListener("pointercancel", onPointerUp);
        renderer.domElement.addEventListener("wheel", onWheel, { passive: false });
        renderer.domElement.addEventListener("webglcontextlost", onWebglContextLost, false);
        document.addEventListener("keydown", onKeyDown);
        cleanupListeners.push(
          () => renderer.domElement.removeEventListener("pointerdown", onPointerDown),
          () => renderer.domElement.removeEventListener("pointermove", onPointerMove),
          () => renderer.domElement.removeEventListener("pointerup", onPointerUp),
          () => renderer.domElement.removeEventListener("pointercancel", onPointerUp),
          () => renderer.domElement.removeEventListener("wheel", onWheel),
          () => renderer.domElement.removeEventListener("webglcontextlost", onWebglContextLost),
          () => document.removeEventListener("keydown", onKeyDown)
        );

        const resize = () => {
          const width = Math.max(1, mount.clientWidth);
          const height = Math.max(1, mount.clientHeight);
          renderer.setSize(width, height, false);
          camera.aspect = width / height;
          camera.updateProjectionMatrix();
        };
        const updateNodeLabels = () => {
          const bounds = renderer.domElement.getBoundingClientRect();
          const projected = new THREE.Vector3();
          nodeLabels.forEach((nodeLabel) => {
            projected.copy(nodeLabel.position).project(camera);
            const x = (projected.x * .5 + .5) * bounds.width;
            const y = (-projected.y * .5 + .5) * bounds.height;
            const visible = projected.z > -1 && projected.z < 1 && x >= 0 && x <= bounds.width && y >= 0 && y <= bounds.height;
            const halfWidth = Math.max(18, Math.ceil(nodeLabel.element.offsetWidth / 2));
            const labelHeight = Math.max(18, nodeLabel.element.offsetHeight);
            const minX = Math.min(Math.max(8, halfWidth + 8), Math.max(8, bounds.width - halfWidth - 8));
            const maxX = Math.max(minX, bounds.width - halfWidth - 8);
            const minY = Math.min(Math.max(8, labelHeight + 8), Math.max(8, bounds.height - 8));
            const maxY = Math.max(minY, bounds.height - 8);
            const labelX = Math.max(minX, Math.min(maxX, x));
            const labelY = Math.max(minY, Math.min(maxY, y));
            nodeLabel.element.style.transform = `translate(-50%, -100%) translate(${Math.round(labelX)}px, ${Math.round(labelY)}px)`;
            nodeLabel.element.style.opacity = visible ? (nodeLabel.focused ? "1" : ".58") : "0";
          });
        };
        resize();
        if (typeof ResizeObserver === "function") {
          resizeObserver = new ResizeObserver(resize);
          resizeObserver.observe(mount);
        } else {
          window.addEventListener("resize", resize);
          cleanupListeners.push(() => window.removeEventListener("resize", resize));
        }

        const animate = (now) => {
          if (disposed || paused) return;
          if (cameraState.target.distanceToSquared(focusTarget) > .0001) {
            cameraState.target.lerp(focusTarget, reduceMotion ? 1 : .13);
            updateCamera();
          }
          const pulse = 1 + Math.sin(now * 0.0032) * 0.055;
          nodeVisuals.forEach((visual) => {
            const phase = Number(visual.mesh.userData.nodeIndex || 0);
            const multiplier = visual.node.isCurrent ? pulse : (visual.node.isPinned ? 1 + Math.sin(now * 0.0024 + phase) * 0.025 : 1);
            visual.mesh.scale.setScalar(visual.baseScale * multiplier);
          });
          background.rotation.y = now * 0.000018;
          renderer.render(scene, camera);
          updateNodeLabels();
          animationFrame = window.requestAnimationFrame(animate);
        };
        const onVisibilityChange = () => {
          paused = document.hidden;
          if (paused && animationFrame) {
            window.cancelAnimationFrame(animationFrame);
            animationFrame = 0;
          } else if (!paused && !animationFrame) {
            animationFrame = window.requestAnimationFrame(animate);
          }
        };
        document.addEventListener("visibilitychange", onVisibilityChange);
        cleanupListeners.push(() => document.removeEventListener("visibilitychange", onVisibilityChange));
        if (!paused) animationFrame = window.requestAnimationFrame(animate);
        setRenderNotice("");

        return () => {
          disposed = true;
          if (animationFrame) window.cancelAnimationFrame(animationFrame);
          if (resizeObserver) resizeObserver.disconnect();
          cleanupListeners.forEach((cleanup) => cleanup());
          scene.traverse((object) => {
            if (object.geometry) object.geometry.dispose();
            if (object.material) {
              const materials = Array.isArray(object.material) ? object.material : [object.material];
              materials.forEach((material) => material && material.dispose && material.dispose());
            }
          });
          if (glowTexture) glowTexture.dispose();
          if (labelLayer) labelLayer.replaceChildren();
          renderer.dispose();
          if (renderer.domElement.parentNode === mount) mount.removeChild(renderer.domElement);
        };
      } catch (error) {
        if (renderer) renderer.dispose();
        console.warn("[super-brain:starmap-webgl]", error);
        setRendererMode("canvas");
        setRenderNotice("3D 星图启动失败，已切换到兼容模式。");
        return undefined;
      }
    }, [graph, props.selectedKey, rendererMode]);

    const selectedTags = selectedNode && Array.isArray(selectedNode.tags) ? selectedNode.tags : [];
    const selectedHasIntegrityIssue = starmapNodeHasDisplayIntegrityIssue(selectedNode);
    const individualMemoryNodes = graph.nodes.filter((node) => node.kind !== "task" && node.kind !== "cluster");
    const groupedMemoryCount = graph.nodes
      .filter((node) => node.kind === "cluster")
      .reduce((total, node) => total + Math.max(0, Number(node.representedCount || 0)), 0);
    const representedMemoryCount = individualMemoryNodes.length + groupedMemoryCount;
    const selectableNodes = graph.nodes.filter((node) => node.kind !== "task");
    const fallbackUnavailable = useCallback(() => {
      setRendererMode("list");
      setRenderNotice("此设备的图形绘制不可用，已切换到可访问记忆列表。");
    }, []);
    const nodePicker = selectableNodes.length > 0 ? h("section", { className: "starmap-node-picker", key: "picker", "aria-label": "选择记忆" }, [
      h("p", { className: "starmap-node-picker-label", key: "label" }, "记忆节点"),
      h("div", { className: "starmap-node-list", role: "list", key: "list" }, selectableNodes.map((node) => h("div", { role: "listitem", key: node.nodeKey }, h("button", {
        type: "button",
        className: props.selectedKey === node.nodeKey ? "starmap-node-option selected" : "starmap-node-option",
        "aria-pressed": props.selectedKey === node.nodeKey,
        onClick: () => props.onSelect(props.selectedKey === node.nodeKey ? null : node.nodeKey),
        title: `查看${starmapNodeDisplayTitle(node)}`
      }, [
        h("i", { style: { backgroundColor: starmapNodeAccent(node) }, key: "dot" }),
        h("span", { key: "kind" }, text(node.kindLabel) || "记忆"),
        h("strong", { key: "title" }, starmapNodeDisplayTitle(node))
      ]))))
    ]) : null;
    return h("div", { className: "starmap-view" }, [
      h("div", { className: "starmap-toolbar", key: "toolbar" }, [
        h("div", { className: "starmap-filters", role: "group", "aria-label": "记忆类型", key: "filters" }, STARMAP_FILTERS.map((filter) => h("button", {
          key: filter.key,
          className: props.filter === filter.key ? "starmap-filter active" : "starmap-filter",
          onClick: () => props.onFilterChange(filter.key),
          title: `只显示${filter.label}记忆`
        }, filter.label))),
        h("div", { className: "starmap-toolbar-summary", key: "summary" }, [
          h("span", { key: "count" }, groupedMemoryCount ? `展开 ${individualMemoryNodes.length} 条，聚合 ${groupedMemoryCount} 条` : `显示 ${representedMemoryCount} 条记忆`),
          candidateCount ? h("span", { className: "starmap-candidate-summary", key: "candidates" }, `历史候选 ${candidateCount} 组${historySourceRecords ? ` / ${historySourceRecords} 条来源` : ""}`) : null,
          Number(counts.excludedMemory || 0) ? h("span", { key: "excluded" }, `按治理隐藏 ${Number(counts.excludedMemory || 0)} 条`): null,
          rendererMode === "canvas" ? h("span", { key: "mode" }, "兼容模式") : null,
          h("span", { className: "starmap-policy", key: "policy" }, text(model.relationshipPolicyLabel) || "仅显示已验证关联")
        ])
      ]),
      h("div", { className: "starmap-workspace", key: "workspace" }, [
        h("section", { className: "starmap-canvas-wrap", key: "canvas-wrap" }, [
          graph.nodes.length ? (rendererMode === "webgl"
            ? h("div", { ref: mountRef, className: "starmap-canvas", "data-testid": "memory-starmap-canvas", key: "canvas" })
            : (rendererMode === "canvas"
              ? h(CanvasStarmap, { nodes: graph.nodes, edges: graph.edges, selectedKey: props.selectedKey, onSelect: props.onSelect, onUnavailable: fallbackUnavailable, key: "canvas-2d" })
              : h("div", { className: "starmap-fallback-list", key: "list" }, [
                h("p", { key: "notice" }, "此设备无法绘制星图，已保留可访问的记忆列表。"),
                h("div", { className: "starmap-fallback-items", role: "list", key: "items" }, selectableNodes.map((node) => h("button", {
                  type: "button",
                  role: "listitem",
                  className: props.selectedKey === node.nodeKey ? "starmap-node-option selected" : "starmap-node-option",
                  onClick: () => props.onSelect(props.selectedKey === node.nodeKey ? null : node.nodeKey),
                  key: node.nodeKey
                }, [
                  h("i", { style: { backgroundColor: starmapNodeAccent(node) }, key: "dot" }),
                  h("span", { key: "kind" }, text(node.kindLabel) || "记忆"),
                  h("strong", { key: "title" }, starmapNodeDisplayTitle(node))
                ])))
              ])))
            : h("div", { className: "starmap-empty", key: "empty" }, "还没有可显示的记忆"),
          rendererMode === "webgl" ? h("div", { ref: labelLayerRef, className: "starmap-label-layer", "aria-hidden": "true", key: "labels" }) : null,
          renderNotice ? h("p", { className: "starmap-render-notice", key: "notice" }, renderNotice) : null,
          h("div", { className: "starmap-legend", key: "legend" }, [
            h("span", { className: "starmap-legend-candidate", key: "candidate" }, [h("i", { style: { backgroundColor: STARMAP_NODE_COLORS.candidate }, key: "dot" }), "历史候选（待审核）"]),
            ...STARMAP_FILTERS.slice(1).map((filter) => h("span", { key: filter.key }, [h("i", { style: { backgroundColor: filter.color || STARMAP_NODE_COLORS[filter.key] }, key: "dot" }), filter.label]))
          ])
        ]),
        h("aside", { className: "starmap-details", key: "details", "aria-live": "polite" }, (selectedNode ? [
          h("div", { className: "starmap-detail-heading", key: "heading" }, [
            h("div", { className: "starmap-detail-meta", key: "meta" }, [
              h("span", { className: "starmap-kind", style: { borderColor: starmapNodeAccent(selectedNode), color: starmapNodeAccent(selectedNode) }, key: "kind" }, text(selectedNode.kindLabel) || "记忆"),
              selectedNode.isCandidate ? h("span", { className: "starmap-candidate-badge", key: "candidate" }, "只读候选") : null,
              selectedNode.isPinned ? h("span", { className: "starmap-pinned", key: "pinned" }, "已固定") : null
            ]),
            h("button", { type: "button", className: "starmap-clear-selection", onClick: clearStarmapSelection, title: "取消选择（Esc）", "aria-label": "取消选择当前记忆", key: "clear" }, "取消选择")
          ]),
          h("h3", { key: "title" }, selectedHasIntegrityIssue ? "内容编码异常，等待修复" : starmapNodeDisplayTitle(selectedNode)),
          h("p", { className: "starmap-detail-summary", key: "summary" }, selectedHasIntegrityIssue ? "这条记录的原始文本存在不可逆编码缺失，已隔离显示并禁止回写。" : (displayText(text(selectedNode.summary)) || "暂无内容摘要")),
          h("dl", { className: "starmap-detail-list", key: "facts" }, [
            h("div", { key: "state" }, [h("dt", null, "状态"), h("dd", null, text(selectedNode.stateLabel) || "已记录")]),
            h("div", { key: "relations" }, [h("dt", null, "直接关联"), h("dd", null, `${directRelationCount} 条`)]),
            selectedNode.isCandidate && Number(selectedNode.candidateSourceCount || 0) ? h("div", { key: "candidate-source" }, [h("dt", null, "历史来源"), h("dd", null, `${Number(selectedNode.candidateSourceCount)} 条记录汇总；未自动采用`)]): null,
            selectedNode.isCandidate && text(selectedNode.candidateReason) ? h("div", { key: "candidate-reason" }, [h("dt", null, "使用状态"), h("dd", null, displayText(text(selectedNode.candidateReason)))]) : null,
            text(selectedNode.date) ? h("div", { key: "date" }, [h("dt", null, "记录日期"), h("dd", null, text(selectedNode.date).slice(0, 10))]) : null,
            !selectedHasIntegrityIssue && text(source.taskTitle) ? h("div", { key: "task" }, [h("dt", null, "关联任务"), h("dd", null, displayText(text(source.taskTitle)))]) : null,
            !selectedHasIntegrityIssue && text(source.conversationTitle) ? h("div", { key: "conversation" }, [h("dt", null, "来源对话"), h("dd", null, displayText(text(source.conversationTitle)))]) : null
          ]),
          !selectedHasIntegrityIssue && selectedTags.length ? h("div", { className: "starmap-detail-tags", key: "tags" }, selectedTags.map((tag) => h("span", { key: tag }, displayText(tag)))) : null
        ] : [
          h("p", { className: "starmap-detail-label", key: "label" }, "记忆详情"),
          h("h3", { key: "title" }, "尚未选择记忆"),
          h("p", { className: "starmap-detail-summary", key: "summary" }, `本视图显示 ${representedMemoryCount} 条记忆，${graph.edges.length} 条关联${candidateCount ? `；其中 ${candidateCount} 组为只读历史候选，不会自动注入。` : "。"}${Number(counts.excludedMemory || 0) ? `另有 ${Number(counts.excludedMemory || 0)} 条因治理状态不显示。` : ""}`)
        ]).concat(nodePicker ? [nodePicker] : []))
      ])
    ]);
  }

  function AmbientStarfield() {
    const canvasRef = useRef(null);

    useEffect(() => {
      const canvas = canvasRef.current;
      if (!canvas) return undefined;
      const context = canvas.getContext("2d");
      if (!context) return undefined;
      const colors = ["150, 204, 255", "204, 219, 255", "255, 217, 122", "176, 122, 255", "255, 144, 96"];
      const motionQuery = window.matchMedia ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;
      let viewportWidth = 1;
      let viewportHeight = 1;
      let stars = [];
      let frame = 0;
      let lastFrame = 0;
      let hidden = document.hidden;

      const randomFactory = () => {
        let seed = 290413;
        return () => {
          seed = (seed * 16807) % 2147483647;
          return (seed - 1) / 2147483646;
        };
      };

      const resize = () => {
        viewportWidth = Math.max(window.innerWidth || 1, 1);
        viewportHeight = Math.max(window.innerHeight || 1, 1);
        const density = Math.min(window.devicePixelRatio || 1, 1.35);
        canvas.width = Math.round(viewportWidth * density);
        canvas.height = Math.round(viewportHeight * density);
        canvas.style.width = `${viewportWidth}px`;
        canvas.style.height = `${viewportHeight}px`;
        context.setTransform(density, 0, 0, density, 0, 0);

        const random = randomFactory();
        const starCount = viewportWidth < 760 ? 166 : 368;
        const clusters = [
          { x: .12, y: .12, radius: Math.max(108, viewportWidth * .105) },
          { x: .78, y: .18, radius: Math.max(96, viewportWidth * .085) },
          { x: .28, y: .72, radius: Math.max(126, viewportWidth * .12) },
          { x: .83, y: .78, radius: Math.max(118, viewportWidth * .11) },
          { x: .52, y: .48, radius: Math.max(92, viewportWidth * .075) }
        ];
        stars = Array.from({ length: starCount }, (_, index) => {
          const cluster = random() < .48 ? clusters[Math.floor(random() * clusters.length)] : null;
          const angle = random() * Math.PI * 2;
          const radius = cluster ? Math.pow(random(), 1.85) * cluster.radius : 0;
          const x = Math.max(-8, Math.min(viewportWidth + 8, cluster ? cluster.x * viewportWidth + Math.cos(angle) * radius : random() * viewportWidth));
          const y = Math.max(-8, Math.min(viewportHeight + 8, cluster ? cluster.y * viewportHeight + Math.sin(angle) * radius * .62 : random() * viewportHeight));
          const beacon = random() > .968;
          const bright = beacon || random() > .88;
          return {
            x: x,
            y: y,
            size: beacon ? 2.7 + random() * 1.8 : (bright ? 1.15 + random() * 1.2 : .34 + random() * .76),
            alpha: beacon ? .9 : (bright ? .68 : .18 + random() * .38),
            phase: random() * Math.PI * 2,
            drift: .1 + random() * .28,
            depth: .25 + random() * .75,
            color: colors[index % colors.length],
            beacon: beacon,
            bright: bright
          };
        });
      };

      const draw = (timestamp) => {
        context.clearRect(0, 0, viewportWidth, viewportHeight);
        const time = timestamp / 1000;

        stars.forEach((star, index) => {
          const twinkle = .74 + Math.sin(time * star.drift + star.phase) * .26;
          const x = star.x + Math.sin(time * .044 * star.depth + star.phase) * (star.bright ? 1.9 : .7);
          const y = star.y + Math.cos(time * .033 * star.depth + star.phase) * (star.bright ? .8 : .35);
          const radius = star.size * (star.bright ? 1.06 : 1);
          context.fillStyle = `rgba(${star.color}, ${star.alpha * twinkle})`;
          if (star.bright) {
            context.shadowBlur = star.beacon ? 18 : 7;
            context.shadowColor = `rgba(${star.color}, ${Math.min(.7, star.alpha * twinkle)})`;
          }
          context.beginPath();
          context.arc(x, y, radius, 0, Math.PI * 2);
          context.fill();
          context.shadowBlur = 0;
        });

        context.lineWidth = .45;
        for (let index = 0; index < Math.min(14, stars.length - 1); index += 1) {
          const a = stars[index * 7];
          const b = stars[index * 7 + 2];
          if (!a || !b) continue;
          const phase = (time * .12 + index * .43) % 1;
          context.strokeStyle = `rgba(108, 164, 255, ${.016 + phase * .025})`;
          context.beginPath();
          context.moveTo(a.x, a.y);
          context.lineTo(b.x, b.y);
          context.stroke();
        }

        const meteorLanes = [
          { cycle: 11.5, offset: .08, startX: .73, startY: .06, endX: .22, endY: .52, color: "255, 217, 122", tail: 84 },
          { cycle: 17.3, offset: .43, startX: .96, startY: .28, endX: .44, endY: .76, color: "108, 221, 255", tail: 68 },
          { cycle: 23.1, offset: .71, startX: .54, startY: -.04, endX: .12, endY: .37, color: "188, 139, 255", tail: 61 }
        ];
        meteorLanes.forEach((meteor) => {
          const progress = (time / meteor.cycle + meteor.offset) % 1;
          if (progress >= .135) return;
          const travel = progress / .135;
          const startX = viewportWidth * meteor.startX;
          const startY = viewportHeight * meteor.startY;
          const endX = viewportWidth * meteor.endX;
          const endY = viewportHeight * meteor.endY;
          const headX = startX + (endX - startX) * travel;
          const headY = startY + (endY - startY) * travel;
          const angle = Math.atan2(endY - startY, endX - startX);
          const tailX = headX - Math.cos(angle) * meteor.tail;
          const tailY = headY - Math.sin(angle) * meteor.tail;
          const opacity = Math.sin(travel * Math.PI);
          const gradient = context.createLinearGradient(tailX, tailY, headX, headY);
          gradient.addColorStop(0, `rgba(${meteor.color}, 0)`);
          gradient.addColorStop(.74, `rgba(${meteor.color}, ${.13 * opacity})`);
          gradient.addColorStop(1, `rgba(${meteor.color}, ${.78 * opacity})`);
          context.strokeStyle = gradient;
          context.lineWidth = 1;
          context.shadowBlur = 10;
          context.shadowColor = `rgba(${meteor.color}, ${.34 * opacity})`;
          context.beginPath();
          context.moveTo(tailX, tailY);
          context.lineTo(headX, headY);
          context.stroke();
          context.shadowBlur = 0;
        });
      };

      const render = (timestamp) => {
        if (hidden || (motionQuery && motionQuery.matches)) {
          frame = 0;
          return;
        }
        if (timestamp - lastFrame >= 55) {
          lastFrame = timestamp;
          draw(timestamp);
        }
        frame = window.requestAnimationFrame(render);
      };

      const onVisibilityChange = () => {
        hidden = document.hidden;
        if (hidden) {
          if (frame) window.cancelAnimationFrame(frame);
          frame = 0;
          return;
        }
        if (!(motionQuery && motionQuery.matches) && !frame) frame = window.requestAnimationFrame(render);
      };
      const onMotionChange = () => {
        if (motionQuery && motionQuery.matches) {
          if (frame) window.cancelAnimationFrame(frame);
          frame = 0;
          draw(0);
        } else if (!hidden && !frame) {
          frame = window.requestAnimationFrame(render);
        }
      };

      resize();
      draw(0);
      if (!hidden && !(motionQuery && motionQuery.matches)) frame = window.requestAnimationFrame(render);
      window.addEventListener("resize", resize);
      document.addEventListener("visibilitychange", onVisibilityChange);
      if (motionQuery) motionQuery.addEventListener("change", onMotionChange);
      return () => {
        if (frame) window.cancelAnimationFrame(frame);
        window.removeEventListener("resize", resize);
        document.removeEventListener("visibilitychange", onVisibilityChange);
        if (motionQuery) motionQuery.removeEventListener("change", onMotionChange);
      };
    }, []);

    return h("canvas", { className: "ambient-starfield", ref: canvasRef, "aria-hidden": "true" });
  }

  function App() {
    const [kind, setKind] = useState("note");
    const [categoryKey, setCategoryKey] = useState("memory");
    const [lifecycle, setLifecycle] = useState("active");
    const [query, setQuery] = useState("");
    const [searchInput, setSearchInput] = useState("");
    const [cards, setCards] = useState([]);
    const [selected, setSelected] = useState(null);
    const [draft, setDraft] = useState(() => newDraft("note"));
    const [isNew, setIsNew] = useState(true);
    const [busy, setBusy] = useState(false);
    const [status, setStatus] = useState("正在加载本地记忆");
    const [history, setHistory] = useState([]);
    const [replaceTarget, setReplaceTarget] = useState(null);
    const [systemView, setSystemView] = useState(false);
    const [overview, setOverview] = useState(null);
    const [timelineView, setTimelineView] = useState(true);
    const [timeline, setTimeline] = useState(null);
    const [starmapView, setStarmapView] = useState(false);
    const [starmap, setStarmap] = useState(null);
    const [starmapFilter, setStarmapFilter] = useState("all");
    const [starmapSelectedKey, setStarmapSelectedKey] = useState(null);
    const [skillsView, setSkillsView] = useState(false);
    const [skills, setSkills] = useState(null);
    const [healthView, setHealthView] = useState(false);
    const [health, setHealth] = useState(null);
    const [profileView, setProfileView] = useState(false);
    const [profile, setProfile] = useState(null);
    const [trashView, setTrashView] = useState(false);
    const [trashCards, setTrashCards] = useState([]);
    const [captureDraft, setCaptureDraft] = useState(() => readCaptureDraft());
    const [learningPlan, setLearningPlan] = useState(null);
    const [drawerOpen, setDrawerOpen] = useState(false);
    const [moreOpen, setMoreOpen] = useState(false);
    const [memoryGeneration, setMemoryGeneration] = useState(0);
    const [lastSyncedAt, setLastSyncedAt] = useState(0);
    const activeCategory = useMemo(() => memoryCategoryByKey(categoryKey), [categoryKey]);
    const forgotten = selected && selected.forgotten;
    const selectedHasIntegrityIssue = Boolean(selected && cardHasDisplayIntegrityIssue(selected));
    const isQuickCapture = isNew && !replaceTarget;
    const recoveredDraftRef = useRef(false);
    const captureRequestRef = useRef(null);
    const navigationEpochRef = useRef(0);
    const cardsRequestRef = useRef(0);
    const timelineRequestRef = useRef(0);
    const editorPanelRef = useRef(null);
    const selectStarmapNode = useCallback((nodeKey) => setStarmapSelectedKey(nodeKey || null), []);
    const markMemoryChanged = useCallback(() => setMemoryGeneration((previous) => previous + 1), []);

    useEffect(() => {
      persistCaptureDraft(captureDraft);
    }, [captureDraft]);

    const loadCards = useCallback(async (preserveStatus) => {
      const requestEpoch = ++cardsRequestRef.current;
      setBusy(true);
      try {
        const visibleLifecycles = lifecycle === "all" ? ["active", "proposed"] : [lifecycle];
        const body = await request("/api/read", { operation: "cards", kinds: activeCategory.kinds, lifecycles: visibleLifecycles, query: query, limit: 100, offset: 0 });
        if (requestEpoch !== cardsRequestRef.current) return;
        setCards(Array.isArray(body.items) ? body.items : []);
        setLastSyncedAt(Date.now());
        if (!preserveStatus && !recoveredDraftRef.current) setStatus((body.items || []).length ? `${body.items.length} 条${activeCategory.label}` : `还没有${activeCategory.label}`);
      } catch (error) {
        if (requestEpoch === cardsRequestRef.current) setStatus(`读取失败：${error.message || "未知错误"}`);
      } finally {
        if (requestEpoch === cardsRequestRef.current) setBusy(false);
      }
    }, [activeCategory, lifecycle, query]);

    const loadLearningPlan = useCallback(async () => {
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "learning_plan", maxProposals: 12 });
        setLearningPlan(body);
        setLastSyncedAt(Date.now());
        const count = Array.isArray(body && body.proposals) ? body.proposals.length : 0;
        setStatus(count ? `已生成 ${count} 条整理建议；查看后再由你决定。` : "目前没有需要整理的候选。");
      } catch (error) {
        setStatus(`读取整理建议失败：${error.message || "未知错误"}`);
      } finally {
        setBusy(false);
      }
    }, []);

    const loadTrash = useCallback(async () => {
      const requestEpoch = ++navigationEpochRef.current;
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "cards", lifecycles: ["trashed"], limit: 100, offset: 0 });
        if (requestEpoch !== navigationEpochRef.current) return;
        const items = Array.isArray(body.items) ? body.items : [];
        setTrashCards(items);
        setLastSyncedAt(Date.now());
        setStatus(items.length ? `已读取回收站：${items.length} 条记录` : "回收站是空的");
      } catch (error) {
        setStatus(`读取回收站失败：${error.message || "未知错误"}`);
      } finally {
        if (requestEpoch === navigationEpochRef.current) setBusy(false);
      }
    }, []);

    const loadStarmap = useCallback(async () => {
      const requestEpoch = ++navigationEpochRef.current;
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "starmap" });
        if (requestEpoch !== navigationEpochRef.current) return;
        setStarmap(body);
        setLastSyncedAt(Date.now());
        const counts = body && typeof body.counts === "object" ? body.counts : {};
        setStatus(`已读取记忆星图：${Number(counts.shownMemory || 0)} 条记忆，${Number(counts.relationships || 0)} 条关联`);
      } catch (error) {
        setStatus(`读取记忆星图失败：${error.message || "未知错误"}`);
      } finally {
        if (requestEpoch === navigationEpochRef.current) setBusy(false);
      }
    }, []);

    const loadTimeline = useCallback(async (preserveStatus) => {
      const requestEpoch = ++timelineRequestRef.current;
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "timeline", limit: 100, offset: 0 });
        if (requestEpoch !== timelineRequestRef.current) return;
        setTimeline(body);
        setLastSyncedAt(Date.now());
        if (!preserveStatus) setStatus("已读取总记忆记录");
      } catch (error) {
        if (requestEpoch === timelineRequestRef.current) setStatus(`读取总记忆记录失败：${error.message || "未知错误"}`);
      } finally {
        if (requestEpoch === timelineRequestRef.current) setBusy(false);
      }
    }, []);

    const activateSpecialView = (view) => {
      recoveredDraftRef.current = false;
      setReplaceTarget(null);
      setDrawerOpen(false);
      setMoreOpen(false);
      setSystemView(view === "overview");
      setTimelineView(view === "timeline");
      setStarmapView(view === "starmap");
      setSkillsView(view === "skills");
      setHealthView(view === "health");
      setProfileView(view === "profile");
      setTrashView(view === "trash");
      setStarmapSelectedKey(null);
      setSelected(null);
      setHistory([]);
    };

    useEffect(() => {
      if (starmapView) {
        loadStarmap();
        return undefined;
      }
      if (trashView) {
        loadTrash();
        return undefined;
      }
      if (systemView || skillsView || healthView || profileView) return undefined;
      if (!timelineView) {
        loadCards();
        return undefined;
      }
      loadTimeline();
      return undefined;
    }, [loadCards, loadStarmap, loadTimeline, loadTrash, memoryGeneration, systemView, starmapView, timelineView, skillsView, healthView, profileView, trashView]);

    useEffect(() => {
      const refreshOnFocus = () => {
        if (starmapView && document.visibilityState === "visible") loadStarmap();
      };
      window.addEventListener("focus", refreshOnFocus);
      return () => window.removeEventListener("focus", refreshOnFocus);
    }, [loadStarmap, starmapView]);

    useEffect(() => {
      if (isQuickCapture || systemView || timelineView || starmapView || skillsView || healthView || profileView || trashView) return undefined;
      let cancelled = false;
      const currentRevision = isNew ? 0 : (selected ? selected.revision : 0);
      request("/api/draft", { operation: "get", cardId: draft.cardId, currentRevision: currentRevision })
        .then((body) => {
          if (cancelled || !body.available || !body.draft || typeof body.draft !== "object") return;
          setDraft(body.draft);
          recoveredDraftRef.current = true;
          setStatus("已恢复未保存草稿；正式保存后会生成新的受控修订。");
        })
        .catch(() => { });
      return () => { cancelled = true; };
    }, [draft.cardId, isNew, isQuickCapture, selected ? selected.revision : 0, systemView, timelineView, starmapView, skillsView, healthView, profileView, trashView]);

    useEffect(() => {
      if (isQuickCapture || systemView || timelineView || starmapView || skillsView || healthView || profileView || trashView || forgotten || selectedHasIntegrityIssue || busy || !hasDraftContent(draft)) return undefined;
      const currentRevision = isNew ? 0 : (selected ? selected.revision : 0);
      const timer = window.setTimeout(() => {
        request("/api/draft", { operation: "save", cardId: draft.cardId, baseRevision: currentRevision, draft: draft })
          .catch((error) => { if (error.message === "BRAIN_CONTROL_STALE_REVISION") setStatus("草稿未覆盖新版本：请刷新后再合并。"); });
      }, 1000);
      return () => window.clearTimeout(timer);
    }, [draft, isNew, isQuickCapture, selected ? selected.revision : 0, systemView, timelineView, starmapView, skillsView, healthView, profileView, trashView, forgotten, selectedHasIntegrityIssue, busy]);

    const startMemoryCapture = (nextCategoryKey) => {
      const nextCategory = memoryCategoryByKey(nextCategoryKey || categoryKey);
      navigationEpochRef.current += 1;
      recoveredDraftRef.current = false;
      setReplaceTarget(null);
      setKind(nextCategory.defaultKind);
      setCategoryKey(nextCategory.key);
      setSystemView(false);
      setTimelineView(false);
      setStarmapView(false);
      setSkillsView(false);
      setHealthView(false);
      setProfileView(false);
      setTrashView(false);
      setSelected(null);
      setIsNew(true);
      setDrawerOpen(true);
      setMoreOpen(false);
      setHistory([]);
      setStatus(hasCaptureDraftContent(captureDraft) ? "已保留未保存输入；补全后直接保存即可。" : "新建记忆：写下问题和想怎么做即可。");
    };

    const openMemoryLibrary = (nextCategoryKey = "all") => {
      navigationEpochRef.current += 1;
      recoveredDraftRef.current = false;
      setReplaceTarget(null);
      setCategoryKey(nextCategoryKey);
      setQuery("");
      setSearchInput("");
      setLifecycle("active");
      setSystemView(false);
      setTimelineView(false);
      setStarmapView(false);
      setSkillsView(false);
      setHealthView(false);
      setProfileView(false);
      setTrashView(false);
      setSelected(null);
      setDrawerOpen(false);
      setMoreOpen(false);
      setHistory([]);
      setStatus("正在读取本机记忆");
    };

    const runSearch = () => {
      const normalized = searchInput.trim();
      if (!normalized) {
        openTimeline();
        return;
      }
      openMemoryLibrary("all");
      setQuery(normalized);
      setStatus(`正在搜索“${normalized}”`);
    };

    const clearSearch = () => {
      setSearchInput("");
      setQuery("");
      openTimeline();
    };

    const closeDrawer = () => {
      setDrawerOpen(false);
      setHistory([]);
      setMoreOpen(false);
    };

    const openCard = async (card, options) => {
      const requestEpoch = ++navigationEpochRef.current;
      recoveredDraftRef.current = false;
      setReplaceTarget(null);
      setBusy(true);
      try {
        const cardRef = text(card && card.cardRef);
        const body = await request("/api/read", cardRef ? { operation: "card", cardRef: cardRef } : { operation: "card", cardId: card.cardId });
      if (requestEpoch !== navigationEpochRef.current) return;
      if (!body.card) return;
        setSystemView(false);
        setTimelineView(false);
        setStarmapView(false);
        setSkillsView(false);
        setHealthView(false);
        setProfileView(false);
        setTrashView(false);
        const detail = body.card;
        setSelected(detail);
        setKind(detail.kind);
        if (!query) setCategoryKey(text(options && options.categoryKey) || memoryCategoryForKind(detail.kind).key);
        setDraft({ cardId: detail.cardId, kind: detail.kind, scope: detail.scope, lifecycle: detail.lifecycle === "proposed" ? "proposed" : "active", authority: detail.authority || "user_confirmed", privacyClass: detail.privacyClass, title: detail.title, payload: detail.payload || defaultPayload(detail.kind), evidenceRefs: detail.evidenceRefs || [] });
        setIsNew(false);
        setHistory([]);
        setDrawerOpen(true);
        setMoreOpen(false);
        setStatus(`已打开第 ${detail.revision} 版`);
      } catch (error) { setStatus(`打开失败：${error.message || "未知错误"}`); }
      finally { setBusy(false); }
    };

    const createNew = () => startMemoryCapture(categoryKey);

    const startReplacement = () => {
      if (!selected || selected.kind !== "decision" || !["active", "proposed"].includes(selected.lifecycle)) return;
      const isHardDecision = selected.payload && selected.payload.enforcement === "completion_gate";
      if (isHardDecision && !window.confirm("新决策保存后，旧的完成前检查会立即失效。确认开始替换吗？")) return;
      navigationEpochRef.current += 1;
      recoveredDraftRef.current = false;
      setReplaceTarget({
        cardId: selected.cardId,
        expectedRevision: selected.revision,
        title: selected.title,
        impactAcknowledged: isHardDecision
      });
      setKind("decision");
      setCategoryKey(memoryCategoryForKind("decision").key);
      setSystemView(false);
      setTimelineView(false);
      setStarmapView(false);
      setSkillsView(false);
      setHealthView(false);
      setProfileView(false);
      setTrashView(false);
      setSelected(null);
      setDraft(newDraft("decision"));
      setIsNew(true);
      setDrawerOpen(true);
      setMoreOpen(false);
      setHistory([]);
      setStatus(`正在替换“${selected.title}”；保存新决策后会原子更新旧决策。`);
    };

    const adoptReflection = async () => {
      if (!selected || selected.kind !== "reflection" || !selected.payload) return;
      const state = text(selected.payload.candidateState);
      const evidence = list(selected.payload.evidence);
      const systemCandidate = isSystemLearningCandidate(selected);
      const suggestedKind = learningSuggestionKind(selected);
      const trial = reflectionTrial(selected);
      const legacyExperience = !suggestedKind && !systemCandidate;
      const targetKind = suggestedKind || (legacyExperience ? "experience" : "");
      if (!targetKind || !REFLECTION_PROMOTABLE_KINDS.has(targetKind)) {
        setStatus(targetKind === "decision" ? "决定需要专门的决定回执流程；当前候选不会直接采纳。" : "这条候选的整理类型不明确或不可直接晋升，已保持为学习记录。");
        return;
      }
      if (!(["validated", "staged"].includes(state)) || !evidence.length) {
        setStatus("先把反思标为已验证或准备采纳，并填写至少一条实际证据。");
        return;
      }
      if (systemCandidate && (trial.verdict !== "passed" || !trial.hasReceipt)) {
        setStatus("当前试用还没有通过；请先完成有任务范围的试用回执，再整理这条记忆。");
        return;
      }
      const targetLabel = KINDS[targetKind] ? KINDS[targetKind].label : "记忆";
      if (!window.confirm(`这会把当前候选整理为${targetLabel}，并保留原反思作为依据。继续吗？`)) return;
      setBusy(true);
      try {
        const targetCardId = "card-" + crypto.randomUUID();
        const body = await request("/api/command", {
          action: "adopt_reflection",
          requestId: crypto.randomUUID(),
          reflectionCardId: selected.cardId,
          expectedRevision: selected.revision,
          adoptedCardId: targetCardId,
          targetKind,
          ...(targetKind === "experience" ? { experienceCardId: targetCardId } : {}),
          reason: "Control Center adopt evidenced reflection"
        });
        markMemoryChanged();
        await loadCards(true);
        const adoptedId = text(body && body.receipt && body.receipt.adopted && body.receipt.adopted.cardId)
          || text(body && body.receipt && body.receipt.experience && body.receipt.experience.cardId);
        const refreshed = await request("/api/read", { operation: "card", cardId: adoptedId || selected.cardId });
        if (refreshed.card) {
          setSelected(refreshed.card);
          setKind(refreshed.card.kind);
          setCategoryKey(memoryCategoryForKind(refreshed.card.kind).key);
          setDraft({ cardId: refreshed.card.cardId, kind: refreshed.card.kind, scope: refreshed.card.scope, lifecycle: refreshed.card.lifecycle, authority: refreshed.card.authority || "user_confirmed", privacyClass: refreshed.card.privacyClass, title: refreshed.card.title, payload: refreshed.card.payload || defaultPayload(refreshed.card.kind), evidenceRefs: refreshed.card.evidenceRefs || [] });
          setIsNew(false);
        }
        const adoptedTitle = text(body && body.receipt && body.receipt.adopted && body.receipt.adopted.title)
          || text(body && body.receipt && body.receipt.experience && body.receipt.experience.title)
          || targetLabel;
        setStatus(`已整理为${targetLabel}：“${adoptedTitle}”。原反思仍保留为依据。`);
      } catch (error) {
        const code = error && error.message;
        const friendly = {
          BRAIN_UI_REFLECTION_SUGGESTION_INVALID: "候选的整理类型不明确，未执行采纳。",
          BRAIN_UI_REFLECTION_TARGET_NOT_PROMOTABLE: "该类型必须走专门流程，未执行采纳。",
          BRAIN_UI_REFLECTION_TARGET_MISMATCH: "整理类型与候选建议不一致，未执行采纳。",
          BRAIN_UI_REFLECTION_TRIAL_NOT_PASSED: "当前试用没有通过，未执行采纳。"
        }[code];
        setStatus(code === "BRAIN_CONTROL_STALE_REVISION" ? "反思刚刚发生变化，未采纳；请刷新后再核对。" : (friendly || `整理为${targetLabel}失败：${code || "未知错误"}`));
      } finally { setBusy(false); }
    };

    const openOverview = async () => {
      const requestEpoch = ++navigationEpochRef.current;
      activateSpecialView("overview");
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "overview" });
        if (requestEpoch !== navigationEpochRef.current) return;
        setOverview(body);
        setStatus("已读取当前任务进度");
      } catch (error) { setStatus(`读取状态失败：${error.message || "未知错误"}`); }
      finally { if (requestEpoch === navigationEpochRef.current) setBusy(false); }
    };

    const saveTaskRetentionSettings = async (completedDays, trashDays, expectedRevision) => {
      if (!Number.isInteger(completedDays) || !Number.isInteger(trashDays) || completedDays < 1 || trashDays < 1 || completedDays + trashDays > 30) {
        setStatus("完成展示期与回收站保留期之和不能超过 30 天。");
        return;
      }
      setBusy(true);
      try {
        const body = await request("/api/command", {
          action: "update_task_retention",
          requestId: crypto.randomUUID(),
          completedDays: completedDays,
          trashDays: trashDays,
          expectedRevision: expectedRevision
        });
        const refreshed = await request("/api/read", { operation: "overview" });
        setOverview(refreshed);
        markMemoryChanged();
        setStatus(`已保存：完成后 ${body.receipt.settings.completedDays} 天进入回收站，保留 ${body.receipt.settings.trashDays} 天；第 ${body.receipt.settings.compactEvidenceDays} 天仅保留紧凑完成证据。`);
      } catch (error) {
        setStatus(error.message === "BRAIN_CONTROL_TASK_RETENTION_STALE" ? "设置刚刚有变化，已保留原设置；请刷新后再保存。" : `保存整理设置失败：${error.message || "未知错误"}`);
      } finally { setBusy(false); }
    };

    const previewTaskRetentionSettings = async (completedDays, trashDays) => {
      if (!Number.isInteger(completedDays) || !Number.isInteger(trashDays) || completedDays < 1 || trashDays < 1 || completedDays + trashDays > 30) {
        setStatus("完成展示期与回收站保留期之和不能超过 30 天。");
        return null;
      }
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "task_retention_preview", completedDays: completedDays, trashDays: trashDays });
        setStatus(`已生成整理影响预览：回收站 ${Number(body.counts && body.counts.trashed || 0)} 条，等待压缩 ${Number(body.counts && body.counts.sealed || 0)} 条，紧凑证据 ${Number(body.counts && body.counts.evidenceOnly || 0)} 条。`);
        return body;
      } catch (error) {
        setStatus(`整理影响预览失败：${error.message || "未知错误"}`);
        return null;
      } finally { setBusy(false); }
    };

    const openSkills = async () => {
      const requestEpoch = ++navigationEpochRef.current;
      activateSpecialView("skills");
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "skills" });
        if (requestEpoch !== navigationEpochRef.current) return;
        setSkills(body);
        setStatus("已读取技能说明");
      } catch (error) { setStatus(`读取技能说明失败：${error.message || "未知错误"}`); }
      finally { if (requestEpoch === navigationEpochRef.current) setBusy(false); }
    };

    const openHealth = async () => {
      const requestEpoch = ++navigationEpochRef.current;
      activateSpecialView("health");
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "health" });
        if (requestEpoch !== navigationEpochRef.current) return;
        setHealth(body);
        setStatus("已读取运行状态");
      } catch (error) { setStatus(`读取运行状态失败：${error.message || "未知错误"}`); }
      finally { if (requestEpoch === navigationEpochRef.current) setBusy(false); }
    };

    const openProfile = async () => {
      const requestEpoch = ++navigationEpochRef.current;
      activateSpecialView("profile");
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "profile" });
        if (requestEpoch !== navigationEpochRef.current) return;
        setProfile(body);
        setStatus(`已读取协作画像：${Number(body.total || 0)} 条已确认偏好`);
      } catch (error) { setStatus(`读取协作画像失败：${error.message || "未知错误"}`); }
      finally { if (requestEpoch === navigationEpochRef.current) setBusy(false); }
    };

    const openProfilePreference = (item) => {
      if (item && (text(item.cardRef) || text(item.cardId))) openCard(item);
    };

    const createProfilePreference = () => startMemoryCapture("preference");

    const restoreTaskCard = async (taskCard) => {
      if (!taskCard || !text(taskCard.taskCardKey)) return;
      setBusy(true);
      try {
        await request("/api/command", { action: "restore_task_card", requestId: crypto.randomUUID(), taskCardKey: taskCard.taskCardKey });
        const refreshed = await request("/api/read", { operation: "overview" });
        setOverview(refreshed);
        markMemoryChanged();
        setStatus("已恢复任务卡；它从今天起重新计算进入回收站的时间。");
      } catch (error) {
        setStatus(error.message === "BRAIN_CONTROL_TASK_RETENTION_STALE" ? "这张任务卡已发生变化，未恢复；请刷新后再查看。" : `恢复任务卡失败：${error.message || "未知错误"}`);
      } finally { setBusy(false); }
    };

    const save = async () => {
      if (isQuickCapture) {
        const problem = text(captureDraft.problem).trim();
        const desiredAction = text(captureDraft.desiredAction).trim();
        if (!problem || !desiredAction) {
          setStatus("请先写下问题是什么，以及想怎么做。");
          return;
        }
        const fingerprint = captureFingerprint(problem, desiredAction);
        const rememberedRequest = captureRequestRef.current;
        const savedRequestId = text(captureDraft.requestId);
        const requestId = rememberedRequest && rememberedRequest.fingerprint === fingerprint
          ? rememberedRequest.requestId
          : (savedRequestId && text(captureDraft.requestFingerprint) === fingerprint ? savedRequestId : crypto.randomUUID());
        captureRequestRef.current = { requestId: requestId, fingerprint: fingerprint };
        if (savedRequestId !== requestId || text(captureDraft.requestFingerprint) !== fingerprint || captureDraft.problem !== problem || captureDraft.desiredAction !== desiredAction) {
          const retryDraft = { problem: problem, desiredAction: desiredAction, requestId: requestId, requestFingerprint: fingerprint };
          setCaptureDraft(retryDraft);
          persistCaptureDraft(retryDraft);
        }
        setBusy(true);
        try {
          const body = await request("/api/command", {
            action: "capture_memory",
            requestId: requestId,
            problem: problem,
            desiredAction: desiredAction,
            reason: "Control Center simple memory capture"
          });
          const cardId = text(body && body.receipt && body.receipt.aggregateId);
          const suggestedKind = text(body && body.capture && body.capture.suggestedKind);
          const suggestedLabel = KINDS[suggestedKind] ? KINDS[suggestedKind].label : "";
          setStatus(suggestedLabel && suggestedKind !== "note"
            ? `已保存为参考记忆；已记录“${suggestedLabel}”整理建议。真实使用并有证据后会生成学习候选，采纳前不改变行为。`
            : "已保存为参考记忆；类别和行为暂未改变。");
          const clearedCapture = emptyCaptureDraft();
          captureRequestRef.current = null;
          setCaptureDraft(clearedCapture);
          persistCaptureDraft(clearedCapture);
          markMemoryChanged();
          await loadCards(true);
          if (cardId) {
            const refreshed = await request("/api/read", { operation: "card", cardId: cardId });
            if (refreshed.card) {
              const detail = refreshed.card;
              setSelected(detail);
              setKind(detail.kind);
              setCategoryKey(memoryCategoryForKind(detail.kind).key);
              setDraft({ cardId: detail.cardId, kind: detail.kind, scope: detail.scope, lifecycle: detail.lifecycle === "proposed" ? "proposed" : "active", authority: detail.authority || "user_confirmed", privacyClass: detail.privacyClass, title: detail.title, payload: detail.payload || defaultPayload(detail.kind), evidenceRefs: detail.evidenceRefs || [] });
              setIsNew(false);
              setHistory([]);
            }
          }
        } catch (error) {
          setStatus(`保存记忆失败：${error.message || "未知错误"}`);
        } finally {
          setBusy(false);
        }
        return;
      }
      const isNewCompletionGate = draft.kind === "decision"
        && draft.payload
        && draft.payload.enforcement === "completion_gate"
        && (!selected || !selected.payload || selected.payload.enforcement !== "completion_gate");
      if (draft.kind === "decision" && draft.payload && draft.payload.enforcement === "completion_gate") {
        if (!list(draft.payload.stageKinds).length || !list(draft.payload.completionCriteria).length) {
          setStatus("作为完成前检查的决策，需要选择适用阶段并填写至少一条完成条件。");
          return;
        }
        if (isNewCompletionGate && !window.confirm("这条决策会在相关阶段完成前被主动核对。确认启用吗？")) {
          setStatus("未启用完成前检查；当前编辑内容仍保留。");
          return;
        }
      }
      setBusy(true);
      try {
        const replacing = isNew && replaceTarget && draft.kind === "decision";
        const body = await request("/api/command", replacing ? {
          action: "replace",
          requestId: crypto.randomUUID(),
          cardId: draft.cardId,
          card: draft,
          replacedCardId: replaceTarget.cardId,
          replacedExpectedRevision: replaceTarget.expectedRevision,
          impactAcknowledged: replaceTarget.impactAcknowledged === true,
          reason: "Control Center replace decision"
        } : {
          action: isNew ? "create" : "edit",
          requestId: crypto.randomUUID(),
          cardId: draft.cardId,
          expectedRevision: isNew ? 0 : selected.revision,
          card: draft,
          reason: "Control Center save"
        });
        recoveredDraftRef.current = false;
        setStatus(replacing
          ? `新决策已保存，并已替换“${replaceTarget.title}”；投影 ${body.delivery.status === "materialized" ? "已同步" : "待同步"}`
          : `已保存第 ${body.receipt.revision} 版；投影 ${body.delivery.status === "materialized" ? "已同步" : "待同步"}`);
        if (isNew) localStorage.removeItem(draftStorageKey(draft.kind));
        if (replacing) setReplaceTarget(null);
        markMemoryChanged();
        await loadCards(true);
        const refreshed = await request("/api/read", { operation: "card", cardId: draft.cardId });
        if (refreshed.card) { setSelected(refreshed.card); setDraft(Object.assign({}, draft, { payload: refreshed.card.payload || draft.payload })); setIsNew(false); }
      } catch (error) {
        setStatus(error.message === "BRAIN_CONTROL_STALE_REVISION" ? "保存冲突：已有新版本，草稿未丢失。请刷新后再合并。" : `保存失败：${error.message || "未知错误"}`);
      } finally { setBusy(false); }
    };

    const trashTimelineCard = async (item) => {
      const cardRef = text(item && item.cardRef);
      const cardId = text(item && item.cardId);
      if (!cardRef && !cardId) {
        setStatus("这条总记忆记录缺少可操作的卡片引用。");
        return;
      }
      setBusy(true);
      try {
        const current = await request("/api/read", cardRef ? { operation: "card", cardRef: cardRef } : { operation: "card", cardId: cardId });
        const detail = current && current.card;
        if (!detail) throw new Error("BRAIN_CONTROL_CARD_NOT_FOUND");
        const body = await request("/api/command", {
          action: "trash",
          requestId: crypto.randomUUID(),
          cardId: detail.cardId,
          expectedRevision: detail.revision,
          reason: "Control Center trash from timeline"
        });
        markMemoryChanged();
        setStatus(`“${detail.title || "未命名记忆"}”已移至回收站（第 ${body.receipt.revision || detail.revision} 版）。`);
      } catch (error) {
        setStatus(error.message === "BRAIN_CONTROL_STALE_REVISION" ? "这条记忆刚刚有更新，未移至回收站；请刷新后再试。" : `移至回收站失败：${error.message || "未知错误"}`);
      } finally { setBusy(false); }
    };

    const openTimeline = () => {
      const alreadyOpen = timelineView;
      navigationEpochRef.current += 1;
      activateSpecialView("timeline");
      setStatus("正在读取总记忆记录");
      if (alreadyOpen) loadTimeline();
    };

    const openTrash = () => {
      navigationEpochRef.current += 1;
      activateSpecialView("trash");
      setStatus("正在读取回收站");
      if (trashView) loadTrash();
    };

    const deleteTrashedCards = async (items) => {
      const selections = Array.isArray(items) ? items.filter((item) => text(item && item.cardId) && Number.isInteger(Number(item.revision)) && Number(item.revision) > 0) : [];
      if (!selections.length) {
        setStatus("请先勾选至少一条回收站记录。");
        return;
      }
      const count = selections.length;
      const confirmation = count === 1
        ? `彻底删除“${text(selections[0].title) || "未命名记忆"}”？这会清除正文和搜索索引，之后不能从控制中心恢复。`
        : `彻底删除勾选的 ${count} 条记录？这会清除正文和搜索索引，之后不能从控制中心恢复。`;
      if (!window.confirm(confirmation)) return;
      setBusy(true);
      try {
        const body = await request("/api/command", {
          action: "delete_trashed_batch",
          requestId: crypto.randomUUID(),
          cards: selections.map((item) => ({ cardId: text(item.cardId), expectedRevision: Number(item.revision) })),
          deleteAcknowledged: true,
          reason: "Control Center permanent Trash delete"
        });
        markMemoryChanged();
        setStatus(`已彻底删除 ${Number(body.receipt && body.receipt.deletedCount) || count} 条回收站记录；正文和搜索索引已清除。`);
      } catch (error) {
        setStatus(error.message === "BRAIN_CONTROL_STALE_REVISION"
          ? "回收站中的记录刚刚发生变化，未删除任何勾选项；请刷新后重试。"
          : `彻底删除失败：${error.message || "未知错误"}`);
      } finally {
        setBusy(false);
      }
    };

    const openStarmap = () => {
      navigationEpochRef.current += 1;
      activateSpecialView("starmap");
      setStatus("正在读取记忆星图");
      if (starmapView) loadStarmap();
    };

    const lifecycleAction = async (action, extras) => {
      if (!selected) return;
      if (action === "forget" && !window.confirm("忘记会移除当前正文、搜索索引和控制中心可见历史。要继续吗？")) return;
      const isHardDecision = selected.kind === "decision" && selected.payload && selected.payload.enforcement === "completion_gate";
      if (action === "cancel" && !window.confirm(isHardDecision ? "取消后，相关任务不再按这条完成前检查执行。确认取消吗？" : "确认取消这条决策吗？")) return;
      setBusy(true);
      try {
        const body = await request("/api/command", Object.assign({ action: action, requestId: crypto.randomUUID(), cardId: selected.cardId, expectedRevision: selected.revision, forgetAcknowledged: action === "forget", impactAcknowledged: action === "cancel" && isHardDecision, reason: `Control Center ${action}` }, extras || {}));
        markMemoryChanged();
        setStatus(action === "forget" ? "当前正文已忘记；物理清理仍须经过归档治理。" : `操作已写入第 ${body.receipt.revision || selected.revision} 版`);
        await loadCards(true);
        if (action === "forget") {
          const refreshed = await request("/api/read", { operation: "card", cardId: selected.cardId });
          setSelected(refreshed.card || null);
        } else {
          setSelected(null); setDraft(newDraft(kind)); setIsNew(true); setHistory([]);
        }
      } catch (error) { setStatus(`操作失败：${error.message || "未知错误"}`); }
      finally { setBusy(false); }
    };

    const viewHistory = async () => {
      if (!selected) return;
      setBusy(true);
      try {
        const body = await request("/api/read", { operation: "history", cardId: selected.cardId, limit: 50, offset: 0 });
        setHistory(Array.isArray(body.items) ? body.items : []);
        setStatus(`已读取 ${(body.items || []).length} 个历史版本`);
      } catch (error) { setStatus(`读取历史失败：${error.message || "未知错误"}`); }
      finally { setBusy(false); }
    };

    const requestPurge = async () => {
      if (!selected || !selected.forgotten) return;
      setBusy(true);
      try {
        const previewResult = await request("/api/command", { action: "purge_preview", cardId: selected.cardId, expectedRevision: selected.revision });
        const preview = previewResult.receipt;
        const confirmation = window.prompt("输入确认短语以提交归档治理请求", preview.confirmationPhrase);
        if (confirmation !== preview.confirmationPhrase) { setStatus("未提交清理请求：确认短语不匹配。"); return; }
        await request("/api/command", { action: "purge_request", previewId: preview.previewId, confirmationPhrase: confirmation });
        setStatus("已提交治理清理请求；当前正文继续保持忘记状态。");
      } catch (error) { setStatus(`清理请求失败：${error.message || "未知错误"}`); }
      finally { setBusy(false); }
    };

    const title = useMemo(() => {
      if (trashView) return "回收站";
      if (profileView) return "偏好与性格画像";
      if (healthView) return "运行状态";
      if (skillsView) return "技能";
      if (starmapView) return "记忆星图";
      if (systemView) return "任务中心";
      if (timelineView) return "总记忆记录";
      if (selected) return selected.title;
      if (isQuickCapture) return "新建记忆";
      if (isNew) return replaceTarget ? "替换决策" : `新建${KINDS[kind].label}`;
      return KINDS[kind].label;
    }, [healthView, isNew, isQuickCapture, kind, profileView, replaceTarget, selected, skillsView, starmapView, systemView, timelineView, trashView]);
    const adoptedReflection = Boolean(selected && selected.kind === "reflection" && selected.payload && text(selected.payload.candidateState) === "adopted");
    const systemLearningCandidate = isSystemLearningCandidate(selected);
    const locked = busy || (selected && selected.lifecycle === "trashed") || adoptedReflection || systemLearningCandidate || selectedHasIntegrityIssue;
    const specialView = systemView || timelineView || starmapView || skillsView || healthView || profileView || trashView;

    const primaryNavigation = [
      { key: "timeline", label: "总记忆记录", hint: "按日期查看已保存内容", title: "按日期查看已保存的记忆和已验证来源", icon: History, active: timelineView, onClick: openTimeline },
      { key: "starmap", label: "记忆星图", hint: "查看关联与聚合", title: "查看已验证记忆之间的关联", icon: Orbit, active: starmapView, onClick: openStarmap }
    ];
    const moreNavigation = [
      { key: "tasks", label: "任务中心", hint: "主线、进度与待办", title: "查看当前任务的内容、进度和待办项", icon: ClipboardList, active: systemView, onClick: openOverview },
      { key: "profile", label: "偏好与性格", hint: "已确认的协作方式", title: "查看已确认的长期协作方式", icon: UserRound, active: profileView, onClick: openProfile },
      { key: "skills", label: "技能", hint: "按需要唤醒的能力", title: "查看每项能力什么时候会帮你", icon: BrainCircuit, active: skillsView, onClick: openSkills },
      { key: "health", label: "运行状态", hint: "本机服务是否正常", title: "查看本机记忆和任务是否正常", icon: Activity, active: healthView, onClick: openHealth },
      { key: "trash", label: "回收站", hint: "已删除记录与恢复", title: "查看已删除记录并恢复", icon: Trash2, active: trashView, onClick: openTrash }
    ];
    const memoryNavigation = [ALL_MEMORY_CATEGORY].concat(MEMORY_CATEGORIES).map((category) => ({
      key: category.key,
      label: category.label,
      hint: category.hint,
      title: `打开${category.label}`,
      icon: category.icon,
      active: !systemView && !timelineView && !starmapView && !skillsView && !healthView && !profileView && !trashView && category.key === categoryKey,
      onClick: () => openMemoryLibrary(category.key)
    }));

    const syncLabel = busy ? "同步中" : (lastSyncedAt ? `已同步 ${new Date(lastSyncedAt).toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" })}` : "本机数据");
    const topbar = h("header", { className: "app-topbar", key: "topbar" }, [
      h("button", { type: "button", className: "topbar-brand", onClick: openTimeline, title: "返回总记忆记录", key: "brand" }, [
        h("span", { className: "brand-mark", key: "mark" }, "SB"),
        h("span", { className: "topbar-brand-copy", key: "copy" }, [h("strong", { key: "strong" }, "超级大脑"), h("small", { key: "small" }, syncLabel)])
      ]),
      h("nav", { className: "topbar-primary-nav", "aria-label": "核心入口", key: "nav" }, primaryNavigation.map((item) => {
        const Icon = item.icon;
        return h("button", { type: "button", className: item.active ? "topbar-nav-item active" : "topbar-nav-item", onClick: item.onClick, title: item.title, "aria-current": item.active ? "page" : undefined, key: item.key }, [h(Icon, { size: 16, strokeWidth: 1.75, key: "icon" }), h("span", { key: "label" }, item.label)]);
      })),
      h("form", { className: "global-search", onSubmit: (event) => { event.preventDefault(); runSearch(); }, key: "search" }, [
        h(Search, { size: 16, strokeWidth: 1.75, key: "icon" }),
        h("input", { value: searchInput, placeholder: "搜索全部记忆", onChange: (event) => setSearchInput(event.target.value), "aria-label": "搜索全部记忆", key: "input" }),
        searchInput ? h("button", { type: "button", className: "global-search-clear", onClick: clearSearch, title: "清空搜索", "aria-label": "清空搜索", key: "clear" }, h(X, { size: 15, strokeWidth: 1.9 })) : null
      ]),
      h("div", { className: "topbar-actions", key: "actions" }, [
        h("button", { type: "button", className: "topbar-create", onClick: createNew, key: "create" }, [h(Plus, { size: 16, strokeWidth: 2, key: "icon" }), h("span", { key: "label" }, "新建记忆")]),
        h("button", { type: "button", className: moreOpen ? "topbar-more active" : "topbar-more", onClick: () => setMoreOpen((open) => !open), "aria-expanded": moreOpen, title: "更多功能", key: "more" }, [h(MoreHorizontal, { size: 18, strokeWidth: 1.8, key: "icon" }), h("span", { key: "label" }, "更多")])
      ])
    ]);

    const moreDrawer = moreOpen ? h("aside", { className: "more-drawer", "aria-label": "更多功能", key: "more-drawer" }, [
      h("div", { className: "more-drawer-heading", key: "heading" }, [h("strong", { key: "title" }, "更多功能"), h("button", { type: "button", onClick: () => setMoreOpen(false), title: "关闭更多功能", "aria-label": "关闭更多功能", key: "close" }, h(X, { size: 16, strokeWidth: 1.9 }))]),
      h("div", { className: "more-drawer-list", key: "list" }, moreNavigation.map((item) => {
        const Icon = item.icon;
        return h("button", { type: "button", className: item.active ? "more-drawer-item active" : "more-drawer-item", onClick: () => { setMoreOpen(false); item.onClick(); }, title: item.title, key: item.key }, [h(Icon, { size: 17, strokeWidth: 1.7, key: "icon" }), h("span", { key: "copy" }, [h("strong", { key: "label" }, item.label), h("small", { key: "hint" }, item.hint)])]);
      }))
    ]) : null;

    const collection = h("section", { className: "collection memory-library" }, [
      h("header", { className: "collection-header", key: "header" }, [
        h("div", { key: "heading" }, [h("p", { key: "p" }, query ? "搜索结果" : "本机记忆"), h("h1", { key: "h1" }, query ? `“${query}”` : activeCategory.label)]),
        h("div", { className: "collection-header-actions", key: "actions" }, [button("刷新", loadCards, "icon-text", busy, "从本机记忆库重新读取"), h("span", { className: "collection-count", key: "count" }, `当前筛选 ${cards.length} 条`)])
      ]),
      activeCategory.key === "learning" ? h(LearningConsolidationPanel, { key: "consolidation", model: learningPlan, busy: busy, onRefresh: loadLearningPlan, onOpen: openCard }) : null,
      h("div", { className: "memory-filter-bar", key: "filters" }, [
        h("div", { className: "memory-type-filters", role: "group", "aria-label": "记忆类型", key: "types" }, memoryNavigation.map((item) => h("button", { type: "button", className: item.active ? "memory-filter active" : "memory-filter", onClick: item.onClick, title: item.title, key: item.key }, item.label))),
        h("div", { className: "filter-row", key: "lifecycle" }, [button("当前", () => setLifecycle("active"), lifecycle === "active" ? "filter selected" : "filter"), button("待确认", () => setLifecycle("proposed"), lifecycle === "proposed" ? "filter selected" : "filter"), button("全部", () => setLifecycle("all"), lifecycle === "all" ? "filter selected" : "filter")])
      ]),
      h("div", { className: "card-list", key: "cards", "aria-live": "polite" }, cards.length ? cards.map((card) => h("button", { className: selected && selected.cardId === card.cardId ? "memory-row selected" : "memory-row", key: card.cardId, onClick: () => openCard(card) }, [h("div", { key: "main" }, [h("span", { className: "memory-row-kind", key: "kind" }, KINDS[card.kind] ? KINDS[card.kind].label : "记忆"), h("strong", { key: "title" }, card.title), h("p", { key: "summary" }, card.summary || "无摘要")]), h("span", { className: "row-meta", key: "meta" }, `v${card.revision}${card.lifecycle === "proposed" ? " · 待确认" : ""}`)])) : h("div", { className: "empty-list" }, status))
    ]);

    let editorBody;
    if (systemView) {
      const model = overview || { cardsByKind: {}, cardsByLifecycle: {}, tasks: [], recentEvents: [], pendingOutbox: 0 };
      editorBody = h(TaskCenter, { model: model, onRefresh: openOverview, onRestore: restoreTaskCard, onSaveSettings: saveTaskRetentionSettings, onPreview: previewTaskRetentionSettings, busy: busy });
    } else if (profileView) {
      editorBody = h(ProfilePanel, { model: profile || { total: 0, longTerm: [], currentProject: [] }, onOpen: openProfilePreference, onCreate: createProfilePreference });
    } else if (trashView) {
      editorBody = h(ManagedRecycleBin, { items: trashCards, onOpen: openCard, onDelete: deleteTrashedCards, onRefresh: loadTrash, busy: busy });
    } else if (skillsView) {
      editorBody = h(SkillCatalog, { model: skills || { items: [] } });
    } else if (healthView) {
      editorBody = h(HealthPanel, { model: health || { indicators: [] } });
    } else if (timelineView) {
      editorBody = h(MemoryTimeline, { model: timeline || { items: [] }, onOpen: (item) => openCard(item, { categoryKey: "all" }), onTrash: trashTimelineCard, busy: busy });
    } else if (starmapView) {
      editorBody = h(MemoryStarmap, { model: starmap || { nodes: [], edges: [], counts: {} }, filter: starmapFilter, onFilterChange: setStarmapFilter, selectedKey: starmapSelectedKey, onSelect: selectStarmapNode });
    } else if (isQuickCapture) {
      editorBody = h(MemoryCaptureEditor, { value: captureDraft, locked: locked, onChange: setCaptureDraft });
    } else if (selectedHasIntegrityIssue) {
      editorBody = h("section", { className: "integrity-state" }, [
        h("p", { className: "integrity-state-label", key: "label" }, "内容完整性保护"),
        h("h3", { key: "title" }, "这条记录包含不可逆的编码异常"),
        h("p", { key: "copy" }, "为避免把占位内容写回记忆库，编辑和自动草稿已暂停。你可以保留它作为审计记录，或移至回收站后重新补录清晰内容。")
      ]);
    } else if (forgotten) {
      editorBody = h("div", { className: "forgotten-state" }, [h("div", { key: "content" }, [h("strong", { key: "title" }, "该卡片的当前正文已忘记"), h("p", { key: "copy" }, "搜索、控制中心详情和可见历史不会再展示正文。归档与备份中的物理治理需要单独确认。"), button("提交治理清理请求", requestPurge, "icon-text muted")])]);
    } else if (systemLearningCandidate) {
      editorBody = h(SystemLearningCandidate, { card: selected, busy: busy, onOpenSource: openCard });
    } else {
      editorBody = h(SimpleCardEditor, { draft: draft, isNew: isNew, locked: locked, onChange: setDraft });
    }

    const specialSubtitle = trashView ? "已删除的记录与恢复" : (profileView ? "已确认的长期协作方式" : (starmapView ? "本地记忆关联" : (timelineView ? "按日期查看保存的记忆" : (skillsView ? "这些能力什么时候会帮你" : (healthView ? "本机记忆和任务的运行情况" : "当前任务与进度")))));
    const specialRefresh = trashView ? loadTrash : (profileView ? openProfile : (starmapView ? loadStarmap : (timelineView ? openTimeline : (skillsView ? openSkills : (healthView ? openHealth : openOverview)))));
    const specialRefreshTitle = trashView ? "刷新回收站" : (profileView ? "刷新偏好与性格画像" : (starmapView ? "刷新记忆星图" : (timelineView ? "刷新总记忆记录" : (skillsView ? "刷新技能说明" : (healthView ? "刷新运行状态" : "刷新当前任务进度")))));
    const editorHeading = specialView
      ? h("div", { key: "heading" }, [h("div", { key: "title" }, [h("p", { key: "sub" }, specialSubtitle), h("h2", { key: "main" }, title)])])
      : h("div", { key: "heading" }, [
        isQuickCapture ? null : button("‹", createNew, "back-button", false, "返回新建"),
        h("div", { key: "title" }, [h("p", { key: "sub" }, isQuickCapture ? "只需留下两句话" : (isNew ? (replaceTarget ? `替换“${replaceTarget.title}”` : "草稿") : (selected ? `第 ${selected.revision} 版` : "本机记录"))), h("h2", { key: "main" }, title)])
      ]);

    const activeViewKey = trashView ? "trash" : (profileView ? "profile" : (healthView ? "health" : (skillsView ? "skills" : (starmapView ? "starmap" : (systemView ? "tasks" : (timelineView ? "timeline" : kind))))));
    const ActiveViewIcon = trashView ? Trash2 : (profileView ? UserRound : (healthView ? Activity : (skillsView ? BrainCircuit : (starmapView ? Orbit : (systemView ? ClipboardList : (timelineView ? History : KIND_ICONS[kind]))))));
    const selectedSuggestedKind = learningSuggestionKind(selected);
    const selectedTrial = reflectionTrial(selected);
    const selectedSystemCandidate = isSystemLearningCandidate(selected);
    const canAdoptReflection = !!(selected && selected.kind === "reflection" && selected.payload && ["validated", "staged"].includes(text(selected.payload.candidateState)) && list(selected.payload.evidence).length && (!selectedSystemCandidate || (REFLECTION_PROMOTABLE_KINDS.has(selectedSuggestedKind) && selectedTrial.verdict === "passed" && selectedTrial.hasReceipt)) && (selectedSystemCandidate ? REFLECTION_PROMOTABLE_KINDS.has(selectedSuggestedKind) : true));
    const adoptReflectionLabel = KINDS[selectedSuggestedKind] ? `采纳为${KINDS[selectedSuggestedKind].label}` : "整理候选";
    useEffect(() => {
      if (editorPanelRef.current) editorPanelRef.current.scrollTop = 0;
    }, [activeViewKey]);
    const editor = h("section", { className: starmapView ? "editor-panel starmap-panel" : (isQuickCapture ? "editor-panel quick-capture-panel" : "editor-panel"), "data-view": activeViewKey, ref: editorPanelRef }, [
      h("header", { className: "editor-header", key: "header", "data-view": activeViewKey }, [
        h("span", { className: "view-signal", key: "signal", "aria-hidden": "true" }, h(ActiveViewIcon, { size: 17, strokeWidth: 1.65 })),
        editorHeading,
        h("div", { className: "header-actions", key: "actions" }, specialView ? [busy ? h("span", { className: "spin", key: "busy" }, "加载") : null, button("刷新", specialRefresh, "icon-text", false, specialRefreshTitle)] : [busy ? h("span", { className: "spin", key: "busy" }, "加载") : null, button("历史", viewHistory, "icon-text", !selected, "版本历史"), canAdoptReflection ? button(adoptReflectionLabel, adoptReflection, "icon-text", busy, "按候选建议整理，并保留原反思作为依据") : null, selected && selected.kind === "decision" && (selected.lifecycle === "active" || selected.lifecycle === "proposed") && !forgotten ? button("替换", startReplacement, "icon-text", false, "新建替代决策并原子替换当前决策") : null, selected && selected.kind === "decision" && (selected.lifecycle === "active" || selected.lifecycle === "proposed") && !forgotten ? button("取消", () => lifecycleAction("cancel"), "icon-text muted", false, "取消当前决策") : null, selected && selected.lifecycle === "trashed" ? button("恢复", () => lifecycleAction("restore"), "icon-text", false, "从回收站恢复") : selected && ["active", "proposed"].includes(selected.lifecycle) && !forgotten ? button("移至回收站", () => lifecycleAction("trash"), "icon-text", false, "删除当前记录，但保留恢复入口") : null, selected && ["active", "proposed"].includes(selected.lifecycle) && !forgotten ? button("忘记", () => lifecycleAction("forget"), "icon-text", false, "忘记当前正文") : null, button("保存", save, "save-button", busy || forgotten || selectedHasIntegrityIssue || (selected && selected.lifecycle === "trashed") || adoptedReflection || systemLearningCandidate, selectedHasIntegrityIssue ? "记录存在编码异常；请重新补录或移至回收站。" : (adoptedReflection ? "已完成整理；原反思仍保留为依据。" : (systemLearningCandidate ? "系统生成的学习候选只能按试用结果整理或移至回收站。" : "保存")))])
      ]),
      h("div", { className: "status-line", key: "status" }, status),
      editorBody,
      history.length ? h("section", { className: "history-panel", key: "history" }, [h("div", { className: "history-title", key: "title" }, h("h3", null, "版本历史")), history.map((entry) => h("div", { className: "history-row", key: String(entry.revision) }, [h("span", { key: "revision" }, `v${entry.revision}`), h("small", { key: "created" }, String(entry.createdAt || "")), entry.forgotten ? h("em", { key: "forgotten" }, "正文已忘记") : button("恢复", () => lifecycleAction("rollback", { restoreRevision: Number(entry.revision) }), "icon-text", false, "恢复此版本")]))]) : null
    ]);

    const workspaceBody = specialView ? editor : collection;
    const detailDrawer = drawerOpen && !specialView ? h("aside", { className: "detail-drawer", "aria-label": "记忆详情", key: "detail-drawer" }, [
      h("button", { type: "button", className: "detail-drawer-close", onClick: closeDrawer, title: "关闭详情", "aria-label": "关闭详情", key: "close" }, h(X, { size: 17, strokeWidth: 1.9 })),
      editor
    ]) : null;
    return h("main", { className: starmapView ? "app-shell minimal-shell starmap-mode" : "app-shell minimal-shell", "data-view": activeViewKey }, (starmapView ? [h(AmbientStarfield, { key: "ambient" })] : []).concat([
      topbar,
      h("div", { className: detailDrawer ? "app-workspace has-drawer" : "app-workspace", key: "workspace" }, [
        h("section", { className: specialView ? "workspace-surface special-surface" : "workspace-surface", key: "surface" }, workspaceBody),
        detailDrawer
      ]),
      moreDrawer
    ]));
  }

  ReactDOM.createRoot(document.getElementById("root")).render(h(App));
})();
