<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, toRaw, watch } from 'vue'
import { onBeforeRouteLeave, RouterLink, useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import type { AuditEntry, Condition, DryRunResult, FlagConfig, FlagDetail, JSONValue, Rule } from '../api'
import AuditDiff from '../components/AuditDiff.vue'
import ConditionEditor from '../components/ConditionEditor.vue'
import ContextEditor from '../components/ContextEditor.vue'
import ErrorBanner from '../components/ErrorBanner.vue'
import JsonView from '../components/JsonView.vue'
import Modal from '../components/Modal.vue'
import ResultEditor from '../components/ResultEditor.vue'
import VariantValueInput from '../components/VariantValueInput.vue'
import { attributesIn, sharedContext } from '../context'
import { fullDate, timeAgo } from '../format'
import { clone, configBody, emptyVariantValue, formatValue, sameJSON, totalWeight, variantsIn } from '../model'
import { activeEnvironments, actorLabel, api } from '../session'

const route = useRoute()
const router = useRouter()
const projectKey = route.params.project as string
const flagKey = route.params.flag as string

const detail = ref<FlagDetail | null>(null)
const drafts = ref<Record<string, FlagConfig>>({})
const load = useAction()

async function refresh() {
  await load.run(async () => {
    const loaded = await api.value.flag(projectKey, flagKey)
    detail.value = loaded
    drafts.value = clone(loaded.configs)
  })
  void loadHistory()
}
onMounted(refresh)

const flag = computed(() => detail.value?.flag)
const variants = computed(() => Object.keys(flag.value?.variants ?? {}).sort())

// The environment being edited, kept in the URL (`?env=prod`).
const environments = computed(() => activeEnvironments(projectKey).filter((environment) => detail.value?.configs[environment.key]))
const envKey = computed(() => {
  const wanted = route.query.env as string | undefined
  return environments.value.find((environment) => environment.key === wanted)?.key ?? environments.value[0]?.key
})
function selectEnvironment(key: string) {
  void router.replace({ query: { ...route.query, env: key } })
}

const saved = computed(() => (envKey.value ? detail.value?.configs[envKey.value] : undefined))
const draft = computed(() => (envKey.value ? drafts.value[envKey.value] : undefined))
const isDirty = (key: string) => !sameJSON(drafts.value[key], detail.value?.configs[key])
const dirtyEnvironments = computed(() => environments.value.filter((environment) => isDirty(environment.key)).map((e) => e.key))

// Leaving with unsaved changes asks first.
onBeforeRouteLeave(() => dirtyEnvironments.value.length === 0 || confirm('Leave without saving your changes?'))
const beforeUnload = (event: BeforeUnloadEvent) => {
  if (dirtyEnvironments.value.length) event.preventDefault()
}
onMounted(() => window.addEventListener('beforeunload', beforeUnload))
onBeforeUnmount(() => window.removeEventListener('beforeunload', beforeUnload))

// Problems the server would also reject, shown before saving.
const problems = computed(() => {
  const config = draft.value
  if (!config) return []
  const found: string[] = []
  const check = (result: FlagConfig['defaultResult'], where: string) => {
    for (const name of variantsIn(result)) if (!variants.value.includes(name)) found.push(`${where} serves '${name || '(nothing)'}', which isn't a variant`)
    if ('rollout' in result) {
      const total = result.rollout.reduce((sum, entry) => sum + entry.weight, 0)
      if (total !== totalWeight) found.push(`${where}: the rollout adds up to ${total / 100}%, not 100%`)
    }
  }
  config.rules.forEach((rule, index) => {
    check(rule.result, `Rule ${index + 1}`)
    if (rule.conditions.some((condition) => !condition.attribute.trim())) found.push(`Rule ${index + 1}: every condition needs an attribute`)
  })
  check(config.defaultResult, 'The default')
  return found
})

// Rules have no IDs; key them by object identity so editors keep their state when rules move.
const ruleIDs = new WeakMap<object, number>()
let nextRuleID = 0
function ruleKey(rule: Rule): number {
  const raw = toRaw(rule)
  if (!ruleIDs.has(raw)) ruleIDs.set(raw, nextRuleID++)
  return ruleIDs.get(raw)!
}

function addRule() {
  draft.value?.rules.push({
    conditions: [{ attribute: 'targetingKey', operator: 'in', value: [] }],
    result: { variant: variants.value[0] ?? '' },
  })
}
function moveRule(index: number, offset: number) {
  const rules = draft.value?.rules
  if (!rules) return
  const [rule] = rules.splice(index, 1)
  if (rule) rules.splice(index + offset, 0, rule)
}
function addCondition(rule: Rule) {
  rule.conditions.push({ attribute: '', operator: 'equals', value: '' })
}
function setCondition(rule: Rule, index: number, condition: Condition) {
  rule.conditions[index] = condition
}

const save = useAction()
async function saveConfig() {
  const key = envKey.value
  const config = draft.value
  if (!key || !config || !detail.value) return
  const result = await save.run(() => api.value.setConfig(projectKey, key, flagKey, configBody(config)))
  if (result) {
    detail.value.configs[key] = result
    drafts.value[key] = clone(result)
    void loadHistory()
    void runDryRun()
  }
}
function revert() {
  if (envKey.value && saved.value) drafts.value[envKey.value] = clone(saved.value)
}

// The kill switch saves at once, with the saved rules (not the draft's).
const toggle = useAction()
async function setEnabled(enabled: boolean) {
  const key = envKey.value
  const config = saved.value
  if (!key || !config || !detail.value) return
  const result = await toggle.run(() => api.value.setConfig(projectKey, key, flagKey, { ...configBody(config), enabled }))
  if (result) {
    detail.value.configs[key] = result
    const current = drafts.value[key]
    drafts.value[key] = current ? { ...current, enabled: result.enabled, version: result.version } : clone(result)
    void loadHistory()
    void runDryRun()
  }
}

// Dry run against the saved config, for the shared context.
const dryRun = ref<DryRunResult | null>(null)
const dry = useAction()
let dryTimer: ReturnType<typeof setTimeout> | undefined
async function runDryRun() {
  const key = envKey.value
  if (!key) return
  const result = await dry.run(() => api.value.evaluate(projectKey, key, flagKey, sharedContext.value))
  if (result) dryRun.value = result
}
watch([sharedContext, envKey], () => {
  clearTimeout(dryTimer)
  dryTimer = setTimeout(runDryRun, 300)
}, { deep: true, immediate: true })

const attributes = computed(() => attributesIn(Object.values(detail.value?.configs ?? {})))

// Variants, description and experiment: edited together, saved with PATCH.
const editingFlag = ref(false)
const flagForm = ref<{ description: string; isExperiment: boolean; variants: { name: string; value: JSONValue }[] }>({
  description: '',
  isExperiment: false,
  variants: [],
})
const flagSave = useAction()
function openFlagEditor() {
  if (!flag.value) return
  flagForm.value = {
    description: flag.value.description,
    isExperiment: flag.value.isExperiment,
    variants: Object.entries(flag.value.variants)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([name, value]) => ({ name, value: clone(value) })),
  }
  flagSave.error.value = null
  editingFlag.value = true
}
const formNames = computed(() => flagForm.value.variants.map((variant) => variant.name.trim()))
const formProblem = computed(() => {
  if (formNames.value.some((name) => !name)) return 'Every variant needs a name.'
  if (new Set(formNames.value).size !== formNames.value.length) return 'Variant names must be different.'
  return null
})
async function saveFlag() {
  const result = await flagSave.run(() =>
    api.value.updateFlag(projectKey, flagKey, {
      description: flagForm.value.description,
      isExperiment: flagForm.value.isExperiment,
      variants: Object.fromEntries(flagForm.value.variants.map((variant) => [variant.name.trim(), variant.value])),
    }),
  )
  if (result && detail.value) {
    detail.value.flag = result.flag
    editingFlag.value = false
    void loadHistory()
  }
}

