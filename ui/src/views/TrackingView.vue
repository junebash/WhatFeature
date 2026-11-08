<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import type { Exposure, SeenContext, TrackedContextDetail, TrackingSettings } from '../api'
import ErrorBanner from '../components/ErrorBanner.vue'
import { sharedContext } from '../context'
import { fullDate, localInputToISO, timeAgo } from '../format'
import { plainValue } from '../model'
import { activeEnvironments, api, loadDirectory } from '../session'

// Per-environment tracking (see "Tracking" in docs/DESIGN.md): its settings, the targeting keys seen, one key's
// attributes and exposures, and exposures for export.
const route = useRoute()
const router = useRouter()
const projectKey = route.params.project as string
const environments = computed(() => activeEnvironments(projectKey))
const envKey = computed(() => {
  const wanted = route.query.env as string | undefined
  return environments.value.find((environment) => environment.key === wanted)?.key ?? environments.value[0]?.key
})
const tab = computed(() => (route.query.tab === 'exposures' ? 'exposures' : 'contexts'))
function setQuery(changes: Record<string, string | undefined>) {
  void router.replace({ query: { ...route.query, ...changes } })
}

// Settings
const settings = ref<TrackingSettings | null>(null)
const attributesText = ref('')
const settingsAction = useAction()
const savedNote = ref(false)
watch(envKey, async (key) => {
  if (!key) return
  settings.value = null
  const loaded = await settingsAction.run(() => api.value.tracking(projectKey, key))
  if (loaded) {
    settings.value = loaded
    attributesText.value = loaded.attributes.join(', ')
  }
}, { immediate: true })

const typedAttributes = computed(() => [...new Set(attributesText.value.split(/[,\s]+/).map((name) => name.trim()).filter(Boolean))].sort())
async function saveSettings() {
  const key = envKey.value
  const current = settings.value
  if (!key || !current) return
  const removed = current.attributes.filter((name) => !typedAttributes.value.includes(name))
  if (removed.length && !confirm(`Stop storing ${removed.join(', ')}? Values already stored are deleted now.`)) return
  const saved = await settingsAction.run(() => api.value.setTracking(projectKey, key, { ...current, attributes: typedAttributes.value }))
  if (saved) {
    settings.value = saved
    attributesText.value = saved.attributes.join(', ')
    savedNote.value = true
    setTimeout(() => (savedNote.value = false), 2000)
    void loadDirectory()
  }
}

// Seen contexts, and the one selected
const selected = ref<TrackedContextDetail | null>(null)
const contexts = ref<SeenContext[]>([])
const contextsSince = ref('')
const contextsLimit = ref(100)
const contextsAction = useAction()
async function loadContexts() {
  const key = envKey.value
  if (!key) return
  const loaded = await contextsAction.run(() =>
    api.value.trackedContexts(projectKey, key, { since: localInputToISO(contextsSince.value), limit: contextsLimit.value }),
  )
  if (loaded) contexts.value = loaded
}
watch(envKey, () => {
  contexts.value = []
  selected.value = null
  void loadContexts()
}, { immediate: true })

const attributeColumns = computed(() => [...new Set(contexts.value.flatMap((context) => Object.keys(context.attributes)))].sort())

// One context
const detailAction = useAction()
async function select(targetingKey: string) {
  const key = envKey.value
  if (!key) return
  const loaded = await detailAction.run(() => api.value.trackedContext(projectKey, key, targetingKey))
  if (loaded) selected.value = loaded
}
async function deleteSelected() {
  const key = envKey.value
  const targetingKey = selected.value?.context.targetingKey
  if (!key || !targetingKey) return
  if (!confirm(`Delete everything stored for '${targetingKey}' in ${key}? Its attributes and every exposure. This can't be undone.`)) return
  const done = await detailAction.run(async () => {
    await api.value.deleteTrackedContext(projectKey, key, targetingKey)
    return true
  })
  if (done) {
    selected.value = null
    await loadContexts()
  }
}
function tryContext(context: SeenContext) {
  sharedContext.value = { ...context.attributes, targetingKey: context.targetingKey }
  void router.push({ name: 'evaluate', params: { project: projectKey }, query: { env: envKey.value } })
}

// Exposures
const exposureFilters = ref({ targetingKey: '', flag: '', variant: '', since: '', limit: 1000 })
const exposures = ref<Exposure[]>([])
const exposuresAction = useAction()
const exposuresLoaded = ref(false)
async function loadExposures() {
  const key = envKey.value
  if (!key) return
  const filters = exposureFilters.value
  const loaded = await exposuresAction.run(() =>
    api.value.exposures(projectKey, key, {
      targetingKey: filters.targetingKey.trim() || undefined,
      flag: filters.flag.trim() || undefined,
      variant: filters.variant.trim() || undefined,
      since: localInputToISO(filters.since),
      limit: filters.limit,
    }),
  )
  if (loaded) {
    exposures.value = loaded
    exposuresLoaded.value = true
  }
}
watch([envKey, tab], () => {
  if (tab.value === 'exposures') void loadExposures()
}, { immediate: true })

