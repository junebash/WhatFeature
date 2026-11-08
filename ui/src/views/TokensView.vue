<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { useAction } from '../action'
import type { CreatedToken, Token, TokenKind } from '../api'
import ErrorBanner from '../components/ErrorBanner.vue'
import Modal from '../components/Modal.vue'
import { fullDate, timeAgo } from '../format'
import { activeEnvironments, actorLabel, api, environmentLabel, loadTokens, session } from '../session'

const tokens = ref<Token[]>([])
const showRevoked = ref(false)
const load = useAction()

async function refresh() {
  const loaded = await load.run(() => api.value.tokens())
  if (loaded) tokens.value = loaded
  void loadTokens()
}
onMounted(refresh)

const visible = computed(() =>
  tokens.value
    .filter((token) => showRevoked.value || !token.revokedAt)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt)),
)
const revokedCount = computed(() => tokens.value.filter((token) => token.revokedAt).length)

// Create
const creating = ref(false)
const create = useAction()
const form = ref<{ name: string; kind: TokenKind; project: string; environment: string }>({ name: '', kind: 'evaluation', project: '', environment: '' })
const created = ref<CreatedToken | null>(null)
const copied = ref(false)
const projects = computed(() => session.projects.filter((project) => !project.archivedAt))
const environments = computed(() => (form.value.project ? activeEnvironments(form.value.project) : []))

function openCreate() {
  const project = projects.value[0]?.key ?? ''
  form.value = { name: '', kind: 'evaluation', project, environment: activeEnvironments(project)[0]?.key ?? '' }
  created.value = null
  copied.value = false
  create.error.value = null
  creating.value = true
}

function setProject(key: string) {
  form.value.project = key
  form.value.environment = activeEnvironments(key)[0]?.key ?? ''
}

async function submitCreate() {
  const { name, kind, project, environment } = form.value
  const result = await create.run(() =>
    api.value.createToken(kind === 'admin' ? { name: name.trim(), kind } : { name: name.trim(), kind, project, environment }),
  )
  if (result) {
    created.value = result
    await refresh()
  }
}

async function copySecret() {
  if (!created.value) return
  await navigator.clipboard.writeText(created.value.secret)
  copied.value = true
}

// Revoke
const revoke = useAction()
async function revokeToken(token: Token) {
  const isSelf = token.id === session.me?.id
  const warning = isSelf
    ? `This is the token you're signed in with. Revoking it signs you out.`
    : token.kind === 'evaluation'
      ? 'Apps using it get 401 and fall back to their code defaults.'
      : 'Anything using it loses admin access.'
  if (!confirm(`Revoke "${token.name}"? ${warning} This can't be undone.`)) return
  const result = await revoke.run(() => api.value.revokeToken(token.id))
  if (result) await refresh()
}
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div>
        <h1>Tokens</h1>
        <p class="subtitle">Admin tokens use this UI, the CLI and the admin API. Evaluation tokens are for apps: read-only, one environment, and public once shipped.</p>
      </div>
      <div class="row">
        <label v-if="revokedCount" class="check small"><input v-model="showRevoked" type="checkbox" /> Show revoked ({{ revokedCount }})</label>
        <button class="primary" @click="openCreate">New token</button>
      </div>
    </div>

    <ErrorBanner :error="load.error.value ?? revoke.error.value" />

    <div class="card">
      <div v-if="load.busy.value && tokens.length === 0" class="empty">Loading…</div>
      <div v-else class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Name</th>
              <th>Kind</th>
              <th>Environment</th>
              <th>Created</th>
              <th>Last used</th>
              <th />
            </tr>
          </thead>
          <tbody>
            <tr v-for="token in visible" :key="token.id">
              <td>
                <div class="row">
                  <strong>{{ token.name }}</strong>
                  <span v-if="token.id === session.me?.id" class="pill accent">you</span>
                  <span v-if="token.revokedAt" class="pill bad" :title="fullDate(token.revokedAt)">revoked</span>
                </div>
                <code class="muted small">{{ token.id }}</code>
              </td>
              <td><span class="pill" :class="{ accent: token.kind === 'admin' }">{{ token.kind }}</span></td>
              <td class="mono small">{{ token.environmentID ? environmentLabel(token.environmentID) : '—' }}</td>
              <td class="small nowrap">
                <span :title="fullDate(token.createdAt)">{{ timeAgo(token.createdAt) }}</span>
                <div class="muted">by {{ actorLabel(token.createdBy) }}</div>
              </td>
              <td class="muted small nowrap" :title="token.lastUsedAt ? fullDate(token.lastUsedAt) : undefined">
                {{ token.lastUsedAt ? timeAgo(token.lastUsedAt) : 'never' }}
              </td>
              <td style="text-align: right">
                <button v-if="!token.revokedAt" class="small ghost danger" :disabled="revoke.busy.value" @click="revokeToken(token)">Revoke</button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>

    <Modal v-if="creating" :title="created ? 'Token created' : 'New token'" @close="creating = false">
      <template v-if="created">
        <div class="banner warn">Copy the secret now. It's shown only once; the server keeps just a hash.</div>
        <div class="row">
          <input :value="created.secret" readonly class="grow mono" aria-label="Secret" @focus="($event.target as HTMLInputElement).select()" />
          <button @click="copySecret">{{ copied ? 'Copied' : 'Copy' }}</button>
        </div>
        <p class="muted small">
          {{ created.token.kind === 'admin' ? 'Admin' : 'Evaluation' }} token “{{ created.token.name }}”<template v-if="created.token.environmentID">
            for {{ environmentLabel(created.token.environmentID) }}</template>.
        </p>
      </template>
      <form v-else id="token-form" class="stack" @submit.prevent="submitCreate">
        <label class="field">
          Name
          <input v-model="form.name" required placeholder="iOS app" autofocus />
        </label>
        <div class="field">
          <span>Kind</span>
          <label class="check"><input v-model="form.kind" type="radio" value="evaluation" /> Evaluation: an app reads flags in one environment</label>
          <label class="check"><input v-model="form.kind" type="radio" value="admin" /> Admin: full control, like the one you're using</label>
        </div>
        <div v-if="form.kind === 'evaluation'" class="row">
          <label class="field grow">
            Project
            <select :value="form.project" @change="setProject(($event.target as HTMLSelectElement).value)">
              <option v-for="project in projects" :key="project.id" :value="project.key">{{ project.name }}</option>
            </select>
          </label>
          <label class="field grow">
            Environment
            <select v-model="form.environment">
              <option v-for="environment in environments" :key="environment.id" :value="environment.key">{{ environment.key }}</option>
            </select>
          </label>
        </div>
        <ErrorBanner :error="create.error.value" />
      </form>
      <template #footer>
        <button v-if="created" class="primary" @click="creating = false">Done</button>
        <template v-else>
          <button @click="creating = false">Cancel</button>
          <button
            class="primary"
            type="submit"
            form="token-form"
            :disabled="create.busy.value || !form.name.trim() || (form.kind === 'evaluation' && !form.environment)"
          >
            Create
          </button>
        </template>
      </template>
    </Modal>
  </div>
</template>