// Archive, unarchive, delete.
const lifecycle = useAction()
async function setArchived(archived: boolean) {
  if (archived && !confirm(`Archive ${flagKey}? It evaluates as disabled everywhere, so apps use their code defaults.`)) return
  const result = await lifecycle.run(() => api.value.setFlagArchived(projectKey, flagKey, archived))
  if (result && detail.value) {
    detail.value.flag = result.flag
    void loadHistory()
  }
}
const deleting = ref(false)
const deleteConfirmation = ref('')
async function deleteFlag() {
  const done = await lifecycle.run(async () => {
    await api.value.deleteFlag(projectKey, flagKey)
    return true
  })
  if (done) {
    deleting.value = false
    drafts.value = clone(detail.value?.configs ?? {})
    await router.push({ name: 'flags', params: { project: projectKey } })
  }
}

// History from the audit log.
const history = ref<AuditEntry[]>([])
const expanded = ref<number | null>(null)
async function loadHistory() {
  try {
    history.value = await api.value.audit({ project: projectKey, flag: flagKey, limit: 25 })
  } catch {
    history.value = []
  }
}
</script>

<template>
  <div class="page">
    <div class="row muted small">
      <RouterLink :to="{ name: 'flags', params: { project: projectKey } }">Flags</RouterLink>
      <span>/</span>
      <span>{{ flagKey }}</span>
    </div>

    <ErrorBanner :error="load.error.value" />
    <div v-if="load.busy.value && !detail" class="muted">Loading…</div>

    <template v-if="flag && detail">
      <div class="page-header">
        <div class="stack tight">
          <div class="row">
            <h1 class="flag-title">{{ flag.key }}</h1>
            <span class="pill">{{ flag.type }}</span>
            <span v-if="flag.isExperiment" class="pill accent">experiment</span>
            <span v-if="flag.archivedAt" class="pill warn">archived</span>
          </div>
          <p class="subtitle">{{ flag.description || 'No description.' }}</p>
          <p class="muted small">Created {{ timeAgo(flag.createdAt) }} by {{ actorLabel(flag.createdBy) }}</p>
        </div>
        <div class="row">
          <button @click="openFlagEditor">Edit variants &amp; details</button>
          <button v-if="flag.archivedAt" :disabled="lifecycle.busy.value" @click="setArchived(false)">Unarchive</button>
          <button v-else class="danger" :disabled="lifecycle.busy.value" @click="setArchived(true)">Archive</button>
          <button class="danger" @click="deleting = true; deleteConfirmation = ''">Delete</button>
        </div>
      </div>

      <ErrorBanner :error="lifecycle.error.value" />
      <div v-if="flag.archivedAt" class="banner warn">Archived: evaluates as disabled in every environment, whatever its configs say.</div>

      <div class="card">
        <div class="card-header"><h2>Variants</h2></div>
        <div class="variants">
          <div v-for="name in variants" :key="name" class="variant">
            <span class="mono variant-name">{{ name }}</span>
            <code class="muted">{{ formatValue(flag.variants[name]) }}</code>
          </div>
        </div>
      </div>

      <div class="layout">
        <div class="card config">
          <div class="tabs env-tabs">
            <button
              v-for="environment in environments"
              :key="environment.id"
              :class="{ active: environment.key === envKey }"
              @click="selectEnvironment(environment.key)"
            >
              <span class="dot" :style="{ color: detail.configs[environment.key]?.enabled ? 'var(--green)' : 'var(--border)' }" />
              {{ environment.key }}
              <span v-if="isDirty(environment.key)" class="pill warn">unsaved</span>
            </button>
          </div>

          <div v-if="draft && saved" class="card-body">
            <div class="row spread">
              <label class="check">
                <input type="checkbox" class="switch" :checked="saved.enabled" :disabled="toggle.busy.value" @change="setEnabled(($event.target as HTMLInputElement).checked)" />
                <strong>{{ saved.enabled ? 'Enabled' : 'Disabled' }}</strong>
                <span class="muted small">{{ saved.enabled ? 'Serving the rules below.' : 'Apps get no value and use their code default.' }}</span>
              </label>
              <span class="muted small">Version {{ saved.version }}</span>
            </div>
            <ErrorBanner :error="toggle.error.value" />

            <div class="stack">
              <div class="row spread">
                <h3>Rules <span class="muted small">· checked in order; the first match wins</span></h3>
                <button class="small" @click="addRule">Add rule</button>
              </div>
              <p v-if="draft.rules.length === 0" class="muted small">No rules: everyone gets the default.</p>
              <div
                v-for="(rule, ruleIndex) in draft.rules"
                :key="ruleKey(rule)"
                class="rule"
                :class="{ matched: dryRun && dryRun.matchedRule === ruleIndex && !isDirty(envKey!) }"
              >
                <div class="row spread">
                  <strong class="small">Rule {{ ruleIndex + 1 }}</strong>
                  <div class="row">
                    <span v-if="dryRun && dryRun.matchedRule === ruleIndex && !isDirty(envKey!)" class="pill on">matches the test context</span>
                    <button class="ghost icon" :disabled="ruleIndex === 0" title="Move up" aria-label="Move up" @click="moveRule(ruleIndex, -1)">↑</button>
                    <button class="ghost icon" :disabled="ruleIndex === draft.rules.length - 1" title="Move down" aria-label="Move down" @click="moveRule(ruleIndex, 1)">↓</button>
                    <button class="ghost icon danger" title="Remove rule" aria-label="Remove rule" @click="draft.rules.splice(ruleIndex, 1)">✕</button>
                  </div>
                </div>
                <div class="stack tight">
                  <span class="label">If</span>
                  <p v-if="rule.conditions.length === 0" class="muted small">No conditions: matches everyone who gets this far.</p>
                  <template v-for="(condition, conditionIndex) in rule.conditions" :key="conditionIndex">
                    <span v-if="conditionIndex > 0" class="label">and</span>
                    <ConditionEditor
                      :model-value="condition"
                      :attributes="attributes"
                      @update:model-value="setCondition(rule, conditionIndex, $event)"
                      @remove="rule.conditions.splice(conditionIndex, 1)"
                    />
                  </template>
                  <div><button class="small ghost" @click="addCondition(rule)">+ Condition</button></div>
                </div>
                <div class="stack tight">
                  <span class="label">Serve</span>
                  <ResultEditor v-model="rule.result" :variants="variants" />
                </div>
              </div>
            </div>

            <div class="rule default" :class="{ matched: dryRun && dryRun.reason !== 'DISABLED' && dryRun.reason !== 'ERROR' && dryRun.matchedRule === undefined && !isDirty(envKey!) }">
              <strong class="small">{{ draft.rules.length ? 'Otherwise, serve' : 'Serve' }}</strong>
              <ResultEditor v-model="draft.defaultResult" :variants="variants" />
            </div>

            <div v-if="problems.length" class="banner warn">
              Fix before saving:
              <ul><li v-for="problem in problems" :key="problem">{{ problem }}</li></ul>
            </div>
            <ErrorBanner :error="save.error.value" />
            <div class="row save-bar">
              <button class="primary" :disabled="!isDirty(envKey!) || problems.length > 0 || save.busy.value" @click="saveConfig">
                {{ save.busy.value ? 'Saving…' : `Save ${envKey}` }}
              </button>
              <button :disabled="!isDirty(envKey!)" @click="revert">Discard changes</button>
              <span v-if="dirtyEnvironments.length > 1" class="muted small">Also unsaved: {{ dirtyEnvironments.filter((key) => key !== envKey).join(', ') }}</span>
            </div>
          </div>
        </div>

        <div class="side">
          <div class="card">
            <div class="card-header"><h2>Test a context</h2><span class="muted small">in {{ envKey }}</span></div>
            <div class="card-body">
              <ContextEditor v-model="sharedContext" :attributes="attributes" />
              <ErrorBanner :error="dry.error.value" />
              <div v-if="dryRun" class="stack tight">
                <div class="row">
                  <span class="pill" :class="dryRun.reason === 'DISABLED' ? 'off' : dryRun.reason === 'ERROR' ? 'bad' : 'on'">{{ dryRun.reason }}</span>
                  <template v-if="dryRun.variant">
                    <strong class="mono">{{ dryRun.variant }}</strong>
                    <code class="muted">{{ formatValue(dryRun.value) }}</code>
                  </template>
                </div>
                <p class="small muted">
                  <template v-if="dryRun.reason === 'DISABLED'">Disabled, so the app uses its code default.</template>
                  <template v-else-if="dryRun.errorCode">{{ dryRun.errorCode }}: {{ dryRun.errorDetails }}</template>
                  <template v-else-if="dryRun.matchedRule !== undefined">Rule {{ dryRun.matchedRule + 1 }} matched.</template>
                  <template v-else-if="dryRun.reason === 'STATIC'">No rules; everyone gets the default.</template>
                  <template v-else>No rule matched, so the default.</template>
                </p>
                <p v-if="envKey && isDirty(envKey)" class="small banner warn">Uses the saved config, not your unsaved changes.</p>
                <details>
                  <summary class="small muted">What the app gets (HTTP {{ dryRun.ofrep.status }})</summary>
                  <JsonView :value="dryRun.ofrep.body" />
                </details>
              </div>
            </div>
          </div>

          <div class="card">
            <div class="card-header">
              <h2>History</h2>
              <RouterLink class="small" :to="{ name: 'audit', query: { project: projectKey, flag: flagKey } }">All</RouterLink>
            </div>
            <div v-if="history.length === 0" class="empty small">Nothing yet.</div>
            <ul class="history">
              <li v-for="entry in history" :key="entry.id">
                <button class="ghost history-item" @click="expanded = expanded === entry.id ? null : entry.id">
                  <span class="mono small">{{ entry.action }}</span>
                  <span class="muted small" :title="fullDate(entry.timestamp)">{{ timeAgo(entry.timestamp) }} · {{ actorLabel(entry.actor) }}</span>
                </button>
                <AuditDiff v-if="expanded === entry.id" :entry="entry" />
              </li>
            </ul>
          </div>
        </div>
      </div>
    </template>

    <Modal v-if="editingFlag && flag" :title="`Edit ${flag.key}`" @close="editingFlag = false">
      <form id="flag-form" class="stack" @submit.prevent="saveFlag">
        <label class="field">
          Description
          <input v-model="flagForm.description" placeholder="What it's for" />
        </label>
        <label class="check"><input v-model="flagForm.isExperiment" type="checkbox" /> A/B test (marks results with <code>experiment: true</code>)</label>
        <div class="field">
          <span>Variants <span class="hint">· a variant in use by a rule or default can't be removed or renamed</span></span>
          <div v-for="(variant, index) in flagForm.variants" :key="index" class="row top">
            <input v-model="variant.name" placeholder="name" style="width: 130px" aria-label="Variant name" />
            <VariantValueInput v-model="variant.value" :type="flag.type" class="grow" />
            <button type="button" class="ghost icon" :disabled="flagForm.variants.length <= 1" aria-label="Remove variant" @click="flagForm.variants.splice(index, 1)">✕</button>
          </div>
          <div>
            <button type="button" class="small" @click="flagForm.variants.push({ name: '', value: emptyVariantValue(flag.type) })">Add variant</button>
          </div>
          <span v-if="formProblem" class="field-error">{{ formProblem }}</span>
        </div>
        <p class="muted small">The type ({{ flag.type }}) and key can't change. Make a new flag instead.</p>
        <ErrorBanner :error="flagSave.error.value" />
      </form>
      <template #footer>
        <button @click="editingFlag = false">Cancel</button>
        <button class="primary" type="submit" form="flag-form" :disabled="flagSave.busy.value || !!formProblem">Save</button>
      </template>
    </Modal>

    <Modal v-if="deleting" :title="`Delete ${flagKey}?`" @close="deleting = false">
      <p>This deletes the flag and its config in every environment. It can't be undone. Apps asking for it get <code>FLAG_NOT_FOUND</code>.</p>
      <p class="muted small">To stop serving it but keep it, archive it instead.</p>
      <label class="field">
        Type the flag key to confirm
        <input v-model="deleteConfirmation" :placeholder="flagKey" autofocus />
      </label>
      <ErrorBanner :error="lifecycle.error.value" />
      <template #footer>
        <button @click="deleting = false">Cancel</button>
        <button class="primary danger-fill" :disabled="deleteConfirmation !== flagKey || lifecycle.busy.value" @click="deleteFlag">Delete forever</button>
      </template>
    </Modal>
  </div>