// Counts per flag and variant, for a quick look at an experiment's split.
const exposureSummary = computed(() => {
  const counts = new Map<string, Map<string, number>>()
  for (const exposure of exposures.value) {
    const variants = counts.get(exposure.flagKey) ?? new Map<string, number>()
    variants.set(exposure.variant, (variants.get(exposure.variant) ?? 0) + 1)
    counts.set(exposure.flagKey, variants)
  }
  return [...counts.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([flag, variants]) => ({
    flag,
    total: [...variants.values()].reduce((sum, count) => sum + count, 0),
    variants: [...variants.entries()].sort(([a], [b]) => a.localeCompare(b)),
  }))
})

function download() {
  const blob = new Blob([JSON.stringify(exposures.value, null, 2)], { type: 'application/json' })
  const link = document.createElement('a')
  link.href = URL.createObjectURL(blob)
  link.download = `exposures-${projectKey}-${envKey.value}.json`
  link.click()
  URL.revokeObjectURL(link.href)
}
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Tracking</h1>
        <p class="subtitle">Who the server saw and what it served them. Off by default; only the targeting key and allowed attributes are stored.</p>
      </div>
      <label class="field">
        Environment
        <select :value="envKey" @change="setQuery({ env: ($event.target as HTMLSelectElement).value })">
          <option v-for="environment in environments" :key="environment.id" :value="environment.key">{{ environment.key }}</option>
        </select>
      </label>
    </div>

    <div class="card">
      <div class="card-header"><h2>Settings for {{ envKey }}</h2></div>
      <form v-if="settings" class="card-body" @submit.prevent="saveSettings">
        <label class="check">
          <input v-model="settings.enabled" type="checkbox" class="switch" />
          <strong>{{ settings.enabled ? 'Recording' : 'Not recording' }}</strong>
          <span class="muted small">Turning it off stops recording; what's stored expires on schedule.</span>
        </label>
        <div class="grid-2">
          <label class="field">
            Attributes to store
            <input v-model="attributesText" placeholder="appVersion, platform" />
            <span class="hint">Besides the targeting key, nothing else from a context is kept. Removing one deletes its stored values.</span>
          </label>
          <label class="field">
            Keep for (days)
            <input v-model.number="settings.retentionDays" type="number" min="1" style="max-width: 120px" />
            <span class="hint">IDs not seen for this long are deleted, with their exposures.</span>
          </label>
        </div>
        <div class="row">
          <button class="primary" type="submit" :disabled="settingsAction.busy.value">Save settings</button>
          <span v-if="savedNote" class="pill on">Saved</span>
        </div>
      </form>
      <div v-else-if="!settingsAction.error.value" class="empty">Loading…</div>
      <div v-if="settingsAction.error.value" class="card-body"><ErrorBanner :error="settingsAction.error.value" /></div>
    </div>

    <div class="tabs">
      <button :class="{ active: tab === 'contexts' }" @click="setQuery({ tab: undefined })">Seen IDs</button>
      <button :class="{ active: tab === 'exposures' }" @click="setQuery({ tab: 'exposures' })">Exposures</button>
    </div>

    <template v-if="tab === 'contexts'">
      <form class="row" @submit.prevent="loadContexts">
        <label class="field small">Seen since <input v-model="contextsSince" type="datetime-local" /></label>
        <label class="field small">Limit <input v-model.number="contextsLimit" type="number" min="1" max="1000" style="width: 90px" /></label>
        <button type="submit" style="align-self: flex-end" :disabled="contextsAction.busy.value">Refresh</button>
      </form>
      <ErrorBanner :error="contextsAction.error.value ?? (selected ? null : detailAction.error.value)" />
      <div class="layout" :class="{ split: selected }">
        <div class="card">
          <div v-if="contexts.length === 0" class="empty">
            {{ contextsAction.busy.value ? 'Loading…' : settings?.enabled ? 'No IDs seen yet.' : 'Nothing stored. Turn recording on to start.' }}
          </div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Targeting key</th>
                  <th v-for="name in attributeColumns" :key="name">{{ name }}</th>
                  <th>Last seen</th>
                  <th>First seen</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  v-for="context in contexts"
                  :key="context.targetingKey"
                  class="clickable"
                  :class="{ selected: selected?.context.targetingKey === context.targetingKey }"
                  @click="select(context.targetingKey)"
                >
                  <td class="mono">{{ context.targetingKey }}</td>
                  <td v-for="name in attributeColumns" :key="name" class="small">{{ plainValue(context.attributes[name]) }}</td>
                  <td class="muted small nowrap" :title="fullDate(context.lastSeen)">{{ timeAgo(context.lastSeen) }}</td>
                  <td class="muted small nowrap" :title="fullDate(context.firstSeen)">{{ timeAgo(context.firstSeen) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div v-if="selected" class="card">
          <div class="card-header">
            <h2 class="mono">{{ selected.context.targetingKey }}</h2>
            <button class="ghost icon" aria-label="Close" @click="selected = null">✕</button>
          </div>
          <div class="card-body">
            <ErrorBanner :error="detailAction.error.value" />
            <div class="small muted">First seen {{ fullDate(selected.context.firstSeen) }} · last seen {{ fullDate(selected.context.lastSeen) }}</div>
            <div v-if="Object.keys(selected.context.attributes).length" class="stack tight">
              <h3>Attributes</h3>
              <div v-for="(value, name) in selected.context.attributes" :key="name" class="row small">
                <span class="mono muted">{{ name }}</span> <code>{{ plainValue(value) }}</code>
              </div>
            </div>
            <div class="stack tight">
              <h3>Served</h3>
              <p v-if="selected.exposures.length === 0" class="muted small">Nothing served yet.</p>
              <table v-else>
                <thead>
                  <tr><th>Flag</th><th>Variant</th><th>Last served</th></tr>
                </thead>
                <tbody>
                  <tr v-for="exposure in selected.exposures" :key="`${exposure.flagKey}/${exposure.variant}`">
                    <td class="nowrap"><RouterLink class="mono" :to="{ name: 'flag', params: { project: projectKey, flag: exposure.flagKey }, query: { env: envKey } }">{{ exposure.flagKey }}</RouterLink></td>
                    <td class="mono">{{ exposure.variant }} <span class="muted small">{{ exposure.reason }}</span></td>
                    <td class="muted small nowrap" :title="fullDate(exposure.lastServed)">{{ timeAgo(exposure.lastServed) }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div class="row">
              <button @click="tryContext(selected.context)">Try this context</button>
              <button class="danger" :disabled="detailAction.busy.value" @click="deleteSelected">Delete stored data</button>
            </div>
            <p class="muted small">To give this ID a specific variant, add a <code>targetingKey is one of</code> rule on the flag.</p>
          </div>
        </div>
      </div>
    </template>

    <template v-else>
      <form class="row filters" @submit.prevent="loadExposures">
        <label class="field small">Targeting key <input v-model="exposureFilters.targetingKey" /></label>
        <label class="field small">Flag <input v-model="exposureFilters.flag" /></label>
        <label class="field small">Variant <input v-model="exposureFilters.variant" style="width: 110px" /></label>
        <label class="field small">Served since <input v-model="exposureFilters.since" type="datetime-local" /></label>
        <label class="field small">Limit <input v-model.number="exposureFilters.limit" type="number" min="1" max="100000" style="width: 100px" /></label>
        <button type="submit" :disabled="exposuresAction.busy.value">Apply</button>
        <button type="button" :disabled="exposures.length === 0" @click="download">Download JSON</button>
      </form>
      <ErrorBanner :error="exposuresAction.error.value" />

      <div v-if="exposureSummary.length" class="card">
        <div class="card-header"><h2>Variants served</h2><span class="muted small">IDs per variant, in these {{ exposures.length }} exposures</span></div>
        <div class="card-body summary">
          <div v-for="item in exposureSummary" :key="item.flag" class="row">
            <span class="mono summary-flag">{{ item.flag }}</span>
            <span v-for="[variant, count] in item.variants" :key="variant" class="pill">{{ variant }} {{ count }} · {{ Math.round((count / item.total) * 100) }}%</span>
          </div>
        </div>
      </div>

      <div class="card">
        <div v-if="exposures.length === 0" class="empty">{{ exposuresAction.busy.value ? 'Loading…' : exposuresLoaded ? 'No exposures match.' : '' }}</div>
        <div v-else class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Targeting key</th>
                <th>Flag</th>
                <th>Variant</th>
                <th>Reason</th>
                <th>First served</th>
                <th>Last served</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="exposure in exposures" :key="`${exposure.targetingKey}/${exposure.flagKey}/${exposure.variant}`">
                <td class="mono">{{ exposure.targetingKey }}</td>
                <td class="mono">{{ exposure.flagKey }}</td>
                <td class="mono">{{ exposure.variant }}</td>
                <td class="small">{{ exposure.reason }}<span v-if="exposure.matchedRule !== undefined" class="muted"> · rule {{ exposure.matchedRule + 1 }}</span></td>
                <td class="muted small nowrap" :title="fullDate(exposure.firstServed)">{{ timeAgo(exposure.firstServed) }}</td>
                <td class="muted small nowrap" :title="fullDate(exposure.lastServed)">{{ timeAgo(exposure.lastServed) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.layout { display: grid; grid-template-columns: 1fr; gap: 16px; align-items: start; }
.layout.split { grid-template-columns: minmax(0, 1fr) 380px; }
.layout.split > .card:last-child { position: sticky; top: 16px; max-height: calc(100vh - 32px); overflow-y: auto; }
@media (max-width: 1000px) { .layout.split { grid-template-columns: 1fr; } }
.filters { align-items: flex-end; }
.summary { gap: 8px; }
.summary-flag { min-width: 160px; font-weight: 600; }
</style>
