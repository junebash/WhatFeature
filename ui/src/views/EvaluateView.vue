<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import type { BulkDryRunResult, FlagConfig } from '../api'
import ContextEditor from '../components/ContextEditor.vue'
import ErrorBanner from '../components/ErrorBanner.vue'
import JsonView from '../components/JsonView.vue'
import { attributesIn, sharedContext } from '../context'
import { formatValue } from '../model'
import { activeEnvironments, api } from '../session'

// The bulk dry run: what every flag gives one context in one environment, and why. Stores nothing.
const route = useRoute()
const router = useRouter()
const projectKey = route.params.project as string
const environments = computed(() => activeEnvironments(projectKey))
const envKey = computed(() => {
  const wanted = route.query.env as string | undefined
  return environments.value.find((environment) => environment.key === wanted)?.key ?? environments.value[0]?.key
})

const result = ref<BulkDryRunResult | null>(null)
const evaluate = useAction()
let timer: ReturnType<typeof setTimeout> | undefined

async function run() {
  const key = envKey.value
  if (!key) return
  const bulk = await evaluate.run(() => api.value.evaluateAll(projectKey, key, sharedContext.value))
  if (bulk) result.value = bulk
}
watch([sharedContext, envKey], () => {
  clearTimeout(timer)
  timer = setTimeout(run, 300)
}, { deep: true, immediate: true })

// Attribute suggestions: what rules use, plus what tracking stores.
const configs = ref<FlagConfig[]>([])
onMounted(async () => {
  try {
    const flags = await api.value.flags(projectKey)
    const details = await Promise.all(flags.map((flag) => api.value.flag(projectKey, flag.key)))
    configs.value = details.flatMap((detail) => Object.values(detail.configs))
  } catch {
    // Suggestions only.
  }
})
const attributes = computed(() => {
  const tracked = environments.value.find((environment) => environment.key === envKey.value)?.tracking.attributes ?? []
  return [...new Set([...attributesIn(configs.value), ...tracked])].sort()
})

function reasonClass(reason: string) {
  return reason === 'DISABLED' ? 'off' : reason === 'ERROR' ? 'bad' : 'on'
}
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Try a context</h1>
        <p class="subtitle">What every flag gives this user or device, and why. Uses the live configs and stores nothing.</p>
      </div>
      <label class="field">
        Environment
        <select :value="envKey" @change="router.replace({ query: { env: ($event.target as HTMLSelectElement).value } })">
          <option v-for="environment in environments" :key="environment.id" :value="environment.key">{{ environment.key }}</option>
        </select>
      </label>
    </div>

    <div class="layout">
      <div class="card">
        <div class="card-header"><h2>Context</h2></div>
        <div class="card-body">
          <ContextEditor v-model="sharedContext" :attributes="attributes" />
          <p class="muted small">The flag pages use this context too.</p>
        </div>
      </div>

      <div class="stack">
        <ErrorBanner :error="evaluate.error.value" />
        <div class="card">
          <div v-if="!result" class="empty">{{ evaluate.busy.value ? 'Evaluating…' : 'No result yet.' }}</div>
          <div v-else-if="result.flags.length === 0" class="empty">No flags in this project.</div>
          <div v-else class="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>Flag</th>
                  <th>Gets</th>
                  <th>Why</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="flag in result.flags" :key="flag.key">
                  <td>
                    <RouterLink class="mono" :to="{ name: 'flag', params: { project: projectKey, flag: flag.key }, query: { env: envKey } }">{{ flag.key }}</RouterLink>
                  </td>
                  <td>
                    <template v-if="flag.variant">
                      <strong class="mono">{{ flag.variant }}</strong>
                      <code class="muted value">{{ formatValue(flag.value) }}</code>
                    </template>
                    <span v-else class="muted">code default</span>
                  </td>
                  <td>
                    <div class="row">
                      <span class="pill" :class="reasonClass(flag.reason)">{{ flag.reason }}</span>
                      <span class="muted small">
                        <template v-if="flag.errorCode">{{ flag.errorCode }}: {{ flag.errorDetails }}</template>
                        <template v-else-if="flag.matchedRule !== undefined">rule {{ flag.matchedRule + 1 }}</template>
                        <template v-else-if="flag.reason !== 'DISABLED'">default</template>
                      </span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        <details v-if="result" class="card">
          <summary class="card-header">▸ What an app gets from the bulk endpoint (HTTP {{ result.ofrep.status }})</summary>
          <div class="card-body"><JsonView :value="result.ofrep.body" /></div>
        </details>
      </div>
    </div>
  </div>
</template>

<style scoped>
.layout { display: grid; grid-template-columns: 440px minmax(0, 1fr); gap: 16px; align-items: start; }
@media (max-width: 1000px) { .layout { grid-template-columns: 1fr; } }
.value { margin-left: 6px; }
summary { cursor: pointer; }
</style>