</template>

<style scoped>
.variants { display: flex; flex-wrap: wrap; gap: 8px; padding: 12px 16px; }
.variant { display: flex; gap: 8px; align-items: baseline; padding: 4px 10px; border: 1px solid var(--border); border-radius: 6px; max-width: 100%; overflow: hidden; }
.variant code { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 360px; }
.variant-name { font-weight: 600; }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 16px; align-items: start; }
@media (max-width: 1100px) { .layout { grid-template-columns: 1fr; } }
.side { display: flex; flex-direction: column; gap: 16px; }
.env-tabs { padding: 0 8px; }
.env-tabs button { display: inline-flex; align-items: center; gap: 6px; }
.rule { border: 1px solid var(--border); border-radius: 8px; padding: 12px; display: flex; flex-direction: column; gap: 10px; background: var(--panel); }
.rule.default { background: var(--panel-2); }
.rule.matched { border-color: var(--green); box-shadow: 0 0 0 1px var(--green); }
.label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
.save-bar { position: sticky; bottom: 0; background: var(--panel); padding: 10px 0 2px; }
.history { list-style: none; margin: 0; padding: 4px 8px 8px; display: flex; flex-direction: column; gap: 2px; }
.history-item { width: 100%; flex-direction: column; align-items: flex-start; padding: 6px 8px; gap: 0; }
.flag-title { font-family: var(--mono); }
.danger-fill { background: var(--red) !important; border-color: var(--red) !important; }
</style>
