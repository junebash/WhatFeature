<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { RouterLink, useRoute, useRouter } from 'vue-router'
import { useAction } from '../action'
import type { AuditEntry } from '../api'
import AuditDiff from '../components/AuditDiff.vue'
import ErrorBanner from '../components/ErrorBanner.vue'
import { fullDate, localInputToISO, timeAgo } from '../format'
import { actorLabel, api, environmentLabel, projectLabel, session } from '../session'

// Every admin change, newest first. Filters live in the URL, so a filtered view can be linked (the flag page does).
const route = useRoute()
const router = useRouter()

const filters = ref({ project: '', flag: '', actor: '', since: '', until: '', limit: 100 })
function readQuery() {
  const query = route.query
  filters.value = {
    project: (query.project as string) ?? '',
    flag: (query.flag as string) ?? '',
    actor: (query.actor as string) ?? '',
    since: (query.since as string) ?? '',
    until: (query.until as string) ?? '',
    limit: Number(query.limit ?? 100) || 100,
  }
}

const entries = ref<AuditEntry[]>([])
const expanded = ref(new Set<number>())
const load = useAction()

async function refresh() {
  const f = filters.value
  const loaded = await load.run(() =>
    api.value.audit({
      project: f.project || undefined,
      flag: f.flag.trim() || undefined,
      actor: f.actor || undefined,
      since: localInputToISO(f.since),
      until: localInputToISO(f.until),
      limit: f.limit,
    }),
  )
  if (loaded) entries.value = loaded
}
watch(() => route.query, () => {
  readQuery()
  void refresh()
}, { immediate: true })

function apply() {
  const f = filters.value
  const query: Record<string, string> = {}
  for (const [name, value] of Object.entries(f)) if (value !== '' && !(name === 'limit' && value === 100)) query[name] = String(value)
  void router.replace({ query })
}

function toggle(id: number) {
  const next = new Set(expanded.value)
  if (next.has(id)) next.delete(id)
  else next.add(id)
  expanded.value = next
}

const actors = computed(() => [...new Set(entries.value.map((entry) => entry.actor))].sort())
const projectKeyFor = (id?: string) => (id ? session.projects.find((project) => project.id === id)?.key : undefined)
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Audit log</h1>
        <p class="subtitle">Every admin change, written in the same transaction as the change. Never edited or deleted.</p>
      </div>
    </div>

    <form class="row filters" @submit.prevent="apply">
      <label class="field small">
        Project
        <select v-model="filters.project">
          <option value="">All</option>
          <option v-for="project in session.projects" :key="project.id" :value="project.key">{{ project.key }}</option>
        </select>
      </label>
      <label class="field small">Flag <input v-model="filters.flag" placeholder="key" style="width: 150px" /></label>
      <label class="field small">
        Actor
        <input v-model="filters.actor" list="audit-actors" placeholder="token:…" style="width: 170px" />
        <datalist id="audit-actors">
          <option v-for="actor in actors" :key="actor" :value="actor">{{ actorLabel(actor) }}</option>
        </datalist>
      </label>
      <label class="field small">Since <input v-model="filters.since" type="datetime-local" /></label>
      <label class="field small">Until <input v-model="filters.until" type="datetime-local" /></label>
      <label class="field small">Limit <input v-model.number="filters.limit" type="number" min="1" max="1000" style="width: 80px" /></label>
      <button type="submit" :disabled="load.busy.value">Apply</button>
    </form>

    <ErrorBanner :error="load.error.value" />

    <div class="card">
      <div v-if="entries.length === 0" class="empty">{{ load.busy.value ? 'Loading…' : 'No entries match.' }}</div>
      <div v-else class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>When</th>
              <th>Action</th>
              <th>Where</th>
              <th>Who</th>
            </tr>
          </thead>
          <tbody>
            <template v-for="entry in entries" :key="entry.id">
              <tr class="clickable" :class="{ selected: expanded.has(entry.id) }" @click="toggle(entry.id)">
                <td class="small nowrap" :title="fullDate(entry.timestamp)">{{ timeAgo(entry.timestamp) }}</td>
                <td class="mono small">{{ entry.action }}</td>
                <td class="small">
                  <span v-if="entry.environmentID" class="mono">{{ environmentLabel(entry.environmentID) }}</span>
                  <span v-else-if="entry.projectID" class="mono">{{ projectLabel(entry.projectID) }}</span>
                  <template v-if="entry.flagKey">
                    <span class="muted"> · </span>
                    <RouterLink
                      v-if="projectKeyFor(entry.projectID)"
                      class="mono"
                      :to="{ name: 'flag', params: { project: projectKeyFor(entry.projectID)!, flag: entry.flagKey } }"
                      @click.stop
                    >{{ entry.flagKey }}</RouterLink>
                    <span v-else class="mono">{{ entry.flagKey }}</span>
                  </template>
                </td>
                <td class="small">{{ actorLabel(entry.actor) }}</td>
              </tr>
              <tr v-if="expanded.has(entry.id)">
                <td colspan="4"><AuditDiff :entry="entry" /></td>
              </tr>
            </template>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>

<style scoped>
.filters { align-items: flex-end; }
</style>
